//! The screen stream as a run of access units, for one that watches it (`roamrunctl view`): this alone reads the
//! stream's sockets while it is held, and without the device's lock, so inputs go on meanwhile.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use idevice::core_device::{build_frame_ack, build_keyframe_request, build_rctl, is_rtcp, HevcDepacketizer, RtpPacket};
use idevice::tcp::handle::UdpSocketHandle;

use crate::{stream_for_input, with_room, Held, KEYFRAME_APART, KEYFRAME_WAIT, LABEL, STOPPED, STREAM_DEADLINE, VIDEO_SENDER_PORT};

/// How often the receiver's report goes, as idevice's `build_rctl` documents it.
const RCTL_EVERY: Duration = Duration::from_millis(50);
/// Nothing at all from the device for this long, asked or not: the stream is taken as gone.
const SILENT: Duration = Duration::from_secs(8);

/// One access unit of the stream, Annex B; `key` where it holds an IRAP picture (with its parameter sets before it).
pub struct Frame {
    pub key: bool,
    pub data: Vec<u8>,
}

/// While it is held, the stream runs and only this reads it. Dropped, the stream is left to the idle stop.
pub struct Watch {
    held: Arc<Held>,
    video: Arc<UdpSocketHandle>,
    audio: Arc<UdpSocketHandle>,
    ssrc: u32,
    media: Option<u32>,
    feedback_port: Option<u16>,
    frames: HevcDepacketizer,
    /// Frame acks and receiver reports sent.
    feedback: bool,
    began: Instant,
    rctl_at: Instant,
    heard_at: Instant,
    count: u16,
    first_seq: Option<u16>,
    highest_seq: u16,
    keyframe_at: Instant,
    asked_at: Option<Instant>,
    requests: u8,
    /// Raised by whoever wants a key frame; lowered when one comes.
    wanted: Arc<AtomicBool>,
    pub asked: u32,
    pub answered: u32,
    last_seq: Option<u16>,
    gap: u32,
    frame_first: Option<u16>,
    trace: bool,
    max_datagram: usize,
    /// The next number the depacketizer is given.
    fed: u16,
    broken_at: Option<Instant>,
    /// Access units already cut from what the depacketizer gave, not yet handed on.
    ready: std::collections::VecDeque<Vec<u8>>,
    /// A packet went missing: nothing is given until a whole IRAP picture comes.
    broken: bool,
    /// Taken up again at an IRAP after a hole: its RASL pictures refer to what was lost, and aren't given.
    skip_rasl: bool,
    pub lost: u32,
    pub dropped: u32,
}

impl Watch {
    /// The stream, started if it doesn't run. One watch at a time.
    pub(crate) fn start(held: Arc<Held>, feedback: bool, wanted: Arc<AtomicBool>) -> Result<Watch, String> {
        let watch = with_room(|| {
            let mut link = held.link.lock().unwrap_or_else(|e| e.into_inner());
            if link.stop.raised() { return Err(STOPPED.into()) }
            if link.watched { return Err("the screen is watched already".into()) }
            held.runtime.block_on(async { tokio::time::timeout(STREAM_DEADLINE, stream_for_input(&mut link)).await.unwrap_or_else(|_| Err("timed out".into())) })?;
            let stream = link.stream.as_ref().ok_or("no stream")?;
            let parts = (stream.video.clone(), stream.audio.clone(), stream.ssrc, stream.media, stream.feedback_port, stream.keyframe_at);
            link.watched = true;
            Ok(parts)
        })?;
        let (video, audio, ssrc, media, feedback_port, keyframe_at) = watch;
        let now = Instant::now();
        wanted.store(true, Ordering::Relaxed);
        Ok(Watch {
            held, video, audio, ssrc, media, feedback_port, frames: HevcDepacketizer::new(), feedback, began: now, rctl_at: now, heard_at: now,
            count: 0, first_seq: None, highest_seq: 0, keyframe_at, asked_at: None, requests: 0, wanted, asked: 0, answered: 0,
            last_seq: None, gap: 0, frame_first: None, trace: std::env::var_os("ROAMRUNCTL_VIEW_TRACE").is_some(), broken: false, skip_rasl: false, max_datagram: 0, fed: 0, broken_at: None, ready: Default::default(), lost: 0, dropped: 0,
        })
    }

