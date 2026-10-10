//! Carries the device's one connection to the far Mac; says when one has carried bytes both ways.

use std::net::{Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
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
        let (true, Ok(held)) = (from.ip() == only_from, held) else {
            let _ = events.send(Event::Refused(from)).await;
            continue;
        };
        let _ = events.send(Event::Connected(only_from)).await;
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

/// Copies both ways until both have closed, or either broke (a reset ends pairings, and the
/// other way may never close by itself); whether bytes went both ways.
async fn carry(inbound: TcpStream, outbound: TcpStream) -> bool {
    let (ir, iw) = inbound.into_split();
    let (or, ow) = outbound.into_split();
    let counts = [Arc::new(AtomicU64::new(0)), Arc::new(AtomicU64::new(0))];
    let up = tokio::spawn(pump(ir, ow, counts[0].clone()));
    let down = tokio::spawn(pump(or, iw, counts[1].clone()));
    let (stop_up, stop_down) = (up.abort_handle(), down.abort_handle());
    let up = tokio::spawn(async move {
        if !up.await.unwrap_or(false) {
            stop_down.abort();
        }
    });
    if !down.await.unwrap_or(false) {
        stop_up.abort();
    }
    let _ = up.await;
    counts.iter().all(|c| c.load(Ordering::Relaxed) > 0)
}

async fn send(events: &Sender<Event>, event: Event) {
    let _ = events.send(event).await;
}

/// Copies until EOF or an error, then closes the writing side; false when an error ended it.
/// The bytes carried are counted whatever ended it (tokio's copy loses the count on an error).
async fn pump<R: AsyncReadExt + Unpin, W: AsyncWriteExt + Unpin>(mut from: R, mut to: W, count: Arc<AtomicU64>) -> bool {
    let mut buf = vec![0u8; 65536];
    let clean = loop {
        match from.read(&mut buf).await {
            Ok(0) => break true,
            Err(_) => break false,
            Ok(n) => {
                if to.write_all(&buf[..n]).await.is_err() {
                    break false;
                }
                count.fetch_add(n as u64, Ordering::Relaxed);
            }
        }
    };
    let _ = to.shutdown().await;
    clean
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
            // Closed with unread bytes waiting: a reset, not an end.
            device.write_all(b"more").await.unwrap();
            tokio::time::sleep(Duration::from_millis(200)).await;
            drop(far);
            assert_eq!(tokio::time::timeout(Duration::from_secs(5), carried).await.map(Result::ok), Ok(Some(true)));
            drop(device);
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
                said.push(matches!(events.recv().await, Some(Event::Refused(_))));
            }
            assert_eq!(said, [false, false, true]);
        });
    }
}
