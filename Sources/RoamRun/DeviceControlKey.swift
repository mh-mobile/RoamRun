#if DEVICE_CONTROL
import CryptoKit
import DeviceControl
import Foundation
import Security

/// The one key the saved pairings are sealed with, in the login Keychain: read by RoamRun
/// alone (another program is asked about by macOS), made when the first pairing is saved.
/// Read once a process — the Keychain may ask the user, and waits for the answer: never on
/// the main thread. A build signed ad hoc is asked about anew after every rebuild.
final class DeviceControlKey: @unchecked Sendable {
    static let shared = DeviceControlKey()
    private let lock = NSLock()
    private var held: SymmetricKey?

    private static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "io.github.mh-mobile.roamrun.device-control", kSecAttrAccount as String: "pairings"]
    }

    @Sendable func key(make: Bool) throws -> SymmetricKey {
        try lock.withLock {
            if let held { return held }
            let key = try Self.key(make: make, read: {
                var found: CFTypeRef?
                let status = SecItemCopyMatching(Self.item.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &found)
                return (status, found as? Data)
            }, add: { fresh in
                SecItemAdd(Self.item.merging([kSecValueData as String: fresh, kSecAttrLabel as String: "RoamRun device control"]) { $1 } as CFDictionary, nil)
            })
            held = key
            return key
        }
    }

    /// A key is made only when the Keychain says there is none: after a refusal (the user's, or
    /// a Keychain that can't ask) a new one would leave every saved pairing unreadable.
    static func key(make: Bool, read: () -> (OSStatus, Data?), add: (Data) -> OSStatus) throws -> SymmetricKey {
        func failure(_ status: OSStatus) -> DeviceSession.Failure {
            .message("the Keychain didn't give RoamRun its key for device control (\(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"))")
        }
        let (status, data) = read()
        if status == errSecSuccess, let data { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else { throw failure(status) }
        guard make else { throw DeviceSession.Failure.message("this Mac's key for device control is gone from the Keychain: set device control up again") }
        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
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
#endif
