#if DEVICE_CONTROL
import DeviceControl
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// How `roamrun look`, `tap` and the rest ask the app, which holds the connections: one JSON
/// line each way over a Unix socket only this user can open.
enum DeviceControlWire {
    struct Request: Codable, Equatable {
        var op: String
        var device: UUID
        var path: String?
        var x: Double?
        var y: Double?
        var x2: Double?
        var y2: Double?
        var milliseconds: Int?
        var text: String?
        var limit: Int?
    }

    struct Response: Codable, Equatable {
        var ok: Bool
        var error: String?
        var width: Int?
        var height: Int?
        var captions: [String]?
        var complete: Bool?
        /// For "state": whether the connection to the device stands.
        var open: Bool?
        /// For "state": the device no longer knows the pairing (it was removed there).
        var refused: Bool?
        static func failure(_ why: String) -> Response { Response(ok: false, error: why) }
    }

    enum WireError: Error, CustomStringConvertible {
        case noApp, message(String)
        var description: String {
            switch self {
            case .noApp: "the RoamRun app isn't running"
            case .message(let m): m
            }
        }
    }

    /// The longest a line may be: a long paste, or many elements.
    static let longestLine = 1 << 20
    /// How long the app waits for a request once a client has connected.
    static let requestWait: TimeInterval = 10
    /// How long the CLI waits for the answer: longer than any call takes with its retries.
    static let answerWait: TimeInterval = 150

    /// A write to a socket whose other end has gone must fail, not end the process with SIGPIPE.
    /// Set before the socket has a peer (on the listening one, whose accepted ones inherit it):
    /// on one whose peer has already left, the option can no longer be set.
    private static func noSIGPIPE(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// The other end saying nothing is given up on after `wait`.
    private static func readWait(_ fd: Int32, _ wait: TimeInterval) {
        var limit = timeval(tv_sec: Int(wait), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    /// In a folder of its own that only this user can enter: what keeps others out, whatever
    /// mode the socket itself is made with.
    static func socketFolder(in directory: URL) -> URL { directory.appendingPathComponent("control", isDirectory: true) }
    static func socketPath(in directory: URL) -> String { socketFolder(in: directory).appendingPathComponent("sock").path }

    /// The pairing of our own with a device, where there is one: what makes it controllable.
    static func pairingFile(udid: String, in directory: URL) -> URL {
        directory.appendingPathComponent("device-pairing-\(udid).plist")
    }

    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        // The kernel's limit; a path that doesn't fit can't be bound or reached.
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    private static func withAddress<R>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R? {
        guard var address = address(path) else { return nil }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// Up to the first newline, or the end.
    private static func readLine(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < longestLine {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
            if buffer[..<n].contains(0x0A) { break }
        }
        return data
    }

    /// False when it couldn't be said (NaN has no JSON) or the other end has gone.
    @discardableResult
    private static func writeLine<T: Encodable>(_ value: T, to fd: Int32) -> Bool {
        guard var data = try? JSONEncoder().encode(value) else { return false }
        data.append(0x0A)
        return data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let n = write(fd, bytes.baseAddress! + sent, bytes.count - sent)
                guard n > 0 else { return false }
                sent += n
            }
            return true
        }
    }

    /// The CLI's side: one request, one answer.
    static func ask(_ request: Request, in directory: URL) throws -> Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WireError.message("no socket") }
        defer { close(fd) }
        noSIGPIPE(fd)
        readWait(fd, answerWait)
        guard withAddress(socketPath(in: directory), { connect(fd, $0, $1) }) == 0 else { throw WireError.noApp }
        guard writeLine(request, to: fd) else { throw WireError.message("couldn't send the request (a number that isn't one?)") }
        let line = readLine(fd)
        guard let response = try? JSONDecoder().decode(Response.self, from: line) else {
            throw WireError.message(line.isEmpty ? "the app didn't answer" : "the app's answer couldn't be read")
        }
        return response
    }

