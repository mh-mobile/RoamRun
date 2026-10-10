//! Carries the device's one connection to the far Mac; says when one has carried bytes both ways.

use std::net::{Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc::Sender;
use tokio::sync::Semaphore;

/// Listens on `port` or one of the next twenty.
pub async fn listen(local: Ipv4Addr, port: u16) -> Result<TcpListener, String> {
    let mut why = String::new();
    for p in port..=port.saturating_add(20) {
        match TcpListener::bind(SocketAddr::from((local, p))).await {
            Ok(l) => return Ok(l),
            Err(e) => why = e.to_string(),
        }
    }
    Err(format!("no port of {port}–{} on {local} could be listened on ({why})", port.saturating_add(20)))
}

/// What the relay says, and what else ends the wait for a pairing.
pub enum Event {
    Connected(Ipv4Addr),
    Refused(SocketAddr),
    /// From the device, with as many carried already as are taken at once.
    Full(SocketAddr),
    FarDidNotAnswer(String),
    /// A connection carried bytes both ways and closed: a pairing was tried.
    Carried,
    Deadline,
    Stopped,
    AddressLost,
    /// The far Mac said this on its wire.
    Far(String),
    /// The far Mac's command ended (its wire closed, or said something that isn't ours).
    FarGone,
    /// Device control: the device is done here, and the far Mac hasn't said what it kept in time.
    NoResult,
}

/// A pairing is one connection; RoamRun's own introducer takes two at a time as well.
const AT_ONCE: usize = 2;

/// Takes connections from `only_from` alone, `AT_ONCE` at a time, and carries each to `far`.
pub async fn serve(listener: TcpListener, only_from: Ipv4Addr, far: SocketAddr, events: Sender<Event>) {
    let room = Arc::new(Semaphore::new(AT_ONCE));
    loop {
        let Ok((inbound, from)) = listener.accept().await else { continue };
        let held = room.clone().try_acquire_owned();
        // Said when there is room to say it: strangers knocking mustn't keep the device waiting.
        let (true, Ok(held)) = (from.ip() == only_from, held) else {
            let _ = events.try_send(if from.ip() == only_from { Event::Full(from) } else { Event::Refused(from) });
            continue;
        };
        let _ = events.try_send(Event::Connected(only_from));
        let events = events.clone();
        tokio::spawn(async move {
            let _held = held;
            let outbound = match tokio::time::timeout(Duration::from_secs(10), TcpStream::connect(far)).await {
                Ok(Ok(s)) => s,
                Ok(Err(e)) => return send(&events, Event::FarDidNotAnswer(e.to_string())).await,
                Err(_) => return send(&events, Event::FarDidNotAnswer("no answer in 10 s".into())).await,
            };
            if carry(inbound, outbound).await {
                send(&events, Event::Carried).await;
            }
        });
    }
}

/// How long the other way goes on once one has broken: what it still holds gets through, and a
/// side that never closes doesn't keep the connection.
const GRACE: Duration = Duration::from_secs(3);

/// Copies both ways until both have closed, or `GRACE` after either broke (a reset ends
/// pairings, and the other way may never close by itself); whether bytes went both ways.
async fn carry<I, O>(inbound: I, outbound: O) -> bool
where
    I: AsyncRead + AsyncWrite + Send + 'static,
    O: AsyncRead + AsyncWrite + Send + 'static,
{
    let (ir, iw) = tokio::io::split(inbound);
    let (or, ow) = tokio::io::split(outbound);
    let broke = Arc::new(AtomicBool::new(false));
    let counts = [Arc::new(AtomicU64::new(0)), Arc::new(AtomicU64::new(0))];
    let up = tokio::spawn(pump(ir, ow, counts[0].clone(), broke.clone()));
    let down = tokio::spawn(pump(or, iw, counts[1].clone(), broke));
    let _ = (up.await, down.await);
    counts.iter().all(|c| c.load(Ordering::Relaxed) > 0)
}

async fn send(events: &Sender<Event>, event: Event) {
    let _ = events.send(event).await;
}

/// Copies until EOF or an error, then closes the writing side; an error says so in `broke`, and
/// `GRACE` after the other way said so this ends too. The bytes carried are counted whatever
/// ended it (tokio's copy loses the count on an error).
async fn pump<R: AsyncRead + Unpin, W: AsyncWrite + Unpin>(mut from: R, mut to: W, count: Arc<AtomicU64>, broke: Arc<AtomicBool>) {
    let mut buf = vec![0u8; 65536];
    let mut until = None;
    loop {
        if broke.load(Ordering::Relaxed) && *until.get_or_insert_with(|| Instant::now() + GRACE) <= Instant::now() {
            break;
        }
        // Looked at again every second: the other way may have broken while this one waits.
        match tokio::time::timeout(Duration::from_secs(1), from.read(&mut buf)).await {
            Err(_) => continue,
            Ok(Ok(0)) => break,
            Ok(Ok(n)) if to.write_all(&buf[..n]).await.is_ok() => drop(count.fetch_add(n as u64, Ordering::Relaxed)),
            Ok(_) => {
                broke.store(true, Ordering::Relaxed);
                break;
            }
        }
    }
    let _ = to.shutdown().await;
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn pair() -> (TcpStream, TcpStream) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let near = TcpStream::connect(listener.local_addr().unwrap()).await.unwrap();
        (near, listener.accept().await.unwrap().0)
    }

    #[test]
    #[allow(deprecated)] // set_linger: the one way to a reset for certain; nothing blocks on a zero linger
    fn a_reset_from_the_far_side_ends_a_connection_the_device_holds_open() {
        tokio::runtime::Runtime::new().unwrap().block_on(async {
            let (mut device, inbound) = pair().await;
            let (outbound, mut far) = pair().await;
            let carried = tokio::spawn(carry(inbound, outbound));
            device.write_all(b"ping").await.unwrap();
            let mut buf = [0u8; 4];
            far.read_exact(&mut buf).await.unwrap();
            far.write_all(b"pong").await.unwrap();
            device.read_exact(&mut buf).await.unwrap();
            // A reset, not an end, whatever has arrived by then.
            far.set_linger(Some(Duration::ZERO)).unwrap();
            drop(far);
            assert_eq!(tokio::time::timeout(GRACE + Duration::from_secs(5), carried).await.map(Result::ok), Ok(Some(true)));
            drop(device);
        });
    }

    /// Reads nothing and fails: a side whose connection broke.
    struct Broken;
    impl AsyncRead for Broken {
        fn poll_read(self: std::pin::Pin<&mut Self>, _: &mut std::task::Context<'_>, _: &mut tokio::io::ReadBuf<'_>) -> std::task::Poll<std::io::Result<()>> {
            std::task::Poll::Ready(Err(std::io::ErrorKind::ConnectionReset.into()))
        }
    }

    #[test]
    fn what_one_way_still_holds_gets_through_when_the_other_breaks() {
        tokio::runtime::Runtime::new().unwrap().block_on(async {
            // The device takes the answer slowly, through a small buffer, and its own sending has broken.
            let (mut device, to_device) = tokio::io::duplex(1024);
            let (outbound, mut far) = tokio::io::duplex(1024);
            let carried = tokio::spawn(carry(tokio::io::join(Broken, to_device), outbound));
            // Small enough to be through well within GRACE on a slow machine, and more than one read of it.
            let answer = vec![7u8; 20_000];
            let sent = tokio::spawn({
                let answer = answer.clone();
                async move {
                    far.write_all(&answer).await.unwrap();
                    far.shutdown().await.unwrap();
                    far
                }
            });
            let mut got = Vec::new();
            let mut buf = [0u8; 4096];
            while let Ok(Ok(n)) = tokio::time::timeout(Duration::from_secs(10), device.read(&mut buf)).await {
                if n == 0 {
                    break;
                }
                got.extend_from_slice(&buf[..n]);
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
            assert_eq!(got.len(), answer.len());
            let _ = (sent.await, carried.await);
        });
    }

    #[test]
    fn no_more_than_two_at_once() {
        tokio::runtime::Runtime::new().unwrap().block_on(async {
            let far = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let (at, (tx, mut events)) = (listener.local_addr().unwrap(), tokio::sync::mpsc::channel(16));
            tokio::spawn(serve(listener, Ipv4Addr::LOCALHOST, far.local_addr().unwrap(), tx));
            let mut held = Vec::new();
            for _ in 0..3 {
                held.push(TcpStream::connect(at).await.unwrap());
            }
            let mut said = Vec::new();
            for _ in 0..3 {
                said.push(matches!(events.recv().await, Some(Event::Full(_))));
            }
            assert_eq!(said, [false, false, true]);
        });
    }
}
