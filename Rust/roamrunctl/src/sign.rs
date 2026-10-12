//! A pairing's private key kept on one machine and used from another: `roamrunctl sign --for <machine>`
//! runs where the key is, and signs the one thing a connection to the device has signed (pair-verify);
//! the machine that uses the device asks it at each connection, and never has the key.
//! What that keeps: the key from being copied off the machine that uses the device. Not: that
//! machine from connecting for as long as this answers it.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpListener, TcpStream};
use std::time::Duration;

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use ed25519_dalek::{Signer, SigningKey};

use crate::tailscale;

pub const PORT: u16 = 41831;
const PREFIX: &str = "rr-sign-v1 ";
const LINE: Duration = Duration::from_secs(10);
/// A line of ours at most: the prefix, an identifier, and what pair-verify signs.
const MAX: usize = 512;

/// What pair-verify signs for the pairing `identifier`: a 32-byte key, the identifier, a 32-byte key.
/// Nothing else is signed: the key isn't lent for whatever is sent.
pub fn fits(identifier: &str, what: &[u8]) -> bool {
    what.len() == 64 + identifier.len() && &what[32..32 + identifier.len()] == identifier.as_bytes()
}

/// One request's answer: the line to send back, and the device's name where it was signed for.
fn answer<'a>(line: &str, keys: &'a HashMap<String, (String, SigningKey)>) -> (String, Option<&'a str>) {
    let refused = |why: &str| (format!("{PREFIX}refused {why}"), None);
    let Some(["sign", identifier, what]) = line.strip_prefix(PREFIX).map(|words| words.split(' ').collect::<Vec<_>>()).as_deref().map(|w| <[&str; 3]>::try_from(w).ok()).unwrap_or(None) else {
        return refused("not-a-request");
    };
    let Some((name, key)) = keys.get(identifier) else { return refused("no-such-pairing") };
    let Ok(what) = URL_SAFE_NO_PAD.decode(what) else { return refused("not-a-request") };
    if !fits(identifier, &what) { return refused("not-a-pairing-check"); }
    (format!("{PREFIX}signed {}", URL_SAFE_NO_PAD.encode(key.sign(&what).to_bytes())), Some(name))
}

fn read_line(stream: &TcpStream) -> Option<String> {
    stream.set_read_timeout(Some(LINE)).ok()?;
    let mut line = String::new();
    // No more than a line of ours is read: what sends more isn't one of ours.
    BufReader::new(std::io::Read::take(stream, MAX as u64)).read_line(&mut line).ok()?;
    line.ends_with('\n').then(|| line.trim_end().to_string())
}

/// `roamrunctl sign --for <machine>`: until Ctrl-C.
pub fn serve(machine: &str, keys: HashMap<String, (String, SigningKey)>) -> Result<String, String> {
    let status = tailscale::status()?;
    let own: Ipv4Addr = status.this.ips.iter().find_map(|a| a.parse().ok()).ok_or("this machine has no IPv4 address on the tailnet")?;
    let other = tailscale::machine(&status, machine)?;
    if keys.is_empty() { return Err("no pairing with its key is saved here to sign with: `roamrunctl devices` lists what is".into()); }
    let listener = TcpListener::bind((own, PORT)).map_err(|e| if e.kind() == std::io::ErrorKind::AddrInUse { "another `roamrunctl sign` runs on this machine already".to_string() } else { format!("can't listen on {own}: {e}") })?;
    let mut names: Vec<&str> = keys.values().map(|(name, _)| name.as_str()).collect();
    names.sort();
    eprintln!("Signing for {machine}, and for it alone, with the pairing of: {}. Ctrl-C ends it: {machine} can then make no new connection to them.", names.join(", "));
    for stream in listener.incoming() {
        let Ok(mut stream) = stream else { continue };
        let Ok(from) = stream.peer_addr() else { continue };
        // Whoever asks is held to being the machine named, by address and by Tailscale's own id for it.
        if from.ip() != std::net::IpAddr::V4(other.ip) { eprintln!("Turned away {}: it isn't {machine}.", from.ip()); continue }
        if !tailscale::status().and_then(|now| tailscale::machine(&now, machine)).is_ok_and(|now| now.is(&other)) {
            eprintln!("Turned away a request: Tailscale couldn't say just then that it is {machine}.");
            continue;
        }
        let Some(line) = read_line(&stream) else { continue };
        let (said, name) = answer(&line, &keys);
        let _ = stream.write_all(format!("{said}\n").as_bytes());
        match name {
            Some(name) => eprintln!("Signed one connection to {name} for {machine}."),
            None => eprintln!("Refused a request of {machine}'s ({}).", said.trim_start_matches(PREFIX)),
        }
    }
    Ok(String::new())
}

