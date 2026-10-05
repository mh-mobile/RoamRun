//! RoamRun's C ABI over idevice. rr_device_tap, _swipe, _type, _paste and
//! _button operate the device; rr_device_elements can scroll it.

use std::ffi::{c_char, CStr, CString};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use idevice::core_device::hid::{
    ButtonState, IndigoHidClient, UniversalHidServiceClient, TOUCHSCREEN_STATE_CONTACT, TOUCHSCREEN_STATE_RELEASE,
};
use idevice::dvt::message::AuxValue;
use idevice::dvt::remote_server::RemoteServerClient;
use idevice::core_device::{
    build_keyframe_request, build_screen_audio_offer, build_screen_video_offer, build_start_audio_parameters,
    build_start_video_parameters, is_rtcp, CallInfoBlob, DisplayServiceClient, HevcDepacketizer, PasteboardServiceClient, RtpPacket,
    GENERAL_PASTEBOARD,
};
use idevice::remote_pairing::{
    connect_tls_psk_tunnel_native, PairableHost, PairableHostInfo, RemotePairingClient, RpPairingFile, RpPairingSocket,
};
use idevice::rsd::RsdHandshake;
use idevice::tcp::adapter::Adapter;
use idevice::tcp::handle::{AdapterHandle, UdpSocketHandle};
use idevice::{ReadWrite, RsdService};
use tokio::net::{TcpListener, TcpStream};

const VERSION: &CStr = c"0.6.0";
const LABEL: &str = "roamrun";
/// Each call: a device that stops answering mid-way must not hang the caller.
const DEADLINE: Duration = Duration::from_secs(20);
/// Services device control needs, by the word that names them.
const WANTED: [(&str, &str); 4] = [
    ("hid", "com.apple.coredevice.hid.universalhidservice"),
    ("display", "com.apple.coredevice.displayservice"),
    ("screenshot", "com.apple.coredevice.screencaptureservice"),
    ("accessibility", "com.apple.accessibility.axAuditDaemon.remoteserver.shim.remote"),
];

/// A tunnel of our own to a device whose pairing verified, and what was opened on it.
struct Link {
    handle: AdapterHandle,
    handshake: RsdHandshake,
    hid: Option<UniversalHidServiceClient<Box<dyn ReadWrite>>>,
    keys: Option<IndigoHidClient<Box<dyn ReadWrite>>>,
    /// The screen stream, kept between calls while they keep coming.
    stream: Option<Stream>,
    stream_used: Instant,
    /// When a stream was last stopped: one started right on its heels has been refused, and has stalled.
    stream_stopped: Option<Instant>,
    /// How the stream has been used, for whoever asks: started, key frames asked of a running
    /// one, and how many of those came.
    stream_starts: u32,
    keyframes_asked: u32,
    keyframes_answered: u32,
    /// Inputs sent on a new connection because the kept one was found gone.
    resent: u32,
    verified_ms: u128,
    tunnel_ms: u128,
    rsd_ms: u128,
}

/// What the C side holds. The runtime has a thread of its own: the tunnel is served between calls.
pub struct RRDevice {
    held: Arc<Held>,
}

/// The device's own, shared with the thread that watches its stream. Not for the C side.
#[doc(hidden)]
pub struct Held {
    runtime: tokio::runtime::Runtime,
    link: Mutex<Link>,
}

impl std::ops::Deref for RRDevice {
    type Target = Held;
    fn deref(&self) -> &Held { &self.held }
}

/// A stream nothing has used for this long is stopped: the device shows a screen-sharing
/// session for as long as one runs, and frames keep arriving (150 to 200 KB a second, which
/// counts on cellular). Long enough for look, think, act; a stopped one costs ~0.5 s to start.
const STREAM_IDLE: Duration = Duration::from_secs(5);

/// Stops the stream once it has sat unused, for as long as the device is held.
fn watch_idle_stream(held: &Arc<Held>) {
    let held = Arc::downgrade(held);
    let _ = std::thread::Builder::new().stack_size(STACK).spawn(move || loop {
        std::thread::sleep(Duration::from_secs(1));
        let Some(held) = held.upgrade() else { return };
        let mut link = held.link.lock().unwrap_or_else(|e| e.into_inner());
        if link.stream.is_some() && link.stream_used.elapsed() >= STREAM_IDLE {
            if let Some(mut stream) = link.stream.take() {
                held.runtime.block_on(stream.stop());
                link.stream_stopped = Some(Instant::now());
            }
        }
    });
}

/// The stack this library's work gets. The tunnel's network stack puts large buffers on it: on
/// a caller's own thread (a dispatch worker has 512 KB) that overflowed.
const STACK: usize = 8 << 20;

/// Runs `work` on a thread with room for it, and waits.
fn with_room<T: Send>(work: impl FnOnce() -> Result<T, String> + Send) -> Result<T, String> {
    std::thread::scope(|scope| {
        std::thread::Builder::new().stack_size(STACK).spawn_scoped(scope, work)
            .map_err(|e| format!("no thread: {e}"))?
            .join().unwrap_or_else(|_| Err("the library failed unexpectedly".into()))
    })
}

#[no_mangle]
pub extern "C" fn rr_device_version() -> *const c_char {
    VERSION.as_ptr()
}

/// # Safety
/// `string` came from this library, or is null.
#[no_mangle]
pub unsafe extern "C" fn rr_string_free(string: *mut c_char) {
    if !string.is_null() {
        drop(unsafe { CString::from_raw(string) });
    }
}

/// # Safety
/// `bytes` and `length` are what rr_device_keyframe returned, or `bytes` is null.
#[no_mangle]
pub unsafe extern "C" fn rr_bytes_free(bytes: *mut u8, length: usize) {
    if !bytes.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(bytes, length)) });
    }
}