    /// The app's side: answers every request with `handler` until stopped. Requests are served
    /// side by side; a device's own calls queue in its session.
    final class Listener: @unchecked Sendable {
        private let fd: Int32
        private let path: String
        private let stopped = NSLock()
        private var isStopped = false

        init?(directory: URL, handler: @escaping @Sendable (Request) -> Response) {
            let path = DeviceControlWire.socketPath(in: directory)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            // Not umask around bind(): that is the whole process's, and another thread's file
            // made meanwhile would get it too.
            let folder = DeviceControlWire.socketFolder(in: directory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard chmod(folder.path, 0o700) == 0 else { close(fd); return nil }
            unlink(path)   // a previous run's; only one app runs
            DeviceControlWire.noSIGPIPE(fd)
            guard DeviceControlWire.withAddress(path, { bind(fd, $0, $1) }) == 0, listen(fd, 64) == 0 else { close(fd); return nil }
            chmod(path, 0o600)
            self.fd = fd
            self.path = path
            Thread.detachNewThread { [weak self, fd] in
                while true {
                    let client = accept(fd, nil, nil)
                    guard client >= 0 else {
                        // stop() closed it; anything else (a client that gave up) is one accept lost.
                        if self?.stopped.withLock({ self?.isStopped }) ?? true { return }
                        usleep(50_000)
                        continue
                    }
                    DispatchQueue.global(qos: .userInitiated).async {
                        defer { close(client) }
                        DeviceControlWire.readWait(client, DeviceControlWire.requestWait)
                        let line = DeviceControlWire.readLine(client)
                        guard !line.isEmpty else { return }   // said nothing: nobody to answer
                        let request = try? JSONDecoder().decode(Request.self, from: line)
                        DeviceControlWire.writeLine(request.map(handler) ?? .failure("unreadable request"), to: client)
                    }
                }
            }
        }

        func stop() {
            stopped.withLock { isStopped = true }
            close(fd)
            unlink(path)
        }
    }
}

/// The devices the app controls: a connection kept open to each that has a pairing of our own,
/// so it is there when the device leaves Wi‑Fi (away from it none can be opened).
final class DeviceControlHub: @unchecked Sendable {
    struct Target: Equatable {
        var id: UUID
        var name: String
        var ip: String
        var port: UInt16
        var udid: String

        /// The same device at the same place: what a connection is to.
        func reaches(_ other: Target) -> Bool { ip == other.ip && port == other.port && udid == other.udid }
    }

    private struct Held {
        var target: Target
        var session: DeviceSession
        /// The last look's size: what a tap's pixels are of.
        var looked: (width: Int, height: Int)?
        /// When the last input ended: a look right after it waits for the screen to settle.
        var acted: Date?
    }

    private let directory: URL
    private let lock = NSLock()
    private var held: [UUID: Held] = [:]
    private var listener: DeviceControlWire.Listener?
    private var timer: DispatchSourceTimer?
    /// The last update's, for when a pairing is made or removed in between.
    private var targets: [Target] = []
    private var pairing: DevicePairing?
    private var pairingUnderWay = false
    private var pairingCancelled = false
    var onLog: (@Sendable (String, UUID) -> Void)?

    init(directory: URL) { self.directory = directory }

