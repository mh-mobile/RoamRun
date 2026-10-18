//! Who is where on the tailnet, from the installed `tailscale` CLI.

use serde::Deserialize;
use std::io::Read;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Deserialize)]
pub struct Status {
    #[serde(rename = "Self")]
    pub this: Node,
    #[serde(rename = "Peer", default, deserialize_with = "or_none")]
    pub peers: std::collections::HashMap<String, Node>,
    #[serde(rename = "CurrentTailnet", default)]
    tailnet: Option<Tailnet>,
}

/// Tailscale writes a map or a list it has nothing in (no peers yet) as null.
fn or_none<'de, D: serde::Deserializer<'de>, T: Default + Deserialize<'de>>(d: D) -> Result<T, D::Error> {
    Ok(Option::<T>::deserialize(d)?.unwrap_or_default())
}

#[derive(Deserialize)]
struct Tailnet {
    #[serde(rename = "MagicDNSSuffix", default)]
    suffix: String,
}

#[derive(Deserialize)]
pub struct Node {
    #[serde(rename = "ID", default)]
    pub id: String,
    #[serde(rename = "DNSName", default)]
    pub dns_name: String,
    #[serde(rename = "TailscaleIPs", default, deserialize_with = "or_none")]
    pub ips: Vec<String>,
    #[serde(rename = "CurAddr", default)]
    pub cur_addr: String,
    /// Whose it is, as Tailscale numbers its users; a tagged machine is nobody's.
    #[serde(rename = "UserID", default)]
    pub user: i64,
    #[serde(rename = "Tags", default)]
    pub tags: Option<Vec<String>>,
    #[serde(rename = "Online", default)]
    pub online: bool,
}

/// This machine's user's other machines that are online, by name and address: the ones a key of that user's
/// may be kept on. None of them where this machine is tagged (it is then nobody's).
pub fn own_machines(status: &Status) -> Vec<(String, Ipv4Addr)> {
    let tagged = |node: &Node| node.tags.as_ref().is_some_and(|tags| !tags.is_empty());
    if status.this.user == 0 || tagged(&status.this) { return Vec::new(); }
    let mut found: Vec<(String, Ipv4Addr)> = status.peers.values()
        .filter(|p| p.online && p.user == status.this.user && !tagged(p))
        .filter_map(|p| Some((p.dns_name.trim_end_matches('.').to_string(), p.ips.iter().find_map(|a| a.parse().ok())?)))
        .filter(|(name, _)| !name.is_empty())
        .collect();
    found.sort();
    found
}

/// Whether `peer` asks this machine by itself which devices it signs for: it does where both are one user's, untagged.
pub fn asks_by_itself(status: &Status, peer: &Peer) -> bool {
    let tagged = |node: &Node| node.tags.as_ref().is_some_and(|tags| !tags.is_empty());
    status.this.user != 0 && !tagged(&status.this)
        && status.peers.values().any(|node| node.id == peer.id && node.user == status.this.user && !tagged(node))
}

/// A peer by its Tailscale name.
pub struct Peer {
    /// Tailscale's lasting id for it; empty when it was given by address.
    pub id: String,
    pub ip: Ipv4Addr,
    pub dns: String,
    /// Its address on this LAN when Tailscale talks to it directly there; None when relayed or IPv6.
    pub lan: Option<Ipv4Addr>,
}

impl Peer {
    /// Still the machine `earlier` was: an address can pass to another while this waits.
    pub fn is(&self, earlier: &Peer) -> bool {
        !self.id.is_empty() && self.id == earlier.id && self.ip == earlier.ip
    }
}

/// The first label of a Tailscale DNS name.
pub fn short(dns: &str) -> &str {
    dns.split('.').next().unwrap_or(dns)
}

/// The CLI: `tailscale` in PATH, else where the App Store app (macOS) or the installer (Windows) puts it.
fn exe() -> std::path::PathBuf {
    let mut candidates = vec![std::path::PathBuf::from("tailscale")];
    if cfg!(target_os = "macos") {
        candidates.extend(["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"].map(Into::into));
    }
    if let Some(programs) = std::env::var_os("ProgramFiles").filter(|_| cfg!(windows)) {
        candidates.push(std::path::Path::new(&programs).join("Tailscale").join("tailscale.exe"));
    }
    let in_path = |p: &std::path::Path| std::env::var_os("PATH").is_some_and(|v| std::env::split_paths(&v).any(|d| d.join(p).is_file()));
    candidates.iter().find(|p| p.is_absolute() && p.exists() || in_path(p)).cloned().unwrap_or_else(|| candidates[0].clone())
}

