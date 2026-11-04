//! `roamrunctl view <device> --http <port> --allow <who>`: a prototype. The device's screen stream in a browser on
//! the tailnet, as WebCodecs decodes it, and taps, swipes, keys and buttons back. One page (`view.html`), one
//! WebSocket for each viewer; the stream runs while one watches. The device is this process's alone meanwhile.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{IpAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{mpsc, Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use base64::Engine;
use roamrun_device::safe::Device;
use roamrun_device::watch::{nal_units, Watch};
use serde_json::{json, Value};
use sha1::Digest;

use crate::http::{self, Allow};
use crate::tailscale::Whois;

const PAGE: &str = include_str!("view.html");
/// Connections at once, and from one address.
const AT_ONCE: usize = 8;
const FROM_ONE: usize = 4;
/// For a request's head, each read; and for a viewer's first message.
const HEAD_WITHIN: Duration = Duration::from_secs(10);
/// A viewer whose oldest frame not yet shown is older than this is cut to the next key frame.
const LATE: Duration = Duration::from_millis(500);
/// A message from the page, at most.
const MESSAGE: usize = 64 * 1024;
/// Off: no frame acks and no receiver reports go back to the device (to compare a stream without them).
pub const FEEDBACK: &str = "ROAMRUNCTL_VIEW_FEEDBACK";

/// One access unit as viewers are sent it. `picture`: for a key frame, what the page decodes it with.
struct Sent {
    key: bool,
    at: Instant,
    ms: u64,
    data: Vec<u8>,
    picture: Option<Arc<str>>,
}

/// What a viewer is sent, in order: nothing before a key frame, and once it falls behind, nothing until the next.
struct Queue {
    waiting: VecDeque<Arc<Sent>>,
    /// Written, and not yet acknowledged by the page: by their time, and when they were written.
    flight: VecDeque<(u64, Instant)>,
    key_needed: bool,
    cuts: u32,
}

impl Queue {
    fn new() -> Queue { Queue { waiting: VecDeque::new(), flight: VecDeque::new(), key_needed: true, cuts: 0 } }

    /// Takes a frame from the stream; true where a key frame is to be asked for (this viewer was just cut).
    fn push(&mut self, frame: Arc<Sent>, now: Instant) -> bool {
        let oldest = self.waiting.front().map(|f| f.at).into_iter().chain(self.flight.front().map(|f| f.1)).min();
        let cut = oldest.is_some_and(|at| now.duration_since(at) > LATE);
        if cut {
            self.waiting.clear();
            self.flight.clear();
            self.key_needed = true;
            self.cuts += 1;
        }
        if self.key_needed && !frame.key { return cut }
        self.key_needed = false;
        self.waiting.push_back(frame);
        cut
    }

    fn take(&mut self, now: Instant) -> Option<Arc<Sent>> {
        let frame = self.waiting.pop_front()?;
        self.flight.push_back((frame.ms, now));
        Some(frame)
    }

    /// The page has the frame of time `ms`, and those before it.
    fn acked(&mut self, ms: u64) {
        while self.flight.front().is_some_and(|f| f.0 <= ms) { self.flight.pop_front(); }
    }

    /// The page's decoder failed: nothing until a key frame.
    fn restart(&mut self) {
        self.waiting.clear();
        self.key_needed = true;
    }
}

struct Out {
    queue: Queue,
    texts: VecDeque<String>,
    closed: bool,
}

struct Viewer {
    out: Mutex<Out>,
    ready: Condvar,
}

impl Viewer {
    fn say(&self, text: String) {
        self.out.lock().unwrap_or_else(|e| e.into_inner()).texts.push_back(text);
        self.ready.notify_one();
    }
    fn close(&self) {
        self.out.lock().unwrap_or_else(|e| e.into_inner()).closed = true;
        self.ready.notify_one();
    }
}

/// What a page asks of the device.
#[derive(Debug, PartialEq)]
enum Input {
    Tap(f64, f64),
    Swipe((f64, f64), (f64, f64), u32),
    Type(String),
    Press(String),
}

/// The device's screen as `view` uses it; a test gives its own.
trait Screen: Send + Sync {
    fn watch(&self, wanted: Arc<AtomicBool>) -> Result<Box<dyn Frames>, String>;
    /// The screen's size by the device's word, as a frame is cut to.
    fn size(&self) -> Option<(u32, u32)>;
    fn input(&self, input: &Input) -> Result<(), String>;
}

trait Frames: Send {
    fn frame(&mut self) -> Result<roamrun_device::watch::Frame, String>;
    /// Key frames asked for, and answered.
    fn counts(&self) -> (u32, u32);
}

impl Frames for Watch {
    fn frame(&mut self) -> Result<roamrun_device::watch::Frame, String> { Watch::frame(self) }
    fn counts(&self) -> (u32, u32) { (self.asked, self.answered) }
}

struct OnDevice {
    device: Mutex<Device>,
    feedback: bool,
}

