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
        /// For "tap" and "swipe": the look the points are of, when the caller keeps it (the MCP
        /// tools do; a command run by hand is of whatever was looked at last).
        var look: Int?
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
        /// For "state": only pairing again helps (removed on the device, without the device's key, or unreadable here).
        var refused: Bool?
        /// For "import": what the device is saved as here.
        var name: String?
        /// For "look": which look this is, to be named by the tap or swipe that reads off it.
        var look: Int?
        /// For "state": whether commands and agents may operate the device (its switch in the app).
        var allowed: Bool?
        /// For "state": what answers at the device's address isn't the device the pairing was made with.
        var another: Bool?
        /// For "state": the list of what is switched on couldn't be read from the Keychain (so nothing is).
        var listUnreadable: Bool?
        /// For "import": whether the file the pairing came in is gone (`error` may say more than that).
        var removed: Bool?
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

    /// Whether `path` still names the file `fd` is open on: a name can come to be another file's,
    /// or a link's, while the one it was is held open.
    static func names(_ path: String, theFileOf fd: Int32) -> Bool {
        var held = stat(), named = stat()
        return fstat(fd, &held) == 0 && lstat(path, &named) == 0 && held.st_dev == named.st_dev && held.st_ino == named.st_ino
    }

    /// The longest a line may be: a long paste, or many elements.
    static let longestLine = 1 << 20
    /// What is said after a text was typed that a keyboard other than an English one takes otherwise:
    /// it was warned of before, and typed all the same — said here, where it is read.
    static func typed(_ text: String) -> String? {
        guard text.contains(where: { $0 == " " || $0 == "\n" }) else { return nil }
        return "typed. If the device's keyboard wasn't an English one, its spaces and Returns converted or confirmed instead of being typed, and under an English one auto-correction may have changed a word it didn't know: look, and if the text isn't what you sent, clear it and use paste."
    }

    /// How long the app waits for a request once a client has connected.
    static let requestWait: TimeInterval = 10
    /// How long the CLI waits for the answer: longer than any call may take (the longest text
    /// typed is given some seven minutes by the library).
    static let answerWait: TimeInterval = 480
    /// …and for what the app answers from what it has at hand, without asking the device.
    static let stateWait: TimeInterval = 5

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

    /// Whether a pairing is saved there. A file with nothing in it is none: one that couldn't be
    /// removed was emptied instead.
    static func hasPairing(udid: String, in directory: URL) -> Bool {
        sealedBytes(pairingFile(udid: udid, in: directory))?.isEmpty == false
    }

    /// A sealed pairing as it is on disk — read as the small file of its own it is: not through
    /// a link, not from a pipe or a device (reading those would wait), and no more than a
    /// pairing can be. nil for anything else: it is read while the hub's lock is held.
    static func sealedBytes(_ file: URL) -> Data? { sealedRead(file).bytes }

    /// The same, saying whether it is known what is there. Not known (it couldn't be opened or
    /// read for a reason of the moment — too many files open, an interrupt): not the same as
    /// gone, and nothing is concluded from it.
    static func sealedRead(_ file: URL) -> (bytes: Data?, known: Bool) {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return (nil, [ENOENT, ELOOP, ENOTDIR].contains(errno)) }
        defer { close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0 else { return (nil, false) }
        guard s.st_mode & S_IFMT == S_IFREG, s.st_size < 1 << 20 else { return (nil, true) }
        var data = Data(count: Int(s.st_size))
        let got = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        return got == data.count ? (data, true) : (nil, false)
    }

    /// What a sealed pairing is known by to the switch: a digest of the UDID it is saved under
    /// and of its bytes. The same bytes under another device's name are another mark: a file
    /// copied there doesn't carry its switch along, and isn't switched with the device it was put under.
    static func mark(of sealed: Data, udid: String) -> String {
        var hash = SHA256()
        hash.update(data: Data(udid.lowercased().utf8))
        hash.update(data: Data([0]))
        hash.update(data: sealed)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// What a UDID is made of. It names a file here and is handed to Xcode's tools.
    static func plausible(udid: String) -> Bool {
        !udid.isEmpty && udid.utf8.count <= 64 && udid.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
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
    /// A request that can be given up from another thread while it waits for its answer: the
    /// app sees its asker gone, and doesn't begin what hasn't begun.
    final class Asking: @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32 = -1
        private var given = false

        /// For the next request.
        func again() { lock.withLock { given = false } }
        func giveUp() { lock.withLock { given = true; if fd >= 0 { shutdown(fd, SHUT_RDWR) } } }
        fileprivate func began(_ fd: Int32) -> Bool { lock.withLock { self.fd = fd; return !given } }
        fileprivate func ended() { lock.withLock { fd = -1 } }
    }

    static func ask(_ request: Request, in directory: URL, asking: Asking? = nil, wait: TimeInterval = answerWait) throws -> Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WireError.message("no socket") }
        defer { close(fd) }
        noSIGPIPE(fd)
        readWait(fd, wait)
        guard withAddress(socketPath(in: directory), { connect(fd, $0, $1) }) == 0 else {
            // Not there or nobody listening: no app. Refused by the system: a sandbox around this process.
            let why = errno
            throw why == EPERM || why == EACCES ? WireError.keptOut(String(cString: strerror(why))) : WireError.noApp
        }
        defer { asking?.ended() }   // before the close above: a number given up later isn't this one's
        guard asking?.began(fd) ?? true else { throw WireError.message("taken back") }
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
        /// Held for as long as this listens: the socket's name is one process's at a time, from
        /// before it is made until after it is removed.
        private let held: Int32
        private let stopped = NSLock()
        private var isStopped = false

        /// For a handler that doesn't mind whether its asker is still there.
        convenience init?(directory: URL, handler: @escaping @Sendable (Request) -> Response) {
            self.init(directory: directory, answering: { request, _ in handler(request) })
        }

        /// `answering` is given, with the request, a way to ask whether whoever sent it is
        /// still waiting: one that waited its turn behind another isn't begun for nobody.
        init?(directory: URL, answering handler: @escaping @Sendable (Request, _ wanted: @escaping @Sendable () -> Bool) -> Response) {
            let path = DeviceControlWire.socketPath(in: directory)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            // Not umask around bind(): that is the whole process's, and another thread's file
            // made meanwhile would get it too.
            let folder = DeviceControlWire.socketFolder(in: directory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard chmod(folder.path, 0o700) == 0 else { close(fd); return nil }
            // One at a time, by a lock the system lets go of when its holder ends: a copy started
            // beside the app doesn't take its socket, and one that is ending removes its own —
            // tried by asking whether something answers, an ending one answered no and then
            // removed the socket its successor had made meanwhile.
            let held = open(folder.appendingPathComponent("listener.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard held >= 0, flock(held, LOCK_EX | LOCK_NB) == 0 else {
                if held >= 0 { close(held) }
                close(fd)
                return nil
            }
            unlink(path)   // a run's that ended without removing it
            // Looks a CLI was to move to their place and didn't (it was interrupted): screens aren't left lying.
            for left in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where left.lastPathComponent.hasPrefix("look-") { try? FileManager.default.removeItem(at: left) }
            DeviceControlWire.noSIGPIPE(fd)
            guard DeviceControlWire.withAddress(path, { bind(fd, $0, $1) }) == 0, listen(fd, 64) == 0 else { close(fd); close(held); return nil }
            chmod(path, 0o600)
            self.fd = fd
            self.path = path
            self.held = held
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
                        // Gone: the other end closed (it says nothing more once it has asked, so
                        // nothing to read and not "nothing yet" is its leaving).
                        let wanted: @Sendable () -> Bool = {
                            var byte: UInt8 = 0
                            return recv(client, &byte, 1, MSG_PEEK | MSG_DONTWAIT) != 0
                        }
                        DeviceControlWire.writeLine(request.map { handler($0, wanted) } ?? .failure("unreadable request"), to: client)
                    }
                }
            }
        }

        func stop() {
            // Once: asked again, the name may be a successor's by then.
            guard stopped.withLock({ () -> Bool in defer { isStopped = true }; return !isStopped }) else { return }
            unlink(path)
            close(fd)
            close(held)   // last: until here nobody else makes the socket
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
              !read.pairing.isEmpty, let udid = read.device.udid, DeviceControlWire.plausible(udid: udid),
              isAddress(read.device.providerIP),
              // What a bridge would announce it as: only what RoamRun itself saves.
              read.device.serviceType == "_remotepairing._tcp", ["local", "local."].contains(read.device.domain) else { return nil }
        return read
    }
}

