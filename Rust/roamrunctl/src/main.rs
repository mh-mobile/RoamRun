//! `roamrunctl`: RoamRun's `pair introduce` from a machine that has no RoamRun.
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
use std::io::Write;
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tailscale::{short, Peer, Status};
use tokio::sync::{mpsc, watch};

const HOST_SERVICE: &str = "_remotepairing-pairable-host._tcp";

#[derive(Parser)]
#[command(name = "roamrunctl", version = env!("ROAMRUN_VERSION"), about = "Introduces a far Mac to a device, from a machine that has no RoamRun")]
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
    /// This machine's address on the device's LAN, when it has more than one there and the device doesn't list the far Mac
    #[arg(long)]
    on: Option<Ipv4Addr>,
    #[arg(long, hide = true, default_value = HOST_SERVICE)]
    service: String,
    #[arg(long, hide = true)]
    far_ip: Option<Ipv4Addr>,
    #[arg(long, hide = true)]
    device_ip: Option<Ipv4Addr>,
}

// Not eprintln!: it panics once the terminal is gone, and what is announced must still be taken back.
macro_rules! say { ($($t:tt)*) => {{ let _ = writeln!(std::io::stderr(), "roamrunctl: {}", format!($($t)*)); }} }

fn main() {
    let Cli { command: Command::Pair { command: Pair::Introduce(args) } } = Cli::parse();
    match introduce(args) {
        Ok((line, saved)) => {
            if let Some(line) = line {
                let _ = writeln!(std::io::stdout(), "{line}");
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
    let (mut lan, mut local, mut also) = place(&device, a.on)?;
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
                // Gone before it was asked is gone before it answered: tried again, as RoamRun does.
                let answer = match w.send("offer?").map_err(|_| wire::CLOSED.to_string()).and_then(|_| w.read(left)) {
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
                        let named = Device { name: a.save_as.clone().unwrap_or_else(|| short(&device.dns).to_string()), peer: device.dns.to_lowercase(), port, txt, v: 1 };
                        let line = lines::device_line(&named);
                        lines::device(&line).map_err(|why| format!("what the device announces can't be handed over ({why})"))?;
                        w.send(&format!("device {line}"))?;
                        let offered = w.read(left)?;
                        match (offered.split_once(' '), wire::said(&offered)) {
                            (Some(("offer", line)), _) => {
                                // Its attempt's id follows at once; without it this isn't the pairing it asked about.
                                let Ok(wire::Said::Attempt(id)) = w.read(Duration::from_secs(10)).map(|l| wire::said(&l)) else {
                                    return Err("far Mac offered without saying which attempt it is; nothing was announced".into());
                                };
                                attempt = Some(id);
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
    // The wait for an offer may have been ten minutes: whose the far Mac's address is, and where
    // the device is, are asked again before anything is announced, as RoamRun does.
    if let (Some(w), Some(_)) = (wire.as_mut(), &status) {
        let now = tailscale::status().and_then(|now| Ok((tailscale::peer(&now, &a.mac)?, tailscale::peer(&now, &a.to)?)));
        let placed = now.and_then(|(far_now, device_now)| match (far_now.is(&far), device_now.is(&device)) {
            (true, true) => place(&device_now, a.on),
            (false, _) => Err(format!("{} isn't the machine it was when this began", far.dns)),
            (_, false) => Err(format!("{} isn't the device it was when this began", device.dns)),
        });
        match placed {
            Ok(now) if now == (lan, local, also.clone()) => {}
            Ok(now) => {
                (lan, local, also) = now;
                say!("the device is at {lan} now; this machine {local}");
            }
            Err(why) => {
                let _ = w.send("ended failed");
                return Err(format!("{why}; nothing was announced"));
            }
        }
    }
    // Which of them the device is beyond can't be told from here when they aren't one network.
    let also = also.iter().map(Ipv4Addr::to_string).collect::<Vec<_>>().join(", ");
    if !also.is_empty() {
        say!("this machine is also {also} on that network: if the device doesn't list the far Mac, run this again with --on <one of them>");
    }
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
    let plan = Plan { service, offer, far: far.ip, lan, local, also, deadline: a.deadline, listed_as, control };
    let rt = tokio::runtime::Runtime::new().map_err(|e| e.to_string())?;
    // From here on: before anything is announced, and until the far Mac has been told.
    let stopped = {
        let _in = rt.enter();
        stops()?
    };
    let outcome = rt.block_on(session(plan, wire.as_ref(), stopped.clone()));

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
            let _ = w.send("ended no-line");
        }
        return Err("the device's own announcement wasn't seen here: on the far Mac, run `roamrun devices add` by hand with a line from a Mac that has it".into());
    };
    // Saved there under its Tailscale name unless another was asked for: what it announces itself as is "iPhone" for most.
    found.name = a.save_as.unwrap_or_else(|| short(&device.dns).to_string());
    // Its whole name: the far Mac may be of another tailnet, where the first label alone is another's.
    found.peer = device.dns.to_lowercase();
    let line = lines::device_line(&found);
    if let Err(why) = lines::device(&line) {
        if let Some(w) = wire.as_mut() {
            let _ = w.send("ended no-line");
        }
        return Err(format!("what the device announces can't be handed over ({why}): on the far Mac, run `roamrun devices add` by hand with a line from a Mac that has it"));
    }
    let Some(mut w) = wire else { return Ok((Some(line), true)) };
    let unknown = "whether the far Mac saved it couldn't be learned: there, `roamrun devices` shows; if it isn't listed, `roamrun devices add` with the line below.";
    // Told before anything can stop this: a far Mac left without it would wait its ten minutes out.
    let told = w.send(&format!("tried {line}"));
    // Stopping is this program's to act on by now: without this it would wait out the read.
    let on_stop = rt.spawn({
        let (line, mut stopped) = (line.clone(), stopped);
        async move {
            if stopped.wait_for(|s| *s).await.is_ok() {
                say!("stopped; {unknown}");
                let _ = writeln!(std::io::stdout(), "{line}");
                std::process::exit(1);
            }
        }
    });
    let exchange = rt.spawn_blocking(move || told.and_then(|_| w.read(Duration::from_secs(30))));
    let answer = rt.block_on(exchange).unwrap_or_else(|e| Err(e.to_string()));
    on_stop.abort();
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
        (Some(ip), _) => Ok(Peer { id: String::new(), ip, dns: name.to_string(), lan }),
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

/// Where the device is on this LAN, this machine's address there, and its others there.
fn place(device: &Peer, on: Option<Ipv4Addr>) -> Result<(Ipv4Addr, Ipv4Addr, Vec<Ipv4Addr>), String> {
    match device.lan.map(|lan| (lan, lan_ip(lan, on))) {
        Some((lan, Ok((local, also)))) => Ok((lan, local, also)),
        Some((_, Err(Elsewhere::NotOn(why)))) => Err(why),
        _ => Err(format!(
            "Tailscale doesn't reach {} directly on this LAN (relayed, IPv6, or off this subnet): its connection couldn't be told from another host's",
            device.dns
        )),
    }
}

/// Why this machine has no address on a device's LAN.
enum Elsewhere {
    None,
    /// `--on` names one it hasn't there: the sentence.
    NotOn(String),
}

/// This machine's address on the LAN that has `toward`: the one of its interfaces whose own
/// network holds that address. Not what the routing table would pick (a route Tailscale took
/// in may lead there another way), and from the prefix length each system gives as it is (the
/// netmask is worked out differently on each, and on Windows by a guess).
fn lan_ip(toward: Ipv4Addr, on: Option<Ipv4Addr>) -> Result<(Ipv4Addr, Vec<Ipv4Addr>), Elsewhere> {
    let interfaces: Vec<(Ipv4Addr, u8, bool)> = if_addrs::get_if_addrs()
        .map_err(|_| Elsewhere::None)?
        .iter()
        .filter_map(|i| match &i.addr {
            if_addrs::IfAddr::V4(a) => Some((a.ip, a.prefixlen, i.is_oper_up())),
            _ => None,
        })
        .collect();
    // Where the system would send from: no more than a hint between interfaces that are there anyway.
    let routed = || match std::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).and_then(|s| s.connect((toward, 9)).and_then(|_| s.local_addr())).ok()?.ip() {
        std::net::IpAddr::V4(ip) => Some(ip),
        _ => None,
    };
    on_lan(&interfaces, toward, on.or_else(routed), on.is_some())
}

/// Of (address, prefix length, up), the one on `toward`'s network, and the others alike: the
/// narrowest network that holds it (a VPN's 10/8 also holds a Wi-Fi's 10.0.0/24), and among
/// several of those `wanted` — which must be one of them when it is `asked` for — else the first.
fn on_lan(interfaces: &[(Ipv4Addr, u8, bool)], toward: Ipv4Addr, wanted: Option<Ipv4Addr>, asked: bool) -> Result<(Ipv4Addr, Vec<Ipv4Addr>), Elsewhere> {
    let mut here: Vec<_> = interfaces.iter().filter(|(ip, prefix, up)| *up && !ip.is_loopback() && same_net(toward, *ip, mask(*prefix))).collect();
    if let (Some(on), true) = (wanted, asked) {
        if !here.iter().any(|i| i.0 == on) {
            return Err(Elsewhere::NotOn(format!("--on {on} isn't an address of this machine on {toward}'s network")));
        }
    }
    // The one asked for stays, wherever it is; the others are those of the narrowest network alone.
    let narrowest = here.iter().map(|i| i.1).max().ok_or(Elsewhere::None)?;
    here.retain(|i| i.1 == narrowest || asked && Some(i.0) == wanted);
    let one = here.iter().map(|i| i.0).find(|ip| Some(*ip) == wanted).or(here.first().map(|i| i.0)).ok_or(Elsewhere::None)?;
    Ok((one, here.iter().map(|i| i.0).filter(|ip| *ip != one).collect()))
}

/// Set once this is told to stop: Ctrl-C, and what a closed terminal or a dropped ssh session
/// sends. Without the latter two the announcement would stay on the LAN for its 75 minutes.
fn stops() -> Result<watch::Receiver<bool>, String> {
    let (tx, rx) = watch::channel(false);
    macro_rules! on {
        ($signal:expr) => {{
            let (mut signal, tx) = ($signal.map_err(|e| format!("signals couldn't be listened for ({e})"))?, tx.clone());
            tokio::spawn(async move {
                if signal.recv().await.is_some() {
                    let _ = tx.send(true);
                }
            });
        }};
    }
    #[cfg(unix)]
    {
        use tokio::signal::unix::{signal, SignalKind};
        on!(signal(SignalKind::interrupt()));
        on!(signal(SignalKind::terminate()));
        on!(signal(SignalKind::hangup()));
    }
    #[cfg(windows)]
    {
        use tokio::signal::windows::{ctrl_break, ctrl_c, ctrl_close};
        on!(ctrl_c());
        on!(ctrl_break());
        on!(ctrl_close());
    }
    Ok(rx)
}

fn mask(prefix: u8) -> Ipv4Addr {
    Ipv4Addr::from(u32::MAX.checked_shl(32 - u32::from(prefix.min(32))).unwrap_or(0))
}

/// A network of more than one host: a direct endpoint elsewhere (a public address through a NAT
/// hairpin, another LAN) or a point-to-point link says nothing about the device's address here.
fn same_net(a: Ipv4Addr, b: Ipv4Addr, mask: Ipv4Addr) -> bool {
    u32::from(mask) != 0 && u32::from(mask) != u32::MAX && u32::from(a) & u32::from(mask) == u32::from(b) & u32::from(mask)
}

struct Plan {
    service: String,
    offer: Offer,
    far: Ipv4Addr,
    lan: Ipv4Addr,
    local: Ipv4Addr,
    /// This machine's other addresses on the device's network, for a person to read.
    also: String,
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
async fn session(plan: Plan, far_link: Option<&wire::Wire>, mut stopped: watch::Receiver<bool>) -> Result<Ended, (&'static str, String)> {
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
        if stopped.wait_for(|s| *s).await.is_ok() {
            let _ = stop.send(Event::Stopped).await;
        }
    });
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(plan.deadline)).await;
        let _ = deadline.send(Event::Deadline).await;
    });
    let (lan, local, lost) = (plan.lan, plan.local, tx.clone());
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(2)).await;
            // Not there any more; interfaces that couldn't be read just then say nothing.
            if matches!(lan_ip(lan, Some(local)), Err(Elsewhere::NotOn(_))) {
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
            far.blocking_send(said.map_or(Event::FarGone, Event::Far)).is_ok()
        })
    });
    let name = &plan.offer.txt["name"];
    say!("announced “{name}” ({}) on {}:{port}; taking connections from {} only.", announcement.fullname(), plan.local, plan.lan);
    say!("On the device: Settings › Privacy & Security › Developer Mode › Pair with “{name}”; type the code {}. {}s at most.",
         if plan.control { "that shows here once it is picked" } else { "the far Mac shows" }, plan.deadline);
    say!("Once paired the device lists it as “{}”.", plan.listed_as);

    let mut connected = false;
    let end = loop {
        match events.recv().await {
            Some(Event::Connected(from)) => {
                connected = true;
                say!("a device connected from {from}")
            }
            Some(Event::Refused(from)) => say!("refused connection from {from}"),
            Some(Event::Full(from)) => say!("two connections are carried already; one more from {from} wasn't taken"),
            Some(Event::FarDidNotAnswer(why)) => say!("far Mac didn't take it ({why})"),
            Some(Event::Carried) => break Ok(None),
            // For device control the far Mac passes the code on and says what it kept; for Xcode's
            // pairing it says nothing while it waits, so a word from it means it has stopped.
            Some(Event::Far(words)) if plan.control => match wire::said(&words) {
                wire::Said::Code(digits) => say!("Code to type on the device: {digits}"),
                wire::Said::Done(on) => break Ok(Some(Ended::Kept(on))),
                wire::Said::Failed(why) => break Ok(Some(Ended::KeptNothing(why))),
                wire::Said::Ended(why) => break Err(("stopped", format!("far Mac: {}", ended(&why)))),
                wire::Said::Other | wire::Said::Attempt(_) => break Err(("stopped", "the far Mac said something else, and was left".to_string())),
            },
            Some(Event::Far(_)) | Some(Event::NoResult) => break Err(("stopped", "the far Mac's command ended".to_string())),
            // Listed on the device and no connection here is what a firewall in between looks like.
            Some(Event::Deadline) => break Err((
                "deadline",
                if connected {
                    "nothing was paired in time: the device connected, and its pairing didn't come to an end".to_string()
                } else {
                    format!(
                        "nothing was paired in time. If the device listed the far Mac and got no further, a firewall here keeps it out: let TCP from {} in on port {port}{}",
                        plan.lan,
                        if plan.also.is_empty() { String::new() } else { format!(". If it didn't list it at all: run this again with --on <one of {}>", plan.also) }
                    )
                },
            )),
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
                    // Its app holds the pairing by now and says what came of it, whoever listens.
                    Some(Event::Stopped) => break Ok(Ended::NotSaid),
                    _ => {}
                }
            }
        }
        Ok(None) => Ok(Ended::Tried(device_seen(&announcement, &seen, plan.lan).await)),
    };
    over.store(true, Ordering::Relaxed);
    // A far Mac that goes on talking would otherwise hold its reader on a full channel, and this on it.
    events.close();
    if let Some(w) = watching {
        let _ = w.join();
    }
    announcement.shutdown().await;
    found
}

