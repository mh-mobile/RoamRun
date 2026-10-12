//! `roamrunctl pair control --with <machine>`: this machine comes to hold a pairing of its own with a
//! device it isn't near. The machine named sits on the device's Wi‑Fi and introduces it (`roamrunctl pair
//! introduce --host <this one>`, `roamrun pair introduce`, or the Introducer app); what the two say is
//! what a Mac's `roamrun pair control --with` says.

use std::net::{Ipv4Addr, TcpListener};
use std::sync::{mpsc, Arc};
use std::time::{Duration, Instant};

use roamrun_device::safe::Pairing;

use crate::lines::{self, Offer};
use crate::tailscale::{self, short};
use crate::wire::{self, Wire};
use crate::{device, secret};

/// How long the machine that introduces is waited for, and then the pairing itself.
const CONNECT: Duration = Duration::from_secs(600);
const PAIRING: Duration = Duration::from_secs(420);
const LINE: Duration = Duration::from_secs(30);
/// How often the device may come and not pair (a wrong code) before this gives up.
const TRIES: u32 = 5;

/// How a try at pairing ended, where it didn't pair.
enum Stopped {
    /// The device came and didn't pair, and nothing was kept: the other machine's command ends on that and is run again.
    Again(String),
    For(String),
}
/// What the device is told this machine is: one it lists a pairing under.
// A Mac's model, as the library's own calls give; a device shows the name, not this.
const MODEL: &str = "Mac17,7";

/// What tells this machine from another, whatever either is named: the same each time, so that
/// pairing again replaces the device's record of it.
fn host_id() -> Result<String, String> {
    let path = device::folder()?.with_file_name("host-id");
    if let Ok(id) = std::fs::read_to_string(&path) {
        if lines::is_uuid(id.trim()) { return Ok(id.trim().to_string()); }
    }
    let id = uuid()?;
    match device::own_whole(&path, id.as_bytes()) {
        Ok(()) => Ok(id),
        // Another command made it just now, whole: its id is this machine's. What isn't one is made anew.
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => match std::fs::read_to_string(&path) {
            Ok(theirs) if lines::is_uuid(theirs.trim()) => Ok(theirs.trim().to_string()),
            _ => {
                let _ = std::fs::remove_file(&path);
                device::own_whole(&path, id.as_bytes()).map(|()| id).map_err(|e| format!("{}: {e}", path.display()))
            }
        },
        Err(e) => Err(format!("{}: {e}", path.display())),
    }
}

pub fn random<const N: usize>() -> Result<[u8; N], String> {
    let mut b = [0u8; N];
    getrandom::fill(&mut b).map_err(|e| format!("no random source: {e}"))?;
    Ok(b)
}

fn uuid() -> Result<String, String> {
    let mut b: [u8; 16] = random()?;
    b[6] = b[6] & 0x0f | 0x40;
    b[8] = b[8] & 0x3f | 0x80;
    let hex: String = b.iter().map(|x| format!("{x:02X}")).collect();
    Ok(format!("{}-{}-{}-{}-{}", &hex[..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..]))
}

/// A device's name as a file's here.
pub fn filed(name: &str) -> String {
    let filed: String = name.chars().map(|c| if c.is_ascii_alphanumeric() || "-_.".contains(c) { c } else { '-' }).collect();
    // Not led by what a command reads as an option, or hides as a file.
    let filed = filed.trim_start_matches(['-', '.']);
    if filed.is_empty() { "device".into() } else { filed.into() }
}

/// The other machine's word for why it ended, as a sentence.
fn why_ended(word: &str) -> &'static str {
    match word {
        "deadline" => "the device wasn't paired in its time",
        "unreachable" => "it couldn't reach this machine's pairing port (Tailscale's rules, or a firewall here)",
        "offer-refused" => "it couldn't take this machine's offer",
        "address-lost" => "it lost its address on the device's network",
        "stopped" => "it was stopped there",
        _ => "its own terminal says why",
    }
}

/// What the Introducer app sends for the device's Tailscale name, which it can't learn: the device is the one asking.
const ITSELF: &str = "this-device.invalid";