/// An address in numbers: nothing is looked up, and nothing else is connected to.
private func isAddress(_ text: String) -> Bool {
    var v4 = in_addr(), v6 = in6_addr()
    return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
}

/// Where a pairing made elsewhere goes among the saved devices: nothing is saved by working it out.
struct DevicePlacement: Equatable {
    /// The saved device it is for, or the one to add (as the other Mac saved it: here it was
    /// never seen on the network to be added from).
    var profile: DeviceProfile
    var isNew: Bool
}

extension Array where Element == DeviceProfile {
    func placement(of device: DeviceProfile, udid: String, as name: String?) -> Result<DevicePlacement, DeviceControlWire.WireError> {
        func same(_ p: DeviceProfile) -> Bool {
            if let known = p.udid { return known.caseInsensitiveCompare(udid) == .orderedSame }
            return p.providerIP == device.providerIP || p.instanceName == device.instanceName
        }
        if let saved = first(where: same) { return .success(.init(profile: saved, isNew: false)) }
        var profile = device
        profile.id = UUID()
        profile.udid = udid
        profile.displayName = (name ?? device.displayName).trimmingCharacters(in: .whitespaces)
        if let problem = nameProblem(profile.displayName) {
            return .failure(.message("“\(profile.displayName)”: \(problem) Give another with --as."))
        }
        return .success(.init(profile: profile, isNew: true))
    }
}

/// What the hub does with a device: a `DeviceSession`, or a stand-in for one in tests.
protocol ControlledDevice: AnyObject, Sendable {
    var isOpen: Bool { get }
    var isRefused: Bool { get }
    var isAnother: Bool { get }
    func connect() throws
    /// Finds out whether the connection still stands, without waiting for a call under way: `isOpen` says.
    func check()
    /// At once, from any thread: nothing more is begun on the device. `close` follows, and waits.
    func letGo()
    /// The call under way stops where it can; the device is kept.
    func interrupt()
    /// Asked when a call gets its turn on the device, before it begins: false, it isn't begun.
    func gate(_ mayBegin: @escaping @Sendable () -> Bool)
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

extension ControlledDevice {
    var isAnother: Bool { false }
    func interrupt() {}
    func gate(_ mayBegin: @escaping @Sendable () -> Bool) {}
}

/// What a device pairs with: `DevicePairing`, or a stand-in for it in tests.
protocol PairingListener: AnyObject, Sendable {
    var name: String { get }
    func accept(code: @escaping @Sendable (String) -> Void) throws -> DevicePairing.Paired
    func cancel()
}

extension DevicePairing: PairingListener {}

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
        /// The last look: its size, which a tap's pixels are of, which look it was, and when.
        /// (This and `acted` under the device's gate.)
        var looked: (width: Int, height: Int, id: Int, at: Date)?
        /// When the last input ended: a look right after it waits for the screen to settle.
        var acted: Date?
        /// Opening it in the background: one attempt at a time, and further apart while they fail.
        /// (These three under the hub's lock.)
        var connecting = false
        var failures = 0
        var nextTry = Date.distantPast
        /// When the connection was last asked whether it stands (from when it was made).
        var checked = Date()