fn c_string(s: String) -> *mut c_char {
    CString::new(s).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// `error` is null or writable.
unsafe fn set_error(error: *mut *mut c_char, why: String) {
    if !error.is_null() {
        unsafe { *error = c_string(why) };
    }
}

fn failure(why: &str) -> String {
    format!("{{\"ok\":false,\"error\":{}}}", quoted(why))
}

fn quoted(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// # Safety
/// `ip` is null or a NUL-terminated string; `pairing` is null or `pairing_len` readable bytes
/// (the pairing itself, never a path: it isn't kept on disk as it is); `error` is null or writable.
#[no_mangle]
pub unsafe extern "C" fn rr_device_open(ip: *const c_char, port: u16, pairing: *const u8, pairing_len: usize, error: *mut *mut c_char) -> *mut RRDevice {
    let ip = (!ip.is_null()).then(|| unsafe { CStr::from_ptr(ip) }.to_str().ok()).flatten();
    let file = (!pairing.is_null()).then(|| unsafe { std::slice::from_raw_parts(pairing, pairing_len) });
    let opened = match (ip, file) {
        (Some(ip), Some(file)) => tokio::runtime::Builder::new_multi_thread().worker_threads(1).thread_stack_size(STACK).enable_all().build()
            .map_err(|e| format!("no runtime: {e}"))
            .and_then(|runtime| {
                let link = with_room(|| runtime.block_on(async {
                    tokio::time::timeout(DEADLINE, connect(ip, port, file)).await.unwrap_or_else(|_| Err("timed out".into()))
                }))?;
                let held = Arc::new(Held { runtime, link: Mutex::new(link) });
                watch_idle_stream(&held);
                Ok(RRDevice { held })
            }),
        _ => Err("bad arguments".into()),
    };
    match opened {
        Ok(device) => Box::into_raw(Box::new(device)),
        Err(why) => {
            unsafe { set_error(error, why) };
            std::ptr::null_mut()
        }
    }
}

/// # Safety
/// `device` came from rr_device_open and isn't used again, or is null.
#[no_mangle]
pub unsafe extern "C" fn rr_device_close(device: *mut RRDevice) {
    if !device.is_null() {
        let device = unsafe { Box::from_raw(device) };
        // A stream still running is ended, not left for the device to time out.
        let _ = with_room(|| {
            let mut link = device.link.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(mut stream) = link.stream.take() { device.runtime.block_on(stream.stop()); }
            Ok(())
        });
    }
}

/// # Safety
/// `device` came from rr_device_open and wasn't closed.
#[no_mangle]
pub unsafe extern "C" fn rr_device_info(device: *mut RRDevice) -> *mut c_char {
    let Some(device) = (unsafe { device.as_ref() }) else { return std::ptr::null_mut() };
    let link = device.link.lock().unwrap_or_else(|e| e.into_inner());
    let has = WANTED.map(|(word, name)| format!("{}:{}", quoted(word), link.handshake.services.contains_key(name)));
    c_string(format!(
        "{{\"ok\":true,\"verifiedMs\":{},\"tunnelMs\":{},\"rsdMs\":{},\"services\":{},\"has\":{{{}}},\"stream\":{{\"running\":{},\"starts\":{},\"keyframesAsked\":{},\"keyframesAnswered\":{},\"feedbackPort\":{}}}}}",
        link.verified_ms, link.tunnel_ms, link.rsd_ms, link.handshake.services.len(), has.join(","),
        link.stream.is_some(), link.stream_starts, link.keyframes_asked, link.keyframes_answered,
        link.stream.as_ref().and_then(|s| s.feedback_port).map_or("null".to_string(), |p| p.to_string())
    ))
}

/// # Safety
/// `device` came from rr_device_open and wasn't closed; `length` and `error` are null or writable.
#[no_mangle]
pub unsafe extern "C" fn rr_device_keyframe(device: *mut RRDevice, length: *mut usize, error: *mut *mut c_char) -> *mut u8 {
    let (Some(device), false) = (unsafe { device.as_ref() }, length.is_null()) else {
        unsafe { set_error(error, "bad arguments".into()) };
        return std::ptr::null_mut();
    };
    let result = with_room(|| {
        let mut link = device.link.lock().unwrap_or_else(|e| e.into_inner());
        device.runtime.block_on(async {
            tokio::time::timeout(DEADLINE, keyframe(&mut link)).await.unwrap_or_else(|_| Err("timed out".into()))
        })
    });
    match result {
        Ok(frame) => {
            let boxed = frame.into_boxed_slice();
            unsafe { *length = boxed.len() };
            Box::into_raw(boxed) as *mut u8
        }
        Err(why) => {
            unsafe { set_error(error, why) };
            std::ptr::null_mut()
        }
    }
}

/// One thing done to the device.
enum Input {
    Tap(f64, f64),
    Swipe { from: (f64, f64), to: (f64, f64), ms: u32 },
    Type(Vec<(u64, bool)>),
    Paste(String),
    Button(u64, u64, u64),
}

/// # Safety
/// `device` came from rr_device_open and wasn't closed, or is null.
unsafe fn run(device: *mut RRDevice, input: Result<Input, String>) -> *mut c_char {
    let Some(device) = (unsafe { device.as_ref() }) else { return std::ptr::null_mut() };
    let input = match input {
        Ok(input) => input,
        // Refused for what it says, before anything went to the device: "invalid" tells the
        // caller its connection is none the worse for it.
        Err(why) => return c_string(format!("{{\"ok\":false,\"invalid\":true,\"error\":{}}}", quoted(&why))),
    };
    let started = Instant::now();
    let result = with_room(|| {
        let mut link = device.link.lock().unwrap_or_else(|e| e.into_inner());
        let before = link.resent;
        device.runtime.block_on(perform(&mut link, input)).map(|()| link.resent != before)
    });
    c_string(match result {
        // "reconnected": the kept connection was gone, and the input went on a new one.
        Ok(anew) => format!("{{\"ok\":true,\"ms\":{},\"reconnected\":{anew}}}", started.elapsed().as_millis()),
        Err(why) => failure(&why),
    })
}

/// Refused, not clamped: a point off the screen is a caller's mistake, and pressing the edge isn't what it meant.
fn on_screen(points: &[f64]) -> Result<(), String> {
    if points.iter().all(|v| (0.0..=1.0).contains(v)) { Ok(()) } else { Err("x and y must be within 0...1".into()) }
}

/// # Safety
/// `device` came from rr_device_open and wasn't closed.
#[no_mangle]
pub unsafe extern "C" fn rr_device_tap(device: *mut RRDevice, x: f64, y: f64) -> *mut c_char {
    unsafe { run(device, on_screen(&[x, y]).map(|()| Input::Tap(x, y))) }
}

/// # Safety
/// `device` came from rr_device_open and wasn't closed.
#[no_mangle]
pub unsafe extern "C" fn rr_device_swipe(device: *mut RRDevice, x1: f64, y1: f64, x2: f64, y2: f64, duration_ms: u32) -> *mut c_char {
    let input = on_screen(&[x1, y1, x2, y2]).and_then(|()| {
        if (50..=5000).contains(&duration_ms) { Ok(Input::Swipe { from: (x1, y1), to: (x2, y2), ms: duration_ms }) }
        else { Err("duration must be 50...5000 ms".into()) }
    });
    unsafe { run(device, input) }
}

/// # Safety
/// `device` came from rr_device_open and wasn't closed; `text` is null or a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn rr_device_type(device: *mut RRDevice, text: *const c_char) -> *mut c_char {
    let text = (!text.is_null()).then(|| unsafe { CStr::from_ptr(text) }.to_str().ok()).flatten();
    // Every key is found before any is sent: half a text typed is worse than none.
    let input = text.ok_or("bad text".to_string()).and_then(|t| {
        if t.chars().count() > LONGEST_TYPED { return Err(format!("too long to type: {LONGEST_TYPED} characters at most (paste takes any length)")); }
        t.chars().map(|c| key(c).ok_or(format!("can't type {c:?}: only what a US keyboard has"))).collect::<Result<Vec<_>, _>>()
    });
    unsafe { run(device, input.map(Input::Type)) }
}

/// # Safety
/// `device` came from rr_device_open and wasn't closed; `text` is null or a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn rr_device_paste(device: *mut RRDevice, text: *const c_char) -> *mut c_char {
    let text = (!text.is_null()).then(|| unsafe { CStr::from_ptr(text) }.to_str().ok()).flatten();
    unsafe { run(device, text.map(|t| Input::Paste(t.to_string())).ok_or("bad text".to_string())) }
}

/// # Safety
/// `device` came from rr_device_open and wasn't closed; `name` is null or a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn rr_device_button(device: *mut RRDevice, name: *const c_char) -> *mut c_char {
    let name = (!name.is_null()).then(|| unsafe { CStr::from_ptr(name) }.to_str().ok()).flatten();
    let input = BUTTONS.iter().find(|b| Some(b.0) == name)
        .map(|&(_, page, code, hold)| Input::Button(page, code, hold))
        .ok_or(format!("no such button; one of: {}", BUTTONS.map(|b| b.0).join(", ")));
    unsafe { run(device, input) }
}

