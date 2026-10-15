//! `roamrunctl mcp --http <port> --allow <who>… <devices>…`: the MCP tools over HTTP — Streamable HTTP as MCP
//! 2025-11-25 has it, without sessions, every answer JSON — on this machine's Tailscale IPv4 address, for the
//! callers Tailscale says are allowed. One request a connection. Tool calls take turns, as over stdio.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{IpAddr, Ipv4Addr, TcpListener, TcpStream};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

use crate::mcp::{Server, VERSIONS};
use crate::tailscale::{self, Whois};

/// A request's head at most, and a message's body.
const HEAD: usize = 16 * 1024;
const BODY: usize = 1 << 20;
/// For reading a whole request, and for writing an answer.
const READ: Duration = Duration::from_secs(30);
/// Connections served at once (a client opens up to 16, and one more to take a call back); more are turned away.
const AT_ONCE: usize = 32;
/// A tool call that waited this long for its turn isn't begun: another held the device.
const TURN: Duration = Duration::from_secs(20);

/// Who may call: tagged machines by a tag, people's own machines by their login.
#[derive(Debug, PartialEq, Clone)]
pub enum Allow {
    Tag(String),
    Login(String),
}

/// `--allow`, as given.
pub fn allow(said: &str) -> Result<Allow, String> {
    if said.len() > 4 && said.starts_with("tag:") { return Ok(Allow::Tag(said.to_string())) }
    if said.contains('@') { return Ok(Allow::Login(said.to_string())) }
    Err(format!("--allow {said}: a tag (tag:ci) or a login (someone@example.com), as `tailscale whois` names them. A machine's name isn't taken: it can be taken by another"))
}

/// Whether the machine Tailscale says is calling may, and who it is for the log: by its tags where it has any,
/// else by its user's login. One shared in from another tailnet is refused; so is this machine itself (`own`) —
/// any user of it would pass — unless the token came too.
pub fn judged(who: &Whois, allowed: &[Allow], own: bool, token: bool) -> Result<String, String> {
    let tags = who.node.tags.clone().unwrap_or_default();
    let name = if tags.is_empty() { who.user.login.clone() } else { tags.join(",") };
    if who.node.sharer != 0 { return Err(format!("{name}, shared in from another tailnet")) }
    if own { return if token { Ok(format!("{name} (this machine)")) } else { Err("this machine itself, without the token".into()) } }
    let fits = |allow: &Allow| match allow {
        Allow::Tag(tag) => tags.contains(tag),
        // A tagged machine is nobody's, whoever it shows as.
        Allow::Login(login) => tags.is_empty() && !who.user.login.is_empty() && login.eq_ignore_ascii_case(&who.user.login),
    };
    if allowed.iter().any(fits) { Ok(name) } else { Err(format!("{name}, not allowed")) }
}

/// The token in `path`: the owner's alone to read (not checked on Windows), 32 characters at least, one line.
pub fn token(path: &Path) -> Result<String, String> {
    let meta = std::fs::metadata(path).map_err(|e| format!("{}: {e}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if meta.permissions().mode() & 0o077 != 0 { return Err(format!("{} can be read by others than its owner: chmod 600 it", path.display())) }
    }
    let _ = meta;
    let token = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?.trim().to_string();
    if token.len() < 32 || token.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(format!("{}: a token is 32 characters or more on one line (`openssl rand -hex 32`, say)", path.display()));
    }
    Ok(token)
}

/// Equal, in a time that doesn't tell how much of it was.
fn same(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |differ, (x, y)| differ | (x ^ y)) == 0
}

pub struct Request {
    pub method: String,
    pub path: String,
    headers: Vec<(String, String)>,
}

impl Request {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(n, _)| n == name).map(|(_, v)| v.as_str())
    }
}

/// A line, ending in LF; `most` bytes at most.
fn line(reader: &mut impl BufRead, most: usize) -> Result<String, u16> {
    let mut line = Vec::new();
    let read = reader.by_ref().take(most as u64 + 1).read_until(b'\n', &mut line).map_err(|_| 408u16)?;
    if read == 0 || !line.ends_with(b"\n") { return Err(if read > most { 431 } else { 400 }) }
    String::from_utf8(line).map(|line| line.trim_end_matches(['\r', '\n']).to_string()).map_err(|_| 400)
}

