//! The device's sound, as `roamrunctl view` gives it to a page: AAC-ELD access units (48 kHz, stereo, 480 samples each) decoded to 16-bit PCM,
//! interleaved, little-endian. By AudioToolbox on macOS; nowhere else yet (no browser decodes AAC-ELD).

/// Samples a second, and channels, of what the device sends and what is given.
pub const RATE: u32 = 48_000;
pub const CHANNELS: u32 = 2;

#[cfg(target_os = "macos")]
pub use mac::Decoder;

#[cfg(not(target_os = "macos"))]
pub struct Decoder;

#[cfg(not(target_os = "macos"))]
impl Decoder {
    pub fn new() -> Result<Decoder, String> { Err("the device's sound is decoded on macOS only".into()) }
    pub fn decode(&mut self, _: &[u8]) -> Option<Vec<u8>> { None }
}

#[cfg(target_os = "macos")]
mod mac {
    use std::ffi::c_void;

    #[repr(C)]
    struct Format { sample_rate: f64, id: u32, flags: u32, bytes_per_packet: u32, frames_per_packet: u32, bytes_per_frame: u32, channels: u32, bits: u32, reserved: u32 }
    #[repr(C)]
    struct PacketDescription { start: i64, frames: u32, size: u32 }
    #[repr(C)]
    struct Buffer { channels: u32, size: u32, data: *mut c_void }
    #[repr(C)]
    struct BufferList { count: u32, buffers: [Buffer; 1] }
    type Input = unsafe extern "C" fn(*mut c_void, *mut u32, *mut BufferList, *mut *mut PacketDescription, *mut c_void) -> i32;

    #[link(name = "AudioToolbox", kind = "framework")]
    extern "C" {
        fn AudioConverterNew(from: *const Format, to: *const Format, converter: *mut *mut c_void) -> i32;
        fn AudioConverterFillComplexBuffer(converter: *mut c_void, input: Input, user: *mut c_void, frames: *mut u32, out: *mut BufferList, descriptions: *mut PacketDescription) -> i32;
        fn AudioConverterDispose(converter: *mut c_void) -> i32;
    }

    const fn four(code: &[u8; 4]) -> u32 { u32::from_be_bytes(*code) }
    /// What the input callback says once its one packet is taken: no more for now (not an error).
    const NO_MORE: i32 = 1;

    /// One access unit, handed to the converter once.
    struct Unit<'a> { data: &'a [u8], description: PacketDescription, taken: bool }

    unsafe extern "C" fn give(_: *mut c_void, packets: *mut u32, data: *mut BufferList, descriptions: *mut *mut PacketDescription, user: *mut c_void) -> i32 {
        let unit = unsafe { &mut *(user as *mut Unit) };
        if unit.taken { unsafe { *packets = 0 }; return NO_MORE }
        unit.taken = true;
        unit.description = PacketDescription { start: 0, frames: 0, size: unit.data.len() as u32 };
        unsafe {
            *packets = 1;
            (*data).buffers[0] = Buffer { channels: super::CHANNELS, size: unit.data.len() as u32, data: unit.data.as_ptr() as *mut c_void };
            if !descriptions.is_null() { *descriptions = &mut unit.description }
        }
        0
    }

    pub struct Decoder(*mut c_void);
    // The converter is used from one thread at a time: the one that holds the Decoder.
    unsafe impl Send for Decoder {}

    impl Decoder {
        pub fn new() -> Result<Decoder, String> {
            let from = Format { sample_rate: super::RATE as f64, id: four(b"aace"), flags: 0, bytes_per_packet: 0, frames_per_packet: 480, bytes_per_frame: 0, channels: super::CHANNELS, bits: 0, reserved: 0 };
            let bytes = 2 * super::CHANNELS;
            // Signed integer, packed.
            let to = Format { sample_rate: super::RATE as f64, id: four(b"lpcm"), flags: (1 << 2) | (1 << 3), bytes_per_packet: bytes, frames_per_packet: 1, bytes_per_frame: bytes, channels: super::CHANNELS, bits: 16, reserved: 0 };
            let mut converter = std::ptr::null_mut();
            let status = unsafe { AudioConverterNew(&from, &to, &mut converter) };
            if status != 0 || converter.is_null() { return Err(format!("no AAC-ELD decoder (AudioConverterNew: {status})")) }
            // No AudioSpecificConfig: the format above is all it takes (one for ELD without SBR was refused as bad data).
            Ok(Decoder(converter))
        }

        /// One access unit as PCM; None where it doesn't decode.
        pub fn decode(&mut self, unit: &[u8]) -> Option<Vec<u8>> {
            if unit.is_empty() { return None }
            let mut pcm = vec![0u8; 2048 * 2 * super::CHANNELS as usize];
            let mut frames: u32 = 2048;
            let mut out = BufferList { count: 1, buffers: [Buffer { channels: super::CHANNELS, size: pcm.len() as u32, data: pcm.as_mut_ptr().cast() }] };
            let mut given = Unit { data: unit, description: PacketDescription { start: 0, frames: 0, size: 0 }, taken: false };
            let status = unsafe { AudioConverterFillComplexBuffer(self.0, give, (&mut given as *mut Unit).cast(), &mut frames, &mut out, std::ptr::null_mut()) };
            if (status != 0 && status != NO_MORE) || frames == 0 { return None }
            pcm.truncate(frames as usize * 2 * super::CHANNELS as usize);
            Some(pcm)
        }
    }

    impl Drop for Decoder {
        fn drop(&mut self) { unsafe { AudioConverterDispose(self.0) }; }
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    /// One access unit the device sent (an iPhone Duo, iOS 27) is 480 stereo samples; what isn't one gives none.
    #[test]
    fn a_unit_the_device_sent_is_480_stereo_samples() {
        let mut decoder = Decoder::new().unwrap();
        assert_eq!(decoder.decode(include_bytes!("sound-unit.bin")).map(|pcm| pcm.len()), Some(480 * 2 * 2));
        assert!(decoder.decode(&[]).is_none());
    }
}