/// The Tailscale name of the device a line names, sent by the machine named `with`.
fn device_named<'a>(peer: &'a str, with: &'a str) -> &'a str {
    if peer == ITSELF { with } else { peer }
}

/// What the device answered, where it did just as this was given up: a pairing it made isn't dropped.
fn late(told: &mpsc::Receiver<Result<String, String>>) -> Option<String> {
    told.try_iter().filter_map(Result::ok).find(|answer| device::said(answer.clone()).is_ok())
}

// Not eprintln!: it panics once the terminal is gone, and what is announced must still be taken back.
fn say(line: &str) {
    use std::io::Write;
    let _ = writeln!(std::io::stderr(), "{line}");
}

/// What the library says it listens with, as the offer the other machine announces.
pub fn offer(advert: &str) -> Result<String, String> {
    let said: serde_json::Value = serde_json::from_str(advert).map_err(|_| "the pairing's own announcement wasn't readable")?;
    let port = said["port"].as_u64().and_then(|p| u16::try_from(p).ok()).ok_or("the pairing listens on no port")?;
    let txt = said["txt"].as_object().ok_or("the pairing announces nothing")?
        .iter().filter_map(|(key, value)| Some((key.clone(), value.as_str()?.to_string()))).collect();
    let line = lines::offer_line(&Offer { port, txt, v: 1 });
    // As the other machine will read it: an offer that doesn't read as one isn't sent.
    lines::offer(&line).map(|_| line).map_err(|why| format!("this machine's own offer doesn't read as one ({why})"))
}