        /// The pairing this session is for, and the only one it connects with (`session(for:)`):
        /// what the switch is asked about. The saved file changed, this session isn't it any more.
        let mark: String

        init(target: Target, session: any ControlledDevice, mark: String) {
            self.target = target
            self.session = session
            self.mark = mark
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
    private var pairing: (any PairingListener)?
    /// Makes the listener a device pairs with; tests give a stand-in.
    var listening: @Sendable (_ name: String, _ host: String) throws -> any PairingListener = { try DevicePairing(name: $0, host: $1) }
    /// Pairings that were to be removed and whose file wouldn't go: not used again by this
    /// process, whatever is on disk. Lowercased UDIDs, under a lock of their own: they are asked
    /// about from under `lock`.
    private var unremoved: Set<String> = []
    /// Under the same lock: the marks of the pairings this run sealed, by lowercased UDID.
    private var sealedMarks: [String: String] = [:]
    /// Under `lock`: stopped, for good.
    private var stopped = false
    private let unremovedLock = NSLock()
    /// Counts the looks, over all devices: each is told apart by its number. Not from the same
    /// place at every start: a look kept from before a restart isn't taken for one made since.
    private var looks = Int.random(in: 0..<1_000_000_000)
    /// The attempt at pairing under way, and what it has saved while `.done` isn't said yet:
    /// cancelled till then, that goes with it.
    private var pairingUnderWay: UUID?
    private var pairingKept: (udid: String, id: UUID, mark: String?)?
    /// Attempts cancelled, each by its own name: one begun right after doesn't undo it.
    private var pairingsCancelled: Set<UUID> = []
    static let pairingCancelled = "The pairing was cancelled; nothing of it is kept on this Mac. If the device paired, it knows no earlier pairing of this Mac's any more: set it up again."

    var onLog: (@Sendable (String, UUID) -> Void)?
    /// A background attempt to open a device's connection failed, and why.
    var onUnreached: (@Sendable (UUID, String) -> Void)?
    /// …or opened it.
    var onReached: (@Sendable (UUID) -> Void)?
    /// A pairing made on another Mac is brought in (the file's path): the app's to do, which
    /// knows the saved devices.
    var onImport: (@Sendable (String, String?, _ wanted: @Sendable () -> Bool) -> DeviceControlWire.Response)?
    /// Whether commands and agents may use a pairing, named by its mark (a session's `Held.mark`):
    /// the device's switch in the app. Asked at every request, off the main thread.
    var allowed: @Sendable (String) -> Bool = { _ in true }
    /// The sessions that stand may have changed (and every half minute): `heldMarks` is what the
    /// switch may keep. Not to wait in, and asked for the marks when it acts, not now.
    var onHeldChanged: (@Sendable () -> Void)?
    /// A saved pairing was written over: its mark, for the switch to drop. Not to wait in.
    var onReplaced: (@Sendable (String) -> Void)?
    /// The Keychain didn't give the list of what is on: said with how a device stands, apart from a switch that is off.
    var allowedUnreadable: @Sendable () -> Bool = { false }
    /// The same as far as it is known without waiting, for saying how a device stands.
    var allowedKnown: @Sendable (String) -> Bool? = { _ in true }

    /// What the pairing saved under `udid` is known by to the switch (`DeviceControlWire.mark`);
    /// nil where none is saved, or what is there is no pairing's file.
    static func pairingMark(udid: String, in directory: URL) -> String? {
        guard let sealed = DeviceControlWire.sealedBytes(DeviceControlWire.pairingFile(udid: udid, in: directory)), !sealed.isEmpty else { return nil }
        return DeviceControlWire.mark(of: sealed, udid: udid)
    }

    /// The marks the sessions that stand connect with: what the switch may keep. A pairing no
    /// session holds (its file moved away, its device gone from the list, another put in its
    /// place) loses its switch — it isn't found on when it is brought back.
    /// nil once this was stopped: at the end nothing is held, and that isn't what the switch goes by.
    func heldMarks() -> Set<String>? { lock.withLock { stopped ? nil : Set(held.values.map(\.mark)) } }

    /// Whether the pairing saved for `udid` is another than `mark` by now (or gone). nil: it
    /// couldn't be read just now, and isn't taken for changed.
    private func pairingChanged(from mark: String, udid: String) -> Bool? {
        let read = DeviceControlWire.sealedRead(DeviceControlWire.pairingFile(udid: udid, in: directory))
        guard read.known else { return nil }
        return read.bytes.flatMap { $0.isEmpty ? nil : DeviceControlWire.mark(of: $0, udid: udid) } != mark
    }

    /// The call a device is busy with stops where it can: its switch was turned off.
    func interrupt(_ id: UUID) { session(of: id)?.interrupt() }

    /// Runs `body`, and calls `stop` if it is no longer wanted meanwhile (its asker left, its
    /// device was switched off) — again and again for as long as that is so: the call may only now be about to begin, and
    /// begins by taking back a stop that was asked before it.
    static func whileWanted<T>(_ wanted: @escaping @Sendable () -> Bool, else stop: @escaping @Sendable () -> Void, _ body: () throws -> T) rethrows -> T {
        let done = DispatchSemaphore(value: 0), ended = DispatchSemaphore(value: 0)
        // A thread of its own: on a queue shared with everything else it may not get to run
        // while they are all busy, and the call waits for it at its end.
        Thread.detachNewThread {
            while done.wait(timeout: .now() + 0.3) == .timedOut {
                if !wanted() { stop() }
            }
            ended.signal()
        }
        defer { done.signal(); ended.wait() }   // not left asking about an asker whose connection is closed
        return try body()
    }
    static let switchedOff = "device control is switched off for this device: the user switches it on in the RoamRun app, on the device's page"


    private let open: Opener
    private let key: Key

    /// `open` makes the session for a device; tests give stand-ins, and a key of their own.
    init(directory: URL, key: @escaping Key, open: @escaping Opener = { target, pairing, said in
        let session = DeviceSession(ip: target.ip, port: target.port, pairing: pairing)
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
                // …nor one whose saved pairing is another than its session's by now.
                if let t = saved[id], t.reaches(h.target), !unremovedLock.withLock({ unremoved.contains(t.udid.lowercased()) }),
                   pairingChanged(from: h.mark, udid: t.udid) != true {
                    held[id]?.target = t
                } else {
                    gone.append(h.session)
                    held[id] = nil
                }
            }
            for t in targets where held[t.id] == nil {
                if let (session, mark) = session(for: t) { held[t.id] = Held(target: t, session: session, mark: mark) }
            }
        }
        Self.closing(gone)
        onHeldChanged?()
        keepOpen()
    }

