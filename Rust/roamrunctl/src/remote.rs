//! `install` and `launch` with `--relay`: through `roamrunctl mcp --http` on the machine that holds the device's key
//! (anywhere on the tailnet: it reaches the device over Tailscale, as this one would). `ota` with `--server`: through
//! an OTA server, a Mac's `roamrun mcp --http --allow-ota`, which puts an .ipa on its OTA page.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
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
/// The most one read or write waits (for `launch`, also the whole request); a connection; an answer to
/// `Expect: 100-continue`.
const ANSWER: Duration = if cfg!(test) { Duration::from_secs(3) } else { Duration::from_secs(120) };
const CONNECT: Duration = Duration::from_secs(10);
const CONTINUE: Duration = if cfg!(test) { Duration::from_millis(300) } else { Duration::from_secs(10) };

/// When a request is over, and what to say then.
type Deadline<'a> = (Instant, &'a str);

pub struct Relay {
    /// host:port, as connected to and as the Host the server checks.
    host: String,
    token: Option<String>,
    /// What it is called in what is said: "the relay", or "the OTA server" (never the one for the other).
    noun: &'static str,
    /// Whether the last request's head went out: past that, a lost answer may hide what the server did.
    sent: std::cell::Cell<bool>,
}

impl Relay {
    /// `at`: host:port, or the address `mcp --http` printed (http://host:port/mcp). The token: `token_file`, else `TOKEN`.
    pub fn new(at: &str, token_file: Option<&Path>) -> Result<Relay, String> {
        Self::named(at, token_file, "the relay", "--relay", "`roamrunctl mcp --http`", 9090)
    }

    /// An OTA server, `at` as for `new`.
    pub fn server(at: &str, token_file: Option<&Path>) -> Result<Relay, String> {
        Self::named(at, token_file, "the OTA server", "--server", "`roamrun mcp --http --allow-ota` on the Mac", 9091)
    }

    fn named(at: &str, token_file: Option<&Path>, noun: &'static str, flag: &str, printer: &str, example: u16) -> Result<Relay, String> {
        let host = at.strip_prefix("http://").unwrap_or(at).split('/').next().unwrap_or("");
        if host.rsplit_once(':').is_none_or(|(name, port)| name.is_empty() || port.parse::<u16>().is_err()) {
            return Err(format!("{flag} {at}: {noun}'s address and port, as {printer} printed them (100.x.y.z:{example})"));
        }
        let token = match token_file {
            Some(path) => Some(crate::http::token(path)?),
            None => std::env::var(TOKEN).ok().map(|token| token.trim().to_string()).filter(|token| !token.is_empty()),
        };
        Ok(Relay { host: host.to_string(), token, noun, sent: std::cell::Cell::new(false) })
    }

    /// One request, tried again while the relay answers 503: its status and body. `body` gives a body anew for each try.
    fn ask(&self, method: &str, path: &str, body: &dyn Fn() -> std::io::Result<(u64, Box<dyn Read>)>, until: Deadline) -> Result<(u16, String), String> {
        let mut tries = 0;
        loop {
            let (status, said) = self.once(method, path, body, until)?;
            tries += 1;
            if status != 503 || tries == TRIES || Instant::now() + APART >= until.0 { return Ok((status, said)) }
            std::thread::sleep(APART);
        }
    }