/// The request line and the headers, to the empty line. A target in absolute form is taken by its path.
pub fn head(reader: &mut impl BufRead) -> Result<Request, u16> {
    let mut left = HEAD;
    let mut first = String::new();
    while first.is_empty() {
        first = line(reader, left)?;
        left = left.checked_sub(first.len() + 2).ok_or(431u16)?;
    }
    let mut words = first.split(' ');
    let (Some(method), Some(target), Some(version), None) = (words.next(), words.next(), words.next(), words.next()) else { return Err(400) };
    if !version.starts_with("HTTP/1.") { return Err(505) }
    let target = match target.strip_prefix("http://") {
        Some(rest) => rest.find('/').map_or("/", |at| &rest[at..]),
        None => target,
    };
    let path = target.split('?').next().unwrap_or("/").to_string();
    let mut headers = Vec::new();
    loop {
        let line = line(reader, left)?;
        left = left.checked_sub(line.len() + 2).ok_or(431u16)?;
        if line.is_empty() { break }
        let (name, value) = line.split_once(':').ok_or(400u16)?;
        if name.is_empty() || name.contains(|c: char| c.is_whitespace()) { return Err(400) }
        headers.push((name.to_ascii_lowercase(), value.trim().to_string()));
    }
    Ok(Request { method: method.to_string(), path, headers })
}

/// The body as the head frames it: chunked where it says so (also when a length comes with it, as HTTP has
/// it), else by its one length, else none. `most` bytes at most.
pub fn body(reader: &mut impl BufRead, request: &Request, most: usize) -> Result<Vec<u8>, u16> {
    if let Some(coding) = request.header("transfer-encoding") {
        if !coding.eq_ignore_ascii_case("chunked") { return Err(501) }
        let mut body = Vec::new();
        loop {
            let size = line(reader, 1024)?;
            let size = usize::from_str_radix(size.split(';').next().unwrap_or("").trim(), 16).map_err(|_| 400u16)?;
            if size == 0 { break }
            if size > most - body.len() { return Err(413) }
            let at = body.len();
            body.resize(at + size, 0);
            reader.read_exact(&mut body[at..]).map_err(|_| 400u16)?;
            if !line(reader, 2)?.is_empty() { return Err(400) }
        }
        // What may trail the last piece: read to the empty line, not used.
        while !line(reader, 1024)?.is_empty() {}
        return Ok(body);
    }
    let lengths: Vec<&str> = request.headers.iter().filter(|(n, _)| n == "content-length").map(|(_, v)| v.as_str()).collect();
    let length = match lengths.as_slice() {
        [] => return Ok(Vec::new()),
        [one] if !one.is_empty() && one.bytes().all(|b| b.is_ascii_digit()) => one.parse::<usize>().map_err(|_| 413u16)?,
        _ => return Err(400),
    };
    if length > most { return Err(413) }
    let mut body = vec![0; length];
    reader.read_exact(&mut body).map_err(|_| 400u16)?;
    Ok(body)
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK", 202 => "Accepted", 400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found",
        405 => "Method Not Allowed", 408 => "Request Timeout", 413 => "Content Too Large", 431 => "Request Header Fields Too Large",
        501 => "Not Implemented", 503 => "Service Unavailable", 505 => "HTTP Version Not Supported", _ => "",
    }
}

fn respond(stream: &mut TcpStream, status: u16, extra: &str, body: &str) {
    let kind = if body.starts_with('{') { "application/json" } else { "text/plain; charset=utf-8" };
    let head = format!("HTTP/1.1 {status} {}\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nConnection: close\r\n{extra}\r\n", reason(status), body.len());
    let _ = stream.write_all(head.as_bytes()).and_then(|()| stream.write_all(body.as_bytes())).and_then(|()| stream.flush());
}

