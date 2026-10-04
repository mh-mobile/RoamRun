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
// These OPERATE THE DEVICE; points are fractions 0...1 of the screen. With [after.png], a
// frame of what followed is saved:
// DeviceProbe tap    <device ip> <port> <pairing file> <x> <y> [after.png]
// DeviceProbe swipe  <device ip> <port> <pairing file> <x1> <y1> <x2> <y2> <ms> [after.png]
// DeviceProbe type   <device ip> <port> <pairing file> <text> [after.png]
// DeviceProbe button <device ip> <port> <pairing file> <home|lock|volume-up|volume-down> [after.png]
// DeviceProbe elements <device ip> <port> <pairing file> [limit]
//                                                          CAN SCROLL THE DEVICE: accessibility's
//                                                          captions for what is on the screen
// `elements` sends no input, but the screen may follow it.
// --udid <udid> anywhere: frames are cut to the screen's own size, asked of devicectl (the
// stream pads them and doesn't say by how much). Without it they are saved as they come.
print("roamrun-device \(String(cString: rr_device_version()))")
var args = Array(CommandLine.arguments.dropFirst())
var screen: (width: Int, height: Int)?
if let flag = args.firstIndex(of: "--udid"), flag + 1 < args.count {
    screen = screenSize(udid: args[flag + 1])
    if screen == nil { print("devicectl didn't give the screen's size: frames keep the stream's padding (under 1% of each side)") }
    args.removeSubrange(flag...flag + 1)
}
let verb = ["tap", "swipe", "type", "button", "elements"].contains(args.first ?? "") ? args.removeFirst() : ""
let listing = verb == "elements"
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
        let image = cut(try decodeKeyFrame(frame), to: screen)
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
} else if !verb.isEmpty {
    let rest = Array(args.dropFirst(3))
    let number = { (i: Int) in i < rest.count ? Double(rest[i]) : nil }
    var after: String?
    let json: UnsafeMutablePointer<CChar>?
    switch verb {
    case "tap":
        guard let x = number(0), let y = number(1) else { exit(2) }
        json = rr_device_tap(device, x, y)
        after = rest.count > 2 ? rest[2] : nil
    case "swipe":
        guard let x1 = number(0), let y1 = number(1), let x2 = number(2), let y2 = number(3), let duration = number(4) else { exit(2) }
        json = rr_device_swipe(device, x1, y1, x2, y2, UInt32(max(duration, 0)))
        after = rest.count > 5 ? rest[5] : nil
    case "type":
        guard let text = rest.first else { exit(2) }
        json = rr_device_type(device, text)
        after = rest.count > 1 ? rest[1] : nil
    default:
        guard let name = rest.first else { exit(2) }
        json = rr_device_button(device, name)
        after = rest.count > 1 ? rest[1] : nil
    }
    guard let json else { fatalError("bad arguments") }
    print("\(verb): \(String(cString: json))")
    rr_string_free(json)
    if let after {
        Thread.sleep(forTimeInterval: 0.7)   // let the interface settle before looking
        saveFrame(to: after, "after")
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

/// The primary display's size in pixels, as the device holds it (portrait for a phone).
func screenSize(udid: String) -> (width: Int, height: Int)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    p.arguments = ["devicectl", "--quiet", "device", "info", "displays", "--device", udid, "--json-output", "-"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let displays = (root["result"] as? [String: Any])?["displays"] as? [[String: Any]],
          let size = (displays.first { $0["primary"] as? Bool == true } ?? displays.first)?["nativeSize"] as? [Int],
          size.count == 2, size[0] > 0, size[1] > 0 else { return nil }
    return (size[0], size[1])
}

/// The frame without the stream's padding, which is on the right and at the bottom. A frame
/// that is neither the screen's size nor a little more (either way round) is left alone.
func cut(_ image: CGImage, to screen: (width: Int, height: Int)?) -> CGImage {
    guard let screen else { return image }
    for (w, h) in [(screen.width, screen.height), (screen.height, screen.width)]
    where (w...w + 32).contains(image.width) && (h...h + 32).contains(image.height) {
        return image.cropping(to: CGRect(x: 0, y: 0, width: w, height: h)) ?? image
    }
    return image
}

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