    /// One request, over by `until`.
    fn once(&self, method: &str, path: &str, body: &dyn Fn() -> std::io::Result<(u64, Box<dyn Read>)>, (until, why): Deadline) -> Result<(u16, String), String> {
        self.sent.set(false);
        let noun = self.noun;
        let out = || format!("{noun} at {}: {why}", self.host);
        let failed = |e: std::io::Error| match e.kind() {
            _ if Instant::now() >= until => out(),
            // A read or write given up before the deadline, at `ANSWER`.
            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut => format!("{noun} at {}: no answer within {} s", self.host, ANSWER.as_secs()),
            _ => format!("{noun} at {}: {e}", self.host),
        };
        let left = || until.checked_duration_since(Instant::now()).filter(|left| !left.is_zero()).ok_or_else(out);
        let stream = match roamrun_device::proxy::named() {
            // Through the proxy named (ROAMRUNCTL_PROXY), which finds the relay itself.
            Some(proxy) => {
                let (name, port) = self.host.rsplit_once(':').and_then(|(name, port)| Some((name, port.parse().ok()?))).ok_or_else(out)?;
                roamrun_device::proxy::through(proxy, name, port, CONNECT.min(left()?)).map_err(|e| format!("{noun} at {}: {e}", self.host))?
            }
            // It listens on IPv4 alone: each IPv4 address the name gives is tried.
            None => {
                let mut stream = Err(format!("{noun} at {}: no IPv4 address", self.host));
                for at in self.host.to_socket_addrs().map_err(failed)?.filter(SocketAddr::is_ipv4) {
                    stream = TcpStream::connect_timeout(&at, CONNECT.min(left()?)).map_err(failed);
                    if stream.is_ok() { break }
                }
                stream?
            }
        };
        // Before the head is sent and the Expect waited on: no longer than what is left. (The body and the answer: `Bounded`.)
        let within = |most: Duration| -> Result<(), String> {
            let most = most.min(left()?);
            let _ = stream.set_read_timeout(Some(most)).and_then(|()| stream.set_write_timeout(Some(most)));
            Ok(())
        };
        let (length, mut content) = body().map_err(|e| e.to_string())?;
        let token = self.token.as_ref().map_or(String::new(), |token| format!("Authorization: Bearer {token}\r\n"));
        // With Expect, a refusal (the token, who this is, the size) comes before the body is sent.
        let kind = if path == "/upload" { "application/octet-stream" } else { "application/json" };
        let head = format!("{method} {path} HTTP/1.1\r\nHost: {}\r\n{token}Content-Type: {kind}\r\nContent-Length: {length}\r\nExpect: 100-continue\r\nConnection: close\r\n\r\n", self.host);
        within(ANSWER)?;
        (&stream).write_all(head.as_bytes()).map_err(failed)?;
        self.sent.set(true);
        // A server that doesn't answer the Expect is sent the body all the same, after a while.
        within(CONTINUE)?;
        let early = match stream.peek(&mut [0]) {
            Ok(_) => true,
            Err(e) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => false,
            Err(e) => return Err(failed(e)),
        };
        let mut reader = BufReader::new(Bounded(&stream, until));
        // Its first word: a refusal, or 100 Continue (the body goes).
        let refused = if early { Some(answer_head(&mut reader).map_err(failed)?).filter(|(status, _)| !(100..200).contains(status)) } else { None };
        let (status, length) = match refused {
            Some(answer) => answer,
            None => {
                let sent = std::io::copy(&mut content.as_mut().take(length), &mut Bounded(&stream, until));
                // Refused while it was sent (answered, then closed): that answer, not the broken pipe. A 100 Continue
                // that came after the body was sent anyway, and any other 1xx, is passed over.
                let answer = loop {
                    match answer_head(&mut reader) {
                        Ok((status, _)) if (100..200).contains(&status) => continue,
                        answer => break answer,
                    }
                };
                match (answer, sent) {
                    (Ok(answer), _) => answer,
                    (Err(_), Err(e)) | (Err(e), Ok(_)) => return Err(failed(e)),
                }
            }
        };
        let mut said = Vec::new();
        match length {
            Some(length) => reader.take(length).read_to_end(&mut said),
            None => reader.read_to_end(&mut said),
        }.map_err(failed)?;
        Ok((status, String::from_utf8_lossy(&said).into_owned()))
    }

    /// One tool's answer, as text: an error where the tool says it failed.
    pub fn call(&self, tool: &str, arguments: Value) -> Result<String, String> {
        self.call_by(tool, arguments, (Instant::now() + ANSWER, &format!("no answer within {} s", ANSWER.as_secs())))
    }

    fn call_by(&self, tool: &str, arguments: Value, until: Deadline) -> Result<String, String> {
        let line = json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": { "name": tool, "arguments": arguments } }).to_string();
        let (status, said) = self.ask("POST", "/mcp", &|| Ok((line.len() as u64, Box::new(std::io::Cursor::new(line.clone().into_bytes())))), until)?;
        if status != 200 { return Err(self.refused(tool, status, &said)) }
        let said: Value = serde_json::from_str(&said).map_err(|_| format!("{tool}: the relay's answer isn't JSON"))?;
        if let Some(message) = said["error"]["message"].as_str() { return Err(format!("{tool}: {message}")) }
        let text = said["result"]["content"].as_array().into_iter().flatten().filter_map(|c| c["text"].as_str()).collect::<Vec<_>>().join("\n");
        if said["result"]["isError"] == true { Err(text) } else { Ok(text) }
    }

    /// Sends the .ipa at `path`, installs it on the relay's device `name` and waits for it to be in, all within `timeout`
    /// (else what the relay gives the upload and the install, and a minute more). What `install_status` said of this
    /// install, and the app's bundle identifier.
    pub fn install(&self, name: &str, path: &Path, timeout: Option<u64>) -> Result<(String, String), String> {
        let began = Instant::now();
        if !std::fs::metadata(path).map_err(|e| format!("{}: {e}", path.display()))?.is_file() { return Err(format!("{}: through a relay, an .ipa (not an .app folder)", path.display())) }
        let text = path.to_string_lossy();
        let bundle = roamrun_device::ipa_checked(&text)?;
        let (megabytes, given) = roamrun_device::install_given(&text);
        let until = began + timeout.map_or(given + Duration::from_secs(60 + 2 * megabytes), Duration::from_secs);
        let why = format!("out of time ({} s{})", until.duration_since(began).as_secs(), if timeout.is_some() { ", --timeout" } else { ": what the relay gives the upload and the install; --timeout sets another" });
        let deadline = (until, why.as_str());
        let sha256 = sha256_of(path)?;
        let upload = self.upload(path, &sha256, megabytes, false, "installed", deadline)?;
        let begun = self.call_by("install", json!({ "device": name, "upload": upload, "sha256": sha256 }), deadline)?;
        note!("{begun}");
        // Asked of by its id: another caller's install on the device meanwhile, of the same app even, isn't taken for this one.
        let id = install_id(&begun).ok_or("the relay doesn't say which install this is (it needs roamrunctl 0.9.0 or later): not waited for")?;
        loop {
            std::thread::sleep(EVERY);
            if Instant::now() >= until {
                return Err(format!("not in after {} s: the relay goes on with it, and install_status there says how it ends", began.elapsed().as_secs()));
            }
            let said = self.call_by("install_status", json!({ "device": name, "install": id }), deadline)?;
            if said.contains(" is installed on ") { return Ok((said, bundle)) }
            if !said.starts_with("installing ") { return Err(said) }
        }
    }
}

