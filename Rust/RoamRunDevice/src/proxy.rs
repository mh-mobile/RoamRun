//! Connections to the device through an HTTP proxy's CONNECT, where one was named: for a machine that
//! reaches the device no other way. Nothing here reads the environment: whoever wants a proxy names it.

use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::OnceLock;
use std::time::Duration;

/// The proxy's answer at most: a status line and its headers.
const MAX: usize = 4096;

#[derive(Debug, PartialEq)]
pub struct Proxy {
    host: String,
    port: u16,
}

static NAMED: OnceLock<Proxy> = OnceLock::new();

/// `http://host:port`, and nothing else: no user, no path, not https (a proxy spoken to in the clear).
pub fn parse(url: &str) -> Result<Proxy, String> {
    let bad = || format!("“{url}” isn't a proxy this takes: http://<host>:<port>");
    let rest = url.strip_prefix("http://").ok_or_else(bad)?;
    let rest = rest.strip_suffix('/').unwrap_or(rest);
    let (host, port) = rest.rsplit_once(':').ok_or_else(bad)?;
    let fits = !host.is_empty() && host.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-');
    match port.parse() {
        Ok(port) if fits && port != 0 => Ok(Proxy { host: host.to_string(), port }),
        _ => Err(bad()),
    }
}

/// The proxy named, if one was: for the caller's own connections that go where the device's do (a relay).
pub fn named() -> Option<&'static Proxy> {
    NAMED.get()
}

/// From here on, connections to a device go through this proxy. Once: a second name is refused.
pub fn name(url: &str) -> Result<(), String> {
    NAMED.set(parse(url)?).map_err(|_| "a proxy is named already".to_string())
}

/// A connection to `ip:port` through `proxy`, each step given `within`.
pub fn through(proxy: &Proxy, ip: &str, port: u16, within: Duration) -> Result<TcpStream, String> {
    let at = (proxy.host.as_str(), proxy.port).to_socket_addrs().ok().and_then(|mut all| all.next())
        .ok_or_else(|| format!("the proxy {}:{} has no address", proxy.host, proxy.port))?;
    let said = |e: std::io::Error| format!("the proxy {}:{}: {e}", proxy.host, proxy.port);
    let mut stream = TcpStream::connect_timeout(&at, within).map_err(said)?;
    stream.set_read_timeout(Some(within)).map_err(said)?;
    stream.set_write_timeout(Some(within)).map_err(said)?;
    stream.write_all(format!("CONNECT {ip}:{port} HTTP/1.1\r\nHost: {ip}:{port}\r\n\r\n").as_bytes()).map_err(said)?;
    // A byte at a time: what follows the blank line is the device's, and stays unread.
    let mut answer = Vec::new();
    let mut byte = [0u8; 1];
    while !answer.ends_with(b"\r\n\r\n") {
        if answer.len() >= MAX { return Err(format!("the proxy {}:{} answered with more than a proxy does", proxy.host, proxy.port)); }
        match stream.read(&mut byte) {
            Ok(1) => answer.push(byte[0]),
            Ok(_) => return Err(format!("the proxy {}:{} closed before it answered", proxy.host, proxy.port)),
            Err(e) => return Err(said(e)),
        }
    }
    let line = String::from_utf8_lossy(&answer);
    let line = line.lines().next().unwrap_or("");
    let status = line.split(' ').nth(1).unwrap_or("");
    if !line.starts_with("HTTP/1.") || status != "200" {
        return Err(format!("the proxy {}:{} didn't connect to {ip}:{port} ({})", proxy.host, proxy.port, if line.is_empty() { "no status" } else { line }));
    }
    stream.set_read_timeout(None).map_err(said)?;
    stream.set_write_timeout(None).map_err(said)?;
    Ok(stream)
}

/// A connection to `ip:port`: through the proxy named, else as it is.
pub fn reach(ip: &str, port: u16, within: Duration) -> Result<TcpStream, String> {
    match NAMED.get() {
        Some(proxy) => through(proxy, ip, port, within),
        None => {
            let at = format!("{ip}:{port}").parse().map_err(|_| format!("{ip}:{port} isn't an address"))?;
            TcpStream::connect_timeout(&at, within).map_err(|e| e.to_string())
        }
    }
}

/// As `reach`, for the library's own connections: without a proxy, exactly what it did before there was one.
pub(crate) async fn dial(ip: &str, port: u16) -> Result<tokio::net::TcpStream, String> {
    let Some(proxy) = NAMED.get() else {
        return tokio::net::TcpStream::connect((ip, port)).await.map_err(|e| e.to_string());
    };
    let ip = ip.to_string();
    let stream = tokio::task::spawn_blocking(move || through(proxy, &ip, port, crate::DEADLINE)).await.map_err(|e| e.to_string())??;
    stream.set_nonblocking(true).map_err(|e| e.to_string())?;
    tokio::net::TcpStream::from_std(stream).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    /// A proxy that answers one CONNECT with `status`, and then gives back what it is sent.
    fn proxy(status: &'static str) -> (Proxy, std::thread::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let asked = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut asked = Vec::new();
            let mut byte = [0u8; 1];
            while !asked.ends_with(b"\r\n\r\n") {
                stream.read_exact(&mut byte).unwrap();
                asked.push(byte[0]);
            }
            // The device's first bytes in the same write as the answer: they aren't the proxy's.
            stream.write_all(format!("HTTP/1.1 {status}\r\nserver: test\r\n\r\nfirst").as_bytes()).unwrap();
            let mut said = [0u8; 4];
            if stream.read_exact(&mut said).is_ok() { stream.write_all(&said).unwrap(); }
            String::from_utf8(asked).unwrap()
        });
        (Proxy { host: "127.0.0.1".into(), port }, asked)
    }

    #[test]
    fn a_connection_through_a_proxy_asks_for_the_device_and_carries_what_follows() {
        let (proxy, asked) = proxy("200 OK");
        let mut stream = through(&proxy, "100.64.0.9", 49152, Duration::from_secs(10)).unwrap();
        let mut first = [0u8; 5];
        stream.read_exact(&mut first).unwrap();
        assert_eq!(&first, b"first");
        stream.write_all(b"ping").unwrap();
        let mut back = [0u8; 4];
        stream.read_exact(&mut back).unwrap();
        assert_eq!(&back, b"ping");
        assert_eq!(asked.join().unwrap(), "CONNECT 100.64.0.9:49152 HTTP/1.1\r\nHost: 100.64.0.9:49152\r\n\r\n");
    }

    #[test]
    fn a_proxy_that_refuses_isn_t_a_connection() {
        let (proxy, _) = proxy("403 Forbidden");
        let why = through(&proxy, "100.64.0.9", 49152, Duration::from_secs(10)).unwrap_err();
        assert!(why.contains("HTTP/1.1 403 Forbidden") && why.contains("100.64.0.9:49152"), "{why}");
    }

    #[test]
    fn only_a_plain_http_proxy_is_taken() {
        assert_eq!(parse("http://proxy:8080"), Ok(Proxy { host: "proxy".into(), port: 8080 }));
        assert_eq!(parse("http://10.0.0.1:3128/"), Ok(Proxy { host: "10.0.0.1".into(), port: 3128 }));
        for bad in ["https://proxy:8080", "proxy:8080", "http://proxy", "http://user:pw@proxy:8080", "http://proxy:8080/path", "http://:8080", "http://proxy:0", "socks5://proxy:1080"] {
            assert!(parse(bad).is_err(), "{bad}");
        }
    }
}
