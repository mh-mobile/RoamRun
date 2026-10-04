import DeviceControl
import Foundation
import ImageIO
import UniformTypeIdentifiers

// DeviceProbe selftest                                   the recovery rules, without a device
// DeviceProbe info     <ip> <port> <pairing file>        open: verify, tunnel, list services
// DeviceProbe look     <ip> <port> <pairing file> <out.png> [n]   n frames (default 1), the last saved
// DeviceProbe elements <ip> <port> <pairing file> [limit]         CAN SCROLL THE DEVICE
// DeviceProbe hold     <ip> <port> <pairing file> <dir> [seconds between, default 5] [minutes, default 10]
//     one connection kept open: a frame into <dir>/hold.png each time, a line per try. A line
//     "tap <x> <y>" in <dir>/cmd is performed once and the file removed.
// These OPERATE THE DEVICE; points are fractions 0...1 of the screen. With [after.png], a frame
// of what followed is saved:
// DeviceProbe tap    <ip> <port> <pairing file> <x> <y> [after.png]
// DeviceProbe swipe  <ip> <port> <pairing file> <x1> <y1> <x2> <y2> <ms> [after.png]
// DeviceProbe type   <ip> <port> <pairing file> <text> [after.png]
// DeviceProbe paste  <ip> <port> <pairing file> <text> [after.png]   (replaces its pasteboard)
// DeviceProbe button <ip> <port> <pairing file> <home|lock|volume-up|volume-down> [after.png]
// DeviceProbe pair   <pairing file> [name]                 waits for a device to pair with this Mac
//     (iOS 27+, same network): on the device, Settings > Privacy & Security > Developer Mode
//     lists [name]; the code printed here is entered there. Sends the device no input.
// --udid <udid> anywhere: frames are cut to the screen's own size, asked of devicectl.
var args = Array(CommandLine.arguments.dropFirst())
var udid: String?
if let flag = args.firstIndex(of: "--udid"), flag + 1 < args.count {
    udid = args[flag + 1]
    args.removeSubrange(flag...flag + 1)
}
guard let verb = args.first else { print("see the top of Sources/DeviceProbe/main.swift"); exit(0) }
args.removeFirst()

if verb == "selftest" {
    selfTest()
    exit(0)
}
if verb == "pair" {
    guard let file = args.first else { exit(2) }
    setvbuf(stdout, nil, _IOLBF, 0)
    do {
        let pairing = try DevicePairing(name: args.count > 1 ? args[1] : "RoamRun (\(Host.current().localizedName ?? "Mac"))")
        print("waiting: pick \"\(pairing.name)\" on the device")
        let paired = try pairing.accept(to: file) { print("code: \($0)") }
        print("paired: \(paired.name) (\(paired.model)) \(paired.udid) -> \(file)")
        exit(0)
    } catch {
        print("pair: \(error)")
        exit(1)
    }
}
guard args.count >= 3, let port = UInt16(args[1]) else { exit(2) }
let rest = Array(args.dropFirst(3))
let clock = DateFormatter()
clock.dateFormat = "HH:mm:ss"
setvbuf(stdout, nil, _IOLBF, 0)
let session = DeviceSession(ip: args[0], port: port, pairingFile: args[2], udid: udid)
session.onEvent = { print("  [\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))] \($0)") }

func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }

/// One frame, saved to `path`; false when it couldn't be had.
@discardableResult
func save(to path: String, _ label: String) -> Bool {
    let started = Date()
    do {
        let image = try session.look()
        guard let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw FrameError.message("can't write \(path)")
        }
        CGImageDestinationAddImage(out, image, nil)
        guard CGImageDestinationFinalize(out) else { throw FrameError.message("can't write \(path)") }
        print("\(label): \(image.width)x\(image.height) in \(ms(started)) ms")
        return true
    } catch {
        print("\(label): no frame after \(ms(started)) ms: \(error)")
        return false
    }
}

func operate(_ what: String, after: String?, _ body: () throws -> Void) {
    let started = Date()
    do {
        try body()
        print("\(what): done in \(ms(started)) ms")
    } catch {
        print("\(what): \(error)")
        return
    }
    if let after {
        Thread.sleep(forTimeInterval: 0.7)   // let the interface settle before looking
        save(to: after, "after")
    }
}

