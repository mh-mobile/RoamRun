import CoreMedia
import Foundation
import ImageIO
import RoamRunDevice
import UniformTypeIdentifiers
import VideoToolbox

// DeviceProbe                                              what the linked library is
// DeviceProbe <device ip> <port> <pairing file>            open: verify, tunnel, list services
// DeviceProbe <device ip> <port> <pairing file> <out.png> [n]
//                                                          n frames of the screen (default 1) over
//                                                          one connection; the last is saved
// DeviceProbe tap <device ip> <port> <pairing file> <x> <y> [after.png]
//                                                          OPERATES THE DEVICE: one tap at x, y
//                                                          (fractions 0...1 of the screen), then
//                                                          a frame of what followed
// DeviceProbe elements <device ip> <port> <pairing file> [limit]
//                                                          CAN SCROLL THE DEVICE: accessibility's
//                                                          captions for what is on the screen
// Only `tap` sends the device input; `elements` moves no finger but the screen may follow it.
print("roamrun-device \(String(cString: rr_device_version()))")
var args = Array(CommandLine.arguments.dropFirst())
let tapping = args.first == "tap"
let listing = args.first == "elements"
if tapping || listing { args.removeFirst() }
guard args.count >= 3, let port = UInt16(args[1]) else { exit(0) }

let opening = Date()
var error: UnsafeMutablePointer<CChar>?
guard let device = rr_device_open(args[0], port, args[2], &error) else {
    print("can't open: \(error.map { String(cString: $0) } ?? "unknown")")
    rr_string_free(error)
    exit(1)
}
defer { rr_device_close(device) }
print("opened in \(ms(opening)) ms")

func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }

/// One frame over the open connection, decoded and written to `path`.
@MainActor func saveFrame(to path: String, _ label: String) {
    let started = Date()
    var length = 0
    var error: UnsafeMutablePointer<CChar>?
    guard let bytes = rr_device_keyframe(device, &length, &error) else {
        print("\(label): no frame: \(error.map { String(cString: $0) } ?? "unknown")")
        rr_string_free(error)
        return
    }
    let frame = Data(bytes: bytes, count: length)
    rr_bytes_free(bytes, length)
    let received = ms(started)
    do {
        let image = try decodeKeyFrame(frame)
        guard let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw FrameError.message("can't write \(path)")
        }
        CGImageDestinationAddImage(out, image, nil)
        guard CGImageDestinationFinalize(out) else { throw FrameError.message("can't write \(path)") }
        print("\(label): \(frame.count) B of HEVC in \(received) ms, \(image.width)x\(image.height), decoded and saved in \(ms(started) - received) ms")
    } catch {
        print("\(label): couldn't decode: \(error)")
    }
}

if listing {
    guard let json = rr_device_elements(device, args.count >= 4 ? UInt32(args[3]) ?? 40 : 40) else { fatalError("no answer") }
    defer { rr_string_free(json) }
    let text = String(cString: json)
    if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
       let elements = object["elements"] as? [[String: Any]] {
        for (n, element) in elements.enumerated() { print("\(n): \(element["caption"] as? String ?? "")") }
        print("\(elements.count) elements, complete: \(object["complete"] ?? "?"), \(object["ms"] ?? "?") ms")
    } else {
        print(text)
    }
} else if tapping {
    guard args.count >= 5, let x = Double(args[3]), let y = Double(args[4]) else { exit(2) }
    guard let json = rr_device_tap(device, x, y) else { fatalError("bad arguments") }
    print("tap: \(String(cString: json))")
    rr_string_free(json)
    if args.count >= 6 {
        Thread.sleep(forTimeInterval: 0.7)   // let the interface settle before looking
        saveFrame(to: args[5], "after")
    }
} else if args.count == 3 {
    guard let json = rr_device_info(device) else { fatalError("no info") }
    print(String(cString: json))
    rr_string_free(json)
} else {
    let count = args.count >= 5 ? Int(args[4]) ?? 1 : 1
    for n in 1...max(count, 1) { saveFrame(to: args[3], "frame \(n)") }
}

enum FrameError: Error { case message(String) }

final class Output: @unchecked Sendable { var pixels: CVImageBuffer? }

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
func decodeKeyFrame(_ annexB: Data) throws -> CGImage {
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
