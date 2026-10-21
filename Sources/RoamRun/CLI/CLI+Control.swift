import DeviceControl
import Foundation

extension CLI {
    /// Where a device stands with being operated. `line` is nil when there is nothing to say
    /// (no pairing of our own: it was never set up).
    enum ControlState: Equatable {
        case notSetUp, connected, notConnected, refused, noApp
        /// Paired, and its switch in the app is off: commands and agents are refused.
        case switchedOff
        /// What answers at its address isn't the device the pairing was made with.
        case another
        /// The Keychain didn't give the app its list of devices switched on: none is.
        case listUnreadable
        /// The app can't be asked from here (a sandbox around this process).
        case keptOut

        /// For `status --json`: nil where device control isn't set up.
        var key: String? {
            switch self {
            case .notSetUp: nil
            case .connected: "connected"
            case .notConnected: "notConnected"
            case .refused: "refused"
            case .switchedOff: "switchedOff"
            case .listUnreadable: "listUnreadable"
            case .another: "another"
            case .noApp: "noApp"
            case .keptOut: "keptOut"
            }
        }

        /// `mesh`: what keeps this Mac itself off Tailscale, when something does.
        static func notConnectedLine(mesh: String?) -> String {
            guard let mesh else { return ControlState.notConnected.line! }
            return "paired, not connected — \(mesh): until then nothing on this Mac reaches the device"
        }

        var line: String? {
            switch self {
            case .notSetUp: nil
            case .connected: "connected"
            case .notConnected: "paired, not connected — the app keeps trying; it can connect only while the device is on a Wi‑Fi"
            case .refused: "the pairing can no longer be used (removed on the device, made by a build that didn't keep the device's key with it, or this Mac can't read what it saved) — the user pairs again in the RoamRun app, on the device's page"
            case .another: "paired, but what answers at its address isn't the device the pairing was made with — it is told nothing of this Mac's and sent no input. Erased or replaced: the user pairs again in the RoamRun app; otherwise something else has its address"
            case .listUnreadable: "paired, off — the Keychain didn't give the RoamRun app its list of devices switched on (the Keychain is locked, it was refused, or the item there isn't RoamRun's); the device's page in the app says what to do"
            case .switchedOff: "paired, switched off — the user switches it on in the RoamRun app, on the device's page"
            case .noApp: "paired; the RoamRun app, which holds the connection, isn't running (or is a build without device control)"
            case .keptOut: "paired; this process isn't allowed to reach the RoamRun app (a sandbox around it?) — run it outside, or use the MCP tools"
            }
        }
    }

    static func controlState(_ id: UUID, udid: String?) -> ControlState {
        guard let udid, DeviceControlWire.hasPairing(udid: udid, in: ProfileStore.directory) else {
            return .notSetUp
        }
        let r: DeviceControlWire.Response
        do { r = try DeviceControlWire.ask(
            .init(op: "state", device: id),
            in: ProfileStore.directory,
            wait: DeviceControlWire.stateWait
        ) } catch {
            if case DeviceControlWire.WireError.keptOut = error {
                return .keptOut
            }
            return .noApp
        }
        // In the order the app's page says them: what must be mended first comes first.
        if r.ok, r.refused == true {
            return .refused
        }
        if r.ok, r.another == true {
            return .another
        }
        if r.ok, r.listUnreadable == true {
            return .listUnreadable
        }
        if r.ok, r.allowed == false {
            return .switchedOff
        }
        // A pairing the app hasn't picked up yet answers as not set up there.
        guard r.ok, r.open != true else { return r.ok ? .connected : .notConnected }
        return r.refused == true ? .refused : .notConnected
    }

