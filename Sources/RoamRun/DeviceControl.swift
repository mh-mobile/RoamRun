#if DEVICE_CONTROL
import DeviceControl
import Foundation
import ImageIO
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
        static func failure(_ why: String) -> Response { Response(ok: false, error: why) }
    }

    enum WireError: Error { case noApp, message(String) }

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
        while data.count < 1 << 16 {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
            if buffer[..<n].contains(0x0A) { break }
        }
        return data
    }

    private static func writeLine<T: Encodable>(_ value: T, to fd: Int32) {
        guard var data = try? JSONEncoder().encode(value) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }

    /// The CLI's side: one request, one answer.
    static func ask(_ request: Request, in directory: URL) throws -> Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WireError.message("no socket") }
        defer { close(fd) }
        guard withAddress(socketPath(in: directory), { connect(fd, $0, $1) }) == 0 else { throw WireError.noApp }
        writeLine(request, to: fd)
        guard let response = try? JSONDecoder().decode(Response.self, from: readLine(fd)) else {
            throw WireError.message("the app didn't answer")
        }
        return response
    }

    /// The app's side: answers every request with `handler` until stopped. Requests are served
    /// side by side; a device's own calls queue in its session.
    final class Listener: @unchecked Sendable {
        private let fd: Int32
        private let path: String

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
            guard DeviceControlWire.withAddress(path, { bind(fd, $0, $1) }) == 0, listen(fd, 8) == 0 else { close(fd); return nil }
            chmod(path, 0o600)
            self.fd = fd
            self.path = path
            Thread.detachNewThread { [fd] in
                while true {
                    let client = accept(fd, nil, nil)
                    guard client >= 0 else { return }   // closed by stop()
                    DispatchQueue.global(qos: .userInitiated).async {
                        defer { close(client) }
                        let request = try? JSONDecoder().decode(Request.self, from: DeviceControlWire.readLine(client))
                        DeviceControlWire.writeLine(request.map(handler) ?? .failure("unreadable request"), to: client)
                    }
                }
            }
        }

        func stop() {
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
    }

    private struct Held {
        var target: Target
        var session: DeviceSession
        /// The last look's size: what a tap's pixels are of.
        var looked: (width: Int, height: Int)?
    }

    private let directory: URL
    private let lock = NSLock()
    private var held: [UUID: Held] = [:]
    private var listener: DeviceControlWire.Listener?
    private var timer: DispatchSourceTimer?
    var onLog: (@Sendable (String, UUID) -> Void)?

    init(directory: URL) { self.directory = directory }

    /// The saved devices as they are now. One whose address or port changed gets a new session.
    func update(_ targets: [Target]) {
        let paired = targets.filter { FileManager.default.fileExists(atPath: DeviceControlWire.pairingFile(udid: $0.udid, in: directory).path) }
        var gone: [DeviceSession] = []
        lock.withLock {
            for (id, h) in held where !paired.contains(h.target) {
                gone.append(h.session)
                held[id] = nil
            }
            for t in paired where held[t.id] == nil {
                let session = DeviceSession(ip: t.ip, port: t.port,
                                            pairingFile: DeviceControlWire.pairingFile(udid: t.udid, in: directory).path, udid: t.udid)
                session.onEvent = { [weak self] event in self?.onLog?("device control: \(event)", t.id) }
                held[t.id] = Held(target: t, session: session)
            }
        }
        gone.forEach { $0.close() }
        keepOpen()
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
        sessions.forEach { $0.close() }
    }

    private func keepOpen() {
        let closed = lock.withLock { held.values.map(\.session).filter { !$0.isOpen } }
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

    private static let lookFirst = "look first: a point is given in the pixels of a look, and each look serves one action"

    private func answer(_ request: DeviceControlWire.Request) -> DeviceControlWire.Response {
        guard let h = lock.withLock({ held[request.device] }) else {
            return .failure("device control isn't set up for this device")
        }
        do {
            switch request.op {
            case "elements":
                _ = spendLook(of: request.device)   // the walk can scroll the screen
                let found = try h.session.elements(limit: request.limit ?? 40)
                return .init(ok: true, captions: found.captions, complete: found.complete)
            case "swipe":
                guard let size = spendLook(of: request.device) else { return .failure(Self.lookFirst) }
                guard let from = Self.fraction(x: request.x, y: request.y, of: size),
                      let to = Self.fraction(x: request.x2, y: request.y2, of: size) else {
                    return .failure("both points must be inside the last look (\(size.width) x \(size.height))")
                }
                try h.session.swipe(from: from, to: to, milliseconds: request.milliseconds ?? 300)
                return .init(ok: true)
            case "type", "paste", "press":
                _ = spendLook(of: request.device)
                guard let text = request.text else { return .failure("nothing to send") }
                switch request.op {
                case "type": try h.session.type(text)
                case "paste": try h.session.paste(text)
                default: try h.session.press(text)
                }
                return .init(ok: true)
            case "look":
                guard let path = request.path else { return .failure("no file") }
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