impl Relay {
    /// Sends the .ipa at `path`, whose sha256 is `sha256`: the upload's id. What arrived is what was sent, else nothing is
    /// `done` with it. `busy`: a 409 (another upload coming in) is tried again, `APART` apart, until the deadline.
    fn upload(&self, path: &Path, sha256: &str, megabytes: u64, busy: bool, done: &str, deadline: Deadline) -> Result<String, String> {
        let opened = || std::fs::File::open(path).and_then(|file| Ok((file.metadata()?.len(), Box::new(file) as Box<dyn Read>)));
        note!("Sending {} ({megabytes} MB) to {} at {}", path.display(), self.noun, self.host);
        let (status, said) = loop {
            let (status, said) = self.ask("PUT", "/upload", &opened, deadline)?;
            if !(busy && status == 409 && Instant::now() + APART < deadline.0) { break (status, said) }
            std::thread::sleep(APART);
        };
        if status != 200 { return Err(self.refused("the upload", status, &said)) }
        let said: Value = serde_json::from_str(&said).map_err(|_| format!("{}'s answer to the upload isn't JSON", self.noun))?;
        if said["sha256"].as_str() != Some(sha256) { return Err(format!("{}'s sha256 of the upload isn't {}'s: nothing was {done}", self.noun, path.display())) }
        said["upload"].as_str().map(str::to_string).ok_or_else(|| format!("{}'s answer to the upload has no id", self.noun))
    }

    /// One JSON-RPC request's result: an error where there is none, or it isn't an object.
    fn request(&self, method: &str, params: Value, until: Deadline) -> Result<Value, String> {
        let (status, said) = self.post(method, params, until)?;
        self.result(method, status, &said)
    }

    fn post(&self, method: &str, params: Value, until: Deadline) -> Result<(u16, String), String> {
        let line = json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params }).to_string();
        self.ask("POST", "/mcp", &|| Ok((line.len() as u64, Box::new(std::io::Cursor::new(line.clone().into_bytes())))), until)
    }

    fn result(&self, method: &str, status: u16, said: &str) -> Result<Value, String> {
        if status != 200 { return Err(self.refused(method, status, said)) }
        let said: Value = serde_json::from_str(said).map_err(|_| format!("{method}: {}'s answer isn't JSON", self.noun))?;
        if let Some(message) = said["error"]["message"].as_str() { return Err(format!("{method}: {message}")) }
        match &said["result"] {
            result @ Value::Object(_) => Ok(result.clone()),
            _ => Err(format!("{method}: {}'s answer has no result", self.noun)),
        }
    }

    /// Puts the .ipa at `path` on the OTA page, through an OTA server, all within `timeout` (else 2 s a MB, as the server
    /// gives an upload, 30 s more, and 120 s for `ota`). What the server said of it. The deadline is the network's: hashing
    /// the file and finding the server's address aren't held to it.
    pub fn ota(&self, path: &Path, replace: bool, timeout: Option<u64>) -> Result<String, String> {
        let began = Instant::now();
        let is_ipa = path.extension().is_some_and(|e| e.eq_ignore_ascii_case("ipa"));
        let size = std::fs::metadata(path).map_err(|e| format!("{}: {e}", path.display()))?;
        if !size.is_file() || !is_ipa { return Err(format!("{}: an .ipa signed for Release Testing (Ad Hoc) or Enterprise", path.display())) }
        let megabytes = size.len().div_ceil(1 << 20);
        let until = began + timeout.map_or(Duration::from_secs(2 * megabytes + 30 + 120), Duration::from_secs);
        let why = format!("out of time ({} s{})", until.duration_since(began).as_secs(), if timeout.is_some() { ", --timeout" } else { "; --timeout sets another" });
        let deadline = (until, why.as_str());
        // What it is, before anything is sent: a relay (which can't), or a RoamRun without `ota`.
        let hello = self.request("initialize", json!({ "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": { "name": "roamrunctl", "version": env!("ROAMRUN_VERSION") } }), deadline)?;
        if hello["serverInfo"]["name"] == "roamrunctl" {
            return Err(format!("{} is a relay (roamrunctl mcp --http), which can't publish to the OTA page: give --server the Mac's `roamrun mcp --http --allow-ota` (RoamRun 0.12.0 or later)", self.host));
        }
        let tools = self.request("tools/list", json!({}), deadline)?;
        if !tools["tools"].as_array().into_iter().flatten().any(|tool| tool["name"] == "ota") {
            return Err(format!("the server at {} has no ota: its RoamRun is older than 0.12.0, or it was started without --allow-ota", self.host));
        }
        // Hashing is this Mac's time, not the network's: the deadline moves on by it.
        let hashing = Instant::now();
        let sha256 = sha256_of(path)?;
        let deadline = (until + hashing.elapsed(), deadline.1);
        let mut again = false;
        loop {
            let upload = self.upload(path, &sha256, megabytes, true, "published", deadline)?;
            // Sent and not answered, or answered with what ota doesn't give: it may have stored the build. Not sent again.
            let unknown = |why: String| format!("{why}. The build may have been stored: look at the page before running this again");
            let (status, said) = self.post("tools/call", json!({ "name": "ota", "arguments": { "upload": upload, "sha256": sha256, "replace": replace } }), deadline)
                .map_err(|e| if self.sent.get() { unknown(e) } else { e })?;
            // A 200 that isn't JSON-RPC's error, yet not a result either, may have come after ota ran.
            let refusal = status != 200 || serde_json::from_str::<Value>(&said).is_ok_and(|said| said["error"]["message"].is_string());
            let said = self.result("ota", status, &said).map_err(|e| if refusal { e } else { unknown(e) })?;
            let (Some(content), true) = (said["content"].as_array(), said.get("isError").is_none_or(Value::is_boolean)) else {
                return Err(unknown(format!("ota: {}'s answer isn't one ota gives", self.noun)));
            };
            let text = content.iter().filter_map(|c| c["text"].as_str()).collect::<Vec<_>>().join("\n");
            if said["isError"] != true { return Ok(text) }
            // Refused before ota ran (another upload replaced this one): nothing was stored, so it can go once more.
            if !text.starts_with("no upload ") { return Err(text) }
            if std::mem::replace(&mut again, true) {
                return Err(format!("{text}\nIt was sent again once, and another job's upload replaced it again: publish one job at a time, or run this again"));
            }
        }
    }
}