/// Hardware buttons: name, HID usage page and code (consumer page), and how long to hold.
const BUTTONS: [(&str, u64, u64, u64); 4] = [
    ("home", 0x0C, 0x40, 80),
    ("lock", 0x0C, 0x30, 200),
    ("volume-up", 0x0C, 0xE9, 80),
    ("volume-down", 0x0C, 0xEA, 80),
];
const LEFT_SHIFT: u64 = 0xE1;
const LEFT_COMMAND: u64 = 0xE3;
const KEY_V: u64 = 0x19;

/// The key of a US keyboard that types `c`, and whether with Shift (HID keyboard page usages).
fn key(c: char) -> Option<(u64, bool)> {
    const PLAIN: &str = "-=[]\\;'`,./";
    const PLAIN_USAGE: [u64; 11] = [0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38];
    const SHIFTED: &str = "_+{}|:\"~<>?";
    const DIGIT_SHIFTED: &str = "!@#$%^&*()";
    Some(match c {
        'a'..='z' => (0x04 + (c as u64 - 'a' as u64), false),
        'A'..='Z' => (0x04 + (c as u64 - 'A' as u64), true),
        '1'..='9' => (0x1E + (c as u64 - '1' as u64), false),
        '0' => (0x27, false),
        '\n' => (0x28, false),
        ' ' => (0x2C, false),
        _ => {
            if let Some(i) = PLAIN.find(c) { (PLAIN_USAGE[i], false) }
            else if let Some(i) = SHIFTED.find(c) { (PLAIN_USAGE[i], true) }
            else if let Some(i) = DIGIT_SHIFTED.find(c) { (0x1E + i as u64, true) }
            else { return None }
        }
    })
}

/// # Safety
/// `device` came from rr_device_open and wasn't closed.
#[no_mangle]
pub unsafe extern "C" fn rr_device_elements(device: *mut RRDevice, limit: u32) -> *mut c_char {
    let Some(device) = (unsafe { device.as_ref() }) else { return std::ptr::null_mut() };
    let started = Instant::now();
    // Its own deadline inside: a walk cut short still returns what it found.
    let result = with_room(|| {
        let mut link = device.link.lock().unwrap_or_else(|e| e.into_inner());
        device.runtime.block_on(elements(&mut link, limit.max(1) as usize, started + WALK))
    });
    c_string(match result {
        Ok((captions, complete, ended)) => format!(
            "{{\"ok\":true,\"elements\":[{}],\"complete\":{complete},\"ended\":\"{ended}\",\"ms\":{}}}",
            captions.iter().map(|c| format!("{{\"caption\":{}}}", quoted(c))).collect::<Vec<_>>().join(","),
            started.elapsed().as_millis()
        ),
        Err(why) => failure(&why),
    })
}

/// How long a walk may take in all, and how long one element may take to come back.
const WALK: Duration = Duration::from_secs(30);
const ELEMENT: Duration = Duration::from_millis(1500);
/// Which way the inspector's focus moves.
const NEXT: u64 = 4;
const FIRST: u64 = 5;

/// The audit service wraps what it is given and gives back: {ObjectType, Value}.
fn wrapped(value: plist::Value) -> plist::Value {
    plist::Value::Dictionary([("ObjectType".to_string(), "passthrough".into()), ("Value".to_string(), value)].into_iter().collect())
}

fn unwrapped(value: &plist::Value) -> &plist::Value {
    value.as_dictionary().and_then(|d| d.get("Value")).unwrap_or(value)
}

/// What is sent has the walk's end as its deadline too, not only what is waited for: a tunnel
/// that stopped taking bytes would hold the device's lock, and every call after this one.
async fn within<T>(until: Instant, sending: impl std::future::Future<Output = T>) -> Result<T, String> {
    tokio::time::timeout_at(tokio::time::Instant::from_std(until), sending).await
        .map_err(|_| "the accessibility service stopped taking what was sent".to_string())
}

/// Captions in the inspector's order, and whether the walk came round (true) or was cut short.
async fn elements(link: &mut Link, limit: usize, until: Instant) -> Result<(Vec<String>, bool, &'static str), String> {
    let port = link.handshake.services.get(WANTED[3].1).ok_or("no accessibility service on this device")?.port;
    let call = |name: &'static str, argument: plist::Value| (name, Some(vec![AuxValue::archived_value(argument)]));
    // Getting to the service has the deadline every call has: one that takes the connection and
    // then says nothing would otherwise be waited on for ever.
    let handle = &mut link.handle;
    let mut client = tokio::time::timeout(DEADLINE, async {
        let stream = handle.connect(port).await.map_err(|e| format!("accessibility service: {e:?}"))?;
        // A lockdown service bridged onto RSD: it wants a check-in before its own protocol.
        let mut plain = idevice::Idevice::new(Box::new(stream), LABEL);
        plain.rsd_checkin().await.map_err(|e| format!("accessibility check-in: {e:?}"))?;
        Ok::<_, String>(RemoteServerClient::new(plain.get_socket().ok_or("accessibility socket")?))
    }).await.unwrap_or_else(|_| Err("the accessibility service didn't answer".into()))?;

    // The greeting both ends send first; then: watch nothing, draw nothing on the device.
    let capabilities: plist::Dictionary = [
        ("com.apple.private.DTXBlockCompression".to_string(), plist::Value::Integer(2u64.into())),
        ("com.apple.private.DTXConnection".to_string(), plist::Value::Integer(1u64.into())),
    ].into_iter().collect();
    for (name, arguments) in [
        call("_notifyOfPublishedCapabilities:", plist::Value::Dictionary(capabilities)),
        call("deviceInspectorSetMonitoredEventType:", plist::Value::Integer(0u64.into())),
        call("deviceInspectorShowVisuals:", plist::Value::Boolean(false)),
    ] {
        within(until, client.root_channel().call_method(Some(name), arguments, false)).await?.map_err(|e| format!("{name} {e:?}"))?;
    }

    let mut captions = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let mut asked_twice = false;
    // How the walk gets to its first element: 0 asks for the first; 1 takes a step away; 2 asks for the first again.
    let mut start = 0u8;
    let mut step = 0;
    while step < limit {
        if Instant::now() >= until { return Ok((captions, false, "deadline")); }
        // From the first element each time a walk starts: the focus is wherever the last one left it.
        let options: plist::Dictionary = [
            ("allowNonAX".to_string(), wrapped(plist::Value::Boolean(false))),
            ("direction".to_string(), wrapped(plist::Value::Integer((if step > 0 || start == 1 { NEXT } else { FIRST }).into()))),
            ("includeContainers".to_string(), wrapped(plist::Value::Boolean(true))),
        ].into_iter().collect();
        let (name, arguments) = call("deviceInspectorMoveWithOptions:", wrapped(plist::Value::Dictionary(options)));
        within(until, client.root_channel().call_method(Some(name), arguments, false)).await?.map_err(|e| format!("{name} {e:?}"))?;

        // The element comes back as the device's own call to us, among others.
        // One wait for the element, however many other messages come meanwhile, and never past the walk's end.
        let wait = tokio::time::Instant::from_std((Instant::now() + ELEMENT).min(until));
        let focus = loop {
            let Ok(message) = tokio::time::timeout_at(wait, client.read_message(0)).await else { break None };
            let message = message.map_err(|e| format!("accessibility: {e:?}"))?;
            let changed = message.data.as_ref().and_then(|d| d.as_string()).is_some_and(|s| s.contains("CurrentElementChanged"));
            if !changed { continue; }
            break message.aux.iter().flat_map(|a| a.values.iter()).find_map(|v| match v {
                AuxValue::Array(bytes) => ns_keyed_archive::decode::from_bytes(bytes).ok(),
                _ => None,
            });
        };
        let Some(focus) = focus else {
            if step == 0 {
                // No answer to "the first": the focus may be on it already (a walk that came round
                // leaves it there), and a move that changes nothing reports nothing. A step away
                // and back makes it say so. Still nothing after that: no element there (the home screen).
                if start < 2 && Instant::now() < until {
                    start += 1;
                    continue;
                }
            } else if !asked_twice && Instant::now() < until {
                // The end of what can be visited — or an answer that was only slow: asked once more.
                asked_twice = true;
                continue;
            }
            // A screen read whole ends by coming round (seen on the device); silence is a walk cut short.
            return Ok((captions, false, "quiet"));
        };
        if step == 0 && start == 1 {
            start = 2;   // that was the step away, not the first element
            continue;
        }
        asked_twice = false;
        let inner = unwrapped(unwrapped(&focus)).as_dictionary();
        let field = |key: &str| inner.and_then(|d| d.get(key)).map(unwrapped);
        // The element's token says when the walk has come round to where it began.
        let token = field("ElementValue_v1").map(|e| format!("{:?}", unwrapped(e)));
        if let Some(token) = token {
            if !seen.insert(token) { return Ok((captions, true, "round")); }
        }
        captions.push(field("CaptionTextValue_v1").and_then(|v| v.as_string()).unwrap_or("").to_string());
        step += 1;
    }
    Ok((captions, false, "limit"))
}