/// A JSON-RPC error with no request to answer: what the MCP SDKs send with a 400.
fn rpc_error(code: i32, message: &str) -> String {
    json!({ "jsonrpc": "2.0", "id": null, "error": { "code": code, "message": message } }).to_string()
}

/// The time of day in UTC, as a cloud's logs give it.
fn clock() -> String {
    let s = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs()) % 86_400;
    format!("{:02}:{:02}:{:02} UTC", s / 3600, s / 60 % 60, s % 60)
}

enum Work {
    Call { caller: IpAddr, id: Value, line: String, gone: Arc<AtomicBool>, at: Instant, reply: mpsc::Sender<String> },
    Cancel(IpAddr, Value),
}

/// The tool calls, one at a time, in the order they came. One taken back (by its caller) or whose caller went
/// before its turn isn't begun, and isn't answered; one that waited too long is answered so, and not begun.
fn work(mut server: Server, told: mpsc::Receiver<Work>) {
    let mut waiting: VecDeque<Work> = VecDeque::new();
    while let Some(next) = waiting.pop_front().or_else(|| told.recv().ok()) {
        waiting.extend(told.try_iter());
        let Work::Call { caller, id, line, gone, at, reply } = next else { continue };
        let taken_back = waiting.iter().any(|w| matches!(w, Work::Cancel(c, i) if *c == caller && *i == id));
        if taken_back || gone.load(Ordering::SeqCst) { continue }
        if at.elapsed() > TURN {
            let busy = format!("not begun: another call held the device for more than {} s. Look before trying again", TURN.as_secs());
            let _ = reply.send(json!({ "jsonrpc": "2.0", "id": id, "result": { "content": [{ "type": "text", "text": busy }], "isError": true } }).to_string());
            continue;
        }
        if let Some(answer) = server.handle(&line) { let _ = reply.send(answer); }
    }
}

pub struct Options {
    pub port: u16,
    pub allowed: Vec<Allow>,
    pub token: Option<String>,
    pub devices: Vec<String>,
}

struct Shared {
    options: Options,
    /// Where this listens: what a request's Host has to name.
    own: std::net::SocketAddr,
    /// This machine's address and lasting id on the tailnet: a call from it is this machine's own.
    own_ip: IpAddr,
    own_id: String,
    whois: Box<dyn Fn(IpAddr) -> Result<Whois, String> + Send + Sync>,
    busy: AtomicUsize,
}

/// `roamrunctl mcp --http`: until Ctrl-C.
pub fn serve(options: Options) -> Result<String, String> {
    if options.allowed.is_empty() { return Err("who may call: --allow tag:<name> (a tagged machine, such as a cloud's) or --allow <login> (a person's own machines)".into()) }
    if options.devices.is_empty() { return Err("which devices: roamrunctl mcp --http <port> --allow <who> <device>…   (`roamrunctl devices` lists them)".into()) }
    for name in &options.devices {
        // One only offered by a machine that signs isn't used here yet: whether to believe it is the user's to decide, at a terminal.
        if !crate::device::saved_here(name)? { return Err(format!("{name} isn't saved here: use it once here first (`roamrunctl look {name}`), or name another")) }
    }
    let status = tailscale::status()?;
    let own: Ipv4Addr = status.this.ips.iter().find_map(|a| a.parse().ok()).ok_or("this machine has no IPv4 address on the tailnet")?;
    let listener = TcpListener::bind((own, options.port)).map_err(|e| match e.kind() {
        std::io::ErrorKind::AddrInUse => format!("port {} is taken on {own}", options.port),
        std::io::ErrorKind::AddrNotAvailable => format!("can't listen on {own}: this machine's Tailscale gives it no address of its own to listen on (userspace networking?)"),
        _ => format!("can't listen on {own}:{}: {e}", options.port),
    })?;
    let who: Vec<&str> = options.allowed.iter().map(|a| match a { Allow::Tag(s) | Allow::Login(s) => s.as_str() }).collect();
    note!("roamrunctl: the MCP tools for {} at http://{own}:{}/mcp, for {}{} on the tailnet. Ctrl-C ends it. What is sent and shown passes through whatever lies between (a cloud's proxy sees images and text).",
        options.devices.join(", "), options.port, who.join(", "), if options.token.is_some() { ", with the token" } else { "" });
    run(listener, options, IpAddr::V4(own), status.this.id.clone(), Box::new(tailscale::whois))
}