/// The file's sha256, as the server answers it.
fn sha256_of(path: &Path) -> Result<String, String> {
    let mut hash = <sha2::Sha256 as sha2::Digest>::new();
    let mut file = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    std::io::copy(&mut file, &mut hash).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(sha2::Digest::finalize(hash).iter().map(|b| format!("{b:02x}")).collect())
}

/// The id in what `install` answered: "… (install <id>) …".
fn install_id(begun: &str) -> Option<&str> {
    begun.split_once("(install ").and_then(|(_, rest)| rest.split_once(')')).map(|(id, _)| id).filter(|id| !id.is_empty())
}

/// The connection, read and written until `.1`, then failing: an upload or an answer that would go on past the deadline stops.
struct Bounded<'a>(&'a TcpStream, Instant);

impl Bounded<'_> {
    /// The next read or write waits only what is left (`ANSWER` at most); none left, TimedOut. Where the relay has reset
    /// the connection (it answered and closed, or just closed, while the body went), macOS refuses to set it: what it
    /// answered is read all the same, and the reset is said as one.
    fn wait(&self, set: fn(&TcpStream, Option<Duration>) -> std::io::Result<()>) -> std::io::Result<()> {
        let left = self.1.checked_duration_since(Instant::now()).filter(|left| !left.is_zero()).ok_or(std::io::ErrorKind::TimedOut)?;
        let _ = set(self.0, Some(ANSWER.min(left)));
        Ok(())
    }
}

/// A relay that stops reading doesn't hold an upload past the deadline.
impl Write for Bounded<'_> {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.wait(TcpStream::set_write_timeout)?;
        let mut stream = self.0;
        stream.write(bytes)
    }
    fn flush(&mut self) -> std::io::Result<()> { Ok(()) }
}

