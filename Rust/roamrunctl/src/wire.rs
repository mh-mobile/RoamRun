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

    /// Calls `gone` once the far Mac says anything or closes, until `over` is set (checked every
    /// half second). Nothing is expected on the wire while a pairing is awaited.
    pub fn watch(&self, over: Arc<AtomicBool>, gone: impl FnOnce() + Send + 'static) -> Option<std::thread::JoinHandle<()>> {
        let stream = self.reader.get_ref().try_clone().ok()?;
        stream.set_read_timeout(Some(Duration::from_millis(500))).ok()?;
        Some(std::thread::spawn(move || {
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            while !over.load(Ordering::Relaxed) {
                match reader.read_line(&mut line) {
                    Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => continue,
                    _ => return gone(),
                }
            }
        }))
    }
}