async fn connect(ip: &str, port: u16, file: &[u8]) -> Result<Link, String> {
    let started = Instant::now();
    let mut pairing = RpPairingFile::from_bytes(file).map_err(|e| format!("pairing: {e:?}"))?;
    let control = TcpStream::connect((ip, port)).await.map_err(|e| format!("RemotePairing port: {e}"))?;
    let mut client = RemotePairingClient::new(RpPairingSocket::new(control), LABEL);
    // Verify only: a pairing the device doesn't know must fail here, not start a new one.
    client.attempt_pair_verify().await.map_err(|e| format!("handshake: {e:?}"))?;
    // Said in words the caller knows a refusal by (REFUSED in the header): only when the device
    // answered and said no, not when the exchange itself broke off.
    client.validate_pairing(&mut pairing).await.map_err(|e| match e {
        idevice::IdeviceError::RemotePairing(_) => format!("the device doesn't accept this pairing: {e:?}"),
        _ => format!("the pairing couldn't be verified: {e:?}"),
    })?;
    let verified_ms = started.elapsed().as_millis();

    let tunnel_port = client.create_tcp_listener().await.map_err(|e| format!("tunnel listener: {e:?}"))?;
    let stream = TcpStream::connect((ip, tunnel_port)).await.map_err(|e| format!("tunnel port {tunnel_port}: {e}"))?;
    let tunnel = connect_tls_psk_tunnel_native(stream, client.encryption_key()).await.map_err(|e| format!("tunnel: {e:?}"))?;
    let info = tunnel.info.clone();
    let ours = info.client_address.parse().map_err(|_| "tunnel address".to_string())?;
    let theirs = info.server_address.parse().map_err(|_| "tunnel address".to_string())?;
    let mut adapter = Adapter::new(Box::new(tunnel.into_inner()), ours, theirs);
    adapter.set_mss((info.mtu as usize).saturating_sub(60));
    let mut handle = adapter.to_async_handle();
    let tunnel_ms = started.elapsed().as_millis();

    let rsd = handle.connect(info.server_rsd_port).await.map_err(|e| format!("RSD: {e:?}"))?;
    let handshake = RsdHandshake::new(rsd).await.map_err(|e| format!("RSD handshake: {e:?}"))?;
    Ok(Link { handle, handshake, hid: None, keys: None, stream: None, stream_used: Instant::now(), stream_stopped: None, stream_starts: 0, keyframes_asked: 0, keyframes_answered: 0, resent: 0, verified_ms, tunnel_ms, rsd_ms: started.elapsed().as_millis() })
}

/// The most that is typed in one call: beyond it, a slip in the middle is too costly, and paste does it in one.
const LONGEST_TYPED: usize = 2000;

/// How long an input may take to send, once everything is ready for it: its own length, and
/// room for a slow link. (Typing took some 60 ms a key over Wi‑Fi.)
fn input_time(input: &Input) -> Duration {
    let own = match input {
        Input::Tap(..) => 100,
        Input::Swipe { ms, .. } => *ms as u64,
        Input::Type(strokes) => strokes.len() as u64 * 200,
        Input::Paste(_) => 5_000,
        Input::Button(_, _, hold) => *hold,
    };
    Duration::from_millis(own) + Duration::from_secs(10)
}

/// The device drops input that isn't accompanied by a screen stream, so one runs with it: the
/// one kept from before if frames still come on it, a new one otherwise. Getting that far has
/// the deadline every call has; the input then gets the time its own length needs, so that the
/// deadline doesn't fall in the middle of it.
async fn perform(link: &mut Link, input: Input) -> Result<(), String> {
    tokio::time::timeout(DEADLINE, stream_for_input(link)).await.unwrap_or_else(|_| Err("timed out".into()))?;
    let done = match tokio::time::timeout(input_time(&input), send(link, &input)).await {
        Ok(done) => done,
        Err(_) => {
            let_go(link).await;
            Err("timed out part-way: look at the device before going on".into())
        }
    };
    link.stream_used = Instant::now();
    done
}

async fn stream_for_input(link: &mut Link) -> Result<(), String> {
    // Looked at where it is kept: taken out, it would be dropped unstopped if this were cut short.
    let alive = match link.stream.as_mut() {
        Some(stream) => stream.alive().await,
        None => false,
    };
    if alive { return Ok(()); }
    if let Some(mut stream) = link.stream.take() {
        stream.stop().await;
        link.stream_stopped = Some(Instant::now());
    }
    // Nothing has been sent yet, so a start that fails is tried once more.
    let stream = match start_stream(link).await {
        Ok(stream) => stream,
        Err(_) => start_stream(link).await?,
    };
    link.stream = Some(stream);
    Ok(())
}

/// After an input cut short: the modifier keys are let go as far as that can still be said, and
/// the connections it used aren't kept (what the device makes of a finger left down is its own).
async fn let_go(link: &mut Link) {
    if let Some(keys) = link.keys.as_mut() {
        let _ = tokio::time::timeout(Duration::from_secs(1), async {
            let _ = keys.send_keyboard(LEFT_SHIFT, ButtonState::Up).await;
            let _ = keys.send_keyboard(LEFT_COMMAND, ButtonState::Up).await;
        }).await;
    }
    link.keys = None;
    link.hid = None;
}

/// A connection kept from an earlier call that the device has closed since (it does when it
/// locks): the write fails before anything is sent, so making a new one and sending is no repeat.
fn gone(error: &idevice::IdeviceError) -> bool {
    matches!(error, idevice::IdeviceError::Socket(e) if e.kind() == std::io::ErrorKind::NotConnected)
}

/// Whether what failed is sent again on a new connection: only the first attempt, on a
/// connection kept from before and found gone, with nothing of this input sent yet — the device
/// would otherwise be given part of it twice (a swipe half made, then made again).
fn again(attempt: usize, kept: bool, sent_any: bool, error: &idevice::IdeviceError) -> bool {
    attempt == 0 && kept && !sent_any && gone(error)
}

/// One thing a finger does: a report of where it is (down or up), or a wait.
#[derive(Debug, PartialEq, Clone, Copy)]
enum Touch {
    At(u8, u16, u16),
    Wait(u64),
}

