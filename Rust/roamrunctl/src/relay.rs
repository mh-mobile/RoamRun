//! Carries the device's one connection to the far Mac; says when one has carried bytes both ways.

use std::net::{Ipv4Addr, SocketAddr};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc::Sender;

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
    /// The far Mac's command ended (its wire said something, or closed).
    FarGone,
}

/// Takes connections from `only_from` alone and carries each to `far`.
pub async fn serve(listener: TcpListener, only_from: Ipv4Addr, far: SocketAddr, events: Sender<Event>) {
    loop {
        let Ok((inbound, from)) = listener.accept().await else { continue };
        if from.ip() != only_from {
            let _ = events.send(Event::Refused(from)).await;
            continue;
        }
        let _ = events.send(Event::Connected(only_from)).await;
        let events = events.clone();
        tokio::spawn(async move {
            let outbound = match tokio::time::timeout(Duration::from_secs(10), TcpStream::connect(far)).await {
                Ok(Ok(s)) => s,
                Ok(Err(e)) => return send(&events, Event::FarDidNotAnswer(e.to_string())).await,
                Err(_) => return send(&events, Event::FarDidNotAnswer("no answer in 10 s".into())).await,
            };
            let (ir, iw) = inbound.into_split();
            let (or, ow) = outbound.into_split();
            let up = tokio::spawn(pump(ir, ow));
            let down = tokio::spawn(pump(or, iw));
            let (up, down) = (up.await.unwrap_or(0), down.await.unwrap_or(0));
            if up > 0 && down > 0 {
                send(&events, Event::Carried).await;
            }
        });
    }
}

async fn send(events: &Sender<Event>, event: Event) {
    let _ = events.send(event).await;
}

/// Copies until EOF or an error, then closes the writing side; the bytes carried, counted
/// whatever ended it (tokio's copy loses the count on an error, and a reset ends pairings).
async fn pump<R: AsyncReadExt + Unpin, W: AsyncWriteExt + Unpin>(mut from: R, mut to: W) -> u64 {
    let mut buf = vec![0u8; 65536];
    let mut count = 0u64;
    loop {
        match from.read(&mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                if to.write_all(&buf[..n]).await.is_err() {
                    break;
                }
                count += n as u64;
            }
        }
    }
    let _ = to.shutdown().await;
    count
}