impl Screen for OnDevice {
    fn watch(&self, wanted: Arc<AtomicBool>) -> Result<Box<dyn Frames>, String> {
        let device = self.device.lock().unwrap_or_else(|e| e.into_inner());
        device.watch(self.feedback, wanted).map(|watch| Box::new(watch) as Box<dyn Frames>)
    }
    fn size(&self) -> Option<(u32, u32)> { crate::device::screen_size(&self.device.lock().unwrap_or_else(|e| e.into_inner())) }
    fn input(&self, input: &Input) -> Result<(), String> {
        let device = self.device.lock().unwrap_or_else(|e| e.into_inner());
        crate::device::said(match input {
            Input::Tap(x, y) => device.tap(*x, *y),
            Input::Swipe(from, to, ms) => device.swipe(*from, *to, *ms),
            Input::Type(text) => device.type_text(text),
            Input::Press(button) => device.button(button),
        }).map(|_| ())
    }
}

/// Everything the connections share.
struct Hub {
    viewers: Mutex<Vec<Arc<Viewer>>>,
    joined: Condvar,
    wanted: Arc<AtomicBool>,
    asked: AtomicU32,
    answered: AtomicU32,
    began: Instant,
    feedback: bool,
    allowed: Vec<Allow>,
    token: Option<String>,
    hosts: Vec<String>,
    own_ip: IpAddr,
    own_id: String,
    whois: Box<dyn Fn(IpAddr) -> Result<Whois, String> + Send + Sync>,
    inputs: Mutex<mpsc::Sender<(Arc<Viewer>, Input)>>,
    open: Mutex<std::collections::HashMap<IpAddr, usize>>,
}

impl Hub {
    fn push(&self, frame: Sent) {
        let frame = Arc::new(frame);
        let now = Instant::now();
        for viewer in self.viewers.lock().unwrap_or_else(|e| e.into_inner()).iter() {
            if viewer.out.lock().unwrap_or_else(|e| e.into_inner()).queue.push(frame.clone(), now) { self.wanted.store(true, Ordering::Relaxed) }
            viewer.ready.notify_one();
        }
    }
    fn say(&self, text: &str) {
        for viewer in self.viewers.lock().unwrap_or_else(|e| e.into_inner()).iter() { viewer.say(text.to_string()) }
    }
}

pub struct Options {
    pub device: String,
    pub port: u16,
    pub allowed: Vec<Allow>,
    pub token: Option<String>,
}

/// `roamrunctl view`: until Ctrl-C.
pub fn serve(options: Options) -> Result<String, String> {
    #[cfg(unix)]
    http::not_root(roamrun_device::safe::effective_user())?;
    if options.allowed.is_empty() { return Err("who may watch: --allow <login> (your own machines), or --allow tag:<name>".into()) }
    let device = crate::device::opened(&options.device)?;
    let (listener, status, own, names) = http::listen(options.port)?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    // The stream stopped at Ctrl-C, not left listed on the device as screen sharing.
    crate::at_stop()?.then(|| {});
    let feedback = std::env::var(FEEDBACK).map_or(true, |v| v != "off");
    note!("roamrunctl: {}'s screen at http://{own}:{port}/ (a prototype), for {} on the tailnet{}{}. The page needs WebCodecs, which a browser offers only to a secure page: see `roamrunctl view --help`. Ctrl-C ends it.",
        options.device, options.allowed.iter().map(|a| match a { Allow::Tag(s) | Allow::Login(s) => s.as_str() }).collect::<Vec<_>>().join(", "),
        if options.token.is_some() { ", with the token" } else { "" }, if feedback { "" } else { "; no frame acks or receiver reports to the device" });
    let screen = Arc::new(OnDevice { device: Mutex::new(device), feedback });
    run(listener, screen, options.allowed, options.token, http::hosts(IpAddr::V4(own), names, port), IpAddr::V4(own), status.this.id.clone(), feedback, Box::new(crate::tailscale::whois))
}

