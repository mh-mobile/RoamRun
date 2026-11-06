//! `roamrunctl view <device> --http <port> --allow <who>`: experimental. The device's screen stream in a browser on
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
const AT_ONCE: usize = 12;
/// How long an agent's look waits for a whole key frame from the stream (asked for, at most each 1.05 s; a stream
/// that starts gives its first within some seconds) before the device is asked for its picture instead.
const LOOK_WAIT: Duration = if cfg!(test) { Duration::from_secs(1) } else { Duration::from_secs(8) };
/// A page takes two (its picture and its sound), an MCP client two or three at once.
const FROM_ONE: usize = 6;
/// For a request's head, each read and all of it; for a viewer's first message, or an MCP request's body, the same,
/// counted from the connection's start: a caller not yet let in doesn't keep a connection longer.
const HEAD_WITHIN: Duration = if cfg!(test) { Duration::from_secs(3) } else { Duration::from_secs(10) };
/// A viewer whose oldest frame not yet shown is older than this, beyond its shortest round trip (a page acknowledges
/// a frame once it is decoded), is cut to the next key frame.
const LATE: Duration = Duration::from_millis(500);
/// A page's round trip assumed until its first acknowledgement says what it is: a far page, cut sooner, would never
/// get one in.
const FIRST_TRIP: Duration = Duration::from_millis(1500);
/// A page's browser says it is there at least this often (its pongs to the pings each PING_EVERY, which it answers
/// with the page's script asleep in a background tab too, and the page's acknowledgements): one that says nothing for
/// this long is gone (a laptop asleep), and is let go of.
const PAGE_QUIET: Duration = if cfg!(test) { Duration::from_secs(2) } else { Duration::from_secs(20) };
const PING_EVERY: Duration = if cfg!(test) { Duration::from_millis(500) } else { Duration::from_secs(5) };
/// Inputs from one page waiting their turn, at most: more are refused, not kept for minutes.
const INPUTS_WAITING: usize = 20;
/// A message from the page, at most.
const MESSAGE: usize = 64 * 1024;
/// Off: no frame acks and no receiver reports go back to the device (to compare a stream without them).
pub const FEEDBACK: &str = "ROAMRUNCTL_VIEW_FEEDBACK";

/// One access unit as viewers are sent it. `picture`: for a key frame, what the page decodes it with.
struct Sent {
    key: bool,
    /// A key frame with its parameter sets: decodable alone, by a decoder just made.
    whole: bool,
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
    /// The shortest time from writing a frame to the page's acknowledgement: the page's way's own, not lateness.
    trip: Option<Duration>,
    key_needed: bool,
    cuts: u32,
}

impl Queue {
    fn new() -> Queue { Queue { waiting: VecDeque::new(), flight: VecDeque::new(), trip: None, key_needed: true, cuts: 0 } }