    /// The next access unit; an error once nothing has come for `SILENT` (the stream is then let go of: watch anew).
    /// From a thread of its own, with room (8 MB).
    pub fn frame(&mut self) -> Result<Frame, String> {
        let held = self.held.clone();
        held.runtime.block_on(async {
            loop {
                if let Some(data) = self.ready.pop_front() {
                    let key = has_irap(&data);
                    if key { self.keyframe_at = Instant::now() }
                    if self.broken && !key { self.dropped += 1; continue }
                    if key {
                        self.skip_rasl = std::mem::take(&mut self.broken);
                        if let (Some(at), true) = (self.broken_at.take(), self.trace) { eprintln!("trace: whole again after {} ms", at.elapsed().as_millis()) }
                    }
                    else if self.skip_rasl && is_rasl(&data) { self.dropped += 1; continue }
                    else { self.skip_rasl = false }
                    if key {
                        if self.asked_at.take().is_some() { self.answered += 1 }
                        self.wanted.store(false, Ordering::Relaxed);
                    }
                    return Ok(Frame { key, data });
                }
                while let Ok(Ok(_)) = tokio::time::timeout(Duration::ZERO, self.audio.recv()).await {}
                self.ask_if_wanted().await;
                if self.feedback && self.rctl_at.elapsed() >= RCTL_EVERY {
                    self.rctl_at = Instant::now();
                    let clock = self.began.elapsed().as_millis() as u16;
                    let highest = self.highest_seq.wrapping_sub(self.first_seq.unwrap_or(self.highest_seq));
                    self.send(build_rctl(self.ssrc, clock, self.count, highest)).await;
                }
                let datagram = match tokio::time::timeout(RCTL_EVERY, self.video.recv()).await {
                    Ok(Ok(datagram)) => datagram,
                    Ok(Err(e)) => return Err(format!("video: {e:?}")),
                    Err(_) if self.heard_at.elapsed() >= SILENT => return Err(format!("no frames for {} s", SILENT.as_secs())),
                    Err(_) => continue,
                };
                self.heard_at = Instant::now();
                if is_rtcp(&datagram.data) {
                    self.feedback_port = Some(datagram.source_port);
                    continue;
                }
                self.max_datagram = self.max_datagram.max(datagram.data.len());
                let Some(packet) = RtpPacket::parse(&datagram.data) else { continue };
                if *self.media.get_or_insert(packet.ssrc) != packet.ssrc { continue }
                self.first_seq.get_or_insert(packet.sequence_number);
                let mut hole = false;
                if let Some(last) = self.last_seq {
                    let step = packet.sequence_number.wrapping_sub(last);
                    // Late or repeated packets (step past half the range) aren't losses.
                    if step >= 0x8000 && self.trace { eprintln!("trace: late {} after {last} (back {})", packet.sequence_number, 0u16.wrapping_sub(step)) }
                    if step >= 0x8000 { continue }
                    hole = step != 1;
                    if hole { self.gap += u32::from(step.wrapping_sub(1)); if self.trace { eprintln!("trace: seq {last} -> {} (step {step})", packet.sequence_number) } }
                }
                if self.last_seq.is_none_or(|last| packet.sequence_number.wrapping_sub(last) < 0x8000) { self.last_seq = Some(packet.sequence_number) }
                self.highest_seq = packet.sequence_number;
                // A picture that opens right after a hole can come whole: what refers to the lost one waits for a key frame.
                if feed(&mut self.frames, &mut self.fed, hole, packet.timestamp, packet.payload) {
                    self.lost += std::mem::take(&mut self.gap);
                    self.frame_first = None;
                    self.broke();
                }
                self.frame_first.get_or_insert(packet.sequence_number);
                if !packet.marker { continue }
                let data = self.frames.take_output();
                if data.is_empty() { continue }
                self.count = self.count.wrapping_add(1);
                if self.feedback { self.send(build_frame_ack(self.ssrc, packet.timestamp)).await }
                if self.trace && (self.gap > 0 || self.count.is_multiple_of(120)) {
                    eprintln!("trace: frame {} seq {}-{} bytes {} gap {} ts {} max datagram {} units {}", self.count, self.frame_first.unwrap_or(0), packet.sequence_number, data.len(), self.gap, packet.timestamp, self.max_datagram, access_units(&data).len());
                }
                let whole = self.gap == 0;
                self.lost += self.gap;
                self.gap = 0;
                self.frame_first = None;
                // A picture with a hole decodes as garbage, or not at all, and so does all that refers to it.
                if !whole {
                    self.broke();
                    self.dropped += 1;
                    if has_irap(&data) { self.keyframe_at = Instant::now() }
                    continue;
                }
                // Several pictures can come out at one marker: each is given on its own, as a decoder takes them.
                self.ready.extend(access_units(&data));
            }
        })
    }

