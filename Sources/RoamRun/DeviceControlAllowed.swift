import Foundation
import Security

/// The pairings commands and agents may use, kept in the login Keychain beside the key: another
/// program can't put one on the list (macOS asks about what it wrote there), so a device the
/// user switched off stays off. A pairing is named by the mark of its sealed file — not by the
/// device's place in the list of saved devices, which any program of the user can rewrite: a
/// pairing moved under another device's name, or a device given another's address, is still
/// the pairing that was switched off. What can't be read is nobody: off is the safe side.
final class DeviceControlAllowed: @unchecked Sendable {
    static let shared = DeviceControlAllowed()
    /// Guards what was read; never held while the Keychain is asked (it may ask the user, and
    /// the main thread reads `known` while it draws).
    private let lock = NSLock()
    private var held: Set<String>?
    private var unreadable = false
    /// Switched off here and now, whatever the Keychain has been told yet (it may be busy, or asking).
    private var off: Set<String> = []
    /// One call to the Keychain at a time.
    private let io = NSLock()
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

    /// Under `io`. Read once a process: nothing else writes it that is to be believed. A read
    /// that failed (refused) isn't taken for an empty list: asked again only when
    /// the user switches something (`again`), not at every request — it may ask them each time.
    private func list(again: Bool) -> Set<String>? {
        let (known, failed) = lock.withLock { (held, unreadable) }
        if let known { return known }
        if failed, !again { return nil }
        let (status, data) = read()
        // Given, and not a list (an earlier build's, or garbled): nothing is on, and it is written anew.
        let found: Set<String>? = status == errSecItemNotFound ? []
            : status == errSecSuccess ? (data.flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []) : nil
        lock.withLock { held = found; unreadable = found == nil }
        return found
    }

    @Sendable func contains(_ mark: String) -> Bool {
        guard !lock.withLock({ off.contains(mark) }) else { return false }
        return io.withLock { list(again: false)?.contains(mark) ?? false } && !lock.withLock { off.contains(mark) }
    }

    /// As far as it has been read; nil before that, and when it couldn't be. Never waits.
    @Sendable func known(_ mark: String) -> Bool? { lock.withLock { off.contains(mark) ? false : held?.contains(mark) } }

    /// Off from this moment, before the Keychain is told (`set` follows): never waits.
    func offNow(_ mark: String) { lock.withLock { _ = off.insert(mark) } }

    /// The Keychain's list couldn't be read: nothing is on, and nothing can be switched until it can.
    var isUnreadable: Bool { lock.withLock { unreadable } }

    /// Whether it was written. Not written, it isn't switched on (after a restart it would be off
    /// again unsaid); it is switched off here all the same, and is on again after a restart —
    /// which the caller says. A list that can't be read isn't written over.
    @discardableResult
    func set(_ mark: String, _ allowed: Bool) -> Bool {
        if !allowed { offNow(mark) }
        return io.withLock {
            guard var next = list(again: true) else { return false }
            let was = next
            if allowed { next.insert(mark) } else { next.remove(mark) }
            guard next != was else {
                if allowed { lock.withLock { _ = off.remove(mark) } }
                return true
            }
            let kept = (try? JSONEncoder().encode(next)).map { write($0) == errSecSuccess } ?? false
            lock.withLock {
                if kept || !allowed { held = next }
                if kept, allowed { off.remove(mark) }
            }
            return kept
        }
    }
}