    private func hasPairing(_ t: Target) -> Bool {
        hasPairing(udid: t.udid)
    }

    private func hasPairing(udid: String) -> Bool {
        !unremovedLock.withLock({ unremoved.contains(udid.lowercased()) }) && DeviceControlWire.hasPairing(udid: udid, in: directory)
    }

    /// The session held for a device, if any.
    func session(of id: UUID) -> (any ControlledDevice)? { lock.withLock { held[id]?.session } }

    /// Closing waits for a call that runs on the session, which can take long: never on the
    /// caller's thread (the main one, when the list is saved).
    private static func closing(_ sessions: [any ControlledDevice]) {
        guard !sessions.isEmpty else { return }
        // Told at once that nothing more is to begin; the closing itself waits for what runs.
        sessions.forEach { $0.letGo() }
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

    /// Whether what answers for the device isn't the device its pairing was made with.
    func isAnother(_ id: UUID) -> Bool { session(of: id)?.isAnother == true }

    /// Whether a pairing of our own is saved for the device, and whether its connection stands.
    func state(of id: UUID, udid: String) -> (paired: Bool, open: Bool, refused: Bool) {
        let paired = hasPairing(udid: udid)
        let session = session(of: id)
        return (paired, paired && session?.isOpen == true, paired && session?.isRefused == true)
    }

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
        /// The device asked for is known by another UDID than the one that paired: its pairing
        /// would be saved under that one's name, in the place of that one's own.
        case another
    }

    static func verdict(expected: String?, paired: String, others: [(udid: String, name: String)]) -> PairingVerdict {
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        if let expected, same(expected, paired) { return .expected }
        if let other = others.first(where: { same($0.udid, paired) }) { return .savedAs(other.name) }
        if expected == nil, paired.isEmpty { return .nameless }
        if expected != nil, !paired.isEmpty { return .another }
        return .toProve
    }

