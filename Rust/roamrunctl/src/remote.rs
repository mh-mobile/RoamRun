//! `install` and `launch` with `--relay`: through `roamrunctl mcp --http` on the machine beside the device.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::path::Path;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

/// The relay's token itself (the server's `--token-file` holds the same).
pub const TOKEN: &str = "ROAMRUNCTL_TOKEN";

/// How often `install_status` is asked.
const EVERY: Duration = if cfg!(test) { Duration::from_millis(50) } else { Duration::from_secs(5) };
/// A request the relay answers 503 (it couldn't tell who this is just then) is tried this often, this far apart.
const TRIES: u32 = 5;
const APART: Duration = if cfg!(test) { Duration::from_millis(50) } else { Duration::from_secs(3) };
/// The most one answer is waited for, and one write.
const ANSWER: Duration = Duration::from_secs(120);

pub struct Relay {
    /// host:port, as connected to and as the Host the server checks.
    host: String,
    token: Option<String>,
}

impl Relay {
    /// `at`: host:port, or the address `mcp --http` printed (http://host:port/mcp). The token: `token_file`, else `TOKEN`.
    pub fn new(at: &str, token_file: Option<&Path>) -> Result<Relay, String> {
        let host = at.strip_prefix("http://").unwrap_or(at).split('/').next().unwrap_or("");
        if host.rsplit_once(':').is_none_or(|(name, port)| name.is_empty() || port.parse::<u16>().is_err()) {
            return Err(format!("--relay {at}: the relay's address and port, as `roamrunctl mcp --http` printed them (100.x.y.z:9090)"));
        }
        let token = match token_file {
            Some(path) => Some(crate::http::token(path)?),
            None => std::env::var(TOKEN).ok().map(|token| token.trim().to_string()).filter(|token| !token.is_empty()),
        };
        Ok(Relay { host: host.to_string(), token })
    }

    /// One request, tried again while the relay answers 503: its status and body. `body` gives a body anew for each try.
    fn ask(&self, method: &str, path: &str, body: &dyn Fn() -> std::io::Result<(u64, Box<dyn Read>)>) -> Result<(u16, String), String> {
        let mut tries = 0;
        loop {
            let (status, said) = self.once(method, path, body)?;
            tries += 1;
            if status != 503 || tries == TRIES { return Ok((status, said)) }
            std::thread::sleep(APART);
        }
    }

    fn once(&self, method: &str, path: &str, body: &dyn Fn() -> std::io::Result<(u64, Box<dyn Read>)>) -> Result<(u16, String), String> {
        let failed = |e: std::io::Error| format!("the relay at {}: {e}", self.host);
        let at = self.host.to_socket_addrs().map_err(failed)?.next().ok_or_else(|| format!("the relay at {}: no address", self.host))?;
        let stream = TcpStream::connect_timeout(&at, Duration::from_secs(10)).map_err(failed)?;
        stream.set_read_timeout(Some(ANSWER)).and_then(|()| stream.set_write_timeout(Some(ANSWER))).map_err(failed)?;
        let (length, mut content) = body().map_err(|e| e.to_string())?;
        let token = self.token.as_ref().map_or(String::new(), |token| format!("Authorization: Bearer {token}\r\n"));
        // With Expect, a refusal (the token, who this is, the size) comes before the body is sent.
        let kind = if path == "/upload" { "application/octet-stream" } else { "application/json" };
        let head = format!("{method} {path} HTTP/1.1\r\nHost: {}\r\n{token}Content-Type: {kind}\r\nContent-Length: {length}\r\nExpect: 100-continue\r\nConnection: close\r\n\r\n", self.host);
        (&stream).write_all(head.as_bytes()).map_err(failed)?;
        let mut reader = BufReader::new(&stream);
        let mut answer = answer_head(&mut reader).map_err(failed)?;
        if answer.0 == 100 {
            std::io::copy(&mut content.as_mut().take(length), &mut &stream).map_err(failed)?;
            answer = answer_head(&mut reader).map_err(failed)?;
        }
        let (status, length) = answer;
        let mut said = Vec::new();
        match length {
            Some(length) => reader.take(length).read_to_end(&mut said),
            None => reader.read_to_end(&mut said),
        }.map_err(failed)?;
        Ok((status, String::from_utf8_lossy(&said).into_owned()))
    }

    /// One tool's answer, as text: an error where the tool says it failed.
    pub fn call(&self, tool: &str, arguments: Value) -> Result<String, String> {
        let line = json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": { "name": tool, "arguments": arguments } }).to_string();
        let (status, said) = self.ask("POST", "/mcp", &|| Ok((line.len() as u64, Box::new(std::io::Cursor::new(line.clone().into_bytes())))))?;
        if status != 200 { return Err(refused(tool, status, &said)) }
        let said: Value = serde_json::from_str(&said).map_err(|_| format!("{tool}: the relay's answer isn't JSON"))?;
        if let Some(message) = said["error"]["message"].as_str() { return Err(format!("{tool}: {message}")) }
        let text = said["result"]["content"].as_array().into_iter().flatten().filter_map(|c| c["text"].as_str()).collect::<Vec<_>>().join("\n");
        if said["result"]["isError"] == true { Err(text) } else { Ok(text) }
    }