    /// The saved devices as they are now. One whose address or port changed gets a new session.
    func update(_ targets: [Target]) {
        var gone: [DeviceSession] = []
        lock.withLock {
            self.targets = targets
            let saved = Dictionary(targets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for (id, h) in held {
                // A device renamed keeps its connection (away from Wi‑Fi no new one could be made);
                // one moved to another address, removed or unpaired doesn't.
                if let t = saved[id], t.reaches(h.target), hasPairing(t) {
                    held[id]?.target = t
                } else {
                    gone.append(h.session)
                    held[id] = nil
                }
            }
            for t in targets where held[t.id] == nil {
                if let session = session(for: t) { held[t.id] = Held(target: t, session: session) }
            }
        }
        Self.closing(gone)
        keepOpen()
    }

    private func hasPairing(_ t: Target) -> Bool {
        FileManager.default.fileExists(atPath: DeviceControlWire.pairingFile(udid: t.udid, in: directory).path)
    }

    /// The session held for a device, if any.
    func session(of id: UUID) -> DeviceSession? { lock.withLock { held[id]?.session } }

    /// Closing waits for a call that runs on the session, which can take long: never on the
    /// caller's thread (the main one, when the list is saved).
    private static func closing(_ sessions: [DeviceSession]) {
        guard !sessions.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { sessions.forEach { $0.close() } }
    }

    /// A pairing in the making, as it is shown.
    enum PairingStep: Equatable, Sendable {
        /// Listening under this name: the device's user picks it in Settings.
        case waiting(String)
        /// The six digits to enter on the device.
        case code(String)
        case checking
        case done
        case failed(String)
    }

    /// Whether a pairing of our own is saved for the device, and whether its connection stands.
    func state(of id: UUID, udid: String) -> (paired: Bool, open: Bool, refused: Bool) {
        let paired = FileManager.default.fileExists(atPath: DeviceControlWire.pairingFile(udid: udid, in: directory).path)
        let session = session(of: id)
        return (paired, paired && session?.isOpen == true, paired && session?.isRefused == true)
    }

    /// Lets the device pair with this Mac (iOS 27 and later, on the same network), one at a time.
    /// The new pairing replaces the saved one only once it opened a connection of its own.
    func pair(_ target: Target, as name: String, step: @escaping @Sendable (PairingStep) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let file = DeviceControlWire.pairingFile(udid: target.udid, in: directory)
            let fresh = file.appendingPathExtension("new")
            // Taken before anything is advertised: two of these would name themselves alike.
            let free = lock.withLock { () -> Bool in
                guard !pairingUnderWay else { return false }
                pairingUnderWay = true
                pairingCancelled = false
                return true
            }
            guard free else { return step(.failed("Another pairing is under way.")) }
            defer {
                try? FileManager.default.removeItem(at: fresh)
                lock.withLock { pairing = nil; pairingUnderWay = false }
            }
            do {
                let listening = try DevicePairing(name: name, host: Self.hostID(in: directory))
                // A cancel that came before there was anything to cancel still counts.
                if lock.withLock({ () -> Bool in pairing = listening; return pairingCancelled }) { listening.cancel() }
                step(.waiting(listening.name))
                let paired = try listening.accept(to: fresh.path) { step(.code($0)) }
                step(.checking)
                onLog?("device control: \(paired.name) (\(paired.model), \(paired.udid)) paired", target.id)
                // From the side that will use it, at the address it will use: what tells this
                // device from another that picked this Mac.
                let check = DeviceSession(ip: target.ip, port: target.port, pairingFile: fresh.path)
                defer { check.close() }
                do { try check.connect() } catch {
                    throw DeviceSession.Failure.message("\(paired.name) paired, but that pairing opens no connection to \(target.name) (\(error)). Nothing was saved. If it was another device, its pairing with this Mac can be removed there, in Settings.")
                }
                try Self.adopt(fresh, as: file)
                reopen(target.id)
                step(.done)
            } catch {
                step(.failed("\(error)"))
            }
        }
    }

    /// What a device knows this Mac by: made once and kept with the pairings, so a Mac renamed
    /// stays the one it was, and two of one name stay two.
    static func hostID(in directory: URL) -> String {
        let file = directory.appendingPathComponent("device-control-host")
        if let saved = try? String(contentsOf: file, encoding: .utf8), UUID(uuidString: saved) != nil { return saved }
        let fresh = UUID().uuidString
        try? Data(fresh.utf8).write(to: file, options: .atomic)
        return fresh
    }