    /// Takes a frame from the stream; true where a key frame is to be asked for (this viewer was just cut).
    fn push(&mut self, frame: Arc<Sent>, now: Instant) -> bool {
        let late = |at: Instant, beyond: Duration| now.duration_since(at) > LATE + beyond;
        let cut = self.waiting.front().is_some_and(|f| late(f.at, Duration::ZERO))
            || self.flight.front().is_some_and(|f| late(f.1, self.trip.unwrap_or(FIRST_TRIP)));
        if cut {
            self.waiting.clear();
            self.flight.clear();
            self.key_needed = true;
            self.cuts += 1;
        }
        // Waiting for a key frame: one without its parameter sets doesn't do, and another is asked for.
        if self.key_needed && !frame.whole { return cut || frame.key }
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
    fn acked(&mut self, ms: u64, now: Instant) {
        while let Some((_, written)) = self.flight.front().filter(|f| f.0 <= ms).copied() {
            self.flight.pop_front();
            let took = now.duration_since(written);
            self.trip = Some(self.trip.map_or(took, |trip| trip.min(took)));
        }
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
    /// The device's sound, for a page that asked for it: PCM messages not yet written, the oldest let go past `SOUND_KEPT`.
    hears: bool,
    sounds: VecDeque<Arc<Vec<u8>>>,
    closed: bool,
}

/// About half a second of sound waits for a page at most; more, and the oldest goes.
const SOUND_KEPT: usize = 50;

struct Viewer {
    out: Mutex<Out>,
    ready: Condvar,
    /// A connection the page opens for the sound alone: no frames on it, so that none holds the sound up behind it.
    sound_only: bool,
    /// Its inputs not yet done.
    pending: std::sync::atomic::AtomicUsize,
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
    fn new(sound_only: bool) -> Viewer {
        Viewer { out: Mutex::new(Out { queue: Queue::new(), texts: VecDeque::new(), hears: sound_only, sounds: VecDeque::new(), closed: false }), ready: Condvar::new(), sound_only, pending: Default::default() }
    }
}

/// What a page asks of the device.
#[derive(Debug, PartialEq)]
enum Input {
    Tap(f64, f64),
    Swipe((f64, f64), (f64, f64), u32),
    /// Its centre, scale, degrees clockwise, and ms.
    Pinch((f64, f64), f64, f64, u32),
    Type(String),
    Paste(String),
    Press(String),
}

/// The device's screen as `view` uses it; a test gives its own.
trait Screen: Send + Sync {
    fn watch(&self, wanted: Arc<AtomicBool>) -> Result<Box<dyn Frames>, String>;
    /// The screen's size by the device's word, as a frame is cut to.
    fn size(&self) -> Option<(u32, u32)>;
    fn input(&self, input: &Input) -> Result<(), String>;
    /// Which way up the interface is (rr_device_way: 1–4, 0 unknown): the picture comes in the device's own terms.
    fn way(&self) -> u8;
}

trait Frames: Send {
    /// `None`: nothing yet (the video pauses on a still screen); asked again once the viewers are looked at.
    fn frame(&mut self) -> Result<Option<roamrun_device::watch::Frame>, String>;
    /// The sound's access units to `to` from now on, where there is sound.
    fn sound_to(&mut self, _to: mpsc::Sender<Vec<u8>>) {}
    /// Key frames asked for, and answered.
    fn counts(&self) -> (u32, u32);
}

impl Frames for Watch {
    fn frame(&mut self) -> Result<Option<roamrun_device::watch::Frame>, String> { Watch::frame(self) }
    fn sound_to(&mut self, to: mpsc::Sender<Vec<u8>>) { Watch::sound_to(self, to) }
    fn counts(&self) -> (u32, u32) { (self.asked, self.answered) }
}

struct OnDevice {
    device: Arc<Device>,
    feedback: bool,
}

impl Screen for OnDevice {
    fn watch(&self, wanted: Arc<AtomicBool>) -> Result<Box<dyn Frames>, String> {
        let device = &self.device;
        device.watch(self.feedback, wanted).map(|watch| Box::new(watch) as Box<dyn Frames>)
    }
    fn size(&self) -> Option<(u32, u32)> { crate::device::screen_size(&self.device) }
    fn way(&self) -> u8 { self.device.way() }
    fn input(&self, input: &Input) -> Result<(), String> {
        let device = &self.device;
        crate::device::said(match input {
            Input::Tap(x, y) => device.tap(*x, *y),
            Input::Swipe(from, to, ms) => device.swipe(*from, *to, *ms),
            Input::Pinch(centre, scale, degrees, ms) => device.pinch(*centre, *scale, *degrees, *ms),
            Input::Type(text) => device.type_text(text),
            Input::Paste(text) => device.paste(text),
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
    /// The interface's way up, as last asked (0 until then).
    way: std::sync::atomic::AtomicU8,
    began: Instant,
    feedback: bool,
    allowed: Vec<Allow>,
    token: Option<String>,
    hosts: Vec<String>,
    own_ip: IpAddr,
    own_id: String,
    whois: Box<dyn Fn(IpAddr) -> Result<Whois, String> + Send + Sync>,
    inputs: Mutex<mpsc::Sender<(Arc<Viewer>, Input)>>,
    sound: Mutex<mpsc::Sender<Vec<u8>>>,
    mcp: Option<Mcp>,
    /// Agents' looks waiting for the next whole key frame.
    waiting: Mutex<Vec<mpsc::Sender<Arc<Sent>>>>,
    /// Connections open, by the way they came and the address: on loopback, Serve's and this machine's are told apart.
    open: Mutex<std::collections::HashMap<(Route, IpAddr), usize>>,
    /// Whether the sound can be decoded here, once that is known: the page is told.
    can_hear: Mutex<Option<Result<(), String>>>,
}

impl Hub {
    fn push(&self, frame: Sent) {
        let frame = Arc::new(frame);
        let now = Instant::now();
        // A key frame without its parameter sets can't be decoded alone: the looks wait on for the next one, asked for
        // again (the stream lowered the asking at this one).
        if frame.key {
            let mut waiting = self.waiting.lock().unwrap_or_else(|e| e.into_inner());
            if frame.whole { for look in waiting.drain(..) { let _ = look.send(frame.clone()); } }
            else if !waiting.is_empty() { self.wanted.store(true, Ordering::Relaxed) }
        }
        for viewer in self.viewers.lock().unwrap_or_else(|e| e.into_inner()).iter().filter(|v| !v.sound_only) {
            if viewer.out.lock().unwrap_or_else(|e| e.into_inner()).queue.push(frame.clone(), now) { self.wanted.store(true, Ordering::Relaxed) }
            viewer.ready.notify_one();
        }
    }
    /// The next whole key frame from the stream, within `within`. The stream runs for it with no page open: a
    /// viewer that takes nothing stands in meanwhile, and the stream stops some seconds after, as after a page.
    fn keyframe(&self, within: Duration) -> Option<Arc<Sent>> {
        let (look, came) = mpsc::channel();
        self.waiting.lock().unwrap_or_else(|e| e.into_inner()).push(look);
        let standing = Arc::new(Viewer::new(true));
        standing.out.lock().unwrap_or_else(|e| e.into_inner()).hears = false;
        self.viewers.lock().unwrap_or_else(|e| e.into_inner()).push(standing.clone());
        self.joined.notify_all();
        self.wanted.store(true, Ordering::Relaxed);
        let frame = came.recv_timeout(within).ok();
        self.viewers.lock().unwrap_or_else(|e| e.into_inner()).retain(|viewer| !Arc::ptr_eq(viewer, &standing));
        frame
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
    pub at: Option<IpAddr>,
    /// The device connected by USB with this UDID; empty: the only one.
    pub usb: Option<String>,
    /// `POST /mcp`: roamrunctl's MCP tools on this device, through this connection (needs the token).
    pub mcp: bool,
    /// The page over HTTPS too, at this port of this machine's tailnet name, by `tailscale serve` (needs the token).
    pub https: Option<u16>,
}

/// `view --mcp`: the MCP server on view's own device, and the name it goes by there.
struct Mcp {
    name: String,
    server: Mutex<crate::mcp::Server>,
    /// The page's inputs, counted for the server (see `PageInputs`).
    page: Arc<crate::mcp::PageInputs>,
}

/// `roamrunctl view`: until Ctrl-C.
pub fn serve(options: Options) -> Result<String, String> {
    #[cfg(unix)]
    http::not_root(roamrun_device::safe::effective_user())?;
    if options.allowed.is_empty() { return Err("who may watch: --allow <login> (your own machines), or --allow tag:<name>".into()) }
    let device = match (&options.usb, options.at) {
        (Some(udid), _) => Device::open_usb(Some(udid.as_str()).filter(|u| !u.is_empty()))?,
        (None, Some(at)) => crate::device::opened_at(&options.device, at)?,
        (None, None) => crate::device::opened(&options.device)?,
    };
    let device_name = match &options.usb { Some(udid) if udid.is_empty() => "the USB device".to_string(), Some(udid) => udid.clone(), None => options.device.clone() };
    let (listener, status, own, names) = http::listen(options.port)?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    // The stream stopped at Ctrl-C, not left listed on the device as screen sharing.
    let stop = crate::at_stop()?;
    let feedback = std::env::var(FEEDBACK).map_or(true, |v| v != "off");
    note!("roamrunctl: {}'s screen at http://{own}:{port}/ (experimental), for {} on the tailnet{}{}. The page needs WebCodecs, which Chrome offers only to a secure page: see `roamrunctl view --help`. Ctrl-C ends it.",
        device_name, options.allowed.iter().map(|a| match a { Allow::Tag(s) | Allow::Login(s) => s.as_str() }).collect::<Vec<_>>().join(", "),
        if options.token.is_some() { ", with the token" } else { "" }, if feedback { "" } else { "; no frame acks or receiver reports to the device" });
    let device = Arc::new(device);
    let page = Arc::new(crate::mcp::PageInputs::default());
    // The name an agent gives: the saved one, or for USB the UDID, else `usb`.
    let mcp = options.mcp.then(|| {
        let name = match &options.usb { Some(udid) if udid.is_empty() => "usb".to_string(), Some(udid) => udid.clone(), None => options.device.clone() };
        note!("roamrunctl: MCP at http://{own}:{port}/mcp for the same callers, with the token as a bearer: its device is “{name}”");
        Mcp { server: Mutex::new(crate::mcp::Server::holding(&name, device.clone(), Some(page.clone()))), name, page }
    });
    let screen = Arc::new(OnDevice { device, feedback });
    // On this machine's loopback too, for a browser on this machine that takes no flags (an app's own): there the page
    // is a secure one. Callers there are this machine, so they give the token: without one, not there.
    let local = match &options.token {
        Some(_) => TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, port)).map_err(|e| note!("roamrunctl: not on localhost:{port} too ({e})")).ok(),
        None => { note!("roamrunctl: not on localhost, and not for this machine at all: this machine gives the token (--token-file)"); None }
    };
    let mut hosts = http::hosts(IpAddr::V4(own), names.clone(), port);
    if local.is_some() {
        hosts.extend([format!("localhost:{port}"), format!("127.0.0.1:{port}")]);
        note!("roamrunctl: and on this machine at http://localhost:{port}/ (a secure page to any browser here), with the token");
    }
    // HTTPS, by Tailscale in front of the loopback listener: a secure page to any browser on the tailnet. Taken off
    // `tailscale serve` again at Ctrl-C.
    let mut forwarded = None;
    if let Some(https) = options.https {
        let proxy = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)).map_err(|e| e.to_string())?;
        crate::tailscale::serve_https(https, &format!("http://{}", proxy.local_addr().map_err(|e| e.to_string())?))?;
        forwarded = Some(proxy);
        stop.then(move || { let _ = crate::tailscale::serve_https_off(https); });
        hosts.extend(https_hosts(&names, https));
        note!("roamrunctl: and at https://{}:{https}/ for the same callers, by tailscale serve, with the token (taken off it at Ctrl-C)", names.first().map_or("this machine", String::as_str));
    } else {
        stop.then(|| {});
    }
    run(listener, local, forwarded, screen, options.allowed, options.token, hosts, IpAddr::V4(own), status.this.id.clone(), feedback, mcp, Box::new(crate::tailscale::whois))
}

fn https_hosts(names: &[String], port: u16) -> Vec<String> {
    names.iter().flat_map(|name| {
        std::iter::once(format!("{name}:{port}")).chain((port == 443).then(|| name.clone()))
    }).collect()
}

#[allow(clippy::too_many_arguments)]
fn run(listener: TcpListener, local: Option<TcpListener>, forwarded: Option<TcpListener>, screen: Arc<dyn Screen>, allowed: Vec<Allow>, token: Option<String>, hosts: Vec<String>, own_ip: IpAddr, own_id: String, feedback: bool, mcp: Option<Mcp>,
       whois: Box<dyn Fn(IpAddr) -> Result<Whois, String> + Send + Sync>) -> Result<String, String> {
    let (inputs, asked) = mpsc::channel::<(Arc<Viewer>, Input)>();
    let (sound, heard) = mpsc::channel::<Vec<u8>>();
    // An agent's look takes view's stream: the server is given it (by a weak hold: the hub holds the server).
    let hub = Arc::new_cyclic(|hub: &std::sync::Weak<Hub>| {
        if let Some(mcp) = &mcp {
            let mut server = mcp.server.lock().unwrap_or_else(|e| e.into_inner());
            server.take_pictures(from_stream(hub.clone()));
            // What an agent pressed, shown to whoever watches (a ring where it tapped, a line where it swiped).
            let told = hub.clone();
            server.tell(Box::new(move |what, points| {
                if let Some(hub) = told.upgrade() { hub.say(&json!({ "type": "agent", "what": what, "points": points }).to_string()) }
            }));
        }
        Hub {
        viewers: Mutex::new(Vec::new()), joined: Condvar::new(), wanted: Arc::new(AtomicBool::new(false)), asked: AtomicU32::new(0), answered: AtomicU32::new(0),
        way: std::sync::atomic::AtomicU8::new(0), began: Instant::now(), feedback, allowed, token, hosts, own_ip, own_id, whois, inputs: Mutex::new(inputs), sound: Mutex::new(sound), open: Mutex::new(Default::default()), mcp, waiting: Mutex::new(Vec::new()), can_hear: Mutex::new(None),
        }
    });
    // The sound decoded on a thread of its own, and given to the pages that asked for it.
    let hearing = hub.clone();
    std::thread::spawn(move || {
        let mut decoder = match roamrun_device::sound::Decoder::new() {
            Ok(decoder) => Some(decoder),
            Err(why) => { note!("roamrunctl: no sound for the page: {why}"); *hearing.can_hear.lock().unwrap_or_else(|e| e.into_inner()) = Some(Err(why)); None }
        };
        if decoder.is_some() { *hearing.can_hear.lock().unwrap_or_else(|e| e.into_inner()) = Some(Ok(())) }
        for unit in heard {
            let Some(pcm) = decoder.as_mut().and_then(|d| d.decode(&unit)) else { continue };
            let message = Arc::new(sound_message(hearing.began.elapsed().as_millis() as u64, &pcm));
            for viewer in hearing.viewers.lock().unwrap_or_else(|e| e.into_inner()).iter() {
                let mut out = viewer.out.lock().unwrap_or_else(|e| e.into_inner());
                if !out.hears { continue }
                out.sounds.push_back(message.clone());
                while out.sounds.len() > SOUND_KEPT { out.sounds.pop_front(); }
                drop(out);
                viewer.ready.notify_one();
            }
        }
    });
    // Inputs one at a time, on a thread of their own: a long `type` doesn't hold up what the page acknowledges.
    let device = screen.clone();
    let pages = hub.mcp.as_ref().map(|mcp| mcp.page.clone());
    std::thread::spawn(move || {
        for (viewer, input) in asked {
            let began = Instant::now();
            let what = match &input { Input::Tap(..) => "tap", Input::Swipe(..) => "swipe", Input::Pinch(..) => "pinch", Input::Type(_) => "type", Input::Paste(_) => "paste", Input::Press(_) => "press" };
            // An agent's action waits meanwhile, and this waits for one: what an agent looked at is judged, and acted on,
            // with no input of a page's between. Counted before it begins and timed once it ends: an agent's look
            // meanwhile isn't taken to be current.
            let turn = pages.as_ref().map(|page| page.gate.lock().unwrap_or_else(|e| e.into_inner()));
            // A page gone, while this waited too: what it left isn't done for nobody.
            if viewer.out.lock().unwrap_or_else(|e| e.into_inner()).closed { viewer.pending.fetch_sub(1, Ordering::SeqCst); continue }
            if let Some(page) = &pages { page.count.fetch_add(1, Ordering::SeqCst); }
            let said = device.input(&input);
            if let Some(page) = &pages { *page.ended.lock().unwrap_or_else(|e| e.into_inner()) = Some(Instant::now()); }
            drop(turn);
            viewer.pending.fetch_sub(1, Ordering::SeqCst);
            viewer.say(match said {
                Ok(()) => json!({ "type": "done", "what": what, "ms": began.elapsed().as_millis() as u64 }),
                Err(why) => json!({ "type": "error", "what": what, "error": why }),
            }.to_string());
        }
    });
    // The way up, asked when someone starts watching and then every 10 s: each asking opens a service connection
    // in the tunnel, and asked every 2 s that went with three times the packets lost.
    let (turned, asking) = (hub.clone(), screen.clone());
    std::thread::spawn(move || {
        let mut asked: Option<Instant> = None;
        loop {
            std::thread::sleep(Duration::from_secs(1));
            if turned.viewers.lock().unwrap_or_else(|e| e.into_inner()).is_empty() { asked = None; continue }
            if asked.is_some_and(|at| at.elapsed() < Duration::from_secs(10)) { continue }
            asked = Some(Instant::now());
            let way = asking.way();
            if way != 0 { turned.way.store(way, Ordering::Relaxed) }
        }
    });
    let pumped = hub.clone();
    std::thread::Builder::new().stack_size(8 << 20).spawn(move || pump(&pumped, screen.as_ref())).map_err(|e| e.to_string())?;
    for (listener, route) in local.into_iter().map(|l| (l, Route::Local)).chain(forwarded.into_iter().map(|l| (l, Route::Serve))) {
        let hub = hub.clone();
        std::thread::spawn(move || accept(listener, &hub, route));
    }
    accept(listener, &hub, Route::Tailnet);
    Ok(String::new())
}

/// How a connection arrived; Serve never inherits the local caller's allowance.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
enum Route { Tailnet, Local, Serve }

/// Each connection on its own thread, within the limits.
fn accept(listener: TcpListener, hub: &Arc<Hub>, route: Route) {
    for stream in listener.incoming() {
        let Ok(stream) = stream else { std::thread::sleep(Duration::from_millis(100)); continue };
        let Ok(from) = stream.peer_addr().map(|a| a.ip()) else { continue };
        {
            let mut open = hub.open.lock().unwrap_or_else(|e| e.into_inner());
            // Closed unanswered: one machine doesn't take them all.
            if open.values().sum::<usize>() >= AT_ONCE || open.get(&(route, from)).is_some_and(|n| *n >= FROM_ONE) { continue }
            *open.entry((route, from)).or_default() += 1;
        }
        let hub = hub.clone();
        std::thread::spawn(move || {
            let began = Instant::now();
            let (mut who, mut what) = ("-".to_string(), "-".to_string());
            let lingering = stream.try_clone().ok();
            // Closed once HEAD_WITHIN has gone by, unless let in before (`in_time` dropped).
            let (in_time, deadline) = mpsc::channel::<()>();
            if let Ok(watched) = stream.try_clone() {
                std::thread::spawn(move || if deadline.recv_timeout(HEAD_WITHIN) == Err(mpsc::RecvTimeoutError::Timeout) { let _ = watched.shutdown(std::net::Shutdown::Both); });
            }
            let outcome = connection(stream, from, route, &hub, &mut who, &mut what, in_time);
            // A body not read (refused first) is drained a moment, so that the caller isn't reset before its answer.
            if let Some(stream) = lingering.filter(|_| what.starts_with("POST")) { http::linger(&stream) }
            note!("{} {from} {} {} {outcome} {:.1}s", http::clock(), http::printable(&who), what, began.elapsed().as_secs_f64());
            let mut open = hub.open.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(n) = open.get_mut(&(route, from)) { *n -= 1; if *n == 0 { open.remove(&(route, from)); } }
        });
    }
}

/// Only Serve's dedicated loopback listener trusts Tailscale's identity header.
fn caller(hub: &Hub, from: IpAddr, route: Route, request: &http::Request) -> Result<(Whois, bool), String> {
    match route {
        Route::Local => return Ok((whois_local(), true)),
        Route::Serve => return Ok((Whois {
            user: crate::tailscale::WhoisUser { login: request.header("tailscale-user-login").unwrap_or("").to_string() },
            ..Whois::default()
        }, false)),
        Route::Tailnet => {}
    }
    let whois = (hub.whois)(from)?;
    let own = from == hub.own_ip || (!hub.own_id.is_empty() && whois.node.id == hub.own_id);
    Ok((whois, own))
}

fn whois_local() -> Whois {
    Whois { user: crate::tailscale::WhoisUser { login: "localhost".into() }, ..Whois::default() }
}

/// While anyone watches: the stream, to each viewer. Once nobody does, it is let go of (and the device stops it).
fn pump(hub: &Hub, screen: &dyn Screen) {
    // What the last key frame said (its codec and size), and what the page was told of it; the last parameter sets.
    let mut picture: Option<(Described, Arc<str>)> = None;
    let mut sets: Vec<Vec<u8>> = Vec::new();
    loop {
        {
            let mut viewers = hub.viewers.lock().unwrap_or_else(|e| e.into_inner());
            while viewers.is_empty() { viewers = hub.joined.wait(viewers).unwrap_or_else(|e| e.into_inner()); }
        }
        let mut frames = match screen.watch(hub.wanted.clone()) {
            Ok(frames) => frames,
            Err(why) => {
                // Not opened again here (another connection would start a second stream): said, each time it is tried.
                let why = if why.contains(crate::mcp::GONE) { format!("the connection to the device is gone ({why}): start view again, with the device connected") } else { why };
                hub.say(&json!({ "type": "status", "text": format!("the stream didn't start: {why}") }).to_string());
                std::thread::sleep(Duration::from_secs(2));
                continue;
            }
        };
        frames.sound_to(hub.sound.lock().unwrap_or_else(|e| e.into_inner()).clone());
        while !hub.viewers.lock().unwrap_or_else(|e| e.into_inner()).is_empty() {
            let frame = match frames.frame() {
                Ok(Some(frame)) => frame,
                // A pause: whether anyone still watches is looked at again, so that the last to go lets the stream go.
                Ok(None) => continue,
                Err(why) => { hub.say(&json!({ "type": "status", "text": format!("the stream stopped ({why}): starting it again") }).to_string()); break }
            };
            let (asked, answered) = frames.counts();
            hub.asked.store(asked, Ordering::Relaxed);
            hub.answered.store(answered, Ordering::Relaxed);
            // A key frame without its parameter sets is given those last seen: a page or a look starting at it decodes it.
            let data = if frame.key { with_parameter_sets(frame.data, &mut sets) } else { frame.data };
            let said = if frame.key { described(&data) } else { None };
            if let Some(said) = said {
                if picture.as_ref().is_none_or(|(was, _)| *was != said) {
                    let crop = crate::device::fit(said.1, screen.size()).unwrap_or(said.1);
                    let text = json!({ "type": "picture", "codec": said.0, "width": said.1.0, "height": said.1.1, "crop": [crop.0, crop.1] }).to_string();
                    picture = Some((said, text.into()));
                }
            }
            let ms = hub.began.elapsed().as_millis() as u64;
            hub.push(Sent { key: frame.key, whole: frame.key && whole(&data), at: Instant::now(), ms, picture: frame.key.then(|| picture.as_ref().map(|p| p.1.clone())).flatten(), data });
        }
    }
}

/// One connection: the page, or a viewer's WebSocket. What is shown or typed is never logged.
fn connection(stream: TcpStream, from: IpAddr, route: Route, hub: &Hub, who: &mut String, what: &mut String, in_time: mpsc::Sender<()>) -> String {
    let _ = stream.set_read_timeout(Some(HEAD_WITHIN));
    let Ok(mut writer) = stream.try_clone() else { return "gone".into() };
    let mut reader = BufReader::new(stream);
    let refuse = |writer: &mut TcpStream, status: u16| { answer(writer, status, "text/plain; charset=utf-8", ""); status.to_string() };
    let request = match http::head(&mut reader) { Ok(request) => request, Err(status) => return refuse(&mut writer, status) };
    *what = format!("{} {}", http::printable(&request.method), http::printable(&request.path));
    let Some(host) = request.header("host").filter(|host| hub.hosts.iter().any(|h| h.eq_ignore_ascii_case(host))) else { return refuse(&mut writer, 400) };
    if request.path == "/mcp" { return mcp_call(&mut reader, &mut writer, &request, from, route, hub, who, what, in_time) }
    // A page of this server's own, or none (the page itself, opened): not one of another site.
    // http, or https where Tailscale serves it in front (`--https`).
    let own_origin = |origin: &str| origin.eq_ignore_ascii_case(&format!("http://{host}")) || origin.eq_ignore_ascii_case(&format!("https://{host}"));
    let socket = request.path == "/ws";
    match request.header("origin") {
        Some(origin) if own_origin(origin) => {}
        None if !socket => {}
        _ => return refuse(&mut writer, 403),
    }
    if request.method != "GET" { return refuse(&mut writer, 405) }
    if !socket && request.path != "/" { return refuse(&mut writer, 404) }
    let (whois, own) = match caller(hub, from, route, &request) {
        Ok(caller) => caller,
        Err(why) => { *who = format!("(whois: {why})"); return refuse(&mut writer, 503) }
    };
    // This machine's own users take the token: they are let in to the page, and asked for it in the first message.
    match http::judged(&whois, &hub.allowed, own, hub.token.is_some()) {
        Ok(name) => *who = name,
        Err(why) => {
            // The page's refusal says why, to whoever opened it.
            let body = if socket { String::new() }
                else if whois.user.login.is_empty() && whois.node.tags.as_ref().is_none_or(Vec::is_empty) { "no Tailscale login came with the request: a tagged machine opens http://<this machine's Tailscale address>:<port>/, let in by --allow tag:<name>\n".to_string() }
                else { format!("{why}: roamrunctl view lets in the logins it was started with (--allow), and this machine with its token (--token-file)\n") };
            answer(&mut writer, 403, "text/plain; charset=utf-8", &body);
            *who = why;
            return "403".into();
        }
    }
    if !socket {
        drop(in_time);
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
    drop(in_time);
    // A page that says nothing for PAGE_QUIET is gone (its pongs, its acknowledgements); one
    // slow to take what is written isn't cut for that.
    let _ = reader.get_ref().set_read_timeout(Some(PAGE_QUIET));
    let _ = writer.set_write_timeout(None);
    let sound_only = hello["only"] == "sound";
    let viewer = Arc::new(Viewer::new(sound_only));
    let sound = match &*hub.can_hear.lock().unwrap_or_else(|e| e.into_inner()) { Some(Ok(())) => json!(true), Some(Err(why)) => json!(why), None => Value::Null };
    viewer.say(json!({ "type": "hello", "feedback": hub.feedback, "sound": sound }).to_string());
    hub.viewers.lock().unwrap_or_else(|e| e.into_inner()).push(viewer.clone());
    if !sound_only { hub.wanted.store(true, Ordering::Relaxed) }
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
            "ack" => if let Some(ms) = message["t"].as_u64() { viewer.out.lock().unwrap_or_else(|e| e.into_inner()).queue.acked(ms, Instant::now()) },
            "keyframe" => {
                viewer.out.lock().unwrap_or_else(|e| e.into_inner()).queue.restart();
                hub.wanted.store(true, Ordering::Relaxed);
            }
            _ => match input(&message) {
                Ok(_) if viewer.pending.load(Ordering::SeqCst) >= INPUTS_WAITING => {
                    viewer.say(json!({ "type": "error", "what": message["type"], "error": format!("{INPUTS_WAITING} inputs are waiting their turn already: this one wasn't taken") }).to_string())
                }
                Ok(input) => {
                    viewer.pending.fetch_add(1, Ordering::SeqCst);
                    let _ = hub.inputs.lock().unwrap_or_else(|e| e.into_inner()).send((viewer.clone(), input));
                }
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
        "pinch" => {
            let ms = message["ms"].as_u64().filter(|ms| (50..=5000).contains(ms)).ok_or("ms: 50...5000")?;
            let scale = message["scale"].as_f64().filter(|s| (0.25..=4.0).contains(s)).ok_or("scale: 0.25...4")?;
            let degrees = message["degrees"].as_f64().filter(|d| (-180.0..=180.0).contains(d)).ok_or("degrees: -180...180")?;
            Ok(Input::Pinch((at("x")?, at("y")?), scale, degrees, ms as u32))
        }
        "type" => Ok(Input::Type(word("text")?)),
        "paste" => Ok(Input::Paste(word("text")?)),
        "press" => Ok(Input::Press(word("button")?)),
        other => Err(format!("nothing is done for {:?}", http::printable(other))),
    }
}

/// To the page: what is said, then frames as they come; the counts once a second.
fn write_to(writer: &mut TcpStream, viewer: &Viewer, hub: &Hub) {
    let mut picture: Option<Arc<str>> = None;
    let (mut counted, mut pinged) = (Instant::now(), Instant::now());
    loop {
        let (texts, sounds, frame, cuts) = {
            let mut out = viewer.out.lock().unwrap_or_else(|e| e.into_inner());
            while !out.closed && out.texts.is_empty() && out.sounds.is_empty() && out.queue.waiting.is_empty() && counted.elapsed() < Duration::from_secs(1) {
                out = viewer.ready.wait_timeout(out, Duration::from_secs(1)).unwrap_or_else(|e| e.into_inner()).0;
            }
            if out.closed { return }
            let texts: Vec<String> = out.texts.drain(..).collect();
            let sounds: Vec<Arc<Vec<u8>>> = out.sounds.drain(..).collect();
            (texts, sounds, out.queue.take(Instant::now()), out.queue.cuts)
        };
        let mut bytes = Vec::new();
        for text in texts { bytes.extend(ws_frame(1, text.as_bytes())) }
        for sound in sounds { bytes.extend(ws_frame(2, &sound)) }
        if counted.elapsed() >= Duration::from_secs(1) {
            counted = Instant::now();
            let counts = json!({ "type": "counts", "keyframesAsked": hub.asked.load(Ordering::Relaxed), "keyframesAnswered": hub.answered.load(Ordering::Relaxed), "cuts": cuts, "way": hub.way.load(Ordering::Relaxed) });
            bytes.extend(ws_frame(1, counts.to_string().as_bytes()));
        }
        if pinged.elapsed() >= PING_EVERY {
            pinged = Instant::now();
            bytes.extend(ws_frame(9, &[]));
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

/// A look's picture from view's stream: the next whole key frame, decoded here (macOS: VideoToolbox), the display's
/// own way up, as a look from the stream is anywhere.
fn from_stream(hub: std::sync::Weak<Hub>) -> crate::mcp::Pictures {
    Box::new(move || {
        let hub = hub.upgrade().ok_or("view is ending")?;
        let frame = hub.keyframe(LOOK_WAIT).ok_or(format!("no key frame came from it within {} s", LOOK_WAIT.as_secs()))?;
        decoded(&frame.data).map(|picture| (picture, frame.at))
    })
}

#[cfg(target_os = "macos")]
fn decoded(frame: &[u8]) -> Result<crate::device::Picture, String> {
    let (rgb, width, height) = roamrun_device::hevc::decode(frame)?;
    let image = image::RgbImage::from_raw(width, height, rgb).ok_or("decode: a short image")?;
    Ok(crate::device::Picture { image: image::DynamicImage::ImageRgb8(image), native: true })
}

#[cfg(not(target_os = "macos"))]
fn decoded(_: &[u8]) -> Result<crate::device::Picture, String> { Err("it is decoded on macOS only".into()) }

/// A key frame with the parameter sets it lacks: the depacketizer gives them with the first IRAP after a picture of
/// another kind only, so consecutive ones come without. Those it carries replace the kept ones of their kind (in
/// `sets`, by kind) first, so that a new SPS (a display that changed) isn't given an old one; a frame that lacks
/// none goes as it came. Otherwise the sets, in order (VPS, SPS, PPS), follow its access unit delimiter.
fn with_parameter_sets(data: Vec<u8>, sets: &mut Vec<Vec<u8>>) -> Vec<u8> {
    let kind = |nal: &[u8]| (nal[0] >> 1) & 0x3f;
    let carried: Vec<&[u8]> = nal_units(&data).filter(|nal| (32..=34).contains(&kind(nal))).collect();
    sets.retain(|set| carried.iter().all(|nal| kind(nal) != kind(set)));
    sets.extend(carried.iter().map(|nal| nal.to_vec()));
    sets.sort_by_key(|set| kind(set));
    if whole(&data) || ![32, 33, 34].iter().all(|k| sets.iter().any(|set| kind(set) == *k)) { return data }
    let mut made = Vec::with_capacity(data.len() + sets.iter().map(|set| set.len() + 4).sum::<usize>());
    let mut put = false;
    for nal in nal_units(&data).filter(|nal| !(32..=34).contains(&kind(nal))) {
        if !put && kind(nal) != 35 {
            for set in sets.iter() { made.extend([0, 0, 0, 1]); made.extend(set) }
            put = true;
        }
        made.extend([0, 0, 0, 1]);
        made.extend(nal);
    }
    made
}

/// Whether an access unit carries its parameter sets (VPS, SPS, PPS) and a slice: decodable alone.
fn whole(annexb: &[u8]) -> bool {
    let types: Vec<u8> = nal_units(annexb).map(|nal| (nal[0] >> 1) & 0x3f).collect();
    [32, 33, 34].iter().all(|t| types.contains(t)) && types.iter().any(|t| *t < 32)
}

/// `POST /mcp` (`view --mcp`): roamrunctl's MCP tools on view's own device, by its connection and its stream, so that
/// an agent's look starts no second screen stream (which stops view's). Asked as `mcp --http` asks: no Origin (no
/// browser's page, this one's included), the token as a bearer, `--allow`. A call waits for the one before it.
#[allow(clippy::too_many_arguments)]
fn mcp_call(reader: &mut BufReader<TcpStream>, writer: &mut TcpStream, request: &http::Request, from: IpAddr, route: Route, hub: &Hub, who: &mut String, what: &mut String, in_time: mpsc::Sender<()>) -> String {
    let Some(mcp) = &hub.mcp else { return reply(writer, 404, "", "") };
    if request.header("origin").is_some() { return reply(writer, 403, "", "") }
    if request.method != "POST" { return reply(writer, 405, "Allow: POST\r\n", "") }
    let presented = request.header("authorization").and_then(|v| v.split_once(' ')).filter(|(scheme, _)| scheme.eq_ignore_ascii_case("bearer")).map(|(_, t)| t.trim());
    let token = matches!((&hub.token, presented), (Some(t), Some(p)) if http::same(t.as_bytes(), p.as_bytes()));
    if !token { return reply(writer, 401, "WWW-Authenticate: Bearer\r\n", "") }
    let (whois, own) = match caller(hub, from, route, request) {
        Ok(caller) => caller,
        Err(why) => { *who = format!("(whois: {why})"); return reply(writer, 503, "", "the caller couldn't be looked up (tailscale whois): try again\n") }
    };
    match http::judged(&whois, &hub.allowed, own, token) {
        Ok(name) => *who = name,
        Err(why) => { *who = why; return reply(writer, 403, "", "") }
    }
    if let Some(version) = request.header("mcp-protocol-version").filter(|v| !crate::mcp::VERSIONS.contains(v)) {
        return reply(writer, 400, "", &http::rpc_error(Value::Null, -32000, &format!("Bad Request: Unsupported protocol version: {version} (supported: {})", crate::mcp::VERSIONS.join(", "))));
    }
    let _ = reader.get_ref().set_read_timeout(Some(http::BODY_WITHIN));
    if request.header("expect").is_some_and(|e| e.eq_ignore_ascii_case("100-continue")) { let _ = writer.write_all(b"HTTP/1.1 100 Continue\r\n\r\n"); }
    let body = match http::body(reader, request, http::BODY) { Ok(body) => body, Err(status) => return reply(writer, status, "", "") };
    drop(in_time);
    let Ok(message) = serde_json::from_slice::<Value>(&body) else { return reply(writer, 400, "", &http::rpc_error(Value::Null, -32700, "not JSON")) };
    if !message.is_object() { return reply(writer, 400, "", &http::rpc_error(Value::Null, -32600, "one message a request, as an object")) }
    let method = message["method"].as_str().unwrap_or("");
    *what = match method {
        "tools/call" => format!("POST /mcp tools/call {}", message["params"]["name"].as_str().unwrap_or("?")),
        "" => "POST /mcp a response".into(),
        method => format!("POST /mcp {method}"),
    };
    // A notification or a response: nothing to answer (a cancel does nothing here; closing the connection does).
    let response = method.is_empty() && (message.get("result").is_some() || message.get("error").is_some());
    if response || message.get("id").is_none() { return reply(writer, 202, "", "") }
    let line = message.to_string();
    let answer = if method == "tools/call" {
        let mut server = mcp.server.lock().unwrap_or_else(|e| e.into_inner());
        // Gone while it waited its turn: not made for nobody (a client that tries again would have it twice).
        if http::closed(writer) { return "not begun".into() }
        server.handle(&line)
    } else {
        // Asks nothing of the device: answered at once, by a server like it, not after the call that runs.
        crate::mcp::Server::holding(&mcp.name, Arc::new(Device::none()), None).handle(&line)
    }.unwrap_or_default();
    let failed = serde_json::from_str::<Value>(&answer).is_ok_and(|a| a["result"]["isError"] == true);
    reply(writer, 200, "", &answer);
    if failed { "error".into() } else { "ok".into() }
}

/// An answer to `/mcp`, and its status for the log.
fn reply(writer: &mut TcpStream, status: u16, extra: &str, body: &str) -> String {
    http::respond(writer, status, extra, body);
    status.to_string()
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

/// Sound as the page reads it: a flag byte (2), the server's time in ms (8 bytes, big-endian), then PCM (`roamrun_device::sound::RATE`,
/// `roamrun_device::sound::CHANNELS` interleaved, 16-bit little-endian).
fn sound_message(ms: u64, pcm: &[u8]) -> Vec<u8> {
    let mut message = Vec::with_capacity(9 + pcm.len());
    message.push(2);
    message.extend_from_slice(&ms.to_be_bytes());
    message.extend_from_slice(pcm);
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

    fn sent(key: bool, at: Instant, ms: u64) -> Arc<Sent> { Arc::new(Sent { key, whole: key, at, ms, data: vec![], picture: None }) }

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
        queue.acked(2, t + Duration::from_millis(20));
        assert!(!queue.push(sent(false, later, 4), later));
        // Frame 3 has waited more than LATE: cut, a key frame asked for, nothing until one comes.
        let late = t + Duration::from_millis(600);
        assert!(queue.push(sent(false, late, 5), late));
        assert!(queue.take(late).is_none());
        assert!(!queue.push(sent(false, late, 6), late));
        assert!(!queue.push(sent(true, late, 7), late));
        assert_eq!(queue.take(late).unwrap().ms, 7);
        assert_eq!(queue.cuts, 1);
        // Written and not acknowledged for longer than LATE beyond the page's round trip (20 ms): cut too.
        let slow = late + Duration::from_millis(521);
        assert!(queue.push(sent(true, slow, 8), slow));
        assert_eq!(queue.take(slow).unwrap().ms, 8);
        // A decoder that failed: nothing until a key frame, and not one without its parameter sets (another is asked for).
        queue.restart();
        assert!(!queue.push(sent(false, slow, 9), slow));
        assert!(queue.push(Arc::new(Sent { key: true, whole: false, at: slow, ms: 10, data: vec![], picture: None }), slow));
        assert!(queue.take(slow).is_none());

        // A page far away (its acknowledgements come 700 ms after writing) isn't late for that alone.
        let mut far = Queue::new();
        assert!(!far.push(sent(true, t, 1), t));
        far.take(t);
        far.acked(1, t + Duration::from_millis(700));
        let next = t + Duration::from_millis(700);
        assert!(!far.push(sent(false, next, 2), next));
        far.take(next);
        assert!(!far.push(sent(false, next + Duration::from_millis(1000), 3), next + Duration::from_millis(1000)));
        assert!(far.push(sent(false, next + Duration::from_millis(1300), 4), next + Duration::from_millis(1300)));
    }

    /// A page 700 ms away, sent a frame each 16 ms and acknowledging each 700 ms after it was written, isn't cut: its
    /// round trip is learned before the allowance for it runs out.
    #[test]
    fn a_far_page_sent_frames_all_along_learns_its_round_trip() {
        let t = Instant::now();
        let mut queue = Queue::new();
        let mut written: VecDeque<(u64, Instant)> = VecDeque::new();
        for i in 0..300u64 {
            let now = t + Duration::from_millis(16 * i);
            while written.front().is_some_and(|w| now.duration_since(w.1) >= Duration::from_millis(700)) {
                let (ms, at) = written.pop_front().unwrap();
                queue.acked(ms, at + Duration::from_millis(700));
            }
            queue.push(sent(i % 60 == 0, now, i), now);
            if let Some(frame) = queue.take(now) { written.push_back((frame.ms, now)); }
        }
        assert_eq!(queue.cuts, 0);
        assert_eq!(queue.trip, Some(Duration::from_millis(700)));
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
        assert_eq!(parse(r#"{"type":"paste","text":"日本語"}"#), Ok(Input::Paste("日本語".into())));
        assert!(parse(r#"{"type":"elements"}"#).is_err());
        assert_eq!(parse(r#"{"type":"pinch","x":0.5,"y":0.5,"scale":2,"degrees":-30,"ms":400}"#), Ok(Input::Pinch((0.5, 0.5), 2.0, -30.0, 400)));
        assert!(parse(r#"{"type":"pinch","x":0.5,"y":0.5,"scale":9,"degrees":0,"ms":400}"#).is_err());
    }

    /// A screen whose frames are made up: one key frame, then others, while it is watched.
    /// `whole`: its key frames carry their parameter sets, as the device's do.
    /// `still`: after its first key frame, the video pauses for good (a still screen). `let_go` counts the watches
    /// dropped, `done` the inputs made (each takes 300 ms).
    struct Fake { watched: Arc<AtomicU32>, whole: bool, still: bool, let_go: Arc<AtomicU32>, done: Arc<AtomicU32> }
    struct FakeFrames { n: u32, whole: bool, still: bool, let_go: Arc<AtomicU32> }
    impl Drop for FakeFrames { fn drop(&mut self) { self.let_go.fetch_add(1, Ordering::SeqCst); } }
    impl Fake {
        fn new(whole: bool) -> Fake { Fake { watched: Default::default(), whole, still: false, let_go: Default::default(), done: Default::default() } }
    }
    /// A key frame as the stream gives one: VPS, SPS, PPS, then an IDR slice.
    const FAKE_KEY: [u8; 20] = [0, 0, 1, 0x40, 1, 0, 0, 1, 0x42, 1, 0, 0, 1, 0x44, 1, 0, 0, 1, 0x26, 1];
    impl Frames for FakeFrames {
        fn frame(&mut self) -> Result<Option<roamrun_device::watch::Frame>, String> {
            std::thread::sleep(Duration::from_millis(5));
            if self.still && self.n > 0 { std::thread::sleep(Duration::from_millis(50)); return Ok(None) }
            self.n += 1;
            let key = self.n % 50 == 1;
            let data = match (key, self.whole) { (true, true) => FAKE_KEY.to_vec(), (true, false) => vec![0, 0, 1, 0x26, 1], _ => vec![0, 0, 1, 0x02, 1] };
            Ok(Some(roamrun_device::watch::Frame { key, data }))
        }
        fn counts(&self) -> (u32, u32) { (0, 0) }
    }
    impl Screen for Fake {
        fn watch(&self, _: Arc<AtomicBool>) -> Result<Box<dyn Frames>, String> {
            self.watched.fetch_add(1, Ordering::SeqCst);
            Ok(Box::new(FakeFrames { n: 0, whole: self.whole, still: self.still, let_go: self.let_go.clone() }))
        }
        fn size(&self) -> Option<(u32, u32)> { None }
        fn input(&self, _: &Input) -> Result<(), String> { std::thread::sleep(Duration::from_millis(300)); self.done.fetch_add(1, Ordering::SeqCst); Ok(()) }
        fn way(&self) -> u8 { 1 }
    }

    fn whois(login: &str) -> Whois {
        Whois { node: WhoisNode { id: "n1".into(), tags: None, sharer: 0 }, user: WhoisUser { login: login.into() } }
    }

    /// A server on 127.0.0.1 that takes `login`'s machines, with a token; Tailscale says each caller is `caller`.
    /// And how many times the stream was watched.
    fn served(caller: &'static str) -> (std::net::SocketAddr, Arc<AtomicU32>) { served_with(caller, false) }

    /// As `served`, with `--mcp` where `mcp` is (its device none, named `fake`).
    fn served_with(caller: &'static str, mcp: bool) -> (std::net::SocketAddr, Arc<AtomicU32>) { served_as(caller, mcp, true) }

    /// As `served_with`, its key frames whole or not.
    fn served_as(caller: &'static str, mcp: bool, whole: bool) -> (std::net::SocketAddr, Arc<AtomicU32>) {
        let fake = Fake::new(whole);
        let watched = fake.watched.clone();
        (served_fake(caller, mcp, fake), watched)
    }

    fn served_fake(caller: &'static str, mcp: bool, fake: Fake) -> std::net::SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let at = listener.local_addr().unwrap();
        let hosts = vec![at.to_string()];
        std::thread::spawn(move || run(listener, None, None, Arc::new(fake), vec![Allow::Login("me@example.com".into())], Some("t".repeat(32)), hosts,
            "100.64.0.1".parse().unwrap(), "own".into(), true,
            mcp.then(|| Mcp { name: "fake".into(), server: Mutex::new(crate::mcp::Server::holding("fake", Arc::new(Device::none()), None)), page: Default::default() }),
            Box::new(move |_| Ok(whois(caller)))));
        at
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
        assert_eq!(&frame[9..], FAKE_KEY);
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
        // The page says why, to whoever opened it (read whole: `ask` reads the head through a buffer of its own).
        let mut stream = TcpStream::connect(at).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        stream.write_all(format!("GET / HTTP/1.1\r\nHost: {at}\r\n\r\n").as_bytes()).unwrap();
        let mut answer = String::new();
        let _ = stream.read_to_string(&mut answer);
        assert!(answer.starts_with("HTTP/1.1 403") && answer.contains("other@example.com, not allowed") && answer.contains("--allow"), "{answer}");
        assert!(ask(at, UPGRADE).1.starts_with("HTTP/1.1 403"));
    }

    /// A WebSocket's messages until the server closes it, or `within` goes by: whether it closed, and its texts.
    /// `answer`: its pings are answered, as a browser does, its page's script asleep or not.
    fn until_closed(stream: &mut TcpStream, within: Duration, answer: bool) -> (bool, Vec<String>) {
        let until = Instant::now() + within;
        let mut texts = Vec::new();
        stream.set_read_timeout(Some(Duration::from_millis(200))).unwrap();
        while Instant::now() < until {
            let mut head = [0u8; 2];
            match stream.read_exact(&mut head) {
                Ok(()) => {}
                Err(e) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => continue,
                Err(_) => return (true, texts),
            }
            stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            let length = match head[1] { 126 => { let mut n = [0u8; 2]; stream.read_exact(&mut n).unwrap(); u16::from_be_bytes(n) as usize } n => n as usize };
            let mut payload = vec![0u8; length];
            if stream.read_exact(&mut payload).is_err() { return (true, texts) }
            stream.set_read_timeout(Some(Duration::from_millis(200))).unwrap();
            match head[0] & 0x0f {
                8 => return (true, texts),
                1 => texts.push(String::from_utf8_lossy(&payload).into_owned()),
                9 if answer && stream.write_all(&[0x8a, 0x80, 0, 0, 0, 0]).is_err() => return (true, texts),
                _ => {}
            }
        }
        (false, texts)
    }

    /// A page that says nothing (its machine asleep) is let go of after PAGE_QUIET; one whose browser answers the pings
    /// stays, though it sends nothing else (its script asleep in a background tab).
    #[test]
    fn a_page_that_says_nothing_is_let_go_of() {
        let (at, _) = served("me@example.com");
        let (mut quiet, _) = ask(at, UPGRADE);
        hello(&mut quiet, &"t".repeat(32));
        let (mut there, _) = ask(at, UPGRADE);
        hello(&mut there, &"t".repeat(32));
        let stays = std::thread::spawn(move || !until_closed(&mut there, PAGE_QUIET + Duration::from_secs(2), true).0);
        assert!(until_closed(&mut quiet, PAGE_QUIET + Duration::from_secs(2), false).0);
        assert!(stays.join().unwrap());
    }

    /// On a still screen the video pauses for good: the last viewer to go still lets the stream go.
    #[test]
    fn a_still_screen_lets_the_stream_go_when_the_last_viewer_does() {
        let fake = Fake { still: true, ..Fake::new(true) };
        let let_go = fake.let_go.clone();
        let at = served_fake("me@example.com", false, fake);
        let (mut stream, _) = ask(at, UPGRADE);
        hello(&mut stream, &"t".repeat(32));
        assert_eq!(first(&mut stream, 2)[0], 1);
        drop(stream);
        let until = Instant::now() + Duration::from_secs(3);
        while let_go.load(Ordering::SeqCst) == 0 && Instant::now() < until { std::thread::sleep(Duration::from_millis(50)) }
        assert_eq!(let_go.load(Ordering::SeqCst), 1);
    }

    /// A page's inputs wait their turn, INPUTS_WAITING at most; those left waiting by a page that is gone aren't made.
    #[test]
    fn a_pages_inputs_are_bounded_and_not_made_once_it_is_gone() {
        let fake = Fake::new(true);
        let done = fake.done.clone();
        let at = served_fake("me@example.com", false, fake);
        let (mut stream, _) = ask(at, UPGRADE);
        hello(&mut stream, &"t".repeat(32));
        for _ in 0..INPUTS_WAITING + 3 {
            let text = br#"{"type":"tap","x":0.5,"y":0.5}"#;
            let mut frame = vec![0x81, 0x80 | text.len() as u8, 0, 0, 0, 0];
            frame.extend(text);
            stream.write_all(&frame).unwrap();
        }
        let (_, texts) = until_closed(&mut stream, Duration::from_millis(800), true);
        assert!(texts.iter().any(|t| t.contains("waiting their turn")), "{texts:?}");
        drop(stream);
        std::thread::sleep(Duration::from_millis(1500));
        let made = done.load(Ordering::SeqCst);
        std::thread::sleep(Duration::from_millis(1000));
        assert_eq!(done.load(Ordering::SeqCst), made);
        assert!(made < 8, "{made}");
    }

    /// A page that goes while its input waits behind an agent's action: the input isn't made once the agent is done.
    #[test]
    fn an_input_left_by_a_page_gone_behind_an_agent_isnt_made() {
        let fake = Fake::new(true);
        let done = fake.done.clone();
        let page = Arc::new(crate::mcp::PageInputs::default());
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let at = listener.local_addr().unwrap();
        let hosts = vec![at.to_string()];
        let mcp = Mcp { name: "fake".into(), server: Mutex::new(crate::mcp::Server::holding("fake", Arc::new(Device::none()), Some(page.clone()))), page: page.clone() };
        std::thread::spawn(move || run(listener, None, None, Arc::new(fake), vec![Allow::Login("me@example.com".into())], Some("t".repeat(32)), hosts,
            "100.64.0.1".parse().unwrap(), "own".into(), true, Some(mcp), Box::new(|_| Ok(whois("me@example.com")))));
        let agent = page.gate.lock().unwrap();
        let (mut stream, _) = ask(at, UPGRADE);
        hello(&mut stream, &"t".repeat(32));
        let text = br#"{"type":"tap","x":0.5,"y":0.5}"#;
        let mut frame = vec![0x81, 0x80 | text.len() as u8, 0, 0, 0, 0];
        frame.extend(text);
        stream.write_all(&frame).unwrap();
        std::thread::sleep(Duration::from_millis(300));   // the tap waits at the gate
        drop(stream);
        std::thread::sleep(Duration::from_millis(300));   // the page is seen to be gone
        drop(agent);
        std::thread::sleep(Duration::from_millis(700));
        assert_eq!(done.load(Ordering::SeqCst), 0);
    }

    /// A caller that sends its head a little at a time isn't kept past HEAD_WITHIN.
    #[test]
    fn a_head_sent_slowly_is_cut_at_head_within() {
        let (at, _) = served("me@example.com");
        let mut stream = TcpStream::connect(at).unwrap();
        stream.write_all(b"GET / HTTP/1.1\r\n").unwrap();
        let began = Instant::now();
        let cut = loop {
            std::thread::sleep(Duration::from_millis(500));
            if stream.write_all(b"X-A: b\r\n").is_err() { break true }
            stream.set_read_timeout(Some(Duration::from_millis(10))).unwrap();
            let mut byte = [0u8; 1];
            if matches!(stream.read(&mut byte), Ok(0)) { break true }
            if began.elapsed() > HEAD_WITHIN + Duration::from_secs(3) { break false }
        };
        assert!(cut && began.elapsed() < HEAD_WITHIN + Duration::from_secs(2), "{:?}", began.elapsed());
    }

    /// One POST to /mcp with `extra` head lines and `body`: the status line and the body.
    fn posted(at: std::net::SocketAddr, extra: &str, body: &str) -> (String, String) {
        let mut stream = TcpStream::connect(at).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        stream.write_all(format!("POST /mcp HTTP/1.1\r\nHost: {at}\r\n{extra}Content-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}", body.len()).as_bytes()).unwrap();
        let mut answer = String::new();
        let _ = stream.read_to_string(&mut answer);
        let (head, body) = answer.split_once("\r\n\r\n").unwrap_or((&answer, ""));
        (head.lines().next().unwrap_or("").to_string(), body.to_string())
    }

    /// `/mcp` asks as `mcp --http` does (no Origin, the token as a bearer, `--allow`), answers initialize and
    /// tools/list at once, takes notifications, and refuses a tap without a look; without `--mcp` there is none.
    #[test]
    fn mcp_is_asked_like_mcp_over_http() {
        let bearer = format!("Authorization: Bearer {}\r\n", "t".repeat(32));
        let init = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#;
        let (at, _) = served("me@example.com");
        assert!(posted(at, &bearer, init).0.starts_with("HTTP/1.1 404"));
        let (at, watched) = served_with("me@example.com", true);
        assert!(posted(at, "", init).0.starts_with("HTTP/1.1 401"));
        assert!(posted(at, "Authorization: Bearer nope\r\n", init).0.starts_with("HTTP/1.1 401"));
        assert!(posted(at, &format!("{bearer}Origin: http://{at}\r\n"), init).0.starts_with("HTTP/1.1 403"));
        assert!(posted(at, &format!("{bearer}MCP-Protocol-Version: 1999-01-01\r\n"), init).0.starts_with("HTTP/1.1 400"));
        let (status, body) = posted(at, &bearer, init);
        assert!(status.starts_with("HTTP/1.1 200") && body.contains("serverInfo"), "{status} {body}");
        let (status, body) = posted(at, &bearer, r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#);
        assert!(status.starts_with("HTTP/1.1 200") && body.contains("\"tap\"") && !body.contains("\"install\""), "{body}");
        assert!(posted(at, &bearer, r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).0.starts_with("HTTP/1.1 202"));
        let (_, body) = posted(at, &bearer, r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"tap","arguments":{"device":"fake","look":1,"x":1,"y":1}}}"#);
        assert!(body.contains("look first") && body.contains("\"isError\":true"), "{body}");
        let (_, body) = posted(at, &bearer, r#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"devices","arguments":{}}}"#);
        assert!(body.contains("fake"), "{body}");
        // No stream was started for any of it.
        assert_eq!(watched.load(Ordering::SeqCst), 0);
        let (at, _) = served_with("other@example.com", true);
        assert!(posted(at, &bearer, init).0.starts_with("HTTP/1.1 403"));
    }

    /// An agent's look takes its picture from view's stream, which runs for it with no page open: a whole key frame
    /// comes (the Fake's isn't HEVC, so its decoding is what fails, not the wait); with none whole, the look waits
    /// LOOK_WAIT, asks the device instead (none here) and says why.
    #[test]
    fn an_agents_look_takes_a_whole_key_frame_from_the_stream() {
        let bearer = format!("Authorization: Bearer {}\r\n", "t".repeat(32));
        let look = r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"look","arguments":{"device":"fake"}}}"#;
        let (at, watched) = served_as("me@example.com", true, true);
        let (_, body) = posted(at, &bearer, look);
        assert_eq!(watched.load(Ordering::SeqCst), 1);
        assert!(body.contains("from view's stream") && !body.contains("no key frame came"), "{body}");
        let (at, _) = served_as("me@example.com", true, false);
        let began = Instant::now();
        let (_, body) = posted(at, &bearer, look);
        assert!(body.contains("no key frame came") && began.elapsed() >= LOOK_WAIT, "{body}");
    }

    /// A key frame without parameter sets (an IDR right after another) is given those of the last whole one, after its
    /// delimiter; a whole one, or anything before the first whole one, goes as it came.
    #[test]
    fn a_key_frame_without_parameter_sets_is_given_the_last_ones() {
        let mut sets = Vec::new();
        let bare = vec![0, 0, 0, 1, 0x46, 1, 0x50, 0, 0, 1, 0x26, 1, 0xaa];   // AUD, IDR
        assert_eq!(with_parameter_sets(bare.clone(), &mut sets), bare);
        assert_eq!(with_parameter_sets(FAKE_KEY.to_vec(), &mut sets), FAKE_KEY.to_vec());
        let made = with_parameter_sets(bare, &mut sets);
        assert!(whole(&made));
        let kinds: Vec<u8> = nal_units(&made).map(|nal| (nal[0] >> 1) & 0x3f).collect();
        assert_eq!(kinds, [35, 32, 33, 34, 19]);

        // A new SPS alone (the display changed): it is kept, and given with the rest, not the old one.
        let new_sps = [0x42, 1, 0xbb];
        let changed = [&[0, 0, 0, 1, 0x46, 1, 0x50][..], &[0, 0, 0, 1], &new_sps, &[0, 0, 1, 0x26, 1, 0xaa]].concat();
        let made = with_parameter_sets(changed, &mut sets);
        let units: Vec<&[u8]> = nal_units(&made).collect();
        assert_eq!(units.iter().map(|nal| (nal[0] >> 1) & 0x3f).collect::<Vec<_>>(), [35, 32, 33, 34, 19]);
        assert_eq!(units[2], new_sps);
        let bare = vec![0, 0, 0, 1, 0x46, 1, 0x50, 0, 0, 1, 0x26, 1, 0xcc];
        assert_eq!(nal_units(&with_parameter_sets(bare, &mut sets)).nth(2).unwrap(), new_sps);
    }

    #[test]
    fn a_key_frame_is_whole_with_its_parameter_sets() {
        assert!(whole(&FAKE_KEY));
        assert!(!whole(&[0, 0, 1, 0x26, 1]));
        assert!(!whole(&FAKE_KEY[..15]));
    }

    /// The loopback listener's callers are this machine: Tailscale isn't asked (here it would refuse them), and they
    /// give the token, as this machine's do.
    #[test]
    fn a_caller_on_localhost_is_this_machine_with_the_token() {
        let (main, local) = (TcpListener::bind("127.0.0.1:0").unwrap(), TcpListener::bind("127.0.0.1:0").unwrap());
        let at = local.local_addr().unwrap();
        let host = format!("localhost:{}", at.port());
        let hosts = vec![main.local_addr().unwrap().to_string(), host.clone()];
        let fake = Fake::new(true);
        std::thread::spawn(move || run(main, Some(local), None, Arc::new(fake), vec![Allow::Login("me@example.com".into())], Some("t".repeat(32)), hosts,
            "100.64.0.1".parse().unwrap(), "own".into(), true,
            Some(Mcp { name: "fake".into(), server: Mutex::new(crate::mcp::Server::holding("fake", Arc::new(Device::none()), None)), page: Default::default() }),
            Box::new(|_| Ok(whois("other@example.com")))));
        let (_, first) = ask(at, &format!("GET / HTTP/1.1\r\nHost: {host}\r\n\r\n"));
        assert!(first.starts_with("HTTP/1.1 200"), "{first}");
        let init = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#;
        let post = |extra: &str| {
            let mut stream = TcpStream::connect(at).unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            stream.write_all(format!("POST /mcp HTTP/1.1\r\nHost: {host}\r\n{extra}Content-Length: {}\r\n\r\n{init}", init.len()).as_bytes()).unwrap();
            let mut answer = String::new();
            let _ = stream.read_to_string(&mut answer);
            answer.lines().next().unwrap_or("").to_string()
        };
        assert!(post(&format!("Authorization: Bearer {}\r\n", "t".repeat(32))).starts_with("HTTP/1.1 200"));
        assert!(post("").starts_with("HTTP/1.1 401"));
        // The page's WebSocket from an https page of this server (Tailscale's HTTPS in front) is its own.
        let (_, first) = ask(at, &UPGRADE.replace("Origin: http://{at}", &format!("Origin: https://{host}")).replace("Host: {at}", &format!("Host: {host}")));
        assert!(first.starts_with("HTTP/1.1 101"), "{first}");
    }
    #[test]
    fn serve_needs_an_allowed_identity_even_with_the_token() {
        let main = TcpListener::bind("127.0.0.1:0").unwrap();
        let proxy = TcpListener::bind("127.0.0.1:0").unwrap();
        let (direct, at) = (main.local_addr().unwrap(), proxy.local_addr().unwrap());
        let fake = Fake::new(true);
        let mut hosts = vec![direct.to_string(), at.to_string()];
        hosts.extend(https_hosts(&["view.example.ts.net".into()], 443));
        std::thread::spawn(move || run(main, None, Some(proxy), Arc::new(fake), vec![Allow::Login("me@example.com".into())], Some("t".repeat(32)),
            hosts, "100.64.0.1".parse().unwrap(), "own".into(), true,
            Some(Mcp { name: "fake".into(), server: Mutex::new(crate::mcp::Server::holding("fake", Arc::new(Device::none()), None)), page: Default::default() }),
            Box::new(|_| Ok(whois("other@example.com")))));
        let bearer = format!("Authorization: Bearer {}\r\n", "t".repeat(32));
        let ping = r#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#;
        for login in ["", "Tailscale-User-Login: other@example.com\r\n"] {
            assert!(posted(at, &(bearer.clone() + login), ping).0.starts_with("HTTP/1.1 403"));
            assert!(ask(at, &format!("GET / HTTP/1.1\r\nHost: {{at}}\r\n{login}\r\n")).1.starts_with("HTTP/1.1 403"));
            assert!(ask(at, &UPGRADE.replace("\r\n\r\n", &format!("\r\n{login}\r\n"))).1.starts_with("HTTP/1.1 403"));
        }
        // No login with it (a tagged machine through Serve): the page says to use the direct address.
        let mut stream = TcpStream::connect(at).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        stream.write_all(format!("GET / HTTP/1.1\r\nHost: {at}\r\n\r\n").as_bytes()).unwrap();
        let mut answer = String::new();
        let _ = stream.read_to_string(&mut answer);
        assert!(answer.contains("no Tailscale login came with the request") && answer.contains("--allow tag:"), "{answer}");
        let login = "Tailscale-User-Login: me@example.com\r\n";
        assert!(posted(at, &(bearer.clone() + login), ping).0.starts_with("HTTP/1.1 200"));
        assert!(posted(at, login, ping).0.starts_with("HTTP/1.1 401"));
        assert!(ask(at, &format!("GET / HTTP/1.1\r\nHost: view.example.ts.net\r\n{login}\r\n")).1.starts_with("HTTP/1.1 200"));
        // A direct tailnet caller can't claim the proxy's login.
        assert!(posted(direct, &(bearer + login), ping).0.starts_with("HTTP/1.1 403"));
        let (mut stream, status) = ask(at, &UPGRADE.replace("\r\n\r\n", &format!("\r\n{login}\r\n")));
        assert!(status.starts_with("HTTP/1.1 101"));
        hello(&mut stream, "wrong");
        assert_eq!(first(&mut stream, 8), [0x03, 0xf0]);
        let (mut stream, _) = ask(at, &UPGRADE.replace("\r\n\r\n", &format!("\r\n{login}\r\n")));
        hello(&mut stream, &"t".repeat(32));
        assert_eq!(first(&mut stream, 2)[0], 1);
    }

}
