import Foundation
import Security

/// The devices commands and agents may operate, kept in the login Keychain beside the key:
/// another program can't put a device on the list (macOS asks about what it wrote there), so
/// one that the user switched off stays off. What can't be read is nobody: off is the safe side.
/// The Keychain may ask the user, and waits: read off the main thread.
final class DeviceControlAllowed: @unchecked Sendable {
    static let shared = DeviceControlAllowed()
    private let lock = NSLock()
    private var held: Set<UUID>?
    private let read: () -> (OSStatus, Data?)
    private let write: (Data) -> OSStatus

    /// The Keychain's own by default; tests give stand-ins.
    init(read: @escaping () -> (OSStatus, Data?) = {
        var found: CFTypeRef?
        let status = SecItemCopyMatching(item.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &found)
        return (status, found as? Data)
    }, write: @escaping (Data) -> OSStatus = { list in
        let status = SecItemAdd(item.merging([kSecValueData as String: list, kSecAttrLabel as String: "RoamRun device control (devices switched on)"]) { $1 } as CFDictionary, nil)
        guard status == errSecDuplicateItem else { return status }
        return SecItemUpdate(item as CFDictionary, [kSecValueData as String: list] as CFDictionary)
    }) {
        self.read = read
        self.write = write
    }

    private static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "io.github.mh-mobile.roamrun.device-control", kSecAttrAccount as String: "allowed"]
    }

    /// Under `lock`. Read once a process: nothing else writes it that is to be believed.
    private func list() -> Set<UUID> {
        if let held { return held }
        let (status, data) = read()
        let found = status == errSecSuccess ? data.flatMap { try? JSONDecoder().decode(Set<UUID>.self, from: $0) } : nil
        held = found ?? []
        return held!
    }

    @Sendable func contains(_ id: UUID) -> Bool { lock.withLock { list().contains(id) } }

    /// As far as it has been read; nil before that. For the main thread, which doesn't wait on the Keychain.
    func known(_ id: UUID) -> Bool? { lock.withLock { held?.contains(id) } }

    /// Whether it was written. Not written, it isn't switched on (after a restart it would be off
    /// again unsaid); it is switched off here all the same, and is on again after a restart —
    /// which the caller says.
    @discardableResult
    func set(_ id: UUID, _ allowed: Bool) -> Bool {
        lock.withLock {
            var next = list()
            if allowed { next.insert(id) } else { next.remove(id) }
            guard next != held else { return true }
            guard let data = try? JSONEncoder().encode(next), write(data) == errSecSuccess else {
                if !allowed { held = next }
                return false
            }
            held = next
            return true
        }
    }
}