#[allow(clippy::too_many_arguments)]
fn run(listener: TcpListener, screen: Arc<dyn Screen>, allowed: Vec<Allow>, token: Option<String>, hosts: Vec<String>, own_ip: IpAddr, own_id: String, feedback: bool,
       whois: Box<dyn Fn(IpAddr) -> Result<Whois, String> + Send + Sync>) -> Result<String, String> {
    let (inputs, asked) = mpsc::channel::<(Arc<Viewer>, Input)>();
    let hub = Arc::new(Hub {
        viewers: Mutex::new(Vec::new()), joined: Condvar::new(), wanted: Arc::new(AtomicBool::new(false)), asked: AtomicU32::new(0), answered: AtomicU32::new(0),
        began: Instant::now(), feedback, allowed, token, hosts, own_ip, own_id, whois, inputs: Mutex::new(inputs), open: Mutex::new(Default::default()),
    });
    // Inputs one at a time, on a thread of their own: a long `type` doesn't hold up what the page acknowledges.
    let device = screen.clone();
    std::thread::spawn(move || {
        for (viewer, input) in asked {
            let began = Instant::now();
            let what = match &input { Input::Tap(..) => "tap", Input::Swipe(..) => "swipe", Input::Type(_) => "type", Input::Press(_) => "press" };
            viewer.say(match device.input(&input) {
                Ok(()) => json!({ "type": "done", "what": what, "ms": began.elapsed().as_millis() as u64 }),
                Err(why) => json!({ "type": "error", "what": what, "error": why }),
            }.to_string());
        }
    });
    let pumped = hub.clone();
    std::thread::Builder::new().stack_size(8 << 20).spawn(move || pump(&pumped, screen.as_ref())).map_err(|e| e.to_string())?;
    for stream in listener.incoming() {
        let Ok(stream) = stream else { std::thread::sleep(Duration::from_millis(100)); continue };
        let Ok(from) = stream.peer_addr().map(|a| a.ip()) else { continue };
        {
            let mut open = hub.open.lock().unwrap_or_else(|e| e.into_inner());
            // Closed unanswered: one machine doesn't take them all.
            if open.values().sum::<usize>() >= AT_ONCE || open.get(&from).is_some_and(|n| *n >= FROM_ONE) { continue }
            *open.entry(from).or_default() += 1;
        }
        let hub = hub.clone();
        std::thread::spawn(move || {
            let began = Instant::now();
            let (mut who, mut what) = ("-".to_string(), "-".to_string());
            let outcome = connection(stream, from, &hub, &mut who, &mut what);
            note!("{} {from} {} {} {outcome} {:.1}s", http::clock(), http::printable(&who), what, began.elapsed().as_secs_f64());
            let mut open = hub.open.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(n) = open.get_mut(&from) { *n -= 1; if *n == 0 { open.remove(&from); } }
        });
    }
    Ok(String::new())
}

/// While anyone watches: the stream, to each viewer. Once nobody does, it is let go of (and the device stops it).
fn pump(hub: &Hub, screen: &dyn Screen) {
    // What the last key frame said (its codec and size), and what the page was told of it.
    let mut picture: Option<(Described, Arc<str>)> = None;
    loop {
        {
            let mut viewers = hub.viewers.lock().unwrap_or_else(|e| e.into_inner());
            while viewers.is_empty() { viewers = hub.joined.wait(viewers).unwrap_or_else(|e| e.into_inner()); }
        }
        let mut frames = match screen.watch(hub.wanted.clone()) {
            Ok(frames) => frames,
            Err(why) => {
                hub.say(&json!({ "type": "status", "text": format!("the stream didn't start: {why}") }).to_string());
                std::thread::sleep(Duration::from_secs(2));
                continue;
            }
        };
        while !hub.viewers.lock().unwrap_or_else(|e| e.into_inner()).is_empty() {
            let frame = match frames.frame() {
                Ok(frame) => frame,
                Err(why) => { hub.say(&json!({ "type": "status", "text": format!("the stream stopped ({why}): starting it again") }).to_string()); break }
            };
            let (asked, answered) = frames.counts();
            hub.asked.store(asked, Ordering::Relaxed);
            hub.answered.store(answered, Ordering::Relaxed);
            let said = if frame.key { described(&frame.data) } else { None };
            if let Some(said) = said {
                if picture.as_ref().is_none_or(|(was, _)| *was != said) {
                    let crop = crate::device::fit(said.1, screen.size()).unwrap_or(said.1);
                    let text = json!({ "type": "picture", "codec": said.0, "width": said.1.0, "height": said.1.1, "crop": [crop.0, crop.1] }).to_string();
                    picture = Some((said, text.into()));
                }
            }
            let ms = hub.began.elapsed().as_millis() as u64;
            hub.push(Sent { key: frame.key, at: Instant::now(), ms, picture: frame.key.then(|| picture.as_ref().map(|p| p.1.clone())).flatten(), data: frame.data });
        }
    }
}

