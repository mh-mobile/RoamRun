//! One HEVC key frame of the device's screen stream, decoded to an image with macOS's own decoder
//! (VideoToolbox), as the RoamRun app does: a look this way doesn't wait on the device's full-size PNG.

use std::ffi::c_void;

type OSStatus = i32;
type Ref = *const c_void;

#[repr(C)]
#[derive(Clone, Copy)]
struct CMTime {
    value: i64,
    timescale: i32,
    flags: u32,
    epoch: i64,
}

type OutputCallback = extern "C" fn(*mut c_void, *mut c_void, OSStatus, u32, Ref, CMTime, CMTime);

#[repr(C)]
struct OutputCallbackRecord {
    callback: OutputCallback,
    refcon: *mut c_void,
}

#[repr(C)]
struct Opaque {
    _p: [u8; 0],
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    static kCFTypeDictionaryKeyCallBacks: Opaque;
    static kCFTypeDictionaryValueCallBacks: Opaque;
    fn CFRelease(cf: Ref);
    fn CFNumberCreate(allocator: Ref, kind: isize, value: *const c_void) -> Ref;
    fn CFDictionaryCreate(allocator: Ref, keys: *const Ref, values: *const Ref, count: isize, key_callbacks: *const Opaque,
                          value_callbacks: *const Opaque) -> Ref;
}

#[link(name = "CoreMedia", kind = "framework")]
extern "C" {
    fn CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: Ref, count: usize, pointers: *const *const u8,
                                                           sizes: *const usize, header_length: i32, extensions: Ref,
                                                           out: *mut Ref) -> OSStatus;
    fn CMBlockBufferCreateWithMemoryBlock(allocator: Ref, memory: *mut c_void, length: usize, block_allocator: Ref,
                                          source: *const c_void, offset: usize, data_length: usize, flags: u32,
                                          out: *mut Ref) -> OSStatus;
    fn CMBlockBufferReplaceDataBytes(source: *const c_void, buffer: Ref, offset: usize, length: usize) -> OSStatus;
    fn CMSampleBufferCreateReady(allocator: Ref, data: Ref, format: Ref, samples: isize, timings: isize,
                                 timing: *const c_void, sizes_count: isize, sizes: *const usize, out: *mut Ref) -> OSStatus;
}

#[link(name = "VideoToolbox", kind = "framework")]
extern "C" {
    fn VTDecompressionSessionCreate(allocator: Ref, format: Ref, specification: Ref, attributes: Ref,
                                    callback: *const OutputCallbackRecord, out: *mut Ref) -> OSStatus;
    fn VTDecompressionSessionDecodeFrame(session: Ref, sample: Ref, flags: u32, frame: *mut c_void, info: *mut u32) -> OSStatus;
    fn VTDecompressionSessionWaitForAsynchronousFrames(session: Ref) -> OSStatus;
    fn VTDecompressionSessionInvalidate(session: Ref);
}

#[link(name = "CoreVideo", kind = "framework")]
extern "C" {
    static kCVPixelBufferPixelFormatTypeKey: Ref;
    fn CVPixelBufferLockBaseAddress(buffer: Ref, flags: u64) -> i32;
    fn CVPixelBufferUnlockBaseAddress(buffer: Ref, flags: u64) -> i32;
    fn CVPixelBufferGetBaseAddress(buffer: Ref) -> *const u8;
    fn CVPixelBufferGetBytesPerRow(buffer: Ref) -> usize;
    fn CVPixelBufferGetWidth(buffer: Ref) -> usize;
    fn CVPixelBufferGetHeight(buffer: Ref) -> usize;
    fn CVPixelBufferGetPixelFormatType(buffer: Ref) -> u32;
}

const BGRA: u32 = u32::from_be_bytes(*b"BGRA");
const SINT32: isize = 3;
const READ_ONLY: u64 = 1;

/// The NAL units of an Annex B stream (each after its 00 00 01 or 00 00 00 01).
fn units(bytes: &[u8]) -> Vec<&[u8]> {
    let mut starts = Vec::new();
    let mut i = 0;
    while i + 3 <= bytes.len() {
        if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
            starts.push((i, i + 3));
            i += 3;
        } else {
            i += 1;
        }
    }
    starts.iter().enumerate().map(|(n, &(_, unit))| {
        // A 4-byte start code's leading zero belongs to it, not to the unit before.
        let end = starts.get(n + 1).map_or(bytes.len(), |&(code, _)| if code > 0 && bytes[code - 1] == 0 { code - 1 } else { code });
        &bytes[unit..end.max(unit)]
    }).filter(|u| !u.is_empty()).collect()
}

/// The parameter sets (VPS, SPS, PPS) and the coded slices of a key frame, the slices length-prefixed as
/// VideoToolbox takes them.
fn split(frame: &[u8]) -> Result<([&[u8]; 3], Vec<u8>), String> {
    let (mut vps, mut sps, mut pps, mut slices) = (None, None, None, Vec::new());
    for unit in units(frame) {
        match (unit[0] >> 1) & 0x3f {
            32 => vps = Some(unit),
            33 => sps = Some(unit),
            34 => pps = Some(unit),
            0..=31 => {
                slices.extend_from_slice(&(unit.len() as u32).to_be_bytes());
                slices.extend_from_slice(unit);
            }
            _ => {}
        }
    }
    match (vps, sps, pps) {
        (Some(v), Some(s), Some(p)) if !slices.is_empty() => Ok(([v, s, p], slices)),
        _ => Err("no parameter sets or slices in the frame".into()),
    }
}

/// What the decoder hands back, filled in by its callback: RGB, and its width and height.
struct Decoded {
    image: Option<(Vec<u8>, u32, u32)>,
    status: OSStatus,
}