/// Asks the machine that keeps the key for the signature a connection takes.
pub fn ask(signer: &str, identifier: &str, what: &[u8]) -> Result<[u8; 64], String> {
    let there = tailscale::status().and_then(|status| tailscale::machine(&status, signer))?;
    let mut stream = TcpStream::connect_timeout(&SocketAddr::from((there.ip, PORT)), LINE)
        .map_err(|_| "it isn't answering (there: roamrunctl sign --for <this machine>)".to_string())?;
    stream.write_all(format!("{PREFIX}sign {identifier} {}\n", URL_SAFE_NO_PAD.encode(what)).as_bytes()).map_err(|e| e.to_string())?;
    let line = read_line(&stream).ok_or("it gave no answer")?;
    match line.strip_prefix(PREFIX).map(|words| words.split(' ').collect::<Vec<_>>()).as_deref() {
        Some(["signed", signature]) => URL_SAFE_NO_PAD.decode(signature).ok().and_then(|bytes| bytes.try_into().ok()).ok_or("what it sent isn't a signature".to_string()),
        Some(["refused", "no-such-pairing"]) => Err("it has no such pairing (removed there?)".into()),
        Some(["refused", why]) => Err(format!("it refused ({why})")),
        _ => Err("it said something else".into()),
    }
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
        let keys = HashMap::from([(id.to_string(), ("phone".to_string(), key.clone()))]);
        let mut what = vec![1u8; 32];
        what.extend_from_slice(id.as_bytes());
        what.extend_from_slice(&[2u8; 32]);
        let (said, name) = answer(&format!("{PREFIX}sign {id} {}", URL_SAFE_NO_PAD.encode(&what)), &keys);
        assert_eq!(name, Some("phone"));
        let signature: [u8; 64] = URL_SAFE_NO_PAD.decode(said.strip_prefix("rr-sign-v1 signed ").unwrap()).unwrap().try_into().unwrap();
        assert!(key.verifying_key().verify(&what, &ed25519_dalek::Signature::from_bytes(&signature)).is_ok());
        // Another pairing's identifier inside, another length, any other text: not signed.
        let mut other = what.clone();
        other[40] ^= 1;
        for (bad, why) in [
            (format!("{PREFIX}sign {id} {}", URL_SAFE_NO_PAD.encode(&other)), "not-a-pairing-check"),
            (format!("{PREFIX}sign {id} {}", URL_SAFE_NO_PAD.encode(&what[1..])), "not-a-pairing-check"),
            (format!("{PREFIX}sign {id} {}", URL_SAFE_NO_PAD.encode(b"sign this message for me, as it is")), "not-a-pairing-check"),
            (format!("{PREFIX}sign 11111111-2222-4333-8444-555555555555 {}", URL_SAFE_NO_PAD.encode(&what)), "no-such-pairing"),
            (format!("{PREFIX}sign {id} ***"), "not-a-request"),
            (format!("{PREFIX}give {id} x"), "not-a-request"),
            ("rr-pair-v1 offer?".to_string(), "not-a-request"),
        ] {
            assert_eq!(answer(&bad, &keys), (format!("{PREFIX}refused {why}"), None), "{bad}");
        }
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