let number = { (i: Int) in i < rest.count ? Double(rest[i]) : nil }
switch verb {
case "info":
    do { print(try session.info()) } catch { print("can't open: \(error)") }
case "look":
    guard let path = rest.first else { exit(2) }
    // A third word: seconds to wait between frames (the stream is stopped after 15 unused).
    let pause = number(2) ?? 0
    for n in 1...max(rest.count > 1 ? Int(rest[1]) ?? 1 : 1, 1) {
        if n > 1, pause > 0 { Thread.sleep(forTimeInterval: pause) }
        save(to: path, "frame \(n)")
    }
    print((try? session.info()) ?? "")
case "elements":
    do {
        let started = Date()
        let found = try session.elements(limit: rest.first.flatMap { Int($0) } ?? 40)
        for (n, caption) in found.captions.enumerated() { print("\(n): \(caption)") }
        print("\(found.captions.count) elements, complete: \(found.complete), \(ms(started)) ms")
    } catch { print("elements: \(error)") }
case "hold":
    guard let dir = rest.first else { exit(2) }
    let every = number(1) ?? 5
    let until = Date().addingTimeInterval((number(2) ?? 10) * 60)
    while Date() < until {
        let command = dir + "/cmd"
        if let line = try? String(contentsOfFile: command, encoding: .utf8) {
            try? FileManager.default.removeItem(atPath: command)
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if words.count == 3, words[0] == "tap", let x = Double(words[1]), let y = Double(words[2]) {
                operate("\(clock.string(from: Date())) tap \(x) \(y)", after: nil) { try session.tap(x: x, y: y) }
            }
        }
        save(to: dir + "/hold.png", clock.string(from: Date()))
        Thread.sleep(forTimeInterval: every)
    }
case "tap":
    guard let x = number(0), let y = number(1) else { exit(2) }
    operate("tap", after: rest.count > 2 ? rest[2] : nil) { try session.tap(x: x, y: y) }
case "swipe":
    guard let x1 = number(0), let y1 = number(1), let x2 = number(2), let y2 = number(3), let duration = number(4) else { exit(2) }
    operate("swipe", after: rest.count > 5 ? rest[5] : nil) { try session.swipe(from: (x1, y1), to: (x2, y2), milliseconds: Int(duration)) }
case "type":
    guard let text = rest.first else { exit(2) }
    operate("type", after: rest.count > 1 ? rest[1] : nil) { try session.type(text) }
case "paste":
    guard let text = rest.first else { exit(2) }
    operate("paste", after: rest.count > 1 ? rest[1] : nil) { try session.paste(text) }
case "button":
    guard let name = rest.first else { exit(2) }
    operate("button", after: rest.count > 1 ? rest[1] : nil) { try session.press(name) }
default:
    exit(2)
}
session.close()

/// The recovery rules against scripted outcomes. Stops at the first that doesn't hold.
func selfTest() {
    struct Boom: Error {}
    func run(repeatable: Bool, outcomes: [Bool], reopens: Bool) -> (result: Bool, attempts: Int, pauses: Int, reopened: Int) {
        var (attempts, pauses, reopened) = (0, 0, 0)
        let outcome: Void? = try? Recovery.run(repeatable: repeatable, attempt: { () throws -> Void in
            defer { attempts += 1 }
            if attempts < outcomes.count, !outcomes[attempts] { throw Boom() }
        }, pause: { pauses += 1 }, reopen: { reopened += 1; return reopens })
        return (outcome != nil, attempts, pauses, reopened)
    }
    func check(_ what: String, _ got: (result: Bool, attempts: Int, pauses: Int, reopened: Int), _ want: (Bool, Int, Int, Int)) {
        precondition(got.result == want.0 && got.attempts == want.1 && got.pauses == want.2 && got.reopened == want.3, "\(what): got \(got)")
        print("ok  \(what)")
    }
    check("a read that works is run once", run(repeatable: true, outcomes: [true], reopens: true), (true, 1, 0, 0))
    check("a read that fails once is tried again on the same connection", run(repeatable: true, outcomes: [false, true], reopens: true), (true, 2, 1, 0))
    check("a read that fails twice gets a new connection", run(repeatable: true, outcomes: [false, false, true], reopens: true), (true, 3, 1, 1))
    check("with no new connection to be had, it fails without a third try", run(repeatable: true, outcomes: [false, false, true], reopens: false), (false, 2, 1, 1))
    check("an input that fails is not repeated", run(repeatable: false, outcomes: [false, true], reopens: true), (false, 1, 0, 0))
    check("an input that works is run once", run(repeatable: false, outcomes: [true], reopens: true), (true, 1, 0, 0))
}
