//! The two lines a person carries between Macs, as `Introductions.swift` reads and writes them.

use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::collections::BTreeMap;

pub const OFFER_PREFIX: &str = "rr-xcode-offer-v1:";
pub const DEVICE_PREFIX: &str = "rr-device-v1:";
pub const OFFER_KEYS: [&str; 7] = ["identifier", "authTag", "model", "name", "flags", "ver", "minVer"];
pub const DEVICE_KEYS: [&str; 5] = ["identifier", "authTag", "flags", "ver", "minVer"];
const MAX_LINE: usize = 4096;

/// A Mac's offer to pair, as Xcode announces it. Fields in key order: the Swift side encodes sorted keys.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Offer {
    pub port: u16,
    pub txt: BTreeMap<String, String>,
    pub v: i64,
}

/// A device without its UDID or any key: what a bridge announces for it, and its Tailscale name.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Device {
    pub name: String,
    pub peer: String,
    pub port: u16,
    pub txt: BTreeMap<String, String>,
    pub v: i64,
}

#[cfg(test)]
pub fn offer_line(offer: &Offer) -> String {
    format!("{OFFER_PREFIX}{}", packed(offer))
}

pub fn device_line(device: &Device) -> String {
    format!("{DEVICE_PREFIX}{}", packed(device))
}

/// The offer a line holds, or why it isn't one.
pub fn offer(line: &str) -> Result<Offer, String> {
    let line = line.trim();
    if line.starts_with(DEVICE_PREFIX) {
        return Err("that is a saved device's line (for `roamrun devices add`), not a Mac's offer".into());
    }
    let offer: Offer = line
        .strip_prefix(OFFER_PREFIX)
        .and_then(unpacked)
        .filter(|o: &Offer| o.v == 1)
        .ok_or("not an offer line (from `roamrun pair xcode`)")?;
    if offer.port < 1024 {
        return Err(format!("port {} isn't one a pairing listens on", offer.port));
    }
    if let Some(problem) = txt_problem(&offer.txt, &OFFER_KEYS) {
        return Err(problem);
    }
    Ok(offer)
}

/// The device a line holds, or why the far Mac's `roamrun devices add` would refuse it.
pub fn device(line: &str) -> Result<Device, String> {
    let line = line.trim();
    if line.starts_with(OFFER_PREFIX) {
        return Err("that is a Mac's offer to pair (for `roamrun pair introduce`), not a device's line".into());
    }
    let device: Device = line
        .strip_prefix(DEVICE_PREFIX)
        .and_then(unpacked)
        .filter(|d: &Device| d.v == 1)
        .ok_or("not a device line")?;
    if device.port < 1024 {
        return Err(format!("port {} isn't one a pairing listens on", device.port));
    }
    if let Some(problem) = txt_problem(&device.txt, &DEVICE_KEYS) {
        return Err(problem);
    }
    if let Some(problem) = name_problem(&device.name) {
        return Err(format!("its name: {problem}"));
    }
    let peer = device.peer.to_lowercase();
    if !(1..=253).contains(&peer.len()) || peer.starts_with(['-', '.']) || !peer.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'.') {
        return Err("its Tailscale name isn't one".into());
    }
    Ok(device)
}

/// Why a name can't be saved on a Mac (`nameProblem` in Models.swift, and the line's own bounds).
pub fn name_problem(name: &str) -> Option<String> {
    let n = name.trim();
    if n.is_empty() {
        return Some("Enter a name.".into());
    }
    if n.starts_with('-') {
        return Some("A name can't start with “-” (the CLI would read it as an option).".into());
    }
    if n.chars().any(char::is_control) {
        return Some("A name can't contain control characters.".into());
    }
    (n.len() > 64 || !shows(n)).then(|| "A name can't be shown as it is.".into())
}

/// Exactly the keys given, each a value of its kind.
pub fn txt_problem(txt: &BTreeMap<String, String>, keys: &[&str]) -> Option<String> {
    let missing: Vec<&str> = keys.iter().copied().filter(|k| !txt.contains_key(*k)).collect();
    let extra = txt.keys().filter(|k| !keys.contains(&k.as_str())).count();
    if !missing.is_empty() || extra > 0 {
        let mut why = String::from("its announcement isn't the kind this RoamRun knows");
        if !missing.is_empty() {
            why += &format!(" (missing: {})", missing.join(", "));
        }
        if extra > 0 {
            why += &format!(" (not known: {extra})");
        }
        return Some(why);
    }
    for (key, value) in txt {
        let len = value.len();
        let ok = match key.as_str() {
            "identifier" => is_uuid(value),
            "authTag" => (1..=32).contains(&len) && value.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/'),
            "model" => (1..=40).contains(&len) && value.bytes().all(|b| b.is_ascii_alphanumeric() || b",._-".contains(&b)),
            "name" => (1..=63).contains(&len) && name_shows(value),
            _ => (1..=6).contains(&len) && value.bytes().all(|b| b.is_ascii_digit()),
        };
        if !ok {
            return Some(format!("its announcement's {key} isn't one"));
        }
    }
    None
}

