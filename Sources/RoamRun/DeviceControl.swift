import CryptoKit
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
        /// For "import": what the device is saved as here.
        var name: String?
        static func failure(_ why: String) -> Response { Response(ok: false, error: why) }
    }

    enum WireError: Error, CustomStringConvertible {
        case noApp, message(String)
        /// The app may well be running: this process isn't let through to it.
        case keptOut(String)
        var description: String {
            switch self {
            case .noApp: "the RoamRun app isn't running"
            case .message(let m): m
            case .keptOut(let why):
                "this process isn't allowed to reach the RoamRun app (\(why)): it runs in a sandbox that keeps it from the app's socket. Run the command outside the sandbox, or use the MCP tools (`roamrun mcp`, started by the agent itself)"
            }
        }
    }

    /// The longest a line may be: a long paste, or many elements.
    static let longestLine = 1 << 20
    /// How long the app waits for a request once a client has connected.
    static let requestWait: TimeInterval = 10
    /// How long the CLI waits for the answer: longer than any call may take (the longest text
    /// typed is given some seven minutes by the library).
    static let answerWait: TimeInterval = 480

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
        directory.appendingPathComponent("device-pairing-\(udid).sealed")
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
        guard withAddress(socketPath(in: directory), { connect(fd, $0, $1) }) == 0 else {
            // Not there or nobody listening: no app. Refused by the system: a sandbox around this process.
            let why = errno
            throw why == EPERM || why == EACCES ? WireError.keptOut(String(cString: strerror(why))) : WireError.noApp
        }
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
            // Looks a CLI was to move to their place and didn't (it was interrupted): screens aren't left lying.
            for left in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where left.lastPathComponent.hasPrefix("look-") { try? FileManager.default.removeItem(at: left) }
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

/// A pairing made for another Mac, with the device it is for: what `roamrun pairing create`
/// writes and `pairing import` takes. The file is the key: whoever has it and reaches the device
/// can see and operate it.
struct SharedPairing: Codable, Equatable {
    var roamrunPairing = 1
    var device: DeviceProfile
    /// The pairing itself, a property list's text.
    var pairing: String

    static func read(_ data: Data) -> SharedPairing? {
        guard let read = try? JSONDecoder().decode(SharedPairing.self, from: data), read.roamrunPairing == 1,
              !read.pairing.isEmpty, read.device.udid?.isEmpty == false else { return nil }
        return read
    }
}

/// What the hub does with a device: a `DeviceSession`, or a stand-in for one in tests.
protocol ControlledDevice: AnyObject, Sendable {
    var isOpen: Bool { get }
    var isRefused: Bool { get }
    func connect() throws
    func close()
    func look() throws -> CGImage
    func elements(limit: Int) throws -> (captions: [String], complete: Bool)
    func tap(x: Double, y: Double) throws
    func swipe(from: (x: Double, y: Double), to: (x: Double, y: Double), milliseconds: Int) throws
    func type(_ text: String) throws
    func paste(_ text: String) throws
    func press(_ button: String) throws
}

