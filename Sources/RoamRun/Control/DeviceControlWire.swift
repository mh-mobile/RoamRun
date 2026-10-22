import CryptoKit
import Foundation

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
        /// For "tap", "swipe", "type" and "paste": the look the points or the text are held to, when
        /// the caller keeps it (the MCP tools do; a command run by hand is of whatever was looked at last).
        var look: Int?
        /// For "pair-start": this Mac's address on the tailnet, the interface it is on, and the
        /// one address the device's connection will come from (the Mac that introduces it).
        var address: String?
        var interface: String?
        var peer: String?
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
        /// For "rules": which look rules this app holds to (`DeviceControlHub.rules`); an older app has none.
        var rules: Int?
        /// For "pair-start": this Mac's offer to pair. For "pair-status": where the attempt stands
        /// (waiting, code, checking, done, failed, unknown), its code while one is shown, and
        /// why it failed, as a word.
        var offer: String?
        var state: String?
        var code: String?
        var reason: String?
        static func failure(_ why: String) -> Response {
            Response(ok: false, error: why)
        }
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
        return fstat(fd, &held) == 0 && lstat(path, &named) == 0 && held.st_dev == named.st_dev && held.st_ino == named
            .st_ino
    }

    /// The longest a line may be: a long paste, or many elements.
    static let longestLine = 1 << 20
    /// What is said after a text was typed that a keyboard other than an English one takes otherwise:
    /// it was warned of before, and typed all the same — said here, where it is read.
    static func typed(_ text: String) -> String? {
        guard text.contains(where: {
            $0 == " " || $0 == "\n"
        }) else { return nil }
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
    static func socketFolder(in directory: URL) -> URL {
        directory.appendingPathComponent("control", isDirectory: true)
    }

    static func socketPath(in directory: URL) -> String {
        socketFolder(in: directory)
            .appendingPathComponent("sock")
            .path
    }

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
    static func sealedBytes(_ file: URL) -> Data? {
        sealedRead(file).bytes
    }

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
        let got = data.withUnsafeMutableBytes {
            pread(fd, $0.baseAddress, $0.count, 0)
        }
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
        return hash.finalize()
            .map {
                String(format: "%02x", $0)
            }
            .joined()
    }

    /// What a UDID is made of. It names a file here and is handed to Xcode's tools.
    static func plausible(udid: String) -> Bool {
        !udid.isEmpty && udid.utf8.count <= 64 && udid.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-")
        }
    }

    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        // The kernel's limit; a path that doesn't fit can't be bound or reached.
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.copyBytes(from: bytes)
        }
        return address
    }

    private static func withAddress<R>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R? {
        guard var address = address(path) else { return nil }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
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
            if buffer[..<n].contains(0x0A) {
                break
            }
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
        func again() {
            lock.withLock {
                given = false
            }
        }

        func giveUp() {
            lock.withLock {
                given = true
                if fd >= 0 {
                    shutdown(fd, SHUT_RDWR)
                }
            }
        }

        fileprivate func began(_ fd: Int32) -> Bool {
            lock.withLock {
                self.fd = fd
                return !given
            }
        }

        fileprivate func ended() {
            lock.withLock {
                fd = -1
            }
        }
    }

    static func ask(_ request: Request, in directory: URL, asking: Asking? = nil,
                    wait: TimeInterval = answerWait) throws -> Response
    {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WireError.message("no socket") }
        defer { close(fd) }
        noSIGPIPE(fd)
        readWait(fd, wait)
        guard withAddress(socketPath(in: directory), {
            connect(fd, $0, $1)
        }) == 0 else {
            // Not there or nobody listening: no app. Refused by the system: a sandbox around this process.
            let why = errno
            throw why == EPERM || why == EACCES ? WireError.keptOut(String(cString: strerror(why))) : WireError.noApp
        }
        defer { asking?.ended() } // before the close above: a number given up later isn't this one's
        guard asking?.began(fd) ?? true else { throw WireError.message("taken back") }
        guard writeLine(request, to: fd)
        else { throw WireError.message("couldn't send the request (a number that isn't one?)") }
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
            self.init(directory: directory, answering: { request, _ in
                handler(request)
            })
        }

        /// `answering` is given, with the request, a way to ask whether whoever sent it is
        /// still waiting: one that waited its turn behind another isn't begun for nobody.
        init?(
            directory: URL,
            answering handler: @escaping @Sendable (Request, _ wanted: @escaping @Sendable () -> Bool) -> Response
        ) {
            let path = DeviceControlWire.socketPath(in: directory)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            // Not umask around bind(): that is the whole process's, and another thread's file
            // made meanwhile would get it too.
            let folder = DeviceControlWire.socketFolder(in: directory)
            try? FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard chmod(folder.path, 0o700) == 0 else { close(fd)
                return nil
            }
            // One at a time, by a lock the system lets go of when its holder ends: a copy started
            // beside the app doesn't take its socket, and one that is ending removes its own —
            // tried by asking whether something answers, an ending one answered no and then
            // removed the socket its successor had made meanwhile.
            let held = open(folder.appendingPathComponent("listener.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard held >= 0, flock(held, LOCK_EX | LOCK_NB) == 0 else {
                if held >= 0 {
                    close(held)
                }
                close(fd)
                return nil
            }
            unlink(path) // a run's that ended without removing it
            // Looks a CLI was to move to their place and didn't (it was interrupted): screens aren't left lying.
            for left in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ??
                []
                where left.lastPathComponent.hasPrefix("look-")
            {
                try? FileManager.default.removeItem(at: left)
            }
            DeviceControlWire.noSIGPIPE(fd)
            guard DeviceControlWire.withAddress(path, {
                bind(fd, $0, $1)
            }) == 0, listen(fd, 64) == 0 else { close(fd)
                close(held)
                return nil
            }
            chmod(path, 0o600)
            self.fd = fd
            self.path = path
            self.held = held
            Thread.detachNewThread { [weak self, fd] in
                while true {
                    let client = accept(fd, nil, nil)
                    guard client >= 0 else {
                        // stop() closed it; anything else (a client that gave up) is one accept lost.
                        if self?.stopped.withLock({
                            self?.isStopped
                        }) ?? true {
                            return
                        }
                        usleep(50_000)
                        continue
                    }
                    DispatchQueue.global(qos: .userInitiated).async {
                        defer { close(client) }
                        DeviceControlWire.readWait(client, DeviceControlWire.requestWait)
                        let line = DeviceControlWire.readLine(client)
                        guard !line.isEmpty else { return } // said nothing: nobody to answer
                        let request = try? JSONDecoder().decode(Request.self, from: line)
                        // Gone: the other end closed (it says nothing more once it has asked, so
                        // nothing to read and not "nothing yet" is its leaving).
                        let wanted: @Sendable () -> Bool = {
                            var byte: UInt8 = 0
                            return recv(client, &byte, 1, MSG_PEEK | MSG_DONTWAIT) != 0
                        }
                        DeviceControlWire.writeLine(request.map {
                            handler($0, wanted)
                        } ?? .failure("unreadable request"), to: client)
                    }
                }
            }
        }

        func stop() {
            // Once: asked again, the name may be a successor's by then.
            guard stopped.withLock({ () -> Bool in
                defer { isStopped = true }
                return !isStopped
            }) else { return }
            unlink(path)
            close(fd)
            close(held) // last: until here nobody else makes the socket
        }
    }
}
