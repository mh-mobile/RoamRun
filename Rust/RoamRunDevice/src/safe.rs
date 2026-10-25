//! The same calls as the C ABI, for Rust that keeps `unsafe` out of itself (roamrunctl).
//! A wrapper over the C functions, not the other way round: the Mac's path stays as it is.
//! Turn it over (C over this) when a second caller needs more than these.

use std::ffi::{c_char, CStr, CString};

use crate::*;

/// A device that is open. Closed when dropped.
pub struct Device(*mut RRDevice);

// The C side's own rule: one call at a time, from any thread (a lock is held inside each).
unsafe impl Send for Device {}

fn take(said: *mut c_char) -> String {
    if said.is_null() { return "{\"ok\":false,\"error\":\"no answer\"}".into(); }
    let text = unsafe { CStr::from_ptr(said) }.to_string_lossy().into_owned();
    unsafe { rr_string_free(said) };
    text
}

fn c(text: &str) -> Result<CString, String> {
    CString::new(text).map_err(|_| "a NUL in the text".to_string())
}

impl Device {
    /// `pairing`: the pairing itself (a property list's bytes), not a path.
    pub fn open(ip: &str, port: u16, pairing: &[u8]) -> Result<Device, String> {
        let ip = c(ip)?;
        let mut error = std::ptr::null_mut();
        let device = unsafe { rr_device_open(ip.as_ptr(), port, pairing.as_ptr(), pairing.len(), &mut error) };
        if device.is_null() { return Err(take(error)); }
        // No screen stream for inputs: see rr_device_bare_inputs. The Mac's app keeps its stream.
        unsafe { rr_device_bare_inputs(device, true) };
        Ok(Device(device))
    }

    /// As `open`, for a pairing whose private key is kept elsewhere: `sign` is asked for the one signature a
    /// connection takes (None: it wasn't given), and `pairing` holds any key in the private key's place.
    pub fn open_signed(ip: &str, port: u16, pairing: &[u8], sign: impl Fn(&[u8]) -> Option<[u8; 64]> + Send + Sync) -> Result<Device, String> {
        unsafe extern "C" fn asked<F: Fn(&[u8]) -> Option<[u8; 64]>>(what: *const u8, length: usize, signature: *mut u8, context: *mut std::ffi::c_void) -> bool {
            let sign = unsafe { &*(context as *const F) };
            match sign(unsafe { std::slice::from_raw_parts(what, length) }) {
                Some(made) => { unsafe { std::ptr::copy_nonoverlapping(made.as_ptr(), signature, 64) }; true }
                None => false,
            }
        }
        fn with<F: Fn(&[u8]) -> Option<[u8; 64]>>(ip: &CString, port: u16, pairing: &[u8], sign: &F, error: &mut *mut c_char) -> *mut RRDevice {
            unsafe { rr_device_open_signed(ip.as_ptr(), port, pairing.as_ptr(), pairing.len(), Some(asked::<F>), sign as *const F as *mut std::ffi::c_void, error) }
        }
        let ip = c(ip)?;
        let mut error = std::ptr::null_mut();
        let device = with(&ip, port, pairing, &sign, &mut error);
        if device.is_null() { return Err(take(error)); }
        unsafe { rr_device_bare_inputs(device, true) };
        Ok(Device(device))
    }

    /// Each of these answers as the C function does: JSON with "ok", and "error" when it isn't.
    pub fn info(&self) -> String { take(unsafe { rr_device_info(self.0) }) }
    pub fn screen(&self) -> String { take(unsafe { rr_device_screen(self.0) }) }
    pub fn tap(&self, x: f64, y: f64) -> String { take(unsafe { rr_device_tap(self.0, x, y) }) }
    pub fn swipe(&self, from: (f64, f64), to: (f64, f64), ms: u32) -> String {
        take(unsafe { rr_device_swipe(self.0, from.0, from.1, to.0, to.1, ms) })
    }
    pub fn type_text(&self, text: &str) -> String { self.with(text, |d, t| unsafe { rr_device_type(d, t) }) }
    pub fn paste(&self, text: &str) -> String { self.with(text, |d, t| unsafe { rr_device_paste(d, t) }) }
    pub fn button(&self, name: &str) -> String { self.with(name, |d, t| unsafe { rr_device_button(d, t) }) }
    pub fn elements(&self, limit: u32) -> String { take(unsafe { rr_device_elements(self.0, limit) }) }
    pub fn install(&self, path: &str) -> String { self.with(path, |d, t| unsafe { rr_device_install(d, t) }) }
    /// Which way up the interface is: see rr_device_way.
    pub fn way(&self) -> u8 { unsafe { rr_device_way(self.0) } }
    pub fn launch(&self, bundle: &str) -> String { self.with(bundle, |d, t| unsafe { rr_device_launch(d, t) }) }

