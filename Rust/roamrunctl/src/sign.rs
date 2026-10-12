//! `roamrunctl sign <devices> --for <machine>`: the pairing's key stays here, and the machine named is given
//! the one signature each connection to a device takes. It can't copy the key; it connects for as long as this answers.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpListener, TcpStream};
use std::time::{Duration, Instant};

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use ed25519_dalek::{Signer, SigningKey};

use crate::tailscale;

pub const PORT: u16 = 41831;
const PREFIX: &str = "rr-sign-v1 ";
const LINE: Duration = Duration::from_secs(10);
/// A request at most: the prefix, a device's name, and what pair-verify signs.
const MAX: usize = 512;
/// An answer at most: the devices signed for, each without its key.
const MAX_ANSWER: usize = 256 * 1024;
/// Set to a machine's Tailscale name, only that machine is asked whether it signs for this one: for a
/// tagged machine, which has no user whose other machines could be asked.
pub const SIGNER: &str = "ROAMRUNCTL_SIGNER";

/// What pair-verify signs for the pairing `identifier`: a 32-byte key, the identifier, a 32-byte key.
/// Not what making a pairing signs, which has that shape and ends in the pairing's own public key: the key
/// isn't lent to pair another device as this machine. The two 32 bytes are otherwise whatever is sent.
pub fn fits(identifier: &str, own: &[u8; 32], what: &[u8]) -> bool {
    what.len() == 64 + identifier.len() && &what[32..32 + identifier.len()] == identifier.as_bytes() && what[what.len() - 32..] != own[..]
}

/// The pairings signed with, by the names their devices are saved under: pairings made on one machine
/// share an identifier, and each has a key of its own.
pub type Keys = HashMap<String, (String, SigningKey)>;
/// Said of a device that was signed for and isn't any more: removed here, or saved anew, since this began.
const CHANGED: &str = "changed";

/// Whether a device is still saved here as it was; and the devices signed for, those still held, as JSON.
pub type Held<'a> = &'a dyn Fn(&str) -> bool;
pub type Listed<'a> = &'a dyn Fn(Held) -> String;

/// One request's answer: the line to send back, and the device's name where it was signed for.
/// `list`: the devices signed for, each without its key, as the machine asking learns of them — those still held.
/// `held`: whether a device is saved here as it was when this began — one removed since, or saved anew under
/// its name, is signed for no more.
fn answer<'a>(line: &str, keys: &'a Keys, list: Listed, held: Held) -> (String, Option<&'a str>) {
    let refused = |why: &str| (format!("{PREFIX}refused {why}"), None);
    if line == format!("{PREFIX}devices?") { return (format!("{PREFIX}devices {}", list(held)), None); }
    let Some(["sign", name, what]) = line.strip_prefix(PREFIX).map(|words| words.split(' ').collect::<Vec<_>>()).as_deref().map(|w| <[&str; 3]>::try_from(w).ok()).unwrap_or(None) else {
        return refused("not-a-request");
    };
    let Some((name, (identifier, key))) = keys.get_key_value(name) else { return refused("no-such-pairing") };
    if !held(name) { return refused(CHANGED) }
    let Ok(what) = URL_SAFE_NO_PAD.decode(what) else { return refused("not-a-request") };
    if !fits(identifier, &key.verifying_key().to_bytes(), &what) { return refused("not-a-pairing-check"); }
    (format!("{PREFIX}signed {}", URL_SAFE_NO_PAD.encode(key.sign(&what).to_bytes())), Some(name))
}

/// A line, `most` bytes at most, all of it `within`: what trickles in is waited for no longer than that.
fn read_line(mut stream: &TcpStream, most: usize, within: Duration) -> Option<String> {
    let until = Instant::now() + within;
    let (mut line, mut some) = (Vec::new(), [0u8; 4096]);
    while !line.contains(&b'\n') {
        let left = until.checked_duration_since(Instant::now()).filter(|left| !left.is_zero())?;
        stream.set_read_timeout(Some(left)).ok()?;
        let read = stream.read(&mut some).ok().filter(|read| *read > 0)?;
        line.extend_from_slice(&some[..read]);
        if line.len() > most { return None }
    }
    line.truncate(line.iter().position(|b| *b == b'\n')?);
    String::from_utf8(line).ok().map(|line| line.trim_end().to_string())
}