/// The far Mac's Tailscale name as the device is to show it: its first label, cut to 63 bytes
/// between characters; None when what is left can't be an offer's name.
pub fn announced_name(tailscale_name: &str) -> Option<String> {
    let label = tailscale_name.split('.').next().unwrap_or("");
    let mut end = label.len().min(63);
    while !label.is_char_boundary(end) {
        end -= 1;
    }
    let name = &label[..end];
    (!name.is_empty() && name_shows(name)).then(|| name.to_string())
}

fn name_shows(value: &str) -> bool {
    shows(value) && !value.contains('=') && !value.contains('\\')
}

/// Whether text reads on a screen as what it is: no control or format characters, no line or
/// paragraph separators, nothing private-use. (Unassigned code points aren't told apart here:
/// std has no category tables.)
pub fn shows(text: &str) -> bool {
    text.chars().all(|c| {
        let u = c as u32;
        !(c.is_control()
            || matches!(u, 0x2028 | 0x2029)
            || matches!(u, 0xE000..=0xF8FF | 0xF0000..=0xFFFFD | 0x100000..=0x10FFFD)
            || is_format(u))
    })
}

/// Unicode general category Cf, as of Unicode 16.
fn is_format(u: u32) -> bool {
    matches!(
        u,
        0xAD | 0x600..=0x605 | 0x61C | 0x6DD | 0x70F | 0x890..=0x891 | 0x8E2 | 0x180E | 0x200B..=0x200F
            | 0x202A..=0x202E | 0x2060..=0x2064 | 0x2066..=0x206F | 0xFEFF | 0xFFF9..=0xFFFB | 0x110BD | 0x110CD
            | 0x13430..=0x1343F | 0x1BCA0..=0x1BCA3 | 0x1D173..=0x1D17A | 0xE0001 | 0xE0020..=0xE007F
    )
}

fn is_uuid(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 36
        && b.iter().enumerate().all(|(i, c)| match i {
            8 | 13 | 18 | 23 => *c == b'-',
            _ => c.is_ascii_hexdigit(),
        })
}

fn packed<T: Serialize>(value: &T) -> String {
    let json = serde_json::to_vec(value).unwrap_or_default();
    STANDARD.encode(json).replace('+', "-").replace('/', "_").replace('=', "")
}

