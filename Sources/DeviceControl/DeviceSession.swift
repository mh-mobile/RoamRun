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
            guard repeatable else { throw error }
            pause()
            do { return try attempt() } catch {
                guard reopen() else { throw error }
                return try attempt()
            }
        }
    }
}

/// One device over one connection that is kept open; calls run one at a time, from any thread.
public final class DeviceSession: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case message(String)
        public var description: String { if case .message(let m) = self { m } else { "" } }
    }

    private let ip: String, port: UInt16, pairingFile: String, udid: String?
    private let lock = NSLock()
    private var device: OpaquePointer?
    private var screen: (width: Int, height: Int)?
    private var askedScreen = false
    /// Said as things happen (opened, tried again, reopened), for whoever shows or logs it.
    public var onEvent: (@Sendable (String) -> Void)?

    public init(ip: String, port: UInt16, pairingFile: String, udid: String? = nil) {
        self.ip = ip; self.port = port; self.pairingFile = pairingFile; self.udid = udid
    }

    deinit { rr_device_close(device) }

    public func close() {
        lock.withLock { rr_device_close(device); device = nil }
    }

    public var isOpen: Bool { lock.withLock { device != nil } }

    /// Opens the connection if there is none; nothing is asked of the device beyond that.
    public func connect() throws {
        try perform(repeatable: false) { _ in }
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
        let size = lock.withLock { () -> (width: Int, height: Int)? in
            // Asked once: the size doesn't change, and devicectl may not be reachable later.
            if !askedScreen, let udid { askedScreen = true; screen = screenSize(udid: udid) }
            return screen
        }
        return cut(try decodeKeyFrame(frame), to: size)
    }

    /// Accessibility's captions; `complete` is false when the walk was cut short. Can scroll the screen.
    public func elements(limit: Int = 40) throws -> (captions: [String], complete: Bool) {
        // Not repeated: each walk moves the screen.
        let object = try answer(repeatable: false) { rr_device_elements($0, UInt32(max(limit, 1))) }
        let captions = (object["elements"] as? [[String: Any]] ?? []).map { $0["caption"] as? String ?? "" }
        return (captions, object["complete"] as? Bool ?? false)
    }

    // These operate the device. Points are fractions 0...1 of the screen.
    public func tap(x: Double, y: Double) throws { _ = try answer(repeatable: false) { rr_device_tap($0, x, y) } }
    public func swipe(from: (x: Double, y: Double), to: (x: Double, y: Double), milliseconds: Int) throws {
        _ = try answer(repeatable: false) { rr_device_swipe($0, from.x, from.y, to.x, to.y, UInt32(max(milliseconds, 0))) }
    }
    public func type(_ text: String) throws { _ = try answer(repeatable: false) { rr_device_type($0, text) } }
    public func paste(_ text: String) throws { _ = try answer(repeatable: false) { rr_device_paste($0, text) } }
    public func press(_ button: String) throws { _ = try answer(repeatable: false) { rr_device_button($0, button) } }

    /// A call that answers {"ok":…} JSON; its "error" becomes the failure.
    private func answer(repeatable: Bool, _ call: @escaping (OpaquePointer) -> UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
        try perform(repeatable: repeatable) { d in
            guard let json = call(d) else { throw Failure.message("no answer") }
            defer { rr_string_free(json) }
            guard let object = try? JSONSerialization.jsonObject(with: Data(String(cString: json).utf8)) as? [String: Any] else {
                throw Failure.message("unreadable answer")
            }
            guard object["ok"] as? Bool == true else { throw Failure.message(object["error"] as? String ?? "failed") }
            return object
        }
    }

    private func open() throws -> OpaquePointer {
        var error: UnsafeMutablePointer<CChar>?
        guard let opened = rr_device_open(ip, port, pairingFile, &error) else {
            defer { rr_string_free(error) }
            throw Failure.message(error.map { String(cString: $0) } ?? "can't open")
        }
        return opened
    }

    private func perform<T>(repeatable: Bool, _ body: (OpaquePointer) throws -> T) throws -> T {
        try lock.withLock {
            if device == nil {
                device = try open()
                onEvent?("opened")
            }
            return try Recovery.run(repeatable: repeatable, attempt: {
                do { return try body(device!) } catch {
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
}