    /// The screen as the PNG the device makes: its own size, turned as its interface is.
    pub fn screenshot(&self) -> Result<Vec<u8>, String> {
        let (mut length, mut error) = (0usize, std::ptr::null_mut());
        let image = unsafe { rr_device_screenshot(self.0, &mut length, &mut error) };
        if image.is_null() { return Err(take(error)); }
        let bytes = unsafe { std::slice::from_raw_parts(image, length) }.to_vec();
        unsafe { rr_bytes_free(image, length) };
        Ok(bytes)
    }

    /// One key frame of the screen stream (HEVC, Annex B): the display's own size and way up. The stream is
    /// started if it isn't running, and kept a few seconds for the next.
    pub fn keyframe(&self) -> Result<Vec<u8>, String> {
        let (mut length, mut error) = (0usize, std::ptr::null_mut());
        let frame = unsafe { rr_device_keyframe(self.0, &mut length, &mut error) };
        if frame.is_null() { return Err(take(error)); }
        let bytes = unsafe { std::slice::from_raw_parts(frame, length) }.to_vec();
        unsafe { rr_bytes_free(frame, length) };
        Ok(bytes)
    }

    fn with(&self, text: &str, call: impl FnOnce(*mut RRDevice, *const c_char) -> *mut c_char) -> String {
        match c(text) {
            Ok(text) => take(call(self.0, text.as_ptr())),
            // Refused before anything went to the device, as the library's own refusals are.
            Err(why) => format!("{{\"ok\":false,\"invalid\":true,\"error\":\"{why}\"}}"),
        }
    }
}

impl Drop for Device {
    fn drop(&mut self) {
        unsafe { rr_device_close(self.0) };
    }
}

/// This process's effective user id, for roamrunctl, whose own code has no `unsafe`.
#[cfg(unix)]
pub fn effective_user() -> u32 {
    extern "C" { fn geteuid() -> u32; }
    unsafe { geteuid() }
}

/// What a device's refusal says, where the library gives it as the device sent it: an archived dictionary's
/// bytes (`Data([98, 112, …])`), or a dictionary with a description in it. Anything else comes back as it is.
pub fn readable(error: &str) -> String {
    // A description given in words already.
    for key in ["NSLocalizedDescription", "NSDebugDescription"] {
        if let Some(at) = error.find(&format!("\"{key}\": String(\"")) {
            let rest = &error[at + key.len() + 12..];
            if let Some(end) = rest.find("\")") { return with_what(error, &rest[..end].replace("\\\"", "\"")); }
        }
    }
    // An archive: its strings are in `$objects`; the sentence is the one that isn't a key or a class's name.
    let Some(start) = error.find("Data([") else { return error.to_string() };
    let Some(end) = error[start..].find("])") else { return error.to_string() };
    let bytes: Vec<u8> = error[start + 6..start + end].split(',').filter_map(|n| n.trim().parse().ok()).collect();
    let Ok(archive) = plist::Value::from_reader(std::io::Cursor::new(bytes)) else { return error.to_string() };
    let said = archive.as_dictionary().and_then(|d| d.get("$objects")).and_then(|o| o.as_array()).and_then(|objects| {
        objects.iter().filter_map(|o| o.as_string()).filter(|s| !s.starts_with("NS") && !s.starts_with('$') && s.contains(' ')).max_by_key(|s| s.len())
    });
    match said {
        Some(said) => with_what(error, said),
        None => error.to_string(),
    }
}

/// "launch: CoreDevice(…" keeps its "launch: ".
fn with_what(error: &str, said: &str) -> String {
    match error.split_once(": ") {
        Some((what, _)) if what.len() <= 24 && !what.contains('(') => format!("{what}: {said}"),
        _ => said.to_string(),
    }
}

/// A pairing a device comes to make: this side listens, shows a code, and keeps the key that comes of it.
pub struct Pairing(*mut RRPairing);

