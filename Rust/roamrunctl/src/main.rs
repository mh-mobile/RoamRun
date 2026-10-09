//! `roamrunctl`: RoamRun's `pair introduce` from a machine that isn't a Mac. Prototype.
#![forbid(unsafe_code)]

mod announce;
mod lines;
mod relay;
mod tailscale;
mod wire;

use clap::{Args, Parser, Subcommand};
use lines::{Device, Offer, DEVICE_KEYS};
use mdns_sd::{ResolvedService, ServiceEvent};
use relay::Event;
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpStream, UdpSocket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tailscale::{short, Peer, Status};
use tokio::sync::mpsc;

const HOST_SERVICE: &str = "_remotepairing-pairable-host._tcp";

#[derive(Parser)]
#[command(name = "roamrunctl", version, about = "RoamRun from a machine that isn't a Mac (prototype)")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Pair a device with a Mac
    Pair {
        #[command(subcommand)]
        command: Pair,
    },
}

#[derive(Subcommand)]
enum Pair {
    /// Stand in on this LAN for a far Mac's offer to pair — with Xcode, or for device control, as that Mac asks — and carry the device's connection to it
    Introduce(Introduce),
}

#[derive(Args)]
struct Introduce {
    /// The far Mac's Tailscale name
    #[arg(long)]
    mac: String,
    /// The device's Tailscale name
    #[arg(long)]
    to: String,
    /// The far Mac's offer, from `roamrun pair xcode` there (else asked of it: `roamrun pair xcode --with <this machine>`)
    #[arg(long)]
    offer: Option<String>,
    /// The name the far Mac saves the device under
    #[arg(long = "as", value_parser = name)]
    save_as: Option<String>,
    /// Seconds to wait for the pairing
    #[arg(long, default_value_t = 300)]
    deadline: u64,
    #[arg(long, hide = true, default_value = HOST_SERVICE)]
    service: String,
    #[arg(long, hide = true)]
    far_ip: Option<Ipv4Addr>,
    #[arg(long, hide = true)]
    device_ip: Option<Ipv4Addr>,
}

macro_rules! say { ($($t:tt)*) => { eprintln!("roamrunctl: {}", format!($($t)*)) } }

fn main() {
    let Cli { command: Command::Pair { command: Pair::Introduce(args) } } = Cli::parse();
    match introduce(args) {
        Ok((line, saved)) => {
            if let Some(line) = line {
                println!("{line}");
            }
            std::process::exit(if saved { 0 } else { 1 });
        }
        Err(why) => {
            say!("{why}");
            std::process::exit(1);
        }
    }
}

/// `--as`, as the far Mac would take it; refused here, before anything is paired.
fn name(s: &str) -> Result<String, String> {
    lines::name_problem(s).map_or_else(|| Ok(s.trim().to_string()), Err)
}

