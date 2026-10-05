import Foundation
import Security

/// The pairings commands and agents may use, kept in the login Keychain beside the key: another
/// program can't put one on the list (macOS asks about what it wrote there), so a device the
/// user switched off stays off. A pairing is named by its mark — a digest of its sealed file and
/// of the UDID it is saved under — not by the device's place in the list of saved devices,
/// which any program of the user can rewrite: a device given another's address is still the
/// pairing that was switched off, and a file put under another device's name is another mark.
/// Only what a session connects with is kept (`prune`): a pairing parked aside and brought back
/// is off. What can't be read is nobody: off is the safe side.
final class DeviceControlAllowed: @unchecked Sendable {
    static let shared = DeviceControlAllowed()
    /// Guards what was read; never held while the Keychain is asked (it may ask the user, and
    /// the main thread reads `known` while it draws).
    private let lock = NSLock()
    private var held: Set<String>?
    private var unreadable = false
    /// Switched off here and now, whatever the Keychain has been told yet (it may be busy, or asking).
    private var off: Set<String> = []
    /// Counts what is asked, so that a switch-on that was waiting doesn't undo an off asked after it.
    private var asked: UInt64 = 0
    private var offAt: [String: UInt64] = [:]
    /// The Keychain has something else than `held` (a write that failed): written at the next chance.
    private var unwritten = false
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
    /// the user switches something on (`again`), not at every request — it may ask them each time.
    private func list(again: Bool) -> Set<String>? {
        let (known, failed) = lock.withLock { (held, unreadable) }
        if let known { return known }
        if failed, !again { return nil }
        let (status, data) = read()
        // Given, and not a list (an earlier build's, or garbled): nothing is on, and the next switch writes a list in its place.
        let found: Set<String>? = status == errSecItemNotFound ? []
            : status == errSecSuccess ? (data.flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []) : nil
        lock.withLock { held = found; unreadable = found == nil }
        return found
    }

    @Sendable func contains(_ mark: String) -> Bool {
        // Known already: answered without waiting behind a write for another device.
        // …nor behind one that is asking the user, when the list is known not to be readable.
        let (isOff, known, failed) = lock.withLock { (off.contains(mark), held, unreadable) }
        if isOff || failed { return false }
        if let known { return known.contains(mark) }
        return io.withLock { list(again: false)?.contains(mark) ?? false } && !lock.withLock { off.contains(mark) }
    }

    /// As far as it has been read; nil before that, and when it couldn't be. Never waits.
    @Sendable func known(_ mark: String) -> Bool? { lock.withLock { off.contains(mark) ? false : held?.contains(mark) } }

    /// Off from this moment, before the Keychain is told (`set` follows): never waits.
    func offNow(_ mark: String) {
        lock.withLock {
            asked += 1
            offAt[mark] = asked
            off.insert(mark)
        }
    }

    /// When something is asked: given to `set` for a switch-on that may wait its turn.
    func now() -> UInt64 { lock.withLock { asked += 1; return asked } }

    /// The Keychain's list couldn't be read: nothing is on, and nothing can be switched until it can.
    var isUnreadable: Bool { lock.withLock { unreadable } }

    /// Writes what an earlier write failed to, if anything: before the app ends.
    func flush() {
        io.withLock {
            guard lock.withLock({ unwritten }), let now = lock.withLock({ held }) else { return }
            let kept = (try? JSONEncoder().encode(now.subtracting(lock.withLock { off }))).map { write($0) == errSecSuccess } ?? false
            lock.withLock { unwritten = !kept }
        }
    }

    /// Drops what names no pairing in use: a mark is only as good as the pairing it was made for.
    func prune(keeping inUse: Set<String>) {
        io.withLock {
            guard let now = list(again: false) else { return }
            let next = now.intersection(inUse).subtracting(lock.withLock { off })
            // Also the chance to write what an earlier write failed to.
            guard next != now || lock.withLock({ unwritten }) else { return }
            let kept = (try? JSONEncoder().encode(next)).map { write($0) == errSecSuccess } ?? false
            lock.withLock { held = next; unwritten = !kept }
        }
    }

    /// Whether it was written. Not written, it isn't switched on (after a restart it would be off
    /// again unsaid); it is switched off here all the same, and written again at the next chance
    /// (the next switch, or `prune`) — until then it would be on again after a restart, which the
    /// caller says. A list that can't be read isn't written over, and has no such next chance.
    @discardableResult
    func set(_ mark: String, _ allowed: Bool, asked when: UInt64? = nil) -> Bool {
        if !allowed { offNow(mark) }
        let when = when ?? now()
        /// Switched off since this switch-on was asked: the off stands.
        func overtaken() -> Bool { allowed && (offAt[mark] ?? 0) > when }
        return io.withLock {
            // The Keychain is asked again (it may ask the user) only to switch on: off is off here
            // without it, and Remove doesn't put a question about a list that may not be ours.
            guard var next = list(again: allowed) else { return false }
            // Switched off since it was asked: nothing of it is taken, kept or written.
            let (lost, pending) = lock.withLock { () -> (Bool, Set<String>) in
                if overtaken() { return (true, off) }
                if allowed { off.remove(mark) }
                return (false, off)
            }
            if lost { return true }
            let was = next
            // With it goes whatever was switched off here and the Keychain hasn't been told
            // (it couldn't be read then): off isn't left to end with this run.
            next.subtract(pending)
            if allowed { next.insert(mark) } else { next.remove(mark) }
            guard next != was || lock.withLock({ unwritten }) else { return true }
            let kept = (try? JSONEncoder().encode(next)).map { write($0) == errSecSuccess } ?? false
            lock.withLock {
                if kept || !allowed { held = next }
                unwritten = !kept
            }
            return kept
        }
    }
}