/// `roamrunctl sign <devices> --for <machine>`: until Ctrl-C.
/// `list`: the devices signed for, each without its key (see `devices`).
pub fn serve(machine: &str, keys: Keys, list: Listed, held: Held) -> Result<String, String> {
    let status = tailscale::status()?;
    let own: Ipv4Addr = status.this.ips.iter().find_map(|a| a.parse().ok()).ok_or("this machine has no IPv4 address on the tailnet")?;
    let other = tailscale::known(&status, machine)?;
    if keys.is_empty() { return Err("no pairing with its key is saved here to sign with: `roamrunctl devices` lists what is".into()); }
    let listener = TcpListener::bind((own, PORT)).map_err(|e| match e.kind() {
        std::io::ErrorKind::AddrInUse => "another `roamrunctl sign` runs on this machine already".to_string(),
        std::io::ErrorKind::AddrNotAvailable => format!("can't listen on {own}: this machine's Tailscale gives it no address of its own to listen on (userspace networking?)"),
        _ => format!("can't listen on {own}: {e}"),
    })?;
    let mut names: Vec<&str> = keys.keys().map(String::as_str).collect();
    names.sort();
    note!("Signing for {machine}, and for it alone, with the pairing of: {}. Ctrl-C ends it: {machine} can then make no new connection to them — one it has open (a `roamrunctl mcp` running there) goes on until that ends.", names.join(", "));
    if tailscale::asks_by_itself(&status, &other) {
        note!("Nothing is to be done on {machine}: `roamrunctl devices` there lists them, and its commands ask here (TCP port {PORT}).");
    } else {
        note!("{machine} is tagged, or another user's: it doesn't ask by itself. There, set ROAMRUNCTL_SIGNER={} — then `roamrunctl devices` lists them, and its commands ask here (TCP port {PORT}).", tailscale::short(&status.this.dns_name));
    }
    for stream in listener.incoming() {
        let Ok(mut stream) = stream else { continue };
        let Ok(from) = stream.peer_addr() else { continue };
        // Whoever asks is held to being the machine named, by address and by Tailscale's own id for it.
        if from.ip() != std::net::IpAddr::V4(other.ip) { note!("Turned away {}: it isn't {machine}.", from.ip()); continue }
        if !tailscale::status().and_then(|now| tailscale::known(&now, machine)).is_ok_and(|now| now.is(&other)) {
            note!("Turned away a request: Tailscale couldn't say just then that it is {machine}.");
            continue;
        }
        let Some(line) = read_line(&stream, MAX, LINE) else { continue };
        let (said, name) = answer(&line, &keys, list, held);
        let _ = stream.set_write_timeout(Some(LINE));
        let _ = stream.write_all(format!("{said}\n").as_bytes());
        match name {
            Some(name) => note!("Signed one connection to {name} for {machine}."),
            None if said.starts_with(&format!("{PREFIX}devices ")) => {}
            None if said.ends_with(CHANGED) => note!("Refused a request of {machine}'s: that device was removed here, or saved anew, since this began. To sign for it again, end this and run it again."),
            None => note!("Refused a request of {machine}'s ({}).", said.trim_start_matches(PREFIX)),
        }
    }
    Ok(String::new())
}

/// Asks the machine that keeps the key for the signature a connection takes.
/// `name`: the device's, as that machine has it saved.
pub fn ask(signer: &str, name: &str, what: &[u8]) -> Result<[u8; 64], String> {
    let status = tailscale::status()?;
    let there = tailscale::known(&status, signer)?;
    let mut stream = TcpStream::connect_timeout(&SocketAddr::from((there.ip, PORT)), LINE)
        .map_err(|_| format!("it isn't answering (there: roamrunctl sign {name} --for {})", tailscale::short(&status.this.dns_name)))?;
    stream.write_all(format!("{PREFIX}sign {name} {}\n", URL_SAFE_NO_PAD.encode(what)).as_bytes()).map_err(|e| e.to_string())?;
    let line = read_line(&stream, MAX, LINE).ok_or("it gave no answer")?;
    match line.strip_prefix(PREFIX).map(|words| words.split(' ').collect::<Vec<_>>()).as_deref() {
        Some(["signed", signature]) => URL_SAFE_NO_PAD.decode(signature).ok().and_then(|bytes| bytes.try_into().ok()).ok_or("what it sent isn't a signature".to_string()),
        Some(["refused", CHANGED]) => Err(format!("it signs for {name} no more: it was removed there, or paired again, since its `roamrunctl sign` began. To use it again, that is ended and run again there")),
        Some(["refused", "no-such-pairing"]) => Err("it signs for no such device (removed there, or not named to its `roamrunctl sign`?)".into()),
        // Its word only where it is one of ours: what is shown here isn't whatever it sends.
        Some(["refused", why]) if ["not-a-request", "not-a-pairing-check"].contains(why) => Err(format!("it refused ({why})")),
        Some(["refused", _]) => Err("it refused".into()),
        _ => Err("it said something else".into()),
    }
}