// As the C side has it: accept on one thread, cancel from any.
unsafe impl Send for Pairing {}
unsafe impl Sync for Pairing {}

impl Pairing {
    /// Listens on `listener` (this call's from here on) for connections from `only` alone.
    /// The second value is what to offer: JSON {"port":…,"identifier":…,"txt":{…}}.
    pub fn listen_on(name: &str, model: &str, host: &str, listener: std::net::TcpListener, only: &str) -> Result<(Pairing, String), String> {
        let only = only.parse::<std::net::IpAddr>().map_err(|_| "the address to take connections from isn't one".to_string())?;
        let (pairing, advert) = crate::listening(name, model, host, Some(listener), Some(only))?;
        Ok((Pairing(Box::into_raw(Box::new(pairing))), advert))
    }

    /// Waits for a device to pair; `code` is given the six digits to show. The answer is JSON: {"ok":true,"udid":…,
    /// "name":…,"model":…,"pairing":…} (the pairing holds this side's private key), or {"ok":false,"error":…}.
    pub fn accept(&self, mut code: impl FnMut(&str) + Send) -> String {
        unsafe extern "C" fn shown<F: FnMut(&str)>(digits: *const c_char, context: *mut std::ffi::c_void) {
            let show = unsafe { &mut *(context as *mut F) };
            show(&unsafe { CStr::from_ptr(digits) }.to_string_lossy());
        }
        fn with<F: FnMut(&str)>(pairing: *mut RRPairing, code: &mut F) -> *mut c_char {
            unsafe { rr_pairing_accept(pairing, Some(shown::<F>), code as *mut F as *mut std::ffi::c_void) }
        }
        take(with(self.0, &mut code))
    }

    /// Makes a running `accept` return. Any thread.
    pub fn cancel(&self) { unsafe { rr_pairing_cancel(self.0) } }
}

impl Drop for Pairing {
    fn drop(&mut self) {
        unsafe { rr_pairing_free(self.0) };
    }
}

#[cfg(test)]
mod tests {
    use super::{readable, Device};

    /// Text with a NUL in it is refused before anything is sent, and said so ("invalid"): roamrunctl's
    /// MCP keeps the device's connection for it (and, for type and paste, the look they spent).
    #[test]
    fn a_nul_is_refused_before_anything_is_sent() {
        let none = Device(std::ptr::null_mut());   // never reached: the text is refused first
        for said in [none.type_text("a\0b"), none.paste("a\0b"), none.button("home\0"), none.launch("a\0b")] {
            assert!(said.starts_with(r#"{"ok":false,"invalid":true,"#), "{said}");
        }
    }

    #[test]
    fn a_refusal_is_said_in_its_own_words() {
        // As the screenshot service refused a format.
        let dictionary = r#"screenshot: CoreDevice(DeviceError("Dictionary({\"code\": Integer(4864), \"userInfo\": Dictionary({\"NSDebugDescription\": String(\"Cannot initialize ScreenshotImageFormat from invalid String value jpeg\"), \"NSCodingPath\": String(\"x\")})})"))"#;
        assert_eq!(readable(&dictionary.replace("\\\"", "\"")), "screenshot: Cannot initialize ScreenshotImageFormat from invalid String value jpeg");
        // As the display service refused a stream during a call: an archive of a dictionary.
        let mut archive = plist::Dictionary::new();
        archive.insert("$objects".into(), plist::Value::Array(vec![
            "$null".into(), "NSLocalizedDescription".into(), "A phone or VoIP call is currently in progress on the device.".into(), "NSDictionary".into(), "NSObject".into(),
        ]));
        let mut bytes = Vec::new();
        plist::Value::Dictionary(archive).to_writer_binary(&mut bytes).unwrap();
        let numbers: Vec<String> = bytes.iter().map(u8::to_string).collect();
        let refused = format!("audio start: CoreDevice(DeviceError(\"Dictionary({{\\\"userInfoWithNSSecureCoding\\\": Data([{}])}})\"))", numbers.join(", "));
        assert_eq!(readable(&refused), "audio start: A phone or VoIP call is currently in progress on the device.");
        // What isn't either comes back as it is.
        assert_eq!(readable("timed out"), "timed out");
        assert_eq!(readable("x: Data([1, 2, 3])"), "x: Data([1, 2, 3])");
    }
}