/// A tap: down, held long enough to count, up.
fn tap_steps(x: u16, y: u16) -> Vec<Touch> {
    vec![Touch::At(TOUCHSCREEN_STATE_CONTACT, x, y), Touch::Wait(50), Touch::At(TOUCHSCREEN_STATE_RELEASE, x, y)]
}

/// A drag: down at the start, on along the line a sample every `every` ms (slow enough to read
/// as a drag, not a tap), down at the end, up.
fn drag_steps(from: (u16, u16), to: (u16, u16), samples: u32, every: u64) -> Vec<Touch> {
    let samples = samples.max(1);
    let along = |a: u16, b: u16, i: u32| (a as f64 + (b as f64 - a as f64) * (i as f64 / samples as f64)).round() as u16;
    let mut steps = Vec::with_capacity(samples as usize * 2 + 2);
    for i in 0..samples {
        steps.push(Touch::At(TOUCHSCREEN_STATE_CONTACT, along(from.0, to.0, i), along(from.1, to.1, i)));
        steps.push(Touch::Wait(every));
    }
    steps.push(Touch::At(TOUCHSCREEN_STATE_CONTACT, to.0, to.1));
    steps.push(Touch::At(TOUCHSCREEN_STATE_RELEASE, to.0, to.1));
    steps
}

/// The steps, on the touch connection: the one kept, or a new one. As `press` does with keys.
async fn touch(link: &mut Link, steps: &[Touch]) -> Result<(), String> {
    for attempt in 0..2 {
        let kept = link.hid.is_some();
        if !kept {
            link.hid = Some(UniversalHidServiceClient::connect_rsd(&mut link.handle, &mut link.handshake)
                .await.map_err(|e| format!("HID service: {e:?}"))?);
        }
        let hid = link.hid.as_mut().expect("just set");
        let mut sent_any = false;
        let mut failed = None;
        for step in steps {
            match *step {
                Touch::Wait(ms) => tokio::time::sleep(Duration::from_millis(ms)).await,
                Touch::At(state, x, y) => match hid.send_touchscreen(state, x, y, None).await {
                    Ok(()) => sent_any = true,
                    Err(e) => { failed = Some(e); break }
                },
            }
        }
        let Some(e) = failed else { return Ok(()) };
        link.hid = None;   // a dead connection isn't kept for the next call
        if again(attempt, kept, sent_any, &e) {
            link.resent += 1;
            continue;
        }
        return Err(format!("touch: {e:?}"));
    }
    unreachable!("the second attempt returns")
}

/// One thing a keyboard or a button does.
enum Step {
    Key(u64, ButtonState),
    Button(u64, u64, ButtonState),
    Wait(u64),
}

/// The steps, on the key connection: the one kept, or a new one. A kept one found gone at the
/// first step is replaced and the steps sent; a failure after something was sent is not repeated.
async fn press(link: &mut Link, steps: &[Step]) -> Result<(), String> {
    for attempt in 0..2 {
        let kept = link.keys.is_some();
        if !kept {
            link.keys = Some(IndigoHidClient::connect_rsd(&mut link.handle, &mut link.handshake)
                .await.map_err(|e| format!("HID service: {e:?}"))?);
        }
        let keys = link.keys.as_mut().expect("just set");
        let mut sent_any = false;
        let mut failed = None;
        for step in steps {
            let sent = match *step {
                Step::Key(usage, state) => keys.send_keyboard(usage, state).await,
                Step::Button(page, code, state) => keys.send_button(page, code, state).await,
                Step::Wait(ms) => { tokio::time::sleep(Duration::from_millis(ms)).await; continue }
            };
            match sent {
                Ok(()) => sent_any = true,
                Err(e) => { failed = Some(e); break }
            }
        }
        let Some(e) = failed else { return Ok(()) };
        link.keys = None;   // a dead connection isn't kept for the next call
        if again(attempt, kept, sent_any, &e) {
            link.resent += 1;
            continue;
        }
        return Err(format!("keys: {e:?}"));
    }
    unreachable!("the second attempt returns")
}

async fn send(link: &mut Link, input: &Input) -> Result<(), String> {
    // The touchscreen takes 0...65535 across each axis.
    let unit = |v: f64| (v * 65535.0).round() as u16;
    match input {
        Input::Tap(x, y) => touch(link, &tap_steps(unit(*x), unit(*y))).await,
        Input::Swipe { from, to, ms } => {
            touch(link, &drag_steps((unit(from.0), unit(from.1)), (unit(to.0), unit(to.1)), (ms / 16).max(2), 16)).await
        }
        Input::Paste(text) => {
            // The text goes onto the device's pasteboard, then Command-V as a keyboard would press it.
            let mut board = PasteboardServiceClient::connect_rsd(&mut link.handle, &mut link.handshake)
                .await.map_err(|e| format!("pasteboard service: {e:?}"))?;
            board.set_text(text, GENERAL_PASTEBOARD).await.map_err(|e| format!("pasteboard: {e:?}"))?;
            press(link, &[
                Step::Key(LEFT_COMMAND, ButtonState::Down), Step::Key(KEY_V, ButtonState::Down),
                Step::Key(KEY_V, ButtonState::Up), Step::Key(LEFT_COMMAND, ButtonState::Up),
            ]).await
        }
        Input::Type(strokes) => {
            let mut steps = Vec::with_capacity(strokes.len() * 5);
            for &(usage, shift) in strokes {
                if shift { steps.push(Step::Key(LEFT_SHIFT, ButtonState::Down)); }
                steps.push(Step::Key(usage, ButtonState::Down));
                steps.push(Step::Key(usage, ButtonState::Up));
                if shift { steps.push(Step::Key(LEFT_SHIFT, ButtonState::Up)); }
                steps.push(Step::Wait(12));   // or strokes run together
            }
            press(link, &steps).await
        }
        Input::Button(page, code, hold) => {
            press(link, &[Step::Button(*page, *code, ButtonState::Down), Step::Wait(*hold), Step::Button(*page, *code, ButtonState::Up)]).await
        }
    }
}

/// What the device is told about this end of the stream; the values of an offer it accepts.
fn call_info() -> CallInfoBlob {
    CallInfoBlob {
        call_id: 0,
        client_version: 1,
        device_type: "Mac17,7".into(),
        framework_version: "2205.3.1".into(),
        os_version: "25F71".into(),
        device_name: None,
        audio_device_uid: None,
    }
}

const SUPPORTED_FEATURES: u64 = 140;

/// A screen stream that is running.
struct Stream {
    display: DisplayServiceClient<Box<dyn ReadWrite>>,
    video: UdpSocketHandle,
    audio: UdpSocketHandle,
    /// Ours, as declared in the offer: the device heeds feedback only from it.
    ssrc: u32,
    /// The device's, once a packet has shown it.
    media: Option<u32>,
    /// Where the device's own RTCP came from, if any has: where ours goes.
    feedback_port: Option<u16>,
    requests: u8,
    /// When the last key frame came (or the stream began, which opens with one).
    keyframe_at: Instant,
}

/// The device sends video from this port, and takes feedback there or on the next.
const VIDEO_SENDER_PORT: u16 = 50001;
/// How long a kept stream gets to answer a request for a key frame (it comes in ~0.15 s when
/// it comes) before it is asked again, and then started over.
const KEYFRAME_WAIT: Duration = Duration::from_millis(700);
/// How long to wait for the device's own report, which says where it takes requests. It sends
/// one about every second.
const REPORT_WAIT: Duration = Duration::from_millis(1500);
/// A request made sooner than this after a key frame goes unanswered (measured on iOS 27: none
/// of those made within half a second, all of those made a second after), and waiting it out
/// is quicker than the 2 s of finding that out and starting the stream over.
const KEYFRAME_APART: Duration = Duration::from_millis(1050);
/// How long a stop gets to be answered.
const STOP_WAIT: Duration = Duration::from_secs(3);
/// How long after a stop a start waits.
const AFTER_STOP: Duration = Duration::from_millis(300);