/// The device's line for `roamrun devices add`, once a pairing with Xcode was tried, and whether the
/// far Mac saved it (true when no far Mac was asked: the line is all there is). For device control
/// there is no line: whether that Mac's app kept the pairing.
fn introduce(a: Introduce) -> Result<(Option<String>, bool), String> {
    // The far Mac waits 420 s after its offer; RoamRun's own introducer waits 300.
    if a.offer.is_none() && a.deadline > 300 {
        return Err("--deadline above 300 s isn't waited out by the far Mac".into());
    }
    let status = (a.far_ip.is_none() || a.device_ip.is_none()).then(tailscale::status).transpose()?;
    let far = lookup(&status, &a.mac, a.far_ip, None)?;
    let device = lookup(&status, &a.to, a.device_ip, a.device_ip)?;
    let own = status.as_ref().map_or("<this machine's Tailscale name>", |s| short(&s.this.dns_name)).to_string();
    let (lan, local) = match device.lan.map(|lan| (lan, lan_ip(lan))) {
        Some((lan, Ok(local))) if on_subnet(lan, local) => (lan, local),
        Some((_, Err(why))) => return Err(why),
        _ => {
            return Err(format!(
                "Tailscale doesn't reach {} directly on this LAN (relayed, IPv6, or off this subnet): its connection couldn't be told from another host's",
                device.dns
            ))
        }
    };
    say!("this machine {local}; device {} at {lan}; far Mac {} at {}", device.dns, far.dns, far.ip);

    let mut wire = None;
    // Device control: which of the far Mac's attempts this is, to ask it about afterwards.
    let mut attempt: Option<String> = None;
    let offer_line = match a.offer.clone() {
        Some(line) => line,
        None => {
            say!("asking {} for its offer (there: roamrun pair xcode --with {own}, or pair control --with {own} for device control)", far.dns);
            let until = Instant::now() + Duration::from_secs(600);
            loop {
                let left = until.saturating_duration_since(Instant::now()).max(Duration::from_secs(1));
                let mut w = wire::Wire::connect(far.ip, left).ok_or("far Mac isn't waiting (port 41830)")?;
                w.send("offer?")?;
                let answer = match w.read(left) {
                    Ok(answer) => answer,
                    // Closed without a word: it couldn't tell whose this address is just then, and listens on.
                    Err(why) if why == wire::CLOSED && Instant::now() < until => {
                        std::thread::sleep(Duration::from_secs(2));
                        continue;
                    }
                    Err(why) => return Err(why),
                };
                match answer.split_once(' ') {
                    Some(("offer", line)) => {
                        wire = Some(w);
                        break line.to_string();
                    }
                    Some(("ended", why)) => return Err(format!("far Mac: {}", ended(why))),
                    // Asked which device this is, before any offer: it pairs for device control.
                    None if answer == "device?" => {
                        say!("{} pairs for device control: programs there will be able to see {}'s screen and operate it.", far.dns, device.dns);
                        // Nothing was begun there yet: closing without a word leaves it waiting.
                        let Some((_, port, txt)) = announce::find_device(local, lan, &DEVICE_KEYS, Duration::from_secs(7)) else {
                            return Err(format!("{}'s own announcement wasn't seen on this LAN. It announces once it is paired with a Mac: pair Xcode first (there: roamrun pair xcode --with {own}), then this", device.dns));
                        };
                        let named = Device { name: a.save_as.clone().unwrap_or_else(|| short(&device.dns).to_string()), peer: short(&device.dns).to_lowercase(), port, txt, v: 1 };
                        let line = lines::device_line(&named);
                        lines::device(&line).map_err(|why| format!("what the device announces can't be handed over ({why})"))?;
                        w.send(&format!("device {line}"))?;
                        let offered = w.read(left)?;
                        match (offered.split_once(' '), wire::said(&offered)) {
                            (Some(("offer", line)), _) => {
                                // Its attempt's id follows at once.
                                attempt = w.read(Duration::from_secs(10)).ok().and_then(|l| l.strip_prefix("attempt ").map(str::to_string));
                                wire = Some(w);
                                break line.to_string();
                            }
                            (_, wire::Said::Failed(why)) => return Err(format!("far Mac: {}", kept_nothing(&why))),
                            (_, wire::Said::Ended(why)) => return Err(format!("far Mac: {}", ended(&why))),
                            _ => return Err("far Mac said something else than an offer".into()),
                        }
                    }
                    _ => return Err(format!("far Mac said something else: {answer:?}")),
                }
            }
        }
    };
    let mut offer = match lines::offer(&offer_line) {
        Ok(offer) => offer,
        Err(why) => {
            if let Some(w) = wire.as_mut() {
                let _ = w.send("ended offer-refused");
            }
            return Err(why);
        }
    };
    let listed_as = offer.txt["name"].clone();
    if let Some(name) = lines::announced_name(&far.dns) {
        offer.txt.insert("name".into(), name);
    }
    let service = if a.service.ends_with('.') { a.service.clone() } else { format!("{}.local.", a.service.trim_end_matches(".local")) };
    // Before anything is announced: the device would try a port nothing answers on.
    if TcpStream::connect_timeout(&SocketAddr::from((far.ip, offer.port)), Duration::from_secs(5)).is_err() {
        if let Some(w) = wire.as_mut() {
            let _ = w.send("ended unreachable");
        }
        return Err(if wire.is_none() {
            format!("{} isn't waiting to pair on port {} any more (or can't be reached): there, press Pair Nearby Device again and run `roamrun pair xcode` for a new line", far.dns, offer.port)
        } else {
            format!("{} answers, but its pairing port {} can't be reached from here: there, press Pair Nearby Device again; if it stays so, Tailscale's rules don't let this machine in on that port", far.dns, offer.port)
        });
    }

    let control = attempt.is_some();
    let plan = Plan { service, offer, far: far.ip, lan, local, deadline: a.deadline, listed_as, control };
    let rt = tokio::runtime::Runtime::new().map_err(|e| e.to_string())?;
    let outcome = rt.block_on(session(plan, wire.as_ref()));

    let found = match outcome {
        Err((reason, why)) => {
            if let Some(w) = wire.as_mut() {
                let _ = w.send(&format!("ended {reason}"));
            }
            return Err(why);
        }
        Ok(Ended::Kept(on)) => {
            say!("{} is paired with {} for device control{}", far.dns, device.dns,
                 if on { ", and it is switched on there." } else { ". It is switched off there: switch it on in the RoamRun app on that Mac; the pairing needn't be made again." });
            return Ok((None, true));
        }
        Ok(Ended::KeptNothing(why)) => return Err(format!("far Mac: {}", kept_nothing(&why))),
        Ok(Ended::NotSaid) => {
            return Err(format!("what the far Mac kept couldn't be learned. There: roamrun pair control --attempt {}", attempt.unwrap_or_else(|| "<its attempt's id>".into())))
        }
        Ok(Ended::Tried(found)) => found,
    };
    say!("A pairing was tried; whether it was made shows on the far Mac.");
    let Some(mut found) = found else {
        if let Some(w) = wire.as_mut() {
            let _ = w.send("ended failed");
        }
        return Err("the device's own announcement wasn't seen here: on the far Mac, run `roamrun devices add` by hand with a line from a Mac that has it".into());
    };
    // Saved there under its Tailscale name unless another was asked for: what it announces itself as is "iPhone" for most.
    found.name = a.save_as.unwrap_or_else(|| short(&device.dns).to_string());
    found.peer = short(&device.dns).to_lowercase();
    let line = lines::device_line(&found);
    if let Err(why) = lines::device(&line) {
        if let Some(w) = wire.as_mut() {
            let _ = w.send("ended failed");
        }
        return Err(format!("what the device announces can't be handed over ({why}): on the far Mac, run `roamrun devices add` by hand with a line from a Mac that has it"));
    }
    let Some(mut w) = wire else { return Ok((Some(line), true)) };
    let unknown = "whether the far Mac saved it couldn't be learned: there, `roamrun devices` shows; if it isn't listed, `roamrun devices add` with the line below.";
    // tokio holds SIGINT for the whole process: without this, Ctrl-C would wait out the read.
    let on_ctrl_c = rt.spawn({
        let line = line.clone();
        async move {
            if tokio::signal::ctrl_c().await.is_ok() {
                say!("stopped; {unknown}");
                println!("{line}");
                std::process::exit(1);
            }
        }
    });
    let exchange = {
        let line = line.clone();
        rt.spawn_blocking(move || w.send(&format!("tried {line}")).and_then(|_| w.read(Duration::from_secs(30))))
    };
    let answer = rt.block_on(exchange).unwrap_or_else(|e| Err(e.to_string()));
    on_ctrl_c.abort();
    match answer.as_deref() {
        Ok("saved") => say!("far Mac saved the device."),
        Ok("unsaved") => say!("far Mac didn't save it: run `roamrun devices add` there with the line below."),
        Ok(other) => say!("far Mac said something else: {other:?}; {unknown}"),
        Err(why) => say!("{why}; {unknown}"),
    };
    Ok((Some(line), matches!(answer.as_deref(), Ok("saved"))))
}

