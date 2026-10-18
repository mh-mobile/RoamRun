//! `roamrunctl mcp --http <port> --allow <who>… <devices>…`: the MCP tools over HTTP — Streamable HTTP as MCP
//! 2025-11-25 has it, every answer JSON, a session given only to take a call back in — on this machine's Tailscale
//! IPv4 address, for the callers Tailscale says are allowed. One request a connection. Tool calls on one device take
//! turns, as over stdio. With `--allow-install`, `PUT /upload` takes an .ipa for `install`.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{IpAddr, Ipv4Addr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

use crate::mcp::{Server, VERSIONS};
use crate::tailscale::{self, Whois};

/// A request's head at most, and a message's body.
const HEAD: usize = 16 * 1024;
const BODY: usize = 1 << 20;
/// For a request's head, from when it connected (before it is known who it is), and then for its body: all of
/// it, not each read — what trickles in is waited for no longer. And for writing an answer.
const HEAD_WITHIN: Duration = Duration::from_secs(10);
const BODY_WITHIN: Duration = Duration::from_secs(30);
const WRITE: Duration = Duration::from_secs(30);
/// Nor is one read waited for longer than this: an upload whose caller went without a word lets go of its slot.
#[cfg(not(test))]
const IDLE: Duration = Duration::from_secs(60);
#[cfg(test)]
const IDLE: Duration = Duration::from_secs(3);
/// Connections served at once (a client opens up to 16, and one more to take a call back), and from one
/// address: more are turned away, so that one machine on the tailnet can't take them all.
const AT_ONCE: usize = 32;
const FROM_ONE: usize = 17;
/// Connections being turned away at once (each answered, then given a moment); more are closed unanswered.
const TURNING_AWAY: usize = 64;
/// A tool call that waited this long for its turn on its device isn't begun: another held the device.
const TURN: Duration = Duration::from_secs(20);
/// A taking back that came in before its call is kept this long for it: each comes on its own connection, and the
/// call's can be the slower (its head, Tailscale's answer and its body take 45 s at most).
const TAKEN_BACK: Duration = Duration::from_secs(60);
/// Of those, no more than this many are kept at once.
const CANCELS: usize = 256;
/// An upload's body is given this long a MiB on top of `BODY_WITHIN`, by its length or, chunked, by the most taken:
/// 200 MiB took 103 s through a cloud's proxy (about 2 MiB a second).
const UPLOAD_MIB_WITHIN: Duration = Duration::from_secs(2);
/// An upload not used this long is dropped.
const UPLOAD_KEPT: Duration = Duration::from_secs(30 * 60);

/// Who may call: tagged machines by a tag, people's own machines by their login.
#[derive(Debug, PartialEq, Clone)]
pub enum Allow {
    Tag(String),
    Login(String),
}

/// `--allow`, as given.
pub fn allow(said: &str) -> Result<Allow, String> {
    // One each: a list in one (tag:a,tag:b) would be one tag nobody has.
    if said.contains(|c: char| c == ',' || c == ';' || c.is_whitespace()) { return Err(format!("--allow {said:?}: one tag or login each; --allow again for another")) }
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

/// What a caller sent, as the log shows it: no control characters (a newline, a terminal's escape), 200 at most.
fn printable(said: &str) -> String {
    said.chars().take(200).map(|c| if c.is_control() { '?' } else { c }).collect()
}

/// The socket, read with a deadline for all that is read, not for each read.
struct Timed {
    stream: TcpStream,
    until: Instant,
}

impl Read for Timed {
    fn read(&mut self, into: &mut [u8]) -> std::io::Result<usize> {
        let left = self.until.checked_duration_since(Instant::now()).filter(|left| !left.is_zero())
            .ok_or_else(|| std::io::Error::from(std::io::ErrorKind::TimedOut))?;
        self.stream.set_read_timeout(Some(left.min(IDLE)))?;
        self.stream.read(into)
    }
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

/// The body as the head frames it, in memory: `framed`.
pub fn body(reader: &mut impl BufRead, request: &Request, most: usize) -> Result<Vec<u8>, u16> {
    let mut body = Vec::new();
    framed(reader, request, most as u64, &mut body)?;
    Ok(body)
}

/// The length the head gives, if it gives one and isn't chunked; 400 where it gives it wrong.
fn length(request: &Request) -> Result<Option<u64>, u16> {
    if request.header("transfer-encoding").is_some() { return Ok(None) }
    let lengths: Vec<&str> = request.headers.iter().filter(|(n, _)| n == "content-length").map(|(_, v)| v.as_str()).collect();
    match lengths.as_slice() {
        [] => Ok(None),
        [one] if !one.is_empty() && one.bytes().all(|b| b.is_ascii_digit()) => one.parse::<u64>().map(Some).map_err(|_| 413u16),
        _ => Err(400),
    }
}

/// The body as the head frames it, into `into`: chunked where it says so (also when a length comes with it, as
/// HTTP has it), else by its one length, else none. `most` bytes at most; its size.
fn framed(reader: &mut impl BufRead, request: &Request, most: u64, into: &mut impl Write) -> Result<u64, u16> {
    if let Some(coding) = request.header("transfer-encoding") {
        if !coding.eq_ignore_ascii_case("chunked") { return Err(501) }
        let mut size = 0u64;
        loop {
            let piece = line(reader, 1024)?;
            let piece = u64::from_str_radix(piece.split(';').next().unwrap_or("").trim(), 16).map_err(|_| 400u16)?;
            if piece == 0 { break }
            if piece > most - size { return Err(413) }
            passed(reader, piece, into)?;
            size += piece;
            if !line(reader, 2)?.is_empty() { return Err(400) }
        }
        // What may trail the last piece: read to the empty line, not used.
        while !line(reader, 1024)?.is_empty() {}
        return Ok(size);
    }
    let length = length(request)?.unwrap_or(0);
    if length > most { return Err(413) }
    passed(reader, length, into)?;
    Ok(length)
}

/// `length` bytes of the body, into `into`: 408 where its time ran out, 400 where it was cut short, 507 where they
/// couldn't be kept.
fn passed(reader: &mut impl BufRead, mut length: u64, into: &mut impl Write) -> Result<(), u16> {
    while length > 0 {
        let some = reader.fill_buf().map_err(late)?;
        if some.is_empty() { return Err(400) }
        let n = some.len().min(usize::try_from(length).unwrap_or(usize::MAX));
        into.write_all(&some[..n]).map_err(|_| 507u16)?;
        reader.consume(n);
        length -= n as u64;
    }
    Ok(())
}

/// A body that stopped coming: 408 where its time ran out, else 400 (cut short).
fn late(e: std::io::Error) -> u16 {
    if matches!(e.kind(), std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock) { 408 } else { 400 }
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK", 202 => "Accepted", 400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found",
        405 => "Method Not Allowed", 408 => "Request Timeout", 409 => "Conflict", 411 => "Length Required", 413 => "Content Too Large",
        431 => "Request Header Fields Too Large", 501 => "Not Implemented", 503 => "Service Unavailable", 505 => "HTTP Version Not Supported",
        507 => "Insufficient Storage", _ => "",
    }
}

fn respond(stream: &mut TcpStream, status: u16, extra: &str, body: &str) {
    let kind = if body.starts_with('{') { "application/json" } else { "text/plain; charset=utf-8" };
    let head = format!("HTTP/1.1 {status} {}\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nConnection: close\r\n{extra}\r\n", reason(status), body.len());
    let _ = stream.write_all(head.as_bytes()).and_then(|()| stream.write_all(body.as_bytes())).and_then(|()| stream.flush());
}

/// A JSON-RPC error, sent with a 400 (with no id where the request can't be read: what the MCP SDKs do).
fn rpc_error(id: Value, code: i32, message: &str) -> String {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } }).to_string()
}