    /// Puts a new pairing in the saved one's place. The one it replaces is kept beside it
    /// (".previous"), to put back by hand if the device still takes it.
    static func adopt(_ fresh: URL, as file: URL) throws {
        if FileManager.default.fileExists(atPath: file.path) {
            let previous = file.appendingPathExtension("previous")
            try? FileManager.default.removeItem(at: previous)
            try FileManager.default.moveItem(at: file, to: previous)
        }
        try FileManager.default.moveItem(at: fresh, to: file)
    }

    func cancelPairing() {
        lock.withLock { () -> DevicePairing? in pairingCancelled = true; return pairing }?.cancel()
    }

    /// Forgets this Mac's pairing with the device (the device's record of it stays, in its Settings).
    func unpair(_ target: Target) {
        let file = DeviceControlWire.pairingFile(udid: target.udid, in: directory)
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: file.appendingPathExtension("previous"))
        reopen(target.id)
        onLog?("device control: pairing removed", target.id)
    }

    /// The device's session made anew from what is saved now. The new one is in place before
    /// the old one is closed: in between, the device would answer as not set up.
    private func reopen(_ id: UUID) {
        let old = lock.withLock { () -> DeviceSession? in
            let old = held.removeValue(forKey: id)?.session
            if let t = targets.first(where: { $0.id == id }), let session = session(for: t) { held[id] = Held(target: t, session: session) }
            return old
        }
        Self.closing(old.map { [$0] } ?? [])
        keepOpen()
    }

    /// A session for the device, if a pairing of our own is saved for it.
    private func session(for t: Target) -> DeviceSession? {
        guard hasPairing(t) else { return nil }
        let file = DeviceControlWire.pairingFile(udid: t.udid, in: directory)
        let session = DeviceSession(ip: t.ip, port: t.port, pairingFile: file.path, udid: t.udid)
        session.onEvent = { [weak self] event in self?.onLog?("device control: \(event)", t.id) }
        return session
    }

    func start() {
        listener = DeviceControlWire.Listener(directory: directory) { [weak self] in self?.answer($0) ?? .failure("stopping") }
        // ponytail: a look every 30 s for a connection to open, none at one already open — a dead
        // one is found by the next call (and recovered as Recovery says). A heartbeat, if that is too late.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.keepOpen() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        listener?.stop()
        let sessions = lock.withLock { () -> [DeviceSession] in
            defer { held = [:] }
            return held.values.map(\.session)
        }
        // Each is told to end its stream, but quitting doesn't wait on a device that no longer answers.
        let group = DispatchGroup()
        for session in sessions { DispatchQueue.global(qos: .userInitiated).async(group: group) { session.close() } }
        _ = group.wait(timeout: .now() + 2)
    }

    private func keepOpen() {
        let closed = lock.withLock { held.values.map(\.session) }.filter { !$0.isOpen }
        for session in closed {
            DispatchQueue.global(qos: .utility).async { try? session.connect() }
        }
    }

    /// A point given in a look's pixels, as fractions of the screen; nil when outside it.
    static func fraction(x: Double?, y: Double?, of size: (width: Int, height: Int)) -> (x: Double, y: Double)? {
        guard let x, let y, (0..<Double(size.width)).contains(x), (0..<Double(size.height)).contains(y) else { return nil }
        return (x / Double(size.width), y / Double(size.height))
    }

    /// The last look, taken away: whatever follows may change the screen, and the next point
    /// has to come from a look at what it became.
    private func spendLook(of device: UUID) -> (width: Int, height: Int)? {
        lock.withLock {
            defer { held[device]?.looked = nil }
            return held[device]?.looked
        }
    }

    // ponytail: a fixed wait, enough for a transition or a scroll coming to rest. Comparing
    // frames until they stop changing, if it proves short (a playing video never stops).
    static let settle: TimeInterval = 1

