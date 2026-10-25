import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `roamrun mcp`: the device's commands as MCP tools over stdin/stdout (one JSON-RPC message a
/// line). A thin front: every tool asks the app, as the CLI's commands do, and the app alone
/// holds a look to what is done by it (it sees every caller's looks). What differs is that the
/// image comes back in the answer, with the look's id, which a tap, swipe, type or paste gives.
/// Tools run one at a time, in the order asked; what the client says meanwhile is still read,
/// so that it can take a call back.
final class DeviceMCP: @unchecked Sendable {
    typealias Ask = (DeviceControlWire.Request) throws -> DeviceControlWire.Response

    /// Read at each call: a device added or renamed since the server started is there.
    private let saved: () -> [DeviceProfile]
    private var profiles: [DeviceProfile] {
        saved()
    }

    private let ask: Ask
    /// The longer side of the image a look returns: the app's own look is that size already.
    static let longSide = DeviceControlHub.lookSide
    /// The most `type` takes in one call here.
    static let longestTyped = 500
    /// The MCP versions spoken here: initialize answers the one asked for if it is one of them, else the newest.
    static let versions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

    /// Where the app writes a look for this to read: the folder it keeps looks in (and takes an app to install from).
    private let looks: URL
    /// Whether `install` is offered, from a path on this Mac: over stdio, not to a caller elsewhere.
    let installsFromPaths: Bool
    /// Over HTTP with `--allow-install`: `install` from an upload, by its id and sha256 — made ready where the app
    /// takes it from, its path answered.
    let claimUpload: Claim?
    /// An upload handed to an install, by its id and sha256: the path the app takes it from, and what to say once the
    /// app has answered (taken, or not: then the upload is kept again).
    typealias Claim = (String, String) throws -> (path: String, settle: (_ taken: Bool) -> Void)
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
    static func name(_ id: Any) -> String {
        id is String ? "s:\(id)" : "n:\(id)"
    }

    init(
        profiles: @escaping () -> [DeviceProfile],
        looks: URL,
        installsFromPaths: Bool = true,
        claimUpload: Claim? = nil,
        asking: DeviceControlWire.Asking = .init(),
        ask: @escaping Ask
    ) {
        self.saved = profiles
        self.looks = looks
        self.installsFromPaths = installsFromPaths
        self.claimUpload = claimUpload
        self.asking = asking
        self.ask = ask
    }