/// The time of day in UTC, as a cloud's logs give it.
fn clock() -> String {
    let s = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs()) % 86_400;
    format!("{:02}:{:02}:{:02} UTC", s / 3600, s / 60 % 60, s % 60)
}

/// An .ipa sent with `PUT /upload`, for one install: its file goes once nothing holds it.
pub struct Upload {
    id: String,
    /// The caller's lasting id on the tailnet: the only one that can install it.
    owner: String,
    sha256: String,
    pub path: PathBuf,
}

impl Drop for Upload {
    fn drop(&mut self) { let _ = std::fs::remove_file(&self.path); }
}

/// The one upload kept (`--allow-install`), in a folder made for this run, the owner's alone. A new one replaces it.
pub struct Uploads {
    folder: PathBuf,
    /// The most taken, in bytes.
    most: u64,
    kept: Mutex<Slot>,
}

#[derive(Default)]
struct Slot {
    /// The upload, and when it was last used.
    kept: Option<(Arc<Upload>, Instant)>,
    /// Whether one is coming in now.
    coming: bool,
}

/// One upload coming in: the slot is free again once it is dropped.
struct Coming<'a>(&'a Uploads);

impl Drop for Coming<'_> {
    fn drop(&mut self) { self.0.slot().coming = false; }
}

/// The bytes written to a file, and their sha256.
struct Hashed { file: std::fs::File, hash: sha2::Sha256 }

impl Write for Hashed {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let n = self.file.write(bytes)?;
        sha2::Digest::update(&mut self.hash, &bytes[..n]);
        Ok(n)
    }
    fn flush(&mut self) -> std::io::Result<()> { self.file.flush() }
}

fn hex(bytes: &[u8]) -> String { bytes.iter().map(|b| format!("{b:02x}")).collect() }

impl Uploads {
    /// The folder made now, in the system's temporary one (on Windows, the user's own, as it is).
    pub fn new(most: u64) -> Result<Arc<Uploads>, String> {
        let folder = std::env::temp_dir().join(format!("roamrunctl-uploads-{}", hex(&crate::hold::random::<8>()?)));
        let mut made = std::fs::DirBuilder::new();
        #[cfg(unix)]
        std::os::unix::fs::DirBuilderExt::mode(&mut made, 0o700);
        made.create(&folder).map_err(|e| format!("{}: {e}", folder.display()))?;
        Ok(Arc::new(Uploads { folder, most, kept: Mutex::default() }))
    }

    fn slot(&self) -> std::sync::MutexGuard<'_, Slot> { self.kept.lock().unwrap_or_else(|e| e.into_inner()) }

    /// The slot for one coming in, the one kept let go of; None while another comes in.
    fn coming(&self) -> Option<Coming<'_>> {
        let mut slot = self.slot();
        if slot.coming { return None }
        slot.kept = None;
        slot.coming = true;
        Some(Coming(self))
    }

    /// The body, into a file of this folder: what is kept and answered, or a status for a body that didn't
    /// all come. What was written of it is gone then.
    fn receive(&self, reader: &mut impl BufRead, request: &Request, owner: &str) -> Result<String, u16> {
        let id = hex(&crate::hold::random::<16>().map_err(|_| 507u16)?);
        let path = self.folder.join(format!("{id}.ipa"));
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        let file = options.open(&path).map_err(|_| 507u16)?;
        // Removed with its file, however this ends.
        let mut upload = Upload { id, owner: owner.to_string(), sha256: String::new(), path };
        let mut into = Hashed { file, hash: <sha2::Sha256 as sha2::Digest>::new() };
        let size = framed(reader, request, self.most, &mut into)?;
        into.flush().map_err(|_| 507u16)?;
        upload.sha256 = hex(&sha2::Digest::finalize(into.hash));
        let answer = json!({ "upload": upload.id, "size": size, "sha256": upload.sha256 }).to_string();
        self.slot().kept = Some((Arc::new(upload), Instant::now()));
        Ok(answer)
    }

    /// Whether `owner` may install the upload `id` it names by `sha256`: before the call waits its turn.
    pub fn check(&self, id: &str, owner: &str, sha256: &str) -> Result<(), String> {
        let mut slot = self.slot();
        match &mut slot.kept {
            Some((upload, used)) if upload.id == id && upload.owner == owner => {
                *used = Instant::now();
                if upload.sha256.eq_ignore_ascii_case(sha256) { Ok(()) } else { Err(format!("sha256 {sha256} isn't upload {id}'s: nothing was installed")) }
            }
            _ => Err(gone(id)),
        }
    }

    /// Where the upload `id`, named by `sha256`, is kept: for what it holds to be checked before it is used up.
    pub fn path(&self, id: &str, sha256: &str) -> Result<PathBuf, String> {
        match &self.slot().kept {
            Some((upload, _)) if upload.id == id && upload.sha256.eq_ignore_ascii_case(sha256) => Ok(upload.path.clone()),
            _ => Err(gone(id)),
        }
    }

    /// The upload `id`, used up by the install that names it by `sha256`, in its turn (`check`ed before).
    pub fn claim(&self, id: &str, sha256: &str) -> Result<Arc<Upload>, String> {
        let mut slot = self.slot();
        match slot.kept.take() {
            Some((upload, _)) if upload.id == id && upload.sha256.eq_ignore_ascii_case(sha256) => Ok(upload),
            other => { slot.kept = other; Err(gone(id)) }
        }
    }

    /// Lets go of the upload not used since `UPLOAD_KEPT` before `now`.
    fn sweep(&self, now: Instant) {
        let mut slot = self.slot();
        if slot.kept.as_ref().is_some_and(|(_, used)| now.duration_since(*used) > UPLOAD_KEPT) { slot.kept = None }
    }

    /// At stop: the folder, and what is in it.
    pub fn end(&self) {
        let _ = std::fs::remove_dir_all(&self.folder);
    }

    /// For tests: `bytes` uploaded by `owner`; the upload's id and sha256.
    #[cfg(test)]
    pub fn put(&self, owner: &str, bytes: &[u8]) -> (String, String) {
        let request = Request { method: "PUT".into(), path: "/upload".into(), headers: vec![("content-length".into(), bytes.len().to_string())] };
        let _coming = self.coming().unwrap();
        let said: Value = serde_json::from_str(&self.receive(&mut &bytes[..], &request, owner).unwrap()).unwrap();
        (said["upload"].as_str().unwrap().into(), said["sha256"].as_str().unwrap().into())
    }
}

fn gone(id: &str) -> String {
    format!("no upload {id} is kept here for you (replaced by a later upload, used by an install, or dropped after {} minutes unused): send it again", UPLOAD_KEPT.as_secs() / 60)
}

/// `mcp --http` as root: refused (by its effective user id). Not checked on Windows.
#[cfg(unix)]
fn not_root(uid: u32) -> Result<(), String> {
    if uid == 0 { Err("not as root: start it as the user whose devices it offers".into()) } else { Ok(()) }
}

/// A tool call on a device, with what it is answered by. `session`: the `Mcp-Session-Id` it came with; `stream`: the
/// caller's connection, looked at as its turn comes.
struct Call { session: Option<String>, id: Value, line: String, stream: TcpStream, at: Instant, reply: mpsc::Sender<String> }

