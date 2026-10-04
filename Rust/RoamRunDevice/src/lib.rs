//! RoamRun's C ABI over idevice. Experimental. rr_device_tap operates the device;
//! rr_device_elements can scroll it.

use std::ffi::{c_char, CStr, CString};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use idevice::core_device::hid::UniversalHidServiceClient;
use idevice::dvt::message::AuxValue;
use idevice::dvt::remote_server::RemoteServerClient;
use idevice::core_device::{
    build_screen_audio_offer, build_screen_video_offer, build_start_audio_parameters, build_start_video_parameters,
    is_rtcp, CallInfoBlob, DisplayServiceClient, HevcDepacketizer, RtpPacket,
};
use idevice::remote_pairing::{connect_tls_psk_tunnel_native, RemotePairingClient, RpPairingFile, RpPairingSocket};
use idevice::rsd::RsdHandshake;
use idevice::tcp::adapter::Adapter;
use idevice::tcp::handle::AdapterHandle;
use idevice::{ReadWrite, RsdService};
use tokio::net::TcpStream;

const VERSION: &CStr = c"0.2.0";
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
    verified_ms: u128,
    tunnel_ms: u128,
    rsd_ms: u128,
}

/// What the C side holds. The runtime has a thread of its own: the tunnel is served between calls.
pub struct RRDevice {
    runtime: tokio::runtime::Runtime,
    link: Mutex<Link>,
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
/// `ip` and `pairing_file` are null or NUL-terminated strings; `error` is null or writable.
#[no_mangle]
pub unsafe extern "C" fn rr_device_open(ip: *const c_char, port: u16, pairing_file: *const c_char, error: *mut *mut c_char) -> *mut RRDevice {
    let arg = |p: *const c_char| (!p.is_null()).then(|| unsafe { CStr::from_ptr(p) }.to_str().ok()).flatten();
    let opened = match (arg(ip), arg(pairing_file)) {
        (Some(ip), Some(file)) => tokio::runtime::Builder::new_multi_thread().worker_threads(1).enable_all().build()
            .map_err(|e| format!("no runtime: {e}"))
            .and_then(|runtime| {
                let link = runtime.block_on(async {
                    tokio::time::timeout(DEADLINE, connect(ip, port, file)).await.unwrap_or_else(|_| Err("timed out".into()))
                })?;
                Ok(RRDevice { runtime, link: Mutex::new(link) })
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
        drop(unsafe { Box::from_raw(device) });
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
        "{{\"ok\":true,\"verifiedMs\":{},\"tunnelMs\":{},\"rsdMs\":{},\"services\":{},\"has\":{{{}}}}}",
        link.verified_ms, link.tunnel_ms, link.rsd_ms, link.handshake.services.len(), has.join(",")
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
    let mut link = device.link.lock().unwrap_or_else(|e| e.into_inner());
    let result = device.runtime.block_on(async {
        tokio::time::timeout(DEADLINE, keyframe(&mut link)).await.unwrap_or_else(|_| Err("timed out".into()))
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

/// # Safety
/// `device` came from rr_device_open and wasn't closed.
#[no_mangle]
pub unsafe extern "C" fn rr_device_tap(device: *mut RRDevice, x: f64, y: f64) -> *mut c_char {
    let Some(device) = (unsafe { device.as_ref() }) else { return std::ptr::null_mut() };
    // Refused, not clamped: a point off the screen is a caller's mistake, and pressing the edge isn't what it meant.
    if !(0.0..=1.0).contains(&x) || !(0.0..=1.0).contains(&y) {
        return c_string(failure("x and y must be within 0...1"));
    }
    let mut link = device.link.lock().unwrap_or_else(|e| e.into_inner());
    let started = Instant::now();
    let result = device.runtime.block_on(async {
        tokio::time::timeout(DEADLINE, tap(&mut link, x, y)).await.unwrap_or_else(|_| Err("timed out".into()))
    });
    c_string(match result {
        Ok(()) => format!("{{\"ok\":true,\"ms\":{}}}", started.elapsed().as_millis()),
        Err(why) => failure(&why),
    })
}

/// # Safety
/// `device` came from rr_device_open and wasn't closed.
#[no_mangle]
pub unsafe extern "C" fn rr_device_elements(device: *mut RRDevice, limit: u32) -> *mut c_char {
    let Some(device) = (unsafe { device.as_ref() }) else { return std::ptr::null_mut() };
    let mut link = device.link.lock().unwrap_or_else(|e| e.into_inner());
    let started = Instant::now();
    // Its own deadline inside: a walk cut short still returns what it found.
    let result = device.runtime.block_on(elements(&mut link, limit.max(1) as usize, started + WALK));
    c_string(match result {
        Ok((captions, complete)) => format!(
            "{{\"ok\":true,\"elements\":[{}],\"complete\":{complete},\"ms\":{}}}",
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

/// Captions in the inspector's order, and whether the walk came round (true) or was cut short.
async fn elements(link: &mut Link, limit: usize, until: Instant) -> Result<(Vec<String>, bool), String> {
    let port = link.handshake.services.get(WANTED[3].1).ok_or("no accessibility service on this device")?.port;
    let stream = link.handle.connect(port).await.map_err(|e| format!("accessibility service: {e:?}"))?;
    // A lockdown service bridged onto RSD: it wants a check-in before its own protocol.
    let mut plain = idevice::Idevice::new(Box::new(stream), LABEL);
    plain.rsd_checkin().await.map_err(|e| format!("accessibility check-in: {e:?}"))?;
    let mut client = RemoteServerClient::new(plain.get_socket().ok_or("accessibility socket")?);
    let call = |name: &'static str, argument: plist::Value| (name, Some(vec![AuxValue::archived_value(argument)]));

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
        client.root_channel().call_method(Some(name), arguments, false).await.map_err(|e| format!("{name} {e:?}"))?;
    }

    let mut captions = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for step in 0..limit {
        if Instant::now() >= until { return Ok((captions, false)); }
        // From the first element each time a walk starts: the focus is wherever the last one left it.
        let options: plist::Dictionary = [
            ("allowNonAX".to_string(), wrapped(plist::Value::Boolean(false))),
            ("direction".to_string(), wrapped(plist::Value::Integer((if step == 0 { FIRST } else { NEXT }).into()))),
            ("includeContainers".to_string(), wrapped(plist::Value::Boolean(true))),
        ].into_iter().collect();
        let (name, arguments) = call("deviceInspectorMoveWithOptions:", wrapped(plist::Value::Dictionary(options)));
        client.root_channel().call_method(Some(name), arguments, false).await.map_err(|e| format!("{name} {e:?}"))?;

        // The element comes back as the device's own call to us, among others.
        let focus = loop {
            let Ok(message) = tokio::time::timeout(ELEMENT, client.read_message(0)).await else { break None };
            let message = message.map_err(|e| format!("accessibility: {e:?}"))?;
            let changed = message.data.as_ref().and_then(|d| d.as_string()).is_some_and(|s| s.contains("CurrentElementChanged"));
            if !changed { continue; }
            break message.aux.iter().flat_map(|a| a.values.iter()).find_map(|v| match v {
                AuxValue::Array(bytes) => ns_keyed_archive::decode::from_bytes(bytes).ok(),
                _ => None,
            });
        };
        // Nothing came: no element there (the home screen), or the end of what can be visited.
        let Some(focus) = focus else { return Ok((captions, step > 0)) };
        let inner = unwrapped(unwrapped(&focus)).as_dictionary();
        let field = |key: &str| inner.and_then(|d| d.get(key)).map(unwrapped);
        // The element's token says when the walk has come round to where it began.
        let token = field("ElementValue_v1").map(|e| format!("{:?}", unwrapped(e)));
        if let Some(token) = token {
            if !seen.insert(token) { return Ok((captions, true)); }
        }
        captions.push(field("CaptionTextValue_v1").and_then(|v| v.as_string()).unwrap_or("").to_string());
    }
    Ok((captions, false))
}

async fn connect(ip: &str, port: u16, file: &str) -> Result<Link, String> {
    let started = Instant::now();
    let mut pairing = RpPairingFile::read_from_file(file).await.map_err(|e| format!("pairing file: {e:?}"))?;
    let control = TcpStream::connect((ip, port)).await.map_err(|e| format!("RemotePairing port: {e}"))?;
    let mut client = RemotePairingClient::new(RpPairingSocket::new(control), LABEL);
    // Verify only: a pairing the device doesn't know must fail here, not start a new one.
    client.attempt_pair_verify().await.map_err(|e| format!("handshake: {e:?}"))?;
    client.validate_pairing(&mut pairing).await.map_err(|e| format!("the device doesn't accept this pairing: {e:?}"))?;
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
    Ok(Link { handle, handshake, hid: None, verified_ms, tunnel_ms, rsd_ms: started.elapsed().as_millis() })
}

async fn tap(link: &mut Link, x: f64, y: f64) -> Result<(), String> {
    if link.hid.is_none() {
        link.hid = Some(UniversalHidServiceClient::connect_rsd(&mut link.handle, &mut link.handshake)
            .await.map_err(|e| format!("HID service: {e:?}"))?);
    }
    // The touchscreen takes 0...65535 across each axis.
    let unit = |v: f64| (v * 65535.0).round() as u16;
    let sent = link.hid.as_mut().expect("just set").tap(unit(x), unit(y)).await;
    if sent.is_err() { link.hid = None; }   // a dead connection isn't kept for the next call
    sent.map_err(|e| format!("tap: {e:?}"))
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

// ponytail: the stream is started and stopped around each frame (~0.4 s), so a single key
// frame decodes on its own and nothing is received in between. Keeping it running and asking
// for a key frame over RTCP is the faster way, when frames are wanted many times a second.
async fn keyframe(link: &mut Link) -> Result<Vec<u8>, String> {
    let mut display = DisplayServiceClient::connect_rsd(&mut link.handle, &mut link.handshake)
        .await.map_err(|e| format!("display service: {e:?}"))?;
    let audio = link.handle.bind_udp(0).await.map_err(|e| format!("udp: {e:?}"))?;
    let video = link.handle.bind_udp(0).await.map_err(|e| format!("udp: {e:?}"))?;
    let (ours, theirs) = (link.handle.host_ip().to_string(), link.handle.peer_ip().to_string());
    let session = uuid::Uuid::new_v4();
    let call = || uuid::Uuid::new_v4().to_string().to_uppercase();
    // Audio first: it is what establishes the session the video then joins.
    let offer = build_screen_audio_offer(&call(), &call_info()).map_err(|e| format!("audio offer: {e:?}"))?;
    display.start_media_stream(build_start_audio_parameters(&ours, audio.local_port(), &theirs, 50000, offer, SUPPORTED_FEATURES, session))
        .await.map_err(|e| format!("audio start: {e:?}"))?;
    let ssrc = uuid::Uuid::new_v4().as_u128() as u32;
    let offer = build_screen_video_offer(&call(), &call_info(), ssrc).map_err(|e| format!("video offer: {e:?}"))?;
    display.start_media_stream(build_start_video_parameters(&ours, video.local_port(), &theirs, 50001, offer, SUPPORTED_FEATURES, 1, session))
        .await.map_err(|e| format!("video start: {e:?}"))?;

    // The stream opens with a key frame; its last packet carries the RTP marker.
    let mut frames = HevcDepacketizer::new();
    let (mut stream, mut key) = (None, false);
    let frame = loop {
        let datagram = match video.recv().await {
            Ok(d) => d,
            Err(e) => {
                let _ = display.stop_media_stream().await;
                return Err(format!("video: {e:?}"));
            }
        };
        if is_rtcp(&datagram.data) { continue; }
        let Some(packet) = RtpPacket::parse(&datagram.data) else { continue };
        if *stream.get_or_insert(packet.ssrc) != packet.ssrc { continue; }
        let p = packet.payload;
        // A fragmented unit (type 49) names its real type in its third byte; 16...23 are key frames.
        key |= if p.len() >= 3 && (p[0] >> 1) & 0x3f == 49 { (16..=23).contains(&(p[2] & 0x3f)) }
               else { p.len() >= 2 && (16..=23).contains(&((p[0] >> 1) & 0x3f)) };
        frames.push(packet.sequence_number, packet.timestamp, p);
        if packet.marker {
            let out = frames.take_output();
            if key && frames.has_parameter_sets() && !out.is_empty() { break out; }
            key = false;
        }
    };
    let _ = display.stop_media_stream().await;
    Ok(frame)
}
