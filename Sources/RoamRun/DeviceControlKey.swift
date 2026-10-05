import CryptoKit
import DeviceControl
import Foundation
import Security

/// The one key the saved pairings are sealed with, in the login Keychain: read by RoamRun
/// alone (another program is asked about by macOS), made when the first device is set up.
/// Read once a process — the Keychain may ask the user, and waits for the answer: never on
/// the main thread. A build signed ad hoc is asked about anew after every rebuild.
final class DeviceControlKey: @unchecked Sendable {
    static let shared = DeviceControlKey()
    private let lock = NSLock()
    private var held: SymmetricKey?
    /// Why the key couldn't be had, kept: every try to connect asking again would have the
    /// Keychain ask the user again. Setting a device up asks anew.
    private var refused: Error?
    private let read: () -> (OSStatus, Data?)
    private let add: (Data) -> OSStatus

    /// The Keychain's own by default; tests give stand-ins.
    init(read: @escaping () -> (OSStatus, Data?) = {
        var found: CFTypeRef?
        let status = SecItemCopyMatching(item.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &found)
        return (status, found as? Data)
    }, add: @escaping (Data) -> OSStatus = { fresh in
        SecItemAdd(item.merging([kSecValueData as String: fresh, kSecAttrLabel as String: "RoamRun device control"]) { $1 } as CFDictionary, nil)
    }) {
        self.read = read
        self.add = add
    }

    private static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "io.github.mh-mobile.roamrun.device-control", kSecAttrAccount as String: "pairings"]
    }

    @Sendable func key(make: Bool) throws -> SymmetricKey {
        try lock.withLock {
            // To set a device up, the Keychain is asked even with the key at hand: one removed
            // from it meanwhile is put back, or what is saved now couldn't be read after a restart.
            if let held, !make { return held }
            if !make, let refused { throw refused }
            do {
                let key = try Self.key(make: make, read: read, add: add, atHand: held)
                held = key
                refused = nil
                return key
            } catch {
                refused = error
                throw error
            }
        }
    }

    /// A key is made only when the Keychain says there is none: after a refusal (the user's, or
    /// a Keychain that can't ask) a new one would leave every saved pairing unreadable.
    /// `atHand`: the key this process already uses, which is what is saved then, not a new one.
    static func key(make: Bool, read: () -> (OSStatus, Data?), add: (Data) -> OSStatus, atHand: SymmetricKey? = nil) throws -> SymmetricKey {
        func failure(_ status: OSStatus) -> DeviceSession.Failure {
            .message("the Keychain didn't give RoamRun its key for device control (\(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"))")
        }
        let (status, data) = read()
        if status == errSecSuccess, let data { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else { throw failure(status) }
        guard make else { throw DeviceSession.Failure.message("this Mac's key for device control is gone from the Keychain: set device control up again") }
        let fresh = (atHand ?? SymmetricKey(size: .bits256)).withUnsafeBytes { Data($0) }
        switch add(fresh) {
        case errSecSuccess: return SymmetricKey(data: fresh)
        case errSecDuplicateItem:   // made in between: that one is the key
            let (status, data) = read()
            guard status == errSecSuccess, let data else { throw failure(status) }
            return SymmetricKey(data: data)
        case let status: throw failure(status)
        }
    }
}