/// What `serve` does once it listens; `whois` says who a caller is (a test gives its own).
fn run(listener: TcpListener, options: Options, own_ip: IpAddr, own_id: String, whois: Box<dyn Fn(IpAddr) -> Result<Whois, String> + Send + Sync>) -> Result<String, String> {
    let own = listener.local_addr().map_err(|e| e.to_string())?;
    let (tell, told) = mpsc::channel();
    let devices = options.devices.clone();
    std::thread::spawn(move || work(Server::offering(devices), told));
    let shared = Arc::new(Shared { options, own, own_ip, own_id, whois, busy: AtomicUsize::new(0) });
    for stream in listener.incoming() {
        let Ok(mut stream) = stream else { continue };
        if shared.busy.fetch_add(1, Ordering::SeqCst) >= AT_ONCE {
            shared.busy.fetch_sub(1, Ordering::SeqCst);
            respond(&mut stream, 503, "", "too many connections at once\n");
            continue;
        }
        let (shared, tell) = (shared.clone(), tell.clone());
        std::thread::spawn(move || {
            connection(stream, &shared, &tell);
            shared.busy.fetch_sub(1, Ordering::SeqCst);
        });
    }
    Ok(String::new())
}

/// One request, from its head to its answer, and its line in the log. Never logged: the token, a body,
/// what is typed or pasted, what is shown.
fn connection(mut stream: TcpStream, s: &Shared, tell: &mpsc::Sender<Work>) {
    let began = Instant::now();
    let Ok(from) = stream.peer_addr().map(|a| a.ip()) else { return };
    let (mut who, mut what) = ("-".to_string(), "-".to_string());
    let outcome = served(&mut stream, s, tell, from, &mut who, &mut what);
    note!("{} {from} {who} {what} {outcome} {:.1}s", clock(), began.elapsed().as_secs_f64());
}

