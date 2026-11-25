import CoreMedia
import Foundation
import VideoToolbox

public enum FrameError: Error { case message(String) }

/// A screen's size, kept by what it was asked for (a frame's size: another display shown is asked anew) once it has
/// been answered, and while it hasn't, asked again only after `retry` (a look mustn't wait for the answer every time).
public final class ScreenSizes: @unchecked Sendable {
    private let retry: TimeInterval
    private let lock = NSLock()
    private var known: [String: (width: Int, height: Int)] = [:]
    private var failed: [String: Date] = [:]

    public init(retry: TimeInterval = 60) {
        self.retry = retry
    }

    public func size(of key: String, now: Date = Date(),
                     ask: () -> (width: Int, height: Int)?) -> (width: Int, height: Int)?
    {
        let (size, due) = lock.withLock {
            (known[key], failed[key].map {
                now.timeIntervalSince($0) >= retry
            } ?? true)
        }
        if let size {
            return size
        }
        guard due else { return nil }
        let answer = ask() // not under the lock: it can take seconds
        lock.withLock {
            known[key] = answer
            failed[key] = answer == nil ? now : nil
        }
        return answer
    }
}

/// What a stream frame of `frame`'s size is cut to: the screen, either way round, at its size or scaled down as the
/// stream may send it (an opened iPhone Duo: 1878 x 2670 came as 1408 x 2016), without the padding up to 32 pixels
/// on the right and at the bottom. Nil where the frame isn't that. The same in roamrunctl.
public func fit(_ frame: (width: Int, height: Int),
                to screen: (width: Int, height: Int)?) -> (width: Int, height: Int)?
{
    guard let screen else { return nil }
    for (w, h) in [(screen.width, screen.height), (screen.height, screen.width)] {
        if (w ... w + 32).contains(frame.width), (h ... h + 32).contains(frame.height) {
            return (w, h)
        }
        let scale = min(Double(frame.width) / Double(w), Double(frame.height) / Double(h))
        let (sw, sh) = (Int((Double(w) * scale).rounded()), Int((Double(h) * scale).rounded()))
        if scale < 1, frame.width - sw <= 32, frame.height - sh <= 32 {
            return (sw, sh)
        }
    }
    return nil
}

/// The frame without the stream's padding (see `fit`); nil where it doesn't fit.
func cut(_ image: CGImage, to screen: (width: Int, height: Int)?) -> CGImage? {
    fit((image.width, image.height), to: screen).flatMap {
        image.cropping(to: CGRect(x: 0, y: 0, width: $0.width, height: $0.height))
    }
}

final class Output: @unchecked Sendable {
    var pixels: CVImageBuffer?
}

/// The NAL units of an Annex-B stream (each after a 00 00 01 start code).
func nalUnits(_ data: Data) -> [Data] {
    let b = [UInt8](data)
    var starts: [(code: Int, unit: Int)] = []
    var i = 0
    while i + 2 < b.count {
        if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
            starts.append((i > 0 && b[i - 1] == 0 ? i - 1 : i, i + 3))
            i += 3
        } else {
            i += 1
        }
    }
    return starts.enumerated().map { n, s in
        Data(b[s.unit ..< (n + 1 < starts.count ? starts[n + 1].code : b.count)])
    }
}

/// One HEVC key frame (VPS, SPS, PPS and its slices) decoded to an image.
func decodeKeyFrame(_ annexB: Data) throws -> CGImage {
    var sets: [UInt8: Data] = [:] // 32 VPS, 33 SPS, 34 PPS
    var slices = Data()
    for unit in nalUnits(annexB) where !unit.isEmpty {
        let type = (unit[unit.startIndex] >> 1) & 0x3f
        if (32 ... 34).contains(type) {
            sets[type] = unit
        } else if type <= 31 { // a coded slice: length-prefixed, as VideoToolbox takes them
            withUnsafeBytes(of: UInt32(unit.count).bigEndian) {
                slices.append(contentsOf: $0)
            }
            slices.append(unit)
        }
    }
    guard let vps = sets[32], let sps = sets[33], let pps = sets[34], !slices.isEmpty else {
        throw FrameError.message("no parameter sets or slices in the frame")
    }
    var format: CMFormatDescription?
    let status = [vps, sps, pps]
        .map {
            [UInt8]($0)
        }
        .withParameterSets { pointers, sizes in
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil,
                parameterSetCount: 3,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &format
            )
        }
    guard status == noErr, let format else { throw FrameError.message("format description: \(status)") }

    var block: CMBlockBuffer?
    var sample: CMSampleBuffer?
    let count = slices.count
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count, blockAllocator: nil,
                                             customBlockSource: nil, offsetToData: 0, dataLength: count, flags: 0,
                                             blockBufferOut: &block) == noErr, let block,
                                          slices.withUnsafeBytes({
                                              CMBlockBufferReplaceDataBytes(
                                                  with: $0.baseAddress!,
                                                  blockBuffer: block,
                                                  offsetIntoDestination: 0,
                                                  dataLength: count
                                              )
                                          }) == noErr
    else { throw FrameError.message("block buffer") }
    var size = count
    guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                    sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                    sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample
    else { throw FrameError.message("sample buffer") }

    var session: VTDecompressionSession?
    let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
    guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                       imageBufferAttributes: attributes, outputCallback: nil,
                                       decompressionSessionOut: &session) == noErr, let session
    else { throw FrameError.message("decoder") }
    defer { VTDecompressionSessionInvalidate(session) }
    // No async flag: the handler has run by the time the call returns.
    let output = Output()
    let decoded = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
                                                    infoFlagsOut: nil)
    { _, _, buffer, _, _ in
        output.pixels = buffer
    }
    guard decoded == noErr, let pixels = output.pixels else { throw FrameError.message("decode: \(decoded)") }
    var image: CGImage?
    VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
    guard let image else { throw FrameError.message("image") }
    return image
}

extension Array where Element == [UInt8] {
    /// Pointers to each parameter set and their sizes, valid for the call.
    func withParameterSets<R>(_ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        let buffers = map { set -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            p.initialize(from: set, count: set.count)
            return p
        }
        defer { buffers.forEach {
            $0.deallocate()
        } }
        return body(buffers.map {
            UnsafePointer($0)
        }, map(\.count))
    }
}