/// One connection: the page, or a viewer's WebSocket. What is shown or typed is never logged.
fn connection(stream: TcpStream, from: IpAddr, hub: &Hub, who: &mut String, what: &mut String) -> String {
    let _ = stream.set_read_timeout(Some(HEAD_WITHIN));
    let Ok(mut writer) = stream.try_clone() else { return "gone".into() };
    let mut reader = BufReader::new(stream);
    let refuse = |writer: &mut TcpStream, status: u16| { answer(writer, status, "text/plain; charset=utf-8", ""); status.to_string() };
    let request = match http::head(&mut reader) { Ok(request) => request, Err(status) => return refuse(&mut writer, status) };
    *what = format!("{} {}", http::printable(&request.method), http::printable(&request.path));
    let Some(host) = request.header("host").filter(|host| hub.hosts.iter().any(|h| h.eq_ignore_ascii_case(host))) else { return refuse(&mut writer, 400) };
    // A page of this server's own, or none (the page itself, opened): not one of another site.
    let own_origin = format!("http://{host}");
    let socket = request.path == "/ws";
    match request.header("origin") {
        Some(origin) if origin.eq_ignore_ascii_case(&own_origin) => {}
        None if !socket => {}
        _ => return refuse(&mut writer, 403),
    }
    if request.method != "GET" { return refuse(&mut writer, 405) }
    if !socket && request.path != "/" { return refuse(&mut writer, 404) }
    let whois = match (hub.whois)(from) {
        Ok(whois) => whois,
        Err(why) => { *who = format!("(whois: {why})"); return refuse(&mut writer, 503) }
    };
    let own = from == hub.own_ip || (!hub.own_id.is_empty() && whois.node.id == hub.own_id);
    // This machine's own users take the token: they are let in to the page, and asked for it in the first message.
    match http::judged(&whois, &hub.allowed, own, own && hub.token.is_some() || !socket) {
        Ok(name) => *who = name,
        Err(why) => { *who = why; return refuse(&mut writer, 403) }
    }
    if !socket {
        answer(&mut writer, 200, "text/html; charset=utf-8", PAGE);
        return "ok".into();
    }
    let key = request.header("sec-websocket-key").filter(|k| k.len() == 24);
    let upgrade = request.header("upgrade").is_some_and(|u| u.eq_ignore_ascii_case("websocket")) && request.header("sec-websocket-version") == Some("13");
    let (Some(key), true) = (key, upgrade) else { return refuse(&mut writer, 400) };
    let head = format!("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {}\r\n\r\n", accept_key(key));
    if writer.write_all(head.as_bytes()).is_err() { return "gone".into() }
    let _ = writer.set_nodelay(true);
    // The first message within HEAD_WITHIN, with the token where one is given.
    let hello = match read_message(&mut reader) {
        Ok(Message::Text(text)) => serde_json::from_str::<Value>(&text).unwrap_or_default(),
        _ => return "no hello".into(),
    };
    let presented = hello["token"].as_str().unwrap_or("");
    if hello["type"] != "hello" || hub.token.as_ref().is_some_and(|t| !http::same(t.as_bytes(), presented.as_bytes())) {
        let _ = writer.write_all(&ws_frame(8, &[0x03, 0xf0]));   // 1008: refused
        return "token refused".into();
    }
    // A stream isn't cut for being quiet, or slow to take what is written.
    let _ = reader.get_ref().set_read_timeout(None);
    let _ = writer.set_write_timeout(None);
    let viewer = Arc::new(Viewer { out: Mutex::new(Out { queue: Queue::new(), texts: VecDeque::new(), closed: false }), ready: Condvar::new() });
    viewer.say(json!({ "type": "hello", "feedback": hub.feedback }).to_string());
    hub.viewers.lock().unwrap_or_else(|e| e.into_inner()).push(viewer.clone());
    hub.wanted.store(true, Ordering::Relaxed);
    hub.joined.notify_all();
    let ended = std::thread::scope(|scope| {
        scope.spawn(|| write_to(&mut writer, &viewer, hub));
        let ended = read_from(&mut reader, &viewer, hub);
        viewer.close();
        let _ = reader.get_ref().shutdown(std::net::Shutdown::Both);
        ended
    });
    hub.viewers.lock().unwrap_or_else(|e| e.into_inner()).retain(|v| !Arc::ptr_eq(v, &viewer));
    ended
}