pub fn run(with: &str, name: Option<String>, sealed: bool) -> Result<String, String> {
    let status = tailscale::status()?;
    let own: Ipv4Addr = status.this.ips.iter().find_map(|a| a.parse().ok()).ok_or("this machine has no IPv4 address on the tailnet")?;
    let me = short(&status.this.dns_name).to_string();
    let other = tailscale::known(&status, with)?;
    if let Some(name) = &name { device::free(name)?; }
    // Before the device is asked anything: a pairing made and then not kept would leave it paired with nothing here.
    let passphrase = if sealed { Some(secret::passphrase("the pairing", true)?) } else { None };
    let host = host_id()?;
    let shown = lines::announced_name(&status.this.dns_name).ok_or("this machine's Tailscale name can't be shown on a device: rename it there")?;
    let listener = TcpListener::bind((own, wire::PORT)).map_err(|e| if e.kind() == std::io::ErrorKind::AddrInUse {
        "something on this machine already waits for a pairing (RoamRun's app, or another roamrunctl): end that first".to_string()
    } else { format!("can't listen on {own}: {e}") })?;
    listener.set_nonblocking(true).map_err(|e| e.to_string())?;
    note!("Waiting for {with}, 10 minutes at most; only it is answered.\n  There, on the device's Wi‑Fi:  roamrunctl pair introduce --host {me} --to <the device's Tailscale name>\n  (or `roamrun pair introduce --host {me} --to <device>` on a Mac, or the RoamRun Introducer app)");
    let mut until = Instant::now() + CONNECT;
    let mut tried = 0;
    loop {
        if Instant::now() >= until { return Err(format!("{with} didn't come in 10 minutes: nothing was paired")); }
        let (stream, from) = match listener.accept() {
            Ok(came) => came,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => { std::thread::sleep(Duration::from_millis(200)); continue }
            Err(e) => return Err(format!("can't take a connection: {e}")),
        };
        // Whoever connects is held to being the machine named, by address and by Tailscale's own id for it.
        if from.ip() != std::net::IpAddr::V4(other.ip) { note!("Turned away a connection from {}: it isn't {with}.", from.ip()); continue }
        if !tailscale::status().and_then(|now| tailscale::known(&now, with)).is_ok_and(|now| now.is(&other)) {
            note!("Turned away a connection: Tailscale couldn't say just then that it is {with}.");
            continue;
        }
        stream.set_nonblocking(false).map_err(|e| e.to_string())?;
        let Some(mut link) = Wire::over(stream) else { continue };
        let first = link.read(LINE);
        if first.as_deref() != Ok("offer?") {
            // What only a Mac does (standing in for a device that is picked): said, and waited on again.
            if first.is_ok_and(|said| said.starts_with("pairable ")) { let _ = link.send("ended failed"); }
            continue;
        }
        if link.send("device?").is_err() { continue }
        let Ok(said) = link.read(LINE) else { continue };
        let Some(line) = said.strip_prefix("device ") else { continue };
        match paired(link, with, &me, own, other.ip, line, name.clone(), passphrase.as_deref(), &host, &shown) {
            Ok(said) => return Ok(said),
            Err(Stopped::Again(why)) if tried + 1 < TRIES => {
                tried += 1;
                until = Instant::now() + CONNECT;
                note!("{why}\nStill waiting for {with}: run its command again (10 minutes at most).");
            }
            Err(Stopped::Again(why)) | Err(Stopped::For(why)) => return Err(why),
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn paired(mut link: Wire, with: &str, me: &str, own: Ipv4Addr, only: Ipv4Addr, line: &str, name: Option<String>, passphrase: Option<&str>, host: &str, shown: &str) -> Result<String, Stopped> {
    let refuse = |link: &mut Wire, how: &str, why: String| -> Result<String, Stopped> { let _ = link.send(&format!("result failed {how}")); Err(Stopped::For(why)) };
    let Ok(sent) = lines::device(line) else { return refuse(&mut link, "failed", format!("{with} sent something that isn't a device")) };
    // The device is the one Tailscale has under that name on this machine's tailnet, not an address that was sent.
    let asked = device_named(&sent.peer, with);
    let there = match tailscale::status().and_then(|now| tailscale::known(&now, asked)) {
        Ok(there) => there,
        Err(why) => return refuse(&mut link, "failed", format!("the device {with} names ({asked}) isn't on this machine's tailnet: {why}")),
    };
    // The app sends the name its owner gave the device; a file here is named as Tailscale names it.
    let name = name.unwrap_or_else(|| if sent.peer == ITSELF { filed(short(&there.dns)) } else { filed(&sent.name) });
    // "exists" where the name is taken; a name that can't be one here isn't that.
    if let Err(why) = device::free(&name) { return refuse(&mut link, if why.contains("saved here already") { "exists" } else { "failed" }, why); }
    let socket = TcpListener::bind((own, 0)).map_err(|e| Stopped::For(format!("can't listen on {own}: {e}")))?;
    let port = socket.local_addr().map(|at| at.port()).unwrap_or(0);
    let (pairing, advert) = match Pairing::listen_on(shown, MODEL, host, socket, &only.to_string()) {
        Ok(listening) => listening,
        Err(why) => return refuse(&mut link, "failed", format!("couldn't listen for the device: {why}")),
    };
    let offer = match offer(&advert) { Ok(offer) => offer, Err(why) => return refuse(&mut link, "failed", why) };
    let attempt = uuid().map_err(Stopped::For)?;
    link.send(&format!("offer {offer}")).and_then(|()| link.send(&format!("attempt {attempt}"))).map_err(Stopped::For)?;
    note!("{with} has this machine's offer, and carries the device's connection to TCP port {port} here (another each time: {with} has to be let in on it). On the device: Settings › Privacy & Security › Developer Mode › “{shown}”, and type the code that shows here (and there). {with}'s command gives it 5 minutes.");
    let pairing = Arc::new(pairing);
    let (tell, told) = mpsc::channel::<Result<String, String>>();
    let waits = {
        let (pairing, tell) = (pairing.clone(), tell.clone());
        std::thread::spawn(move || {
            let code = tell.clone();
            let answer = pairing.accept(move |digits| { let _ = code.send(Err(digits.to_string())); });
            let _ = tell.send(Ok(answer));
        })
    };
    let until = Instant::now() + PAIRING;
    let answer = loop {
        match told.recv_timeout(Duration::from_millis(200)) {
            // The code: shown here, and sent to where the device is.
            Ok(Err(digits)) => { note!("Code: {digits}"); let _ = link.send(&format!("code {digits}")); }
            Ok(Ok(answer)) => break Ok(answer),
            Err(_) => {}
        }
        if Instant::now() >= until { break Err("no pairing was made in 7 minutes".to_string()) }
        match link.read(Duration::from_millis(100)) {
            Ok(said) if said.starts_with("ended ") => break Err(format!("{with} ended it: {}", why_ended(&said[6..]))),
            Err(why) if why == wire::CLOSED => break Err(format!("{with} went away")),
            _ => {}
        }
    };
    if answer.is_err() { pairing.cancel(); }
    let _ = waits.join();
    let answer = match answer.or_else(|why| late(&told).ok_or(why)) {
        Ok(answer) => answer,
        Err(why) => return refuse(&mut link, "failed", format!("{why}: nothing was kept. Run both commands again")),
    };
    let made = match device::said(answer) {
        Ok(made) => made,
        Err(why) => {
            let _ = link.send("result failed not-paired");
            return Err(Stopped::Again(format!("The device didn't pair ({why}): nothing was kept. If “{shown}” is in the device's list all the same, remove it there.")));
        }
    };
    let Some(key) = made["pairing"].as_str() else { return refuse(&mut link, "failed", "the pairing came without its key".into()) };
    // Tried before it is kept, over the tailnet as it will be used: one that doesn't open the device isn't kept.
    note!("The device paired. Trying it over the tailnet before it is kept: leave this running.");
    match device::keep(&name, there.ip, sent.port, key, passphrase) {
        Ok(kept) => {
            let _ = link.send("result done on");
            Ok(format!("Paired with {} as “{shown}”, and it connects. {kept}\nTo withdraw it: `roamrunctl devices remove {name}`, and remove “{shown}” on the device, in that list.", sent.name))
        }
        Err(why) => refuse(&mut link, "not-kept", format!("paired, but not kept here ({why}): remove “{shown}” on the device, in that list, and run both commands again (this machine is {me})")),
    }
}

/// `roamrunctl pair control --to <device>`: a device on this machine's own Wi‑Fi, paired here and now. This
/// machine announces itself there, the device is picked on its own screen, and the code shows here.
pub fn here(to: &str, name: Option<String>, sealed: bool) -> Result<String, String> {
    let status = tailscale::status()?;
    let device = tailscale::peer(&status, to)?;
    let me = short(&status.this.dns_name).to_string();
    // The device finds this machine by what is announced on the Wi‑Fi both are on, and is known there by its address.
    let lan = device.lan.ok_or_else(|| format!("Tailscale doesn't reach {} directly on a network this machine is on (relayed, or over IPv6): to pair here the device has to be on this machine's Wi‑Fi. From elsewhere: roamrunctl pair control --with <a machine on its Wi‑Fi>", device.dns))?;
    let local = match crate::lan_ip(lan, None) {
        Ok((local, _)) => local,
        Err(_) => return Err(format!("this machine has no address on {}'s network: to pair here it has to be on the device's Wi‑Fi. From elsewhere: roamrunctl pair control --with <a machine on its Wi‑Fi>", device.dns)),
    };
    let name = name.unwrap_or_else(|| filed(short(&device.dns)));
    device::free(&name)?;
    // Before the device is asked anything: a pairing made and then not kept would leave it paired with nothing here.
    let passphrase = if sealed { Some(secret::passphrase("the pairing", true)?) } else { None };
    let host = host_id()?;
    let shown = lines::announced_name(&status.this.dns_name).ok_or("this machine's Tailscale name can't be shown on a device: rename it there")?;
    let socket = TcpListener::bind((local, 0)).map_err(|e| format!("can't listen on {local}: {e}"))?;
    let (pairing, advert) = Pairing::listen_on(&shown, MODEL, &host, socket, &lan.to_string()).map_err(|why| format!("couldn't listen for the device: {why}"))?;
    let read = lines::offer(&offer(&advert)?)?;
    let identifier = read.txt.get("identifier").cloned().ok_or("the pairing announces no identifier")?;
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())?;
    let announcement = crate::announce::start(&format!("{}.local.", crate::HOST_SERVICE), &identifier, local, read.port, &read.txt)?;
    say(&format!("Announced “{shown}” on {local} (TCP port {}, which {lan} has to be let in on); only {} is taken. On the device: Settings › Privacy & Security › Developer Mode › “{shown}”, and type the code that shows here. 7 minutes at most; Ctrl-C gives up.", read.port, device.dns));
    let pairing = Arc::new(pairing);
    let (tell, told) = mpsc::channel::<Result<String, String>>();
    let waits = {
        let (pairing, tell) = (pairing.clone(), tell.clone());
        std::thread::spawn(move || {
            let code = tell.clone();
            let answer = pairing.accept(move |digits| { let _ = code.send(Err(digits.to_string())); });
            let _ = tell.send(Ok(answer));
        })
    };
    let until = Instant::now() + PAIRING;
    let answer = runtime.block_on(async {
        // Ctrl-C, and a closed terminal or a dropped ssh session too.
        let answer = match crate::stops() {
            Err(why) => Err(why),
            Ok(mut stopped) => loop {
                match told.try_recv() {
                    Ok(Err(digits)) => say(&format!("Code: {digits}")),
                    Ok(Ok(answer)) => break Ok(answer),
                    Err(_) => {}
                }
                if Instant::now() >= until { break Err("no pairing was made in 7 minutes".to_string()) }
                tokio::select! {
                    _ = stopped.changed() => break Err("stopped".to_string()),
                    _ = tokio::time::sleep(Duration::from_millis(200)) => {}
                }
            },
        };
        // Taken off the Wi‑Fi however it ended: left there, the device would go on offering to pair with it.
        if !announcement.unregister().await { say("The announcement may linger on this network for a while."); }
        announcement.shutdown().await;
        answer
    });
    if answer.is_err() { pairing.cancel(); }
    let _ = waits.join();
    let answer = answer.or_else(|why| late(&told).ok_or(why))
        .map_err(|why| if why.starts_with("no pairing") {
            format!("{why}: nothing was kept. If the device showed “{shown}” and nothing came of picking it: this machine's firewall may keep the device ({lan}) from TCP port {} here", read.port)
        } else { format!("{why}: nothing was kept") })?;
    let made = device::said(answer).map_err(|why| format!("the device didn't pair ({why}): nothing was kept. If “{shown}” is in the device's list all the same, remove it there. Run this again"))?;
    let key = made["pairing"].as_str().ok_or("the pairing came without its key")?;
    // Tried before it is kept, over the tailnet as it will be used.
    say("The device paired. Trying it over the tailnet before it is kept: leave this running.");
    match device::keep(&name, device.ip, 49152, key, passphrase.as_deref()) {
        Ok(kept) => Ok(format!("Paired with {} as “{shown}”, and it connects. {kept}\nTo withdraw it: `roamrunctl devices remove {name}`, and remove “{shown}” on the device, in that list.", device.dns)),
        Err(why) => Err(format!("paired, but not kept here ({why}): remove “{shown}” on the device, in that list, and run this again (this machine is {me})")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn what_is_listened_with_reads_as_an_offer() {
        let advert = r#"{"port":50123,"identifier":"0F0E0D0C-0B0A-4908-8706-050403020100","txt":{"identifier":"0F0E0D0C-0B0A-4908-8706-050403020100","authTag":"dGFn","model":"Mac17,7","name":"box","flags":"1","ver":"24","minVer":"17"}}"#;
        let line = offer(advert).unwrap();
        let read = lines::offer(&line).unwrap();
        assert_eq!((read.port, read.txt["name"].as_str()), (50123, "box"));
        assert!(offer("{}").is_err() && offer("not json").is_err());
        assert!(offer(r#"{"port":1,"txt":{"name":"only"}}"#).is_err());
    }

    #[test]
    fn an_id_is_one_and_a_name_is_a_files() {
        let id = uuid().unwrap();
        assert!(lines::is_uuid(&id) && id != uuid().unwrap());
        assert_eq!(filed("Taro's iPhone 15"), "Taro-s-iPhone-15");
        // Not a name a command would read as an option.
        assert_eq!((filed("太郎のiPhone"), filed("太郎")), ("iPhone".to_string(), "device".to_string()));
    }

    #[test]
    fn the_app_on_the_device_is_the_device() {
        assert_eq!(device_named("this-device.invalid", "my-iphone"), "my-iphone");
        assert_eq!(device_named("my-ipad.tail.ts.net", "my-pc"), "my-ipad.tail.ts.net");
    }
}
