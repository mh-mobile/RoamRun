//! Who is where on the tailnet, from the installed `tailscale` CLI.

use serde::Deserialize;
use std::net::{Ipv4Addr, SocketAddr};
use std::process::Command;

#[derive(Deserialize)]
pub struct Status {
    #[serde(rename = "BackendState", default)]
    pub backend_state: String,
    #[serde(rename = "Self")]
    pub this: Node,
    #[serde(rename = "Peer", default)]
    pub peers: std::collections::HashMap<String, Node>,
    #[serde(rename = "CurrentTailnet", default)]
    tailnet: Option<Tailnet>,
}

#[derive(Deserialize)]
struct Tailnet {
    #[serde(rename = "MagicDNSSuffix", default)]
    suffix: String,
}

#[derive(Deserialize)]
pub struct Node {
    #[serde(rename = "ID", default)]
    id: String,
    #[serde(rename = "DNSName", default)]
    pub dns_name: String,
    #[serde(rename = "TailscaleIPs", default)]
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

pub fn status() -> Result<Status, String> {
    let status: Status = serde_json::from_str(&run(&["status", "--json"])?).map_err(|e| format!("tailscale status wasn't readable ({e})"))?;
    if let Some(problem) = state_problem(&status.backend_state) {
        return Err(problem);
    }
    Ok(status)
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
        for name in ["iphone-15", "iPhone-15.tail.ts.net", "iphone-15.tail.ts.net."] {
            let p = peer(&st, name).unwrap();
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
        assert_eq!(st.backend_state, "");
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
