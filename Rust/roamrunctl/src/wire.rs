//! The `rr-pair-v1` wire to the far Mac (port 41830), as `PairByName.swift` speaks it.

use std::io::{BufRead, BufReader, ErrorKind, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub const PORT: u16 = 41830;
/// `read`'s error when the far Mac closed without a word: transient while an offer is awaited.
pub const CLOSED: &str = "far Mac closed the connection";
const PREFIX: &str = "rr-pair-v1 ";
const MAX_LINE: usize = 4096;

/// One reader, whoever reads: what it has taken in ahead belongs to the next line read.
pub struct Wire {
    stream: TcpStream,
    reader: Arc<Mutex<BufReader<TcpStream>>>,
}

/// Adds what has come to `line`, up to its newline: true once it is whole. One read at most, so
/// that whoever calls looks at its own deadline between two: a far side that sends a byte now and
/// then would otherwise never let go. More than a line of ours is `InvalidData`, the far side
/// closing `UnexpectedEof`.
fn fill<R: BufRead>(reader: &mut R, line: &mut Vec<u8>) -> std::io::Result<bool> {
    let room = (PREFIX.len() + MAX_LINE + 2).saturating_sub(line.len());
    let came = reader.fill_buf()?;
    if came.is_empty() {
        return Err(ErrorKind::UnexpectedEof.into());
    }
    let (take, whole) = match came.iter().take(room).position(|b| *b == b'\n') {
        Some(at) => (at + 1, true),
        None => (came.len().min(room), false),
    };
    line.extend_from_slice(&came[..take]);
    reader.consume(take);
    if !whole && take == room {
        return Err(ErrorKind::InvalidData.into());
    }
    Ok(whole)
}

/// A read that gave nothing yet: its timeout passed, or it was interrupted.
fn waiting(e: &std::io::Error) -> bool {
    matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut | ErrorKind::Interrupted)
}

/// A line's words after the prefix.
fn words(line: &[u8]) -> Option<String> {
    String::from_utf8_lossy(line).trim_end_matches(['\n', '\r']).strip_prefix(PREFIX).map(str::to_string)
}

impl Wire {
    /// Tries every two seconds until the far Mac listens, or `window` has passed.
    pub fn connect(ip: Ipv4Addr, window: Duration) -> Option<Wire> {
        let until = Instant::now() + window;
        let addr = SocketAddr::from((ip, PORT));
        loop {
            if let Some(wire) = TcpStream::connect_timeout(&addr, Duration::from_secs(10)).ok().and_then(Wire::over) {
                return Some(wire);
            }
            if Instant::now() >= until {
                return None;
            }
            std::thread::sleep(Duration::from_secs(2));
        }
    }

    fn over(stream: TcpStream) -> Option<Wire> {
        let reader = Arc::new(Mutex::new(BufReader::new(stream.try_clone().ok()?)));
        Some(Wire { stream, reader })
    }

    pub fn send(&mut self, text: &str) -> Result<(), String> {
        self.stream.write_all(format!("{PREFIX}{text}\n").as_bytes()).and_then(|_| self.stream.flush()).map_err(|e| format!("far Mac went away ({e})"))
    }

    /// The next line's words after the prefix, whole within `timeout`; the far Mac saying
    /// something else is an error.
    pub fn read(&mut self, timeout: Duration) -> Result<String, String> {
        let until = Instant::now() + timeout;
        let mut reader = self.reader.lock().unwrap_or_else(|e| e.into_inner());
        let mut line = Vec::new();
        loop {
            let Some(left) = until.checked_duration_since(Instant::now()).filter(|d| !d.is_zero()) else {
                return Err("no answer from the far Mac (in time)".into());
            };
            // On the reader's own handle: Windows doesn't carry a timeout over to a clone.
            reader.get_ref().set_read_timeout(Some(left)).map_err(|e| e.to_string())?;
            match fill(&mut *reader, &mut line) {
                Ok(true) => break,
                Ok(false) => {}
                Err(e) if waiting(&e) => {}
                // Windows says "aborted" of a connection the far side dropped.
                Err(e) if matches!(e.kind(), ErrorKind::UnexpectedEof | ErrorKind::ConnectionReset | ErrorKind::ConnectionAborted) => return Err(CLOSED.into()),
                Err(e) if e.kind() == ErrorKind::InvalidData => return Err("far Mac sent a line too long to be one of ours".into()),
                Err(e) => return Err(format!("no answer from the far Mac ({e})")),
            }
        }
        words(&line).ok_or_else(|| format!("far Mac said something else: {:?}", String::from_utf8_lossy(&line)))
    }

