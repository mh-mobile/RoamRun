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
}

#[derive(Deserialize)]
pub struct Node {
    #[serde(rename = "DNSName", default)]
    pub dns_name: String,
    #[serde(rename = "HostName", default)]
    pub host_name: String,
    #[serde(rename = "TailscaleIPs", default)]
    pub ips: Vec<String>,
    #[serde(rename = "CurAddr", default)]
    pub cur_addr: String,
}

/// A peer by its Tailscale name.
pub struct Peer {
    pub ip: Ipv4Addr,
    pub dns: String,
    /// Its address on this LAN when Tailscale talks to it directly there; None when relayed or IPv6.
    pub lan: Option<Ipv4Addr>,
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
    let out = Command::new(exe()).args(args).output().map_err(|e| format!("tailscale isn't installed here ({e})"))?;
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

pub fn peer(status: &Status, name: &str) -> Result<Peer, String> {
    let want = name.trim_end_matches('.').to_lowercase();
    let node = status
        .peers
        .values()
        .find(|p| {
            let dns = p.dns_name.trim_end_matches('.').to_lowercase();
            want == dns || want == short(&dns) || want == p.host_name.to_lowercase()
        })
        .ok_or(format!("no peer named {name} on this tailnet"))?;
    let ip = node
        .ips
        .iter()
        .find_map(|a| a.parse::<Ipv4Addr>().ok())
        .ok_or(format!("{name} has no IPv4 address on the tailnet"))?;
    let dns = node.dns_name.trim_end_matches('.').to_string();
    let lan = if node.cur_addr.is_empty() {
        // Nothing talked to it lately: a ping says which way packets go.
        let pong = run(&["ping", "-c", "3", "--timeout", "3s", "--until-direct=false", &ip.to_string()]).unwrap_or_default();
        pinged(&pong)
    } else {
        direct(&node.cur_addr)
    };
    Ok(Peer { ip, dns, lan })
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
    fn peers_by_any_name() {
        let json = r#"{"Self":{"DNSName":"me.tail.ts.net.","HostName":"me","TailscaleIPs":["100.64.0.1"]},
            "Peer":{"k":{"DNSName":"iPhone-15.tail.ts.net.","HostName":"iPhone 15","TailscaleIPs":["fd7a::1","100.64.0.9"],"CurAddr":"192.168.0.19:41641"}}}"#;
        let st: Status = serde_json::from_str(json).unwrap();
        for name in ["iphone-15", "iPhone-15.tail.ts.net", "iphone 15"] {
            let p = peer(&st, name).unwrap();
            assert_eq!((p.ip, p.dns.as_str(), p.lan), (Ipv4Addr::new(100, 64, 0, 9), "iPhone-15.tail.ts.net", Some(Ipv4Addr::new(192, 168, 0, 19))));
        }
        assert!(peer(&st, "nobody").is_err());
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
