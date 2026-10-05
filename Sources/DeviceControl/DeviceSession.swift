import CoreGraphics
import Foundation
import RoamRunDevice

/// What to do when a call on a kept connection fails. Pure, so it can be checked without a device.
public enum Recovery {
    /// Runs `attempt`. A failed read is tried once more on the same connection after `pause`
    /// (a change of network stalls it for a few seconds), then on a new connection if `reopen`
    /// gets one. `reopen` returning false leaves the old connection in place: away from Wi‑Fi no
    /// new one can be made, and the old one may still come back.
    /// An input is never repeated: it may have reached the device before the failure showed.
    public static func run<T>(repeatable: Bool, attempt: () throws -> T, pause: () -> Void, reopen: () -> Bool) throws -> T {
        do { return try attempt() } catch {
            // What failed for being told to stop, or for what it asked, fails again the same way.
            guard repeatable, DeviceSession.leavesConnectionInDoubt(error) else { throw error }
            pause()
            do { return try attempt() } catch {
                guard DeviceSession.leavesConnectionInDoubt(error), reopen() else { throw error }
                return try attempt()
            }
        }
    }
}

/// One device over one connection that is kept open; calls run one at a time, from any thread.
public final class DeviceSession: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case message(String)
        /// Refused for what was asked, before anything went to the device.
        case invalid(String)
        public var description: String {
            switch self {
            case .message(let m), .invalid(let m): m
            }
        }
    }

    /// Whether a call's failure leaves its connection in doubt. A read is tried again and on a
    /// new connection first, so its failure does. An input is never sent twice, but one that
    /// failed for anything other than what it asked says the same about the connection: it is
    /// taken for gone (a new one is made in the background) instead of standing as connected.
    public static func leavesConnectionInDoubt(_ error: Error) -> Bool {
        if case Failure.invalid = error { return false }
        if case Failure.message(let m) = error, m.hasPrefix(stopped) { return false }   // told to stop, by us
        return true
    }

    private let ip: String, port: UInt16, udid: String?
    /// The pairing itself, read each time a connection is made (never on the caller's thread:
    /// it may have to be unsealed first).
    private let pairing: @Sendable () throws -> Data
    private let lock = NSLock()
    private var device: OpaquePointer?
    /// A read failed even after trying again and reopening: the connection is taken for gone
    /// until a call works or a new one is made.
    private var broken = false
    private var refused = false
    /// What answered when a connection was last tried wasn't the device the pairing was made with.
    private var another = false
    private var closed = false
    /// What `isOpen` and `isRefused` answer with, under a lock of its own: `lock` is held for
    /// as long as a call to the device takes, and asking how things stand mustn't wait for that.
    private let standingLock = NSLock()
    private var standing = (open: false, refused: false, another: false)
    /// Under `standingLock`: let go of, and to be closed.
    private var leaving = false
    /// Said as things happen (opened, tried again, reopened), for whoever shows or logs it.
    public var onEvent: (@Sendable (String) -> Void)?

    public init(ip: String, port: UInt16, pairing: @escaping @Sendable () throws -> Data, udid: String? = nil) {
        self.ip = ip; self.port = port; self.pairing = pairing; self.udid = udid
    }

    /// Raised when this is closed, and for the call under way by `interrupt`: a long text stops between two keys, instead of
    /// being typed out on a device that was let go of.
    private let stopping: UnsafeMutablePointer<UInt8> = {
        let flag = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        flag.initialize(to: 0)
        return flag
    }()

    deinit {
        rr_device_close(device)
        stopping.deallocate()
    }

    /// For good: a session closed is one replaced, and nothing opens it again (a call that
    /// still holds it fails, instead of making a connection beside its successor's).
    public func close() {
        letGo()
        lock.withLock {
            closed = true
            rr_device_close(device)
            device = nil
            noteStanding()
        }
    }

    /// At once, whatever runs: a long text stops between two keys, and a call that waits here
    /// (for the connection to open, or its turn) doesn't begin on the device. `close` follows.
    public func letGo() {
        // Under the lock a call lowers the flag under: let go of, it stays raised.
        standingLock.withLock {
            leaving = true
            rr_flag_raise(stopping)
        }
    }

    /// The call under way is to stop where it can (a text, between two keys; a walk, at its next
    /// step); the device is kept. For a switch turned off, or an asker who left.
    public func interrupt() { rr_flag_raise(stopping) }

    /// Asked when a call has its turn (the lock had, the connection open), before it begins.
    private var mayBegin: (@Sendable () -> Bool)?
    public func gate(_ mayBegin: @escaping @Sendable () -> Bool) { standingLock.withLock { self.mayBegin = mayBegin } }

    /// In the words of a call stopped: not a failure of the connection, and not tried again.
    private static let replaced = Failure.message("\(stopped) this connection was closed (the device has a new one): look again")

    /// As of the last call that finished; never waits for one that runs.
    public var isOpen: Bool { standingLock.withLock { standing.open } }

    /// The pairing was of no use when a connection was last tried — the device refused it (it
    /// was removed there), or it couldn't be read here: only pairing again helps.
    public var isRefused: Bool { standingLock.withLock { standing.refused } }

    /// Something answers at the device's address that isn't the device this pairing was made
    /// with: it is told nothing of this Mac's and sent no input. The device erased or replaced — or something else there.
    public var isAnother: Bool { standingLock.withLock { standing.another } }

    /// Under `lock`, whenever what it guards may have changed.
    private func noteStanding() {
        let now = (device != nil && !broken, refused, another)
        standingLock.withLock { standing = now }
    }

    /// Opens a connection if none stands; nothing is asked of the device beyond that. One
    /// taken for gone stays in place when no new one can be made: a later call may find it back.
    public func connect() throws {
        try lock.withLock {
            defer { noteStanding() }
            guard !closed else { throw Self.replaced }
            guard device == nil || broken else { return }
            let fresh = try open()
            rr_device_close(device)
            device = fresh
            broken = false
            onEvent?("opened")
        }
    }

    /// The services the device has, as the library reports them (JSON).
    public func info() throws -> String {
        try perform(repeatable: true) { d in
            guard let json = rr_device_info(d) else { throw Failure.message("no answer") }
            defer { rr_string_free(json) }
            return String(cString: json)
        }
    }

    /// The screen now, cut to its own size when devicectl knows it.
    public func look() throws -> CGImage {
        let frame = try perform(repeatable: true) { d -> Data in
            var length = 0
            var error: UnsafeMutablePointer<CChar>?
            guard let bytes = rr_device_keyframe(d, &length, &error) else {
                defer { rr_string_free(error) }
                throw Failure.message(error.map { String(cString: $0) } ?? "no frame")
            }
            defer { rr_bytes_free(bytes, length) }
            return Data(bytes: bytes, count: length)
        }
        // Outside the session's lock: devicectl can take seconds, and another call needn't wait for it.
        return cut(try decodeKeyFrame(frame), to: udid.flatMap { ScreenSizes.shared.size(of: $0) })
    }

    /// Accessibility's captions; `complete` is false when the walk was cut short. Can scroll the screen.
    public func elements(limit: Int = 40) throws -> (captions: [String], complete: Bool) {
        // Not repeated: each walk moves the screen.
        let object = try answer(repeatable: false) { rr_device_elements($0, UInt32(clamping: max(limit, 1))) }
        let captions = (object["elements"] as? [[String: Any]] ?? []).map { $0["caption"] as? String ?? "" }
        // How it ended (round, quiet, limit, deadline) and how long it took: what tells a screen read whole from one cut short.
        onEvent?("elements: \(captions.count), ended \(object["ended"] as? String ?? "?") in \(object["ms"] as? Int ?? 0) ms")
        return (captions, object["complete"] as? Bool ?? false)
    }

    // These operate the device. Points are fractions 0...1 of the screen.
    public func tap(x: Double, y: Double) throws { _ = try answer(repeatable: false) { rr_device_tap($0, x, y) } }
    public func swipe(from: (x: Double, y: Double), to: (x: Double, y: Double), milliseconds: Int) throws {
        _ = try answer(repeatable: false) { rr_device_swipe($0, from.x, from.y, to.x, to.y, UInt32(clamping: max(milliseconds, 0))) }
    }
    public func type(_ text: String) throws { try whole(text); _ = try answer(repeatable: false) { rr_device_type($0, text) } }
    public func paste(_ text: String) throws { try whole(text); _ = try answer(repeatable: false) { rr_device_paste($0, text) } }

    /// The library takes text up to its first NUL: text with one would arrive cut short, and be reported sent.
    private func whole(_ text: String) throws {
        if text.utf8.contains(0) { throw Failure.invalid("the text holds a NUL character, which can't be sent") }
    }
    public func press(_ button: String) throws { _ = try answer(repeatable: false) { rr_device_button($0, button) } }

    /// A call that answers {"ok":…} JSON; its "error" becomes the failure.
    private func answer(repeatable: Bool, _ call: @escaping (OpaquePointer) -> UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
        try perform(repeatable: repeatable) { d in
            guard let json = call(d) else { throw Failure.message("no answer") }
            defer { rr_string_free(json) }
            guard let object = try? JSONSerialization.jsonObject(with: Data(String(cString: json).utf8)) as? [String: Any] else {
                throw Failure.message("unreadable answer")
            }
            guard object["ok"] as? Bool == true else {
                let why = object["error"] as? String ?? "failed"
                throw object["invalid"] as? Bool == true ? Failure.invalid(why) : Failure.message(why)
            }
            if object["reconnected"] as? Bool == true { onEvent?("the kept input connection was gone; sent on a new one") }
            return object
        }
    }

    private func open() throws -> OpaquePointer {
        // Let go of: no new connection is made for a session that is to be closed.
        guard !standingLock.withLock({ leaving }) else { throw Self.replaced }
        var error: UnsafeMutablePointer<CChar>?
        let pairing: Data
        do { pairing = try self.pairing() } catch {
            refused = true   // trying again reads the same
            throw error
        }
        guard let opened = pairing.withUnsafeBytes({ rr_device_open(ip, port, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &error) }) else {
            defer { rr_string_free(error) }
            let why = error.map { String(cString: $0) } ?? "can't open"
            refused = why.contains(Self.refusal) || why.contains(Self.unchecked)
            another = why.contains(Self.notTheDevice)
            throw Failure.message(why)
        }
        refused = false
        another = false
        rr_device_stop_at(opened, stopping)
        return opened
    }

    /// How the library words a pairing the device doesn't know (rr_device_open's error).
    public static let refusal = "doesn't accept this pairing"
    /// How it words a call stopped at this side's bidding.
    public static let stopped = "stopped:"
    /// And a pairing made before the device's key was kept with it, or one it can't read: only
    /// pairing again helps there too.
    public static let unchecked = "doesn't hold the device's key"
    /// How it words an answer that isn't the device's own: not a refusal — pairing again isn't
    /// what to do when something else has taken the device's address.
    public static let notTheDevice = "isn't the device this pairing was made with"

    private func perform<T>(repeatable: Bool, _ body: (OpaquePointer) throws -> T) throws -> T {
        try lock.withLock {
            defer { noteStanding() }
            guard !closed else { throw Self.replaced }
            // A stop asked of the call before this one was for that call.
            standingLock.withLock { if !leaving { rr_flag_lower(stopping) } }
            if device == nil {
                device = try open()
                onEvent?("opened")
            }
            do {
                let result = try recovering(repeatable: repeatable, body)
                broken = false
                return result
            } catch {
                if Self.leavesConnectionInDoubt(error) { broken = true }
                throw error
            }
        }
    }

    private func recovering<T>(repeatable: Bool, _ body: (OpaquePointer) throws -> T) throws -> T {
        try Recovery.run(repeatable: repeatable, attempt: {
            do {
                // Let go of while this waited (for the connection, or to try again): not begun.
                let (leaving, mayBegin) = standingLock.withLock { (leaving, mayBegin) }
                guard !leaving else { throw Self.replaced }
                // Switched off while this waited its turn: a stop asked then was for this call too.
                guard mayBegin?() ?? true else { throw Failure.message("\(Self.stopped) its device was switched off before it began") }
                return try body(device!)
            } catch {
                onEvent?("failed: \(error)")
                throw error
            }
        }, pause: {
            onEvent?("trying again on the same connection")
            Thread.sleep(forTimeInterval: 1)
        }, reopen: {
            // The old connection goes only once a new one stands.
            guard let fresh = try? open() else {
                onEvent?("no new connection can be made; keeping the old one")
                return false
            }
            rr_device_close(device)
            device = fresh
            onEvent?("reopened")
            return true
        })
    }
}
