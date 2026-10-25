import CryptoKit
import DeviceControl
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// Where a pairing made elsewhere goes among the saved devices: nothing is saved by working it out.
struct DevicePlacement: Equatable {
    /// The saved device it is for, or the one to add (as the other Mac saved it: here it was
    /// never seen on the network to be added from).
    var profile: DeviceProfile
    var isNew: Bool
}

extension Array where Element == DeviceProfile {
    func placement(of device: DeviceProfile, udid: String,
                   as name: String?) -> Result<DevicePlacement, DeviceControlWire.WireError>
    {
        func same(_ p: DeviceProfile) -> Bool {
            if let known = p.udid {
                return known.caseInsensitiveCompare(udid) == .orderedSame
            }
            return p.providerIP == device.providerIP || p.instanceName == device.instanceName
        }
        if let saved = first(where: same) {
            return .success(.init(profile: saved, isNew: false))
        }
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
    func install(_ path: String) throws
    func launch(_ bundle: String) throws -> Int
}

extension DeviceSession: ControlledDevice {}

extension ControlledDevice {
    var isAnother: Bool {
        false
    }

    func interrupt() {}
    func gate(_ mayBegin: @escaping @Sendable () -> Bool) {}
    func install(_ path: String) throws {
        throw DeviceSession.Failure.invalid("this device can't install")
    }