extension DeviceSession: ControlledDevice {}

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
        func reaches(_ other: Target) -> Bool {
            ip == other.ip && port == other.port && udid.caseInsensitiveCompare(other.udid) == .orderedSame   // a UDID is one, however it is spelled
        }
    }

    /// One device as it is held: its session, and what belongs to that session alone. A session
    /// replaced (another port, a new pairing) gets a new one of these, so that what was seen or
    /// done through the old session never counts for the new.
    private final class Held: @unchecked Sendable {
        /// Under the hub's lock (a rename changes it while the session stays).
        var target: Target
        let session: any ControlledDevice
        /// The last look's size: what a tap's pixels are of. (This and `acted` under the device's gate.)
        var looked: (width: Int, height: Int)?
        /// When the last input ended: a look right after it waits for the screen to settle.
        var acted: Date?
        /// Opening it in the background: one attempt at a time, and further apart while they fail.
        /// (These three under the hub's lock.)
        var connecting = false
        var failures = 0
        var nextTry = Date.distantPast

        init(target: Target, session: any ControlledDevice) {
            self.target = target
            self.session = session
        }
    }

    typealias Opener = @Sendable (_ target: Target, _ pairing: @escaping @Sendable () throws -> Data, _ said: @escaping @Sendable (String) -> Void) -> any ControlledDevice
    /// The key the saved pairings are sealed with. `make`: one is made if there is none yet
    /// (when a device is set up; never to read a pairing, which a new key couldn't open).
    typealias Key = @Sendable (_ make: Bool) throws -> SymmetricKey

    private let directory: URL
    private let lock = NSLock()
    private var held: [UUID: Held] = [:]
    /// One per device, for as long as the hub lives — not per session: held for the whole of a
    /// command, from checking its look to what it leaves behind, so that one look serves one
    /// action and one command at a time reaches the device, also across a change of session.
    private var gates: [UUID: NSLock] = [:]
    private var listener: DeviceControlWire.Listener?
    private var timer: DispatchSourceTimer?
    /// The last update's, for when a pairing is made or removed in between.
    private var targets: [Target] = []
    private var pairing: DevicePairing?
    private var pairingUnderWay = false
    private var pairingCancelled = false
    var onLog: (@Sendable (String, UUID) -> Void)?
    /// A background attempt to open a device's connection failed, and why.
    var onUnreached: (@Sendable (UUID, String) -> Void)?
    /// A pairing made on another Mac is brought in (the file's path): the app's to do, which
    /// knows the saved devices.
    var onImport: (@Sendable (String, String?) -> DeviceControlWire.Response)?

    private let open: Opener
    private let key: Key

    /// `open` makes the session for a device; tests give stand-ins, and a key of their own.
    init(directory: URL, key: @escaping Key, open: @escaping Opener = { target, pairing, said in
        let session = DeviceSession(ip: target.ip, port: target.port, pairing: pairing, udid: target.udid)
        session.onEvent = said
        return session
    }) {
        self.directory = directory
        self.key = key
        self.open = open
    }

    /// The saved devices as they are now. One whose address or port changed gets a new session.
    func update(_ targets: [Target]) {
        var gone: [any ControlledDevice] = []
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
    func session(of id: UUID) -> (any ControlledDevice)? { lock.withLock { held[id]?.session } }

    /// Closing waits for a call that runs on the session, which can take long: never on the
    /// caller's thread (the main one, when the list is saved).
    private static func closing(_ sessions: [any ControlledDevice]) {
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
        /// Saved under this UDID (the device's own, when none was known). `unreached`: no
        /// connection could be made with it just now, and why.
        case done(udid: String, unreached: String?)
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
    /// The device a pairing is asked for. Its UDID may not be known yet: one added on this
    /// Mac's own Wi‑Fi has never been bridged, and the pairing itself is what tells it.
    struct PairingRequest: Sendable {
        var id: UUID
        var name: String
        var ip: String
        var port: UInt16
        var udid: String?
        /// The other saved devices' UDIDs and names: a device already saved isn't saved twice.
        var others: [(udid: String, name: String)] = []
    }

    /// What a pairing that came in is to this request.
    enum PairingVerdict: Equatable {
        /// The device asked for, by its UDID.
        case expected
        /// Not known to be it: kept only if the pairing opens a connection at the request's address.
        case toProve
        /// Another saved device (its name).
        case savedAs(String)
        /// It gave no UDID, and none is known to name the pairing by.
        case nameless
    }

    static func verdict(expected: String?, paired: String, others: [(udid: String, name: String)]) -> PairingVerdict {
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        if let expected, same(expected, paired) { return .expected }
        if let other = others.first(where: { same($0.udid, paired) }) { return .savedAs(other.name) }
        if expected == nil, paired.isEmpty { return .nameless }
        return .toProve
    }

    func pair(_ device: PairingRequest, as name: String, step: @escaping @Sendable (PairingStep) -> Void) {
        lock.withLock { if !pairingUnderWay { pairingCancelled = false } }   // here, not in the block: a cancel may come before it runs
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // Taken before anything is advertised: two of these would name themselves alike.
            let free = lock.withLock { () -> Bool in
                guard !pairingUnderWay else { return false }
                pairingUnderWay = true
                return true
            }
            guard free else { return step(.failed("Another pairing is under way.")) }
            defer { lock.withLock { pairing = nil; pairingUnderWay = false } }
            do {
                // Before the device is asked anything: once it pairs it knows no older pairing of
                // ours, and a Keychain that then refuses would leave it with none this Mac holds.
                // And that key is the one it is sealed with: asked for again after the pairing,
                // the Keychain could refuse then.
                let sealing = try key(true)
                let listening = try DevicePairing(name: name, host: Self.hostID(in: directory))
                // A cancel that came before there was anything to cancel still counts.
                if lock.withLock({ () -> Bool in pairing = listening; return pairingCancelled }) { listening.cancel() }
                step(.waiting(listening.name))
                let paired = try listening.accept { step(.code($0)) }
                step(.checking)
                onLog?("device control: \(paired.name) (\(paired.model), \(paired.udid)) paired", device.id)
                // The device now knows this pairing and no older one of ours. When it is the one
                // asked for, the pairing is kept whether or not a connection can be made right now
                // (its VPN off, its port moved): dropping it would leave the device with no pairing
                // this Mac holds. One not known to be it is proved by connecting at the address it
                // will be used at — proof against a device that is honest about itself, which is
                // what the bridge trusts that address with too.
                switch Self.verdict(expected: device.udid, paired: paired.udid, others: device.others) {
                case .expected: break
                case .savedAs(let other):
                    throw DeviceSession.Failure.message("\(paired.name) paired, which is saved here as “\(other)”, not “\(device.name)”. Nothing was saved, and its earlier pairing with this Mac no longer works: set device control up again on “\(other)”.")
                case .nameless:
                    throw DeviceSession.Failure.message("\(paired.name) paired without saying which device it is. Nothing was saved.")
                case .toProve:
                    let check = DeviceSession(ip: device.ip, port: device.port, pairing: { paired.pairing })
                    defer { check.close() }
                    do { try check.connect() } catch {
                        let port = "\(error)".hasPrefix("RemotePairing port: Connection refused")
                            ? " The device answered but not on port \(device.port): Technical details › Find RemotePairing Port, then set up again."
                            : " Is its VPN on?"
                        throw DeviceSession.Failure.message("\(paired.name) paired, but that pairing opens no connection to “\(device.name)” at \(device.ip) (\(error)).\(port) Nothing was saved; if it was another device, its pairing with this Mac can be removed there, in Settings.")
                    }
                }
                // Named by the UDID the device is saved under, as it is spelled there; or by its own.
                let udid = device.udid ?? paired.udid
                let target = Target(id: device.id, name: device.name, ip: device.ip, port: device.port, udid: udid)
                try Self.save(Self.seal(paired.pairing, with: sealing), as: DeviceControlWire.pairingFile(udid: udid, in: directory))
                // Held from now on, also when the list of saved devices doesn't have its UDID yet.
                lock.withLock { if !targets.contains(where: { $0.id == target.id }) { targets.append(target) } }
                reopen(target.id)
                // Said as it is: saved, and whether it also connects right now.
                var unreached: String?
                do { try session(of: target.id)?.connect() } catch { unreached = "\(error)" }
                step(.done(udid: udid, unreached: unreached))
            } catch {
                step(.failed("\(error)"))
            }
        }
    }

    /// Takes a pairing made elsewhere for this device: kept only if it opens a connection, and
    /// sealed with this Mac's key, which is had first.
    func adoptPairing(_ pairing: Data, for target: Target) throws {
        let sealing = try key(true)
        let check = open(target, { pairing }) { _ in }
        defer { check.close() }
        do { try check.connect() } catch {
            throw DeviceSession.Failure.message("this pairing opens no connection to “\(target.name)” at \(target.ip) (\(error)). Nothing was saved.")
        }
        try Self.save(Self.seal(pairing, with: sealing), as: DeviceControlWire.pairingFile(udid: target.udid, in: directory))
        lock.withLock { targets.removeAll { $0.id == target.id }; targets.append(target) }
        reopen(target.id)
        // Connected when this returns, as it just was: asked how it stands, it says so.
        try? session(of: target.id)?.connect()
        onLog?("device control: a pairing made on another Mac was taken in", target.id)
    }

    /// Removes the pairing saved under `udid`, held or not: one made for a device that turned
    /// out not to be saved under it.
    func forgetPairing(udid: String, of id: UUID) {
        Self.remove(DeviceControlWire.pairingFile(udid: udid, in: directory))
        lock.withLock { targets.removeAll { $0.id == id && $0.udid.caseInsensitiveCompare(udid) == .orderedSame } }
        reopen(id)
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

    /// A pairing holds this Mac's private key: it is kept sealed, with a key only RoamRun reads
    /// from the Keychain, so a copy of the file opens nothing.
    static func seal(_ pairing: Data, with key: SymmetricKey) throws -> Data {
        guard let sealed = try AES.GCM.seal(pairing, using: key).combined else {
            throw DeviceSession.Failure.message("can't seal the pairing")
        }
        return sealed
    }

    static func unseal(_ sealed: Data, with key: SymmetricKey) throws -> Data {
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key) } catch {
            throw DeviceSession.Failure.message("the saved pairing can't be read with this Mac's key: set device control up again")
        }
    }

    /// Puts a new pairing in the saved one's place: written beside it (its owner's only), then
    /// moved, so a write that fails leaves what was there. The one it replaces is of no use any
    /// more (the device knows this Mac by one identity, and now by the new key).
    static func save(_ sealed: Data, as file: URL) throws {
        let beside = file.appendingPathExtension("writing")
        try? FileManager.default.removeItem(at: beside)
        guard FileManager.default.createFile(atPath: beside.path, contents: sealed, attributes: [.posixPermissions: 0o600]),
              rename(beside.path, file.path) == 0 else {
            let why = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: beside)
            throw DeviceSession.Failure.message("can't save the pairing: \(why)")
        }
        try? FileManager.default.removeItem(at: unsealed(of: file))
    }

    /// Where a build before the pairings were sealed kept this one, as it was.
    static func unsealed(of file: URL) -> URL { file.deletingPathExtension().appendingPathExtension("plist") }

    private static func remove(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: unsealed(of: file))
    }

    /// Pairings a build before the sealing kept as they were, and what it kept of older ones:
    /// each holds a private key the device may still take, and nothing reads them any more.
    static func removeUnsealed(in directory: URL) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasPrefix("device-pairing-") && (name.hasSuffix(".plist") || name.hasSuffix(".plist.previous")) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    func cancelPairing() {
        lock.withLock { () -> DevicePairing? in pairingCancelled = true; return pairing }?.cancel()
    }

    /// Forgets this Mac's pairing with the device (the device's record of it stays, in its Settings).
    func unpair(_ target: Target) {
        Self.remove(DeviceControlWire.pairingFile(udid: target.udid, in: directory))
        reopen(target.id)
        onLog?("device control: pairing removed", target.id)
    }

    /// The device's session made anew from what is saved now. The new one is in place before
    /// the old one is closed: in between, the device would answer as not set up.
    private func reopen(_ id: UUID) {
        let old = lock.withLock { () -> (any ControlledDevice)? in
            let old = held.removeValue(forKey: id)?.session
            if let t = targets.first(where: { $0.id == id }), let session = session(for: t) { held[id] = Held(target: t, session: session) }
            return old
        }
        Self.closing(old.map { [$0] } ?? [])
        keepOpen()
    }

    /// A session for the device, if a pairing of our own is saved for it.
    private func session(for t: Target) -> (any ControlledDevice)? {
        guard hasPairing(t) else { return nil }
        let file = DeviceControlWire.pairingFile(udid: t.udid, in: directory)
        // Read and unsealed when a connection is made, on that thread: the Keychain may ask the user.
        return open(t, { [key] in try Self.unseal(Data(contentsOf: file), with: key(false)) }) { [weak self] event in
            self?.onLog?("device control: \(event)", t.id)
        }
    }

    func start() {
        Self.removeUnsealed(in: directory)
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
        let sessions = lock.withLock { () -> [any ControlledDevice] in
            defer { held = [:] }
            return held.values.map(\.session)
        }
        // Each is told to end its stream, but quitting doesn't wait on a device that no longer answers.
        let group = DispatchGroup()
        for session in sessions { DispatchQueue.global(qos: .userInitiated).async(group: group) { session.close() } }
        _ = group.wait(timeout: .now() + 2)
    }

    /// How long after its nth failure in a row a connection is tried again: a device away or
    /// asleep is asked less and less often (each try reaches it over whatever network it has).
    static func retryDelay(afterFailures n: Int) -> TimeInterval {
        min(30 * pow(2, Double(max(n, 1) - 1)), 300)
    }

    /// Tries to open what isn't: one attempt per device at a time; none for a pairing the device
    /// refused or this Mac can't read (only pairing again helps, and that makes a new session).
    private func keepOpen() {
        let now = Date()
        let due = lock.withLock { () -> [(UUID, any ControlledDevice)] in
            let due = held.filter { !$0.value.connecting && $0.value.nextTry <= now && !$0.value.session.isOpen && !$0.value.session.isRefused }
            for id in due.keys { held[id]?.connecting = true }
            return due.map { ($0.key, $0.value.session) }
        }
        for (id, session) in due {
            DispatchQueue.global(qos: .utility).async { [self] in
                var failure: String?
                do { try session.connect() } catch { failure = "\(error)" }
                lock.withLock {
                    guard held[id]?.session === session else { return }   // replaced meanwhile
                    let failures = failure == nil ? 0 : (held[id]?.failures ?? 0) + 1
                    held[id]?.connecting = false
                    held[id]?.failures = failures
                    held[id]?.nextTry = failure == nil ? .distantPast : Date().addingTimeInterval(Self.retryDelay(afterFailures: failures))
                }
                if let failure { onUnreached?(id, failure) }
            }
        }
    }

    /// A point given in a look's pixels, as fractions of the screen; nil when outside it.
    static func fraction(x: Double?, y: Double?, of size: (width: Int, height: Int)) -> (x: Double, y: Double)? {
        guard let x, let y, (0..<Double(size.width)).contains(x), (0..<Double(size.height)).contains(y) else { return nil }
        return (x / Double(size.width), y / Double(size.height))
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

    private func look(of device: UUID) -> (width: Int, height: Int)? {
        lock.withLock { held[device]?.looked }
    }

    private static let lookFirst = "look first: a point is given in the pixels of a look, and each look serves one action"

    func answer(_ request: DeviceControlWire.Request) -> DeviceControlWire.Response {
        let notSetUp = DeviceControlWire.Response.failure("device control isn't set up for this device: the user sets it up in the RoamRun app, on the device's page")
        if request.op == "import" {
            return onImport?(request.path ?? "", request.text) ?? .failure("this RoamRun can't take a pairing in")
        }
        // How it stands is said at once, whatever runs on the device.
        if request.op == "state" {
            guard let h = lock.withLock({ held[request.device] }) else { return notSetUp }
            return .init(ok: true, open: h.session.isOpen, refused: h.session.isRefused)
        }
        // Everything else one at a time per device, and whole: a look is checked, spent and acted
        // on without another command coming in between. The session is the one held once the
        // gate is had: a command that waited out another doesn't act on a session replaced
        // meanwhile. What it leaves (the look, the time of the input) stays on that session.
        let gate = lock.withLock { () -> NSLock in
            if let gate = gates[request.device] { return gate }
            let gate = NSLock()
            gates[request.device] = gate
            return gate
        }
        return gate.withLock {
            guard let (h, name) = lock.withLock({ held[request.device].map { ($0, $0.target.name) } }) else { return notSetUp }
            return perform(request, on: h, named: name)
        }
    }

    /// Under the device's gate.
    private func perform(_ request: DeviceControlWire.Request, on h: Held, named name: String) -> DeviceControlWire.Response {
        // Failed or not: an input may have reached the device before the failure showed.
        defer { if request.op != "look" { h.acted = Date() } }
        /// The look's size, for a point to be read against; taken away by `spend` once the request is one that goes to the device.
        func spend() { h.looked = nil }
        do {
            switch request.op {
            case "elements":
                spend()   // the walk can scroll the screen
                let found = try h.session.elements(limit: Self.elementLimit(request.limit))
                return .init(ok: true, captions: found.captions, complete: found.complete)
            case "swipe":
                // A request refused for what it says leaves the look to be used: it is spent by what reaches the device.
                guard let size = h.looked else { return .failure(Self.lookFirst) }
                guard let from = Self.fraction(x: request.x, y: request.y, of: size),
                      let to = Self.fraction(x: request.x2, y: request.y2, of: size) else {
                    return .failure("both points must be inside the last look (\(size.width) x \(size.height))")
                }
                guard let duration = Self.swipeDuration(request.milliseconds) else {
                    return .failure("a swipe takes 50...5000 ms")
                }
                spend()
                try h.session.swipe(from: from, to: to, milliseconds: duration)
                return .init(ok: true)
            case "type", "paste", "press":
                spend()
                guard let text = request.text else { return .failure("nothing to send") }
                switch request.op {
                case "type":
                    let started = Date()
                    try h.session.type(text)
                    Self.inputLog.debug("\(name, privacy: .public): typed \(text.count) keys, \(text.filter { $0 == " " }.count) spaces, in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                case "paste": try h.session.paste(text)
                default: try h.session.press(text)
                }
                return .init(ok: true)
            case "look":
                guard let path = request.path else { return .failure("no file") }
                // What an earlier look showed is no longer what a point may be read off, whether or not this one succeeds.
                spend()
                Thread.sleep(forTimeInterval: Self.settleWait(acted: h.acted))
                let image = try h.session.look()
                guard let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    return .failure("can't write \(path)")
                }
                CGImageDestinationAddImage(out, image, nil)
                guard CGImageDestinationFinalize(out) else { return .failure("can't write \(path)") }
                h.looked = (image.width, image.height)
                return .init(ok: true, width: image.width, height: image.height)
            case "tap":
                // In the pixels of what was last looked at: there is no tapping a screen not seen.
                guard let size = h.looked else { return .failure(Self.lookFirst) }
                guard let point = Self.fraction(x: request.x, y: request.y, of: size) else {
                    return .failure("the point must be inside the last look (\(size.width) x \(size.height))")
                }
                spend()
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
