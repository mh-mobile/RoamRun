//! The `rr-pair-v1` wire to the far Mac (port 41830), as `PairByName.swift` speaks it.

use std::io::{BufRead, BufReader, ErrorKind, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

pub const PORT: u16 = 41830;
/// `read`'s error when the far Mac closed without a word: transient while an offer is awaited.
pub const CLOSED: &str = "far Mac closed the connection";
const PREFIX: &str = "rr-pair-v1 ";
const MAX_LINE: usize = 4096;

pub struct Wire {
    reader: BufReader<TcpStream>,
}

impl Wire {
    /// Tries every two seconds until the far Mac listens, or `window` has passed.
    pub fn connect(ip: Ipv4Addr, window: Duration) -> Option<Wire> {
        let until = Instant::now() + window;
        let addr = SocketAddr::from((ip, PORT));
        loop {
            if let Ok(stream) = TcpStream::connect_timeout(&addr, Duration::from_secs(10)) {
                return Some(Wire { reader: BufReader::new(stream) });
            }
            if Instant::now() >= until {
                return None;
            }
            std::thread::sleep(Duration::from_secs(2));
        }
    }

    pub fn send(&mut self, text: &str) -> Result<(), String> {
        let mut stream = self.reader.get_ref();
        stream.write_all(format!("{PREFIX}{text}\n").as_bytes()).and_then(|_| stream.flush()).map_err(|e| format!("far Mac went away ({e})"))
    }

    /// The next line's words after the prefix; the far Mac saying something else is an error.
    pub fn read(&mut self, timeout: Duration) -> Result<String, String> {
        self.reader.get_ref().set_read_timeout(Some(timeout)).map_err(|e| e.to_string())?;
        let mut line = String::new();
        match self.reader.read_line(&mut line) {
            Ok(0) => return Err(CLOSED.into()),
            Ok(_) => {}
            Err(e) if e.kind() == ErrorKind::ConnectionReset => return Err(CLOSED.into()),
            Err(e) => return Err(format!("no answer from the far Mac ({e})")),
        }
        if line.len() > MAX_LINE + PREFIX.len() + 1 {
            return Err("far Mac sent a line too long to be one of ours".into());
        }
        line.trim_end_matches(['\n', '\r'])
            .strip_prefix(PREFIX)
            .map(str::to_string)
            .ok_or_else(|| format!("far Mac said something else: {line:?}"))
    }

    /// Hands `said` each line the far Mac says (its words after the prefix), and `None` once when it
    /// closes or says something that isn't ours, until `over` is set (checked every half second).
    /// For Xcode's pairing nothing is expected while a pairing is awaited; for device control the
    /// code and what was kept come this way. The only reader of the wire while it runs.
    pub fn watch(&self, over: Arc<AtomicBool>, mut said: impl FnMut(Option<String>) + Send + 'static) -> Option<std::thread::JoinHandle<()>> {
        let stream = self.reader.get_ref().try_clone().ok()?;
        stream.set_read_timeout(Some(Duration::from_millis(500))).ok()?;
        Some(std::thread::spawn(move || {
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            while !over.load(Ordering::Relaxed) {
                match reader.read_line(&mut line) {
                    // What came of a line before the timeout stays in `line`; the rest is added to it.
                    Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
                        if line.len() > MAX_LINE + PREFIX.len() {
                            return said(None);
                        }
                    }
                    Ok(n) if n > 0 && line.ends_with('\n') => {
                        match line.trim_end_matches(['\n', '\r']).strip_prefix(PREFIX) {
                            Some(words) => said(Some(words.to_string())),
                            None => return said(None),
                        }
                        line.clear();
                    }
                    _ => return said(None),
                }
            }
        }))
    }
}

/// What a far Mac says while it pairs for device control.
#[derive(Debug, PartialEq)]
pub enum Said {
    /// The code to type on the device.
    Code(String),
    /// Its app kept the pairing; whether it is switched on there.
    Done(bool),
    /// Nothing was kept, and its word for why.
    Failed(String),
    Ended(String),
    Other,
}

pub fn said(words: &str) -> Said {
    let parts: Vec<&str> = words.split(' ').collect();
    match parts.as_slice() {
        ["code", digits] if digits.len() == 6 && digits.bytes().all(|b| b.is_ascii_digit()) => Said::Code(digits.to_string()),
        ["result", "done", "on"] => Said::Done(true),
        ["result", "done", "off"] => Said::Done(false),
        ["result", "failed", why] => Said::Failed(why.to_string()),
        ["ended", why] => Said::Ended(why.to_string()),
        _ => Said::Other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn what_a_far_mac_says_for_device_control() {
        assert_eq!(said("code 456640"), Said::Code("456640".into()));
        // Shown to a person, so only what a code is: six digits.
        assert_eq!(said("code 45664"), Said::Other);
        assert_eq!(said("code 45664a"), Said::Other);
        assert_eq!(said("code 456640 x"), Said::Other);
        assert_eq!(said("result done on"), Said::Done(true));
        assert_eq!(said("result done off"), Said::Done(false));
        assert_eq!(said("result done"), Said::Other);
        assert_eq!(said("result failed not-paired"), Said::Failed("not-paired".into()));
        assert_eq!(said("ended stopped"), Said::Ended("stopped".into()));
        assert_eq!(said("offer x"), Said::Other);
    }
}
