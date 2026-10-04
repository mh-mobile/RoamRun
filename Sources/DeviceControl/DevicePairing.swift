import dnssd
import Foundation
import RoamRunDevice

/// A pairing the device comes to make (iOS 27 and later): this Mac listens and names itself
/// on the local network, the device's user picks it in Settings and enters the code shown
/// here. One at a time; `accept` waits, `cancel` (any thread) makes it return.
/// Known limit: idevice tells the device a fixed serial number and addresses for this side, so
/// the device lists every tool built on it as one host; removing that entry there removes them
/// all. Ours alone shows under its own name.
public final class DevicePairing: @unchecked Sendable {
    public struct Paired: Equatable, Sendable {
        public var udid: String
        public var name: String
        public var model: String
    }

    private let pairing: OpaquePointer
    private var advert: DNSServiceRef?
    /// What the device's Settings lists this Mac as.
    public let name: String

    /// Starts listening and advertising. Both networks have to be the same one: the device
    /// finds this by Bonjour.
    public init(name: String) throws {
        var said: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        guard let pairing = rr_pairing_listen(name, Self.model, &said, &error) else {
            defer { rr_string_free(error) }
            throw DeviceSession.Failure.message(error.map { String(cString: $0) } ?? "can't listen")
        }
        defer { rr_string_free(said) }
        self.pairing = pairing
        self.name = name
        guard let said, let object = try? JSONSerialization.jsonObject(with: Data(String(cString: said).utf8)) as? [String: Any],
              let port = object["port"] as? Int, let identifier = object["identifier"] as? String,
              let txt = object["txt"] as? [String: String] else {
            throw DeviceSession.Failure.message("unreadable advert")   // deinit stops the listening
        }
        // Held by mDNSResponder for as long as the reference lives; nothing to wait on.
        let record = Self.txtRecord(txt)
        let status = record.withUnsafeBytes {
            DNSServiceRegister(&advert, 0, 0, identifier, "_remotepairing-pairable-host._tcp", nil, nil,
                               UInt16(port).bigEndian, UInt16($0.count), $0.baseAddress, nil, nil)
        }
        guard status == kDNSServiceErr_NoError else {
            // NoAuth: macOS keeps this app from Bonjour (Local Network in Privacy & Security, or a
            // build whose Info.plist doesn't name the service).
            throw DeviceSession.Failure.message(status == kDNSServiceErr_NoAuth || status == kDNSServiceErr_PolicyDenied
                ? "macOS didn't let RoamRun announce itself on the local network. Allow it in System Settings › Privacy & Security › Local Network, then try again."
                : "can't announce on the local network (\(status))")
        }
    }

    deinit {
        if let advert { DNSServiceRefDeallocate(advert) }
        rr_pairing_free(pairing)
    }

    /// Waits for a device to pair and writes the pairing to `file` (its owner's only).
    /// `code` gets the six digits to show, on another thread, while this waits.
    public func accept(to file: String, code: @escaping @Sendable (String) -> Void) throws -> Paired {
        let box = Unmanaged.passRetained(Code(show: code))
        defer { box.release() }
        guard let json = rr_pairing_accept(pairing, file, { digits, context in
            guard let digits, let context else { return }
            Unmanaged<Code>.fromOpaque(context).takeUnretainedValue().show(String(cString: digits))
        }, box.toOpaque()) else { throw DeviceSession.Failure.message("no answer") }
        defer { rr_string_free(json) }
        guard let object = try? JSONSerialization.jsonObject(with: Data(String(cString: json).utf8)) as? [String: Any] else {
            throw DeviceSession.Failure.message("unreadable answer")
        }
        guard object["ok"] as? Bool == true, let udid = object["udid"] as? String else {
            throw DeviceSession.Failure.message(object["error"] as? String ?? "failed")
        }
        return Paired(udid: udid, name: object["name"] as? String ?? "", model: object["model"] as? String ?? "")
    }

    public func cancel() { rr_pairing_cancel(pairing) }

    private final class Code {
        let show: @Sendable (String) -> Void
        init(show: @escaping @Sendable (String) -> Void) { self.show = show }
    }

    /// DNS-SD's TXT form: each "key=value" behind its length.
    static func txtRecord(_ pairs: [String: String]) -> Data {
        pairs.sorted { $0.key < $1.key }.reduce(into: Data()) { data, pair in
            let entry = Array("\(pair.key)=\(pair.value)".utf8.prefix(255))
            data.append(UInt8(entry.count))
            data.append(contentsOf: entry)
        }
    }

    /// This Mac's model identifier ("Mac16,1"): the device shows a computer for it.
    static var model: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        let model = bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return model.isEmpty ? "Mac" : model
    }
}