/// What the machine at `ip` signs for this one, as it says it: None where it doesn't answer as one that does.
fn asked(ip: Ipv4Addr) -> Option<String> {
    let mut stream = TcpStream::connect_timeout(&SocketAddr::from((ip, PORT)), Duration::from_millis(800)).ok()?;
    stream.write_all(format!("{PREFIX}devices?\n").as_bytes()).ok()?;
    read_line(&stream, MAX_ANSWER, Duration::from_secs(3))?.strip_prefix(&format!("{PREFIX}devices ")).map(str::to_string)
}

/// The machines that sign for this one, each with what it says it signs for: this user's other machines
/// that answer so, asked together — or, where `ROAMRUNCTL_SIGNER` names one, that one alone.
pub fn signers(status: &tailscale::Status, named: Option<String>) -> Result<Vec<(String, String)>, String> {
    let machines = match named {
        Some(name) => { let peer = tailscale::known(status, &name).map_err(|why| format!("{SIGNER}: {why}"))?; vec![(peer.dns, peer.ip)] }
        None => tailscale::own_machines(status),
    };
    let asking: Vec<_> = machines.into_iter().map(|(name, ip)| std::thread::spawn(move || asked(ip).map(|list| (name, list)))).collect();
    Ok(asking.into_iter().filter_map(|answer| answer.join().ok().flatten()).collect())
}

/// A pairing's own identifier and its private key, from the property list a pairing is kept as.
pub fn key(pairing: &str) -> Option<(String, SigningKey)> {
    let list = plist::Value::from_reader_xml(pairing.as_bytes()).ok()?.into_dictionary()?;
    let private: [u8; 32] = list.get("private_key")?.as_data()?.try_into().ok()?;
    Some((list.get("identifier")?.as_string()?.to_string(), SigningKey::from_bytes(&private)))
}