    /// A pairing for another Mac: made in this process, written to `file` and kept nowhere here.
    /// Under an identity of its own, so the device lists it on its own and it can be removed
    /// there alone; this Mac's own pairing stays as it is.
    static func createPairing(_ profile: DeviceProfile, others: [DeviceProfile], file: String,
                              label: String?) -> Never
    {
        let out = URL(fileURLWithPath: file).standardizedFileURL
        // The file is had before the pairing, and written through what was had: checked now and
        // written after the code was entered, another could be put there in between.
        let fd: Int32
        do { fd = try reserve(out.path) } catch { fail((error as? ArgumentError)?.message ?? "\(error)") }
        // Interrupted, hung up on (an SSH session that ends) or told to end: nothing is left.
        reserved = (strdup(out.path), fd)
        for sign in [SIGINT, SIGHUP, SIGTERM] {
            signal(sign) { sign in
                if let made = CLI.reserved {
                    CLI.removeReserved(made.path, made.fd)
                }
                _exit(128 + sign)
            }
        }
        /// Nothing is left where the pairing was to go.
        func stop(_ why: String) -> Never {
            out.path.withCString {
                CLI.removeReserved($0, fd)
            }
            CLI.reserved = nil // after: a signal in between still finds what to remove
            close(fd)
            CLI.stop(why)
        }
        let label = label ?? "RoamRun (\(out.deletingPathExtension().lastPathComponent))"
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            let listening = try DevicePairing(name: label, host: UUID().uuidString)
            print(
                "On \(profile.displayName) (iOS 27 or later, on this Mac's Wi‑Fi): Settings › Privacy & Security › Developer Mode › “\(listening.name)”."
            )
            let paired = try listening.accept {
                print("Enter this code there: \($0)")
            }
            let known = others.compactMap { o in
                o.udid.map {
                    (udid: $0, name: o.displayName)
                }
            }
            let verdict = DeviceControlHub.verdict(expected: profile.udid, paired: paired.udid, others: known)
            let withdraw = "Remove “\(listening.name)” on it, in that list."
            switch verdict {
            case .savedAs(let other): stop(
                    "\(paired.name) paired, which is saved here as “\(other)”, not “\(profile.displayName)”. Nothing was written. \(withdraw)"
                )
            case .nameless: stop(
                    "\(paired.name) paired without saying which device it is. Nothing was written. \(withdraw)"
                )
            case .another: stop(
                    "\(paired.name) paired, and it isn't “\(profile.displayName)” as that is saved here (another UDID). Nothing was written. \(withdraw)"
                )
            case .expected, .toProve: break
            }
            // Tried once from here: a pairing that connects nowhere isn't worth taking anywhere.
            let check = DeviceSession(
                ip: profile.providerIP,
                port: profile.remotePairingPort,
                pairing: {
                    paired.pairing
                }
            )
            defer { check.close() }
            var unreached: String?
            do { try check.connect() } catch { unreached = "\(error)" }
            if verdict == .toProve, let unreached {
                stop(
                    "\(paired.name) paired, but that pairing opens no connection to “\(profile.displayName)” at \(profile.providerIP) (\(unreached)). Nothing was written. \(withdraw)"
                )
            }
            var device = profile
            device.udid = Self.sharedUDID(saved: profile.udid, paired: paired.udid)
            let shared = SharedPairing(device: device, pairing: String(decoding: paired.pairing, as: UTF8.self))
            guard let data = try? JSONEncoder().encode(shared), Self.write(data, to: fd) else {
                stop("can't write \(out.path). \(withdraw)")
            }
            // Written to what was made at the start: if that name is another file's by now, the
            // pairing isn't where it is said to be.
            guard DeviceControlWire.names(out.path, theFileOf: fd) else {
                stop("\(out.path) was replaced while the pairing was made: the pairing isn't in it. \(withdraw)")
            }
            reserved = nil // done: an interrupt from here on leaves the file
            close(fd)
            print("Wrote \(out.path)" +
                (unreached.map {
                    " (it couldn't be tried from here: \($0))"
                } ?? ", and it connects."))
            print(
                "It is a key to \(profile.displayName): whoever has it and reaches \(profile.providerIP) can see and operate the device. On the other Mac: roamrun key import <that file>"
            )
            print("To withdraw it: remove “\(listening.name)” on the device, in that list.")
            exit(0)
        } catch {
            stop("\(error)")
        }
    }

    /// The file a pairing is being written to, for the handler that removes it when interrupted.
    nonisolated(unsafe) private static var reserved: (path: UnsafeMutablePointer<CChar>, fd: Int32)?

    /// Removes what was made for a pairing — that file, not whatever its name has come to be.
    /// Only what a signal handler may call.
    nonisolated static func removeReserved(_ path: UnsafePointer<CChar>, _ fd: Int32) {
        var held = stat(), named = stat()
        if fstat(fd, &held) == 0, lstat(path, &named) == 0, held.st_dev == named.st_dev,
           held.st_ino == named.st_ino
        {
            unlink(path)
        }
    }

    /// A new file of the owner's alone, or nothing: never one that is there, never through a link.
    nonisolated static func reserve(_ path: String) throws -> Int32 {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw ArgumentError(message: errno == EEXIST ? "\(path) exists: name a file that doesn't" :
                "can't make \(path): \(String(cString: strerror(errno)))")
        }
        return fd
    }

    nonisolated static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            var done = 0
            while done < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress! + done, bytes.count - done)
                if n <= 0 {
                    return false
                }
                done += n
            }
            return true
        }
    }

    /// The UDID a pairing travels under: the paired device's own, which is what it was proved
    /// with — in the saved one's spelling when that is the same device, and the saved one only
    /// when the device named none.
    nonisolated static func sharedUDID(saved: String?, paired: String) -> String? {
        guard !paired.isEmpty else { return saved }
        if let saved, saved.caseInsensitiveCompare(paired) == .orderedSame {
            return saved
        }
        return paired
    }

    static func importPairing(file: String, name: String?) -> Never {
        let path = URL(fileURLWithPath: file).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else { fail("\(path) doesn't exist") }
        let r = askApp(.init(op: "import", device: UUID(), path: path, text: name))
        // Not taken in, the file is where it was — and what it was.
        guard r.ok
        else {
            stop(
                "import failed: \(r.error ?? "no answer")\n\(path) was left as it is: a pairing in it is still a key to the device."
            )
        }
        print("\(r.name ?? "The device") is saved with its pairing." +
            (r.error == nil ? " Try: roamrun look \(r.name.map(shellName) ?? "<name>")" : ""))
        // An app from before it said so says it by saying nothing else.
        if r.removed == true || (r.removed == nil && r.error == nil) {
            print("\(path) is removed.")
        }
        // Said as it is: a key left where it was is not one that is gone, and a device not switched on isn't usable yet.
        if let more = r.error {
            FileHandle.standardError.write(Data("roamrun: \(more)\n".utf8))
            exit(1)
        }
        exit(0)
    }

    /// A look takes a file's place whole, or none: a folder of that name is left as it is (it was
    /// removed with what it held), and so is the file there when the write fails.
    nonisolated static func put(look made: URL, at file: URL) throws {
        defer { try? FileManager.default.removeItem(at: made) }
        var folder: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &folder), folder.boolValue {
            throw ArgumentError(message: "it is a folder")
        }
        // A screen, with whatever was on it: the owner's alone before it is in its place, not after.
        let data = try Data(contentsOf: made)
        let beside = file.deletingLastPathComponent().appendingPathComponent(".roamrun-look-\(UUID().uuidString)")
        let fd = try reserve(beside.path)
        var failed = write(data, to: fd) ? nil : errno
        close(fd)
        if failed == nil, rename(beside.path, file.path) != 0 {
            failed = errno
        }
        if let failed {
            unlink(beside.path)
            throw ArgumentError(message: String(cString: strerror(failed)))
        }
    }

    static func askApp(_ request: DeviceControlWire.Request) -> DeviceControlWire.Response {
        do {
            return try DeviceControlWire.ask(request, in: ProfileStore.directory)
        } catch DeviceControlWire.WireError.noApp {
            stop(
                "the RoamRun app isn't running (or is a build without device control): it holds the connection to the device"
            )
        } catch {
            stop("couldn't ask the RoamRun app: \(error)")
        }
    }

    /// The device's screen now, as PNG. Prints the path, then the size a tap's point is in.
    static func look(_ profile: DeviceProfile, path: String?) -> Never {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let file = URL(fileURLWithPath: path ?? "\(fileSafe(profile.displayName))-look-\(f.string(from: .now)).png")
            .standardizedFileURL
        guard file.pathExtension.lowercased() == "png" else { fail("the file must end in .png") }
        // The app writes it where only RoamRun keeps things; it is this command, run by the user in
        // their own folder, that puts it there (the app would be asked for access to it instead).
        let made = DeviceControlWire.socketFolder(in: ProfileStore.directory)
            .appendingPathComponent("look-\(UUID().uuidString).png")
        let r = askApp(.init(op: "look", device: profile.id, path: made.path))
        guard r.ok, let w = r.width, let h = r.height else { stop("look failed: \(r.error ?? "no answer")") }
        do { try put(look: made, at: file) } catch {
            stop(
                "look failed: can't write \(file.path) (\((error as? ArgumentError)?.message ?? error.localizedDescription))"
            )
        }
        print(file.path)
        print("\(w) x \(h)")
        // Which look this is: given with --look, an action is held to it.
        if let id = r.look {
            print("look \(id)")
        }
        exit(0)
    }

    /// `--look <n>`: the look an action is held to; none, the last one, whoever looked.
    static func lookGiven(_ parsed: Parsed) -> Int? {
        guard let given = parsed.values["--look"] else { return nil }
        guard let n = Int(given), n >= 0 else { fail("--look takes the number a look printed (\"look <n>\")") }
        return n
    }

    /// Something done to the device: silent when it went (but see `typed`), the reason when it didn't.
    static func operate(_ request: DeviceControlWire.Request) -> Never {
        // Held to a look: an app older than this doesn't hold to it, and isn't sent it.
        if request.look != nil, DeviceMCP.older(askApp(.init(op: "rules", device: request.device))) {
            stop("\(request.op) failed: \(DeviceMCP.olderApp)")
        }
        let r = askApp(request)
        guard r.ok else { stop("\(request.op) failed: \(r.error ?? "no answer")") }
        if request.op == "type", let note = request.text.flatMap(DeviceControlWire.typed) {
            print(note)
        }
        exit(0)
    }

    /// Accessibility's captions, one a line. Can scroll the screen.
    static func elements(_ profile: DeviceProfile, limit: Int?) -> Never {
        let r = askApp(.init(op: "elements", device: profile.id, limit: limit))
        guard r.ok, let captions = r.captions else { stop("elements failed: \(r.error ?? "no answer")") }
        captions.forEach {
            print($0)
        }
        if r.complete != true {
            FileHandle.standardError
                .write(Data("roamrun: \(captions.count) elements; the walk was cut short, there may be more\n".utf8))
        }
        exit(0)
    }

    static func screenshot(_ profile: DeviceProfile, path: String?) -> Never {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: .now)
        let file = URL(fileURLWithPath: path ?? "\(fileSafe(profile.displayName))-\(stamp).png").standardizedFileURL
        guard file.pathExtension.lowercased() == "png" else { fail("the file must end in .png") }
        let udid = reachableUDID(profile)
        let capture = [
            "devicectl",
            "--quiet",
            "device",
            "capture",
            "screenshot",
            "--device",
            udid,
            "--destination",
            file.path
        ]
        var r = Proc.run("/usr/bin/xcrun", capture, timeout: 60)
        if r.status != 0, r.err.contains("CoreDeviceError") { // e.g. the ~42s control-channel rebuild: once more
            sleep(2)
            r = Proc.run("/usr/bin/xcrun", capture, timeout: 60)
        }
        guard r.status == 0, FileManager.default.fileExists(atPath: file.path) else {
            stop("screenshot failed: " +
                (r.err.split(separator: "\n").first.map(String.init) ?? "devicectl exited \(r.status)"))
        }
        print(file.path)
        exit(0)
    }
}