fn run(args: &[&str]) -> Result<String, String> {
    // Not handed what opens a pairing: it has no use for it.
    let out = Command::new(exe()).args(args).env_remove("ROAMRUNCTL_PASSPHRASE").output().map_err(|e| format!("tailscale isn't installed here ({e})"))?;
    if !out.status.success() {
        return Err(format!("tailscale {}: {}", args[0], String::from_utf8_lossy(&out.stderr).trim()));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// The same, given `within` to answer: what waits on it (a request) isn't held by a Tailscale that hangs.
fn run_within(args: &[&str], within: Duration) -> Result<String, String> {
    let mut child = Command::new(exe()).args(args).env_remove("ROAMRUNCTL_PASSPHRASE").stdout(Stdio::piped()).stderr(Stdio::piped())
        .spawn().map_err(|e| format!("tailscale isn't installed here ({e})"))?;
    let read = |mut from: Box<dyn Read + Send>| std::thread::spawn(move || { let mut out = String::new(); let _ = from.read_to_string(&mut out); out });
    let reading = read(Box::new(child.stdout.take().ok_or("tailscale gave no output")?));
    let said = read(Box::new(child.stderr.take().ok_or("tailscale gave no output")?));
    let until = Instant::now() + within;
    loop {
        if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
            let out = reading.join().unwrap_or_default();
            let said = said.join().unwrap_or_default();
            return if status.success() { Ok(out) } else { Err(format!("tailscale {}: {}", args[0], said.trim())) };
        }
        if Instant::now() >= until {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("tailscale {} didn't answer in {} s", args[0], within.as_secs()));
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Who is at a tailnet address, as `tailscale whois --json` says: what `mcp --http` lets a caller in by.
#[derive(Deserialize, Default)]
pub struct Whois {
    #[serde(rename = "Node", default)]
    pub node: WhoisNode,
    #[serde(rename = "UserProfile", default)]
    pub user: WhoisUser,
}

#[derive(Deserialize, Default)]
pub struct WhoisNode {
    /// What `Status`'s nodes call `ID`.
    #[serde(rename = "StableID", default)]
    pub id: String,
    #[serde(rename = "Tags", default)]
    pub tags: Option<Vec<String>>,
    /// Set on a machine shared into this tailnet from another: the user who shared it.
    #[serde(rename = "Sharer", default)]
    pub sharer: i64,
}

#[derive(Deserialize, Default)]
pub struct WhoisUser {
    #[serde(rename = "LoginName", default)]
    pub login: String,
}

/// Who is at `ip`, with five seconds for Tailscale to say.
pub fn whois(ip: IpAddr) -> Result<Whois, String> {
    let out = run_within(&["whois", "--json", &ip.to_string()], Duration::from_secs(5))?;
    serde_json::from_str(&out).map_err(|e| format!("tailscale whois wasn't readable ({e})"))
}

/// With ten seconds to answer: a listener asks it for each connection, and a signature for each one made.
pub fn status() -> Result<Status, String> {
    status_from(&run_within(&["status", "--json"], Duration::from_secs(10))?)
}

/// Its state read first: signed out or stopped, the rest of it may be anything (Self too).
fn status_from(out: &str) -> Result<Status, String> {
    #[derive(Deserialize)]
    struct State { #[serde(rename = "BackendState", default)] backend_state: String }
    if let Some(problem) = serde_json::from_str::<State>(out).ok().and_then(|s| state_problem(&s.backend_state)) {
        return Err(problem);
    }
    serde_json::from_str(out).map_err(|e| format!("tailscale status wasn't readable ({e})"))
}

/// None while Tailscale is up (or too old to say); else what to do.
pub fn state_problem(state: &str) -> Option<String> {
    match state {
        "" | "Running" => None,
        "NeedsLogin" => Some("Tailscale here isn't signed in: `tailscale up`".into()),
        "Stopped" => Some("Tailscale here is disconnected: `tailscale up`".into()),
        other => Some(format!("Tailscale here isn't ready ({other})")),
    }
}

/// The peer a person means by `name`: its whole Tailscale name, or the first label of one in this
/// tailnet. Never the name a device gives itself, and never a guess between two (as RoamRun does).
pub fn peer(status: &Status, name: &str) -> Result<Peer, String> {
    let (node, mut peer) = found(status, name)?;
    peer.lan = if node.cur_addr.is_empty() {
        // Nothing talked to it lately: a ping says which way packets go.
        let pong = run(&["ping", "-c", "3", "--timeout", "3s", "--until-direct=false", &peer.ip.to_string()]).unwrap_or_default();
        pinged(&pong)
    } else {
        direct(&node.cur_addr)
    };
    Ok(peer)
}

/// The same, where only who it is matters: nothing is asked of the network for where it is.
pub fn known(status: &Status, name: &str) -> Result<Peer, String> {
    found(status, name).map(|(_, peer)| peer)
}

fn found<'a>(status: &'a Status, name: &str) -> Result<(&'a Node, Peer), String> {
    let want = name.trim_end_matches('.').to_lowercase();
    // An older Tailscale doesn't say its tailnet's suffix: this machine's own name has it.
    let own = status.this.dns_name.trim_end_matches('.').split_once('.').map_or("", |(_, rest)| rest);
    let suffix = status.tailnet.as_ref().map(|t| t.suffix.trim_matches('.')).filter(|s| !s.is_empty()).unwrap_or(own).to_lowercase();
    let mut found: Vec<&Node> = status
        .peers
        .values()
        .filter(|p| {
            let dns = p.dns_name.trim_end_matches('.').to_lowercase();
            !dns.is_empty() && (want == dns || !suffix.is_empty() && dns == format!("{want}.{suffix}"))
        })
        .collect();
    let node = match found.len() {
        0 => return Err(format!("no peer named {name} on this tailnet (its Tailscale name, as `tailscale status` lists it)")),
        1 => found.remove(0),
        _ => {
            let mut names: Vec<&str> = found.iter().map(|p| p.dns_name.trim_end_matches('.')).collect();
            names.sort();
            return Err(format!("{name} is more than one peer: {}", names.join(", ")));
        }
    };
    let ip = node
        .ips
        .iter()
        .find_map(|a| a.parse::<Ipv4Addr>().ok())
        .ok_or(format!("{name} has no IPv4 address on the tailnet"))?;
    let dns = node.dns_name.trim_end_matches('.').to_string();
    Ok((node, Peer { id: node.id.clone(), ip, dns, lan: None }))
}

/// The host of a direct "ip:port" endpoint; None for IPv6.
pub fn direct(endpoint: &str) -> Option<Ipv4Addr> {
    match endpoint.parse::<SocketAddr>().ok()? {
        SocketAddr::V4(a) => Some(*a.ip()),
        SocketAddr::V6(_) => None,
    }
}

/// The direct endpoint a `tailscale ping` reports ("via 192.168.0.19:41641 in 3ms"); None via DERP or IPv6.
pub fn pinged(output: &str) -> Option<Ipv4Addr> {
    output.lines().find_map(|line| {
        let via = line.split(" via ").nth(1)?.split_whitespace().next()?;
        direct(via)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_this_users_own_machines_that_are_online_are_asked() {
        let status = |me: &str| -> Status { serde_json::from_str(&format!(r#"{{"Self":{{"ID":"me","DNSName":"box.tail.ts.net.","TailscaleIPs":["100.64.0.1"],"UserID":7{me}}},"Peer":{{
            "a":{{"ID":"a","DNSName":"laptop.tail.ts.net.","TailscaleIPs":["100.64.0.2","fd7a::2"],"UserID":7,"Online":true}},
            "b":{{"ID":"b","DNSName":"asleep.tail.ts.net.","TailscaleIPs":["100.64.0.3"],"UserID":7,"Online":false}},
            "c":{{"ID":"c","DNSName":"theirs.tail.ts.net.","TailscaleIPs":["100.64.0.4"],"UserID":8,"Online":true}},
            "d":{{"ID":"d","DNSName":"ci.tail.ts.net.","TailscaleIPs":["100.64.0.5"],"UserID":7,"Online":true,"Tags":["tag:ci"]}}}}}}"#)).unwrap() };
        assert_eq!(own_machines(&status("")), [("laptop.tail.ts.net".to_string(), Ipv4Addr::new(100, 64, 0, 2))]);
        // A tagged machine is nobody's: it asks none (one is named for it instead).
        assert!(own_machines(&status(r#","Tags":["tag:ci"]"#)).is_empty());
    }

    #[test]
    fn ping_output() {
        let ok = "pong from iphone (100.64.0.9) via 192.168.0.19:41641 in 3ms\n";
        assert_eq!(pinged(ok), Some(Ipv4Addr::new(192, 168, 0, 19)));
        assert_eq!(pinged("pong from iphone (100.64.0.9) via DERP(tok) in 20ms\n"), None);
        assert_eq!(pinged("pong from iphone (100.64.0.9) via [fe80::1]:41641 in 3ms\n"), None);
        assert_eq!(pinged("no reply\n"), None);
        assert_eq!(pinged(""), None);
        let late = "pong from iphone (100.64.0.9) via DERP(tok) in 20ms\npong from iphone (100.64.0.9) via 192.168.0.19:41641 in 3ms\n";
        assert_eq!(pinged(late), Some(Ipv4Addr::new(192, 168, 0, 19)));
    }

    #[test]
    fn cur_addr() {
        assert_eq!(direct("192.168.0.19:41641"), Some(Ipv4Addr::new(192, 168, 0, 19)));
        assert_eq!(direct("[fe80::1]:41641"), None);
        assert_eq!(direct(""), None);
        assert_eq!(direct("192.168.0.19"), None);
    }

    #[test]
    fn peers_by_their_tailscale_name() {
        let json = r#"{"Self":{"DNSName":"me.tail.ts.net.","HostName":"me","TailscaleIPs":["100.64.0.1"]},
            "CurrentTailnet":{"MagicDNSSuffix":"tail.ts.net"},
            "Peer":{"shared":{"DNSName":"iphone-15.other.ts.net.","HostName":"iPhone 15","TailscaleIPs":["100.64.0.7"]},
                "same":{"ID":"n2","DNSName":"iphone-15-1.tail.ts.net.","HostName":"iPhone 15","TailscaleIPs":["100.64.0.8"]},"k":{"ID":"n1","DNSName":"iPhone-15.tail.ts.net.","HostName":"iPhone 15","TailscaleIPs":["fd7a::1","100.64.0.9"],"CurAddr":"192.168.0.19:41641"}}}"#;
        let st: Status = serde_json::from_str(json).unwrap();
        // `known`, but for the one whose LAN address is looked at: `peer` pings those nothing talked to lately.
        let peer = known;
        for name in ["iphone-15", "iPhone-15.tail.ts.net", "iphone-15.tail.ts.net."] {
            let p = super::peer(&st, name).unwrap();
            assert_eq!((p.ip, p.dns.as_str(), p.lan), (Ipv4Addr::new(100, 64, 0, 9), "iPhone-15.tail.ts.net", Some(Ipv4Addr::new(192, 168, 0, 19))));
        }
        assert!(peer(&st, "nobody").is_err());
        // What a device calls itself is anyone's to choose, and two here choose the same.
        assert!(peer(&st, "iphone 15").is_err());
        assert_eq!(peer(&st, "iphone-15.other.ts.net").unwrap().ip, Ipv4Addr::new(100, 64, 0, 7));
        // The same machine later: its id and its address both, and an id there is.
        let (was, other) = (peer(&st, "iphone-15").unwrap(), peer(&st, "iphone-15-1").unwrap());
        assert!(peer(&st, "iphone-15").unwrap().is(&was));
        assert!(!other.is(&was));
        assert!(!Peer { id: "n2".into(), ..peer(&st, "iphone-15").unwrap() }.is(&was));
        assert!(!Peer { ip: other.ip, ..peer(&st, "iphone-15").unwrap() }.is(&was));
        // Without the tailnet's suffix said, this machine's own name gives it.
        let old: Status = serde_json::from_str(&json.replace(r#""CurrentTailnet":{"MagicDNSSuffix":"tail.ts.net"},"#, "")).unwrap();
        assert_eq!(peer(&old, "iphone-15").unwrap().ip, Ipv4Addr::new(100, 64, 0, 9));
        let unnamed = peer(&st, "iphone-15.other.ts.net").unwrap();
        assert!(!unnamed.is(&unnamed));
        assert_eq!(short(&st.this.dns_name), "me");
        assert!(status_from(&json).is_ok());   // a Tailscale too old to say its state is taken as up
    }

    /// Signed out or stopped, Tailscale writes what it has none of as null: said as what to do, not as unreadable.
    #[test]
    fn a_status_with_nothing_in_it_is_read() {
        let signed_out = r#"{"BackendState":"NeedsLogin","Self":{"ID":"","TailscaleIPs":null},"Peer":null}"#;
        assert!(status_from(signed_out).err().is_some_and(|e| e.contains("signed in")));
        // Read before the rest, which may then be missing too.
        assert!(status_from(r#"{"BackendState":"NeedsLogin","Peer":null}"#).err().is_some_and(|e| e.contains("signed in")));
        let alone = r#"{"BackendState":"Running","Self":{"ID":"n1","DNSName":"pc.example.ts.net.","TailscaleIPs":["100.64.0.2"]},"Peer":null}"#;
        let addressless = r#"{"BackendState":"Running","Self":{"ID":"n1","TailscaleIPs":["100.64.0.2"]},"Peer":{"k":{"ID":"n2","TailscaleIPs":null}}}"#;
        assert!(status_from(addressless).is_ok_and(|s| s.peers["k"].ips.is_empty()));
        assert!(status_from(alone).is_ok_and(|s| s.peers.is_empty() && s.this.ips.len() == 1));
        assert!(status_from("not json").err().is_some_and(|e| e.contains("wasn't readable")));
    }

    #[test]
    fn backend_states() {
        assert_eq!(state_problem("Running"), None);
        assert_eq!(state_problem(""), None);
        assert!(state_problem("NeedsLogin").unwrap().contains("signed in"));
        assert!(state_problem("Stopped").unwrap().contains("disconnected"));
        assert!(state_problem("Starting").unwrap().contains("Starting"));
    }
}