    func launch(_ bundle: String) throws -> Int {
        throw DeviceSession.Failure.invalid("this device can't launch")
    }
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
            ip == other.ip && port == other.port && udid
                .caseInsensitiveCompare(other.udid) == .orderedSame // a UDID is one, however it is spelled
        }
    }

    /// One device as it is held: its session, and what belongs to that session alone. A session
    /// replaced (another port, a new pairing) gets a new one of these, so that what was seen or
    /// done through the old session never counts for the new.
    private final class Held: @unchecked Sendable {
        /// Under the hub's lock (a rename changes it while the session stays).
        var target: Target
        let session: any ControlledDevice
        /// The device's latest look: its size, which a tap's pixels are of, which look it was, when, and
        /// whether a tap, swipe or text went by it already — then no other tap or swipe does (what it
        /// saw may have moved), while text still may (look, tap a field, type). (This and `acted`
        /// under the device's gate.)
        var looked: (width: Int, height: Int, id: Int, at: Date, spent: Bool)?
        /// When the last input ended: a look, or text, right after it waits for the screen to settle.
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

    /// An install: its id, what is installed (its bundle identifier, else its file's name), its size, the seconds
    /// it is given, when it began, and how it ended — nil while it goes on, else why it failed (nil: it didn't) and how long it took.
    struct Install {
        var id: String
        var what: String
        var bundle: String?
        var megabytes: Int
        var seconds: Int
        var began: Date
        var ended: (failed: String?, took: TimeInterval)?
        /// The folder of its own the app was left in, removed when it ends.
        var folder = ""
    }

    /// Whether an install not ended yet, on any device, is installing from `folder`.
    private func installing(from folder: String) -> Bool {
        lock.withLock {
            installs.values.contains {
                $0.contains {
                    $0.ended == nil && $0.folder == folder
                }
            }
        }
    }

    typealias Opener = @Sendable (
        _ target: Target,
        _ pairing: @escaping @Sendable () throws -> Data,
        _ said: @escaping @Sendable (String) -> Void
    ) -> any ControlledDevice
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
    /// Each device's installs, the latest last, `pastInstalls` at most: kept by the device, not its session, which an
    /// install outlives when the session is replaced (under the hub's lock).
    private var installs: [UUID: [Install]] = [:]
    static let pastInstalls = 16
    private var listener: DeviceControlWire.Listener?
    private var timer: DispatchSourceTimer?
    /// The last update's, for when a pairing is made or removed in between.
    private var targets: [Target] = []
    private var pairing: (any PairingListener)?
    /// Makes the listener a device pairs with; tests give a stand-in.
    var listening: @Sendable (_ name: String, _ host: String) throws -> any PairingListener = {
        try DevicePairing(name: $0, host: $1)
    }

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
    private var looks = Int.random(in: 0 ..< 1_000_000_000)
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
    var onIntroduction: (@Sendable (DeviceControlWire.Request) -> DeviceControlWire.Response)?
    /// One pairing at a time, however it was begun: two under this Mac's one identity would each
    /// undo the other on the device. A pairing another Mac introduces takes the same turn Set Up does.
    func claimPairing(_ attempt: UUID) -> Bool {
        lock.withLock {
            guard pairingUnderWay == nil else { return false }
            pairingUnderWay = attempt
            return true
        }
    }

    func releasePairing(_ attempt: UUID) {
        lock.withLock {
            if pairingUnderWay == attempt {
                pairingUnderWay = nil
            }
        }
    }

    /// The key pairings are sealed with is at hand, or why it isn't: asked before a device is.
    func keyReady() throws {
        _ = try key(true)
    }

    /// Whether commands and agents may use a pairing, named by its mark (a session's `Held.mark`):
    /// the device's switch in the app. Asked at every request, off the main thread.
    var allowed: @Sendable (String) -> Bool = { _ in
        true
    }

    /// The sessions that stand may have changed (and every half minute): `heldMarks` is what the
    /// switch may keep. Not to wait in, and asked for the marks when it acts, not now.
    var onHeldChanged: (@Sendable () -> Void)?
    /// A saved pairing was written over: its mark, for the switch to drop. Not to wait in.
    var onReplaced: (@Sendable (String) -> Void)?
    /// The Keychain didn't give the list of what is on: said with how a device stands, apart from a switch that is off.
    var allowedUnreadable: @Sendable () -> Bool = {
        false
    }

    /// The same as far as it is known without waiting, for saying how a device stands.
    var allowedKnown: @Sendable (String) -> Bool? = { _ in
        true
    }

    /// What the pairing saved under `udid` is known by to the switch (`DeviceControlWire.mark`);
    /// nil where none is saved, or what is there is no pairing's file.
    static func pairingMark(udid: String, in directory: URL) -> String? {
        guard let sealed = DeviceControlWire.sealedBytes(DeviceControlWire.pairingFile(udid: udid, in: directory)),
              !sealed.isEmpty else { return nil }
        return DeviceControlWire.mark(of: sealed, udid: udid)
    }

    /// The marks the sessions that stand connect with: what the switch may keep. A pairing no
    /// session holds (its file moved away, its device gone from the list, another put in its
    /// place) loses its switch — it isn't found on when it is brought back.
    /// nil once this was stopped: at the end nothing is held, and that isn't what the switch goes by.
    func heldMarks() -> Set<String>? {
        lock.withLock {
            stopped ? nil : Set(held.values.map(\.mark))
        }
    }

    /// Whether the pairing saved for `udid` is another than `mark` by now (or gone). nil: it
    /// couldn't be read just now, and isn't taken for changed.
    private func pairingChanged(from mark: String, udid: String) -> Bool? {
        let read = DeviceControlWire.sealedRead(DeviceControlWire.pairingFile(udid: udid, in: directory))
        guard read.known else { return nil }
        return read.bytes.flatMap {
            $0.isEmpty ? nil : DeviceControlWire.mark(of: $0, udid: udid)
        } != mark
    }

    /// The call a device is busy with stops where it can: its switch was turned off.
    func interrupt(_ id: UUID) {
        session(of: id)?.interrupt()
    }

    /// Runs `body`, and calls `stop` if it is no longer wanted meanwhile (its asker left, its
    /// device was switched off) — again and again for as long as that is so: the call may only now be about to begin, and
    /// begins by taking back a stop that was asked before it.
    static func whileWanted<T>(
        _ wanted: @escaping @Sendable () -> Bool,
        else stop: @escaping @Sendable () -> Void,
        _ body: () throws -> T
    ) rethrows -> T {
        let done = DispatchSemaphore(value: 0), ended = DispatchSemaphore(value: 0)
        // A thread of its own: on a queue shared with everything else it may not get to run
        // while they are all busy, and the call waits for it at its end.
        Thread.detachNewThread {
            while done.wait(timeout: .now() + 0.3) == .timedOut {
                if !wanted() {
                    stop()
                }
            }
            ended.signal()
        }
        defer { done.signal()
            ended.wait()
        } // not left asking about an asker whose connection is closed
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
            let saved = Dictionary(targets.map {
                ($0.id, $0)
            }, uniquingKeysWith: { a, _ in
                a
            })
            for (id, h) in held {
                // A device renamed keeps its connection (away from Wi‑Fi no new one could be made);
                // one moved to another address, removed or unpaired doesn't.
                // …nor one whose saved pairing is another than its session's by now.
                if let t = saved[id], t.reaches(h.target), !unremovedLock.withLock({
                       unremoved.contains(t.udid.lowercased())
                   }),
                   pairingChanged(from: h.mark, udid: t.udid) != true
                {
                    held[id]?.target = t
                } else {
                    gone.append(h.session)
                    held[id] = nil
                }
            }
            for t in targets where held[t.id] == nil {
                if let (session, mark) = session(for: t) {
                    held[t.id] = Held(target: t, session: session, mark: mark)
                }
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
        !unremovedLock.withLock({
            unremoved.contains(udid.lowercased())
        }) && DeviceControlWire.hasPairing(udid: udid, in: directory)
    }

    /// The session held for a device, if any.
    func session(of id: UUID) -> (any ControlledDevice)? {
        lock.withLock {
            held[id]?.session
        }
    }

    /// Closing waits for a call that runs on the session, which can take long: never on the
    /// caller's thread (the main one, when the list is saved).
    private static func closing(_ sessions: [any ControlledDevice]) {
        guard !sessions.isEmpty else { return }
        // Told at once that nothing more is to begin; the closing itself waits for what runs.
        sessions.forEach {
            $0.letGo()
        }
        DispatchQueue.global(qos: .utility).async {
            sessions.forEach {
                $0.close()
            }
        }
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
    func isAnother(_ id: UUID) -> Bool {
        session(of: id)?.isAnother == true
    }

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
        func same(_ a: String, _ b: String) -> Bool {
            a.caseInsensitiveCompare(b) == .orderedSame
        }
        if let expected, same(expected, paired) {
            return .expected
        }
        if let other = others.first(where: {
            same($0.udid, paired)
        }) {
            return .savedAs(other.name)
        }
        if expected == nil, paired.isEmpty {
            return .nameless
        }
        if expected != nil, !paired.isEmpty {
            return .another
        }
        return .toProve
    }

    /// Lets the device pair with this Mac (iOS 27 and later, on the same network), one at a time.
    /// The new pairing replaces the saved one when the device is the one asked for, or — its
    /// UDID not known here — once it opened a connection of its own.
    /// `attempt` names this pairing for `cancelPairing`. Cancelled before its pairing is saved,
    /// nothing is saved; cancelled after and before `.done` is said, what was saved is removed.
    func pair(
        _ device: PairingRequest,
        as name: String,
        attempt: UUID = UUID(),
        step: @escaping @Sendable (PairingStep) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // Taken before anything is advertised: two of these would name themselves alike.
            let free = lock.withLock { () -> Bool in
                guard pairingUnderWay == nil else { return false }
                pairingUnderWay = attempt
                return true
            }
            guard free else {
                lock.withLock {
                    _ = pairingsCancelled.remove(attempt)
                }
                return step(.failed("Another pairing is under way."))
            }
            defer { lock.withLock {
                pairing = nil
                pairingUnderWay = nil
                pairingKept = nil
                pairingsCancelled.remove(attempt)
            } }
            do {
                // Before the device is asked anything: once it pairs it knows no older pairing of
                // ours, and a Keychain that then refuses would leave it with none this Mac holds.
                // And that key is the one it is sealed with: asked for again after the pairing,
                // the Keychain could refuse then.
                let sealing = try key(true)
                let listening = try self.listening(name, Self.hostID(in: directory))
                // A cancel that came before there was anything to cancel still counts.
                if lock.withLock({ () -> Bool in
                    pairing = listening
                    return pairingsCancelled.contains(attempt)
                }) {
                    listening.cancel()
                }
                step(.waiting(listening.name))
                let paired = try listening.accept {
                    step(.code($0))
                }
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
                    throw DeviceSession.Failure
                        .message("\(paired.name) paired and gave what isn't a UDID. Nothing was saved.")
                }
                switch Self.verdict(expected: device.udid, paired: paired.udid, others: device.others) {
                case .expected: break
                case .savedAs(let other):
                    throw DeviceSession.Failure
                        .message(
                            "\(paired.name) paired, which is saved here as “\(other)”, not “\(device.name)”. Nothing was saved, and its earlier pairing with this Mac no longer works: set device control up again on “\(other)”."
                        )
                case .nameless:
                    throw DeviceSession.Failure
                        .message("\(paired.name) paired without saying which device it is. Nothing was saved.")
                case .another:
                    throw DeviceSession.Failure
                        .message(
                            "\(paired.name) paired, and it isn't “\(device.name)” as that is saved here (another UDID). Nothing was saved, and what was saved for “\(device.name)” is as it was; the pairing just made can be removed on \(paired.name), in Settings. If “\(device.name)” is that device now, remove it here and add it again."
                        )
                case .toProve:
                    let check = DeviceSession(ip: device.ip, port: device.port, pairing: {
                        paired.pairing
                    })
                    defer { check.close() }
                    do { try check.connect() } catch {
                        let port = "\(error)".hasPrefix("RemotePairing port: Connection refused")
                            ? " The device answered but not on port \(device.port): Technical details › Find RemotePairing Port, then set up again."
                            : " Is its VPN on?"
                        throw DeviceSession.Failure
                            .message(
                                "\(paired.name) paired, but that pairing opens no connection to “\(device.name)” at \(device.ip) (\(error)).\(port) Nothing was saved; if it was another device, its pairing with this Mac can be removed there, in Settings."
                            )
                    }
                }
                // Named by the UDID the device is saved under, as it is spelled there; or by its own.
                let udid = device.udid ?? paired.udid
                let target = Target(id: device.id, name: device.name, ip: device.ip, port: device.port, udid: udid)
                // Saved, or cancelled: whichever came first, under the one lock. Held from now on,
                // also when the list of saved devices doesn't have its UDID yet.
                try lock.withLock {
                    guard !pairingsCancelled.contains(attempt)
                    else { throw DeviceSession.Failure.message(Self.pairingCancelled) }
                    // The mark of what was written, not of what is there a moment later.
                    let mark = try sealPairing(paired.pairing, with: sealing, udid: udid)
                    pairingKept = (udid, device.id, mark)
                    if !targets.contains(where: {
                        $0.id == target.id
                    }) {
                        targets.append(target)
                    }
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
        let check = open(target, {
            pairing
        }) { _ in }
        defer { check.close() }
        do { try check.connect() } catch {
            throw DeviceSession.Failure
                .message(
                    "this pairing opens no connection to “\(target.name)” at \(target.ip) (\(error)). Nothing was saved."
                )
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
        if let before, before != mark {
            onReplaced?(before)
        }
        return mark
    }

    /// The mark of the pairing this run last sealed under `udid`, as it wrote it.
    func sealedMark(udid: String) -> String? {
        unremovedLock.withLock {
            sealedMarks[udid.lowercased()]
        }
    }

    /// The mark of the pairing the device's session connects with: what its switch is about.
    func mark(of id: UUID) -> String? {
        lock.withLock {
            held[id]?.mark
        }
    }

    /// And held from now on, connected when this returns.
    func hold(_ target: Target) {
        lock.withLock {
            targets.removeAll {
                $0.id == target.id
            }
            targets.append(target)
        }
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
            throw DeviceSession.Failure
                .message(errno == ELOOP ? "\(path) is a link: give the file itself" :
                    "can't read \(path): \(String(cString: strerror(errno)))")
        }
        var s = stat()
        let why: String? = fstat(fd, &s) != 0 || s.st_mode & S_IFMT != S_IFREG ? "\(path) isn't a file"
            : s.st_nlink != 1 ? "\(path) has another name too (a hard link): the pairing would stay under it"
            : s.st_size >= 1 << 20 ? "\(path) isn't a pairing made by `roamrun key create`" : nil
        if let why {
            close(fd)
            throw DeviceSession.Failure.message(why)
        }
        var data = Data(count: Int(s.st_size))
        let got = data.withUnsafeMutableBytes {
            pread(fd, $0.baseAddress, $0.count, 0)
        }
        guard got == data.count else {
            close(fd)
            throw DeviceSession.Failure.message("can't read \(path)")
        }
        return (fd, data)
    }

    /// The file a pairing was read from is removed once it is taken in. nil when it is gone; else
    /// what to tell whoever brought it: it is still a key to the device.
    static func removeTaken(_ file: URL, readThrough fd: Int32, remove: (URL) throws -> Void = {
        try FileManager.default.removeItem(at: $0)
    }) -> String? {
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
        lock.withLock {
            targets.removeAll {
                $0.id == id && $0.udid.caseInsensitiveCompare(udid) == .orderedSame
            }
        }
        reopen(id)
    }

    /// What a device knows this Mac by: made once and kept with the pairings, so a Mac renamed
    /// stays the one it was, and two of one name stay two.
    static func hostID(in directory: URL) -> String {
        let file = directory.appendingPathComponent("device-control-host")
        if let saved = try? String(contentsOf: file, encoding: .utf8), UUID(uuidString: saved) != nil {
            return saved
        }
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
            throw DeviceSession.Failure
                .message("the saved pairing can't be read with this Mac's key: set device control up again")
        }
    }

    /// Puts a new pairing in the saved one's place: written beside it (its owner's only), then
    /// moved, so a write that fails leaves what was there. The one it replaces is of no use any
    /// more (the device knows this Mac by one identity, and now by the new key).
    static func save(_ sealed: Data, as file: URL) throws {
        // A name of its own: two savings for one device at the same instant (one brought in, one
        // set up) each rename their own bytes, and each knows the mark of what it wrote.
        let beside = file.appendingPathExtension("writing-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: beside.path,
            contents: sealed,
            attributes: [.posixPermissions: 0o600]
        ),
            rename(beside.path, file.path) == 0
        else {
            let why = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: beside)
            throw DeviceSession.Failure.message("can't save the pairing: \(why)")
        }
        try? FileManager.default.removeItem(at: unsealed(of: file))
    }

    /// Where a build before the pairings were sealed kept this one, as it was.
    static func unsealed(of file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension("plist")
    }

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
        unremovedLock.withLock {
            if dropped == .left {
                unremoved.insert(udid.lowercased())
            } else {
                unremoved.remove(udid.lowercased())
            }
        }
        switch dropped {
        case .removed: break
        case .emptied: onLog?(
                "device control: the pairing's file couldn't be removed (\(file.path)); it was emptied, and holds no pairing any more",
                id
            )
        case .left: onLog?(
                "device control: the pairing's file couldn't be removed or emptied and still holds the pairing (\(file.path)). It is out of use until RoamRun is opened again: delete the file, or unpair on the device",
                id
            )
        }
        return dropped
    }

    /// Pairings a build before the sealing kept as they were, and what it kept of older ones:
    /// each holds a private key the device may still take, and nothing reads them any more.
    /// And what a saving left half-done (a run that ended in the middle of one).
    static func removeUnsealed(in directory: URL) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            where name
            .hasPrefix("device-pairing-") &&
            (name.hasSuffix(".plist") || name.hasSuffix(".plist.previous") || name.contains(".sealed.writing"))
        {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    func cancelPairing(_ attempt: UUID) {
        let (listening, kept) = lock.withLock { () -> (
            (any PairingListener)?,
            (udid: String, id: UUID, mark: String?)?
        ) in
            pairingsCancelled.insert(attempt)
            guard pairingUnderWay == attempt else { return (nil, nil) }
            defer { pairingKept = nil }
            return (pairing, pairingKept)
        }
        listening?.cancel()
        // Saved already, and not yet said to be: it goes now, not when the attempt comes round to it.
        // …if it is still what is saved: a pairing brought in over it meanwhile is not this attempt's to remove.
        if let kept, Self.pairingMark(udid: kept.udid, in: directory) == kept.mark {
            forgetPairing(
                udid: kept.udid,
                of: kept.id
            )
        }
    }

    /// Forgets this Mac's pairing with the device (the device's record of it stays, in its Settings).
    @discardableResult
    func unpair(_ target: Target) -> Dropped {
        let dropped = drop(udid: target.udid, of: target.id)
        reopen(target.id)
        if dropped == .removed {
            onLog?("device control: pairing removed", target.id)
        }
        return dropped
    }

    /// The device's session made anew from what is saved now. The new one is in place before
    /// the old one is closed: in between, the device would answer as not set up.
    private func reopen(_ id: UUID) {
        let old = lock.withLock { () -> (any ControlledDevice)? in
            let old = held.removeValue(forKey: id)?.session
            if let t = targets.first(where: {
                $0.id == id
            }), let (session, mark) = session(for: t) {
                held[id] = Held(target: t, session: session, mark: mark)
            }
            return old
        }
        Self.closing(old.map {
            [$0]
        } ?? [])
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
                throw DeviceSession.Failure
                    .message("\(DeviceSession.stopped) the pairing saved for this device couldn't be read just now")
            }
            guard let sealed = read.bytes, DeviceControlWire.mark(of: sealed, udid: t.udid) == mark else {
                throw DeviceSession.Failure
                    .message(
                        "\(DeviceSession.stopped) the pairing saved for this device changed: its connection is made anew"
                    )
            }
            return try Self.unseal(sealed, with: key(false))
        }) { [weak self] event in
            self?.onLog?("device control: \(event)", t.id)
        }
        // Asked again when a call gets its turn on the session: switched off while it waited, it isn't begun.
        session.gate { [weak self] in
            self?.allowed(mark) ?? false
        }
        return (session, mark)
    }

    func start() {
        Self.removeUnsealed(in: directory)
        listen()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.listen() // not had at the start (another copy was ending): had now
            self?.renewChanged()
            self?.checkOpen()
            self?.keepOpen()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        // A pairing saved and not yet said to be done is nobody's once this ends.
        if let attempt = lock.withLock({
            pairingUnderWay
        }) {
            cancelPairing(attempt)
        }
        timer?.cancel()
        listener?.stop()
        let sessions = lock.withLock { () -> [any ControlledDevice] in
            defer { held = [:] }
            stopped = true
            return held.values.map(\.session)
        }
        // Each is told to end its stream, but quitting doesn't wait on a device that no longer answers.
        let group = DispatchGroup()
        for session in sessions {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                session.close()
            }
        }
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
            held.filter {
                pairingChanged(from: $0.value.mark, udid: $0.value.target.udid) == true
            }
            .map(\.key)
            + targets.filter {
                held[$0.id] == nil && hasPairing($0)
            }
            .map(\.id)
        }
        changed.forEach(reopen)
        onHeldChanged?() // also when nothing changed: the chance to write what a write failed to
    }

    /// How often a connection that stands is asked whether it still does: a device restarted, or
    /// its pairing removed on it, otherwise reads as connected until the next call finds out.
    var checkEvery: TimeInterval = 60

    /// Asks each connection that stands and is due; one found gone is opened anew at once.
    func checkOpen() {
        let now = Date()
        let due = lock.withLock { () -> [any ControlledDevice] in
            let due = held.filter {
                $0.value.session.isOpen && now.timeIntervalSince($0.value.checked) >= checkEvery
            }
            for id in due.keys {
                held[id]?.checked = now
            }
            return due.map(\.value.session)
        }
        for session in due {
            // A thread of its own: the shared queue's can all be taken by calls that wait on a device.
            Thread.detachNewThread { [self] in
                session.check()
                if !session.isOpen {
                    keepOpen()
                }
            }
        }
    }

    /// Tries to open what isn't: one attempt per device at a time; none for a pairing the device
    /// refused or this Mac can't read (only pairing again helps, and that makes a new session).
    private func keepOpen() {
        let now = Date()
        let due = lock.withLock { () -> [(UUID, any ControlledDevice)] in
            let due = held.filter {
                !$0.value.connecting && $0.value.nextTry <= now && !$0.value.session.isOpen && !$0.value.session
                    .isRefused
            }
            for id in due.keys {
                held[id]?.connecting = true
            }
            return due.map {
                ($0.key, $0.value.session)
            }
        }
        for (id, session) in due {
            DispatchQueue.global(qos: .utility).async { [self] in
                var failure: String?
                do { try session.connect() } catch { failure = "\(error)" }
                lock.withLock {
                    guard held[id]?.session === session else { return } // replaced meanwhile
                    let failures = failure == nil ? 0 : (held[id]?.failures ?? 0) + 1
                    held[id]?.connecting = false
                    held[id]?.failures = failures
                    held[id]?.nextTry = failure == nil ? .distantPast : Date()
                        .addingTimeInterval(Self.retryDelay(afterFailures: failures))
                }
                if let failure {
                    onUnreached?(id, failure)
                } else {
                    onReached?(id)
                }
            }
        }
    }

    /// A point given in a look's pixels, as fractions of the screen; nil when outside it.
    static func fraction(x: Double?, y: Double?, of size: (width: Int, height: Int)) -> (x: Double, y: Double)? {
        guard let x, let y, (0 ..< Double(size.width)).contains(x),
              (0 ..< Double(size.height)).contains(y) else { return nil }
        return (x / Double(size.width), y / Double(size.height))
    }

    // ponytail: a fixed wait, enough for a transition or a scroll coming to rest. Comparing
    // frames until they stop changing, if it proves short (a playing video never stops).
    static let settle: TimeInterval = 1
    /// The same, for this hub (a test gives less). Keys sent at once after a tap on a field were
    /// seen lost, or put before the cursor (iOS 27.0, a Japanese keyboard): text waits it out too.
    var settling = DeviceControlHub.settle

    /// How long a look, or text, still has to wait after the last input.
    static func settleWait(acted: Date?, now: Date = Date(),
                           settle: TimeInterval = DeviceControlHub.settle) -> TimeInterval
    {
        guard let acted else { return 0 }
        return min(settle, max(0, settle - now.timeIntervalSince(acted)))
    }

    /// The look rules this app holds to, said by "rules": 2, a look's id held to by text too, and a
    /// look spent by a tap still good for text. `roamrun mcp` refuses an app that says fewer.
    static let rules = 2

    /// What a `type` sent (debug level), never the text itself: tells a key the device dropped
    /// from one that wasn't sent.
    private static let inputLog = Logger(subsystem: AppID.bundle, category: "input")

    /// How many elements a walk is asked for: whatever number a caller sends, one the walk can do.
    static func elementLimit(_ asked: Int?) -> Int {
        min(max(asked ?? 40, 1), 1000)
    }

    /// A swipe's duration, or nil for one the device isn't asked for (the library takes 50...5000 ms).
    static func swipeDuration(_ asked: Int?) -> Int? {
        guard let asked else { return 300 }
        return (50 ... 5000).contains(asked) ? asked : nil
    }

    static func isLookFile(_ path: String, in directory: URL) -> Bool {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        return file.deletingLastPathComponent().path == DeviceControlWire.socketFolder(in: directory)
            .standardizedFileURL
            .path
            && file.lastPathComponent.hasPrefix("look-") && file.pathExtension == "png"
    }

    /// An app to install as the CLI leaves it for the app: an .ipa or an .app folder, under its own name (an .app is
    /// staged on the device by that name, and what a cut-short install of it left is cleared), in a folder install-… of
    /// its own in the folder looks are; neither of them a link to something elsewhere. Its path as it was checked, which
    /// is what is used: `..` in what was given could lead elsewhere through a link.
    static func installFile(_ path: String, in directory: URL) -> String? {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let own = file.deletingLastPathComponent()
        var info = stat(), folder = stat()
        guard own.deletingLastPathComponent().path == DeviceControlWire.socketFolder(in: directory)
            .standardizedFileURL
            .path, own.lastPathComponent.hasPrefix("install-"), ["ipa", "app"].contains(file.pathExtension),
            lstat(own.path, &folder) == 0, folder.st_mode & S_IFMT == S_IFDIR,
            lstat(file.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { return nil }
        return file.path
    }

    static func begun(_ install: Install, on name: String) -> String {
        "installing \(install.what) (\(install.megabytes) MB) on \(name) began (install \(install.id)): ask install_status with that id now and then — a megabyte takes a few seconds, and \(install.seconds) s are given. Until it ends, other calls on \(name) answer that it is installing"
    }

    static func installing(_ install: Install, on name: String) -> String {
        "installing \(install.what) on \(name) (\(Int(Date().timeIntervalSince(install.began))) s so far): nothing else is done on it until that ends. install_status says how it goes"
    }

    /// How the device's latest install went; `asked`, that one, among its `pastInstalls` latest.
    static func installStatus(_ installs: [Install], asked: String?, on name: String) -> DeviceControlWire.Response {
        guard let install = asked.map({ asked in
            installs.last {
                $0.id == asked
            }
        }) ?? installs.last else {
            return asked == nil ? .init(ok: true, said: "no install was begun on \(name) since the RoamRun app started")
                : .failure(
                    "install \(asked ?? "") isn't one of \(name)'s here: how it ended isn't known (the RoamRun app was started again since, or \(pastInstalls) more were begun)"
                )
        }
        guard let ended = install.ended else { return .init(ok: true, said: installing(install, on: name)) }
        let took = Int(ended.took)
        if let failed = ended.failed {
            return .failure(
                "installing \(install.what) on \(name) failed after \(took) s (of the \(install.seconds) s it was given): \(failed)"
            )
        }
        return .init(
            ok: true,
            said: install.bundle == nil ? "\(install.what) is installed on \(name) (\(install.megabytes) MB in \(took) s)"
                : "\(install.what) is installed on \(name) (\(install.megabytes) MB in \(took) s): launch takes it by that bundle identifier"
        )
    }

    static let lookFirst = "look first: a point is given in the pixels of the image a look returns"
    static let nobodyWaits = "nobody is waiting for this any more"
    static let notGiven = "not given: whoever asked has left, or the device was switched off meanwhile"
    /// The longer side of a look, at most: what a model is shown without its being scaled once more.
    static let lookSide = 1280
    /// `image` with its longer side at most `lookSide`; itself when it is.
    static func fitted(_ image: CGImage) -> CGImage {
        let longer = max(image.width, image.height)
        guard longer > lookSide else { return image }
        let scale = CGFloat(lookSide) / CGFloat(longer)
        let width = Int((CGFloat(image.width) * scale).rounded()),
            height = Int((CGFloat(image.height) * scale).rounded())
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    static let lookOld = "that look is more than a minute old: look again"
    /// How long a look serves: whoever read a point off it took their time, and the screen its own course.
    var lookStands: TimeInterval = 60
    /// A point given with a look that isn't the device's latest.
    static func lookedSince(_ given: Int)
        -> String
    {
        "look again: look \(given) isn't the device's latest look (it was looked at again since)"
    }

    /// Text given with a look that isn't the device's latest, or after something else was done.
    static func notLatest(_ given: Int, _ op: String) -> String {
        "look again: look \(given) isn't the device's latest look, or something else was done since: nothing was \(op == "type" ? "typed" : "pasted")"
    }

    private func listen() {
        guard lock.withLock({
            listener == nil
        }) else { return }
        let made = DeviceControlWire.Listener(directory: directory, answering: { [weak self] request, wanted in
            self?.answer(request, wanted: wanted) ?? .failure("stopping")
        })
        lock.withLock {
            if listener == nil {
                listener = made
            } else {
                made?.stop()
            }
        }
    }

    /// `wanted`: whether whoever asked is still there. A request that waited its turn and whose
    /// asker has left meanwhile (interrupted, or tired of waiting) isn't begun.
    func answer(_ request: DeviceControlWire.Request, wanted: @escaping @Sendable () -> Bool = {
        true
    }) -> DeviceControlWire.Response {
        let answered = answering(request, wanted: wanted)
        // An install refused, wherever (the gate, the switch, an asker gone, the app's own check), leaves its app to
        // nobody: removed here. One begun is removed when it ends.
        if request.op == "install", !answered.ok, let path = request.path.flatMap({
            Self.installFile($0, in: directory)
        }) {
            // Not one an install is still taking it from (the same path asked for again).
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
            if !installing(from: folder) {
                try? FileManager.default.removeItem(atPath: folder)
            }
        }
        return answered
    }

    private func answering(_ request: DeviceControlWire.Request, wanted: @escaping @Sendable () -> Bool)
        -> DeviceControlWire.Response
    {
        let notSetUp = DeviceControlWire.Response
            .failure(
                "device control isn't set up for this device: the user sets it up in the RoamRun app, on the device's page"
            )
        if request.op == "import" {
            return onImport?(request.path ?? "", request.text, wanted) ??
                .failure("this RoamRun can't take a pairing in")
        }
        if request.op.hasPrefix("pair-") {
            return onIntroduction?(request) ?? .failure("this RoamRun can't be introduced to a device")
        }
        // Which rules a look is held to: asked before an action by `roamrun mcp`, of no device.
        if request.op == "rules" {
            return .init(ok: true, rules: Self.rules)
        }
        // How it stands is said at once, whatever runs on the device.
        if request.op == "state" {
            guard let h = lock.withLock({
                held[request.device]
            }) else { return notSetUp }
            // As far as it is known: how a device stands is said at once, and the Keychain may take its time.
            return .init(ok: true, open: h.session.isOpen, refused: h.session.isRefused, allowed: allowedKnown(h.mark),
                         another: h.session.isAnother ? true : nil, listUnreadable: allowedUnreadable() ? true : nil)
        }
        // How an install goes is said at once, whatever holds the device.
        if request.op == "install_status" {
            guard let (installs, name) = lock.withLock({
                held[request.device].map {
                    (self.installs[request.device] ?? [], $0.target.name)
                }
            }) else { return notSetUp }
            return Self.installStatus(installs, asked: request.install, on: name)
        }
        // Everything else one at a time per device, and whole: a look is checked, spent and acted
        // on without another command coming in between. The session is the one held once the
        // gate is had: a command that waited out another doesn't act on a session replaced
        // meanwhile. What it leaves (the look, the time of the input) stays on that session.
        let gate = lock.withLock { () -> NSLock? in
            if let gate = gates[request.device] {
                return gate
            }
            guard held[request.device] != nil else { return nil } // none kept for what any asker names
            let gate = NSLock()
            gates[request.device] = gate
            return gate
        }
        guard let gate else { return notSetUp }
        return gate.withLock {
            guard wanted() else { return .failure(Self.nobodyWaits) }
            guard let (h, name) = lock.withLock({
                held[request.device].map {
                    ($0, $0.target.name)
                }
            }) else { return notSetUp }
            // By the pairing the session connects with, whatever is saved under the device's name by now.
            let mark = h.mark
            guard allowed(mark) else { return .failure(Self.switchedOff) }
            // Wanted, for a call that takes its time: asked for by someone still there, of a
            // pairing still switched on (it was, a moment ago: it may be switched off meanwhile).
            let known = allowedKnown
            return perform(request, on: h, named: name, wanted: {
                wanted() && known(mark) != false
            })
        }
    }

    /// Under the device's gate.
    private func perform(
        _ request: DeviceControlWire.Request,
        on h: Held,
        named name: String,
        wanted: @escaping @Sendable () -> Bool
    ) -> DeviceControlWire.Response {
        // Failed or not, once begun: an input may have reached the device before the failure showed.
        // One refused for what it says, before anything was sent, isn't an input.
        var begun = false
        defer {
            if begun {
                h.acted = Date()
            }
        }
        /// What a look saw is no longer on the screen as it was: a press, the elements walked, another
        /// look, a failure once something was sent.
        func end() {
            h.looked = nil
        }
        /// A tap, swipe or text reached the device by the look it gave: no other tap or swipe goes by
        /// it; text still may. One that gave none is of no one's look: what the latest saw is gone.
        func went() {
            if request.look == nil {
                end()
            } else {
                h.looked?.spent = true
            }
        }
        /// Text, after the screen's moment: held to the look given (spent or not), when it is given.
        func held(to given: Int?) -> DeviceControlWire.Response? {
            Thread.sleep(forTimeInterval: Self.settleWait(acted: h.acted, settle: settling))
            guard wanted()
            else {
                return .failure(
                    "\(DeviceSession.stopped) whoever asked left, or the device was switched off, before it began"
                )
            }
            guard let given else { return nil } // by hand: whatever was looked at last
            guard let size = h.looked, size.id == given else { return .failure(Self.notLatest(given, request.op)) }
            guard Date().timeIntervalSince(size.at) <= lookStands else { end()
                return .failure(Self.lookOld)
            }
            return nil
        }
        /// The look a point is read against: one no tap or swipe went by yet, the one given, still good.
        func pointable() -> (Int, Int)? {
            guard let size = h.looked, !size.spent else { return nil }
            return (size.width, size.height)
        }
        // A call can wait for its connection, and a text takes its time: an asker who leaves
        // meanwhile has it stopped where it is, or not begun.
        let session = h.session
        // An install holds the device until it ends: nothing else is begun meanwhile.
        if let install = lock.withLock({
            installs[request.device]?.last
        }), install.ended == nil {
            return .failure(Self.installing(install, on: name))
        }
        do {
            switch request.op {
            case "install":
                guard let path = request.path.flatMap({
                    Self.installFile($0, in: directory)
                }) else {
                    return .failure("no app to install: it is given in RoamRun's own folder")
                }
                // Its folder goes with it once the install ends (refused, `answer` removes it).
                let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
                guard !installing(from: folder) else {
                    return .failure(
                        "that app is being installed already, from the same place: send it again for another install"
                    )
                }
                let app: (bundle: String?, megabytes: Int, seconds: Int)
                do { app = try DeviceSession.app(at: path) } catch {
                    return .failure("\(error)")
                }
                // Reached before it is said to have begun: a device asleep or away refuses it here, while whoever
                // sent the app can still try again with it.
                do { try session.connect() } catch {
                    return .failure("\(error)")
                }
                // What a look saw may move while the app is replaced.
                end()
                begun = true
                var bytes = [UInt8](repeating: 0, count: 4)
                arc4random_buf(&bytes, bytes.count)
                let install = Install(
                    id: bytes.map {
                        String(format: "%02x", $0)
                    }
                    .joined(),
                    what: app.bundle ?? URL(fileURLWithPath: path).lastPathComponent,
                    bundle: app.bundle,
                    megabytes: app.megabytes,
                    seconds: app.seconds,
                    began: Date(),
                    folder: folder
                )
                let device = request.device
                lock.withLock {
                    let kept = (installs[device] ?? []) + [install]
                    installs[device] = Array(kept.suffix(Self.pastInstalls))
                }
                Thread.detachNewThread { [weak self] in
                    var failed: String?
                    do { try session.install(path) } catch { failed = "\(error)" }
                    try? FileManager.default.removeItem(atPath: folder)
                    self?.lock.withLock {
                        if let at = self?.installs[device]?.lastIndex(where: {
                            $0.id == install.id
                        }) {
                            self?.installs[device]?[at].ended = (failed, Date().timeIntervalSince(install.began))
                        }
                    }
                }
                return .init(ok: true, install: install.id, said: Self.begun(install, on: name))
            case "launch":
                guard let bundle = request.text, !bundle.isEmpty else { return .failure("no bundle identifier") }
                end() // the app in front changes
                begun = true
                let pid = try Self.whileWanted(wanted, else: {
                    session.interrupt()
                }) {
                    try session.launch(bundle)
                }
                return .init(ok: true, pid: pid)
            case "elements":
                end() // the walk can scroll the screen
                begun = true
                let walked = h.session
                let limit = Self.elementLimit(request.limit)
                let found = try Self.whileWanted(wanted, else: {
                    walked.interrupt()
                }) {
                    try walked.elements(limit: limit)
                }
                return .init(ok: true, captions: found.captions, complete: found.complete)
            case "swipe":
                // A request refused for what it says leaves the look to be used: it is spent by what reaches the device.
                guard pointable() != nil, let size = h.looked else { return .failure(Self.lookFirst) }
                guard request.look ?? size.id == size.id
                else { return .failure(Self.lookedSince(request.look ?? size.id)) }
                guard Date().timeIntervalSince(size.at) <= lookStands else { end()
                    return .failure(Self.lookOld)
                }
                guard let from = Self.fraction(x: request.x, y: request.y, of: (size.width, size.height)),
                      let to = Self.fraction(x: request.x2, y: request.y2, of: (size.width, size.height))
                else {
                    return .failure("the point must be inside the image (\(size.width) x \(size.height))")
                }
                guard let duration = Self.swipeDuration(request.milliseconds) else {
                    return .failure("a swipe takes 50...5000 ms")
                }
                begun = true
                try Self.whileWanted(wanted, else: {
                    session.interrupt()
                }) {
                    try session.swipe(from: from, to: to, milliseconds: duration)
                }
                went()
                return .init(ok: true)
            case "type", "paste", "press":
                guard let text = request.text else { return .failure("nothing to send") }
                // Into whatever has focus: held to the device's latest look, as a point is.
                if request.op != "press", let refused = held(to: request.look) {
                    return refused
                }
                begun = true
                switch request.op {
                case "type":
                    let started = Date()
                    try Self.whileWanted(wanted, else: {
                        session.interrupt()
                    }) {
                        try session.type(text)
                    }
                    Self.inputLog
                        .debug(
                            "\(name, privacy: .public): typed \(text.count) keys, \(text.filter { $0 == " " }.count) spaces, in \(Int(Date().timeIntervalSince(started) * 1000)) ms"
                        )
                    went()
                case "paste":
                    try Self.whileWanted(wanted, else: {
                        session.interrupt()
                    }) {
                        try session.paste(text)
                    }
                    went()
                default:
                    try Self.whileWanted(wanted, else: {
                        session.interrupt()
                    }) {
                        try session.press(text)
                    }
                    end() // goes to whatever is on the screen: what the look saw may go with it
                }
                return .init(ok: true)
            case "look":
                // Written only where RoamRun keeps looks: whoever asks takes it from there.
                guard let path = request.path,
                      Self.isLookFile(path, in: directory) else { return .failure("no file to write the look to") }
                // What an earlier look showed is no longer what a point may be read off, whether or not this one succeeds.
                end()
                Thread.sleep(forTimeInterval: Self.settleWait(acted: h.acted, settle: settling))
                guard wanted() else { return .failure(Self.notGiven) }
                // As large as a model is shown it, no larger: an image scaled again by whatever shows
                // it has points that aren't the look's any more, and a tap goes beside what was meant.
                let image = Self.fitted(try h.session.look())
                guard let out = CGImageDestinationCreateWithURL(
                    URL(fileURLWithPath: path) as CFURL,
                    UTType.png.identifier as CFString,
                    1,
                    nil
                ) else {
                    return .failure("can't write \(path)")
                }
                CGImageDestinationAddImage(out, image, nil)
                guard CGImageDestinationFinalize(out) else { return .failure("can't write \(path)") }
                // Whoever asked left while it was taken: nobody is there to take the screen away.
                guard wanted() else {
                    try? FileManager.default.removeItem(atPath: path)
                    return .failure(Self.notGiven)
                }
                let id = lock.withLock { () -> Int in
                    looks += 1
                    return looks
                }
                h.looked = (image.width, image.height, id, Date(), false)
                return .init(ok: true, width: image.width, height: image.height, look: id)
            case "tap":
                // In the pixels of what was last looked at, no tap or swipe gone by it: there is no tapping a screen not seen.
                guard pointable() != nil, let size = h.looked else { return .failure(Self.lookFirst) }
                // Of this look, when the caller says which: another's look since shows a screen this one never saw.
                guard request.look ?? size.id == size.id
                else { return .failure(Self.lookedSince(request.look ?? size.id)) }
                guard Date().timeIntervalSince(size.at) <= lookStands else { end()
                    return .failure(Self.lookOld)
                }
                guard let point = Self.fraction(x: request.x, y: request.y, of: (size.width, size.height)) else {
                    return .failure("the point must be inside the image (\(size.width) x \(size.height))")
                }
                begun = true
                try Self.whileWanted(wanted, else: {
                    session.interrupt()
                }) {
                    try session.tap(x: point.x, y: point.y)
                }
                went()
                return .init(ok: true)
            default:
                return .failure("unknown request")
            }
        } catch {
            // Refused for what it says, before anything went to the device: the look stands. Failed
            // otherwise (an interruption among them), it may have reached the device: nothing more goes by it.
            if let failure = error as? DeviceSession.Failure {
                switch failure {
                case .invalid, .notBegun: begun = false
                    return .failure("\(error)")
                case .message: break
                }
            }
            guard begun else { return .failure("\(error)") }
            end()
            return .failure("\(error). It may or may not have reached the device: look before doing it again")
        }
    }
}