fn answer(stream: &mut TcpStream, status: u16, kind: &str, body: &str) {
    let reason = match status { 200 => "OK", 400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found", 405 => "Method Not Allowed", 503 => "Service Unavailable", _ => "" };
    let head = format!("HTTP/1.1 {status} {reason}\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", body.len());
    let _ = stream.write_all(head.as_bytes()).and_then(|()| stream.write_all(body.as_bytes()));
}

/// What the page sends, until it closes.
fn read_from(reader: &mut impl BufRead, viewer: &Arc<Viewer>, hub: &Hub) -> String {
    loop {
        let text = match read_message(reader) {
            Ok(Message::Text(text)) => text,
            Ok(Message::Close) => return "closed".into(),
            Ok(Message::Other) => continue,
            Err(why) => return why,
        };
        let message: Value = serde_json::from_str(&text).unwrap_or_default();
        match message["type"].as_str().unwrap_or("") {
            "ack" => if let Some(ms) = message["t"].as_u64() { viewer.out.lock().unwrap_or_else(|e| e.into_inner()).queue.acked(ms) },
            "keyframe" => {
                viewer.out.lock().unwrap_or_else(|e| e.into_inner()).queue.restart();
                hub.wanted.store(true, Ordering::Relaxed);
            }
            _ => match input(&message) {
                Ok(input) => { let _ = hub.inputs.lock().unwrap_or_else(|e| e.into_inner()).send((viewer.clone(), input)); }
                Err(why) => viewer.say(json!({ "type": "error", "what": message["type"], "error": why }).to_string()),
            },
        }
    }
}

/// What the page asked for, checked before it goes to the device.
fn input(message: &Value) -> Result<Input, String> {
    let at = |key: &str| message[key].as_f64().filter(|v| (0.0..=1.0).contains(v)).ok_or(format!("{key}: a number within 0...1"));
    let word = |key: &str| message[key].as_str().filter(|s| !s.is_empty() && s.len() <= 2000).map(str::to_string).ok_or(format!("{key}: some text"));
    match message["type"].as_str().unwrap_or("") {
        "tap" => Ok(Input::Tap(at("x")?, at("y")?)),
        "swipe" => {
            let ms = message["ms"].as_u64().filter(|ms| (50..=5000).contains(ms)).ok_or("ms: 50...5000")?;
            Ok(Input::Swipe((at("x1")?, at("y1")?), (at("x2")?, at("y2")?), ms as u32))
        }
        "type" => Ok(Input::Type(word("text")?)),
        "press" => Ok(Input::Press(word("button")?)),
        other => Err(format!("nothing is done for {:?}", http::printable(other))),
    }
}

/// To the page: what is said, then frames as they come; the counts once a second.
fn write_to(writer: &mut TcpStream, viewer: &Viewer, hub: &Hub) {
    let mut picture: Option<Arc<str>> = None;
    let mut counted = Instant::now();
    loop {
        let (texts, frame, cuts) = {
            let mut out = viewer.out.lock().unwrap_or_else(|e| e.into_inner());
            while !out.closed && out.texts.is_empty() && out.queue.waiting.is_empty() && counted.elapsed() < Duration::from_secs(1) {
                out = viewer.ready.wait_timeout(out, Duration::from_secs(1)).unwrap_or_else(|e| e.into_inner()).0;
            }
            if out.closed { return }
            let texts: Vec<String> = out.texts.drain(..).collect();
            (texts, out.queue.take(Instant::now()), out.queue.cuts)
        };
        let mut bytes = Vec::new();
        for text in texts { bytes.extend(ws_frame(1, text.as_bytes())) }
        if counted.elapsed() >= Duration::from_secs(1) {
            counted = Instant::now();
            let counts = json!({ "type": "counts", "keyframesAsked": hub.asked.load(Ordering::Relaxed), "keyframesAnswered": hub.answered.load(Ordering::Relaxed), "cuts": cuts });
            bytes.extend(ws_frame(1, counts.to_string().as_bytes()));
        }
        if let Some(frame) = frame {
            if let Some(said) = frame.picture.as_ref().filter(|said| picture.as_ref() != Some(said)) {
                bytes.extend(ws_frame(1, said.as_bytes()));
                picture = Some(said.clone());
            }
            bytes.extend(ws_frame(2, &frame_message(frame.key, frame.ms, &frame.data)));
        }
        if writer.write_all(&bytes).is_err() {
            // The page's reader ends with it.
            let _ = writer.shutdown(std::net::Shutdown::Both);
            return;
        }
    }
}

/// A frame as the page reads it: a flag byte (1: a key frame), the server's time in ms (8 bytes, big-endian), the
/// access unit.
fn frame_message(key: bool, ms: u64, data: &[u8]) -> Vec<u8> {
    let mut message = Vec::with_capacity(9 + data.len());
    message.push(key as u8);
    message.extend_from_slice(&ms.to_be_bytes());
    message.extend_from_slice(data);
    message
}

/// RFC 6455's answer to a WebSocket's key.
fn accept_key(key: &str) -> String {
    let digest = sha1::Sha1::digest(format!("{key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11").as_bytes());
    base64::engine::general_purpose::STANDARD.encode(digest)
}

/// A frame of this server's: final, unmasked.
fn ws_frame(opcode: u8, payload: &[u8]) -> Vec<u8> {
    let mut frame = vec![0x80 | opcode];
    match payload.len() {
        n if n < 126 => frame.push(n as u8),
        n if n <= 0xffff => { frame.push(126); frame.extend_from_slice(&(n as u16).to_be_bytes()) }
        n => { frame.push(127); frame.extend_from_slice(&(n as u64).to_be_bytes()) }
    }
    frame.extend_from_slice(payload);
    frame
}

#[derive(Debug, PartialEq)]
enum Message {
    Text(String),
    Close,
    /// Binary, ping, pong: nothing the page sends that is used.
    Other,
}

/// One message of the page's: masked, whole (not in pieces), `MESSAGE` bytes at most.
fn read_message(reader: &mut impl Read) -> Result<Message, String> {
    let mut head = [0u8; 2];
    reader.read_exact(&mut head).map_err(|_| "gone".to_string())?;
    let (last, opcode, masked) = (head[0] & 0x80 != 0, head[0] & 0x0f, head[1] & 0x80 != 0);
    let length = match head[1] & 0x7f {
        126 => { let mut n = [0u8; 2]; reader.read_exact(&mut n).map_err(|_| "gone")?; u16::from_be_bytes(n) as u64 }
        127 => { let mut n = [0u8; 8]; reader.read_exact(&mut n).map_err(|_| "gone")?; u64::from_be_bytes(n) }
        n => n as u64,
    };
    if !masked { return Err("an unmasked message".into()) }
    if !last || opcode == 0 { return Err("a message in pieces".into()) }
    if length > MESSAGE as u64 { return Err("a message too long".into()) }
    let mut mask = [0u8; 4];
    reader.read_exact(&mut mask).map_err(|_| "gone")?;
    let mut payload = vec![0u8; length as usize];
    reader.read_exact(&mut payload).map_err(|_| "gone")?;
    for (i, b) in payload.iter_mut().enumerate() { *b ^= mask[i % 4] }
    Ok(match opcode {
        1 => Message::Text(String::from_utf8(payload).map_err(|_| "text that isn't UTF-8")?),
        8 => Message::Close,
        _ => Message::Other,
    })
}

type Described = (String, (u32, u32));

/// A key frame's codec string (as WebCodecs takes it) and picture size inside its conformance window, from its SPS.
fn described(annexb: &[u8]) -> Option<Described> {
    let sps = nal_units(annexb).find(|nal| (nal[0] >> 1) & 0x3f == 33)?;
    let (mut rbsp, mut zeros) = (Vec::with_capacity(sps.len()), 0);
    for &b in &sps[2..] {
        // An emulation prevention byte: 00 00 03 is 00 00.
        if b == 3 && zeros >= 2 { zeros = 0; continue }
        zeros = if b == 0 { zeros + 1 } else { 0 };
        rbsp.push(b);
    }
    let mut bits = Bits { data: &rbsp, at: 0 };
    bits.read(4)?;
    let sub_layers = bits.read(3)? as usize;
    bits.read(1)?;
    let (space, tier, profile, compatible) = (bits.read(2)? as usize, bits.read(1)?, bits.read(5)?, bits.read(32)? as u32);
    let constraints: Vec<u8> = (0..6).map(|_| bits.read(8).map(|b| b as u8)).collect::<Option<_>>()?;
    let level = bits.read(8)?;
    let present: Vec<(u64, u64)> = (0..sub_layers).map(|_| Some((bits.read(1)?, bits.read(1)?))).collect::<Option<_>>()?;
    if sub_layers > 0 { for _ in sub_layers..8 { bits.read(2)?; } }
    for (profile, level) in present { bits.read(88 * profile as u32)?; bits.read(8 * level as u32)?; }
    bits.ue()?;
    let chroma = bits.ue()?;
    let separate = chroma == 3 && bits.read(1)? == 1;
    let (width, height) = (bits.ue()?, bits.ue()?);
    let (w, h) = match chroma { 1 if !separate => (2, 2), 2 => (2, 1), _ => (1, 1) };
    let window = if bits.read(1)? == 1 { [bits.ue()?, bits.ue()?, bits.ue()?, bits.ue()?] } else { [0; 4] };
    let size = (width.checked_sub(w * (window[0] + window[1]))?, height.checked_sub(h * (window[2] + window[3]))?);
    let mut codec = format!("hev1.{}{profile}.{:X}.{}{level}", ["", "A", "B", "C"][space], compatible.reverse_bits(), if tier == 1 { 'H' } else { 'L' });
    let kept = constraints.iter().rposition(|b| *b != 0).map_or(0, |i| i + 1);
    for b in &constraints[..kept] { codec.push_str(&format!(".{b:X}")) }
    Some((codec, size))
}

struct Bits<'a> {
    data: &'a [u8],
    at: usize,
}