    /// A picture was lost: what refers to it isn't given until a whole IRAP, which is asked for.
    fn broke(&mut self) {
        if !self.broken && self.trace { eprintln!("trace: broken from frame {}", self.count) }
        self.broken_at.get_or_insert_with(Instant::now);
        self.broken = true;
        self.wanted.store(true, Ordering::Relaxed);
    }

    /// A request for a key frame, where one is wanted: not sooner after the last than the device answers, and again
    /// where one asked for doesn't come in time.
    async fn ask_if_wanted(&mut self) {
        let (Some(media), true) = (self.media, self.wanted.load(Ordering::Relaxed)) else { return };
        if self.keyframe_at.elapsed() < KEYFRAME_APART || self.asked_at.is_some_and(|at| at.elapsed() < KEYFRAME_WAIT) { return }
        self.requests = self.requests.wrapping_add(1);
        if self.trace { eprintln!("trace: key frame asked ({}), to {:?}", self.requests, self.feedback_port) }
        self.asked += 1;
        self.asked_at = Some(Instant::now());
        let request = build_keyframe_request(self.ssrc, LABEL, media, &[], self.requests);
        match self.feedback_port {
            Some(_) => self.send(request).await,
            None => {
                let _ = self.video.send_to(VIDEO_SENDER_PORT, request.clone()).await;
                let _ = self.video.send_to(VIDEO_SENDER_PORT + 1, request).await;
            }
        }
    }

    /// To where the device's own reports come from; nowhere before one has.
    async fn send(&self, packet: Vec<u8>) {
        if let Some(port) = self.feedback_port { let _ = self.video.send_to(port, packet).await; }
    }
}

impl Drop for Watch {
    fn drop(&mut self) {
        let mut link = self.held.link.lock().unwrap_or_else(|e| e.into_inner());
        link.watched = false;
        // The idle stop from now: the device stops listing screen sharing some seconds after the last viewer.
        link.stream_used = Instant::now();
    }
}

/// Whether Annex B holds an IRAP slice (NAL types 16...23), wherever it came from (a single, fragmented or
/// aggregated packet).
pub fn has_irap(annexb: &[u8]) -> bool {
    nal_units(annexb).any(|nal| (16..=23).contains(&((nal[0] >> 1) & 0x3f)))
}

/// Annex B cut into access units at its access unit delimiters (NAL type 35), which the depacketizer puts
/// at each new picture; what comes before the first delimiter goes with it.
pub fn access_units(annexb: &[u8]) -> Vec<Vec<u8>> {
    let mut cuts = Vec::new();
    let mut i = 0;
    while i + 4 <= annexb.len() {
        if annexb[i..i + 3] == [0, 0, 1] && (annexb[i + 3] >> 1) & 0x3f == 35 {
            // A four-byte start code starts a zero earlier.
            cuts.push(if i > 0 && annexb[i - 1] == 0 { i - 1 } else { i });
            i += 3;
        } else { i += 1 }
    }
    let mut units = Vec::new();
    let mut from = 0;
    for cut in cuts.into_iter().filter(|&c| c > 0) {
        if annexb[from..cut].iter().any(|&b| b != 0) { units.push(annexb[from..cut].to_vec()) }
        from = cut;
    }
    if from < annexb.len() { units.push(annexb[from..].to_vec()) }
    units
}

/// Whether every slice is a RASL picture's (NAL types 8 and 9), which refers to pictures before its IRAP.
pub fn is_rasl(annexb: &[u8]) -> bool {
    let mut slices = nal_units(annexb).map(|nal| (nal[0] >> 1) & 0x3f).filter(|t| *t < 32).peekable();
    slices.peek().is_some() && slices.all(|t| t == 8 || t == 9)
}

/// A packet to the depacketizer under a number of its own, without holes: at a hole it would hold up to 128 packets
/// for a late one, which this tunnel (TCP) never brings. An empty aggregation packet ends a fragment the hole cut.
/// Where the packet after a hole opens a picture, what came before it (cut short) is let go, and true is returned.
fn feed(frames: &mut HevcDepacketizer, fed: &mut u16, hole: bool, timestamp: u32, payload: &[u8]) -> bool {
    let fresh = hole && starts_picture(payload);
    if fresh { frames.take_output(); }
    if hole {
        frames.push(*fed, timestamp, &[0x60, 0x01]);
        *fed = fed.wrapping_add(1);
    }
    frames.push(*fed, timestamp, payload);
    *fed = fed.wrapping_add(1);
    fresh
}

