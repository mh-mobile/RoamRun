import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `roamrun mcp`: the device's commands as MCP tools over stdin/stdout (one JSON-RPC message a
/// line). A thin front: every tool asks the app, as the CLI's commands do.
/// What differs is the look: the image comes back in the answer, scaled down to what a model
/// is shown anyway, and points are taken in that image's pixels.
/// Tools run one at a time, in the order asked; what the client says meanwhile is still read,
/// so that it can take a call back.
final class DeviceMCP: @unchecked Sendable {
    typealias Ask = (DeviceControlWire.Request) throws -> DeviceControlWire.Response

    /// Read at each call: a device added or renamed since the server started is there.
    private let saved: () -> [DeviceProfile]
    private var profiles: [DeviceProfile] { saved() }
    private let ask: Ask
    /// The longer side of the image a look returns.
    static let longSide = 1280
    /// Per device: the size of the last image given out, of the look behind it, and which look
    /// that was — a point is sent with it, so it isn't read against a look another made since.
    private var shown: [UUID: (shown: CGSize, real: CGSize, look: Int?)] = [:]

    /// Where the app writes a look for this to read: the folder it keeps looks in.
    private let looks: URL
    /// The request to the app under way, which `ask` makes with it: given up when its call is taken back.
    private let asking: DeviceControlWire.Asking
    private let work = DispatchQueue(label: "roamrun.mcp")
    private let calls = NSLock()
    /// Under `calls`: the call running now, those taken back before their turn, and whether
    /// the client has gone (nothing that hasn't begun is begun for it).
    private var running: String?
    private var takenBack: Set<String> = []
    private var gone = false
    private var runningTakenBack = false

    /// A request's id as one name: 1 and "1" are two requests.
    static func name(_ id: Any) -> String { id is String ? "s:\(id)" : "n:\(id)" }

    init(profiles: @escaping () -> [DeviceProfile], looks: URL, asking: DeviceControlWire.Asking = .init(), ask: @escaping Ask) {
        self.saved = profiles
        self.looks = looks
        self.asking = asking
        self.ask = ask
    }