/// A relay that answers a byte at a time, stops halfway, or sends 1xx on and on doesn't hold this past the deadline.
impl Read for Bounded<'_> {
    fn read(&mut self, into: &mut [u8]) -> std::io::Result<usize> {
        self.wait(TcpStream::set_read_timeout)?;
        let mut stream = self.0;
        stream.read(into)
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

impl Relay {
    /// Why it refused `what`, said for the one who runs this.
    fn refused(&self, what: &str, status: u16, said: &str) -> String {
        let server = self.noun == "the OTA server";
        let why = match status {
            401 => "it wants its token (ROAMRUNCTL_TOKEN, or --token-file)".to_string(),
            403 => "it doesn't let this machine in (its --allow)".to_string(),
            404 if what == "the upload" && server => "it isn't an OTA server (started without --allow-ota)".to_string(),
            404 if what == "the upload" => "it takes no installs (it runs without --allow-install)".to_string(),
            409 if server => "it was taking another upload all the time this waited: publish one job at a time".to_string(),
            _ => said.trim().chars().take(400).collect(),
        };
        format!("{what}: {} answered {status}{}{why}", self.noun, if why.is_empty() { "" } else { ": " })
    }
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

    #[test]
    fn an_install_is_known_by_the_id_it_was_answered_with() {
        assert_eq!(install_id("installing a.b (1 MB) on phone (install 0f3a), for 315 s at most"), Some("0f3a"));
        assert_eq!(install_id("installing a.b (1 MB) on phone, for 315 s at most"), None);
        assert_eq!(install_id("(install )"), None);
        assert_eq!(install_id(&crate::mcp::begun("a.b", 1, "phone", "3f2a9c0e1b7d4a65", Duration::from_secs(315))), Some("3f2a9c0e1b7d4a65"));
    }

    #[test]
    fn a_path_that_isnt_there_is_said_so() {
        let said = Relay::new("127.0.0.1:9", None).unwrap().install("phone", Path::new("/nowhere/at/all.ipa"), None).err().unwrap_or_default();
        assert!(said.starts_with("/nowhere/at/all.ipa: ") && !said.contains(".app folder"), "{said}");
    }

    /// A server on 127.0.0.1 that answers one request with `answer`, its 100 Continue sent `late` after the body
    /// went anyway (else none).
    fn served(late: bool, answer: &str) -> std::net::SocketAddr {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let at = listener.local_addr().unwrap();
        let answer = answer.to_string();
        std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(&stream);
            let mut length = 0;
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if line == "\r\n" { break }
                if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") { length = value.trim().parse().unwrap() }
            }
            let mut body = vec![0; length];
            reader.read_exact(&mut body).unwrap();
            if late { (&stream).write_all(b"HTTP/1.1 100 Continue\r\n\r\n").unwrap() }
            (&stream).write_all(format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{answer}", answer.len()).as_bytes()).unwrap();
        });
        at
    }

    /// A server that answers no `Expect: 100-continue`, or answers it late, is sent the body after a while, and answered.
    #[test]
    fn a_body_goes_without_100_continue_and_a_late_one_is_passed_over() {
        let answer = json!({ "jsonrpc": "2.0", "id": 1, "result": { "content": [{ "type": "text", "text": "phone" }] } }).to_string();
        for late in [false, true] {
            let began = Instant::now();
            assert_eq!(Relay::new(&served(late, &answer).to_string(), None).unwrap().call("devices", json!({})).as_deref(), Ok("phone"), "late: {late}");
            assert!(began.elapsed() < Duration::from_secs(5));
        }
    }

    /// A server on 127.0.0.1 that takes one connection and does `then` with it.
    fn serving(then: impl FnOnce(&TcpStream) + Send + 'static) -> std::net::SocketAddr {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let at = listener.local_addr().unwrap();
        std::thread::spawn(move || { let (stream, _) = listener.accept().unwrap(); then(&stream) });
        at
    }

    /// A gigabyte of nothing, as an upload's body.
    fn big() -> std::io::Result<(u64, Box<dyn Read>)> { Ok((1 << 30, Box::new(std::io::repeat(0)))) }

    /// A relay that stops reading holds an upload no longer than its deadline.
    #[test]
    fn a_relay_that_stops_reading_is_left_at_the_deadline() {
        let at = serving(|stream| {
            let mut stream = stream;
            stream.write_all(b"HTTP/1.1 100 Continue\r\n\r\n").unwrap();
            // Reads for a while, then no more: a write begun then waits on what is left, not on what was left at first.
            let began = Instant::now();
            let mut chunk = [0; 1 << 16];
            while began.elapsed() < Duration::from_millis(1200) { let _ = stream.read(&mut chunk); }
            std::thread::sleep(Duration::from_secs(10));
        });
        let began = Instant::now();
        let said = Relay::new(&at.to_string(), None).unwrap().once("PUT", "/upload", &big, (began + Duration::from_secs(2), "out of time")).err().unwrap_or_default();
        // Said as out of time alone, not with what the socket said then.
        assert_eq!(said, format!("the relay at {at}: out of time"));
        assert!(began.elapsed() < Duration::from_millis(2800), "{:?}", began.elapsed());
    }

    /// A relay that says nothing is given up on at `ANSWER`, before a deadline further off, and said so.
    #[test]
    fn a_silent_relay_is_given_up_on_at_answer() {
        let at = serving(|_| std::thread::sleep(Duration::from_secs(8)));
        let body = || Ok((2u64, Box::new(std::io::Cursor::new(b"{}".to_vec())) as Box<dyn Read>));
        let said = Relay::new(&at.to_string(), None).unwrap().once("POST", "/mcp", &body, (Instant::now() + Duration::from_secs(20), "out of time")).err().unwrap_or_default();
        assert_eq!(said, format!("the relay at {at}: no answer within {} s", ANSWER.as_secs()));
    }

    /// A relay that answers halfway and stops, or sends 1xx on and on, isn't waited for past the deadline.
    #[test]
    fn an_answer_is_read_within_the_deadline() {
        let halfway = serving(|stream| {
            let mut stream = stream;
            // Late, so that what was left as its head came is less than what was left at first.
            std::thread::sleep(Duration::from_millis(1300));
            stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nhalf").unwrap();
            std::thread::sleep(Duration::from_secs(10));
        });
        let processing = serving(|stream| {
            let mut stream = stream;
            for _ in 0..50 { if stream.write_all(b"HTTP/1.1 102 Processing\r\n\r\n").is_err() { break } std::thread::sleep(Duration::from_millis(200)) }
        });
        let drip = serving(|stream| {
            let mut stream = stream;
            for byte in b"HTTP/1.1 200 OK\r\nX-Slow: ".iter().chain(std::iter::repeat_n(&b'a', 100)) {
                if stream.write_all(&[*byte]).is_err() { break }
                std::thread::sleep(Duration::from_millis(100));
            }
        });
        for at in [halfway, processing, drip] {
            let began = Instant::now();
            let body = || Ok((2u64, Box::new(std::io::Cursor::new(b"{}".to_vec())) as Box<dyn Read>));
            let said = Relay::new(&at.to_string(), None).unwrap().once("POST", "/mcp", &body, (began + Duration::from_millis(1500), "out of time")).err().unwrap_or_default();
            assert_eq!(said, format!("the relay at {at}: out of time"));
            assert!(began.elapsed() < Duration::from_millis(2000), "{:?}", began.elapsed());
        }
    }

    /// A relay that refuses while the body goes, and closes without reading the rest, is read for its answer; one that
    /// closes so without an answer is said to have reset the connection. The connection is reset by then: on macOS the
    /// socket's timeouts can't be set any more. (Not tried on Windows.)
    #[cfg(not(windows))]
    #[test]
    fn a_refusal_while_the_body_goes_is_read() {
        let at = serving(|stream| {
            let mut stream = stream;
            stream.write_all(b"HTTP/1.1 100 Continue\r\n\r\n").unwrap();
            let mut taken = vec![0; 256 * 1024];
            let _ = stream.read_exact(&mut taken);
            stream.write_all(b"HTTP/1.1 413 Payload Too Large\r\nContent-Length: 10\r\nConnection: close\r\n\r\ntoo large\n").unwrap();
        });
        let said = Relay::new(&at.to_string(), None).unwrap().once("PUT", "/upload", &big, (Instant::now() + Duration::from_secs(20), "out of time"));
        assert_eq!(said, Ok((413, "too large\n".to_string())));
        for _ in 0..3 {
            let at = serving(|stream| {
                let mut stream = stream;
                stream.write_all(b"HTTP/1.1 100 Continue\r\n\r\n").unwrap();
                let mut taken = vec![0; 256 * 1024];
                let _ = stream.read_exact(&mut taken);
            });
            let said = Relay::new(&at.to_string(), None).unwrap().once("PUT", "/upload", &big, (Instant::now() + Duration::from_secs(20), "out of time")).err().unwrap_or_default();
            assert!(["reset", "Broken pipe"].iter().any(|word| said.contains(word)) && !said.contains("Invalid argument"), "{said}");
        }
    }

    /// A server on 127.0.0.1 that answers its requests in turn with `answers` (status, body; status 0: read, then closed
    /// without an answer), keeping each request's first line and body.
    fn scripted(answers: Vec<(u16, String)>) -> (std::net::SocketAddr, std::sync::Arc<std::sync::Mutex<Vec<String>>>) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let at = listener.local_addr().unwrap();
        let seen = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let kept = seen.clone();
        std::thread::spawn(move || {
            for (status, body) in answers {
                let Ok((stream, _)) = listener.accept() else { return };
                let mut reader = BufReader::new(&stream);
                let (mut first, mut length) = (String::new(), 0);
                reader.read_line(&mut first).unwrap();
                loop {
                    let mut line = String::new();
                    reader.read_line(&mut line).unwrap();
                    if line == "\r\n" { break }
                    if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") { length = value.trim().parse().unwrap() }
                }
                // A refusal before the body, as the server's 401/404/409 come.
                let refused = status != 200 && status != 0;
                let mut taken = vec![0; if refused { 0 } else { length }];
                if !refused { (&stream).write_all(b"HTTP/1.1 100 Continue\r\n\r\n").unwrap(); reader.read_exact(&mut taken).unwrap(); }
                kept.lock().unwrap().push(format!("{} {}", first.trim_end(), String::from_utf8_lossy(&taken)));
                if status == 0 { continue }
                let _ = (&stream).write_all(format!("HTTP/1.1 {status} X\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes());
            }
        });
        (at, seen)
    }

    fn rpc(result: Value) -> (u16, String) { (200, json!({ "jsonrpc": "2.0", "id": 1, "result": result }).to_string()) }
    fn hello(name: &str) -> (u16, String) { rpc(json!({ "serverInfo": { "name": name, "version": "0.12.0" } })) }
    fn listing(names: &[&str]) -> (u16, String) { rpc(json!({ "tools": names.iter().map(|name| json!({ "name": name })).collect::<Vec<_>>() })) }
    fn said(text: &str, error: bool) -> (u16, String) { rpc(json!({ "content": [{ "type": "text", "text": text }], "isError": error })) }

    /// An .ipa of a few bytes in a folder of its own, and its sha256: the client checks neither its shape nor its signing.
    fn ipa() -> (std::path::PathBuf, String) {
        let folder = std::env::temp_dir().join(format!("roamrunctl-ota-{}-{:?}", std::process::id(), std::thread::current().id()));
        std::fs::create_dir_all(&folder).unwrap();
        let path = folder.join("App.ipa");
        std::fs::write(&path, b"an app").unwrap();
        let sha256 = sha256_of(&path).unwrap();
        (path, sha256)
    }

    fn uploaded(sha256: &str) -> (u16, String) { (200, json!({ "upload": "u1", "size": 6, "sha256": sha256 }).to_string()) }

    /// `ota` asks what the server is before it sends anything: a relay, or a RoamRun without `ota`, is refused so.
    #[test]
    fn ota_is_refused_by_a_relay_or_a_server_without_it_before_anything_is_sent() {
        let (path, _) = ipa();
        let (relay, seen) = scripted(vec![hello("roamrunctl")]);
        let said = Relay::server(&relay.to_string(), None).unwrap().ota(&path, false, Some(10)).err().unwrap_or_default();
        assert!(said.contains("is a relay") && said.contains("--allow-ota"), "{said}");
        assert_eq!(seen.lock().unwrap().len(), 1);
        let (older, seen) = scripted(vec![hello("roamrun"), listing(&["devices", "look"])]);
        let said = Relay::server(&older.to_string(), None).unwrap().ota(&path, false, Some(10)).err().unwrap_or_default();
        assert!(said.contains("has no ota") && said.contains("0.12.0"), "{said}");
        assert_eq!(seen.lock().unwrap().len(), 2);
        // Its upload refused 404: the OTA server's own reason, not an install's.
        let (plain, _) = scripted(vec![hello("roamrun"), listing(&["ota"]), (404, String::new())]);
        let said = Relay::server(&plain.to_string(), None).unwrap().ota(&path, false, Some(10)).err().unwrap_or_default();
        assert!(said.contains("the OTA server answered 404") && said.contains("--allow-ota") && !said.contains("relay"), "{said}");
    }

    /// Stored: what the server said, after a busy upload slot (409) was waited out; `replace` goes with the call.
    #[test]
    fn ota_waits_out_a_busy_slot_and_says_what_was_stored() {
        let (path, sha256) = ipa();
        let (at, seen) = scripted(vec![hello("roamrun"), listing(&["ota"]), (409, String::new()), uploaded(&sha256), said("Stored App 1.0.", false)]);
        assert_eq!(Relay::server(&at.to_string(), None).unwrap().ota(&path, true, Some(20)), Ok("Stored App 1.0.".to_string()));
        let seen = seen.lock().unwrap();
        assert!(seen[4].contains(r#""name":"ota""#) && seen[4].contains(r#""replace":true"#) && seen[4].contains(&sha256), "{seen:?}");
    }

    /// Another job's upload replaced this one before its `ota`: sent again once; a second time, said so and left.
    #[test]
    fn ota_sends_again_once_when_another_upload_replaced_its_own() {
        let (path, sha256) = ipa();
        let gone = "no upload u1 is kept here for you (replaced by a later upload, used by ota, or dropped after 30 minutes unused): send it again";
        let (at, _) = scripted(vec![hello("roamrun"), listing(&["ota"]), uploaded(&sha256), said(gone, true), uploaded(&sha256), said("Stored App 1.0.", false)]);
        assert_eq!(Relay::server(&at.to_string(), None).unwrap().ota(&path, false, Some(20)), Ok("Stored App 1.0.".to_string()));
        let (at, seen) = scripted(vec![hello("roamrun"), listing(&["ota"]), uploaded(&sha256), said(gone, true), uploaded(&sha256), said(gone, true)]);
        let said = Relay::server(&at.to_string(), None).unwrap().ota(&path, false, Some(20)).err().unwrap_or_default();
        assert!(said.contains("sent again once") && said.contains("one job at a time"), "{said}");
        assert_eq!(seen.lock().unwrap().len(), 6);
    }

    /// A refusal is the step's failure; so are a sha256 that isn't the file's and an answer with no result.
    #[test]
    fn ota_fails_on_a_refusal_a_wrong_sha256_or_no_result() {
        let (path, sha256) = ipa();
        let (at, _) = scripted(vec![hello("roamrun"), listing(&["ota"]), uploaded(&sha256), said("That build is signed for Development", true)]);
        assert_eq!(Relay::server(&at.to_string(), None).unwrap().ota(&path, false, Some(20)), Err("That build is signed for Development".to_string()));
        let (at, _) = scripted(vec![hello("roamrun"), listing(&["ota"]), uploaded("00")]);
        let said = Relay::server(&at.to_string(), None).unwrap().ota(&path, false, Some(20)).err().unwrap_or_default();
        assert!(said.contains("the OTA server's sha256") && said.contains("nothing was published"), "{said}");
        let (at, _) = scripted(vec![(200, json!({ "jsonrpc": "2.0", "id": 1 }).to_string())]);
        let said = Relay::server(&at.to_string(), None).unwrap().ota(&path, false, Some(20)).err().unwrap_or_default();
        assert!(said.contains("has no result"), "{said}");
    }

    /// Hashing the file isn't held to the deadline: a 32 MB .ipa, hashed (unoptimised) for longer than its 1 s, is
    /// still sent to a server that answers at once.
    #[test]
    fn ota_s_deadline_leaves_out_hashing_the_file() {
        let (path, _) = ipa();
        std::fs::write(&path, vec![7u8; 32 << 20]).unwrap();
        let sha256 = sha256_of(&path).unwrap();
        let (at, _) = scripted(vec![hello("roamrun"), listing(&["ota"]), uploaded(&sha256), said("Stored App 1.0.", false)]);
        let stored = Relay::server(&at.to_string(), None).unwrap().ota(&path, false, Some(1));
        std::fs::remove_file(&path).unwrap();
        assert_eq!(stored, Ok("Stored App 1.0.".to_string()));
    }

    /// A server that says nothing is left at the deadline, said as the OTA server's.
    #[test]
    fn ota_is_held_to_its_deadline() {
        let (path, _) = ipa();
        let at = serving(|_| std::thread::sleep(Duration::from_secs(8)));
        let began = Instant::now();
        let said = Relay::server(&at.to_string(), None).unwrap().ota(&path, false, Some(1)).err().unwrap_or_default();
        assert!(said.starts_with(&format!("the OTA server at {at}: out of time (1 s, --timeout)")), "{said}");
        assert!(began.elapsed() < Duration::from_secs(3), "{:?}", began.elapsed());
    }

    /// The token, who this is, and a busy check are said as the OTA server's; a 503 is tried again.
    #[test]
    fn ota_says_refusals_as_the_ota_servers_and_tries_a_503_again() {
        let (path, sha256) = ipa();
        for (status, word) in [(401, "ROAMRUNCTL_TOKEN"), (403, "--allow")] {
            let (at, _) = scripted(vec![(status, String::new())]);
            let said = Relay::server(&at.to_string(), None).unwrap().ota(&path, false, Some(10)).err().unwrap_or_default();
            assert!(said.starts_with(&format!("initialize: the OTA server answered {status}")) && said.contains(word) && !said.contains("may have been stored"), "{said}");
        }
        let (at, _) = scripted(vec![(503, String::new()), hello("roamrun"), listing(&["ota"]), uploaded(&sha256), said("Stored App 1.0.", false)]);
        assert_eq!(Relay::server(&at.to_string(), None).unwrap().ota(&path, false, Some(20)), Ok("Stored App 1.0.".to_string()));
    }

    /// An `ota` sent and not answered, or answered with what ota doesn't give, may have stored the build: said so, and
    /// not sent again.
    #[test]
    fn ota_sent_and_not_answered_is_said_to_be_unknown_and_not_sent_again() {
        let (path, sha256) = ipa();
        let (at, seen) = scripted(vec![hello("roamrun"), listing(&["ota"]), uploaded(&sha256), (0, String::new())]);
        let said = Relay::server(&at.to_string(), None).unwrap().ota(&path, false, Some(20)).err().unwrap_or_default();
        assert!(said.contains("may have been stored"), "{said}");
        assert_eq!(seen.lock().unwrap().iter().filter(|r| r.contains(r#""name":"ota""#)).count(), 1);
        let (at, _) = scripted(vec![hello("roamrun"), listing(&["ota"]), uploaded(&sha256), rpc(json!({}))]);
        let said = Relay::server(&at.to_string(), None).unwrap().ota(&path, false, Some(20)).err().unwrap_or_default();
        assert!(said.contains("isn't one ota gives") && said.contains("may have been stored"), "{said}");
    }

    /// A slot busy all the time it was waited for is said as such, with what to do; a relay's 409 isn't.
    #[test]
    fn a_busy_slot_is_said_with_what_to_do() {
        let said = Relay::server("127.0.0.1:9", None).unwrap().refused("the upload", 409, "");
        assert!(said.starts_with("the upload: the OTA server answered 409") && said.contains("one job at a time"), "{said}");
        assert!(!Relay::new("127.0.0.1:9", None).unwrap().refused("the upload", 409, "").contains("one job at a time"));
    }

    /// An answer to `ota` that isn't JSON, has no result, or says isError as anything but true or false: unknown, not
    /// success, not sent again. A 503 to `ota`, then no server at all: not sent, so not unknown.
    #[test]
    fn ota_answers_that_arent_ota_s_are_unknown() {
        let (path, sha256) = ipa();
        for answer in [(200, "not json".to_string()), (200, json!({ "jsonrpc": "2.0", "id": 1 }).to_string()), rpc(json!({ "content": [], "isError": null })), rpc(json!({ "content": [], "isError": "yes" }))] {
            let (at, seen) = scripted(vec![hello("roamrun"), listing(&["ota"]), uploaded(&sha256), answer]);
            let said = Relay::server(&at.to_string(), None).unwrap().ota(&path, false, Some(20)).err().unwrap_or_default();
            assert!(said.contains("may have been stored"), "{said}");
            assert_eq!(seen.lock().unwrap().iter().filter(|r| r.contains(r#""name":"ota""#)).count(), 1);
        }
        let (at, _) = scripted(vec![hello("roamrun"), listing(&["ota"]), uploaded(&sha256), (200, json!({ "jsonrpc": "2.0", "id": 1, "error": { "code": -32602, "message": "bad params" } }).to_string())]);
        let said = Relay::server(&at.to_string(), None).unwrap().ota(&path, false, Some(20)).err().unwrap_or_default();
        assert!(said.contains("bad params") && !said.contains("may have been stored"), "{said}");
        // The 503's server is gone when it is tried again: that try sent nothing.
        let (at, _) = scripted(vec![hello("roamrun"), listing(&["ota"]), uploaded(&sha256), (503, String::new())]);
        let said = Relay::server(&at.to_string(), None).unwrap().ota(&path, false, Some(20)).err().unwrap_or_default();
        assert!(!said.contains("may have been stored"), "{said}");
    }
}
