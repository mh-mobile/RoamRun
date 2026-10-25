//! RoamRun's C ABI over idevice. rr_device_tap, _swipe, _type, _paste and
//! _button operate the device; rr_device_elements can scroll it.

pub mod proxy;
pub mod safe;

use std::ffi::{c_char, CStr, CString};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use idevice::core_device::hid::{
    build_touchscreen_report, ButtonState, HidSurface, IndigoHidClient, UniversalHidServiceClient, DIGITIZER_SURFACE_MAIN_TOUCHSCREEN,
    TOUCHSCREEN_STATE_CONTACT, TOUCHSCREEN_STATE_RELEASE,
};
use idevice::dvt::message::AuxValue;
use idevice::dvt::remote_server::RemoteServerClient;
use idevice::core_device::{
    build_keyframe_request, build_screen_audio_offer, build_screen_video_offer, build_start_audio_parameters,
    build_start_video_parameters, is_rtcp, CallInfoBlob, DisplayServiceClient, HevcDepacketizer, ImageFormat, PasteboardServiceClient, RtpPacket,
    ScreenCaptureServiceClient, GENERAL_PASTEBOARD,
};
use idevice::remote_pairing::{
    connect_tls_psk_tunnel_native, PairableHost, PairableHostInfo, RemotePairingClient, RpPairingFile, RpPairingSocket,
};
use idevice::rsd::RsdHandshake;
use idevice::tcp::adapter::Adapter;
use idevice::tcp::handle::{AdapterHandle, UdpSocketHandle};
use idevice::provider::RsdProvider;
use idevice::{ReadWrite, RsdService};
use tokio::net::TcpListener;

const VERSION: &CStr = c"0.6.0";
const LABEL: &str = "roamrun";
/// Each call: a device that stops answering mid-way must not hang the caller.
const DEADLINE: Duration = Duration::from_secs(20);
/// A call that starts a screen stream: its steps that wait on the device have limits of their own
/// and stop what they started, which a deadline falling inside them couldn't. This only ends what
/// those don't.
const STREAM_DEADLINE: Duration = Duration::from_secs(45);
/// A look's PNG, its size the screen's (6 MB took 12 s, on the Mac's own Wi‑Fi, and 3.9 MB once
/// 19 s). ponytail: a fixed limit; ending only when nothing arrives would need the service's
/// stream wrapped.
const SHOT_TIME: Duration = Duration::from_secs(60);
/// The device's word on its screen's size: a look waits for it, and does without it.
const SCREEN_WAIT: Duration = Duration::from_secs(5);
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
    /// Inputs go with no screen stream started for them.
    bare_inputs: bool,
    /// Raised by the caller from another thread when the device is to be let go of: a long
    /// input stops between two keys. The caller's, and outlives this.
    stop: Stop,
    /// The key or button down now (not Shift or Command), as (is a button, page or 0, usage):
    /// let go of when an input is cut off between its down and its up.
    held: Option<(bool, u64, u64)>,
    /// Where a finger is down on the screen, for the same.
    finger: Option<(u16, u16)>,
    /// The uniqueId of the display on when last asked (a stream starting, a screenshot), for touches to go to it.
    shown: Option<String>,
    /// That display's id, for a stream to show it.
    shown_id: Option<i64>,
    /// That display's touch surface, found on the HID connection; again after a stream starts.
    touchscreen: Option<u64>,
    verified_ms: u128,
    tunnel_ms: u128,
    rsd_ms: u128,
}

struct Stop(*const AtomicBool);
// Only read, and atomic.
unsafe impl Send for Stop {}

impl Stop {
    fn raised(&self) -> bool { !self.0.is_null() && unsafe { &*self.0 }.load(Ordering::Relaxed) }
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
    unsafe { open_with(ip, port, pairing, pairing_len, None, error) }
}

/// As rr_device_open, for a pairing whose private key is kept elsewhere: `pairing` is the pairing with any
/// key in the private key's place, and `sign` is asked for the one signature a connection takes — given what
/// is to be signed, it writes the 64 bytes of the signature and returns true, or returns false. Called on
/// another thread, before this returns.
/// # Safety
/// As rr_device_open; `sign` and `context` are good until this returns.
#[no_mangle]
pub unsafe extern "C" fn rr_device_open_signed(
    ip: *const c_char, port: u16, pairing: *const u8, pairing_len: usize,
    sign: Option<unsafe extern "C" fn(*const u8, usize, *mut u8, *mut std::ffi::c_void) -> bool>, context: *mut std::ffi::c_void,
    error: *mut *mut c_char,
) -> *mut RRDevice {
    let Some(sign) = sign else {
        unsafe { set_error(error, "bad arguments".into()) };
        return std::ptr::null_mut();
    };
    let context = context as usize;   // an address, carried to the thread that verifies
    let signer: Signer = Arc::new(move |what: &[u8]| {
        let mut signature = [0u8; 64];
        if unsafe { sign(what.as_ptr(), what.len(), signature.as_mut_ptr(), context as *mut std::ffi::c_void) } { Ok(signature) } else { Err("the key's holder didn't sign".into()) }
    });
    unsafe { open_with(ip, port, pairing, pairing_len, Some(signer), error) }
}