impl Stream {
    /// Told to stop, and not waited on for longer than STOP_WAIT: a device that no longer answers
    /// would otherwise hold up every call after this one.
    async fn stop(&mut self) {
        let _ = tokio::time::timeout(STOP_WAIT, self.display.stop_media_stream()).await;
    }

    /// Takes what has arrived without waiting; true if any video did. A running stream sends
    /// some sixty frames a second, moving picture or not.
    async fn drain(&mut self) -> bool {
        let mut video = false;
        // Nothing is done with the sound, but what arrives is taken: unread, it only piles up.
        while let Ok(Ok(_)) = tokio::time::timeout(Duration::ZERO, self.audio.recv()).await {}
        while let Ok(Ok(datagram)) = tokio::time::timeout(Duration::ZERO, self.video.recv()).await {
            if is_rtcp(&datagram.data) {
                self.feedback_port = Some(datagram.source_port);
            } else if let Some(packet) = RtpPacket::parse(&datagram.data) {
                self.media.get_or_insert(packet.ssrc);
                video = true;
            }
        }
        video
    }

    /// Whether frames still come: what arrived since last time, or failing that the next 300 ms.
    async fn alive(&mut self) -> bool {
        if self.drain().await { return true; }
        tokio::time::sleep(Duration::from_millis(300)).await;
        self.drain().await
    }

    /// Asks the device for a key frame now (it sends one at the start and then only changes).
    async fn request_keyframe(&mut self) {
        // The device heeds a request sent to where its own reports come from, and not one sent
        // to the ports it is said to listen on (measured on iOS 27): its first report is waited for.
        if self.feedback_port.is_none() {
            let _ = tokio::time::timeout(REPORT_WAIT, async {
                while self.feedback_port.is_none() {
                    let Ok(datagram) = self.video.recv().await else { return };
                    if is_rtcp(&datagram.data) {
                        self.feedback_port = Some(datagram.source_port);
                    } else if let Some(packet) = RtpPacket::parse(&datagram.data) {
                        self.media.get_or_insert(packet.ssrc);
                    }
                }
            }).await;
        }
        let Some(media) = self.media else { return };
        let early = KEYFRAME_APART.saturating_sub(self.keyframe_at.elapsed());
        if !early.is_zero() {
            tokio::time::sleep(early).await;
            self.drain().await;   // what came meanwhile is older than the frame asked for
        }
        self.requests = self.requests.wrapping_add(1);
        let request = build_keyframe_request(self.ssrc, LABEL, media, &[], self.requests);
        // To where its feedback came from; before any has, to both places it may listen.
        match self.feedback_port {
            Some(port) => { let _ = self.video.send_to(port, request).await; }
            None => {
                let _ = self.video.send_to(VIDEO_SENDER_PORT, request.clone()).await;
                let _ = self.video.send_to(VIDEO_SENDER_PORT + 1, request).await;
            }
        }
    }

    /// The next complete key frame, as Annex-B with its parameter sets first.
    async fn next_keyframe(&mut self) -> Result<Vec<u8>, String> {
        let mut frames = HevcDepacketizer::new();
        let mut key = false;
        loop {
            let datagram = self.video.recv().await.map_err(|e| format!("video: {e:?}"))?;
            if is_rtcp(&datagram.data) {
                self.feedback_port = Some(datagram.source_port);
                continue;
            }
            let Some(packet) = RtpPacket::parse(&datagram.data) else { continue };
            if *self.media.get_or_insert(packet.ssrc) != packet.ssrc { continue; }
            let p = packet.payload;
            // A fragmented unit (type 49) names its real type in its third byte; 16...23 are key frames.
            key |= if p.len() >= 3 && (p[0] >> 1) & 0x3f == 49 { (16..=23).contains(&(p[2] & 0x3f)) }
                   else { p.len() >= 2 && (16..=23).contains(&((p[0] >> 1) & 0x3f)) };
            frames.push(packet.sequence_number, packet.timestamp, p);
            // A frame's last packet carries the RTP marker.
            if packet.marker {
                let out = frames.take_output();
                if key && frames.has_parameter_sets() && !out.is_empty() {
                    self.keyframe_at = Instant::now();
                    return Ok(out);
                }
                key = false;
            }
        }
    }
}

async fn start_stream(link: &mut Link) -> Result<Stream, String> {
    if let Some(early) = link.stream_stopped.and_then(|at| AFTER_STOP.checked_sub(at.elapsed())) {
        tokio::time::sleep(early).await;
    }
    let mut display = DisplayServiceClient::connect_rsd(&mut link.handle, &mut link.handshake)
        .await.map_err(|e| format!("display service: {e:?}"))?;
    let audio = link.handle.bind_udp(0).await.map_err(|e| format!("udp: {e:?}"))?;
    let video = link.handle.bind_udp(0).await.map_err(|e| format!("udp: {e:?}"))?;
    let (ours, theirs) = (link.handle.host_ip().to_string(), link.handle.peer_ip().to_string());
    link.stream_starts += 1;
    let session = uuid::Uuid::new_v4();
    let call = || uuid::Uuid::new_v4().to_string().to_uppercase();
    // Audio first: it is what establishes the session the video then joins.
    let offer = build_screen_audio_offer(&call(), &call_info()).map_err(|e| format!("audio offer: {e:?}"))?;
    display.start_media_stream(build_start_audio_parameters(&ours, audio.local_port(), &theirs, 50000, offer, SUPPORTED_FEATURES, session))
        .await.map_err(|e| format!("audio start: {e:?}"))?;
    let ssrc = uuid::Uuid::new_v4().as_u128() as u32;
    let video_started = match build_screen_video_offer(&call(), &call_info(), ssrc) {
        Ok(offer) => display.start_media_stream(build_start_video_parameters(&ours, video.local_port(), &theirs, VIDEO_SENDER_PORT, offer, SUPPORTED_FEATURES, 1, session))
            .await.map_err(|e| format!("video start: {e:?}")),
        Err(e) => Err(format!("video offer: {e:?}")),
    };
    let mut stream = Stream { display, video, audio, ssrc, media: None, feedback_port: None, requests: 0, keyframe_at: Instant::now() };
    if let Err(why) = video_started {
        // The sound's half did start: it is ended, not left running on the device.
        stream.stop().await;
        link.stream_stopped = Some(Instant::now());
        return Err(why);
    }
    Ok(stream)
}

/// How long a stream just started gets to send the key frame it opens with.
const FIRST_KEYFRAME: Duration = Duration::from_secs(6);