/// What `notifications/cancelled` took back, in a session, and when: (session, request id, when). One list for every
/// device's turn, read as a call's turn comes: a taking back may come before its call (each on its own connection).
type Cancelled = Arc<Mutex<Vec<(String, Value, Instant)>>>;

/// Keeps a taking back a while (an id isn't used twice in a session): CANCELS at most, and more aren't kept, so that a
/// flood doesn't push out another's.
fn take_back(cancelled: &Cancelled, session: &str, id: &Value) {
    let mut cancelled = cancelled.lock().unwrap_or_else(|e| e.into_inner());
    cancelled.retain(|(_, _, at)| at.elapsed() < TAKEN_BACK);
    if cancelled.len() < CANCELS { cancelled.push((session.to_string(), id.clone(), Instant::now())); }
}

/// One device's tool calls, one at a time, in the order they came. One taken back in its session — a client that
/// initialized was given a session id, so another's call of the same id isn't it — or whose caller's connection
/// is closed or broken when its turn comes, isn't begun and isn't answered: what it would have pressed isn't
/// pressed for nobody. One that waited too long is answered so, and not begun.
fn work(mut server: Server, told: mpsc::Receiver<Call>, cancelled: Cancelled) {
    while let Ok(Call { session, id, line, stream, at, reply }) = told.recv() {
        let taken_back = session.as_ref().is_some_and(|session| {
            let mut cancelled = cancelled.lock().unwrap_or_else(|e| e.into_inner());
            cancelled.retain(|(_, _, at)| at.elapsed() < TAKEN_BACK);
            cancelled.iter().any(|(s, i, _)| s == session && *i == id)
        });
        if taken_back || closed(&stream) { continue }
        if at.elapsed() > TURN {
            let busy = format!("not begun: another call held the device for more than {} s. Look before trying again", TURN.as_secs());
            let _ = reply.send(json!({ "jsonrpc": "2.0", "id": id, "result": { "content": [{ "type": "text", "text": busy }], "isError": true } }).to_string());
            continue;
        }
        // A call that fails inside isn't the end of the others: it is answered so, and the next has its turn.
        let answer = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| server.handle(&line))).unwrap_or_else(|_| {
            Some(json!({ "jsonrpc": "2.0", "id": id, "result": { "content": [{ "type": "text", "text": "failed inside roamrunctl: look before trying again" }], "isError": true } }).to_string())
        });
        if let Some(answer) = answer { let _ = reply.send(answer); }
    }
}

pub struct Options {
    pub port: u16,
    pub allowed: Vec<Allow>,
    pub token: Option<String>,
    pub devices: Vec<String>,
    /// `--allow-install`: uploads of this many bytes at most are taken, and `install` is offered.
    pub uploads: Option<u64>,
}

struct Shared {
    options: Options,
    /// The devices offered, each with its saved file as it was when this began (see `Server::offering`).
    offered: Vec<(String, Option<Vec<u8>>)>,
    /// Where a call on each device takes its turn.
    turns: HashMap<String, mpsc::Sender<Call>>,
    /// What was taken back (see `Cancelled`).
    cancelled: Cancelled,
    /// With `--allow-install`.
    uploads: Option<Arc<Uploads>>,
    /// What a request's Host may name (see `hosts`).
    hosts: Vec<String>,
    /// This machine's address and lasting id on the tailnet: a call from it is this machine's own.
    own_ip: IpAddr,
    own_id: String,
    whois: Box<dyn Fn(IpAddr) -> Result<Whois, String> + Send + Sync>,
    /// For a head (`HEAD_WITHIN`; a test gives less).
    head_within: Duration,
    /// Connections open now, from each address.
    open: Mutex<HashMap<IpAddr, usize>>,
    /// Connections being turned away now.
    turning_away: AtomicUsize,
}

/// The devices named, each read as it will be held to: one only offered by a machine that signs isn't used here
/// yet (whether to believe it is the user's to decide, at a terminal), one that can't be read isn't offered, and
/// one device isn't offered under two names — it would have two turns and two latest looks.
fn offerable(devices: &[String]) -> Result<Vec<(String, Option<Vec<u8>>)>, String> {
    let mut at: HashMap<String, &String> = HashMap::new();
    devices.iter().map(|name| {
        let (ip, file) = crate::device::as_saved(name)?;
        if let Some(other) = at.insert(ip.clone(), name) { return Err(format!("{other} and {name} are one device ({ip}): offer it under one name")) }
        Ok((name.clone(), Some(file)))
    }).collect()
}

/// What a request's Host may name: this machine's address, or one of its Tailscale names, with the port — or
/// without it where the port is HTTP's own, as a client then sends it.
fn hosts(ip: IpAddr, names: Vec<String>, port: u16) -> Vec<String> {
    std::iter::once(ip.to_string()).chain(names).flat_map(|host| [Some(format!("{host}:{port}")), (port == 80).then_some(host)]).flatten().collect()
}

/// `roamrunctl mcp --http`: until Ctrl-C.
pub fn serve(options: Options) -> Result<String, String> {
    #[cfg(unix)]
    not_root(roamrun_device::safe::effective_user())?;
    if options.allowed.is_empty() { return Err("who may call: --allow tag:<name> (a tagged machine, such as a cloud's) or --allow <login> (a person's own machines)".into()) }
    if options.devices.is_empty() { return Err("which devices: roamrunctl mcp --http <port> --allow <who> <device>…   (`roamrunctl devices` lists them)".into()) }
    let offered = offerable(&options.devices)?;
    // Asked for what it offers, as it starts: from a device's worker later, nobody would answer.
    crate::secret::ask_no_more();
    let status = tailscale::status()?;
    let own: Ipv4Addr = status.this.ips.iter().find_map(|a| a.parse().ok()).ok_or("this machine has no IPv4 address on the tailnet")?;
    let listener = TcpListener::bind((own, options.port)).map_err(|e| match e.kind() {
        std::io::ErrorKind::AddrInUse => format!("port {} is taken on {own}", options.port),
        std::io::ErrorKind::AddrNotAvailable => format!("can't listen on {own}: this machine's Tailscale gives it no address of its own to listen on (userspace networking?)"),
        _ => format!("can't listen on {own}:{}: {e}", options.port),
    })?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    // At stop, what was uploaded goes with its folder: Ctrl-C, and what a closed terminal sends. Set up before the
    // folder is made, so that a failure here leaves none.
    let uploads = match options.uploads {
        Some(most) => {
            let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())?;
            let mut stop = runtime.block_on(async { crate::stops() })?;
            let uploads = Uploads::new(most)?;
            let (ended, kept) = (uploads.clone(), uploads.clone());
            std::thread::spawn(move || { let _ = runtime.block_on(stop.changed()); ended.end(); std::process::exit(130) });
            std::thread::spawn(move || loop { std::thread::sleep(Duration::from_secs(60)); kept.sweep(Instant::now()) });
            Some(uploads)
        }
        None => None,
    };
    let who: Vec<&str> = options.allowed.iter().map(|a| match a { Allow::Tag(s) | Allow::Login(s) => s.as_str() }).collect();
    note!("roamrunctl: the MCP tools for {} at http://{own}:{port}/mcp, for {} on the tailnet{}{}. Ctrl-C ends it. What is sent and shown passes through whatever lies between (a cloud's proxy sees images and text).",
        options.devices.join(", "), who.join(", "), if options.token.is_some() { ", with the token" } else { "" },
        options.uploads.map_or(String::new(), |most| format!("; install of an .ipa sent to http://{own}:{port}/upload, {} MiB at most", most >> 20)));
    let dns = status.this.dns_name.trim_end_matches('.');
    let names = [dns, tailscale::short(dns)].into_iter().filter(|n| !n.is_empty()).map(str::to_string).collect();
    run(listener, options, offered, IpAddr::V4(own), names, status.this.id.clone(), HEAD_WITHIN, Box::new(tailscale::whois), uploads)
}