fn lookup(status: &Option<Status>, name: &str, ip: Option<Ipv4Addr>, lan: Option<Ipv4Addr>) -> Result<Peer, String> {
    match (ip, status) {
        (Some(ip), _) => Ok(Peer { ip, dns: name.to_string(), lan }),
        (None, Some(status)) => tailscale::peer(status, name),
        (None, None) => Err("no tailscale status".into()),
    }
}

/// The far Mac's word for why nothing came of it, as a sentence.
fn ended(reason: &str) -> String {
    match reason {
        "ambiguous" => "it offers more than one pairing; leave one in Xcode".into(),
        "no-offer" => "it made no offer in time (there: Xcode › Devices › Pair Nearby Device)".into(),
        "stopped" => "it was stopped".into(),
        _ => "it ended; its terminal says why".into(),
    }
}

/// The far Mac's word for why its app kept no pairing for device control, as a sentence.
fn kept_nothing(reason: &str) -> String {
    match reason {
        "exists" => "it already holds a pairing for that device: remove it there first (the RoamRun app, on the device's page), then run both again",
        "not-paired" => "the pairing wasn't completed on the device (a wrong code, refused there, or not in time); nothing was kept. Run this again: that Mac goes on waiting for it",
        "another-device" => "the device that paired isn't the one it has saved under that name; nothing was kept there. Remove the pairing just made on the device (Settings › Privacy & Security › Developer Mode)",
        "not-kept" => "the device paired, but that Mac couldn't keep the pairing (it says why). Remove the pairing just made on the device (Settings › Privacy & Security › Developer Mode)",
        "no-app" => "the RoamRun app isn't running there: it makes and keeps the pairing. Open it there and run both again",
        "cancelled" => "it was stopped there; nothing was kept",
        _ => "it kept nothing; its terminal says why",
    }
    .into()
}