fn unpacked<T: DeserializeOwned>(text: &str) -> Option<T> {
    if text.len() > MAX_LINE {
        return None;
    }
    let mut b64 = text.replace('-', "+").replace('_', "/");
    b64 += &"=".repeat((4 - b64.len() % 4) % 4);
    serde_json::from_slice(&STANDARD.decode(b64).ok()?).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn txt() -> BTreeMap<String, String> {
        [
            ("identifier", "6B29FC40-CA47-1067-B31D-00DD010662DA"),
            ("authTag", "dGVzdA+/"),
            ("model", "Mac16,1"),
            ("name", "Fake Offer Name"),
            ("flags", "1"),
            ("ver", "2"),
            ("minVer", "1"),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
    }

    fn sample() -> Offer {
        Offer { port: 53050, txt: txt(), v: 1 }
    }

    fn with(key: &str, value: &str) -> String {
        let mut o = sample();
        o.txt.insert(key.into(), value.into());
        offer_line(&o)
    }

    #[test]
    fn offer_round_trips() {
        let line = offer_line(&sample());
        assert!(line.starts_with(OFFER_PREFIX));
        assert!(!line.contains(['+', '/', '=']));
        assert_eq!(offer(&format!("  {line}\n")).unwrap(), sample());
    }

    #[test]
    fn keys_come_sorted_and_compact() {
        let device = Device {
            name: "iPhone".into(),
            peer: "iphone".into(),
            port: 49152,
            txt: [("identifier", "x"), ("authTag", "y")].into_iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
            v: 1,
        };
        let json = String::from_utf8(serde_json::to_vec(&device).unwrap()).unwrap();
        assert_eq!(json, r#"{"name":"iPhone","peer":"iphone","port":49152,"txt":{"authTag":"y","identifier":"x"},"v":1}"#);
        assert_eq!(serde_json::to_string(&sample()).unwrap().find("\"port\""), Some(1));
        assert!(device_line(&device).starts_with(DEVICE_PREFIX));
    }

    #[test]
    fn other_lines_are_named() {
        assert!(offer("rr-device-v1:e30").unwrap_err().contains("saved device"));
        assert!(offer("hello").unwrap_err().contains("not an offer"));
        assert!(offer("rr-xcode-offer-v1:!!!").unwrap_err().contains("not an offer"));
        assert!(offer(&format!("{OFFER_PREFIX}{}", "A".repeat(4097))).unwrap_err().contains("not an offer"));
        let v2 = Offer { v: 2, ..sample() };
        assert!(offer(&offer_line(&v2)).unwrap_err().contains("not an offer"));
    }

    #[test]
    fn refused_values() {
        let low = Offer { port: 1023, ..sample() };
        assert_eq!(offer(&offer_line(&low)).unwrap_err(), "port 1023 isn't one a pairing listens on");
        let mut missing = sample();
        missing.txt.remove("model");
        assert_eq!(
            offer(&offer_line(&missing)).unwrap_err(),
            "its announcement isn't the kind this RoamRun knows (missing: model)"
        );
        assert!(offer(&with("extra", "1")).unwrap_err().ends_with("(not known: 1)"));
        for (key, bad) in [
            ("identifier", "6B29FC40-CA47-1067-B31D-00DD010662D"),
            ("identifier", "6B29FC40-CA47-1067-B31D-00DD010662DG"),
            ("authTag", ""),
            ("authTag", "a=b"),
            ("authTag", &"a".repeat(33)),
            ("model", "Mac 16"),
            ("model", &"a".repeat(41)),
            ("name", ""),
            ("name", "a=b"),
            ("name", "a\\b"),
            ("name", "a\tb"),
            ("name", "a\u{200E}b"),
            ("name", "a\u{2028}b"),
            ("name", "a\u{E000}b"),
            ("name", &"é".repeat(32)),
            ("flags", ""),
            ("flags", "1234567"),
            ("ver", "1a"),
            ("minVer", "-1"),
        ] {
            assert_eq!(offer(&with(key, bad)).unwrap_err(), format!("its announcement's {key} isn't one"), "{key}={bad:?}");
        }
        assert!(offer(&with("name", "Mac mini (日本語)")).is_ok());
        assert!(offer(&with("name", &"é".repeat(31))).is_ok());
    }

    #[test]
    fn device_lines() {
        let txt = |tag: &str| [("identifier", "6B29FC40-CA47-1067-B31D-00DD010662DA"), ("authTag", tag), ("flags", "1"), ("ver", "2"), ("minVer", "1")]
            .into_iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        let ok = Device { name: "iPhone".into(), peer: "iphone-15".into(), port: 49152, txt: txt("ZmFrZQ"), v: 1 };
        assert_eq!(device(&device_line(&ok)).unwrap(), ok);
        assert!(device(&offer_line(&sample())).unwrap_err().contains("offer"));
        assert!(device("hello").unwrap_err().contains("not a device"));
        for (bad, why) in [
            (Device { port: 80, ..ok.clone() }, "port 80"),
            (Device { txt: txt(""), ..ok.clone() }, "authTag"),
            (Device { name: " ".into(), ..ok.clone() }, "Enter a name"),
            (Device { name: "-iPhone".into(), ..ok.clone() }, "start with"),
            (Device { name: "a\tb".into(), ..ok.clone() }, "control"),
            (Device { name: "é".repeat(33), ..ok.clone() }, "shown"),
            (Device { name: "a\u{200E}b".into(), ..ok.clone() }, "shown"),
            (Device { peer: "-x".into(), ..ok.clone() }, "Tailscale name"),
            (Device { peer: "a b".into(), ..ok.clone() }, "Tailscale name"),
            (Device { peer: String::new(), ..ok.clone() }, "Tailscale name"),
        ] {
            assert!(device(&device_line(&bad)).unwrap_err().contains(why), "{bad:?}");
        }
        assert_eq!(name_problem("  iPhone  "), None);
        assert_eq!(name_problem(&"a".repeat(64)), None);
        assert!(name_problem(&"a".repeat(65)).is_some());
    }

    #[test]
    fn announced_names() {
        assert_eq!(announced_name("rr-cloud.tail1234.ts.net."), Some("rr-cloud".into()));
        assert_eq!(announced_name(&"a".repeat(70)), Some("a".repeat(63)));
        assert_eq!(announced_name(&"é".repeat(40)), Some("é".repeat(31)));
        assert_eq!(announced_name(""), None);
        assert_eq!(announced_name("a=b.ts.net"), None);
    }
}