impl Bits<'_> {
    /// `n` bits as a number (those beyond 64 are read past).
    fn read(&mut self, n: u32) -> Option<u64> {
        (0..n).try_fold(0u64, |value, _| {
            let bit = (*self.data.get(self.at / 8)? >> (7 - self.at % 8)) & 1;
            self.at += 1;
            Some(value << 1 | bit as u64)
        })
    }
    /// Exp-Golomb.
    fn ue(&mut self) -> Option<u32> {
        let mut zeros = 0;
        while self.read(1)? == 0 {
            zeros += 1;
            if zeros > 31 { return None }
        }
        Some(((1u64 << zeros) - 1 + self.read(zeros)?) as u32)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tailscale::{WhoisNode, WhoisUser};

    fn sent(key: bool, at: Instant, ms: u64) -> Arc<Sent> { Arc::new(Sent { key, at, ms, data: vec![], picture: None }) }

    #[test]
    fn a_viewer_waits_for_a_key_frame_and_once_behind_is_cut_to_the_next() {
        let t = Instant::now();
        let mut queue = Queue::new();
        // Joined: nothing until a key frame.
        assert!(!queue.push(sent(false, t, 1), t));
        assert!(queue.take(t).is_none());
        assert!(!queue.push(sent(true, t, 2), t));
        assert!(!queue.push(sent(false, t, 3), t));
        assert_eq!(queue.take(t).unwrap().ms, 2);
        // Written, and acknowledged in time: on it goes.
        let later = t + Duration::from_millis(400);
        queue.acked(2);
        assert!(!queue.push(sent(false, later, 4), later));
        // Frame 3 has waited more than LATE: cut, a key frame asked for, nothing until one comes.
        let late = t + Duration::from_millis(600);
        assert!(queue.push(sent(false, late, 5), late));
        assert!(queue.take(late).is_none());
        assert!(!queue.push(sent(false, late, 6), late));
        assert!(!queue.push(sent(true, late, 7), late));
        assert_eq!(queue.take(late).unwrap().ms, 7);
        assert_eq!(queue.cuts, 1);
        // Written and not acknowledged for longer than LATE (the page's link is slow): cut too.
        let slow = late + Duration::from_millis(501);
        assert!(queue.push(sent(true, slow, 8), slow));
        assert_eq!(queue.take(slow).unwrap().ms, 8);
        // A decoder that failed: nothing until a key frame.
        queue.restart();
        assert!(!queue.push(sent(false, slow, 9), slow));
        assert!(queue.take(slow).is_none());
    }

    #[test]
    fn the_codec_and_size_come_from_the_sps() {
        // x265's SPS of a 1180 x 2556 picture (coded 1184 x 2560), Main, level 5: emulation prevention bytes in it.
        let sps = "420101016000000300900000030000030096a00250800a01dde5959a4932bc05a02000000300200000030021";
        let mut annexb = vec![0, 0, 0, 1, 0x40, 0x01, 0x0c, 0, 0, 0, 1];
        annexb.extend((0..sps.len()).step_by(2).map(|i| u8::from_str_radix(&sps[i..i + 2], 16).unwrap()));
        annexb.extend([0, 0, 1, 0x26, 0x01, 0xaf]);
        assert_eq!(described(&annexb), Some(("hev1.1.6.L150.90".to_string(), (1180, 2556))));
        assert_eq!(described(&[0, 0, 1, 0x26, 0x01, 0xaf]), None);
    }

    #[test]
    fn a_frame_is_its_flag_the_time_and_the_unit() {
        assert_eq!(frame_message(true, 0x0102, &[7, 8]), [1, 0, 0, 0, 0, 0, 0, 1, 2, 7, 8]);
        assert_eq!(frame_message(false, 5, &[])[0], 0);
    }

    #[test]
    fn websocket_frames_and_the_handshake_are_as_rfc_6455_has_them() {
        // The RFC's own example.
        assert_eq!(accept_key("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
        assert_eq!(ws_frame(1, b"hi"), [0x81, 2, b'h', b'i']);
        assert_eq!(&ws_frame(2, &[0; 200])[..4], [0x82, 126, 0, 200]);
        assert_eq!(&ws_frame(2, &[0; 70000])[..10], [0x82, 127, 0, 0, 0, 0, 0, 1, 0x11, 0x70]);
        let masked = |opcode: u8, last: bool, text: &[u8]| {
            let mask = [1, 2, 3, 4];
            let mut frame = vec![if last { 0x80 } else { 0 } | opcode, 0x80 | text.len() as u8];
            frame.extend(mask);
            frame.extend(text.iter().enumerate().map(|(i, b)| b ^ mask[i % 4]));
            frame
        };
        assert_eq!(read_message(&mut &masked(1, true, b"{\"type\":\"ack\"}")[..]), Ok(Message::Text("{\"type\":\"ack\"}".into())));
        assert_eq!(read_message(&mut &masked(8, true, b"")[..]), Ok(Message::Close));
        assert!(read_message(&mut &masked(1, false, b"part")[..]).is_err());
        // Unmasked, with bytes enough after it to be read as a mask: refused all the same.
        let unmasked = [ws_frame(1, b"unmasked"), vec![0; 4]].concat();
        assert!(read_message(&mut &unmasked[..]).is_err());
        assert!(read_message(&mut &[0x81, 0xff, 0, 0, 0, 0, 0, 1, 0, 0][..]).is_err());
    }

    #[test]
    fn what_the_page_asks_is_checked() {
        let parse = |text: &str| input(&serde_json::from_str(text).unwrap());
        assert_eq!(parse(r#"{"type":"tap","x":0.5,"y":1}"#), Ok(Input::Tap(0.5, 1.0)));
        assert!(parse(r#"{"type":"tap","x":1.5,"y":0}"#).is_err());
        assert_eq!(parse(r#"{"type":"swipe","x1":0,"y1":0,"x2":1,"y2":1,"ms":300}"#), Ok(Input::Swipe((0.0, 0.0), (1.0, 1.0), 300)));
        assert!(parse(r#"{"type":"swipe","x1":0,"y1":0,"x2":1,"y2":1,"ms":10}"#).is_err());
        assert_eq!(parse(r#"{"type":"press","button":"home"}"#), Ok(Input::Press("home".into())));
        assert!(parse(r#"{"type":"type","text":""}"#).is_err());
        assert!(parse(r#"{"type":"elements"}"#).is_err());
    }

    /// A screen whose frames are made up: one key frame, then others, while it is watched.
    struct Fake { watched: Arc<AtomicU32> }
    struct FakeFrames { n: u32 }
    impl Frames for FakeFrames {
        fn frame(&mut self) -> Result<roamrun_device::watch::Frame, String> {
            std::thread::sleep(Duration::from_millis(5));
            self.n += 1;
            Ok(roamrun_device::watch::Frame { key: self.n % 50 == 1, data: vec![0, 0, 1, if self.n % 50 == 1 { 0x26 } else { 0x02 }, 1] })
        }
        fn counts(&self) -> (u32, u32) { (0, 0) }
    }
    impl Screen for Fake {
        fn watch(&self, _: Arc<AtomicBool>) -> Result<Box<dyn Frames>, String> { self.watched.fetch_add(1, Ordering::SeqCst); Ok(Box::new(FakeFrames { n: 0 })) }
        fn size(&self) -> Option<(u32, u32)> { None }
        fn input(&self, _: &Input) -> Result<(), String> { Ok(()) }
    }

    fn whois(login: &str) -> Whois {
        Whois { node: WhoisNode { id: "n1".into(), tags: None, sharer: 0 }, user: WhoisUser { login: login.into() } }
    }

    /// A server on 127.0.0.1 that takes `login`'s machines, with a token; Tailscale says each caller is `caller`.
    /// And how many times the stream was watched.
    fn served(caller: &'static str) -> (std::net::SocketAddr, Arc<AtomicU32>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let at = listener.local_addr().unwrap();
        let hosts = vec![at.to_string()];
        let watched = Arc::new(AtomicU32::new(0));
        let fake = Fake { watched: watched.clone() };
        std::thread::spawn(move || run(listener, Arc::new(fake), vec![Allow::Login("me@example.com".into())], Some("t".repeat(32)), hosts,
            "100.64.0.1".parse().unwrap(), "own".into(), true, Box::new(move |_| Ok(whois(caller)))));
        (at, watched)
    }

    fn ask(at: std::net::SocketAddr, head: &str) -> (TcpStream, String) {
        let mut stream = TcpStream::connect(at).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        stream.write_all(head.replace("{at}", &at.to_string()).as_bytes()).unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut first = String::new();
        reader.read_line(&mut first).unwrap();
        loop { let mut line = String::new(); reader.read_line(&mut line).unwrap(); if line.trim().is_empty() { break } }
        (stream, first)
    }

    const UPGRADE: &str = "GET /ws HTTP/1.1\r\nHost: {at}\r\nOrigin: http://{at}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";

    fn hello(stream: &mut TcpStream, token: &str) {
        let text = format!("{{\"type\":\"hello\",\"token\":\"{token}\"}}");
        let mut frame = vec![0x81, 0x80 | text.len() as u8, 0, 0, 0, 0];
        frame.extend(text.as_bytes());
        stream.write_all(&frame).unwrap();
    }

    /// The first of the server's messages with this opcode.
    fn first(stream: &mut TcpStream, opcode: u8) -> Vec<u8> {
        loop {
            let mut head = [0u8; 2];
            stream.read_exact(&mut head).unwrap();
            let length = match head[1] { 126 => { let mut n = [0u8; 2]; stream.read_exact(&mut n).unwrap(); u16::from_be_bytes(n) as usize } n => n as usize };
            let mut payload = vec![0u8; length];
            stream.read_exact(&mut payload).unwrap();
            if head[0] & 0x0f == opcode { return payload }
        }
    }

    #[test]
    fn a_viewer_is_let_in_by_its_login_its_origin_and_the_token_and_first_sent_a_key_frame() {
        let (at, watched) = served("me@example.com");
        assert!(ask(at, "GET / HTTP/1.1\r\nHost: {at}\r\n\r\n").1.starts_with("HTTP/1.1 200"));
        // Another site's page, none at all on the WebSocket, or a Host that isn't this server.
        assert!(ask(at, "GET / HTTP/1.1\r\nHost: {at}\r\nOrigin: http://evil.example\r\n\r\n").1.starts_with("HTTP/1.1 403"));
        assert!(ask(at, &UPGRADE.replace("Origin: http://{at}", "Origin: http://evil.example")).1.starts_with("HTTP/1.1 403"));
        assert!(ask(at, &UPGRADE.replace("Origin: http://{at}\r\n", "")).1.starts_with("HTTP/1.1 403"));
        assert!(ask(at, &UPGRADE.replace("Host: {at}", "Host: elsewhere:1")).1.starts_with("HTTP/1.1 400"));
        // A wrong token: closed with 1008, nothing sent.
        let (mut stream, said) = ask(at, UPGRADE);
        assert!(said.starts_with("HTTP/1.1 101"));
        hello(&mut stream, "wrong");
        assert_eq!(first(&mut stream, 8), [0x03, 0xf0]);
        // The token: the page is told what it is sent, and its first frame is a key frame.
        let (mut stream, _) = ask(at, UPGRADE);
        hello(&mut stream, &"t".repeat(32));
        let frame = first(&mut stream, 2);
        assert_eq!(frame[0], 1);
        assert_eq!(&frame[9..], [0, 0, 1, 0x26, 1]);
        assert_eq!(watched.load(Ordering::SeqCst), 1);
        // Gone, it lets go of the stream: the next viewer's is watched anew.
        drop(stream);
        let until = Instant::now() + Duration::from_secs(5);
        while watched.load(Ordering::SeqCst) < 2 && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(100));
            let (mut stream, _) = ask(at, UPGRADE);
            hello(&mut stream, &"t".repeat(32));
            assert_eq!(first(&mut stream, 2)[0], 1);
        }
        assert_eq!(watched.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn a_login_not_allowed_is_refused() {
        let (at, _) = served("other@example.com");
        assert!(ask(at, "GET / HTTP/1.1\r\nHost: {at}\r\n\r\n").1.starts_with("HTTP/1.1 403"));
        assert!(ask(at, UPGRADE).1.starts_with("HTTP/1.1 403"));
    }
}