/// This machine's address on the LAN that has `toward`.
fn lan_ip(toward: Ipv4Addr) -> Result<Ipv4Addr, String> {
    let socket = UdpSocket::bind("0.0.0.0:0").map_err(|e| e.to_string())?;
    socket.connect((toward, 9)).map_err(|e| format!("no route to {toward} ({e})"))?;
    match socket.local_addr().map_err(|e| e.to_string())?.ip() {
        IpAddr::V4(ip) => Ok(ip),
        other => Err(format!("{other} isn't an IPv4 address")),
    }
}

/// Whether `other` is on the subnet of the interface that has `local`: a direct endpoint elsewhere
/// (a public address through a NAT hairpin, another LAN) says nothing about the device's address here.
fn on_subnet(other: Ipv4Addr, local: Ipv4Addr) -> bool {
    if_addrs::get_if_addrs().unwrap_or_default().iter().any(|i| match &i.addr {
        if_addrs::IfAddr::V4(a) if a.ip == local => same_net(other, local, a.netmask),
        _ => false,
    })
}

fn same_net(a: Ipv4Addr, b: Ipv4Addr, mask: Ipv4Addr) -> bool {
    u32::from(mask) != 0 && u32::from(a) & u32::from(mask) == u32::from(b) & u32::from(mask)
}

struct Plan {
    service: String,
    offer: Offer,
    far: Ipv4Addr,
    lan: Ipv4Addr,
    local: Ipv4Addr,
    deadline: u64,
    listed_as: String,
    /// Device control: the far Mac's app pairs, passes the code on, and says what it kept.
    control: bool,
}

/// How a stand-in that wasn't cut short came out.
enum Ended {
    /// Xcode: a pairing was tried; the device's own announcement, if it was seen.
    Tried(Option<Device>),
    /// Device control: the far Mac's app kept the pairing; whether it is switched on there.
    Kept(bool),
    /// Device control: it kept nothing, and its word for why.
    KeptNothing(String),
    /// Device control: the device was done here and the far Mac didn't say what it kept.
    NotSaid,
}

type Seen = Arc<Mutex<HashMap<String, ResolvedService>>>;