    /// Serves until stdin closes; tests give the lines and take the answers.
    func serve(lines: () -> String? = { readLine(strippingNewline: true) },
               write: @escaping @Sendable (Data) -> Void = { FileHandle.standardOutput.write($0 + Data([0x0A])) }) {
        while let line = lines() {
            let message = Data(line.utf8)
            let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any]
            if object?["method"] as? String == "notifications/cancelled" {
                if let id = (object?["params"] as? [String: Any])?["requestId"] { takeBack(Self.name(id)) }
                continue
            }
            let id = object?["id"].map(Self.name)
            let acts = object?["method"] as? String == "tools/call"
            work.async {
                // Taken back before its turn: not begun, and (as MCP has it) not answered.
                let begin = self.calls.withLock { () -> Bool in
                    if self.gone, acts { return false }   // what only asks about the server is still answered
                    if let id, self.takenBack.remove(id) != nil { return false }
                    self.running = id
                    self.asking.again()
                    return true
                }
                guard begin else { return }
                let answer = self.handle(message)
                // Taken back while it ran: it is not answered either.
                let wanted = self.calls.withLock { () -> Bool in
                    defer { self.running = nil; self.runningTakenBack = false }
                    return !self.runningTakenBack
                }
                if wanted, let answer { write(answer) }
            }
        }
        // The client has gone: what waits its turn — here, or at the app — isn't begun for
        // nobody. What the device is already doing runs out.
        calls.withLock {
            gone = true
            asking.giveUp()
        }
        work.sync {}
    }

    /// A call taken back by the client: one waiting its turn at the app isn't begun there; one
    /// the device is already doing runs out.
    func takeBack(_ id: String) {
        calls.withLock {
            if running == id {
                runningTakenBack = true
                asking.giveUp()
            } else { takenBack.insert(id) }
        }
    }

    /// One message in, its answer out; nil for a notification (and for what isn't JSON-RPC).
    func handle(_ message: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
              let method = object["method"] as? String else { return nil }
        guard let id = object["id"] else { return nil }   // a notification: nothing to answer
        let params = object["params"] as? [String: Any] ?? [:]
        func reply(_ result: [String: Any]) -> Data? {
            try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
        }
        switch method {
        case "initialize":
            return reply(["protocolVersion": params["protocolVersion"] as? String ?? "2024-11-05",
                          "capabilities": ["tools": [String: Any]()],
                          "serverInfo": ["name": "roamrun", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"],
                          "instructions": Self.instructions])
        case "ping":
            return reply([:])
        case "tools/list":
            return reply(["tools": Self.tools])
        case "tools/call":
            let content: [[String: Any]]
            var failed = false
            do {
                content = try call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
            } catch {
                content = [["type": "text", "text": "\(error)"]]
                failed = true
            }
            return reply(["content": content, "isError": failed])
        default:
            return try? JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "no such method: \(method)"]])
        }
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    private func call(_ tool: String, _ arguments: [String: Any]) throws -> [[String: Any]] {
        func text(_ s: String) -> [[String: Any]] { [["type": "text", "text": s]] }
        let profiles = self.profiles
        if tool == "devices" {
            return text(profiles.isEmpty ? "No devices saved in RoamRun." : profiles.map(\.displayName).joined(separator: "\n"))
        }
        let named = (arguments["device"] as? String).map { name in profiles.filter { $0.displayName.caseInsensitiveCompare(name) == .orderedSame } } ?? []
        // Two under one name (a list that was mended gives them a default one): neither is guessed at.
        guard named.count < 2 else {
            throw Failure(description: "more than one saved device is named that: the user gives each its own name in the RoamRun app")
        }
        guard let device = named.first else {
            throw Failure(description: "no such device; saved: \(profiles.map(\.displayName).joined(separator: ", "))")
        }
        func number(_ key: String) throws -> Double {
            guard let n = arguments[key] as? NSNumber else { throw Failure(description: "\(key) is missing") }
            return n.doubleValue
        }
        /// Asks the app; its refusal becomes this tool's failure.
        func send(_ request: DeviceControlWire.Request) throws -> DeviceControlWire.Response {
            let response: DeviceControlWire.Response
            do { response = try ask(request) } catch DeviceControlWire.WireError.noApp {
                throw Failure(description: "the RoamRun app isn't running (or is a build without device control): it holds the connection to the device")
            }
            guard response.ok else { throw Failure(description: response.error ?? "failed") }
            return response
        }
        /// A point given in the image a look returned, in the pixels of the look itself.
        func real(_ x: Double, _ y: Double) throws -> (x: Double, y: Double) {
            guard let sizes = shown[device.id] else { throw Failure(description: "look first: a point is given in the pixels of the image a look returns") }
            // Said in the image's own size: the app would name the look's, which the caller never saw.
            guard (0..<sizes.shown.width).contains(x), (0..<sizes.shown.height).contains(y) else {
                throw Failure(description: "the point must be inside the image (\(Int(sizes.shown.width)) x \(Int(sizes.shown.height)))")
            }
            return (x * sizes.real.width / sizes.shown.width, y * sizes.real.height / sizes.shown.height)
        }
        switch tool {
        case "look":
            let file = looks.appendingPathComponent("look-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: file) }
            let looked = try send(.init(op: "look", device: device.id, path: file.path))
            guard let (jpeg, size, original) = Self.scaled(file) else { throw Failure(description: "couldn't read the look") }
            shown[device.id] = (size, original, looked.look)
            return [["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]]
                + text("\(Int(size.width)) x \(Int(size.height)). Points for tap and swipe are pixels of this image. It serves one action: look again after it.")
        case "tap":
            let p = try real(try number("x"), try number("y"))
            let look = shown[device.id]?.look
            shown[device.id] = nil
            _ = try send(.init(op: "tap", device: device.id, x: p.x, y: p.y, look: look))
            return text("tapped; look to see what it did")
        case "swipe":
            let from = try real(try number("x1"), try number("y1")), to = try real(try number("x2"), try number("y2"))
            let look = shown[device.id]?.look
            shown[device.id] = nil
            _ = try send(.init(op: "swipe", device: device.id, x: from.x, y: from.y, x2: to.x, y2: to.y,
                               milliseconds: (arguments["milliseconds"] as? NSNumber)?.intValue, look: look))
            return text("swiped; look to see what it did")
        case "elements":
            shown[device.id] = nil   // the walk can scroll the screen
            let r = try send(.init(op: "elements", device: device.id, limit: (arguments["limit"] as? NSNumber)?.intValue))
            let captions = r.captions ?? []
            return text(captions.joined(separator: "\n") + (r.complete == true ? "" : "\n(\(captions.count) elements; the walk was cut short, there may be more)"))
        case "type", "paste", "press":
            guard let value = arguments[tool == "press" ? "button" : "text"] as? String else { throw Failure(description: "nothing to send") }
            shown[device.id] = nil
            _ = try send(.init(op: tool, device: device.id, text: value))
            return text("sent; look to see what it did")
        default:
            throw Failure(description: "no such tool: \(tool)")
        }
    }

    /// The image at `file` as JPEG with its longer side at most `longSide`; its size, and the original's.
    static func scaled(_ file: URL) -> (jpeg: Data, size: CGSize, original: CGSize)? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let original = CGSize(width: image.width, height: image.height)
        let scale = min(1, CGFloat(longSide) / max(original.width, original.height))
        let size = CGSize(width: (original.width * scale).rounded(), height: (original.height * scale).rounded())
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        let data = NSMutableData()
        guard let small = context.makeImage(),
              let out = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, small, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(out) else { return nil }
        return (data as Data, size, original)
    }

    static let instructions = """
    Operates a real iPhone or iPad through RoamRun. Look, act, look again: each look serves one \
    action, and points are pixels of the image the last look returned. These press what is really \
    there — don't tap what spends money, posts, sends, deletes or signs in unless the user asked \
    for exactly that. A look shows whatever is on the screen (notifications, messages); don't pass \
    the image on. The device lists this as screen sharing, where its user can see it, and its \
    sound goes into that session: until about five seconds after the last look or action its \
    speaker is silent and voice input on it doesn't hear. Asked to keep watching a screen, tell \
    the user that first.
    """

    private static func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]] = [:], required: [String] = []) -> [String: Any] {
        var all = properties
        if name != "devices" { all["device"] = ["type": "string", "description": "The device's name in RoamRun (see `devices`)"] }
        return ["name": name, "description": description,
                "inputSchema": ["type": "object", "properties": all, "required": (name == "devices" ? [] : ["device"]) + required]]
    }

    // Computed: JSON objects aren't Sendable, and a static stored one would have to be.
    private static var point: [String: Any] { ["type": "number", "description": "Pixels of the image the last look returned"] }

    static var tools: [[String: Any]] { [
        tool("devices", "The devices saved in RoamRun, one name a line."),
        tool("look", "The device's screen now, as an image. Do this before every tap or swipe: it serves one action."),
        tool("tap", "Tap a point of the last look. Operates the device: whatever is there gets pressed.",
             ["x": point, "y": point], required: ["x", "y"]),
        tool("swipe", "Drag from one point of the last look to another (to scroll, or move something). Operates the device.",
             ["x1": point, "y1": point, "x2": point, "y2": point,
              "milliseconds": ["type": "integer", "description": "How long the drag takes (50...5000, default 300)"]],
             required: ["x1", "y1", "x2", "y2"]),
        tool("elements", "What accessibility says is on the screen, one caption a line (\"Home, tab, selected\"). No positions: find a caption in a look to tap it. The screen may scroll to what is visited. Nothing on the home screen.",
             ["limit": ["type": "integer", "description": "How many at most (default 40)"]]),
        tool("type", "Type text on the device's keyboard, into whatever has its focus. US-keyboard characters only; a newline is Return. Right only while the device's keyboard is an English one — look first: under a Japanese one the text comes out wrong, and a long one can throw the app out. Typed at the device's pace, about 16 characters a second: paste for anything long.",
             ["text": ["type": "string"]], required: ["text"]),
        tool("paste", "Put any text into whatever has the keyboard's focus, by the device's pasteboard (which it replaces). iOS then asks \"Allow Paste\" on the device each time: look, and tap it only if the user wants that.",
             ["text": ["type": "string"]], required: ["text"]),
        tool("press", "Press a hardware button. `lock` can't be undone from here: the user has to unlock.",
             ["button": ["type": "string", "enum": ["home", "lock", "volume-up", "volume-down"]]], required: ["button"]),
    ] }
}
