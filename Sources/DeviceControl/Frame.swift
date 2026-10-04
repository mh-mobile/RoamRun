import CoreMedia
import Foundation
import VideoToolbox

public enum FrameError: Error { case message(String) }

/// The primary display's size in pixels, as the device holds it (portrait for a phone).
public func screenSize(udid: String) -> (width: Int, height: Int)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    p.arguments = ["devicectl", "--quiet", "device", "info", "displays", "--device", udid, "--json-output", "-"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    let read = Output()
    guard (try? p.run()) != nil else { return nil }
    DispatchQueue.global(qos: .utility).async {
        read.data = out.fileHandleForReading.readDataToEndOfFile()
        done.signal()
    }
    // A look waits for this: devicectl that can't reach the device gets 15 s, is then told to
    // end, and a second later is ended. Whatever it does, this returns.
    guard done.wait(timeout: .now() + 15) == .success else {
        p.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        return nil
    }
    let data = read.data
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let displays = (root["result"] as? [String: Any])?["displays"] as? [[String: Any]],
          let size = (displays.first { $0["primary"] as? Bool == true } ?? displays.first)?["nativeSize"] as? [Int],
          size.count == 2, size[0] > 0, size[1] > 0 else { return nil }
    return (size[0], size[1])
}

/// Each device's screen size: asked once it has been answered, and while it hasn't, asked again
/// only after `retry` (a look mustn't wait for devicectl every time). Kept for as long as the app runs.
public final class ScreenSizes: @unchecked Sendable {
    public static let shared = ScreenSizes(ask: screenSize(udid:))

    private let ask: (String) -> (width: Int, height: Int)?
    private let retry: TimeInterval
    private let lock = NSLock()
    private var known: [String: (width: Int, height: Int)] = [:]
    private var failed: [String: Date] = [:]

    public init(ask: @escaping (String) -> (width: Int, height: Int)?, retry: TimeInterval = 60) {
        self.ask = ask
        self.retry = retry
    }

    public func size(of udid: String, now: Date = Date()) -> (width: Int, height: Int)? {
        let (size, due) = lock.withLock { (known[udid], failed[udid].map { now.timeIntervalSince($0) >= retry } ?? true) }
        if let size { return size }
        guard due else { return nil }
        let answer = ask(udid)   // not under the lock: it can take seconds
        lock.withLock {
            known[udid] = answer
            failed[udid] = answer == nil ? now : nil
        }
        return answer
    }
}

/// The frame without the stream's padding, which is on the right and at the bottom. A frame
/// that is neither the screen's size nor a little more (either way round) is left alone.
public func cut(_ image: CGImage, to screen: (width: Int, height: Int)?) -> CGImage {
    guard let screen else { return image }
    for (w, h) in [(screen.width, screen.height), (screen.height, screen.width)]
    where (w...w + 32).contains(image.width) && (h...h + 32).contains(image.height) {
        return image.cropping(to: CGRect(x: 0, y: 0, width: w, height: h)) ?? image
    }
    return image
}

final class Output: @unchecked Sendable {
    var pixels: CVImageBuffer?
    var data = Data()
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
        Data(b[s.unit..<(n + 1 < starts.count ? starts[n + 1].code : b.count)])
    }
}

/// One HEVC key frame (VPS, SPS, PPS and its slices) decoded to an image.
public func decodeKeyFrame(_ annexB: Data) throws -> CGImage {
    var sets: [UInt8: Data] = [:]   // 32 VPS, 33 SPS, 34 PPS
    var slices = Data()
    for unit in nalUnits(annexB) where !unit.isEmpty {
        let type = (unit[unit.startIndex] >> 1) & 0x3f
        if (32...34).contains(type) {
            sets[type] = unit
        } else if type <= 31 {   // a coded slice: length-prefixed, as VideoToolbox takes them
            withUnsafeBytes(of: UInt32(unit.count).bigEndian) { slices.append(contentsOf: $0) }
            slices.append(unit)
        }
    }
    guard let vps = sets[32], let sps = sets[33], let pps = sets[34], !slices.isEmpty else {
        throw FrameError.message("no parameter sets or slices in the frame")
    }
    var format: CMFormatDescription?
    let status = [vps, sps, pps].map { [UInt8]($0) }.withParameterSets { pointers, sizes in
        CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: 3, parameterSetPointers: pointers,
                                                            parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil,
                                                            formatDescriptionOut: &format)
    }
    guard status == noErr, let format else { throw FrameError.message("format description: \(status)") }

    var block: CMBlockBuffer?
    var sample: CMSampleBuffer?
    let count = slices.count
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count, blockAllocator: nil,
                                             customBlockSource: nil, offsetToData: 0, dataLength: count, flags: 0,
                                             blockBufferOut: &block) == noErr, let block,
          slices.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count) }) == noErr
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
    let decoded = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { _, _, buffer, _, _ in
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
        defer { buffers.forEach { $0.deallocate() } }
        return body(buffers.map { UnsafePointer($0) }, map(\.count))
    }
}