unsafe fn open_with(ip: *const c_char, port: u16, pairing: *const u8, pairing_len: usize, signer: Option<Signer>, error: *mut *mut c_char) -> *mut RRDevice {
    let ip = (!ip.is_null()).then(|| unsafe { CStr::from_ptr(ip) }.to_str().ok()).flatten();
    let file = (!pairing.is_null()).then(|| unsafe { std::slice::from_raw_parts(pairing, pairing_len) });
    let opened = match (ip, file) {
        (Some(ip), Some(file)) => tokio::runtime::Builder::new_multi_thread().worker_threads(1).thread_stack_size(STACK).enable_all().build()
            .map_err(|e| format!("no runtime: {e}"))
            .and_then(|runtime| {
                let link = with_room(|| runtime.block_on(async {
                    tokio::time::timeout(DEADLINE, connect(ip, port, file, signer.clone())).await.unwrap_or_else(|_| Err("timed out".into()))
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
/// `device` came from rr_device_open and wasn't closed; `flag` is one byte, zero, that stays
/// where it is for as long as the device is open.
#[no_mangle]
pub unsafe extern "C" fn rr_device_stop_at(device: *mut RRDevice, flag: *const u8) {
    let device = unsafe { &*device };
    device.link.lock().unwrap_or_else(|e| e.into_inner()).stop = Stop(flag.cast());
}

/// Inputs from here on are sent with no screen stream started for them (or with one, as at first).
/// # Safety
/// `device` came from rr_device_open and wasn't closed.
#[no_mangle]
pub unsafe extern "C" fn rr_device_bare_inputs(device: *mut RRDevice, bare: bool) {
    let device = unsafe { &*device };
    device.link.lock().unwrap_or_else(|e| e.into_inner()).bare_inputs = bare;
}

/// # Safety
/// `flag` is the byte given to rr_device_stop_at. Any thread.
#[no_mangle]
pub unsafe extern "C" fn rr_flag_raise(flag: *mut u8) {
    unsafe { &*flag.cast::<AtomicBool>() }.store(true, Ordering::Relaxed);
}

/// # Safety
/// `flag` is the byte given to rr_device_stop_at. Any thread: for a stop that was for one call.
#[no_mangle]
pub unsafe extern "C" fn rr_flag_lower(flag: *mut u8) {
    unsafe { &*flag.cast::<AtomicBool>() }.store(false, Ordering::Relaxed);
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
            link.stop = Stop(std::ptr::null());   // the caller's, and no longer there after this
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

/// The device's own word on its displays.
struct DeviceInfo(idevice::core_device::CoreDeviceServiceClient<Box<dyn ReadWrite>>);

impl RsdService for DeviceInfo {
    fn rsd_service_name() -> std::borrow::Cow<'static, str> { "com.apple.coredevice.deviceinfo".into() }
    async fn from_stream(stream: Box<dyn ReadWrite>) -> Result<Self, idevice::IdeviceError> {
        Ok(Self(idevice::core_device::CoreDeviceServiceClient::new(stream).await?))
    }
}

/// Whether the tunnel still carries a connection to the device: one is opened to a port the
/// device said it listens on, and closed. A few hundred bytes; no service is spoken to, so
/// nothing shows on the device and its sound stays.
/// # Safety
/// `device` came from rr_device_open and wasn't closed.
#[no_mangle]
pub unsafe extern "C" fn rr_device_alive(device: *mut RRDevice) -> *mut c_char {
    let Some(device) = (unsafe { device.as_ref() }) else { return std::ptr::null_mut() };
    let result = with_room(|| {
        let mut link = device.link.lock().unwrap_or_else(|e| e.into_inner());
        let link = &mut *link;
        let Some(port) = link.handshake.services.values().map(|s| s.port).min() else { return Err("no service to ask".to_string()) };
        device.runtime.block_on(async {
            match tokio::time::timeout(SCREEN_WAIT, link.handle.connect_to_service_port(port)).await {
                Ok(Ok(_)) => Ok(()),
                Ok(Err(e)) => Err(format!("tunnel: {e:?}")),
                Err(_) => Err("timed out".into()),
            }
        })
    });
    c_string(match result {
        Ok(()) => "{\"ok\":true}".to_string(),
        Err(why) => failure(&why),
    })
}

/// What the device says of its displays.
async fn display_info(link: &mut Link) -> Result<plist::Value, String> {
    let mut info = DeviceInfo::connect_rsd(&mut link.handle, &mut link.handshake).await.map_err(|e| format!("device info service: {e:?}"))?;
    info.0.invoke("com.apple.coredevice.feature.getdisplayinfo", None).await.map_err(|e| format!("displays: {e:?}"))
}

/// The device's own display that is on: the one marked active, else primary, else the first;
/// an external one isn't taken. A device with two screens marks primary the one that may be off.
fn shown_display(displays: &plist::Value) -> Option<&plist::Dictionary> {
    let flag = |d: &plist::Dictionary, key: &str| d.get(key).and_then(|v| v.as_boolean()) == Some(true);
    let own: Vec<_> = displays.as_dictionary()?.get("displays")?.as_array()?.iter().filter_map(|d| d.as_dictionary()).filter(|d| !flag(d, "external")).collect();
    let marked = |key: &str| own.iter().find(|d| flag(d, key)).copied();
    marked("active").or_else(|| marked("primary")).or_else(|| own.first().copied())
}

/// The shown display's uniqueId, which names its touch surface.
fn unique_id(displays: &plist::Value) -> Option<String> {
    shown_display(displays)?.get("uniqueId")?.as_string().map(str::to_string)
}

/// What the device says of its displays now, kept as which one is on; a touch surface found for
/// another is let go of. None when the device doesn't answer in time.
async fn ask_shown(link: &mut Link) -> Option<plist::Value> {
    let displays = tokio::time::timeout(DISPLAY_WAIT, display_info(link)).await.ok().and_then(|d| d.ok());
    let (unique, id) = kept_shown((link.shown.clone(), link.shown_id), displays.as_ref());
    if unique != link.shown { link.touchscreen = None; }
    (link.shown, link.shown_id) = (unique, id);
    displays
}

/// Which display is on, from the device's answer; with no answer in time, the one known before:
/// the primary one taken instead was, on a two-screen device opened, the screen that is off.
fn kept_shown(known: (Option<String>, Option<i64>), answer: Option<&plist::Value>) -> (Option<String>, Option<i64>) {
    match answer {
        Some(displays) => (unique_id(displays), display_id(displays)),
        None => known,
    }
}

/// The shown display's id, for the stream to show it.
fn display_id(displays: &plist::Value) -> Option<i64> {
    shown_display(displays)?.get("displayId")?.as_signed_integer()
}

/// The shown display's size in pixels, from what the device says of its displays.
fn screen_size(displays: &plist::Value) -> Option<(u32, u32)> {
    let size = shown_display(displays)?.get("nativeSize")?.as_array()?;
    let side = |v: &plist::Value| v.as_real().or(v.as_unsigned_integer().map(|n| n as f64)).filter(|n| (1.0..=65535.0).contains(n)).map(|n| n as u32);
    match size.as_slice() {
        [w, h] => Some((side(w)?, side(h)?)),
        _ => None,
    }
}

/// # Safety
/// `device` came from rr_device_open and wasn't closed.
#[no_mangle]
pub unsafe extern "C" fn rr_device_screen(device: *mut RRDevice) -> *mut c_char {
    let Some(device) = (unsafe { device.as_ref() }) else { return std::ptr::null_mut() };
    let result = with_room(|| {
        let mut link = device.link.lock().unwrap_or_else(|e| e.into_inner());
        let link = &mut *link;
        if link.stop.raised() { return Err(STOPPED.into()); }
        device.runtime.block_on(async {
            tokio::time::timeout(SCREEN_WAIT, async {
                screen_size(&display_info(link).await?).ok_or_else(|| "displays: no size in the answer".to_string())
            }).await.unwrap_or_else(|_| Err("timed out".into()))
        })
    });
    c_string(match result {
        Ok((width, height)) => format!("{{\"ok\":true,\"width\":{width},\"height\":{height}}}"),
        Err(why) => failure(&why),
    })
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
        if link.stop.raised() { return Err(STOPPED.into()); }
        device.runtime.block_on(async {
            tokio::time::timeout(STREAM_DEADLINE, keyframe(&mut link)).await.unwrap_or_else(|_| Err("timed out".into()))
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

/// The screen as a PNG the device makes itself: no stream is started for it.
/// # Safety
/// `device` came from rr_device_open and wasn't closed; `length` and `error` are null or writable.
#[no_mangle]
pub unsafe extern "C" fn rr_device_screenshot(device: *mut RRDevice, length: *mut usize, error: *mut *mut c_char) -> *mut u8 {
    let (Some(device), false) = (unsafe { device.as_ref() }, length.is_null()) else {
        unsafe { set_error(error, "bad arguments".into()) };
        return std::ptr::null_mut();
    };
    let result = with_room(|| {
        let mut link = device.link.lock().unwrap_or_else(|e| e.into_inner());
        if link.stop.raised() { return Err(STOPPED.into()); }
        let link = &mut *link;
        device.runtime.block_on(async {
            // Of the display that is on (the primary one, when not told, can be off); asked each
            // time, as a look comes before each touch: one after the screen changed goes to it.
            ask_shown(link).await;
            let shown = link.shown.clone();
            let mut capture = tokio::time::timeout(DEADLINE, ScreenCaptureServiceClient::connect_rsd(&mut link.handle, &mut link.handshake)).await
                .map_err(|_| "screenshot service: timed out".to_string())?
                .map_err(|e| format!("screenshot service: {e:?}"))?;
            tokio::time::timeout(SHOT_TIME, capture.take_screenshot(shown.as_deref(), ImageFormat::Png)).await
                .map_err(|_| "screenshot: timed out".to_string())?
                .map_err(|e| format!("screenshot: {e:?}"))
        })
    });
    match result {
        Ok(image) => {
            let boxed = image.into_boxed_slice();
            unsafe { *length = boxed.len() };
            Box::into_raw(boxed) as *mut u8
        }
        Err(why) => {
            unsafe { set_error(error, why) };
            std::ptr::null_mut()
        }
    }
}

/// Which way up the device's interface is: 1 portrait, 2 upside down, 3 on its side with the home
/// indicator at the right, 4 with it at the left; 0 when the device doesn't say. A screenshot comes
/// turned as the interface is, and a touch is sent in the device's own upright terms.
/// # Safety
/// `device` came from rr_device_open and wasn't closed.
#[no_mangle]
pub unsafe extern "C" fn rr_device_way(device: *mut RRDevice) -> u8 {
    let Some(device) = (unsafe { device.as_ref() }) else { return 0 };
    with_room(|| {
        let mut link = device.link.lock().unwrap_or_else(|e| e.into_inner());
        let link = &mut *link;
        Ok(device.runtime.block_on(async {
            tokio::time::timeout(SCREEN_WAIT, interface_way(link)).await.ok().flatten().unwrap_or(0)
        }))
    }).unwrap_or(0)
}

async fn interface_way(link: &mut Link) -> Option<u8> {
    use idevice::springboardservices::{InterfaceOrientation, SpringBoardServicesClient};
    let port = link.handshake.services.get("com.apple.springboardservices.shim.remote")?.port;
    let stream = link.handle.connect_to_service_port(port).await.ok()?;
    // A lockdown service bridged onto RSD: it wants a check-in before its own protocol.
    let mut plain = idevice::Idevice::new(Box::new(stream), LABEL);
    plain.rsd_checkin().await.ok()?;
    Some(match SpringBoardServicesClient::new(plain).get_interface_orientation().await.ok()? {
        InterfaceOrientation::Portrait => 1,
        InterfaceOrientation::PortraitUpsideDown => 2,
        InterfaceOrientation::LandscapeRight => 3,
        InterfaceOrientation::LandscapeLeft => 4,
        _ => 0,
    })
}

/// What is at `path`, in megabytes, and how long an install of it is given: five minutes, and fifteen seconds a
/// megabyte. One took three to four on the device's own Wi‑Fi (iPhone 15 Pro, iOS 27.0: 3 MB in 25 s, 37 MB in 150 s):
/// some four times that, for a slower way there. It is there to end what hangs, not what is slow.
pub fn install_given(path: &str) -> (u64, Duration) {
    fn size(path: &std::path::Path) -> u64 {
        match std::fs::read_dir(path) {
            Ok(inside) => inside.flatten().map(|entry| size(&entry.path())).sum(),
            Err(_) => std::fs::metadata(path).map(|meta| meta.len()).unwrap_or(0),
        }
    }
    let megabytes = size(std::path::Path::new(path)) >> 20;
    (megabytes, Duration::from_secs(300 + 15 * megabytes))
}

/// The most an .ipa may unpack to, by what its archive says (the device unpacks it), and the most of each
/// Info.plist read here (idevice reads all of each one it meets, however much it inflates to).
const UNPACKED: u64 = 4 << 30;
const INFO_PLIST: u64 = 1 << 20;

/// The bundle identifier of the app in the .ipa at `path`, checked before anything of it is sent: `Payload`
/// holds one `<name>.app` and nothing else but hidden files (a `.bundle` idevice would install as another kind of
/// package; a name ending in `.app` is an app, hidden or not), the first Info.plist idevice takes a bundle
/// identifier from is the app's, and it unpacks to `UNPACKED` at most.
pub fn ipa_checked(path: &str) -> Result<String, String> {
    ipa_within(path, UNPACKED, INFO_PLIST)
}

fn ipa_within(path: &str, unpacked: u64, info_plist: u64) -> Result<String, String> {
    use futures_lite::io::{AssertAsync, AsyncReadExt, BufReader};
    let not = |why: String| format!("{path} isn't an app's .ipa: {why}");
    let file = std::fs::File::open(path).map_err(|e| format!("{path}: {e}"))?;
    futures_lite::future::block_on(async {
        // The same reader idevice finds the app with: what is checked is what it will read.
        let mut zip = async_zip::base::read::seek::ZipFileReader::new(BufReader::new(AssertAsync::new(file))).await.map_err(|e| not(format!("{e}")))?;
        let (mut app, mut plists, mut size) = (None, Vec::new(), 0u64);
        for (index, entry) in zip.file().entries().iter().enumerate() {
            let name = entry.filename().as_str().map_err(|_| not("a name in it isn't UTF-8".into()))?.trim_end_matches('/');
            size = size.saturating_add(entry.uncompressed_size());
            // Where idevice looks for the app's Info.plist: any name of three parts ending so.
            if name.ends_with("Info.plist") && name.split('/').count() == 3 { plists.push((index, name.to_string(), entry.uncompressed_size())) }
            let Some(top) = name.strip_prefix("Payload/").and_then(|rest| rest.split('/').next()) else { continue };
            // A hidden file beside the app (Finder's .DS_Store) is nothing idevice takes; "._A.app" it could take for the app.
            if top.starts_with('.') && !top.ends_with(".app") && !top.ends_with(".bundle") { continue }
            if !top.ends_with(".app") || app.is_some_and(|app| app != top) {
                return Err(not(format!("Payload/{top}{}: it holds one app (.app) and nothing else", app.map_or(String::new(), |app| format!(" beside {app}")))));
            }
            app = Some(top);
        }
        let app = app.ok_or_else(|| not("no Payload/<name>.app in it".into()))?.to_string();
        if size > unpacked { return Err(not(format!("it says it unpacks to {} MB, more than {} MB", size >> 20, unpacked >> 20))) }
        // As idevice reads them: in order, each whole, until one says a bundle identifier.
        for (index, name, declared) in plists {
            // By what comes out, not by what it says: what it says can be less.
            let mut read = Vec::new();
            if declared <= info_plist {
                let entry = zip.reader_without_entry(index).await.map_err(|e| not(format!("{e}")))?;
                entry.take(info_plist + 1).read_to_end(&mut read).await.map_err(|e| not(format!("{e}")))?;
            }
            if declared > info_plist || read.len() as u64 > info_plist { return Err(not(format!("{name} is more than {} KB", info_plist >> 10))) }
            let info = plist::from_bytes::<plist::Value>(&read).map_err(|e| not(format!("{name} isn't a plist: {e}")))?;
            let Some(id) = info.as_dictionary().and_then(|info| info.get("CFBundleIdentifier")?.as_string()) else { continue };
            if name != format!("Payload/{app}/Info.plist") { return Err(not(format!("{name} is where the app's Info.plist would be looked for"))) }
            return Ok(id.to_string());
        }
        Err(not("no Info.plist where the app's is looked for says a bundle identifier".into()))
    })
}

/// What `rr_device_install` and `rr_device_launch` share: one thing asked of the device's app services.
/// An install carries the app's bundle identifier where it is known: its running processes are ended first.
enum App<'a> { Install(&'a str, Option<String>), Launch(&'a str) }

fn app(device: &RRDevice, what: App) -> String {
    let result = with_room(|| {
        let mut link = device.link.lock().unwrap_or_else(|e| e.into_inner());
        if link.stop.raised() { return Err(STOPPED.into()); }
        let link = &mut *link;
        device.runtime.block_on(async {
            // An install sends the whole app: longer than a call's deadline, and longer the more there is of it.
            let given = match what { App::Install(path, _) => install_given(path).1, App::Launch(_) => Duration::from_secs(300) };
            tokio::time::timeout(given, async {
                match what {
                    App::Install(path, bundle) => {
                        // An app folder is laid over what an earlier, cut-short install of that name left where
                        // the device keeps them: cleared first, or the app taken in is the two mixed.
                        if let Some(name) = std::path::Path::new(path).file_name().and_then(|n| n.to_str()).filter(|_| std::path::Path::new(path).is_dir()) {
                            if let Ok(mut files) = idevice::afc::AfcClient::connect_rsd(&mut link.handle, &mut link.handshake).await {
                                let _ = files.remove_all(format!("PublicStaging/{name}")).await;
                            }
                        }
                        // At most 10 s of the install's time: not answered within it, the install goes on without it.
                        if let Some(bundle) = bundle { let _ = tokio::time::timeout(Duration::from_secs(10), end_running(link, &bundle)).await; }
                        idevice::utils::installation::install_package_rsd(&mut link.handle, &mut link.handshake, path, None)
                            .await.map(|()| String::new()).map_err(|e| format!("install: {e:?}"))
                    }
                    App::Launch(bundle) => {
                        let mut apps = idevice::core_device::AppServiceClient::connect_rsd(&mut link.handle, &mut link.handshake)
                            .await.map_err(|e| format!("app service: {e:?}"))?;
                        // One already running is ended: the one that answers is the one just started.
                        apps.launch_application(bundle, &[], true, false, None, None, None)
                            .await.map(|said| format!(",\"pid\":{}", said.pid)).map_err(|e| format!("launch: {e:?}"))
                    }
                }
            }).await.unwrap_or_else(|_| Err("timed out".into()))
        })
    });
    match result {
        Ok(more) => format!("{{\"ok\":true{more}}}"),
        Err(why) => failure(&why),
    }
}

/// The app's running processes, ended before it is replaced. iOS ends them itself, but not one in front while the
/// device is on a wireless charger (cable charging untried): it waits until the app isn't, which held installs for minutes (iOS 27.0). Ended here first;
/// where anything of it fails, the install goes on as it would have. Where the app is is asked of
/// installation_proxy: AppService's list of apps didn't answer over this connection.
async fn end_running(link: &mut Link, bundle: &str) {
    let Ok(mut lookup) = idevice::installation_proxy::InstallationProxyClient::connect_rsd(&mut link.handle, &mut link.handshake).await else { return };
    let found = lookup.get_apps(Some("User"), Some(vec![bundle.to_string()])).await.ok();
    let Some(app) = found.as_ref().and_then(|found| found.get(bundle)?.as_dictionary()?.get("Path")?.as_string()) else { return };
    let Ok(mut apps) = idevice::core_device::AppServiceClient::connect_rsd(&mut link.handle, &mut link.handshake).await else { return };
    let Ok(processes) = apps.list_processes().await else { return };
    for pid in inside(app, processes.iter().map(|p| (p.pid, p.executable_url.as_ref().map(|u| u.relative.as_str())))) {
        let _ = apps.send_signal(pid, 9).await;
    }
}

/// The pids of `processes` (pid, executable URL) whose executable is inside the app at `app` on the device: a
/// path as installation_proxy gives it, while the URLs are percent-encoded ("My%20App.app"). None for no path.
fn inside<'a>(app: &str, processes: impl Iterator<Item = (u32, Option<&'a str>)>) -> Vec<u32> {
    let app = app.trim_end_matches('/');
    if app.is_empty() { return Vec::new() }
    let within = format!("{app}/");
    processes.filter(|(_, url)| url.and_then(file_path).is_some_and(|path| path.starts_with(&within))).map(|(pid, _)| pid).collect()
}

/// The path a `file://` URL names, its %XX escapes undone; None for another URL, a broken escape, or what isn't UTF-8.
fn file_path(url: &str) -> Option<String> {
    let mut bytes = url.strip_prefix("file://")?.bytes();
    let mut path = Vec::new();
    while let Some(b) = bytes.next() {
        path.push(if b == b'%' { u8::from_str_radix(std::str::from_utf8(&[bytes.next()?, bytes.next()?]).ok()?, 16).ok()? } else { b });
    }
    String::from_utf8(path).ok()
}

/// An .app folder's bundle identifier, where its Info.plist gives one.
fn app_bundle(folder: &str) -> Option<String> {
    let info = plist::Value::from_file(std::path::Path::new(folder).join("Info.plist")).ok()?;
    info.as_dictionary()?.get("CFBundleIdentifier")?.as_string().map(str::to_string)
}

/// Installs the app at `path`, an .ipa or an .app folder on this machine, signed for the device already. An .ipa
/// that `ipa_checked` refuses is refused before anything is sent ("invalid").
/// # Safety
/// `device` came from rr_device_open and wasn't closed; `path` is null or a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn rr_device_install(device: *mut RRDevice, path: *const c_char) -> *mut c_char {
    let path = (!path.is_null()).then(|| unsafe { CStr::from_ptr(path) }.to_str().ok()).flatten();
    match (unsafe { device.as_ref() }, path) {
        (Some(device), Some(path)) => c_string(match with_room(|| if std::path::Path::new(path).is_dir() { Ok(app_bundle(path)) } else { ipa_checked(path).map(Some) }) {
            Ok(bundle) => app(device, App::Install(path, bundle)),
            Err(why) => format!("{{\"ok\":false,\"invalid\":true,\"error\":{}}}", quoted(&why)),
        }),
        _ => c_string(failure("bad arguments")),
    }
}

/// Launches the app with that bundle identifier: JSON {"ok":true,"pid":…}.
/// # Safety
/// `device` came from rr_device_open and wasn't closed; `bundle` is null or a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn rr_device_launch(device: *mut RRDevice, bundle: *const c_char) -> *mut c_char {
    let bundle = (!bundle.is_null()).then(|| unsafe { CStr::from_ptr(bundle) }.to_str().ok()).flatten();
    match (unsafe { device.as_ref() }, bundle) {
        (Some(device), Some(bundle)) => c_string(app(device, App::Launch(bundle))),
        _ => c_string(failure("bad arguments")),
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
        if link.stop.raised() { return Err(STOPPED.into()); }
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
        t.chars().enumerate().map(|(i, c)| key(c).ok_or(format!("can't type character {} of the text: only what a US keyboard has (paste takes anything)", i + 1))).collect::<Result<Vec<_>, _>>()
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
        if link.stop.raised() { return Err(STOPPED.into()); }
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
        if link.stop.raised() { return Err(STOPPED.into()); }   // a walk moves the focus, and can scroll
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

/// What a failed verification is said as. The caller knows three of them by how they begin (the
/// header has the words): a refusal only when the device proved itself and said no, not when the
/// exchange broke off; and never by anything the other side wrote — its text isn't passed on.
fn verify_words(e: &idevice::IdeviceError, ip: &str, port: u16) -> String {
    use idevice::remote_pairing::errors::RemotePairingError as E;
    match e {
        idevice::IdeviceError::RemotePairing(E::PairVerifyFailed) => "the device doesn't accept this pairing: it proved itself and refused it".into(),
        idevice::IdeviceError::RemotePairing(E::PeerNotVerified(what)) =>
            format!("not the device this pairing was made with: what answers at {ip}:{port} didn't prove itself ({what}); it was told nothing of this Mac's and sent no input"),
        idevice::IdeviceError::RemotePairing(E::PairingRejected(_)) => "the pairing couldn't be verified: rejected by what answered".into(),
        _ => format!("the pairing couldn't be verified: {e}"),
    }
}

/// The words the header gives for a pairing without the device's key: only pairing again helps.
const UNCHECKED: &str = "this pairing doesn't hold the device's key (it was made before RoamRun checked who answers): pair again";

/// Signs what pair-verify signs, where the private key is kept elsewhere.
type Signer = idevice::remote_pairing::PairVerifySigner;

async fn connect(ip: &str, port: u16, file: &[u8], signer: Option<Signer>) -> Result<Link, String> {
    let started = Instant::now();
    // Unreadable is for good, like one without the device's key: said in the same words.
    let mut pairing = RpPairingFile::from_bytes(file).map_err(|e| format!("this pairing doesn't hold the device's key in a form RoamRun reads ({e:?}): pair again"))?;
    pairing.signer = signer;
    // The device proves itself at every connection, by the key it gave when the pairing was
    // made: a pairing without that key would take whatever answers for the device.
    if pairing.peer_public_key.is_none() { return Err(UNCHECKED.into()); }
    let control = proxy::dial(ip, port).await.map_err(|e| format!("RemotePairing port: {e}"))?;
    let mut client = RemotePairingClient::new(RpPairingSocket::new(control), LABEL);
    // Verify only: a pairing the device doesn't know must fail here, not start a new one.
    client.attempt_pair_verify().await.map_err(|e| format!("handshake: {e:?}"))?;
    client.validate_pairing(&mut pairing).await.map_err(|e| verify_words(&e, ip, port))?;
    let verified_ms = started.elapsed().as_millis();

    let tunnel_port = client.create_tcp_listener().await.map_err(|e| format!("tunnel listener: {e:?}"))?;
    let stream = proxy::dial(ip, tunnel_port).await.map_err(|e| format!("tunnel port {tunnel_port}: {e}"))?;
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
    Ok(Link { handle, handshake, hid: None, keys: None, stream: None, stream_used: Instant::now(), stream_stopped: None, stream_starts: 0, keyframes_asked: 0, keyframes_answered: 0, resent: 0, bare_inputs: false, stop: Stop(std::ptr::null()), held: None, finger: None, shown: None, shown_id: None, touchscreen: None, verified_ms, tunnel_ms, rsd_ms: started.elapsed().as_millis() })
}

/// The most that is typed in one call: beyond it, a slip in the middle is too costly, and paste does it in one.
const LONGEST_TYPED: usize = 2000;

/// Between two strokes of a text. The device takes keys at its own pace — about 45 ms a
/// character was seen (iOS 27, a note) — and keeps what comes faster for later: sent at 15 ms
/// a character, a long text was still being typed a minute after this had returned, where
/// nothing here could stop it and the next look showed half of it. Slower than the device.
const STROKE_PAUSE: u64 = 60;

/// A text as the keys it is typed with: each stroke whole, and the device's time after it.
fn type_steps(strokes: &[(u64, bool)]) -> Vec<Step> {
    let mut steps = Vec::with_capacity(strokes.len() * 5);
    for &(usage, shift) in strokes {
        if shift { steps.push(Step::Key(LEFT_SHIFT, ButtonState::Down)); }
        steps.push(Step::Key(usage, ButtonState::Down));
        steps.push(Step::Key(usage, ButtonState::Up));
        if shift { steps.push(Step::Key(LEFT_SHIFT, ButtonState::Up)); }
        steps.push(Step::Wait(if shift { STROKE_PAUSE * 3 / 2 } else { STROKE_PAUSE }));
    }
    steps
}

/// How long an input may take to send, once everything is ready for it: its own length, and
/// room for a slow link.
fn input_time(input: &Input) -> Duration {
    let own = match input {
        Input::Tap(..) => 100,
        Input::Swipe { ms, .. } => *ms as u64,
        Input::Type(strokes) => strokes.len() as u64 * 200,
        // Sent once for each kind of text it is put in as (three), at 50 KB/s at least.
        Input::Paste(text) => 5_000 + text.len() as u64 * 3 / 50,
        Input::Button(_, _, hold) => *hold,
    };
    // A touch may first find its surface on a new connection.
    let finding = if matches!(input, Input::Tap(..) | Input::Swipe { .. }) { DISPLAY_WAIT * 2 } else { Duration::ZERO };
    Duration::from_millis(own) + Duration::from_secs(10) + finding
}

/// The device drops input that isn't accompanied by a screen stream, so one runs with it: the
/// one kept from before if frames still come on it, a new one otherwise. Getting that far has
/// a stream's deadline; the input then gets the time its own length needs, so that the
/// deadline doesn't fall in the middle of it.
async fn perform(link: &mut Link, input: Input) -> Result<(), String> {
    // Without one where the caller said so (rr_device_bare_inputs): taps, keys and buttons were taken that way
    // on iOS 27.0, and no screen-sharing session then shows on the device or takes its sound.
    if !link.bare_inputs {
        tokio::time::timeout(STREAM_DEADLINE, stream_for_input(link)).await.unwrap_or_else(|_| Err("timed out".into()))?;
    }
    // Told to stop while the stream was got ready (that can take seconds): nothing is sent.
    if link.stop.raised() { return Err(STOPPED.into()); }
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

/// After an input cut short: the keys and a finger left down are let go as far as that can still
/// be said, and the connections it used aren't kept.
async fn let_go(link: &mut Link) {
    if let (Some(hid), Some((x, y))) = (link.hid.as_mut(), link.finger.take()) {
        let surface = link.touchscreen.unwrap_or(DIGITIZER_SURFACE_MAIN_TOUCHSCREEN);
        let _ = tokio::time::timeout(Duration::from_secs(1), hid.send_report(surface, build_touchscreen_report(TOUCHSCREEN_STATE_RELEASE, x, y, None))).await;
    }
    if let Some(keys) = link.keys.as_mut() {
        let held = link.held.take();
        let _ = tokio::time::timeout(Duration::from_secs(1), async {
            match held {
                Some((true, page, code)) => { let _ = keys.send_button(page, code, ButtonState::Up).await; }
                Some((false, _, usage)) => { let _ = keys.send_keyboard(usage, ButtonState::Up).await; }
                None => {}
            }
            let _ = keys.send_keyboard(LEFT_SHIFT, ButtonState::Up).await;
            let _ = keys.send_keyboard(LEFT_COMMAND, ButtonState::Up).await;
        }).await;
    }
    link.held = None;
    link.finger = None;
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

/// The touch surface of the shown display (the stream's, else asked): a device with two screens
/// has one for each, named after the display's uniqueId. None when the device didn't answer, to
/// be asked again.
async fn find_touchscreen(link: &mut Link) -> Option<u64> {
    let unique = match link.shown.clone() {
        Some(unique) => unique,
        None => {
            let displays = tokio::time::timeout(DISPLAY_WAIT, display_info(link)).await.ok()?.ok()?;
            let Some(unique) = unique_id(&displays) else { return Some(DIGITIZER_SURFACE_MAIN_TOUCHSCREEN) };
            unique
        }
    };
    let surfaces = tokio::time::timeout(DISPLAY_WAIT, link.hid.as_mut()?.list_connected_services()).await.ok()?.ok()?;
    Some(touchscreen_of(&surfaces, &unique))
}

/// The main touchscreen when none is named after the display.
fn touchscreen_of(surfaces: &[HidSurface], unique: &str) -> u64 {
    let named = format!("touchscreen({unique})");
    surfaces.iter()
        .find(|s| (s.primary_usage_page, s.primary_usage) == (Some(13), Some(4)) && s.product.as_deref().is_some_and(|p| p.ends_with(&named)))
        .map_or(DIGITIZER_SURFACE_MAIN_TOUCHSCREEN, |s| s.service_id)
}

/// The steps, on the touch connection: the one kept, or a new one. As `press` does with keys.
async fn touch(link: &mut Link, steps: &[Touch]) -> Result<(), String> {
    for attempt in 0..2 {
        let kept = link.hid.is_some();
        if !kept {
            link.hid = Some(UniversalHidServiceClient::connect_rsd(&mut link.handle, &mut link.handshake)
                .await.map_err(|e| format!("HID service: {e:?}"))?);
        }
        if !kept || link.touchscreen.is_none() {
            link.touchscreen = find_touchscreen(link).await;
        }
        let surface = link.touchscreen.unwrap_or(DIGITIZER_SURFACE_MAIN_TOUCHSCREEN);
        let hid = link.hid.as_mut().expect("just set");
        let mut sent_any = false;
        let mut failed = None;
        for step in steps {
            match *step {
                Touch::Wait(ms) => tokio::time::sleep(Duration::from_millis(ms)).await,
                Touch::At(state, x, y) => {
                    // Noted before it is sent, as a key is: cut off on its way, it may be down.
                    if state == TOUCHSCREEN_STATE_CONTACT { link.finger = Some((x, y)); }
                    match hid.send_report(surface, build_touchscreen_report(state, x, y, None)).await {
                        Ok(()) => {
                            sent_any = true;
                            if state == TOUCHSCREEN_STATE_RELEASE { link.finger = None; }
                        }
                        Err(e) => { failed = Some(e); break }
                    }
                }
            }
        }
        let Some(e) = failed else { return Ok(()) };
        link.hid = None;   // a dead connection isn't kept for the next call
        link.finger = None;
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

/// What a call told to stop says (the flag is looked at where a call begins too: none begins on
/// a device being let go of).
const STOPPED: &str = "stopped: told to stop where it was (the device was switched off or let go of, or whoever asked left)";

/// How many keys are held once `step` is sent.
fn down_after(down: i32, step: &Step) -> i32 {
    match step {
        Step::Key(_, ButtonState::Down) | Step::Button(_, _, ButtonState::Down) => down + 1,
        Step::Key(_, ButtonState::Up) | Step::Button(_, _, ButtonState::Up) => down - 1,
        Step::Wait(_) => down,
    }
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
        let mut down = 0;
        for (i, step) in steps.iter().enumerate() {
            // Between two keys, none held: what is left isn't sent to a device being let go of
            // (with only waiting left, all of it was sent: that isn't said to have been stopped).
            if down == 0 && link.stop.raised() && steps[i..].iter().any(|s| !matches!(s, Step::Wait(_))) { return Err(STOPPED.into()); }
            down = down_after(down, step);
            // Before it is sent: cut off while it is on its way, it may be down on the device.
            match *step {
                Step::Key(usage, ButtonState::Down) if usage != LEFT_SHIFT && usage != LEFT_COMMAND => link.held = Some((false, 0, usage)),
                Step::Button(page, code, ButtonState::Down) => link.held = Some((true, page, code)),
                _ => {}
            }
            let sent = match *step {
                Step::Key(usage, state) => keys.send_keyboard(usage, state).await,
                Step::Button(page, code, state) => keys.send_button(page, code, state).await,
                Step::Wait(ms) => { tokio::time::sleep(Duration::from_millis(ms)).await; continue }
            };
            match sent {
                Ok(()) => sent_any = true,
                Err(e) => { failed = Some(e); break }
            }
            // Once its up is sent it is no longer what `let_go` has to let go of.
            match *step {
                Step::Key(usage, ButtonState::Up) if link.held == Some((false, 0, usage)) => link.held = None,
                Step::Button(page, code, ButtonState::Up) if link.held == Some((true, page, code)) => link.held = None,
                _ => {}
            }
        }
        let Some(e) = failed else { return Ok(()) };
        link.held = None;   // the connection it was down on is gone
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
        Input::Type(strokes) => press(link, &type_steps(strokes)).await,
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
    // Display 1 when the device has never said.
    ask_shown(link).await;
    let shown = link.shown_id.unwrap_or(1);
    link.touchscreen = None;   // the screen may have changed: the touch surface is found again
    let mut display = tokio::time::timeout(STREAM_START, DisplayServiceClient::connect_rsd(&mut link.handle, &mut link.handshake)).await
        .map_err(|_| "display service: no answer".to_string())?
        .map_err(|e| format!("display service: {e:?}"))?;
    let audio = link.handle.bind_udp(0).await.map_err(|e| format!("udp: {e:?}"))?;
    let video = link.handle.bind_udp(0).await.map_err(|e| format!("udp: {e:?}"))?;
    let (ours, theirs) = (link.handle.host_ip().to_string(), link.handle.peer_ip().to_string());
    link.stream_starts += 1;
    let session = uuid::Uuid::new_v4();
    let call = || uuid::Uuid::new_v4().to_string().to_uppercase();
    // Audio first: it is what establishes the session the video then joins.
    let offer = build_screen_audio_offer(&call(), &call_info()).map_err(|e| format!("audio offer: {e:?}"))?;
    // Each start has its own limit, well inside a call's: one that stalls (they have) ends here,
    // where the half that did start is stopped, and not at the call's deadline, where it isn't.
    let audio_started = match tokio::time::timeout(STREAM_START, display.start_media_stream(build_start_audio_parameters(&ours, audio.local_port(), &theirs, 50000, offer, SUPPORTED_FEATURES, session))).await {
        Ok(started) => started.map_err(|e| format!("audio start: {e:?}")),
        Err(_) => Err("audio start: no answer".to_string()),
    };
    let ssrc = uuid::Uuid::new_v4().as_u128() as u32;
    let video_started = match audio_started.and_then(|_| build_screen_video_offer(&call(), &call_info(), ssrc).map_err(|e| format!("video offer: {e:?}"))) {
        Ok(offer) => match tokio::time::timeout(STREAM_START, display.start_media_stream(build_start_video_parameters(&ours, video.local_port(), &theirs, VIDEO_SENDER_PORT, offer, SUPPORTED_FEATURES, shown, session))).await {
            Ok(started) => started.map_err(|e| format!("video start: {e:?}")),
            Err(_) => Err("video start: no answer".into()),
        },
        Err(why) => Err(why),
    };
    let mut stream = Stream { display, video, audio, ssrc, media: None, feedback_port: None, requests: 0, keyframe_at: Instant::now() };
    if let Err(why) = video_started {
        // The sound's half did start, or may have (no answer isn't no): it is ended, not left running on the device.
        stream.stop().await;
        link.stream_stopped = Some(Instant::now());
        return Err(why);
    }
    Ok(stream)
}

/// How long the device gets to say which display is on, and which touch surface is its.
const DISPLAY_WAIT: Duration = Duration::from_secs(2);

/// How long one half of a stream gets to start (they answer within a second when they do), and
/// the display service's connection.
const STREAM_START: Duration = Duration::from_secs(5);

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
    /// The one address connections are taken from; any, when none is given.
    only: Option<std::net::IpAddr>,
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
    unsafe { rr_pairing_listen_on(name, model, host, -1, std::ptr::null(), advert, error) }
}

/// # Safety
/// As rr_pairing_listen. `socket` is -1, or a listening TCP socket that becomes this
/// function's whatever it returns; `only` is null or a NUL-terminated address.
#[no_mangle]
pub unsafe extern "C" fn rr_pairing_listen_on(name: *const c_char, model: *const c_char, host: *const c_char, socket: std::ffi::c_int, only: *const c_char, advert: *mut *mut c_char, error: *mut *mut c_char) -> *mut RRPairing {
    let arg = |p: *const c_char| (!p.is_null()).then(|| unsafe { CStr::from_ptr(p) }.to_str().ok()).flatten();
    // Taken first: every way out from here closes it.
    #[cfg(unix)]
    let given = (socket >= 0).then(|| unsafe { <std::net::TcpListener as std::os::fd::FromRawFd>::from_raw_fd(socket) });
    // A socket isn't an int there: one of the caller's making comes by `safe::Pairing::listen_on`.
    #[cfg(not(unix))]
    let given: Option<std::net::TcpListener> = { let _ = socket; None };
    let only = match arg(only).map(|a| a.parse::<std::net::IpAddr>()) {
        None if only.is_null() => None,
        Some(Ok(address)) => Some(address),
        _ => {
            unsafe { set_error(error, "the address to take connections from isn't one".into()) };
            return std::ptr::null_mut();
        }
    };
    let listening = match (arg(name), arg(model), arg(host)) {
        (Some(name), Some(model), Some(host)) => listening(name, model, host, given, only),
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

/// A pairing that listens — on `given`, or on a port of its own — and what to announce for it.
pub(crate) fn listening(name: &str, model: &str, host: &str, given: Option<std::net::TcpListener>, only: Option<std::net::IpAddr>) -> Result<(RRPairing, String), String> {
    let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(1).thread_stack_size(STACK).enable_all().build().map_err(|e| format!("no runtime: {e}"))?;
    let listener = match given {
        Some(given) => {
            given.set_nonblocking(true).map_err(|e| format!("can't listen: {e}"))?;
            let _in = runtime.enter();
            TcpListener::from_std(given).map_err(|e| format!("can't listen: {e}"))?
        }
        // Both families: the device reaches this Mac by whichever address its name resolves to.
        None => runtime.block_on(TcpListener::bind("[::]:0")).map_err(|e| format!("can't listen: {e}"))?,
    };
    let port = listener.local_addr().map_err(|e| format!("no port: {e}"))?.port();
    // One identity per `host`, whatever it is named: pairing again replaces the
    // device's record of it, and another Mac of the same name doesn't.
    let file = RpPairingFile::generate(&format!("{LABEL} {host}"));
    let mut info = PairableHostInfo::generate(name, model);
    (info.serial_number, info.mac) = own_hardware(file.identifier());
    let txt = info.mdns_txt_records(file.identifier()).iter()
        .map(|(k, v)| format!("{}:{}", quoted(k), quoted(v))).collect::<Vec<_>>().join(",");
    let said = format!("{{\"port\":{port},\"identifier\":{},\"txt\":{{{txt}}}}}", quoted(file.identifier()));
    Ok((RRPairing { runtime, listener, info, file: Mutex::new(file), cancelled: AtomicBool::new(false), only }, said))
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
    let result = with_room(|| Ok(pairing.runtime.block_on(accept_pairing(pairing, &show)))).unwrap_or_else(|why| Err(why.into()));
    c_string(match result {
        Ok((peer, file)) => format!("{{\"ok\":true,\"udid\":{},\"name\":{},\"model\":{},\"pairing\":{}}}",
                            quoted(&peer.remotepairing_udid), quoted(&peer.name), quoted(&peer.model), quoted(&file)),
        // `incomplete`: the device's own doing, after which it can simply be tried again.
        Err(not) if not.incomplete => format!("{{\"ok\":false,\"incomplete\":true,\"error\":{}}}", quoted(&not.why)),
        Err(not) => failure(&not.why),
    })
}

/// Why no pairing came of it. `incomplete`: the device came, a code was shown, and the device
/// didn't take it (a wrong code, a refusal, none entered in time) — nothing is in doubt, and it
/// can be tried again. Anything else (a connection that broke, a pairing that can't be used)
/// isn't known to be that.
struct NotPaired {
    incomplete: bool,
    why: String,
}

impl From<String> for NotPaired {
    fn from(why: String) -> Self { NotPaired { incomplete: false, why } }
}

impl From<&str> for NotPaired {
    fn from(why: &str) -> Self { NotPaired { incomplete: false, why: why.into() } }
}

/// What a failure after the code was shown is: the device's answer to the code, or not.
fn after_code(e: &idevice::IdeviceError) -> NotPaired {
    use idevice::remote_pairing::errors::RemotePairingError as E;
    match e {
        idevice::IdeviceError::RemotePairing(E::SrpAuthFailed) =>
            NotPaired { incomplete: true, why: "the code entered on the device wasn't the one shown".into() },
        idevice::IdeviceError::RemotePairing(E::PairingRejected(_)) =>
            NotPaired { incomplete: true, why: "the pairing was refused on the device".into() },
        // As the responder, idevice reports the device's error answer this way (pinned in Cargo.toml).
        idevice::IdeviceError::UnexpectedResponse(m) if m.starts_with("device returned pairing error") =>
            NotPaired { incomplete: true, why: "the pairing was refused on the device".into() },
        other => NotPaired {
            incomplete: false,
            why: format!("the pairing didn't complete: the connection ended after the code was shown — its screen closed on the device, or the network dropped ({other:?})"),
        },
    }
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

/// Accepts failing since one last succeeded that end a wait: they are the listener's then, not a connection's.
const ACCEPT_TRIES: u32 = 20;

/// What an accept gave: a connection, or none for now. One that failed alone was a connection
/// lost as it was taken, or no room for it just then, and the wait goes on (roamrunctl's too).
pub fn taken_one<T>(accepted: std::io::Result<T>, failed: &mut u32) -> std::io::Result<Option<T>> {
    match accepted {
        Ok(came) => { *failed = 0; Ok(Some(came)) }
        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => Ok(None),
        Err(e) => {
            *failed += 1;
            if *failed < ACCEPT_TRIES { Ok(None) } else { Err(e) }
        }
    }
}

/// Whether a connection from `from` is one to answer. Written as IPv4 or as IPv4 in IPv6's
/// form, an address is one address.
fn taken(from: std::net::IpAddr, only: Option<std::net::IpAddr>) -> bool {
    only.is_none_or(|only| from.to_canonical() == only.to_canonical())
}

async fn accept_pairing(pairing: &RRPairing, show: &(impl Fn(&str) + Sync)) -> Result<(idevice::remote_pairing::PeerDevice, String), NotPaired> {
    let cancelled = || pairing.cancelled.load(Ordering::Relaxed);
    let mut failed = 0;
    loop {
        let stream = loop {
            if cancelled() { return Err("cancelled".into()); }
            if let Ok(accepted) = tokio::time::timeout(TICK, pairing.listener.accept()).await {
                let Some((stream, from)) = taken_one(accepted, &mut failed).map_err(|e| format!("can't accept: {e}"))? else {
                    tokio::time::sleep(TICK).await;
                    continue;
                };
                if !taken(from.ip(), pairing.only) { continue; }
                break stream;
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
                            Some(at) if at.elapsed() >= ENTER_CODE => return Err(NotPaired { incomplete: true, why: "the code wasn't entered in time".into() }),
                            _ => {}
                        }
                    }
                }
            }
        };
        match outcome {
            Some(Ok(peer)) => {
                // Without the device's key the pairing couldn't be used: connections check it.
                if file.peer_public_key.is_none() { return Err("the device paired without giving a key to know it by: nothing was kept".into()); }
                let file = String::from_utf8(file.to_bytes()).map_err(|_| "the pairing isn't text".to_string())?;
                return Ok((peer, file));
            }
            // After the code was shown, a failure is the pairing's (a wrong code, a change of mind).
            Some(Err(e)) if when_shown().is_some() => return Err(after_code(&e)),
            // Before it, it was no device that wanted to pair: the next one is waited for.
            _ => continue,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_processes_of_the_app_replaced_are_ended() {
        let app = "/private/var/containers/Bundle/Application/DF24/RoamRunIntroducer.app";
        let processes: [(u32, Option<&str>); 5] = [
            (10, Some("file:///private/var/containers/Bundle/Application/DF24/RoamRunIntroducer.app/RoamRunIntroducer")),
            (11, Some("file:///private/var/containers/Bundle/Application/DF24/RoamRunIntroducer.app/PlugIns/W.appex/W")),
            // Another app whose name begins the same, another install of the name, and one without a URL.
            (12, Some("file:///private/var/containers/Bundle/Application/DF24/RoamRunIntroducer.app2/X")),
            (13, Some("file:///private/var/containers/Bundle/Application/5806/RoamRunIntroducer.app/RoamRunIntroducer")),
            (14, None),
        ];
        assert_eq!(inside(app, processes.into_iter()), vec![10, 11]);
        assert_eq!(inside(&format!("{app}/"), processes.into_iter()), vec![10, 11]);
        // No path, or the root: nothing is taken for inside it.
        assert!(inside("", processes.into_iter()).is_empty() && inside("/", processes.into_iter()).is_empty());
    }

    #[test]
    fn a_name_with_spaces_or_other_letters_is_matched_as_the_url_encodes_it() {
        let processes: [(u32, Option<&str>); 4] = [
            (20, Some("file:///private/var/containers/Bundle/Application/AB/My%20App.app/My%20App")),
            (21, Some("file:///private/var/containers/Bundle/Application/CD/%E6%97%A5%E6%9C%AC%E8%AA%9E.app/X")),
            // A broken escape isn't guessed at.
            (22, Some("file:///private/var/containers/Bundle/Application/AB/My%2")),
            (23, Some("https://example.com/private/var/containers/Bundle/Application/AB/My%20App.app/My%20App")),
        ];
        assert_eq!(inside("/private/var/containers/Bundle/Application/AB/My App.app", processes.into_iter()), vec![20]);
        assert_eq!(inside("/private/var/containers/Bundle/Application/CD/日本語.app", processes.into_iter()), vec![21]);
        assert_eq!(file_path("file:///a/%41%2fb"), Some("/a/A/b".into()));
        assert_eq!(file_path("file:///a/%zz"), None);
    }

    #[test]
    fn an_app_folders_bundle_identifier_is_read_from_its_info_plist() {
        let folder = std::env::temp_dir().join(format!("rr-bundle-{}.app", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        assert_eq!(app_bundle(folder.to_str().unwrap()), None);
        plist::Value::Dictionary([("CFBundleIdentifier".to_string(), plist::Value::String("io.example.app".into()))].into_iter().collect()).to_file_xml(folder.join("Info.plist")).unwrap();
        assert_eq!(app_bundle(folder.to_str().unwrap()).as_deref(), Some("io.example.app"));
        std::fs::remove_dir_all(folder).unwrap();
    }

    #[test]
    fn an_install_is_given_longer_the_more_there_is_to_send() {
        let folder = std::env::temp_dir().join(format!("rr-install-given-{}.app", std::process::id()));
        std::fs::create_dir_all(folder.join("inside")).unwrap();
        std::fs::write(folder.join("inside/binary"), vec![0u8; 3 << 20]).unwrap();
        std::fs::write(folder.join("Info.plist"), b"<plist/>").unwrap();
        assert_eq!(install_given(folder.to_str().unwrap()), (3, Duration::from_secs(345)));
        assert_eq!(install_given(folder.join("inside/binary").to_str().unwrap()).0, 3);
        assert_eq!(install_given("/nowhere/at/all.ipa"), (0, Duration::from_secs(300)));
        std::fs::remove_dir_all(folder).unwrap();
    }

    /// An .ipa of these files, deflated, written to a file of its own; its path.
    fn ipa(name: &str, files: &[(&str, &[u8])]) -> String {
        use async_zip::{base::write::ZipFileWriter, Compression, ZipEntryBuilder};
        let bytes = futures_lite::future::block_on(async {
            let mut zip = ZipFileWriter::new(Vec::new());
            for (file, data) in files { zip.write_entry_whole(ZipEntryBuilder::new((*file).into(), Compression::Deflate), data).await.unwrap(); }
            zip.close().await.unwrap()
        });
        let path = std::env::temp_dir().join(format!("rr-ipa-{}-{name}.ipa", std::process::id()));
        std::fs::write(&path, bytes).unwrap();
        path.to_string_lossy().into_owned()
    }

    const INFO: &[u8] = b"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>io.example.app</string></dict></plist>";
    const OTHER: &[u8] = b"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>io.example.other</string></dict></plist>";
    const GOOGLE: &[u8] = b"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>BUNDLE_ID</key><string>io.example.app</string></dict></plist>";

    #[test]
    fn an_ipa_is_installed_only_as_one_app_with_its_info_plist_and_not_too_big() {
        let checked = |name: &str, files: &[(&str, &[u8])]| { let path = ipa(name, files); let said = ipa_within(&path, 1 << 20, 1024); std::fs::remove_file(path).unwrap(); said };
        let app = [("Payload/A.app/Info.plist", INFO), ("Payload/A.app/A", &b"binary"[..]), ("SwiftSupport/iphoneos/libswiftCore.dylib", &b"x"[..])];
        assert_eq!(checked("good", &app), Ok("io.example.app".into()));
        // Firebase's GoogleService-Info.plist beside the app's: idevice passes over a plist without an id.
        assert_eq!(checked("firebase-first", &[("Payload/A.app/GoogleService-Info.plist", GOOGLE), ("Payload/A.app/Info.plist", INFO)]), Ok("io.example.app".into()));
        assert_eq!(checked("firebase-after", &[("Payload/A.app/Info.plist", INFO), ("Payload/A.app/GoogleService-Info.plist", GOOGLE)]), Ok("io.example.app".into()));
        assert_eq!(checked("array-first", &[("Payload/A.app/List-Info.plist", b"<plist version=\"1.0\"><array/></plist>"), ("Payload/A.app/Info.plist", INFO)]), Ok("io.example.app".into()));
        let refused = |name: &str, files: &[(&str, &[u8])], why: &str| { let said = checked(name, files).unwrap_err(); assert!(said.contains(why), "{name}: {said}") };
        // A .bundle: idevice would install it as another kind of package.
        refused("bundle", &[("Payload/A.bundle/Info.plist", INFO)], "Payload/A.bundle");
        refused("two-apps", &[("Payload/A.app/Info.plist", INFO), ("Payload/B.app/Info.plist", INFO)], "Payload/B.app beside A.app");
        refused("stray", &[("Payload/A.app/Info.plist", INFO), ("Payload/readme.txt", b"x")], "Payload/readme.txt beside A.app");
        refused("stray-first", &[("Payload/readme.txt", b"x"), ("Payload/A.app/Info.plist", INFO)], "Payload/readme.txt: it holds");
        // A hidden file beside it is let be; one idevice could take for the app isn't.
        assert_eq!(checked("ds-store", &[("Payload/.DS_Store", b"x"), ("Payload/A.app/Info.plist", INFO)]), Ok("io.example.app".into()));
        refused("apple-double", &[("Payload/._A.app", b"x"), ("Payload/A.app/Info.plist", INFO)], "Payload/A.app beside ._A.app");
        refused("hidden-bundle", &[("Payload/A.app/Info.plist", INFO), ("Payload/.B.bundle/x", b"x")], "Payload/.B.bundle");
        // A name ending in .app is an app, hidden or not: alone, it is the one.
        assert_eq!(checked("hidden-app", &[("Payload/.A.app/Info.plist", INFO)]), Ok("io.example.app".into()));
        refused("no-app", &[("A.app/Info.plist", INFO)], "no Payload/<name>.app");
        refused("no-plist", &[("Payload/A.app/A", b"binary")], "no Info.plist where the app's is looked for says");
        // idevice takes the id of the first plist it meets that has one: before the app's, it isn't the app's.
        refused("other-plist", &[("Symbols/x/Info.plist", OTHER), ("Payload/A.app/Info.plist", INFO)], "Symbols/x/Info.plist is where");
        refused("look-alike", &[("Payload/A.app/FooInfo.plist", OTHER), ("Payload/A.app/Info.plist", INFO)], "Payload/A.app/FooInfo.plist is where");
        assert_eq!(checked("other-plist-after", &[("Payload/A.app/Info.plist", INFO), ("Symbols/x/Info.plist", OTHER)]), Ok("io.example.app".into()));
        assert_eq!(checked("look-alike-after", &[("Payload/A.app/Info.plist", INFO), ("Payload/A.app/FooInfo.plist", OTHER)]), Ok("io.example.app".into()));
        // One it reads before the app's that it can't parse fails the install; one it reads whole is bounded too.
        refused("unparsed-first", &[("Payload/A.app/GoogleService-Info.plist", b"not a plist"), ("Payload/A.app/Info.plist", INFO)], "Payload/A.app/GoogleService-Info.plist isn't a plist");
        refused("big-first", &[("Payload/A.app/GoogleService-Info.plist", &vec![b' '; 2048]), ("Payload/A.app/Info.plist", INFO)], "Payload/A.app/GoogleService-Info.plist is more than 1 KB");
        assert_eq!(checked("unparsed-after", &[("Payload/A.app/Info.plist", INFO), ("Payload/A.app/GoogleService-Info.plist", b"not a plist")]), Ok("io.example.app".into()));
        assert_eq!(checked("big-after", &[("Payload/A.app/Info.plist", INFO), ("Payload/A.app/GoogleService-Info.plist", &vec![b' '; 2048])]), Ok("io.example.app".into()));
        refused("elsewhere", &[("Payload/A.app/A", b"binary"), ("Symbols/x/Info.plist", INFO)], "Symbols/x/Info.plist is where");
        refused("deeper", &[("Payload/A.app/Inner/Info.plist", INFO), ("Payload/A.app/A", b"binary")], "no Info.plist where the app's is looked for says");
        refused("too-big", &[("Payload/A.app/Info.plist", INFO), ("Payload/A.app/A", &vec![0u8; 2 << 20])], "unpacks to 2 MB");
        refused("big-plist", &[("Payload/A.app/Info.plist", &vec![b' '; 2048])], "more than 1 KB");
        refused("no-id", &[("Payload/A.app/Info.plist", b"<plist version=\"1.0\"><dict/></plist>"), ("Payload/A.app/GoogleService-Info.plist", GOOGLE)], "no Info.plist where the app's is looked for says");
        assert!(ipa_within("/nowhere/at/all.ipa", 1 << 20, 1024).is_err());
        let not_zip = std::env::temp_dir().join(format!("rr-ipa-{}-text.ipa", std::process::id()));
        std::fs::write(&not_zip, b"not a zip").unwrap();
        assert!(ipa_within(not_zip.to_str().unwrap(), 1 << 20, 1024).unwrap_err().contains("isn't an app's .ipa"));
        std::fs::remove_file(not_zip).unwrap();
    }

    #[test]
    fn an_info_plist_is_read_no_further_than_its_bound_whatever_it_says() {
        // An Info.plist that inflates to more than its archive says: the bound holds by what comes out.
        let big = [INFO, &vec![b' '; 4096]].concat();
        let path = ipa("lying", &[("Payload/A.app/Info.plist", &big)]);
        let mut bytes = std::fs::read(&path).unwrap();
        let said = (big.len() as u32).to_le_bytes();
        // Its size, as the local header (at 22) and the central directory (at 24) say it, made 10.
        for (signature, at) in [([0x50, 0x4b, 0x03, 0x04], 22), ([0x50, 0x4b, 0x01, 0x02], 24)] {
            let start = bytes.windows(4).position(|w| w == signature).unwrap();
            assert_eq!(bytes[start + at..start + at + 4], said);
            bytes[start + at..start + at + 4].copy_from_slice(&10u32.to_le_bytes());
        }
        std::fs::write(&path, &bytes).unwrap();
        let said = ipa_within(&path, 1 << 20, 1024);
        std::fs::remove_file(path).unwrap();
        assert!(said.as_ref().unwrap_err().contains("more than 1 KB"), "{said:?}");
    }

    fn io(kind: std::io::ErrorKind) -> idevice::IdeviceError { idevice::IdeviceError::Socket(std::io::Error::from(kind)) }

    #[test]
    fn only_the_devices_answer_to_the_code_is_a_pairing_to_try_again() {
        use idevice::remote_pairing::errors::RemotePairingError as E;
        let wrong = after_code(&idevice::IdeviceError::RemotePairing(E::SrpAuthFailed));
        assert!(wrong.incomplete && !wrong.why.contains("Srp"));
        assert!(after_code(&idevice::IdeviceError::RemotePairing(E::PairingRejected("no".into()))).incomplete);
        assert!(after_code(&idevice::IdeviceError::UnexpectedResponse("device returned pairing error: [2]".into())).incomplete);
        assert!(!after_code(&idevice::IdeviceError::UnexpectedResponse("pair-setup M3 missing public key or proof".into())).incomplete);
        // A connection that broke after the code was shown: what the device made of it isn't known.
        let broke = after_code(&io(std::io::ErrorKind::ConnectionReset));
        assert!(!broke.incomplete && broke.why.starts_with("the pairing didn't complete"));
        assert!(!NotPaired::from("cancelled").incomplete && !NotPaired::from(String::from("can't accept")).incomplete);
    }

    #[test]
    fn a_pairing_for_one_peer_takes_that_address_however_it_is_written() {
        let ip = |text: &str| text.parse::<std::net::IpAddr>().unwrap();
        assert!(taken(ip("192.168.0.9"), None));
        assert!(taken(ip("100.64.0.1"), Some(ip("100.64.0.1"))));
        assert!(taken(ip("::ffff:100.64.0.1"), Some(ip("100.64.0.1"))));
        assert!(!taken(ip("100.64.0.2"), Some(ip("100.64.0.1"))));
        assert!(!taken(ip("192.168.0.9"), Some(ip("100.64.0.1"))));
        assert!(!taken(ip("::1"), Some(ip("100.64.0.1"))));
    }

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

    /// A text as its steps are laid out: places to stop only where no key is held (never with
    /// Shift down), and no faster than the device takes it — within the time its length is given.
    #[test]
    fn a_text_is_typed_stroke_by_stroke_at_the_devices_pace() {
        let steps = type_steps(&[(0x04, true), (0x05, false)]);   // "Ab"
        let mut down = 0;
        let free: Vec<bool> = steps.iter().map(|s| { let was = down == 0; down = down_after(down, s); was }).collect();
        assert_eq!(free, [true, false, false, false, true, true, false, true]);
        assert_eq!(down, 0);
        let waits: Vec<u64> = steps.iter().filter_map(|s| if let Step::Wait(ms) = s { Some(*ms) } else { None }).collect();
        assert_eq!(waits, [90, 60]);
        assert!(waits.iter().all(|&ms| ms > 45), "slower than the device was seen to take keys");
        let longest: u64 = type_steps(&vec![(0x04, true); LONGEST_TYPED]).iter().filter_map(|s| if let Step::Wait(ms) = s { Some(*ms) } else { None }).sum();
        assert!(Duration::from_millis(longest) < input_time(&Input::Type(vec![(0x04, true); LONGEST_TYPED])));
    }

    /// What the other side writes in a rejection can't make a failure read as one of the three
    /// the app knows by their first words.
    #[test]
    fn what_answers_cannot_word_its_own_refusal() {
        use idevice::remote_pairing::errors::RemotePairingError as E;
        let markers = ["the device doesn't accept this pairing", "this pairing doesn't hold the device's key", "not the device this pairing was made with", "stopped:"];
        for text in markers {
            let said = verify_words(&E::PairingRejected(text.into()).into(), "10.0.0.1", 1);
            assert!(!said.contains(text), "{said}");
        }
        assert!(verify_words(&E::PairVerifyFailed.into(), "10.0.0.1", 1).starts_with(markers[0]));
        assert!(verify_words(&E::PeerNotVerified("x").into(), "10.0.0.1", 1).starts_with(markers[2]));
        assert!(UNCHECKED.starts_with(markers[1]));
        assert!(STOPPED.starts_with(markers[3]));
    }

    /// An input's deadline grows with what it has to send: a long text isn't cut in the middle.
    #[test]
    fn an_input_gets_the_time_its_length_needs() {
        let ten = Duration::from_secs(10);
        // A touch has room to find its surface besides.
        assert_eq!(input_time(&Input::Tap(0.5, 0.5)), ten + DISPLAY_WAIT * 2 + Duration::from_millis(100));
        assert_eq!(input_time(&Input::Swipe { from: (0.0, 0.0), to: (1.0, 1.0), ms: 5000 }), ten + DISPLAY_WAIT * 2 + Duration::from_secs(5));
        let long = Input::Type(vec![(0x04, false); LONGEST_TYPED]);
        assert_eq!(input_time(&long), ten + Duration::from_secs(400));   // 2000 keys at 200 ms each
        assert!(input_time(&Input::Type(vec![(0x04, false); 5])) < DEADLINE);
        // A paste is sent three times over: 1 MiB is 3 MiB, at 50 KB/s.
        assert!(input_time(&Input::Paste("x".repeat(1 << 20))) > Duration::from_secs(60));
        assert!(input_time(&Input::Paste("a few words".into())) < Duration::from_secs(16));
    }

    /// A call that starts a stream ends by its steps' own limits, each of which stops what it
    /// started, before its deadline: cut in the middle, a stream started is dropped unstopped.
    #[test]
    fn a_stream_call_ends_by_its_own_limits_before_its_deadline() {
        let start = AFTER_STOP + DISPLAY_WAIT + STREAM_START * 3 + STOP_WAIT;   // the display, connecting, sound, video, and a half started stopped
        let asked = (REPORT_WAIT + KEYFRAME_APART + KEYFRAME_WAIT) * 2;   // more than it can be
        assert!(asked + STOP_WAIT + start + FIRST_KEYFRAME + STOP_WAIT < STREAM_DEADLINE, "keyframe");
        assert!(Duration::from_millis(300) + STOP_WAIT + start * 2 < STREAM_DEADLINE, "stream_for_input");
    }

    /// A look has room for the slowest one measured on the Mac's own Wi‑Fi, three times over.
    #[test]
    fn a_look_has_room_for_a_big_screen_on_a_slower_link() {
        assert!(SHOT_TIME >= Duration::from_secs(19) * 3);
    }

    /// A connection lost as it was taken doesn't end a wait for a pairing; a listener that
    /// fails every time does.
    #[test]
    fn a_connection_lost_as_it_is_taken_doesnt_end_the_wait() {
        let lost = || Err::<(), _>(std::io::Error::from(std::io::ErrorKind::ConnectionAborted));
        let mut failed = 0;
        assert!(matches!(taken_one(lost(), &mut failed), Ok(None)));
        assert!(matches!(taken_one(Ok(()), &mut failed), Ok(Some(()))) && failed == 0);
        assert!(matches!(taken_one(Err::<(), _>(std::io::ErrorKind::WouldBlock.into()), &mut failed), Ok(None)) && failed == 0);
        for _ in 1..ACCEPT_TRIES { assert!(matches!(taken_one(lost(), &mut failed), Ok(None))); }
        assert!(taken_one(lost(), &mut failed).is_err());
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

    #[test]
    fn the_screens_size_is_the_primary_displays() {
        let display = |primary: bool, w: f64, h: f64| {
            let mut d = plist::Dictionary::new();
            d.insert("primary".into(), primary.into());
            d.insert("nativeSize".into(), plist::Value::Array(vec![w.into(), h.into()]));
            plist::Value::Dictionary(d)
        };
        let said = |displays: Vec<plist::Value>| {
            let mut d = plist::Dictionary::new();
            d.insert("displays".into(), plist::Value::Array(displays));
            plist::Value::Dictionary(d)
        };
        assert_eq!(screen_size(&said(vec![display(false, 1920.0, 1080.0), display(true, 1179.0, 2556.0)])), Some((1179, 2556)));
        assert_eq!(screen_size(&said(vec![display(false, 1920.0, 1080.0)])), Some((1920, 1080)));   // none marked: the first
        assert_eq!(screen_size(&said(vec![display(true, 0.0, 2556.0)])), None);
        assert_eq!(screen_size(&said(vec![])), None);
        assert_eq!(screen_size(&plist::Value::String("no".into())), None);
    }

    #[test]
    fn with_no_answer_in_time_the_display_known_before_stays_the_shown_one() {
        let mut inner = plist::Dictionary::new();
        inner.insert("displayId".into(), 2.into());
        inner.insert("uniqueId".into(), "inner".into());
        inner.insert("active".into(), true.into());
        let mut said = plist::Dictionary::new();
        said.insert("displays".into(), plist::Value::Array(vec![plist::Value::Dictionary(inner)]));
        let said = plist::Value::Dictionary(said);
        let known = (Some("inner".to_string()), Some(2));
        // The device didn't answer: not the primary display (the one off, opened), but the one known.
        assert_eq!(kept_shown(known.clone(), None), known);
        // Nothing known yet: nothing to keep, the stream's display 1 and the screenshot's primary as before.
        assert_eq!(kept_shown((None, None), None), (None, None));
        // An answer is taken as it is.
        assert_eq!(kept_shown((Some("outer".into()), Some(1)), Some(&said)), known);
    }

    #[test]
    fn the_shown_display_is_the_active_one() {
        let display = |id: i64, primary: bool, active: bool, w: f64, h: f64| {
            let mut d = plist::Dictionary::new();
            d.insert("displayId".into(), id.into());
            d.insert("primary".into(), primary.into());
            d.insert("active".into(), active.into());
            d.insert("nativeSize".into(), plist::Value::Array(vec![w.into(), h.into()]));
            plist::Value::Dictionary(d)
        };
        let said = |displays: Vec<plist::Value>| {
            let mut d = plist::Dictionary::new();
            d.insert("displays".into(), plist::Value::Array(displays));
            plist::Value::Dictionary(d)
        };
        // Two screens, the primary one off.
        let two = said(vec![display(1, true, false, 1398.0, 2034.0), display(2, false, true, 1878.0, 2670.0), display(3, false, false, 1920.0, 1080.0)]);
        assert_eq!(display_id(&two), Some(2));
        assert_eq!(screen_size(&two), Some((1878, 2670)));
        // None active: the primary one.
        let off = said(vec![display(3, false, false, 1920.0, 1080.0), display(1, true, false, 1179.0, 2556.0)]);
        assert_eq!(display_id(&off), Some(1));
        assert_eq!(display_id(&said(vec![])), None);
        // None marked: the first of its own; an external one is never taken, active or not.
        assert_eq!(display_id(&said(vec![display(5, false, false, 1.0, 1.0), display(6, false, false, 1.0, 1.0)])), Some(5));
        let mut tv = plist::Dictionary::new();
        tv.insert("displayId".into(), 3i64.into());
        tv.insert("active".into(), true.into());
        tv.insert("external".into(), true.into());
        assert_eq!(display_id(&said(vec![plist::Value::Dictionary(tv.clone()), display(1, true, false, 1179.0, 2556.0)])), Some(1));
        assert_eq!(display_id(&said(vec![plist::Value::Dictionary(tv)])), None);
    }

    #[test]
    fn touches_go_to_the_shown_displays_surface() {
        let surface = |id: u64, product: &str, page: u64, usage: u64| HidSurface { service_id: id, product: Some(product.into()), primary_usage_page: Some(page), primary_usage: Some(usage) };
        // As an iPhone with two screens lists them: each touchscreen named after its display's uniqueId.
        let two = [surface(257, "CoreDevice touchscreen(987-654-321)", 13, 4), surface(258, "CoreDevice touchscreen(123-456-789)", 13, 4), surface(1281, "CoreDevice touchscreenGesture", 1, 2)];
        assert_eq!(touchscreen_of(&two, "123-456-789"), 258);
        assert_eq!(touchscreen_of(&two, "987-654-321"), 257);
        assert_eq!(touchscreen_of(&two, "unknown"), DIGITIZER_SURFACE_MAIN_TOUCHSCREEN);
        assert_eq!(touchscreen_of(&[], "123-456-789"), DIGITIZER_SURFACE_MAIN_TOUCHSCREEN);
        // Named so, but not a touchscreen by its usage: not taken.
        assert_eq!(touchscreen_of(&[surface(300, "CoreDevice touchscreen(123-456-789)", 1, 2)], "123-456-789"), DIGITIZER_SURFACE_MAIN_TOUCHSCREEN);
    }
}