extern "C" fn decoded(refcon: *mut c_void, _: *mut c_void, status: OSStatus, _: u32, buffer: Ref, _: CMTime, _: CMTime) {
    let out = unsafe { &mut *(refcon as *mut Decoded) };
    out.status = status;
    if status != 0 || buffer.is_null() { return; }
    unsafe {
        // Only what was asked for (one plane of BGRA): a panic here would end the process, not the look.
        if CVPixelBufferGetPixelFormatType(buffer) != BGRA || CVPixelBufferLockBaseAddress(buffer, READ_ONLY) != 0 { return; }
        let (width, height, row) = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), CVPixelBufferGetBytesPerRow(buffer));
        let base = CVPixelBufferGetBaseAddress(buffer);
        if !base.is_null() && width > 0 && row >= width * 4 {
            let bgra = std::slice::from_raw_parts(base, row * height);
            let mut rgb = Vec::with_capacity(width * height * 3);
            for line in bgra.chunks_exact(row) {
                for p in line[..width * 4].chunks_exact(4) {
                    rgb.extend_from_slice(&[p[2], p[1], p[0]]);
                }
            }
            out.image = Some((rgb, width as u32, height as u32));
        }
        CVPixelBufferUnlockBaseAddress(buffer, READ_ONLY);
    }
}

/// Released when dropped.
struct Owned(Ref);
impl Drop for Owned {
    fn drop(&mut self) {
        if !self.0.is_null() { unsafe { CFRelease(self.0) } }
    }
}

/// One key frame (Annex B: VPS, SPS, PPS and its slices) as RGB (3 bytes a pixel, rows one after another), with
/// its width and height: the size and way up of the stream.
pub fn decode(frame: &[u8]) -> Result<(Vec<u8>, u32, u32), String> {
    let ([vps, sps, pps], slices) = split(frame)?;
    unsafe {
        let pointers = [vps.as_ptr(), sps.as_ptr(), pps.as_ptr()];
        let sizes = [vps.len(), sps.len(), pps.len()];
        let mut format = std::ptr::null();
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(std::ptr::null(), 3, pointers.as_ptr(), sizes.as_ptr(), 4,
                                                                         std::ptr::null(), &mut format);
        let format = Owned(format);
        if status != 0 || format.0.is_null() { return Err(format!("format description: {status}")); }

        let mut block = std::ptr::null();
        if CMBlockBufferCreateWithMemoryBlock(std::ptr::null(), std::ptr::null_mut(), slices.len(), std::ptr::null(), std::ptr::null(), 0,
                                              slices.len(), 0, &mut block) != 0 || block.is_null() {
            return Err("block buffer".into());
        }
        let block = Owned(block);
        if CMBlockBufferReplaceDataBytes(slices.as_ptr() as *const c_void, block.0, 0, slices.len()) != 0 { return Err("block buffer".into()); }
        let mut sample = std::ptr::null();
        let size = slices.len();
        if CMSampleBufferCreateReady(std::ptr::null(), block.0, format.0, 1, 0, std::ptr::null(), 1, &size, &mut sample) != 0 || sample.is_null() {
            return Err("sample buffer".into());
        }
        let sample = Owned(sample);

        let kind = BGRA as i32;
        let number = Owned(CFNumberCreate(std::ptr::null(), SINT32, &kind as *const i32 as *const c_void));
        let keys = [kCVPixelBufferPixelFormatTypeKey];
        let values = [number.0];
        let attributes = Owned(CFDictionaryCreate(std::ptr::null(), keys.as_ptr(), values.as_ptr(), 1, &kCFTypeDictionaryKeyCallBacks,
                                                  &kCFTypeDictionaryValueCallBacks));
        let mut out = Decoded { image: None, status: 0 };
        let record = OutputCallbackRecord { callback: decoded, refcon: &mut out as *mut Decoded as *mut c_void };
        let mut session = std::ptr::null();
        let status = VTDecompressionSessionCreate(std::ptr::null(), format.0, std::ptr::null(), attributes.0, &record, &mut session);
        if status != 0 || session.is_null() { return Err(format!("decoder: {status}")); }
        let session = Owned(session);
        // No asynchronous flag: the callback has run by the time the frames are waited for.
        let status = VTDecompressionSessionDecodeFrame(session.0, sample.0, 0, std::ptr::null_mut(), std::ptr::null_mut());
        VTDecompressionSessionWaitForAsynchronousFrames(session.0);
        VTDecompressionSessionInvalidate(session.0);
        if status != 0 { return Err(format!("decode: {status}")); }
        out.image.ok_or_else(|| format!("decode: no image ({})", out.status))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_key_frames_units_are_found_after_three_and_four_byte_start_codes() {
        // VPS (type 32), SPS (33), PPS (34) and one slice (19, IDR), the first two after 4-byte codes.
        let frame = [0, 0, 0, 1, 0x40, 1, 0xaa, 0, 0, 0, 1, 0x42, 1, 0xbb, 0, 0, 1, 0x44, 1, 0xcc, 0, 0, 1, 0x26, 1, 0xdd, 0xee];
        let found = units(&frame);
        assert_eq!(found, vec![&[0x40, 1, 0xaa][..], &[0x42, 1, 0xbb], &[0x44, 1, 0xcc], &[0x26, 1, 0xdd, 0xee]]);
        let ([vps, sps, pps], slices) = split(&frame).unwrap();
        assert_eq!((vps[0], sps[0], pps[0]), (0x40, 0x42, 0x44));
        assert_eq!(slices, vec![0, 0, 0, 4, 0x26, 1, 0xdd, 0xee]);
        assert!(split(&frame[..14]).is_err(), "no PPS or slice: not a key frame");
    }
}