/// The pairing without its private key: any key stands in its place (the library reads none as no pairing),
/// and what the device learned of this side at pairing alone (alt_irk) is left out.
pub fn without_key(pairing: &str) -> Result<(String, String), String> {
    let mut list = plist::Value::from_reader_xml(pairing.as_bytes()).ok().and_then(plist::Value::into_dictionary).ok_or("the pairing isn't one that can be read")?;
    let identifier = list.get("identifier").and_then(|i| i.as_string()).ok_or("the pairing names no identifier")?.to_string();
    list.insert("private_key".into(), plist::Value::Data(crate::hold::random::<32>()?.to_vec()));
    list.remove("alt_irk");
    let mut out = Vec::new();
    plist::Value::Dictionary(list).to_writer_xml(&mut out).map_err(|e| e.to_string())?;
    Ok((String::from_utf8(out).map_err(|e| e.to_string())?, identifier))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::Verifier;

    fn pairing(identifier: &str, key: &SigningKey) -> String {
        let mut list = plist::Dictionary::new();
        list.insert("identifier".into(), identifier.into());
        list.insert("private_key".into(), plist::Value::Data(key.to_bytes().to_vec()));
        list.insert("public_key".into(), plist::Value::Data(key.verifying_key().to_bytes().to_vec()));
        list.insert("alt_irk".into(), plist::Value::Data(vec![7; 16]));
        let mut out = Vec::new();
        plist::Value::Dictionary(list).to_writer_xml(&mut out).unwrap();
        String::from_utf8(out).unwrap()
    }

    #[test]
    fn only_what_a_pairing_check_signs_is_signed_and_only_for_a_pairing_held() {
        let key = SigningKey::from_bytes(&[9; 32]);
        let id = "0F0E0D0C-0B0A-4908-8706-050403020100";
        let other = SigningKey::from_bytes(&[5; 32]);
        // Two devices paired by one machine: one identifier, a key each.
        let keys: Keys = HashMap::from([("phone".to_string(), (id.to_string(), key.clone())), ("pad".to_string(), (id.to_string(), other.clone()))]);
        let held = |name: &str| name != "gone";
        let mut what = vec![1u8; 32];
        what.extend_from_slice(id.as_bytes());
        what.extend_from_slice(&[2u8; 32]);
        for (device, key) in [("phone", &key), ("pad", &other)] {
            let (said, name) = answer(&format!("{PREFIX}sign {device} {}", URL_SAFE_NO_PAD.encode(&what)), &keys, &|_| "[]".to_string(), &held);
            assert_eq!(name, Some(device));
            let signature: [u8; 64] = URL_SAFE_NO_PAD.decode(said.strip_prefix("rr-sign-v1 signed ").unwrap()).unwrap().try_into().unwrap();
            assert!(key.verifying_key().verify(&what, &ed25519_dalek::Signature::from_bytes(&signature)).is_ok(), "{device}");
        }
        // What making a pairing signs ends in the pairing's own public key: not signed.
        let mut making = what[..what.len() - 32].to_vec();
        making.extend_from_slice(&key.verifying_key().to_bytes());
        // Another pairing's identifier inside, another length, any other text: not signed.
        let mut changed = what.clone();
        changed[40] ^= 1;
        for (bad, why) in [
            (format!("{PREFIX}sign phone {}", URL_SAFE_NO_PAD.encode(&changed)), "not-a-pairing-check"),
            (format!("{PREFIX}sign phone {}", URL_SAFE_NO_PAD.encode(&what[1..])), "not-a-pairing-check"),
            (format!("{PREFIX}sign phone {}", URL_SAFE_NO_PAD.encode(b"sign this message for me, as it is")), "not-a-pairing-check"),
            (format!("{PREFIX}sign phone {}", URL_SAFE_NO_PAD.encode(&making)), "not-a-pairing-check"),
            (format!("{PREFIX}sign watch {}", URL_SAFE_NO_PAD.encode(&what)), "no-such-pairing"),
            (format!("{PREFIX}sign phone ***"), "not-a-request"),
            (format!("{PREFIX}give phone x"), "not-a-request"),
            ("rr-pair-v1 offer?".to_string(), "not-a-request"),
        ] {
            assert_eq!(answer(&bad, &keys, &|_| "[]".to_string(), &held), (format!("{PREFIX}refused {why}"), None), "{bad}");
        }
        // A device removed here since: signed for no more.
        let gone: Keys = HashMap::from([("gone".to_string(), (id.to_string(), key.clone()))]);
        assert_eq!(answer(&format!("{PREFIX}sign gone {}", URL_SAFE_NO_PAD.encode(&what)), &gone, &|_| "[]".to_string(), &held).0, "rr-sign-v1 refused changed");
        // What it signs for is said as it was given, and no key with it.
        assert_eq!(answer("rr-sign-v1 devices?", &keys, &|held| format!("[{}]", held("gone")), &held), ("rr-sign-v1 devices [false]".to_string(), None));
    }

    #[test]
    fn a_line_that_trickles_in_is_waited_for_no_longer_than_it_is_given() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let at = listener.local_addr().unwrap();
        let slow = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            for _ in 0..40 { if stream.write_all(b"x").is_err() { break } std::thread::sleep(Duration::from_millis(50)); }
        });
        let began = Instant::now();
        assert_eq!(read_line(&TcpStream::connect(at).unwrap(), 1024, Duration::from_millis(300)), None);
        assert!(began.elapsed() < Duration::from_millis(1500), "{:?}", began.elapsed());
        slow.join().unwrap();
        // One whole line is read, and no more than it.
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let at = listener.local_addr().unwrap();
        let quick = std::thread::spawn(move || { let _ = listener.accept().unwrap().0.write_all(b"one line\r\nand more"); });
        assert_eq!(read_line(&TcpStream::connect(at).unwrap(), 1024, Duration::from_secs(5)).as_deref(), Some("one line"));
        quick.join().unwrap();
    }

    #[test]
    fn a_pairing_without_its_key_keeps_who_it_is_and_not_the_key() {
        let key = SigningKey::from_bytes(&[9; 32]);
        let whole = pairing("0F0E0D0C-0B0A-4908-8706-050403020100", &key);
        assert_eq!(super::key(&whole).map(|(id, k)| (id, k.to_bytes())), Some(("0F0E0D0C-0B0A-4908-8706-050403020100".to_string(), [9; 32])));
        let (bare, identifier) = without_key(&whole).unwrap();
        assert_eq!(identifier, "0F0E0D0C-0B0A-4908-8706-050403020100");
        let read = plist::Value::from_reader_xml(bare.as_bytes()).unwrap().into_dictionary().unwrap();
        assert_ne!(read["private_key"].as_data().unwrap(), &[9u8; 32][..]);
        assert_eq!(read["public_key"].as_data().unwrap(), key.verifying_key().to_bytes());
        assert!(!read.contains_key("alt_irk"));
        // Another key each time: not one that could be mistaken for the pairing's.
        assert_ne!(without_key(&whole).unwrap().0, bare);
        assert!(without_key("not a pairing").is_err() && super::key("not a pairing").is_none());
    }
}