/// What `serve` does once it listens; `own_ip`, `names`, `own_id`: this machine on the tailnet (its names, a Host
/// may give); `whois` says who a caller is (a test gives its own).
fn run(listener: TcpListener, options: Options, offered: Vec<(String, Option<Vec<u8>>)>, own_ip: IpAddr, names: Vec<String>, own_id: String, head_within: Duration, whois: Box<dyn Fn(IpAddr) -> Result<Whois, String> + Send + Sync>, uploads: Option<Arc<Uploads>>) -> Result<String, String> {
    let own = listener.local_addr().map_err(|e| e.to_string())?;
    let hosts = hosts(own.ip(), names, own.port());
    // A turn of its own for each device: a call on one doesn't wait for another's.
    let cancelled = Cancelled::default();
    let turns = options.devices.iter().map(|name| {
        let (tell, told) = mpsc::channel();
        let (server, cancelled) = (Server::offering(offered.clone(), uploads.clone()), cancelled.clone());
        std::thread::spawn(move || work(server, told, cancelled));
        (name.clone(), tell)
    }).collect();
    let shared = Arc::new(Shared { options, offered, turns, cancelled, uploads, hosts, own_ip, own_id, whois, head_within, open: Mutex::new(HashMap::new()), turning_away: AtomicUsize::new(0) });
    for stream in listener.incoming() {
        let mut stream = match stream {
            Ok(stream) => stream,
            // Gone before it was taken (Windows says so): the next is taken at once.
            Err(e) if matches!(e.kind(), std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::ConnectionAborted) => continue,
            // Too many files open, say: not tried again at once, over and over.
            Err(_) => { std::thread::sleep(Duration::from_millis(100)); continue }
        };
        let Ok(from) = stream.peer_addr().map(|a| a.ip()) else { continue };
        let taken = {
            let mut open = shared.open.lock().unwrap_or_else(|e| e.into_inner());
            let full = open.values().sum::<usize>() >= AT_ONCE || open.get(&from).is_some_and(|n| *n >= FROM_ONE);
            if !full { *open.entry(from).or_default() += 1; }
            !full
        };
        if !taken {
            // Answered aside, so that waiting for what it sends doesn't hold up the next.
            if shared.turning_away.fetch_add(1, Ordering::SeqCst) < TURNING_AWAY {
                let shared = shared.clone();
                std::thread::spawn(move || {
                    respond(&mut stream, 503, "", "too many connections at once\n");
                    linger(&stream);
                    shared.turning_away.fetch_sub(1, Ordering::SeqCst);
                });
            } else {
                shared.turning_away.fetch_sub(1, Ordering::SeqCst);
            }
            continue;
        }
        let shared = shared.clone();
        std::thread::spawn(move || {
            connection(stream, from, &shared);
            let mut open = shared.open.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(n) = open.get_mut(&from) { *n -= 1; if *n == 0 { open.remove(&from); } }
        });
    }
    Ok(String::new())
}

/// One request, from its head to its answer, and its line in the log. Never logged: the token, a body,
/// what is typed or pasted, what is shown.
fn connection(mut stream: TcpStream, from: IpAddr, s: &Shared) {
    let began = Instant::now();
    let (mut who, mut what) = ("-".to_string(), "-".to_string());
    let outcome = served(&mut stream, s, from, began, &mut who, &mut what);
    note!("{} {from} {} {} {outcome} {:.1}s", clock(), printable(&who), printable(&what), began.elapsed().as_secs_f64());
    linger(&stream);
}

/// What the caller still sends after its answer (a body not read, where it was refused first) is read and
/// dropped for a moment before the connection closes: closed with it unread, the system resets the
/// connection, and the caller can lose the answer it was given.
fn linger(mut stream: &TcpStream) {
    let _ = stream.shutdown(std::net::Shutdown::Write);
    let _ = stream.set_read_timeout(Some(Duration::from_millis(250)));
    let (until, mut left, mut rest) = (Instant::now() + Duration::from_secs(1), BODY, [0u8; 8192]);
    while left > 0 && Instant::now() < until {
        match stream.read(&mut rest) { Ok(0) | Err(_) => break, Ok(read) => left = left.saturating_sub(read) }
    }
}