/// Whether an RTP payload opens a picture: a parameter set, delimiter or prefix SEI, or the first slice segment of one
/// (first_slice_segment_in_pic_flag, the slice header's first bit), alone, as a fragment's start, or first in an
/// aggregation packet.
fn starts_picture(payload: &[u8]) -> bool {
    let opens = |nal: &[u8]| match nal.first().map(|b| (b >> 1) & 0x3f) {
        Some(0..=31) => nal.get(2).is_some_and(|b| b & 0x80 != 0),
        Some(32..=35 | 39) => true,
        _ => false,
    };
    match payload.first().map(|b| (b >> 1) & 0x3f) {
        // An FU: its header's S bit and type, then the NAL's payload (its header isn't repeated).
        Some(49) => payload.get(2).is_some_and(|fu| fu & 0x80 != 0 && fu & 0x3f < 32) && payload.get(3).is_some_and(|b| b & 0x80 != 0),
        Some(48) => payload.get(4..).is_some_and(opens),
        Some(_) => opens(payload),
        None => false,
    }
}

/// The NAL units of Annex B, without their start codes; empty ones left out.
pub fn nal_units(annexb: &[u8]) -> impl Iterator<Item = &[u8]> {
    let mut starts = Vec::new();
    let mut i = 0;
    while i + 3 <= annexb.len() {
        if annexb[i..i + 3] == [0, 0, 1] { starts.push(i + 3); i += 3 } else { i += 1 }
    }
    let ends: Vec<usize> = starts.iter().skip(1).map(|&s| s - 3).chain(std::iter::once(annexb.len())).collect();
    starts.into_iter().zip(ends).map(move |(s, e)| {
        // A four-byte start code leaves its first zero at the end of the unit before.
        let e = if e > s && e < annexb.len() && annexb[e - 1] == 0 { e - 1 } else { e };
        &annexb[s..e.max(s)]
    }).filter(|nal| nal.len() >= 2)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Several pictures that came out at one marker are given one by one, each from its delimiter; parameter sets
    /// before the first delimiter stay with the first picture.
    #[test]
    fn several_pictures_at_one_marker_are_cut_at_their_delimiters() {
        let vps = [0, 0, 0, 1, 0x40, 0x01, 0xaa];
        let aud = [0, 0, 0, 1, 0x46, 0x01, 0x50];
        let idr = [0, 0, 1, 0x28, 0x01, 0xbb, 0xcc];
        let trail = [0, 0, 1, 0x02, 0x01, 0xdd];
        let joined: Vec<u8> = [&aud[..], &vps, &idr, &aud, &trail, &aud, &trail].concat();
        let units = access_units(&joined);
        assert_eq!(units.len(), 3, "{units:?}");
        assert!(has_irap(&units[0]) && !has_irap(&units[1]) && !has_irap(&units[2]));
        assert_eq!(units.concat(), joined);
        assert_eq!(access_units(&[&vps[..], &idr].concat()).len(), 1);
    }

    /// RASL pictures (8, 9) are told from others, which a resumed decoder can take.
    #[test]
    fn rasl_pictures_are_told_apart() {
        let aud = [0, 0, 1, 0x46, 0x01, 0x50];
        assert!(is_rasl(&[&aud[..], &[0, 0, 1, 0x10, 0x01, 0xaa]].concat()));    // type 8
        assert!(!is_rasl(&[&aud[..], &[0, 0, 1, 0x02, 0x01, 0xaa]].concat()));   // type 1
        assert!(!is_rasl(&aud));
    }

    fn rtp(seq: u16, ts: u32, marker: bool, payload: &[u8]) -> Vec<u8> {
        let mut p = vec![0x80, if marker { 0x80 | 100 } else { 100 }];
        p.extend_from_slice(&seq.to_be_bytes());
        p.extend_from_slice(&ts.to_be_bytes());
        p.extend_from_slice(&7u32.to_be_bytes());
        p.extend_from_slice(payload);
        p
    }

    /// As `frame` does it: RTP through idevice's depacketizer, then the key flag from what came out.
    fn units(packets: &[Vec<u8>]) -> Vec<(bool, Vec<u8>)> {
        let (mut frames, mut fed, mut last) = (HevcDepacketizer::new(), 0, None::<u16>);
        let mut out = Vec::new();
        for datagram in packets {
            let packet = RtpPacket::parse(datagram).unwrap();
            let hole = last.is_some_and(|l| packet.sequence_number.wrapping_sub(l) != 1);
            last = Some(packet.sequence_number);
            feed(&mut frames, &mut fed, hole, packet.timestamp, packet.payload);
            if packet.marker {
                let data = frames.take_output();
                out.push((has_irap(&data), data));
            }
        }
        out
    }

    #[test]
    fn a_key_frame_is_told_by_what_the_depacketizer_gives_however_it_came() {
        let (vps, sps, pps) = ([0x40, 0x01, 0xaa], [0x42, 0x01, 0xbb], [0x44, 0x01, 0xcc]);
        // Parameter sets in one aggregation packet, then an IDR slice (type 19) in two fragments.
        let mut ap = vec![0x60, 0x01];
        for set in [&vps[..], &sps, &pps] { ap.extend_from_slice(&(set.len() as u16).to_be_bytes()); ap.extend_from_slice(set); }
        let idr = [vec![0x62, 0x01, 0x80 | 19, 1, 2], vec![0x62, 0x01, 0x40 | 19, 3]];
        // Then a trailing picture (type 1), one packet; then an IDR slice inside an aggregation packet.
        let trail = [0x02, 0x01, 9, 9];
        let mut ap_idr = vec![0x60, 0x01, 0, 3, 0x26, 0x01, 5];
        ap_idr.extend_from_slice(&[0, 2, 0x02, 0x01]);
        let got = units(&[rtp(1, 100, false, &ap), rtp(2, 100, false, &idr[0]), rtp(3, 100, true, &idr[1]), rtp(4, 200, true, &trail), rtp(5, 300, true, &ap_idr)]);
        assert_eq!(got.iter().map(|(key, _)| *key).collect::<Vec<_>>(), [true, false, true]);
        let first: Vec<&[u8]> = nal_units(&got[0].1).collect();
        assert_eq!(first, [&vps[..], &sps, &pps, &[0x26, 0x01, 1, 2, 3]]);
        // The next unit opens with the delimiter the depacketizer writes, and isn't taken for a key frame by it.
        assert_eq!(nal_units(&got[1].1).next().unwrap(), [0x46, 0x01, 0x50]);
    }

    /// After a lost packet the next picture comes out at its marker, not 128 packets later, without the fragment cut.
    #[test]
    fn a_hole_is_not_waited_out() {
        let trail = [0x02, 0x01, 9, 9];
        let got = units(&[rtp(1, 100, false, &[0x62, 0x01, 0x80 | 19, 1, 2]), rtp(3, 200, true, &trail)]);
        assert_eq!(got.len(), 1);
        assert_eq!(nal_units(&got[0].1).collect::<Vec<_>>(), [&[0x46, 0x01, 0x50][..], &trail]);
    }

    /// A picture whose first packet comes right after a hole is given whole; what the hole cut short isn't.
    #[test]
    fn a_picture_that_starts_after_a_hole_comes_whole() {
        let next = [0x02, 0x01, 0x80, 7];
        let got = units(&[rtp(1, 100, false, &[0x02, 0x01, 0x80, 1]), rtp(3, 200, true, &next)]);
        assert_eq!(nal_units(&got[0].1).collect::<Vec<_>>(), [&[0x46, 0x01, 0x50][..], &next]);
    }

    /// What opens a picture: its first slice segment, alone, as a fragment's start or first in an aggregation packet,
    /// and parameter sets; not a later slice segment nor a fragment's middle.
    #[test]
    fn what_opens_a_picture() {
        assert!(starts_picture(&[0x26, 0x01, 0x80, 1]));                 // IDR, first slice segment
        assert!(!starts_picture(&[0x02, 0x01, 0x40, 1]));                // a later slice segment
        assert!(starts_picture(&[0x62, 0x01, 0x80 | 19, 0x80, 1]));      // FU start of a first slice segment
        assert!(!starts_picture(&[0x62, 0x01, 19, 0x80, 1]));            // FU middle
        assert!(!starts_picture(&[0x62, 0x01, 0x80 | 19, 0x00, 1]));     // FU start of a later segment
        assert!(starts_picture(&[0x60, 0x01, 0, 3, 0x40, 0x01, 0xaa]));  // AP opening with a VPS
        assert!(!starts_picture(&[0x60, 0x01]));                         // an empty AP (what `feed` puts at a hole)
    }

    #[test]
    fn start_codes_of_three_and_four_bytes_are_cut_off() {
        let annexb = [0, 0, 0, 1, 0x40, 0x01, 0, 0, 1, 0x26, 0x01, 7, 0, 0, 0, 1, 0x02, 0x01];
        let nals: Vec<&[u8]> = nal_units(&annexb).collect();
        assert_eq!(nals, [&[0x40, 0x01][..], &[0x26, 0x01, 7], &[0x02, 0x01]]);
        assert!(has_irap(&annexb));
        assert!(!has_irap(&[0, 0, 1, 0x02, 0x01, 0, 0, 1, 0x40, 0x01]));
    }
}