async fn collect(rx: mdns_sd::Receiver<ServiceEvent>, seen: Seen) {
    while let Ok(event) = rx.recv_async().await {
        note(&seen, event);
    }
}

/// Keeps what is announced now: a record taken back is no longer the device's.
fn note(seen: &Seen, event: ServiceEvent) {
    let mut seen = seen.lock().unwrap_or_else(|e| e.into_inner());
    match event {
        ServiceEvent::ServiceResolved(service) => drop(seen.insert(service.fullname.clone(), *service)),
        ServiceEvent::ServiceRemoved(_, fullname) => drop(seen.remove(&fullname)),
        _ => {}
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
            Ok(Ok(event)) => note(seen, event),
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
        // A point-to-point link (Tailscale's own interface is a /32) is nobody's LAN.
        assert!(!same_net(a, a, Ipv4Addr::BROADCAST));
        assert_eq!(super::mask(24), mask);
        assert_eq!(super::mask(0), Ipv4Addr::UNSPECIFIED);
        assert_eq!(super::mask(32), Ipv4Addr::BROADCAST);
        assert_eq!(super::mask(20), Ipv4Addr::new(255, 255, 240, 0));
        // Whatever the routing table says, loopback and an address on no interface's network aren't here.
        assert!(lan_ip(Ipv4Addr::new(203, 0, 113, 7), None).is_err());
        assert_eq!(name("  iPhone "), Ok("iPhone".into()));
        assert!(name("-x").is_err());
        assert!(name(" ").is_err());
    }

    #[test]
    fn the_interface_on_the_devices_lan() {
        let ip = |d: u8| Ipv4Addr::new(10, 0, 0, d);
        let pick = |interfaces: &[(Ipv4Addr, u8, bool)], wanted, asked| on_lan(interfaces, ip(30), wanted, asked).ok();
        let (vpn, wifi, wired) = ((Ipv4Addr::new(10, 8, 0, 2), 8, true), (ip(20), 24, true), (ip(10), 24, true));
        let alone = |d| Some((ip(d), vec![]));
        // A wider network that holds the device's address too isn't its LAN, whichever is listed
        // first and wherever the system would send from.
        assert_eq!(pick(&[vpn, wifi], None, false), alone(20));
        assert_eq!(pick(&[wifi, vpn], Some(vpn.0), false), alone(20));
        // One that is down announces nothing.
        assert_eq!(pick(&[(ip(10), 24, false), wifi], None, false), alone(20));
        assert_eq!(pick(&[(ip(20), 24, false)], None, false), None);
        // Several alike: it goes on with where the system sends from, else the first, and says the rest.
        let bridge = (ip(25), 24, true);
        assert_eq!(pick(&[wired, wifi, bridge], None, false), Some((ip(10), vec![ip(20), ip(25)])));
        assert_eq!(pick(&[wired, wifi, bridge], Some(ip(20)), false), Some((ip(20), vec![ip(10), ip(25)])));
        // A route Tailscale took in leads elsewhere: not an address of this LAN, so not taken.
        assert_eq!(pick(&[wired, wifi], Some(Ipv4Addr::new(100, 64, 0, 1)), false), Some((ip(10), vec![ip(20)])));
        // Asked for, it is that one or nothing; a wider network may be asked for too.
        assert_eq!(pick(&[wired, wifi], Some(ip(20)), true), Some((ip(20), vec![ip(10)])));
        assert_eq!(pick(&[wired, wifi], Some(ip(99)), true), None);
        assert_eq!(pick(&[vpn, wifi], Some(vpn.0), true), Some((vpn.0, vec![ip(20)])));
        // The others said are never of a wider network.
        assert_eq!(pick(&[vpn, wired, wifi], Some(ip(20)), true), Some((ip(20), vec![ip(10)])));
    }

    #[test]
    fn a_record_taken_back_is_forgotten() {
        let seen: Seen = Default::default();
        let info = mdns_sd::ServiceInfo::new(announce::DEVICE_SERVICE, "phone", "phone.local.", "192.168.0.19", 49152, None).unwrap();
        note(&seen, ServiceEvent::ServiceResolved(Box::new(info.clone().as_resolved_service())));
        assert_eq!(seen.lock().unwrap().len(), 1);
        note(&seen, ServiceEvent::ServiceRemoved(announce::DEVICE_SERVICE.into(), info.get_fullname().into()));
        assert!(seen.lock().unwrap().is_empty());
    }
}