    /// Serves until stdin closes; tests give the lines and take the answers.
    func serve(lines: () -> String? = {
        readLine(strippingNewline: true)
    },
    write: @escaping @Sendable (Data) -> Void = {
        FileHandle.standardOutput.write($0 + Data([0x0A]))
    }) {
        while let line = lines() {
            if line.allSatisfy(\.isWhitespace) {
                continue
            }
            let message = Data(line.utf8)
            let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any]
            if object?["method"] as? String == "notifications/cancelled" {
                if let id = (object?["params"] as? [String: Any])?["requestId"] {
                    takeBack(Self.name(id))
                }
                continue
            }
            let id = object?["id"].map(Self.name)
            let acts = object?["method"] as? String == "tools/call"
            work.async {
                // Taken back before its turn: not begun, and (as MCP has it) not answered.
                let begin = self.calls.withLock { () -> Bool in
                    if self.gone, acts {
                        return false
                    } // what only asks about the server is still answered
                    if let id, self.takenBack.remove(id) != nil {
                        return false
                    }
                    self.running = id
                    self.asking.again()
                    return true
                }
                guard begin else { return }
                let answer = self.handle(message)
                // Taken back while it ran: it is not answered either.
                let wanted = self.calls.withLock { () -> Bool in
                    defer { self.running = nil
                        self.runningTakenBack = false
                    }
                    return !self.runningTakenBack
                }
                if wanted, let answer {
                    write(answer)
                }
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
            } else {
                takenBack.insert(id)
            }
        }
    }

    /// One message in, its answer out; nil for a notification. What can't be read is answered with
    /// JSON-RPC's error for it, as `roamrunctl mcp` does: a client waiting on it isn't left waiting.
    func handle(_ message: Data) -> Data? {
        func failed(_ id: Any, _ code: Int, _ why: String) -> Data? {
            try? JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": code, "message": why]
            ])
        }
        guard let read = try? JSONSerialization.jsonObject(with: message, options: .fragmentsAllowed)
        else { return failed(
            NSNull(),
            -32700,
            "not JSON"
        ) }
        guard let object = read as? [String: Any] else { return failed(
            NSNull(),
            -32600,
            "one request at a time, as an object"
        ) }
        guard let id = object["id"] else { return nil } // a notification: nothing to answer
        guard let method = object["method"] as? String else { return failed(id, -32600, "no method") }
        let params = object["params"] as? [String: Any] ?? [:]
        func reply(_ result: [String: Any]) -> Data? {
            try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
        }
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            return reply(["protocolVersion": Self.versions.first {
                    $0 == asked
                } ?? Self.versions.max()!,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": [
                    "name": "roamrun",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                ],
                "instructions": Self.instructions])
        case "ping":
            return reply([:])
        case "tools/list":
            return reply(["tools": Self
                    .tools(installs: installsFromPaths ? .paths : claimUpload == nil ? nil : .uploads)])
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
            return failed(id, -32601, "no such method: \(method)")
        }
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    /// The look a tap, swipe, type or paste gives: a number, or one written as text, as a model sometimes gives it.
    static func look(of arguments: [String: Any]) throws -> Int {
        guard let given = arguments["look"],
              !(given is NSNull)
        else { throw Failure(description: "look is missing: give the id the last look answered with") }
        if let id = whole(given), id >= 0 {
            return id
        }
        if let s = given as? String, let id = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)),
           id >= 0
        {
            return id
        }
        throw Failure(description: "look isn't a look's id: give the id the last look answered with, a whole number")
    }

    /// A whole number as JSON wrote it: not true or false (JSONSerialization reads them as 1 and 0), nor 6.0.
    static func whole(_ given: Any?) -> Int? {
        guard let n = given as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(n) else { return nil }
        return n.intValue
    }

    static let olderApp = "the RoamRun app running is older than this roamrun: it doesn't hold what is done to the look given. Quit it and open the RoamRun this command came with"

    /// Over HTTP, an app's file in RoamRun's own folder named in what the app says: "the upload", not a path on this Mac
    /// (whose folders carry the user's name).
    func hidingPaths(_ said: String) -> String {
        guard claimUpload != nil else { return said }
        let folder = NSRegularExpression.escapedPattern(for: looks.standardizedFileURL.path)
        return said.replacingOccurrences(
            of: folder + #"/install-[0-9A-Fa-f-]+/[^\n:"]*?\.(ipa|app)"#,
            with: "the upload",
            options: .regularExpression
        )
    }

    /// Whether an install request's failure says the app surely didn't take its app: refused (or no app), or never
    /// reached it. Only an answer lost after the request went out may hide an install begun.
    static func untaken(_ error: Error) -> Bool {
        switch error {
        case is Failure: true
        case let wire as DeviceControlWire.WireError:
            switch wire {
            case .noApp, .keptOut, .notSent: true
            case .message: false
            }
        default: false
        }
    }

    static let olderForApps = "the RoamRun app running is older than this roamrun: it can't install or launch. Quit it and open the RoamRun this command came with"

    /// Whether the app's answer to "rules" is an older app's: one that doesn't hold an action to the look given.
    static func older(_ said: DeviceControlWire.Response) -> Bool {
        said.ok ? (said.rules ?? 0) < DeviceControlHub.rules : said.error == "unknown request"
    }

    private func call(_ tool: String, _ arguments: [String: Any]) throws -> [[String: Any]] {
        func text(_ s: String) -> [[String: Any]] {
            [["type": "text", "text": s]]
        }
        let profiles = self.profiles
        if tool == "devices" {
            return text(profiles.isEmpty ? "No devices saved in RoamRun." : profiles.map(\.displayName)
                .joined(separator: "\n"))
        }
        let named = (arguments["device"] as? String).map { name in
            profiles.filter {
                $0.displayName.caseInsensitiveCompare(name) == .orderedSame
            }
        } ?? []
        // Two under one name (a list that was mended gives them a default one): neither is guessed at.
        guard named.count < 2 else {
            throw Failure(
                description: "more than one saved device is named that: the user gives each its own name in the RoamRun app"
            )
        }
        guard let device = named.first else {
            throw Failure(description: "no such device; saved: \(profiles.map(\.displayName).joined(separator: ", "))")
        }
        func number(_ key: String) throws -> Double {
            guard let n = arguments[key] as? NSNumber,
                  CFGetTypeID(n) != CFBooleanGetTypeID() else { throw Failure(description: "\(key) is missing") }
            return n.doubleValue
        }
        /// Asks the app; its refusal becomes this tool's failure.
        func send(_ request: DeviceControlWire.Request) throws -> DeviceControlWire.Response {
            let response: DeviceControlWire.Response
            do { response = try ask(request) } catch DeviceControlWire.WireError.noApp {
                throw Failure(
                    description: "the RoamRun app isn't running (or is a build without device control): it holds the connection to the device"
                )
            }
            guard response.ok else { throw Failure(description: response.error ?? "failed") }
            return response
        }
        /// Before what is held to a look: an app that doesn't hold to it (older than this) isn't sent it.
        func heldToLooks() throws {
            let said: DeviceControlWire.Response
            do { said = try send(.init(op: "rules", device: device.id)) } catch let failure as Failure
                where failure.description == "unknown request"
            {
                throw Failure(description: Self.olderApp)
            }
            guard !Self.older(said) else { throw Failure(description: Self.olderApp) }
        }
        switch tool {
        case "look":
            let file = looks.appendingPathComponent("look-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: file) }
            let looked = try send(.init(op: "look", device: device.id, path: file.path))
            // The app's look is no larger than this: points read off the image are the look's own.
            guard let (jpeg, size, _) = Self.scaled(file),
                  let id = looked.look else { throw Failure(description: "couldn't read the look") }
            return [["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]]
                +
                text(
                    "\(Int(size.width)) x \(Int(size.height)), look \(id). Points for tap and swipe are pixels of this image, given with look \(id). Within a minute it serves one tap, swipe, type or paste, and type and paste after that: look again before another tap or swipe."
                )
        case "tap":
            let look = try Self.look(of: arguments)
            let (x, y) = (try number("x"), try number("y"))
            try heldToLooks()
            _ = try send(.init(op: "tap", device: device.id, x: x, y: y, look: look))
            return text("tapped; look to see what it did")
        case "swipe":
            let look = try Self.look(of: arguments)
            let (x1, y1, x2, y2) = (try number("x1"), try number("y1"), try number("x2"), try number("y2"))
            var ms: Int?
            if let given = arguments["milliseconds"], !(given is NSNull) {
                guard let n = Self.whole(given),
                      (50 ... 5000).contains(n)
                else { throw Failure(description: "milliseconds is a whole number, 50...5000") }
                ms = n
            }
            try heldToLooks()
            _ = try send(.init(
                op: "swipe",
                device: device.id,
                x: x1,
                y: y1,
                x2: x2,
                y2: y2,
                milliseconds: ms,
                look: look
            ))
            return text("swiped; look to see what it did")
        case "elements":
            let r = try send(.init(
                op: "elements",
                device: device.id,
                limit: (arguments["limit"] as? NSNumber)?.intValue
            ))
            let captions = r.captions ?? []
            return text(captions
                .joined(separator: "\n") +
                (r.complete == true ? "" : "\n(\(captions.count) elements; the walk was cut short, there may be more)"))
        case "type", "paste", "press":
            guard let value = arguments[tool == "press" ? "button" : "text"] as? String
            else { throw Failure(description: "nothing to send") }
            // Typed at the device's pace: more would outlast a client's patience, and go on being typed after it gave up.
            guard tool != "type" || value.count <= Self.longestTyped else {
                throw Failure(
                    description: "too long to type here: \(Self.longestTyped) characters at most (half a minute or more). paste takes any length"
                )
            }
            // Into whatever has focus: held to the device's latest look. A button isn't.
            let look = tool == "press" ? nil : try Self.look(of: arguments)
            if look != nil {
                try heldToLooks()
            }
            _ = try send(.init(op: tool, device: device.id, text: value, look: look))
            return text(tool == "type" ? DeviceControlWire
                .typed(value) ?? "sent; look to see what it did" : "sent; look to see what it did")
        case "install" where claimUpload != nil:
            guard let upload = arguments["upload"] as? String, let sha256 = arguments["sha256"] as? String else {
                throw Failure(description: "upload and sha256 are missing: as PUT /upload answered them")
            }
            // What the app would refuse it for, asked before the upload is used up: refused then, it stays for another
            // try, as roamrunctl leaves it while the device can't be had.
            do {
                let state = try send(.init(op: "state", device: device.id))
                guard state.allowed != false else { throw Failure(description: DeviceControlHub.switchedOff) }
                // Only one going is a refusal: a latest that failed doesn't hold the next back.
                let latest = try ask(.init(op: "install_status", device: device.id))
                if latest.error == "unknown request" {
                    throw Failure(description: Self.olderForApps)
                }
                if latest.ok, let going = latest.said, going.hasPrefix("installing") {
                    throw Failure(description: going)
                }
            } catch let failure as Failure where failure.description == "unknown request" {
                throw Failure(description: Self.olderForApps)
            }
            guard let claimed = try claimUpload?(upload, sha256) else { throw Failure(description: Self.olderForApps) }
            do {
                let said = try send(.init(op: "install", device: device.id, path: claimed.path)).said
                claimed.settle(true)
                return text(hidingPaths(said ?? "installing"))
            } catch {
                // Not said to have begun (refused, nobody waiting any more, taken back, no answer): the upload stays for
                // another try. Its install folder is removed only where the app surely didn't take it (refused, or not
                // there); one whose answer was lost may be installing from it, and the app removes that one.
                claimed.settle(false)
                if Self.untaken(error) {
                    try? FileManager.default
                        .removeItem(at: URL(fileURLWithPath: claimed.path).deletingLastPathComponent())
                }
                if let refused = error as? Failure {
                    throw refused.description == "unknown request" ? Failure(description: Self.olderForApps)
                        : Failure(description: hidingPaths(refused.description))
                }
                throw error
            }
        case "install_status" where !installsFromPaths && claimUpload == nil:
            throw Failure(description: "no such tool: install_status")
        case "install":
            guard installsFromPaths, let path = arguments["path"] as? String else {
                throw Failure(description: installsFromPaths ? "path is missing" : "no such tool: install")
            }
            // Where a link leads (a build's "latest"), and only an app: an .ipa, or an .app folder that says its bundle
            // identifier — not a folder that only holds one.
            let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath()
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isFolder)
            else { throw Failure(description: "\(path) isn't on this Mac") }
            let app = isFolder.boolValue ? source.pathExtension == "app" &&
                (NSDictionary(contentsOf: source.appendingPathComponent("Info.plist"))?["CFBundleIdentifier"] is String)
                : source.pathExtension == "ipa"
            guard app else {
                throw Failure(
                    description: "\(path) isn't an app: an .ipa, or an .app folder whose Info.plist says its bundle identifier"
                )
            }
            // Copied where the app takes it from, under its own name in a folder of its own: RoamRun's own folder,
            // which only this user can enter.
            let folder = looks.appendingPathComponent("install-\(UUID().uuidString)")
            let copy = folder.appendingPathComponent(source.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                try FileManager.default.copyItem(at: source, to: copy)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw Failure(description: "\(path) couldn't be copied for the app: \(error.localizedDescription)")
            }
            do {
                // The app removes the copy once the install ends, or refuses it.
                return try text(send(.init(op: "install", device: device.id, path: copy.path)).said ?? "installing")
            } catch {
                // Refused by the app, none there, or not sent: nobody else will remove it. A request whose answer was
                // lost may have been taken: the app removes that one, or its next start does.
                if Self.untaken(error) {
                    try? FileManager.default.removeItem(at: folder)
                }
                throw (error as? Failure)?
                    .description == "unknown request" ? Failure(description: Self.olderForApps) : error
            }
        case "install_status":
            do {
                return try text(hidingPaths(send(.init(op: "install_status", device: device.id,
                                                       install: arguments["install"] as? String)).said ?? ""))
            } catch let failure as Failure {
                throw Failure(description: failure.description == "unknown request" ? Self.olderForApps
                    : hidingPaths(failure.description))
            }
        case "launch":
            guard let bundle = arguments["bundle"] as? String, !bundle.isEmpty
            else { throw Failure(description: "bundle is missing: the app's bundle identifier") }
            let said: DeviceControlWire.Response
            do { said = try send(.init(op: "launch", device: device.id, text: bundle)) } catch let failure as Failure
                where failure.description == "unknown request"
            {
                throw Failure(description: Self.olderForApps)
            }
            return text("launched (pid \(said.pid ?? 0)); look to see it")
        default:
            throw Failure(description: "no such tool: \(tool)")
        }
    }

    /// The image at `file` as JPEG with its longer side at most `longSide`; its size, and the original's.
    static func scaled(_ file: URL) -> (jpeg: Data, size: CGSize, original: CGSize)? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(
            source,
            0,
            nil
        ) else { return nil }
        let original = CGSize(width: image.width, height: image.height)
        let scale = min(1, CGFloat(longSide) / max(original.width, original.height))
        let size = CGSize(width: (original.width * scale).rounded(), height: (original.height * scale).rounded())
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        let data = NSMutableData()
        guard let small = context.makeImage(),
              let out = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(out, small, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(out) else { return nil }
        return (data as Data, size, original)
    }

    static let instructions = """
    Operates a real iPhone or iPad through RoamRun. Look, act, look again: each look serves one \
    action, and points are pixels of the image the last look returned, given with the id it answered \
    with. Type and paste give the id of the latest look too, within a minute of it (after a tap with \
    it is fine), and are refused once something else was looked at or done since: they go to whatever \
    has focus. Press goes to whatever is on the screen: look before it too. These press what is really \
    there — don't tap what spends money, posts, sends, deletes or signs in unless the user asked \
    for exactly that. A look shows whatever is on the screen (notifications, messages); don't pass \
    the image on. The device lists this as screen sharing, where its user can see it: until about \
    five seconds after the last look or action, voice input on it may not hear and some apps go \
    silent or stop playing. Asked to keep watching a screen, tell the user that first.
    """

    private static func tool(
        _ name: String,
        _ description: String,
        _ properties: [String: [String: Any]] = [:],
        required: [String] = []
    ) -> [String: Any] {
        var all = properties
        if name != "devices" {
            all["device"] = [
                "type": "string",
                "description": "The device's name in RoamRun (see `devices`)"
            ]
        }
        return ["name": name, "description": description,
                "inputSchema": [
                    "type": "object",
                    "properties": all,
                    "required": (name == "devices" ? [] : ["device"]) + required
                ],
                "annotations": hints(name)]
    }

    /// What a client may take each tool to do, the same in `roamrunctl mcp`. `look` only reads: nothing it does on
    /// the device lasts. `elements` may scroll. Destructive: whatever presses or types into what is
    /// there, or can't be undone from here (`lock`).
    static func hints(_ name: String) -> [String: Bool] {
        ["readOnlyHint": ["devices", "look", "install_status"].contains(name),
         "destructiveHint": ["tap", "swipe", "type", "paste", "press", "install", "launch"].contains(name)]
    }

    // Computed: JSON objects aren't Sendable, and a static stored one would have to be.
    private static var point: [String: Any] {
        [
            "type": "number",
            "description": "Pixels of the image the last look returned"
        ]
    }

    private static var lookGiven: [String: Any] {
        [
            "type": "integer",
            "description": "The id the last look answered with"
        ]
    }

    private static var lookLatest: [String: Any] {
        [
            "type": "integer",
            "description": "The id of the device's latest look, less than a minute old, with nothing done since but by it: no other look, button, elements, action without this id, or action that failed (taps, swipes, types and pastes by it are fine)"
        ]
    }

    enum Installs { case paths, uploads }

    /// With `installs`, `install` (from a path on this Mac, or from an upload) and `install_status`.
    static func tools(installs: Installs?) -> [[String: Any]] {
        let install = installs == .uploads ? tool(
            "install",
            "Start installing an .ipa sent with PUT /upload, built and signed for this device: the upload's id and sha256, as the upload answered them. It ends the app's running processes first. It answers at once; install_status says when the app is in (a megabyte takes a few seconds, a large app minutes), and until then other calls on the device answer that it is installing. An install the app begins uses the upload up.",
            ["upload": ["type": "string"], "sha256": ["type": "string"]],
            required: ["upload", "sha256"]
        ) : tool(
            "install",
            "Start installing an app built and signed for this device: the path, on this Mac, of an .ipa or an .app folder. It ends the app's running processes first. It answers at once; install_status says when the app is in (a megabyte takes a few seconds, a large app minutes), and until then other calls on the device answer that it is installing.",
            ["path": ["type": "string"]],
            required: ["path"]
        )
        return operating + (installs != nil ? [
            install,
            tool(
                "install_status",
                "How the device's install goes: still going (for how long), done (with the app's bundle identifier, for launch), or why it failed. Given the id install answered (install <id>), of that install alone: another begun since is an error.",
                ["install": ["type": "string", "description": "The id install answered with"]]
            ),
        ] : []) + [
            tool("launch", "Launch an app on the device by its bundle identifier (one already running is ended first).",
                 ["bundle": ["type": "string"]], required: ["bundle"]),
        ]
    }

    private static var operating: [[String: Any]] {
        [
            tool("devices", "The devices saved in RoamRun, one name a line."),
            tool(
                "look",
                "The device's screen now, as an image, and the look's id. Do this before every tap or swipe: it serves one, which gives that id."
            ),
            tool("tap", "Tap a point of the last look. Operates the device: whatever is there gets pressed.",
                 ["look": lookGiven, "x": point, "y": point], required: ["look", "x", "y"]),
            tool(
                "swipe",
                "Drag from one point of the last look to another (to scroll, or move something). Operates the device.",
                ["look": lookGiven, "x1": point, "y1": point, "x2": point, "y2": point,
                 "milliseconds": [
                     "type": "integer",
                     "description": "How long the drag takes (50...5000, default 300)"
                 ]],
                required: ["look", "x1", "y1", "x2", "y2"]
            ),
            tool(
                "elements",
                "What accessibility says is on the screen, one caption a line (\"Home, tab, selected\"). No positions: find a caption in a look to tap it. The screen may scroll to what is visited. Nothing on the home screen.",
                ["limit": ["type": "integer", "description": "How many at most (default 40)"]]
            ),
            tool(
                "type",
                "Type text on the device's keyboard, into whatever has its focus. US-keyboard characters only; a newline is Return. Right only while the device's keyboard is an English one — look first: under a Japanese one keys go to its conversion (even a space converts or confirms instead of being typed), the text comes out wrong, and a long one can throw the app out. Look after typing and check what arrived; where the keyboard may be Japanese, paste instead. Typed at the device's pace, at most about 16 characters a second, 500 a call: paste for anything longer.",
                ["look": lookLatest, "text": ["type": "string"]],
                required: ["look", "text"]
            ),
            tool(
                "paste",
                "Put any text into whatever has the keyboard's focus, by the device's pasteboard (which it replaces). iOS then asks \"Allow Paste\" on the device each time: look, and tap it only if the user wants that.",
                ["look": lookLatest, "text": ["type": "string"]],
                required: ["look", "text"]
            ),
            tool("press", "Press a hardware button. `lock` can't be undone from here: the user has to unlock.",
                 ["button": ["type": "string", "enum": ["home", "lock", "volume-up", "volume-down"]]],
                 required: ["button"]),
        ]
    }
}