    /// Hands `said` each line the far Mac says (its words after the prefix), and `None` once when it
    /// closes or says something that isn't ours, until `over` is set (checked every half second)
    /// or `said` answers false. For Xcode's pairing nothing is expected while a pairing is awaited;
    /// for device control the code and what was kept come this way. It holds the reader while it runs.
    pub fn watch(&self, over: Arc<AtomicBool>, mut said: impl FnMut(Option<String>) -> bool + Send + 'static) -> Option<std::thread::JoinHandle<()>> {
        let reader = self.reader.clone();
        Some(std::thread::spawn(move || {
            let mut reader = reader.lock().unwrap_or_else(|e| e.into_inner());
            if reader.get_ref().set_read_timeout(Some(Duration::from_millis(500))).is_err() {
                said(None);
                return;
            }
            let mut line = Vec::new();
            while !over.load(Ordering::Relaxed) {
                match fill(&mut *reader, &mut line) {
                    Ok(true) => {
                        let words = words(&line);
                        if !said(words.clone()) || words.is_none() {
                            return;
                        }
                        line.clear();
                    }
                    Ok(false) => {}
                    Err(e) if waiting(&e) => {}
                    Err(_) => {
                        said(None);
                        return;
                    }
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
    /// Which of its attempts this is, to ask it about afterwards.
    Attempt(String),
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
        // Printed for a person to type there, so only what an id is.
        ["attempt", id] if crate::lines::is_uuid(id) => Said::Attempt(id.to_string()),
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
        let id = "6F9619FF-8B86-D011-B42D-00C04FC964FF";
        assert_eq!(said(&format!("attempt {id}")), Said::Attempt(id.into()));
        assert_eq!(said("attempt \x1b]0;x\x07"), Said::Other);
    }

    /// Gives a byte a call, as a far side that sends one now and then.
    struct Trickle<'a>(&'a [u8]);
    impl std::io::Read for Trickle<'_> {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            let n = self.0.len().min(1).min(buf.len());
            buf[..n].copy_from_slice(&self.0[..n]);
            self.0 = &self.0[n..];
            Ok(n)
        }
    }

    #[test]
    fn a_line_is_bounded_and_comes_in_parts() {
        // No newline, however much comes: refused once it is past a line of ours, and not kept.
        let (mut line, mut endless) = (Vec::new(), BufReader::new(std::io::repeat(b'x')));
        let ended = loop {
            match fill(&mut endless, &mut line) {
                Ok(false) => {}
                other => break other,
            }
        };
        assert_eq!(ended.unwrap_err().kind(), ErrorKind::InvalidData);
        assert!(line.len() <= PREFIX.len() + MAX_LINE + 2);
        // A byte at a time: each call comes back, so the caller's deadline is looked at between.
        let (mut line, mut slow) = (Vec::new(), BufReader::new(Trickle(b"rr-pair-v1 offer?\nrr")));
        let mut calls = 0;
        while !fill(&mut slow, &mut line).unwrap() {
            calls += 1;
        }
        assert_eq!((words(&line), calls), (Some("offer?".into()), 17));
        // What a first read brought stays for the second, and the next line stays unread.
        let (mut line, mut two) = (b"rr-pair-v1 off".to_vec(), &b"er?\nrr-pair-v1 next\n"[..]);
        assert!(fill(&mut two, &mut line).unwrap());
        assert_eq!((words(&line), two), (Some("offer?".into()), &b"rr-pair-v1 next\n"[..]));
        assert!(!fill(&mut &b"rr-pair-v1 cut"[..], &mut Vec::new()).unwrap());
        assert_eq!(fill(&mut &b""[..], &mut Vec::new()).unwrap_err().kind(), ErrorKind::UnexpectedEof);
        assert_eq!(words(b"hello\n"), None);
    }

    /// Both ends of a connection on this machine.
    fn ends() -> (Wire, TcpStream) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let far = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        (Wire::over(listener.accept().unwrap().0).unwrap(), far)
    }

    #[test]
    fn a_far_side_that_sends_a_byte_now_and_then_holds_neither_reader() {
        let (mut wire, mut far) = ends();
        let trickling = Arc::new(AtomicBool::new(true));
        let trickle = std::thread::spawn({
            let trickling = trickling.clone();
            move || {
                while trickling.load(Ordering::Relaxed) && far.write_all(b"x").is_ok() {
                    std::thread::sleep(Duration::from_millis(50));
                }
            }
        });
        // A read is over when its time is, though bytes keep coming.
        let began = Instant::now();
        assert!(wire.read(Duration::from_millis(400)).is_err());
        assert!(began.elapsed() < Duration::from_secs(2));
        // And the watcher ends when it is told to: waited for from another thread, so a failure can't hang this one.
        let over = Arc::new(AtomicBool::new(false));
        let watching = wire.watch(over.clone(), |_| true).unwrap();
        std::thread::sleep(Duration::from_millis(300));
        over.store(true, Ordering::Relaxed);
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || tx.send(watching.join().is_ok()));
        let ended = rx.recv_timeout(Duration::from_secs(3));
        trickling.store(false, Ordering::Relaxed);
        let _ = trickle.join();
        assert_eq!(ended, Ok(true));
    }

    #[test]
    fn lines_sent_together_all_arrive_whoever_reads() {
        let (mut wire, mut far) = ends();
        far.write_all(b"rr-pair-v1 offer x\nrr-pair-v1 result failed cancelled\n").unwrap();
        assert_eq!(wire.read(Duration::from_secs(5)).as_deref(), Ok("offer x"));
        let (tx, rx) = std::sync::mpsc::channel();
        let over = Arc::new(AtomicBool::new(false));
        let watching = wire.watch(over.clone(), move |said| tx.send(said).is_ok()).unwrap();
        assert_eq!(rx.recv_timeout(Duration::from_secs(5)), Ok(Some("result failed cancelled".into())));
        over.store(true, Ordering::Relaxed);
        watching.join().unwrap();
        drop(far);
    }
}