fn served(stream: &mut TcpStream, s: &Shared, from: IpAddr, began: Instant, who: &mut String, what: &mut String) -> String {
    let _ = stream.set_write_timeout(Some(WRITE));
    let Ok(read) = stream.try_clone() else { return "gone".into() };
    let mut reader = BufReader::new(Timed { stream: read, until: began + s.head_within });
    let mut refuse = |status: u16, extra: &str, body: &str| { respond(stream, status, extra, body); status.to_string() };
    let request = match head(&mut reader) { Ok(request) => request, Err(status) => return refuse(status, "", "") };
    *what = format!("{} {}", request.method, request.path);
    // Where a client looks for OAuth: nothing, before anything is asked of it, so that it doesn't start that.
    if request.path.starts_with("/.well-known/") || request.path == "/register" { return refuse(404, "", "") }
    // A browser's: a page on some site isn't let in by its viewer's place on the tailnet.
    if request.header("origin").is_some() { return refuse(403, "", "") }
    if request.header("host").is_none_or(|host| !s.hosts.iter().any(|h| h.eq_ignore_ascii_case(host))) { return refuse(400, "", "the Host isn't this server's address or name\n") }
    let presented = request.header("authorization").and_then(|v| v.split_once(' ')).filter(|(scheme, _)| scheme.eq_ignore_ascii_case("bearer")).map(|(_, t)| t.trim());
    let token = matches!((&s.options.token, presented), (Some(t), Some(p)) if same(t.as_bytes(), p.as_bytes()));
    if s.options.token.is_some() && !token { return refuse(401, "WWW-Authenticate: Bearer\r\n", "") }
    let whois = match (s.whois)(from) {
        Ok(whois) => whois,
        // Not known to be refused: a 403 would tell the caller not to try again.
        Err(why) => { *who = format!("(whois: {why})"); return refuse(503, "", "the caller couldn't be looked up (tailscale whois): try again\n") }
    };
    let own = from == s.own_ip || (!s.own_id.is_empty() && whois.node.id == s.own_id);
    match judged(&whois, &s.options.allowed, own, token) {
        Ok(name) => *who = name,
        Err(why) => { *who = why; return refuse(403, "", "") }
    }
    if request.path == "/upload" {
        let Some(uploads) = &s.uploads else { return refuse(404, "", "") };
        if request.method != "PUT" { return refuse(405, "Allow: PUT\r\n", "") }
        // Tied to the caller by its lasting id: none, no upload.
        if whois.node.id.is_empty() { return refuse(403, "", "") }
        let length = match length(&request) { Ok(length) => length, Err(status) => return refuse(status, "", "") };
        // Refused before the slot is taken, which lets go of the one kept.
        match request.header("transfer-encoding") {
            Some(coding) if !coding.eq_ignore_ascii_case("chunked") => return refuse(501, "", ""),
            None if length.is_none() => return refuse(411, "", ""),
            _ => {}
        }
        let too_big = format!("{} MiB at most: the server's --max-upload sets it\n", uploads.most >> 20);
        if length.is_some_and(|length| length > uploads.most) { return refuse(413, "", &too_big) }
        let Some(_coming) = uploads.coming() else { return refuse(409, "", "another upload is coming in: try again once it is in\n") };
        let mib = length.unwrap_or(uploads.most).div_ceil(1 << 20);
        reader.get_mut().until = Instant::now() + BODY_WITHIN + UPLOAD_MIB_WITHIN * u32::try_from(mib).unwrap_or(u32::MAX);
        if request.header("expect").is_some_and(|e| e.eq_ignore_ascii_case("100-continue")) {
            let _ = stream.write_all(b"HTTP/1.1 100 Continue\r\n\r\n");
        }
        let (status, answer) = uploads.receive(&mut reader, &request, &whois.node.id).map_or_else(|status| (status, if status == 413 { too_big } else { String::new() }), |answer| (200, answer));
        respond(stream, status, "", &answer);
        return if status == 200 { "ok".into() } else { status.to_string() };
    }
    if request.path != "/mcp" { return refuse(404, "", "") }
    if request.method != "POST" { return refuse(405, "Allow: POST\r\n", "") }
    if let Some(version) = request.header("mcp-protocol-version").filter(|v| !VERSIONS.contains(v)) {
        return refuse(400, "", &rpc_error(Value::Null, -32000, &format!("Bad Request: Unsupported protocol version: {version} (supported: {})", VERSIONS.join(", "))));
    }
    reader.get_mut().until = Instant::now() + BODY_WITHIN;
    if request.header("expect").is_some_and(|e| e.eq_ignore_ascii_case("100-continue")) {
        let _ = stream.write_all(b"HTTP/1.1 100 Continue\r\n\r\n");
    }
    let mut refuse = |status: u16, extra: &str, body: &str| { respond(stream, status, extra, body); status.to_string() };
    let body = match body(&mut reader, &request, BODY) { Ok(body) => body, Err(status) => return refuse(status, "", "") };
    let Ok(message) = serde_json::from_slice::<Value>(&body) else { return refuse(400, "", &rpc_error(Value::Null, -32700, "not JSON")) };
    if !message.is_object() { return refuse(400, "", &rpc_error(Value::Null, -32600, "one message a request, as an object")) }
    let method = message["method"].as_str().unwrap_or("");
    *what = match method {
        "tools/call" => format!("tools/call {}", message["params"]["name"].as_str().unwrap_or("?")),
        "" => "a response".into(),
        method => method.to_string(),
    };
    // Given at initialize (a client that initialized sends it on): what a call is taken back within.
    let session = request.header("mcp-session-id").filter(|s| (1..=128).contains(&s.len()) && s.bytes().all(|b| (0x21..=0x7e).contains(&b))).map(str::to_string);
    let response = method.is_empty() && (message.get("result").is_some() || message.get("error").is_some());
    let Some(id) = message.get("id").cloned().filter(|_| !response) else {
        // A notification or a response: nothing to answer. `notifications/cancelled` takes back the call of that id in
        // its session, on whichever device it waits. Without a session it does nothing — the request id is the
        // client's choosing, and another client's call could have the same — and closing the connection does it.
        let taken = &message["params"]["requestId"];
        if let (true, Some(session)) = (method == "notifications/cancelled" && request_id(taken), &session) {
            take_back(&s.cancelled, session, taken);
        }
        return refuse(202, "", "");
    };
    if method.is_empty() { return refuse(400, "", &rpc_error(id, -32600, "no method")) }
    // An install from another's upload, or one not as it was sent, is refused before it waits its turn.
    let arguments = &message["params"]["arguments"];
    if let (Some(uploads), "tools/call", "install", Some(upload)) = (&s.uploads, method, message["params"]["name"].as_str().unwrap_or(""), arguments["upload"].as_str()) {
        if let Err(why) = uploads.check(upload, &whois.node.id, arguments["sha256"].as_str().unwrap_or("")) {
            refuse(200, "", &json!({ "jsonrpc": "2.0", "id": id, "result": { "content": [{ "type": "text", "text": why }], "isError": true } }).to_string());
            return "error".into();
        }
    }
    let line = message.to_string();
    let turn = (method == "tools/call").then(|| message["params"]["arguments"]["device"].as_str()).flatten().and_then(|name| s.turns.get(name));
    let Some(turn) = turn else {
        // Asks nothing of a device offered (`devices`, `initialize`, a device not offered): answered at once. An
        // initialize is given a session id, sent back with what follows.
        let answer = Server::offering(s.offered.clone(), s.uploads.clone()).handle(&line).unwrap_or_default();
        let given = (method == "initialize").then(|| crate::hold::random::<16>().ok()).flatten()
            .map(|bytes| format!("Mcp-Session-Id: {}\r\n", bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()));
        return refuse(200, given.as_deref().unwrap_or(""), &answer);
    };
    let (reply, answered) = mpsc::channel();
    let Ok(watched) = stream.try_clone() else { return "gone".into() };
    if turn.send(Call { session, id, line, stream: watched, at: Instant::now(), reply }).is_err() { respond(stream, 503, "", ""); return "503".into() }
    match answered.recv() {
        Ok(answer) => {
            let failed = serde_json::from_str::<Value>(&answer).is_ok_and(|a| a["result"]["isError"] == true);
            respond(stream, 200, "", &answer);
            if failed { "error".into() } else { "ok".into() }
        }
        // Taken back in its session, or the caller's connection closed, before its turn: not answered.
        Err(_) => "not begun".into(),
    }
}

/// A request id as MCP has one: a number, or text, and not a long one. A taking back naming another isn't kept.
fn request_id(id: &Value) -> bool {
    id.is_number() || id.as_str().is_some_and(|id| id.len() <= 128)
}