    /// Lets the device pair with this Mac (iOS 27 and later, on the same network), one at a time.
    /// The new pairing replaces the saved one when the device is the one asked for, or — its
    /// UDID not known here — once it opened a connection of its own.
    /// `attempt` names this pairing for `cancelPairing`. Cancelled before its pairing is saved,
    /// nothing is saved; cancelled after and before `.done` is said, what was saved is removed.
    func pair(_ device: PairingRequest, as name: String, attempt: UUID = UUID(), step: @escaping @Sendable (PairingStep) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // Taken before anything is advertised: two of these would name themselves alike.
            let free = lock.withLock { () -> Bool in
                guard pairingUnderWay == nil else { return false }
                pairingUnderWay = attempt
                return true
            }
            guard free else {
                lock.withLock { _ = pairingsCancelled.remove(attempt) }
                return step(.failed("Another pairing is under way."))
            }
            defer { lock.withLock { pairing = nil; pairingUnderWay = nil; pairingKept = nil; pairingsCancelled.remove(attempt) } }
            do {
                // Before the device is asked anything: once it pairs it knows no older pairing of
                // ours, and a Keychain that then refuses would leave it with none this Mac holds.
                // And that key is the one it is sealed with: asked for again after the pairing,
                // the Keychain could refuse then.
                let sealing = try key(true)
                let listening = try self.listening(name, Self.hostID(in: directory))
                // A cancel that came before there was anything to cancel still counts.
                if lock.withLock({ () -> Bool in pairing = listening; return pairingsCancelled.contains(attempt) }) { listening.cancel() }
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
                // It names a file here.
                guard paired.udid.isEmpty || DeviceControlWire.plausible(udid: paired.udid) else {
                    throw DeviceSession.Failure.message("\(paired.name) paired and gave what isn't a UDID. Nothing was saved.")
                }
                switch Self.verdict(expected: device.udid, paired: paired.udid, others: device.others) {
                case .expected: break
                case .savedAs(let other):
                    throw DeviceSession.Failure.message("\(paired.name) paired, which is saved here as “\(other)”, not “\(device.name)”. Nothing was saved, and its earlier pairing with this Mac no longer works: set device control up again on “\(other)”.")
                case .nameless:
                    throw DeviceSession.Failure.message("\(paired.name) paired without saying which device it is. Nothing was saved.")
                case .another:
                    throw DeviceSession.Failure.message("\(paired.name) paired, and it isn't “\(device.name)” as that is saved here (another UDID). Nothing was saved, and what was saved for “\(device.name)” is as it was; the pairing just made can be removed on \(paired.name), in Settings. If “\(device.name)” is that device now, remove it here and add it again.")
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
                // Saved, or cancelled: whichever came first, under the one lock. Held from now on,
                // also when the list of saved devices doesn't have its UDID yet.
                try lock.withLock {
                    guard !pairingsCancelled.contains(attempt) else { throw DeviceSession.Failure.message(Self.pairingCancelled) }
                    // The mark of what was written, not of what is there a moment later.
                    let mark = try sealPairing(paired.pairing, with: sealing, udid: udid)
                    pairingKept = (udid, device.id, mark)
                    if !targets.contains(where: { $0.id == target.id }) { targets.append(target) }
                }
                reopen(target.id)
                // Said as it is: saved, and whether it also connects right now.
                var unreached: String?
                do { try session(of: target.id)?.connect() } catch { unreached = "\(error)" }
                // Cancelled while that was tried, what was saved went with the cancel: not said as done.
                let kept = lock.withLock { () -> Bool in
                    pairingKept = nil
                    return !pairingsCancelled.contains(attempt)
                }
                guard kept else { throw DeviceSession.Failure.message(Self.pairingCancelled) }
                step(.done(udid: udid, unreached: unreached))
            } catch {
                step(.failed("\(error)"))
            }
        }
    }

    /// A pairing made elsewhere is taken in two steps, with the saving of its device between
    /// them: tried first, with nothing written — a pairing saved for the device before stays as
    /// it is until this one is sure to be kept. The key it will be sealed with is had now, so
    /// that nothing after the device is saved depends on the Keychain.
    func tryPairing(_ pairing: Data, for target: Target) throws -> SymmetricKey {
        let sealing = try key(true)
        let check = open(target, { pairing }) { _ in }
        defer { check.close() }
        do { try check.connect() } catch {
            throw DeviceSession.Failure.message("this pairing opens no connection to “\(target.name)” at \(target.ip) (\(error)). Nothing was saved.")
        }
        return sealing
    }

    /// The second step, in two parts. Sealed in the saved one's place: quick, no network and no
    /// Keychain, so that whoever saves the device can do both without letting anything in between
    /// (a device removed after it was saved and before its pairing was would leave the pairing).
    /// Gives the mark of what it wrote — of those bytes, not of whatever is in the file a moment
    /// later: it is this that is switched on.
    @discardableResult
    func sealPairing(_ pairing: Data, with sealing: SymmetricKey, udid: String) throws -> String {
        let before = Self.pairingMark(udid: udid, in: directory)
        let sealed = try Self.seal(pairing, with: sealing)
        let mark = DeviceControlWire.mark(of: sealed, udid: udid)
        try Self.save(sealed, as: DeviceControlWire.pairingFile(udid: udid, in: directory))
        unremovedLock.withLock {
            _ = unremoved.remove(udid.lowercased())
            sealedMarks[udid.lowercased()] = mark
        }
        // The pairing this took the place of may still be one the device knows (one brought in
        // has an identity of its own): it isn't left switched on for whoever kept a copy of it.
        if let before, before != mark { onReplaced?(before) }
        return mark
    }

    /// The mark of the pairing this run last sealed under `udid`, as it wrote it.
    func sealedMark(udid: String) -> String? { unremovedLock.withLock { sealedMarks[udid.lowercased()] } }

    /// The mark of the pairing the device's session connects with: what its switch is about.
    func mark(of id: UUID) -> String? { lock.withLock { held[id]?.mark } }

    /// And held from now on, connected when this returns.
    func hold(_ target: Target) {
        lock.withLock { targets.removeAll { $0.id == target.id }; targets.append(target) }
        reopen(target.id)
        // Connected when this returns, as it just was: asked how it stands, it says so.
        try? session(of: target.id)?.connect()
        onLog?("device control: a pairing made on another Mac was taken in", target.id)
    }