/// One key frame. From a stream already running it is asked for, twice if need be (a request
/// is one datagram, and can be lost); when none comes for the asking, or no stream runs, the
/// stream is started over, which opens with one.
async fn keyframe(link: &mut Link) -> Result<Vec<u8>, String> {
    // Asked where it is kept: taken out, it would be dropped unstopped if this were cut short.
    if let Some(stream) = link.stream.as_mut() {
        if stream.drain().await {
            for _ in 0..2 {
                stream.request_keyframe().await;
                link.keyframes_asked += 1;
                if let Ok(Ok(frame)) = tokio::time::timeout(KEYFRAME_WAIT, stream.next_keyframe()).await {
                    link.keyframes_answered += 1;
                    link.stream_used = Instant::now();
                    return Ok(frame);
                }
            }
        }
    }
    if let Some(mut stream) = link.stream.take() {
        stream.stop().await;
        link.stream_stopped = Some(Instant::now());
    }
    let mut stream = start_stream(link).await?;
    match tokio::time::timeout(FIRST_KEYFRAME, stream.next_keyframe()).await {
        Ok(Ok(frame)) => {
            link.stream = Some(stream);
            link.stream_used = Instant::now();
            Ok(frame)
        }
        Ok(Err(why)) => {
            stream.stop().await;
            link.stream_stopped = Some(Instant::now());
            Err(why)
        }
        Err(_) => {
            stream.stop().await;
            link.stream_stopped = Some(Instant::now());
            Err("the stream started but sent no key frame".into())
        }
    }
}

/// A pairing a device comes to make: this side listens and shows a code, the device's user
/// picks it in Settings and enters the code there.
pub struct RRPairing {
    runtime: tokio::runtime::Runtime,
    listener: TcpListener,
    info: PairableHostInfo,
    file: Mutex<RpPairingFile>,
    cancelled: AtomicBool,
}

/// A device that connects gets this long to ask for a code; one that stays silent is dropped
/// for the next (a connection alone doesn't mean a device that wants to pair).
const BEFORE_CODE: Duration = Duration::from_secs(25);
/// The user's part: reading the code and entering it on the device.
const ENTER_CODE: Duration = Duration::from_secs(180);
const TICK: Duration = Duration::from_millis(250);

/// # Safety
/// `name`, `model` and `host` are null or NUL-terminated strings; `advert` and `error` are null or writable.
#[no_mangle]
pub unsafe extern "C" fn rr_pairing_listen(name: *const c_char, model: *const c_char, host: *const c_char, advert: *mut *mut c_char, error: *mut *mut c_char) -> *mut RRPairing {
    let arg = |p: *const c_char| (!p.is_null()).then(|| unsafe { CStr::from_ptr(p) }.to_str().ok()).flatten();
    let listening = match (arg(name), arg(model), arg(host)) {
        (Some(name), Some(model), Some(host)) => tokio::runtime::Builder::new_multi_thread().worker_threads(1).thread_stack_size(STACK).enable_all().build()
            .map_err(|e| format!("no runtime: {e}"))
            .and_then(|runtime| {
                // Both families: the device reaches this Mac by whichever address its name resolves to.
                let listener = runtime.block_on(TcpListener::bind("[::]:0")).map_err(|e| format!("can't listen: {e}"))?;
                let port = listener.local_addr().map_err(|e| format!("no port: {e}"))?.port();
                // One identity per `host`, whatever it is named: pairing again replaces the
                // device's record of it, and another Mac of the same name doesn't.
                let file = RpPairingFile::generate(&format!("{LABEL} {host}"));
                let mut info = PairableHostInfo::generate(name, model);
                (info.serial_number, info.mac) = own_hardware(file.identifier());
                let txt = info.mdns_txt_records(file.identifier()).iter()
                    .map(|(k, v)| format!("{}:{}", quoted(k), quoted(v))).collect::<Vec<_>>().join(",");
                let said = format!("{{\"port\":{port},\"identifier\":{},\"txt\":{{{txt}}}}}", quoted(file.identifier()));
                Ok((RRPairing { runtime, listener, info, file: Mutex::new(file), cancelled: AtomicBool::new(false) }, said))
            }),
        _ => Err("bad arguments".into()),
    };
    match listening {
        Ok((pairing, said)) => {
            if !advert.is_null() { unsafe { *advert = c_string(said) }; }
            Box::into_raw(Box::new(pairing))
        }
        Err(why) => {
            unsafe { set_error(error, why) };
            std::ptr::null_mut()
        }
    }
}

/// # Safety
/// `pairing` came from rr_pairing_listen and wasn't freed; `code` may be called, from another
/// thread, until this returns. The answer carries the pairing itself ("pairing", a property
/// list's text, with this side's private key): nothing is written anywhere.
#[no_mangle]
pub unsafe extern "C" fn rr_pairing_accept(
    pairing: *mut RRPairing,
    code: Option<unsafe extern "C" fn(*const c_char, *mut std::ffi::c_void)>, context: *mut std::ffi::c_void,
) -> *mut c_char {
    let Some(pairing) = (unsafe { pairing.as_ref() }) else { return std::ptr::null_mut() };
    let Some(code) = code else { return c_string(failure("bad arguments")) };
    let context = context as usize;   // an address, carried to the thread that shows the code
    let show = move |pin: &str| {
        if let Ok(pin) = CString::new(pin) { unsafe { code(pin.as_ptr(), context as *mut std::ffi::c_void) } }
    };
    let result = with_room(|| pairing.runtime.block_on(accept_pairing(pairing, &show)));
    c_string(match result {
        Ok((peer, file)) => format!("{{\"ok\":true,\"udid\":{},\"name\":{},\"model\":{},\"pairing\":{}}}",
                            quoted(&peer.remotepairing_udid), quoted(&peer.name), quoted(&peer.model), quoted(&file)),
        Err(why) => failure(&why),
    })
}

/// Makes a running rr_pairing_accept return, and the next one return at once.
///
/// # Safety
/// `pairing` came from rr_pairing_listen and wasn't freed, or is null.
#[no_mangle]
pub unsafe extern "C" fn rr_pairing_cancel(pairing: *mut RRPairing) {
    if let Some(pairing) = unsafe { pairing.as_ref() } { pairing.cancelled.store(true, Ordering::Relaxed); }
}

/// # Safety
/// `pairing` came from rr_pairing_listen, no rr_pairing_accept runs on it, and it isn't used again; or null.
#[no_mangle]
pub unsafe extern "C" fn rr_pairing_free(pairing: *mut RRPairing) {
    if !pairing.is_null() {
        let RRPairing { runtime, listener, .. } = *unsafe { Box::from_raw(pairing) };
        { let _in = runtime.enter(); drop(listener); }   // its socket closes inside the runtime that made it
    }
}

/// A serial number and an address for one identity, the same each time: the device lists the
/// hosts it is paired with by them, so each identity is an entry of its own there, removed
/// alone — and pairing again as the same one stays the same entry.
fn own_hardware(identifier: &str) -> (String, [u8; 6]) {
    let hex: Vec<u8> = identifier.bytes().filter(u8::is_ascii_hexdigit).map(|b| b.to_ascii_uppercase()).collect();
    let digit = |i: usize| (hex.get(i).copied().unwrap_or(b'0') as char).to_digit(16).unwrap_or(0) as u8;
    let serial = (0..12).map(|i| hex.get(i).copied().unwrap_or(b'0') as char).collect();
    let mut mac = [0u8; 6];
    for (i, byte) in mac.iter_mut().enumerate() { *byte = digit(12 + i * 2) << 4 | digit(13 + i * 2); }
    mac[0] = (mac[0] | 0x02) & 0xFE;   // an address made up here, of one station
    (serial, mac)
}