    /// Sends the .ipa at `path`, installs it on the relay's device `name` and waits for it to be in, until `timeout`
    /// (else what the relay gives the upload and the install, and a minute more). What `install_status` said, and the
    /// app's bundle identifier.
    pub fn install(&self, name: &str, path: &Path, timeout: Option<u64>) -> Result<(String, String), String> {
        let began = Instant::now();
        if !path.is_file() { return Err(format!("{}: through a relay, an .ipa (not an .app folder)", path.display())) }
        let text = path.to_string_lossy();
        let bundle = roamrun_device::ipa_checked(&text)?;
        let (megabytes, given) = roamrun_device::install_given(&text);
        let until = began + timeout.map_or(given + Duration::from_secs(60 + 2 * megabytes), Duration::from_secs);
        let opened = || std::fs::File::open(path).and_then(|file| Ok((file.metadata()?.len(), Box::new(file) as Box<dyn Read>)));
        let mut hash = <sha2::Sha256 as sha2::Digest>::new();
        std::io::copy(&mut opened().map_err(|e| format!("{}: {e}", path.display()))?.1, &mut hash).map_err(|e| format!("{}: {e}", path.display()))?;
        let sha256: String = sha2::Digest::finalize(hash).iter().map(|b| format!("{b:02x}")).collect();
        note!("Sending {} ({megabytes} MB) to the relay at {}", path.display(), self.host);
        let (status, said) = self.ask("PUT", "/upload", &opened)?;
        if status != 200 { return Err(refused("the upload", status, &said)) }
        let said: Value = serde_json::from_str(&said).map_err(|_| "the relay's answer to the upload isn't JSON".to_string())?;
        // What arrived is what was sent: else nothing is installed.
        if said["sha256"].as_str() != Some(sha256.as_str()) { return Err(format!("the relay's sha256 of the upload isn't {}'s: nothing was installed", path.display())) }
        let upload = said["upload"].as_str().ok_or("the relay's answer to the upload has no id")?;
        note!("{}", self.call("install", json!({ "device": name, "upload": upload, "sha256": sha256 }))?);
        loop {
            std::thread::sleep(EVERY);
            let said = self.call("install_status", json!({ "device": name }))?;
            if said.contains(" is installed on ") { return Ok((said, bundle)) }
            // Not going on and not in (the relay was started again since, say): not taken for in.
            if !said.starts_with("installing ") { return Err(said) }
            if Instant::now() >= until {
                return Err(format!("not in after {} s: the relay goes on with it, and install_status there says how it ends", began.elapsed().as_secs()));
            }
        }
    }
}

/// The status line and the length of an answer, its head read.
fn answer_head(reader: &mut impl BufRead) -> std::io::Result<(u16, Option<u64>)> {
    let (mut status, mut length, mut first) = (None, None, true);
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line)? == 0 { return Err(std::io::ErrorKind::UnexpectedEof.into()) }
        let line = line.trim_end();
        if line.is_empty() { break }
        if std::mem::take(&mut first) {
            status = line.split(' ').nth(1).and_then(|s| s.parse().ok());
        } else if let Some((name, value)) = line.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") { length = value.trim().parse().ok() }
        }
    }
    status.map(|status| (status, length)).ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidData, "not an HTTP answer"))
}

/// Why the relay refused `what`, said for the one who runs this.
fn refused(what: &str, status: u16, said: &str) -> String {
    let why = match status {
        401 => "it wants its token (ROAMRUNCTL_TOKEN, or --token-file)".to_string(),
        403 => "it doesn't let this machine in (its --allow)".to_string(),
        404 if what == "the upload" => "it takes no installs (it runs without --allow-install)".to_string(),
        _ => said.trim().chars().take(400).collect(),
    };
    format!("{what}: the relay answered {status}{}{why}", if why.is_empty() { "" } else { ": " })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_relay_is_its_address_and_port() {
        for at in ["100.64.0.1:9090", "http://100.64.0.1:9090/mcp", "http://100.64.0.1:9090", "mac.example.ts.net:9090"] {
            assert!(Relay::new(at, None).is_ok(), "{at}");
        }
        assert_eq!(Relay::new("http://100.64.0.1:9090/mcp", None).map(|r| r.host).unwrap_or_default(), "100.64.0.1:9090");
        for at in ["100.64.0.1", "https://100.64.0.1:9090/mcp", ":9090", "100.64.0.1:http", ""] {
            assert!(Relay::new(at, None).is_err(), "{at}");
        }
    }
}
