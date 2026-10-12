//! The same calls as the C ABI, for Rust that keeps `unsafe` out of itself (roamrunctl).
//! ponytail: a wrapper over the C functions, not the other way round: the Mac's path stays as it is.
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

    fn with(&self, text: &str, call: impl FnOnce(*mut RRDevice, *const c_char) -> *mut c_char) -> String {
        match c(text) {
            Ok(text) => take(call(self.0, text.as_ptr())),
            Err(why) => format!("{{\"ok\":false,\"error\":\"{why}\"}}"),
        }
    }
}

impl Drop for Device {
    fn drop(&mut self) {
        unsafe { rr_device_close(self.0) };
    }
}