    /// A pairing file is read as the one file it is: not through a link (the link would be removed
    /// and the file left), not one that has another name (it would stay under that), and no more
    /// than a pairing can be. The descriptor is the caller's to close, after `removeTaken`.
    static func readTaken(_ path: String) throws -> (fd: Int32, data: Data) {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            throw DeviceSession.Failure.message(errno == ELOOP ? "\(path) is a link: give the file itself" : "can't read \(path): \(String(cString: strerror(errno)))")
        }
        var s = stat()
        let why: String? = fstat(fd, &s) != 0 || s.st_mode & S_IFMT != S_IFREG ? "\(path) isn't a file"
            : s.st_nlink != 1 ? "\(path) has another name too (a hard link): the pairing would stay under it"
            : s.st_size >= 1 << 20 ? "\(path) isn't a pairing made by `roamrun pairing create`" : nil
        if let why {
            close(fd)
            throw DeviceSession.Failure.message(why)
        }
        var data = Data(count: Int(s.st_size))
        let got = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        guard got == data.count else {
            close(fd)
            throw DeviceSession.Failure.message("can't read \(path)")
        }
        return (fd, data)
    }

    /// The file a pairing was read from is removed once it is taken in. nil when it is gone; else
    /// what to tell whoever brought it: it is still a key to the device.
    static func removeTaken(_ file: URL, readThrough fd: Int32, remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) -> String? {
        let still = "it still lets whoever has it see and operate the device"
        guard DeviceControlWire.names(file.path, theFileOf: fd) else {
            return "\(file.path) came to name another file while it was read: what the pairing was read from wasn't removed, and may be there under another name — \(still)"
        }
        do { try remove(file) } catch {
            return "\(file.path) couldn't be removed (\(error.localizedDescription)): delete it yourself — \(still)"
        }
        return nil
    }

    /// Removes the pairing saved under `udid`, held or not: one made for a device that turned
    /// out not to be saved under it.
    func forgetPairing(udid: String, of id: UUID) {
        _ = drop(udid: udid, of: id)
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
        // A name of its own: two savings for one device at the same instant (one brought in, one
        // set up) each rename their own bytes, and each knows the mark of what it wrote.
        let beside = file.appendingPathExtension("writing-\(UUID().uuidString)")
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

    /// Whether it is gone: a file that stays (a folder that can't be written to) is still a key.
    @discardableResult
    private static func remove(_ file: URL) -> Bool {
        try? FileManager.default.removeItem(at: unsealed(of: file))
        // By what the removal says: a file that can't be seen (its folder closed) isn't one that is gone.
        return unlink(file.path) == 0 || errno == ENOENT
    }

    /// What became of a pairing that was to be forgotten.
    enum Dropped: Equatable {
        case removed
        /// Its file wouldn't go and was emptied: the key is gone all the same.
        case emptied
        /// Neither: the key is still in the file, and is out of use only while this runs.
        case left
    }

    /// Forgets the pairing saved under `udid`. When its file won't go, the pairing is put out of
    /// use all the same for as long as this runs, and that is said: removed must not go on working.
    private func drop(udid: String, of id: UUID) -> Dropped {
        let file = DeviceControlWire.pairingFile(udid: udid, in: directory)
        // A folder that can't be written to keeps the file; the file itself can still be emptied.
        let dropped: Dropped = Self.remove(file) ? .removed : truncate(file.path, 0) == 0 ? .emptied : .left
        unremovedLock.withLock { if dropped == .left { unremoved.insert(udid.lowercased()) } else { unremoved.remove(udid.lowercased()) } }
        switch dropped {
        case .removed: break
        case .emptied: onLog?("device control: the pairing's file couldn't be removed (\(file.path)); it was emptied, and holds no pairing any more", id)
        case .left: onLog?("device control: the pairing's file couldn't be removed or emptied and still holds the pairing (\(file.path)). It is out of use until RoamRun is opened again: delete the file, or unpair on the device", id)
        }
        return dropped
    }

    /// Pairings a build before the sealing kept as they were, and what it kept of older ones:
    /// each holds a private key the device may still take, and nothing reads them any more.
    /// And what a saving left half-done (a run that ended in the middle of one).
    static func removeUnsealed(in directory: URL) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasPrefix("device-pairing-") && (name.hasSuffix(".plist") || name.hasSuffix(".plist.previous") || name.contains(".sealed.writing")) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    func cancelPairing(_ attempt: UUID) {
        let (listening, kept) = lock.withLock { () -> ((any PairingListener)?, (udid: String, id: UUID, mark: String?)?) in
            pairingsCancelled.insert(attempt)
            guard pairingUnderWay == attempt else { return (nil, nil) }
            defer { pairingKept = nil }
            return (pairing, pairingKept)
        }
        listening?.cancel()
        // Saved already, and not yet said to be: it goes now, not when the attempt comes round to it.
        // …if it is still what is saved: a pairing brought in over it meanwhile is not this attempt's to remove.
        if let kept, Self.pairingMark(udid: kept.udid, in: directory) == kept.mark { forgetPairing(udid: kept.udid, of: kept.id) }
    }

    /// Forgets this Mac's pairing with the device (the device's record of it stays, in its Settings).
    @discardableResult
    func unpair(_ target: Target) -> Dropped {
        let dropped = drop(udid: target.udid, of: target.id)
        reopen(target.id)
        if dropped == .removed { onLog?("device control: pairing removed", target.id) }
        return dropped
    }

    /// The device's session made anew from what is saved now. The new one is in place before
    /// the old one is closed: in between, the device would answer as not set up.
    private func reopen(_ id: UUID) {
        let old = lock.withLock { () -> (any ControlledDevice)? in
            let old = held.removeValue(forKey: id)?.session
            if let t = targets.first(where: { $0.id == id }), let (session, mark) = session(for: t) { held[id] = Held(target: t, session: session, mark: mark) }
            return old
        }
        Self.closing(old.map { [$0] } ?? [])
        onHeldChanged?()
        keepOpen()
    }

    /// A session for the device, if a pairing of our own is saved for it.
    private func session(for t: Target) -> (session: any ControlledDevice, mark: String)? {
        guard hasPairing(t), let mark = Self.pairingMark(udid: t.udid, in: directory) else { return nil }
        let file = DeviceControlWire.pairingFile(udid: t.udid, in: directory)
        // Read and unsealed when a connection is made, on that thread: the Keychain may ask the user.
        // Only the pairing the session was made for: the file put in its place meanwhile (another
        // pairing, one that is switched on) isn't connected with under this one's name.
        let session = open(t, { [key] in
            // In the words of a call stopped, either way: not a pairing to be made again (put back, it connects).
            let read = DeviceControlWire.sealedRead(file)
            guard read.known else {
                throw DeviceSession.Failure.message("\(DeviceSession.stopped) the pairing saved for this device couldn't be read just now")
            }
            guard let sealed = read.bytes, DeviceControlWire.mark(of: sealed, udid: t.udid) == mark else {
                throw DeviceSession.Failure.message("\(DeviceSession.stopped) the pairing saved for this device changed: its connection is made anew")
            }
            return try Self.unseal(sealed, with: key(false))
        }) { [weak self] event in
            self?.onLog?("device control: \(event)", t.id)
        }
        // Asked again when a call gets its turn on the session: switched off while it waited, it isn't begun.
        session.gate { [weak self] in self?.allowed(mark) ?? false }
        return (session, mark)
    }

    func start() {
        Self.removeUnsealed(in: directory)
        listen()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.listen()   // not had at the start (another copy was ending): had now
            self?.renewChanged()
            self?.checkOpen()
            self?.keepOpen()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        // A pairing saved and not yet said to be done is nobody's once this ends.
        if let attempt = lock.withLock({ pairingUnderWay }) { cancelPairing(attempt) }
        timer?.cancel()
        listener?.stop()
        let sessions = lock.withLock { () -> [any ControlledDevice] in
            defer { held = [:] }
            stopped = true
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

    /// A session whose saved pairing is another by now (or gone) connects with nothing any more:
    /// it is replaced by one for what is there, instead of standing as a pairing to be made again.
    func renewChanged() {
        // …and a device whose pairing appeared since (put back, or brought in by hand) gets one:
        // without it there is nothing its switch could be about.
        let changed = lock.withLock { () -> [UUID] in
            held.filter { pairingChanged(from: $0.value.mark, udid: $0.value.target.udid) == true }.map(\.key)
                + targets.filter { held[$0.id] == nil && hasPairing($0) }.map(\.id)
        }
        changed.forEach(reopen)
        onHeldChanged?()   // also when nothing changed: the chance to write what a write failed to
    }

    /// How often a connection that stands is asked whether it still does: a device restarted, or
    /// its pairing removed on it, otherwise reads as connected until the next call finds out.
    var checkEvery: TimeInterval = 60

    /// Asks each connection that stands and is due; one found gone is opened anew at once.
    func checkOpen() {
        let now = Date()
        let due = lock.withLock { () -> [any ControlledDevice] in
            let due = held.filter { $0.value.session.isOpen && now.timeIntervalSince($0.value.checked) >= checkEvery }
            for id in due.keys { held[id]?.checked = now }
            return due.map(\.value.session)
        }
        for session in due {
            // A thread of its own: the shared queue's can all be taken by calls that wait on a device.
            Thread.detachNewThread { [self] in
                session.check()
                if !session.isOpen { keepOpen() }
            }
        }
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
                if let failure { onUnreached?(id, failure) } else { onReached?(id) }
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

    static func isLookFile(_ path: String, in directory: URL) -> Bool {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        return file.deletingLastPathComponent().path == DeviceControlWire.socketFolder(in: directory).standardizedFileURL.path
            && file.lastPathComponent.hasPrefix("look-") && file.pathExtension == "png"
    }

    private static let lookFirst = "look first: a point is given in the pixels of a look, and each look serves one action"
    static let nobodyWaits = "nobody is waiting for this any more"
    static let notGiven = "not given: whoever asked has left, or the device was switched off meanwhile"
    /// The longer side of a look, at most: what a model is shown without its being scaled once more.
    static let lookSide = 1280
    /// `image` with its longer side at most `lookSide`; itself when it is.
    static func fitted(_ image: CGImage) -> CGImage {
        let longer = max(image.width, image.height)
        guard longer > lookSide else { return image }
        let scale = CGFloat(lookSide) / CGFloat(longer)
        let width = Int((CGFloat(image.width) * scale).rounded()), height = Int((CGFloat(image.height) * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
    static let lookOld = "look again: the look this point is from is over a minute old, and the screen may be another by now"
    /// How long a look serves: whoever read a point off it took their time, and the screen its own course.
    var lookStands: TimeInterval = 60
    static let lookedSince = "the device was looked at again since the look this point is from (by another): look again"

    private func listen() {
        guard lock.withLock({ listener == nil }) else { return }
        let made = DeviceControlWire.Listener(directory: directory, answering: { [weak self] request, wanted in
            self?.answer(request, wanted: wanted) ?? .failure("stopping")
        })
        lock.withLock { if listener == nil { listener = made } else { made?.stop() } }
    }

    /// `wanted`: whether whoever asked is still there. A request that waited its turn and whose
    /// asker has left meanwhile (interrupted, or tired of waiting) isn't begun.
    func answer(_ request: DeviceControlWire.Request, wanted: @escaping @Sendable () -> Bool = { true }) -> DeviceControlWire.Response {
        let notSetUp = DeviceControlWire.Response.failure("device control isn't set up for this device: the user sets it up in the RoamRun app, on the device's page")
        if request.op == "import" {
            return onImport?(request.path ?? "", request.text, wanted) ?? .failure("this RoamRun can't take a pairing in")
        }
        // How it stands is said at once, whatever runs on the device.
        if request.op == "state" {
            guard let h = lock.withLock({ held[request.device] }) else { return notSetUp }
            // As far as it is known: how a device stands is said at once, and the Keychain may take its time.
            return .init(ok: true, open: h.session.isOpen, refused: h.session.isRefused, allowed: allowedKnown(h.mark),
                         another: h.session.isAnother ? true : nil, listUnreadable: allowedUnreadable() ? true : nil)
        }
        // Everything else one at a time per device, and whole: a look is checked, spent and acted
        // on without another command coming in between. The session is the one held once the
        // gate is had: a command that waited out another doesn't act on a session replaced
        // meanwhile. What it leaves (the look, the time of the input) stays on that session.
        let gate = lock.withLock { () -> NSLock? in
            if let gate = gates[request.device] { return gate }
            guard held[request.device] != nil else { return nil }   // none kept for what any asker names
            let gate = NSLock()
            gates[request.device] = gate
            return gate
        }
        guard let gate else { return notSetUp }
        return gate.withLock {
            guard wanted() else { return .failure(Self.nobodyWaits) }
            guard let (h, name) = lock.withLock({ held[request.device].map { ($0, $0.target.name) } }) else { return notSetUp }
            // By the pairing the session connects with, whatever is saved under the device's name by now.
            let mark = h.mark
            guard allowed(mark) else { return .failure(Self.switchedOff) }
            // Wanted, for a call that takes its time: asked for by someone still there, of a
            // pairing still switched on (it was, a moment ago: it may be switched off meanwhile).
            let known = allowedKnown
            return perform(request, on: h, named: name, wanted: { wanted() && known(mark) != false })
        }
    }

    /// Under the device's gate.
    private func perform(_ request: DeviceControlWire.Request, on h: Held, named name: String, wanted: @escaping @Sendable () -> Bool) -> DeviceControlWire.Response {
        // Failed or not: an input may have reached the device before the failure showed.
        defer { if request.op != "look" { h.acted = Date() } }
        /// The look's size, for a point to be read against; taken away by `spend` once the request is one that goes to the device.
        func spend() { h.looked = nil }
        do {
            switch request.op {
            case "elements":
                spend()   // the walk can scroll the screen
                let walked = h.session
                let limit = Self.elementLimit(request.limit)
                let found = try Self.whileWanted(wanted, else: { walked.interrupt() }) { try walked.elements(limit: limit) }
                return .init(ok: true, captions: found.captions, complete: found.complete)
            case "swipe":
                // A request refused for what it says leaves the look to be used: it is spent by what reaches the device.
                guard let size = h.looked else { return .failure(Self.lookFirst) }
                guard request.look ?? size.id == size.id else { return .failure(Self.lookedSince) }
                guard Date().timeIntervalSince(size.at) <= lookStands else { return .failure(Self.lookOld) }
                guard let from = Self.fraction(x: request.x, y: request.y, of: (size.width, size.height)),
                      let to = Self.fraction(x: request.x2, y: request.y2, of: (size.width, size.height)) else {
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
                    // A text takes its time: an asker who leaves meanwhile has it stopped where it is.
                    let session = h.session
                    try Self.whileWanted(wanted, else: { session.interrupt() }) { try session.type(text) }
                    Self.inputLog.debug("\(name, privacy: .public): typed \(text.count) keys, \(text.filter { $0 == " " }.count) spaces, in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                case "paste": try h.session.paste(text)
                default: try h.session.press(text)
                }
                return .init(ok: true)
            case "look":
                // Written only where RoamRun keeps looks: whoever asks takes it from there.
                guard let path = request.path, Self.isLookFile(path, in: directory) else { return .failure("no file to write the look to") }
                // What an earlier look showed is no longer what a point may be read off, whether or not this one succeeds.
                spend()
                Thread.sleep(forTimeInterval: Self.settleWait(acted: h.acted))
                // As large as a model is shown it, no larger: an image scaled again by whatever shows
                // it has points that aren't the look's any more, and a tap goes beside what was meant.
                let image = Self.fitted(try h.session.look())
                guard let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    return .failure("can't write \(path)")
                }
                CGImageDestinationAddImage(out, image, nil)
                guard CGImageDestinationFinalize(out) else { return .failure("can't write \(path)") }
                // Whoever asked left while it was taken: nobody is there to take the screen away.
                guard wanted() else {
                    try? FileManager.default.removeItem(atPath: path)
                    return .failure(Self.notGiven)
                }
                let id = lock.withLock { () -> Int in looks += 1; return looks }
                h.looked = (image.width, image.height, id, Date())
                return .init(ok: true, width: image.width, height: image.height, look: id)
            case "tap":
                // In the pixels of what was last looked at: there is no tapping a screen not seen.
                guard let size = h.looked else { return .failure(Self.lookFirst) }
                // Of this look, when the caller says which: another's look since shows a screen this one never saw.
                guard request.look ?? size.id == size.id else { return .failure(Self.lookedSince) }
                guard Date().timeIntervalSince(size.at) <= lookStands else { return .failure(Self.lookOld) }
                guard let point = Self.fraction(x: request.x, y: request.y, of: (size.width, size.height)) else {
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