/// Announces, relays, and ends: the device as seen on the LAN when a pairing was tried (None:
/// its announcement wasn't seen), or why nothing was (a wire reason word, and the sentence).
async fn session(plan: Plan, far_link: Option<&wire::Wire>) -> Result<Ended, (&'static str, String)> {
    let failed = |why: String| ("failed", why);
    let identifier = plan.offer.txt["identifier"].clone();
    let listener = relay::listen(plan.local, plan.offer.port).await.map_err(failed)?;
    let port = listener.local_addr().map_err(|e| failed(e.to_string()))?.port();
    let announcement = announce::start(&plan.service, &identifier, plan.local, port, &plan.offer.txt).map_err(failed)?;
    let seen: Seen = Default::default();
    if let Ok(rx) = announcement.browse(announce::DEVICE_SERVICE) {
        tokio::spawn(collect(rx, seen.clone()));
    }
    let (tx, mut events) = mpsc::channel(16);
    let serving = tokio::spawn(relay::serve(listener, plan.lan, SocketAddr::from((plan.far, plan.offer.port)), tx.clone()));
    let (deadline, stop) = (tx.clone(), tx.clone());
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(plan.deadline)).await;
        let _ = deadline.send(Event::Deadline).await;
    });
    tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            let _ = stop.send(Event::Stopped).await;
        }
    });
    let (lan, local, lost) = (plan.lan, plan.local, tx.clone());
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(2)).await;
            if lan_ip(lan).ok() != Some(local) {
                let _ = lost.send(Event::AddressLost).await;
                return;
            }
        }
    });
    // The far Mac's command ending ends this: nothing stays announced for a Mac that isn't waiting.
    let over = Arc::new(AtomicBool::new(false));
    let watching = far_link.and_then(|w| {
        let far = tx.clone();
        w.watch(over.clone(), move |said| {
            let _ = far.blocking_send(said.map_or(Event::FarGone, Event::Far));
        })
    });
    let name = &plan.offer.txt["name"];
    say!("announced “{name}” ({}) on {}:{port}; taking connections from {} only.", announcement.fullname(), plan.local, plan.lan);
    say!("On the device: Settings › Privacy & Security › Developer Mode › Pair with “{name}”; type the code {}. {}s at most.",
         if plan.control { "that shows here once it is picked" } else { "the far Mac shows" }, plan.deadline);
    say!("Once paired the device lists it as “{}”.", plan.listed_as);

    let end = loop {
        match events.recv().await {
            Some(Event::Connected(from)) => say!("a device connected from {from}"),
            Some(Event::Refused(from)) => say!("refused connection from {from}"),
            Some(Event::FarDidNotAnswer(why)) => say!("far Mac didn't take it ({why})"),
            Some(Event::Carried) => break Ok(None),
            // For device control the far Mac passes the code on and says what it kept; for Xcode's
            // pairing it says nothing while it waits, so a word from it means it has stopped.
            Some(Event::Far(words)) if plan.control => match wire::said(&words) {
                wire::Said::Code(digits) => say!("Code to type on the device: {digits}"),
                wire::Said::Done(on) => break Ok(Some(Ended::Kept(on))),
                wire::Said::Failed(why) => break Ok(Some(Ended::KeptNothing(why))),
                wire::Said::Ended(why) => break Err(("stopped", format!("far Mac: {}", ended(&why)))),
                wire::Said::Other => break Err(("stopped", "the far Mac said something else, and was left".to_string())),
            },
            Some(Event::Far(_)) | Some(Event::NoResult) => break Err(("stopped", "the far Mac's command ended".to_string())),
            Some(Event::Deadline) => break Err(("deadline", "nothing was paired in time".to_string())),
            Some(Event::Stopped) => break Err(("stopped", "stopped".to_string())),
            Some(Event::AddressLost) => break Err(("address-lost", "this machine's address on the LAN changed".to_string())),
            Some(Event::FarGone) => break Err(("stopped", "the far Mac's command ended".to_string())),
            None => break Err(failed("the relay ended".into())),
        }
    };
    serving.abort();
    if !announcement.unregister().await {
        say!("the announcement wasn't taken back cleanly; it may linger on the LAN for a while");
    }
    let found = match end {
        Err(why) => Err(why),
        Ok(Some(kept)) => Ok(kept),
        // The device is done here: nothing is announced any more, and the far Mac says what it kept.
        Ok(None) if plan.control => {
            say!("The device is done here; the far Mac says what it kept (90 seconds at most).");
            let late = tx.clone();
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_secs(90)).await;
                let _ = late.send(Event::NoResult).await;
            });
            loop {
                match events.recv().await {
                    Some(Event::Far(words)) => match wire::said(&words) {
                        wire::Said::Code(digits) => say!("Code to type on the device: {digits}"),
                        wire::Said::Done(on) => break Ok(Ended::Kept(on)),
                        wire::Said::Failed(why) => break Ok(Ended::KeptNothing(why)),
                        _ => break Ok(Ended::NotSaid),
                    },
                    Some(Event::FarGone) | Some(Event::NoResult) | None => break Ok(Ended::NotSaid),
                    Some(Event::Stopped) => break Err(("stopped", "stopped".to_string())),
                    _ => {}
                }
            }
        }
        Ok(None) => Ok(Ended::Tried(device_seen(&announcement, &seen, plan.lan).await)),
    };
    over.store(true, Ordering::Relaxed);
    if let Some(w) = watching {
        let _ = w.join();
    }
    announcement.shutdown().await;
    found
}