    /// How long a look still has to wait after the last input.
    static func settleWait(acted: Date?, now: Date = Date()) -> TimeInterval {
        guard let acted else { return 0 }
        return min(settle, max(0, settle - now.timeIntervalSince(acted)))
    }

    /// What a `type` sent (debug level), never the text itself: tells a key the device dropped
    /// from one that wasn't sent.
    private static let inputLog = Logger(subsystem: AppID.bundle, category: "input")

    /// How many elements a walk is asked for: whatever number a caller sends, one the walk can do.
    static func elementLimit(_ asked: Int?) -> Int { min(max(asked ?? 40, 1), 1000) }

    /// A swipe's duration, or nil for one the device isn't asked for (the library takes 50...5000 ms).
    static func swipeDuration(_ asked: Int?) -> Int? {
        guard let asked else { return 300 }
        return (50...5000).contains(asked) ? asked : nil
    }

    private static let lookFirst = "look first: a point is given in the pixels of a look, and each look serves one action"

    private func answer(_ request: DeviceControlWire.Request) -> DeviceControlWire.Response {
        guard let h = lock.withLock({ held[request.device] }) else {
            return .failure("device control isn't set up for this device: the user sets it up in the RoamRun app, on the device's page")
        }
        // Failed or not: an input may have reached the device before the failure showed.
        defer { if !["state", "look"].contains(request.op) { lock.withLock { held[request.device]?.acted = Date() } } }
        do {
            switch request.op {
            case "state":
                return .init(ok: true, open: h.session.isOpen, refused: h.session.isRefused)
            case "elements":
                _ = spendLook(of: request.device)   // the walk can scroll the screen
                let found = try h.session.elements(limit: Self.elementLimit(request.limit))
                return .init(ok: true, captions: found.captions, complete: found.complete)
            case "swipe":
                guard let size = spendLook(of: request.device) else { return .failure(Self.lookFirst) }
                guard let from = Self.fraction(x: request.x, y: request.y, of: size),
                      let to = Self.fraction(x: request.x2, y: request.y2, of: size) else {
                    return .failure("both points must be inside the last look (\(size.width) x \(size.height))")
                }
                guard let duration = Self.swipeDuration(request.milliseconds) else {
                    return .failure("a swipe takes 50...5000 ms")
                }
                try h.session.swipe(from: from, to: to, milliseconds: duration)
                return .init(ok: true)
            case "type", "paste", "press":
                _ = spendLook(of: request.device)
                guard let text = request.text else { return .failure("nothing to send") }
                switch request.op {
                case "type":
                    let started = Date()
                    try h.session.type(text)
                    Self.inputLog.debug("\(h.target.name, privacy: .public): typed \(text.count) keys, \(text.filter { $0 == " " }.count) spaces, in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                case "paste": try h.session.paste(text)
                default: try h.session.press(text)
                }
                return .init(ok: true)
            case "look":
                guard let path = request.path else { return .failure("no file") }
                Thread.sleep(forTimeInterval: Self.settleWait(acted: h.acted))
                let image = try h.session.look()
                guard let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    return .failure("can't write \(path)")
                }
                CGImageDestinationAddImage(out, image, nil)
                guard CGImageDestinationFinalize(out) else { return .failure("can't write \(path)") }
                lock.withLock { held[request.device]?.looked = (image.width, image.height) }
                return .init(ok: true, width: image.width, height: image.height)
            case "tap":
                // In the pixels of what was last looked at: there is no tapping a screen not seen.
                guard let size = spendLook(of: request.device) else { return .failure(Self.lookFirst) }
                guard let point = Self.fraction(x: request.x, y: request.y, of: size) else {
                    return .failure("the point must be inside the last look (\(size.width) x \(size.height))")
                }
                try h.session.tap(x: point.x, y: point.y)
                return .init(ok: true)
            default:
                return .failure("unknown request")
            }
        } catch {
            return .failure("\(error)")
        }
    }
}
#endif