fn served(stream: &mut TcpStream, s: &Shared, tell: &mpsc::Sender<Work>, from: IpAddr, who: &mut String, what: &mut String) -> String {
    let _ = stream.set_read_timeout(Some(READ));
    let _ = stream.set_write_timeout(Some(READ));
    let Ok(read) = stream.try_clone() else { return "gone".into() };
    let mut reader = BufReader::new(read);
    let mut refuse = |status: u16, extra: &str, body: &str| { respond(stream, status, extra, body); status.to_string() };
    let request = match head(&mut reader) { Ok(request) => request, Err(status) => return refuse(status, "", "") };
    *what = format!("{} {}", request.method, request.path);
    // Where a client looks for OAuth: nothing, before anything is asked of it, so that it doesn't start that.
    if request.path.starts_with("/.well-known/") || request.path == "/register" { return refuse(404, "", "") }
    // A browser's: a page on some site isn't let in by its viewer's place on the tailnet.
    if request.header("origin").is_some() { return refuse(403, "", "") }
    if request.header("host").is_none_or(|host| host != s.own.to_string()) { return refuse(400, "", "the Host isn't this server's address\n") }
    let presented = request.header("authorization").and_then(|v| v.strip_prefix("Bearer "));
    let token = matches!((&s.options.token, presented), (Some(t), Some(p)) if same(t.as_bytes(), p.as_bytes()));
    if s.options.token.is_some() && !token { return refuse(401, "WWW-Authenticate: Bearer\r\n", "") }
    let whois = match (s.whois)(from) {
        Ok(whois) => whois,
        Err(why) => { *who = format!("(whois: {why})"); return refuse(403, "", "") }
    };
    let own = from == s.own_ip || (!s.own_id.is_empty() && whois.node.id == s.own_id);
    match judged(&whois, &s.options.allowed, own, token) {
        Ok(name) => *who = name,
        Err(why) => { *who = why; return refuse(403, "", "") }
    }
    if request.path != "/mcp" { return refuse(404, "", "") }
    if request.method != "POST" { return refuse(405, "Allow: POST\r\n", "") }
    if let Some(version) = request.header("mcp-protocol-version").filter(|v| !VERSIONS.contains(v)) {
        return refuse(400, "", &rpc_error(-32000, &format!("Bad Request: Unsupported protocol version: {version} (supported: {})", VERSIONS.join(", "))));
    }
    if request.header("expect").is_some_and(|e| e.eq_ignore_ascii_case("100-continue")) {
        let _ = stream.write_all(b"HTTP/1.1 100 Continue\r\n\r\n");
    }
    let mut refuse = |status: u16, extra: &str, body: &str| { respond(stream, status, extra, body); status.to_string() };
    let body = match body(&mut reader, &request, BODY) { Ok(body) => body, Err(status) => return refuse(status, "", "") };
    let Ok(message) = serde_json::from_slice::<Value>(&body) else { return refuse(400, "", &rpc_error(-32700, "not JSON")) };
    if !message.is_object() { return refuse(400, "", &rpc_error(-32600, "one message a request, as an object")) }
    let method = message["method"].as_str().unwrap_or("");
    *what = match method {
        "tools/call" => format!("tools/call {}", message["params"]["name"].as_str().unwrap_or("?")),
        "" => "a response".into(),
        method => method.to_string(),
    };
    let Some(id) = message.get("id").cloned().filter(|_| !method.is_empty()) else {
        // A notification or a response: nothing to answer. A call taken back is told to the queue.
        if method == "notifications/cancelled" { let _ = tell.send(Work::Cancel(from, message["params"]["requestId"].clone())); }
        return refuse(202, "", "");
    };
    let line = message.to_string();
    if method != "tools/call" {
        // Asks nothing of a device: answered at once, beside whatever call runs.
        let answer = Server::offering(s.options.devices.clone()).handle(&line).unwrap_or_default();
        return refuse(200, "", &answer);
    }
    let (reply, answered) = mpsc::channel();
    let gone = Arc::new(AtomicBool::new(false));
    if tell.send(Work::Call { caller: from, id, line, gone: gone.clone(), at: Instant::now(), reply }).is_err() { return refuse(503, "", "") }
    loop {
        match answered.recv_timeout(Duration::from_millis(250)) {
            Ok(answer) => {
                let failed = serde_json::from_str::<Value>(&answer).is_ok_and(|a| a["result"]["isError"] == true);
                respond(stream, 200, "", &answer);
                return if failed { "error".into() } else { "ok".into() };
            }
            // Taken back, or the caller went before its turn: not answered.
            Err(mpsc::RecvTimeoutError::Disconnected) => return "not begun".into(),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if closed(stream) { gone.store(true, Ordering::SeqCst); }
            }
        }
    }
}