async fn collect(rx: mdns_sd::Receiver<ServiceEvent>, seen: Seen) {
    while let Ok(event) = rx.recv_async().await {
        if let ServiceEvent::ServiceResolved(service) = event {
            seen.lock().unwrap_or_else(|e| e.into_inner()).insert(service.fullname.clone(), *service);
        }
    }
}

/// The device's own announcement, as a line's worth: what was seen so far, or what a fresh
/// browse brings in the next few seconds (a device that just paired has only now begun to announce).
async fn device_seen(announcement: &announce::Announcement, seen: &Seen, lan: Ipv4Addr) -> Option<Device> {
    let found = |seen: &Seen| {
        let seen = seen.lock().unwrap_or_else(|e| e.into_inner());
        announce::device_among(seen.values(), lan, &DEVICE_KEYS).map(|(s, txt)| Device {
            name: s.host.split('.').next().filter(|h| !h.is_empty()).unwrap_or("iPhone").to_string(),
            peer: String::new(),
            port: s.port,
            txt,
            v: 1,
        })
    };
    let until = Instant::now() + Duration::from_secs(5);
    let rx = announcement.browse(announce::DEVICE_SERVICE).ok();
    loop {
        if let Some(device) = found(seen) {
            return Some(device);
        }
        let (Some(rx), Some(left)) = (&rx, until.checked_duration_since(Instant::now()).filter(|d| !d.is_zero())) else {
            return None;
        };
        match tokio::time::timeout(left, rx.recv_async()).await {
            Ok(Ok(ServiceEvent::ServiceResolved(service))) => {
                seen.lock().unwrap_or_else(|e| e.into_inner()).insert(service.fullname.clone(), *service);
            }
            Ok(Ok(_)) => {}
            _ => return found(seen),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn subnets() {
        let (mask, a) = (Ipv4Addr::new(255, 255, 255, 0), Ipv4Addr::new(192, 168, 0, 19));
        assert!(same_net(a, Ipv4Addr::new(192, 168, 0, 1), mask));
        assert!(!same_net(a, Ipv4Addr::new(192, 168, 1, 1), mask));
        assert!(!same_net(a, Ipv4Addr::new(203, 0, 113, 7), mask));
        assert!(!same_net(a, a, Ipv4Addr::UNSPECIFIED));
        assert_eq!(name("  iPhone "), Ok("iPhone".into()));
        assert!(name("-x").is_err());
        assert!(name(" ").is_err());
    }
}