/// Whether the caller's connection is closed or broken. Nothing more is due from a caller once its request is
/// in, so a read that ends, or fails, says so — a caller that only shuts its own side to wait is taken as gone
/// too: that can't be told apart, and a call for nobody isn't made.
fn closed(stream: &TcpStream) -> bool {
    if stream.set_nonblocking(true).is_err() { return true }
    let ended = match stream.peek(&mut [0u8; 1]) {
        Ok(read) => read == 0,
        Err(e) => e.kind() != std::io::ErrorKind::WouldBlock,
    };
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
        assert!(["tag:ci,tag:cloud", "a@example.com b@example.com", "tag:ci\ttag:cloud", "tag:ci;tag:cloud", "a@example.com\nb@example.com"].iter().all(|said| allow(said).is_err()));
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
        // A body whose time ran out, not one cut short.
        struct Late;
        impl Read for Late { fn read(&mut self, _: &mut [u8]) -> std::io::Result<usize> { Err(std::io::ErrorKind::TimedOut.into()) } }
        let mut reader = BufReader::new(b"POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\nhe".chain(Late));
        let request = head(&mut reader).unwrap();
        assert_eq!(super::body(&mut reader, &request, 16).err(), Some(408));
    }

    /// A server on 127.0.0.1 offering one device, saying who callers are by `whois`; this machine is named `mac`.
    fn started(token: Option<&str>, whois: fn(IpAddr) -> Result<Whois, String>) -> SocketAddr {
        started_with(token, whois, None)
    }

    /// The same, taking uploads into `uploads` (`--allow-install`).
    fn started_with(token: Option<&str>, whois: fn(IpAddr) -> Result<Whois, String>, uploads: Option<Arc<Uploads>>) -> SocketAddr {
        started_for(token, whois, uploads, Duration::from_millis(500))
    }

    /// The same, a head given `head_within`.
    fn started_for(token: Option<&str>, whois: fn(IpAddr) -> Result<Whois, String>, uploads: Option<Arc<Uploads>>, head_within: Duration) -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let at = listener.local_addr().unwrap();
        let options = Options { port: at.port(), allowed: vec![Allow::Tag("tag:ci".into())], token: token.map(str::to_string), devices: vec!["phone".into()], uploads: uploads.as_ref().map(|u| u.most) };
        let names = vec!["mac.example.ts.net".into(), "mac".into()];
        std::thread::spawn(move || run(listener, options, vec![("phone".into(), None)], "100.64.0.1".parse().unwrap(), names, "own".into(), head_within, Box::new(whois), uploads));
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
        // An initialize is given a session id; a cancel in one, or in none, is nothing to answer.
        assert!(hello.lines().any(|l| l.starts_with("Mcp-Session-Id: ") && l.len() == "Mcp-Session-Id: ".len() + 32), "{hello}");
        assert!(!post(at, "", r#"{"jsonrpc":"2.0","id":9,"method":"ping"}"#).contains("Mcp-Session-Id"));
        for session in ["Mcp-Session-Id: abc\r\n", ""] {
            assert_eq!(status(&post(at, session, r#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#)), "202");
        }
        // No install over HTTP without --allow-install.
        let listed = post(at, "", r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#);
        assert!(listed.contains(r#""name":"launch""#) && !listed.contains(r#""name":"install"#), "{listed}");
        let other = post(at, "", r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"look","arguments":{"device":"pad"}}}"#);
        assert!(other.contains("isn't offered here: phone") && other.contains(r#""isError":true"#), "{other}");
        let install = post(at, "", r#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"install","arguments":{"device":"phone","path":"/etc/hosts"}}}"#);
        assert!(install.contains("without --allow-install"), "{install}");
        assert_eq!(status(&asked(at, &format!("PUT /upload HTTP/1.1\r\nHost: {at}\r\nContent-Length: 2\r\n\r\nPK"))), "404");
        // Chunked with a length too, and Expect: 100-continue answered first.
        let both = asked(at, &format!("POST /mcp HTTP/1.1\r\nHost: {at}\r\nExpect: 100-continue\r\nContent-Length: 999\r\nTransfer-Encoding: chunked\r\n\r\n2a\r\n{}\r\n0\r\n\r\n", r#"{"jsonrpc":"2.0","id":5,"method":"ping"} "#));
        assert!(both.starts_with("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200"), "{both}");
        // This machine's Tailscale names are its own: not a page's on another site.
        for host in ["mac", "MAC.example.ts.net"] {
            assert_eq!(status(&asked(at, &format!("POST /mcp HTTP/1.1\r\nHost: {host}:{}\r\nContent-Length: 40\r\n\r\n{}", at.port(), r#"{"jsonrpc":"2.0","id":6,"method":"ping"}"#))), "200", "{host}");
        }
        assert_eq!(status(&asked(at, &format!("POST /mcp HTTP/1.1\r\nHost: mac.example.com:{}\r\nContent-Length: 2\r\n\r\n{{}}", at.port()))), "400");
        // A request with no method, which isn't a response, is told so; a response gets nothing.
        let no_method = post(at, "", r#"{"jsonrpc":"2.0","id":7}"#);
        assert!(no_method.starts_with("HTTP/1.1 400") && no_method.contains("-32600") && no_method.contains(r#""id":7"#), "{no_method}");
    }

    #[test]
    fn a_slow_caller_is_given_no_longer_than_its_deadline_and_one_address_not_every_connection() {
        let at = started(None, ci);
        // A byte now and then keeps no read waiting long, but the whole head is due by its deadline.
        let began = Instant::now();
        let mut slow = TcpStream::connect(at).unwrap();
        slow.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
        // Until the answer comes: on Windows, what is sent after the server closed resets the connection, and
        // the answer received with it is lost.
        let (mut answer, mut some) = (Vec::new(), [0u8; 256]);
        for _ in 0..20 {
            if slow.write_all(b"P").is_err() { break }
            if let Ok(read) = slow.read(&mut some) { answer.extend_from_slice(&some[..read]); break }
        }
        slow.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let _ = slow.read_to_end(&mut answer);
        let answer = String::from_utf8_lossy(&answer);
        assert!(answer.starts_with("HTTP/1.1 408") && began.elapsed() < Duration::from_secs(3), "{answer:?} {:?}", began.elapsed());
        // One address holds FROM_ONE connections at most: the next is turned away, once the server has taken them
        // (a busy machine may take a while: they are given a head long enough to be held till then).
        let at = started_for(None, ci, None, Duration::from_secs(10));
        let idle: Vec<TcpStream> = (0..FROM_ONE).map(|_| TcpStream::connect(at).unwrap()).collect();
        let until = Instant::now() + Duration::from_secs(5);
        while !asked(at, "GET / HTTP/1.1\r\n\r\n").starts_with("HTTP/1.1 503") {
            assert!(Instant::now() < until, "one address was never turned away");
            std::thread::sleep(Duration::from_millis(50));
        }
        drop(idle);
    }

    #[test]
    fn a_device_is_offered_only_as_it_can_be_read_and_under_one_name() {
        let (a, b) = (format!("one-{}", std::process::id()), format!("two-{}", std::process::id()));
        crate::device::stub(&a, 49152);
        crate::device::stub(&b, 49152);
        // Not `serve`, which would go on to listen where these checks let it.
        let offer = |devices: &[&String]| offerable(&devices.iter().map(|d| d.to_string()).collect::<Vec<_>>()).unwrap_err();
        // Two names of one device (one address): it would have two turns and two latest looks.
        assert!(offer(&[&a, &b]).contains("are one device"), "{}", offer(&[&a, &b]));
        // One that can't be read as it will be used isn't offered.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let file = crate::device::folder().unwrap().join(format!("{a}.json"));
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
            assert!(offer(&[&a]).contains("can be read by others"));
        }
        crate::device::unstub(&a);
        crate::device::unstub(&b);
        assert!(offer(&[&a]).contains("isn't saved here"));
    }

    #[test]
    fn what_a_caller_sends_is_logged_on_one_line_without_its_control_characters() {
        assert_eq!(printable("tools/call a\nb\u{1b}[2J"), "tools/call a?b?[2J");
        assert_eq!(printable(&"x".repeat(300)).len(), 200);
    }

    /// A connection's two ends: what the server holds, and the caller's (dropped, it is gone).
    fn ends() -> (TcpStream, TcpStream) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let caller = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        (listener.accept().unwrap().0, caller)
    }

    #[test]
    fn a_call_is_begun_only_while_its_caller_still_wants_it() {
        let (tell, told) = mpsc::channel();
        let cancelled = Cancelled::default();
        let mut kept = Vec::new();
        let mut call = |session: Option<&str>, id: i64, gone: bool, waited: u64| {
            let (reply, answered) = mpsc::channel();
            let line = json!({ "jsonrpc": "2.0", "id": id, "method": "tools/call", "params": { "name": "look", "arguments": { "device": "pad" } } }).to_string();
            let at = Instant::now().checked_sub(Duration::from_secs(waited)).unwrap();
            let (stream, theirs) = ends();
            if gone { drop(theirs) } else { kept.push(theirs) }
            tell.send(Call { session: session.map(str::to_string), id: json!(id), line, stream, at, reply }).unwrap();
            answered
        };
        // All queued before the first has its turn.
        let went = call(None, 1, true, 0);
        let late = call(None, 2, false, TURN.as_secs() + 1);
        let answered = call(None, 3, false, 0);
        // Taken back in its session; the same id in another session, or in none, isn't.
        let taken_back = call(Some("a"), 4, false, 0);
        let other = call(Some("b"), 4, false, 0);
        let none = call(None, 4, false, 0);
        take_back(&cancelled, "a", &json!(4));
        // Taken back before the call came in (each on its own connection, the call's the slower): not made either.
        take_back(&cancelled, "c", &json!(5));
        let first = call(Some("c"), 5, false, 0);
        // No more than CANCELS are kept, and a flood of them doesn't push out one kept already.
        for id in 0..=CANCELS as i64 { take_back(&cancelled, "e", &json!(id)); }
        let (kept_first, not_kept) = (call(Some("e"), 0, false, 0), call(Some("e"), CANCELS as i64, false, 0));
        drop(tell);
        std::thread::spawn(move || work(Server::offering(vec![("phone".into(), None)], None), told, cancelled));
        let got = |answered: mpsc::Receiver<String>| answered.recv_timeout(Duration::from_secs(10)).ok();
        assert_eq!(got(went), None);
        assert!(got(late).is_some_and(|a| a.contains("not begun") && a.contains(r#""id":2"#)));
        assert!(got(answered).is_some_and(|a| a.contains("isn't offered here") && a.contains(r#""id":3"#)));
        assert_eq!(got(taken_back), None);
        assert!(got(other).is_some_and(|a| a.contains(r#""id":4"#)));
        assert!(got(none).is_some_and(|a| a.contains(r#""id":4"#)));
        assert_eq!(got(first), None);
        assert_eq!(got(kept_first), None);
        assert!(got(not_kept).is_some_and(|a| a.contains(&format!(r#""id":{CANCELS}"#))));
    }

    #[test]
    fn a_taking_back_is_kept_only_for_an_id_as_mcp_has_one() {
        assert!(request_id(&json!(5)) && request_id(&json!("a-1")));
        assert!(!request_id(&json!("x".repeat(129))) && !request_id(&json!({ "a": 1 })) && !request_id(&Value::Null));
    }

    #[test]
    fn a_host_is_this_machine_with_the_port_or_without_it_where_it_is_80() {
        let ip: IpAddr = "100.64.0.1".parse().unwrap();
        assert_eq!(hosts(ip, vec!["mac".into()], 9090), ["100.64.0.1:9090", "mac:9090"]);
        // HTTP's own port, which a client leaves out.
        assert_eq!(hosts(ip, vec!["mac".into()], 80), ["100.64.0.1:80", "100.64.0.1", "mac:80", "mac"]);
    }

    #[test]
    fn a_request_refused_before_its_body_is_read_still_gets_its_answer() {
        // Closed with the body unread, the connection could be reset before the answer was read.
        let at = started(Some("0123456789abcdef0123456789abcdef"), ci);
        let body = format!(r#"{{"jsonrpc":"2.0","id":1,"method":"ping","params":{{"pad":"{}"}}}}"#, "x".repeat(64 * 1024));
        for _ in 0..40 {
            assert!(post(at, "", &body).starts_with("HTTP/1.1 401"));
            assert!(post(at, "Authorization: Bearer 0123456789abcdef0123456789abcdef\r\nMCP-Protocol-Version: 2026-07-28\r\n", &body).starts_with("HTTP/1.1 400"));
        }
    }

    #[test]
    fn a_caller_is_let_in_only_as_it_is_allowed() {
        let body = r#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#;
        // The token's scheme is taken in any case, as HTTP has it.
        let at = started(Some("0123456789abcdef0123456789abcdef"), ci);
        assert!(post(at, "Authorization: bearer 0123456789abcdef0123456789abcdef\r\n", body).starts_with("HTTP/1.1 200"));
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
        // Tailscale can't say: not let in, and told to try again (a 403 says not to).
        let at = started(None, |_| Err("no answer".into()));
        let unknown = post(at, "", body);
        assert!(unknown.starts_with("HTTP/1.1 503") && unknown.contains("couldn't be looked up"), "{unknown}");
        // This machine itself, without a token: refused.
        let at = started(None, |_| Ok(whois("own", &["tag:ci"], "tagged-devices", 0)));
        assert!(post(at, "", body).starts_with("HTTP/1.1 403"));
    }

    /// Who uploads and installs in `an_install_names_its_own_upload_as_it_was_sent`: n1, or n2 while this is set.
    static AS_N2: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    fn n1_or_n2(_: IpAddr) -> Result<Whois, String> { Ok(whois(if AS_N2.load(Ordering::SeqCst) { "n2" } else { "n1" }, &["tag:ci"], "tagged-devices", 0)) }

    fn put(at: SocketAddr, extra: &str, body: &[u8]) -> String {
        let mut stream = TcpStream::connect(at).unwrap();
        stream.write_all(format!("PUT /upload HTTP/1.1\r\nHost: {at}\r\n{extra}\r\n").as_bytes()).unwrap();
        let _ = stream.write_all(body);
        let mut answer = String::new();
        let _ = stream.read_to_string(&mut answer);
        answer
    }

    fn files(uploads: &Uploads) -> Vec<PathBuf> {
        std::fs::read_dir(&uploads.folder).unwrap().map(|e| e.unwrap().path()).collect()
    }

    #[test]
    fn an_upload_is_taken_only_as_allowed_and_kept_whole_or_not_at_all() {
        let uploads = Uploads::new(64 * 1024).unwrap();
        let at = started_with(None, ci, Some(uploads.clone()));
        let status = |answer: &str| answer.split(' ').nth(1).unwrap_or("").to_string();
        // Checked before its body is taken: the method, a length to go by, the most taken.
        let get = asked(at, &format!("GET /upload HTTP/1.1\r\nHost: {at}\r\n\r\n"));
        assert!(get.starts_with("HTTP/1.1 405") && get.contains("Allow: PUT\r\n"), "{get}");
        assert_eq!(status(&put(at, "", b"")), "411");
        assert_eq!(status(&put(at, "Content-Length: 70000\r\n", b"")), "413");
        // Kept whole: the answer names it by an id, its size and its sha256; a file of the owner's alone.
        let bytes: Vec<u8> = (0..5000u32).map(|i| i as u8).collect();
        let answer = put(at, "Content-Length: 5000\r\nExpect: 100-continue\r\n", &bytes);
        assert!(answer.starts_with("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200"), "{answer}");
        let said: Value = serde_json::from_str(answer.rsplit("\r\n\r\n").next().unwrap()).unwrap();
        let sha256 = hex(&<sha2::Sha256 as sha2::Digest>::digest(&bytes));
        assert_eq!((said["size"].as_u64(), said["sha256"].as_str(), said["upload"].as_str().map(str::len)), (Some(5000), Some(sha256.as_str()), Some(32)));
        assert_eq!(files(&uploads).len(), 1);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&uploads.folder).unwrap().permissions().mode() & 0o777, 0o700);
            assert_eq!(std::fs::metadata(&files(&uploads)[0]).unwrap().permissions().mode() & 0o777, 0o600);
        }
        // Too big by its length, or in a coding not taken: refused before 100 Continue, and the one kept stays.
        let big = put(at, "Content-Length: 70000\r\nExpect: 100-continue\r\n", b"");
        assert!(big.starts_with("HTTP/1.1 413") && big.contains("--max-upload sets it"), "{big}");
        assert_eq!(status(&put(at, "Transfer-Encoding: gzip\r\nExpect: 100-continue\r\n", b"")), "501");
        assert!(uploads.check(said["upload"].as_str().unwrap(), "n1", &sha256).is_ok());
        // Given longer than a head is, by its length: one still coming once the head's time is up is taken.
        let mut slow = TcpStream::connect(at).unwrap();
        slow.write_all(format!("PUT /upload HTTP/1.1\r\nHost: {at}\r\nContent-Length: 3\r\n\r\na").as_bytes()).unwrap();
        std::thread::sleep(Duration::from_millis(700));
        slow.write_all(b"bc").unwrap();
        let mut answer = String::new();
        let _ = slow.read_to_string(&mut answer);
        assert_eq!(status(&answer), "200", "{answer}");
        // Chunked, it replaces the one kept.
        let chunked = put(at, "Transfer-Encoding: chunked\r\n", b"3\r\nabc\r\n0\r\n\r\n");
        assert!(chunked.starts_with("HTTP/1.1 200") && chunked.contains(r#""size":3"#), "{chunked}");
        assert_eq!(files(&uploads).len(), 1);
        assert!(uploads.check(said["upload"].as_str().unwrap(), "n1", &sha256).unwrap_err().contains("no upload"));
        // Cut short, or more than the most chunked: nothing is kept.
        let mut cut = TcpStream::connect(at).unwrap();
        cut.write_all(format!("PUT /upload HTTP/1.1\r\nHost: {at}\r\nContent-Length: 5000\r\n\r\nabc").as_bytes()).unwrap();
        cut.shutdown(std::net::Shutdown::Write).unwrap();
        let mut answer = String::new();
        let _ = cut.read_to_string(&mut answer);
        assert_eq!(status(&answer), "400");
        assert!(files(&uploads).is_empty());
        let over = format!("{:x}\r\n{}\r\n", 70000, "x".repeat(70000));
        let chunked = put(at, "Transfer-Encoding: chunked\r\n", over.as_bytes());
        assert!(status(&chunked) == "413" && chunked.contains("--max-upload sets it"), "{chunked}");
        assert!(files(&uploads).is_empty());
        // One at a time: another while one comes in is turned away.
        let mut coming = TcpStream::connect(at).unwrap();
        coming.write_all(format!("PUT /upload HTTP/1.1\r\nHost: {at}\r\nContent-Length: 5000\r\n\r\nabc").as_bytes()).unwrap();
        std::thread::sleep(Duration::from_millis(200));
        assert_eq!(status(&put(at, "Content-Length: 3\r\n", b"abc")), "409");
        drop(coming);
        // Once the server has seen it go.
        let began = Instant::now();
        while status(&put(at, "Content-Length: 3\r\n", b"abc")) == "409" && began.elapsed() < IDLE { std::thread::sleep(Duration::from_millis(50)) }
        // One that stops coming without a word lets go once nothing came for IDLE, not at its body's deadline.
        let began = Instant::now();
        let mut silent = TcpStream::connect(at).unwrap();
        silent.write_all(format!("PUT /upload HTTP/1.1\r\nHost: {at}\r\nContent-Length: 60000\r\n\r\nabc").as_bytes()).unwrap();
        let mut answer = String::new();
        silent.set_read_timeout(Some(IDLE * 3)).unwrap();
        let _ = silent.read_to_string(&mut answer);
        assert!(status(&answer) == "408" && began.elapsed() < IDLE * 2, "{answer:?} {:?}", began.elapsed());
        assert_eq!(status(&put(at, "Content-Length: 3\r\n", b"abc")), "200");
        // Install is offered.
        let listed = post(at, "", r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#);
        assert!(listed.contains(r#""name":"install""#) && listed.contains(r#""name":"install_status""#) && listed.contains(r#""sha256""#), "{listed}");
        uploads.end();
    }

    #[test]
    fn an_install_names_its_own_upload_as_it_was_sent() {
        let uploads = Uploads::new(64 * 1024).unwrap();
        let at = started_with(None, n1_or_n2, Some(uploads.clone()));
        let answer = put(at, "Content-Length: 3\r\n", b"abc");
        let said: Value = serde_json::from_str(answer.rsplit("\r\n\r\n").next().unwrap()).unwrap();
        let (id, sha256) = (said["upload"].as_str().unwrap(), said["sha256"].as_str().unwrap());
        let install = |sha256: &str| post(at, "", &json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": { "name": "install", "arguments": { "device": "phone", "upload": id, "sha256": sha256 } } }).to_string());
        // Another caller's, or not as it was sent: refused before its turn, and the upload stays.
        AS_N2.store(true, Ordering::SeqCst);
        let other = install(sha256);
        AS_N2.store(false, Ordering::SeqCst);
        assert!(other.contains("no upload") && other.contains(r#""isError":true"#), "{other}");
        assert!(install(&"0".repeat(64)).contains("isn't upload"));
        assert!(uploads.check(id, "n1", sha256).is_ok());
        // Its own, as sent: its turn comes (the device offered here can't be used, which leaves the upload).
        let own = install(&sha256.to_uppercase());
        assert!(own.contains(r#""isError":true"#) && !own.contains("no upload") && !own.contains("isn't upload"), "{own}");
        assert!(uploads.check(id, "n1", sha256).is_ok());
        uploads.end();
    }

    #[test]
    fn an_upload_is_used_up_only_as_it_is_named_and_goes_with_its_last_holder() {
        let uploads = Uploads::new(1024).unwrap();
        let (id, sha256) = uploads.put("n1", b"abc");
        // Named otherwise: it stays.
        assert!(uploads.claim("0", &sha256).is_err() && uploads.path(&id, &sha256).is_ok());
        assert!(uploads.claim(&id, "0").is_err() && uploads.path(&id, &sha256).is_ok());
        // Used up: no longer kept, its file there while the install holds it, gone after.
        let taken = uploads.claim(&id, &sha256.to_uppercase()).unwrap();
        assert!(uploads.path(&id, &sha256).is_err() && taken.path.exists());
        drop(taken);
        assert!(files(&uploads).is_empty());
        uploads.end();
    }

    #[test]
    fn an_upload_not_used_for_half_an_hour_goes_and_all_go_at_stop() {
        let uploads = Uploads::new(1024).unwrap();
        let (id, sha256) = uploads.put("n1", b"abc");
        uploads.sweep(Instant::now() + UPLOAD_KEPT - Duration::from_secs(60));
        assert!(uploads.check(&id, "n1", &sha256).is_ok());
        uploads.sweep(Instant::now() + UPLOAD_KEPT + Duration::from_secs(60));
        assert!(uploads.check(&id, "n1", &sha256).is_err() && files(&uploads).is_empty());
        // Another caller's upload replaces it.
        let (id, sha256) = uploads.put("n1", b"abc");
        uploads.put("n2", b"def");
        assert!(uploads.check(&id, "n1", &sha256).is_err() && files(&uploads).len() == 1);
        uploads.end();
        assert!(!uploads.folder.exists());
    }

    #[test]
    #[cfg(unix)]
    fn it_doesnt_serve_as_root() {
        assert!(not_root(0).is_err() && not_root(501).is_ok());
    }
}