/// Whether the caller closed its side: nothing more is due from it, so a read that ends says so.
fn closed(stream: &TcpStream) -> bool {
    if stream.set_nonblocking(true).is_err() { return false }
    let ended = matches!(stream.peek(&mut [0u8; 1]), Ok(0));
    let _ = stream.set_nonblocking(false);
    ended
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tailscale::{WhoisNode, WhoisUser};
    use std::net::SocketAddr;

    fn whois(id: &str, tags: &[&str], login: &str, sharer: i64) -> Whois {
        let tags = (!tags.is_empty()).then(|| tags.iter().map(|t| t.to_string()).collect());
        Whois { node: WhoisNode { id: id.into(), tags, sharer }, user: WhoisUser { login: login.into() } }
    }

    #[test]
    fn a_caller_is_let_in_by_its_tag_or_its_login_and_by_nothing_else() {
        assert_eq!(allow("tag:ci"), Ok(Allow::Tag("tag:ci".into())));
        assert_eq!(allow("someone@example.com"), Ok(Allow::Login("someone@example.com".into())));
        // A machine's name can be taken by another: not taken here.
        assert!(allow("laptop").is_err() && allow("tag:").is_err());
        let allowed = [Allow::Tag("tag:ci".into()), Allow::Login("Someone@example.com".into())];
        assert_eq!(judged(&whois("n1", &["tag:ci", "tag:other"], "tagged-devices", 0), &allowed, false, false), Ok("tag:ci,tag:other".into()));
        assert_eq!(judged(&whois("n2", &[], "someone@example.com", 0), &allowed, false, false), Ok("someone@example.com".into()));
        assert!(judged(&whois("n3", &["tag:other"], "tagged-devices", 0), &allowed, false, false).is_err());
        assert!(judged(&whois("n4", &[], "another@example.com", 0), &allowed, false, false).is_err());
        // A tagged machine is nobody's, whatever login it shows.
        assert!(judged(&whois("n5", &["tag:other"], "someone@example.com", 0), &allowed, false, false).is_err());
        // Shared in from another tailnet: refused, tag or not.
        assert!(judged(&whois("n6", &["tag:ci"], "tagged-devices", 7), &allowed, false, true).is_err());
        // This machine itself: any user of it would pass, so only with the token.
        assert!(judged(&whois("own", &[], "someone@example.com", 0), &allowed, true, false).is_err());
        assert!(judged(&whois("own", &[], "someone@example.com", 0), &allowed, true, true).is_ok());
    }

    #[test]
    fn a_token_is_long_on_one_line_and_the_owners_alone() {
        let dir = std::env::temp_dir().join(format!("roamrunctl-token-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("token");
        std::fs::write(&file, "0123456789abcdef0123456789abcdef\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
            assert!(token(&file).unwrap_err().contains("chmod 600"));
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
        }
        assert_eq!(token(&file).as_deref(), Ok("0123456789abcdef0123456789abcdef"));
        std::fs::write(&file, "short").unwrap();
        assert!(token(&file).is_err());
        std::fs::write(&file, "0123456789abcdef 0123456789abcdef").unwrap();
        assert!(token(&file).is_err());
        std::fs::remove_dir_all(&dir).unwrap();
        assert!(same(b"abc", b"abc") && !same(b"abc", b"abd") && !same(b"abc", b"abcd"));
    }

    fn parsed(raw: &str) -> Result<(Request, Vec<u8>), u16> {
        let mut reader = BufReader::new(raw.as_bytes());
        let request = head(&mut reader)?;
        let body = body(&mut reader, &request, 16)?;
        Ok((request, body))
    }

    #[test]
    fn a_body_is_read_as_its_head_frames_it() {
        let (request, body) = parsed("POST http://100.64.0.1:9090/mcp?x=1 HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhelloworld").unwrap();
        assert_eq!((request.method.as_str(), request.path.as_str(), request.header("host"), body.as_slice()), ("POST", "/mcp", Some("h"), &b"hello"[..]));
        // Chunked, and chunked where a length comes too (as a proxy has been seen to send).
        let chunked = "Transfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2;x=y\r\nde\r\n0\r\nTrailer: t\r\n\r\n";
        assert_eq!(parsed(&format!("POST /mcp HTTP/1.1\r\n{chunked}")).unwrap().1, b"abcde");
        assert_eq!(parsed(&format!("POST /mcp HTTP/1.1\r\nContent-Length: 99\r\n{chunked}")).unwrap().1, b"abcde");
        for (raw, status) in [
            ("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello", 400),
            ("POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n", 400),
            ("POST /mcp HTTP/1.1\r\nContent-Length: 17\r\n\r\n", 413),
            ("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n11\r\n", 413),
            ("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nffffffffffffffff\r\n", 413),
            ("POST /mcp HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n", 501),
            ("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\nhel", 400),
            ("POST /mcp HTTP/1.1\r\nNo colon\r\n\r\n", 400),
            ("POST /mcp\r\n\r\n", 400),
            ("POST /mcp HTTP/2\r\n\r\n", 505),
        ] {
            assert_eq!(parsed(raw).err(), Some(status), "{raw:?}");
        }
        assert_eq!(parsed(&format!("POST /mcp HTTP/1.1\r\nX: {}\r\n\r\n", "a".repeat(HEAD))).err(), Some(431));
    }

    /// A server on 127.0.0.1 offering one device, saying who callers are by `whois`.
    fn started(token: Option<&str>, whois: fn(IpAddr) -> Result<Whois, String>) -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let at = listener.local_addr().unwrap();
        let options = Options { port: at.port(), allowed: vec![Allow::Tag("tag:ci".into())], token: token.map(str::to_string), devices: vec!["phone".into()] };
        std::thread::spawn(move || run(listener, options, "100.64.0.1".parse().unwrap(), "own".into(), Box::new(whois)));
        at
    }

    fn ci(_: IpAddr) -> Result<Whois, String> { Ok(whois("n1", &["tag:ci"], "tagged-devices", 0)) }

    /// The whole answer to `raw`, the server having closed the connection.
    fn asked(at: SocketAddr, raw: &str) -> String {
        let mut stream = TcpStream::connect(at).unwrap();
        stream.write_all(raw.as_bytes()).unwrap();
        let mut answer = String::new();
        stream.read_to_string(&mut answer).unwrap();
        answer
    }

    fn post(at: SocketAddr, extra: &str, body: &str) -> String {
        asked(at, &format!("POST /mcp HTTP/1.1\r\nHost: {at}\r\n{extra}Content-Length: {}\r\n\r\n{body}", body.len()))
    }

    #[test]
    fn each_request_is_answered_as_the_transport_has_it() {
        let at = started(None, ci);
        let status = |answer: &str| answer.split(' ').nth(1).unwrap_or("").to_string();
        // Before anything is asked of the caller: where OAuth is looked for, and a browser's request.
        assert_eq!(status(&asked(at, &format!("GET /.well-known/oauth-protected-resource HTTP/1.1\r\nHost: {at}\r\n\r\n"))), "404");
        assert_eq!(status(&post(at, "Origin: http://example.com\r\n", "{}")), "403");
        assert_eq!(status(&post(at, "Origin: null\r\n", "{}")), "403");
        assert_eq!(status(&asked(at, "POST /mcp HTTP/1.1\r\nHost: example.com\r\nContent-Length: 2\r\n\r\n{}")), "400");
        let get = asked(at, &format!("GET /mcp HTTP/1.1\r\nHost: {at}\r\n\r\n"));
        assert!(get.starts_with("HTTP/1.1 405") && get.contains("Allow: POST\r\n") && get.contains("Connection: close\r\n"), "{get}");
        let newer = post(at, "MCP-Protocol-Version: 2026-07-28\r\n", "{}");
        assert!(newer.starts_with("HTTP/1.1 400") && newer.contains("-32000") && newer.contains("2025-11-25"), "{newer}");
        assert_eq!(status(&post(at, "", "[]")), "400");
        assert_eq!(status(&post(at, "", "not json")), "400");
        // Notifications and responses: nothing to answer.
        assert_eq!(status(&post(at, "", r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)), "202");
        assert_eq!(status(&post(at, "", r#"{"jsonrpc":"2.0","id":1,"result":{}}"#)), "202");
        let hello = post(at, "MCP-Protocol-Version: 2025-06-18\r\n", r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#);
        assert!(hello.starts_with("HTTP/1.1 200") && hello.contains(r#""protocolVersion":"2025-06-18""#) && hello.contains("application/json"), "{hello}");
        // No install over HTTP: its path would name a file on this machine for whoever calls.
        let listed = post(at, "", r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#);
        assert!(listed.contains(r#""name":"launch""#) && !listed.contains(r#""name":"install""#), "{listed}");
        let other = post(at, "", r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"look","arguments":{"device":"pad"}}}"#);
        assert!(other.contains("isn't offered here: phone") && other.contains(r#""isError":true"#), "{other}");
        let install = post(at, "", r#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"install","arguments":{"device":"phone","path":"/etc/hosts"}}}"#);
        assert!(install.contains("install isn't offered over HTTP"), "{install}");
        // Chunked with a length too, and Expect: 100-continue answered first.
        let both = asked(at, &format!("POST /mcp HTTP/1.1\r\nHost: {at}\r\nExpect: 100-continue\r\nContent-Length: 999\r\nTransfer-Encoding: chunked\r\n\r\n2a\r\n{}\r\n0\r\n\r\n", r#"{"jsonrpc":"2.0","id":5,"method":"ping"} "#));
        assert!(both.starts_with("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200"), "{both}");
    }

    #[test]
    fn a_call_is_begun_only_while_its_caller_still_wants_it() {
        let (tell, told) = mpsc::channel();
        let call = |caller: &str, id: i64, gone: bool, waited: u64| {
            let (reply, answered) = mpsc::channel();
            let line = json!({ "jsonrpc": "2.0", "id": id, "method": "tools/call", "params": { "name": "look", "arguments": { "device": "pad" } } }).to_string();
            let at = Instant::now().checked_sub(Duration::from_secs(waited)).unwrap();
            tell.send(Work::Call { caller: caller.parse().unwrap(), id: json!(id), line, gone: Arc::new(AtomicBool::new(gone)), at, reply }).unwrap();
            answered
        };
        // All queued before the first has its turn.
        let went = call("100.64.0.2", 1, true, 0);
        let taken_back = call("100.64.0.2", 2, false, 0);
        tell.send(Work::Cancel("100.64.0.2".parse().unwrap(), json!(2))).unwrap();
        // The same id from another caller isn't taken back by it.
        let other = call("100.64.0.3", 2, false, 0);
        let late = call("100.64.0.2", 3, false, TURN.as_secs() + 1);
        let answered = call("100.64.0.2", 4, false, 0);
        drop(tell);
        std::thread::spawn(move || work(Server::offering(vec!["phone".into()]), told));
        let got = |answered: mpsc::Receiver<String>| answered.recv_timeout(Duration::from_secs(10)).ok();
        assert_eq!(got(went), None);
        assert_eq!(got(taken_back), None);
        assert!(got(other).is_some_and(|a| a.contains("isn't offered here")));
        assert!(got(late).is_some_and(|a| a.contains("not begun") && a.contains(r#""id":3"#)));
        assert!(got(answered).is_some_and(|a| a.contains("isn't offered here") && a.contains(r#""id":4"#)));
    }

    #[test]
    fn a_caller_is_let_in_only_as_it_is_allowed() {
        let body = r#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#;
        // A token asked for: none or another is 401 (with nothing that would start OAuth), before Tailscale is asked.
        let at = started(Some("0123456789abcdef0123456789abcdef"), |_| panic!("not asked"));
        let none = post(at, "", body);
        assert!(none.starts_with("HTTP/1.1 401") && none.contains("WWW-Authenticate: Bearer\r\n") && !none.contains("resource_metadata"), "{none}");
        assert!(post(at, "Authorization: Bearer 0123456789abcdef0123456789abcdeX\r\n", body).starts_with("HTTP/1.1 401"));
        // The token alone isn't enough: the caller is still asked about.
        let at = started(Some("0123456789abcdef0123456789abcdef"), |_| Ok(whois("n9", &["tag:other"], "tagged-devices", 0)));
        assert!(post(at, "Authorization: Bearer 0123456789abcdef0123456789abcdef\r\n", body).starts_with("HTTP/1.1 403"));
        let at = started(Some("0123456789abcdef0123456789abcdef"), ci);
        assert!(post(at, "Authorization: Bearer 0123456789abcdef0123456789abcdef\r\n", body).starts_with("HTTP/1.1 200"));
        // Tailscale can't say: refused.
        let at = started(None, |_| Err("no answer".into()));
        assert!(post(at, "", body).starts_with("HTTP/1.1 403"));
        // This machine itself, without a token: refused.
        let at = started(None, |_| Ok(whois("own", &["tag:ci"], "tagged-devices", 0)));
        assert!(post(at, "", body).starts_with("HTTP/1.1 403"));
    }
}