async fn accept_pairing(pairing: &RRPairing, show: &(impl Fn(&str) + Sync)) -> Result<(idevice::remote_pairing::PeerDevice, String), String> {
    let cancelled = || pairing.cancelled.load(Ordering::Relaxed);
    loop {
        let stream = loop {
            if cancelled() { return Err("cancelled".into()); }
            if let Ok(accepted) = tokio::time::timeout(TICK, pairing.listener.accept()).await {
                break accepted.map_err(|e| format!("can't accept: {e}"))?.0;
            }
        };
        let mut file = pairing.file.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let mut host = PairableHost::new(RpPairingSocket::new_device(stream), pairing.info.clone());
        let shown: Mutex<Option<Instant>> = Mutex::new(None);
        let when_shown = || *shown.lock().unwrap_or_else(|e| e.into_inner());
        let connected = Instant::now();
        let outcome = {
            let exchange = host.accept(&mut file, |pin| {
                *shown.lock().unwrap_or_else(|e| e.into_inner()) = Some(Instant::now());
                show(&pin);
                std::future::ready(())
            });
            tokio::pin!(exchange);
            loop {
                tokio::select! {
                    done = &mut exchange => break Some(done),
                    _ = tokio::time::sleep(TICK) => {
                        if cancelled() { return Err("cancelled".into()); }
                        match when_shown() {
                            None if connected.elapsed() >= BEFORE_CODE => break None,
                            Some(at) if at.elapsed() >= ENTER_CODE => return Err("the code wasn't entered in time".into()),
                            _ => {}
                        }
                    }
                }
            }
        };
        match outcome {
            Some(Ok(peer)) => {
                let file = String::from_utf8(file.to_bytes()).map_err(|_| "the pairing isn't text".to_string())?;
                return Ok((peer, file));
            }
            // After the code was shown, a failure is the pairing's (a wrong code, a change of mind).
            Some(Err(e)) if when_shown().is_some() => return Err(format!("the pairing didn't complete: {e:?}")),
            // Before it, it was no device that wanted to pair: the next one is waited for.
            _ => continue,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn io(kind: std::io::ErrorKind) -> idevice::IdeviceError { idevice::IdeviceError::Socket(std::io::Error::from(kind)) }

    #[test]
    fn an_input_is_sent_again_only_when_none_of_it_went() {
        let gone = io(std::io::ErrorKind::NotConnected);
        assert!(again(0, true, false, &gone));
        assert!(!again(0, true, true, &gone));    // part of it reached the device: a swipe isn't made twice
        assert!(!again(1, true, false, &gone));   // once
        assert!(!again(0, false, false, &gone));  // a connection just made: not one found gone
        assert!(!again(0, true, false, &io(std::io::ErrorKind::BrokenPipe)));
    }

    #[test]
    fn a_tap_and_a_drag_are_what_a_finger_does() {
        assert_eq!(tap_steps(10, 20), vec![Touch::At(TOUCHSCREEN_STATE_CONTACT, 10, 20), Touch::Wait(50), Touch::At(TOUCHSCREEN_STATE_RELEASE, 10, 20)]);
        let drag = drag_steps((0, 100), (100, 0), 4, 16);
        let at: Vec<_> = drag.iter().filter_map(|s| match s { Touch::At(state, x, y) => Some((*state, *x, *y)), _ => None }).collect();
        assert_eq!(at, vec![
            (TOUCHSCREEN_STATE_CONTACT, 0, 100), (TOUCHSCREEN_STATE_CONTACT, 25, 75), (TOUCHSCREEN_STATE_CONTACT, 50, 50),
            (TOUCHSCREEN_STATE_CONTACT, 75, 25), (TOUCHSCREEN_STATE_CONTACT, 100, 0), (TOUCHSCREEN_STATE_RELEASE, 100, 0),
        ]);
        assert_eq!(drag.iter().filter(|s| matches!(s, Touch::Wait(16))).count(), 4);
        assert_eq!(drag_steps((5, 5), (9, 9), 0, 16).len(), 4);   // never no samples
    }

    #[test]
    fn what_is_sent_is_given_up_at_the_deadline() {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_time().build().unwrap();
        let started = Instant::now();
        let stalled = runtime.block_on(within(Instant::now() + Duration::from_millis(60), std::future::pending::<()>()));
        assert!(stalled.is_err());
        assert!(started.elapsed() < Duration::from_secs(2));
        assert_eq!(runtime.block_on(within(Instant::now() + Duration::from_secs(5), async { 7 })), Ok(7));
    }

    #[test]
    fn each_identity_has_hardware_of_its_own() {
        let one = RpPairingFile::generate("roamrun A");
        let (serial, mac) = own_hardware(one.identifier());
        assert_eq!(serial.len(), 12);
        assert!(serial.bytes().all(|b| b.is_ascii_digit() || b.is_ascii_uppercase()));
        assert_eq!(mac[0] & 0x03, 0x02);
        // The same identity again: the same entry on the device.
        assert_eq!(own_hardware(RpPairingFile::generate("roamrun A").identifier()), (serial.clone(), mac));
        // Another: an entry of its own.
        let (other_serial, other_mac) = own_hardware(RpPairingFile::generate("roamrun B").identifier());
        assert_ne!(other_serial, serial);
        assert_ne!(other_mac, mac);
        // Not the ones every host had.
        assert_ne!(serial, "AAAAAAAAAAAA");
        assert_eq!(own_hardware("").0, "000000000000");   // nothing to go by: still twelve characters
    }

    /// An input's deadline grows with what it has to send: a long text isn't cut in the middle.
    #[test]
    fn an_input_gets_the_time_its_length_needs() {
        let ten = Duration::from_secs(10);
        assert_eq!(input_time(&Input::Tap(0.5, 0.5)), ten + Duration::from_millis(100));
        assert_eq!(input_time(&Input::Swipe { from: (0.0, 0.0), to: (1.0, 1.0), ms: 5000 }), ten + Duration::from_secs(5));
        let long = Input::Type(vec![(0x04, false); LONGEST_TYPED]);
        assert_eq!(input_time(&long), ten + Duration::from_secs(400));   // 2000 keys at 200 ms each
        assert!(input_time(&Input::Type(vec![(0x04, false); 5])) < DEADLINE);
    }

    /// Every character a US keyboard has maps to its key, shifted or not; anything else to none.
    #[test]
    fn keys_are_those_of_a_us_keyboard() {
        assert_eq!(key('a'), Some((0x04, false)));
        assert_eq!(key('Z'), Some((0x1D, true)));
        assert_eq!(key('1'), Some((0x1E, false)));
        assert_eq!(key('0'), Some((0x27, false)));
        assert_eq!(key('!'), Some((0x1E, true)));
        assert_eq!(key(')'), Some((0x27, true)));
        assert_eq!(key(' '), Some((0x2C, false)));
        assert_eq!(key('\n'), Some((0x28, false)));
        assert_eq!(key('-'), Some((0x2D, false)));
        assert_eq!(key('_'), Some((0x2D, true)));
        assert_eq!(key('?'), Some((0x38, true)));
        assert_eq!(key('あ'), None);
        assert_eq!(key('\t'), None);
    }

    /// Only a write to a connection that is no longer there is one nothing was sent on.
    #[test]
    fn only_a_connection_that_is_gone_is_sent_on_anew() {
        let io = |kind| idevice::IdeviceError::Socket(std::io::Error::new(kind, "x"));
        assert!(gone(&io(std::io::ErrorKind::NotConnected)));
        assert!(!gone(&io(std::io::ErrorKind::BrokenPipe)));
        assert!(!gone(&io(std::io::ErrorKind::ConnectionReset)));
        assert!(!gone(&io(std::io::ErrorKind::TimedOut)));
    }

    #[test]
    fn json_strings_are_quoted_whole() {
        assert_eq!(quoted("a\"b\\c\n\u{0}"), "\"a\\\"b\\\\c\\u000a\\u0000\"");
    }
}
