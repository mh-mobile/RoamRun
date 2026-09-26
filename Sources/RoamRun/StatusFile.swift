import Foundation

/// Bridge status shared between the menu bar app and the CLI, so either one
/// can report on — and refuse to collide with — a bridge the other runs.
// ponytail: whole-file rewrite, last writer wins; fine for a handful of devices.
enum StatusFile {
    struct Entry: Codable, Equatable {
        var pid: Int32
        /// Written by `roamrun up` (vs. the app) — decides how to stop it.
        var cli: Bool?
        var udid: String?
        var status: String
        var detail: String
        var ready: Bool
        var tunnelPorts: [UInt16]
        var updated: Date
        /// BridgeStatus raw value ("local", …): the stable key. `status` stays the display
        /// title for older RoamRun versions, which ignore this field.
        var state: String? = nil

        /// From `state`, else from the title an older version wrote.
        var kind: BridgeStatus { state.flatMap(BridgeStatus.init(rawValue:)) ?? BridgeStatus(title: status) }
        var isError: Bool { kind == .error }
        /// Errored or standing aside (iPhone on this LAN): doesn't hold the device.
        var holdsDevice: Bool { kind != .error && kind != .local }
    }

    static let url = ProfileStore.directory.appendingPathComponent("status.json")
    /// `dir` and `live` are for tests: a scratch folder, and owners that aren't RoamRun.app.
    typealias Liveness = (Int32) -> Bool

    /// Entries whose owner is still a live RoamRun process. Checking the
    /// executable, not just liveness, guards against recycled PIDs — these
    /// PIDs get SIGTERM from `roamrun down` and the app's Stop button.
    static func read(in dir: URL = ProfileStore.directory, live: Liveness = isRoamRun) -> [UUID: Entry] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("status.json")) else { return [:] }
        return decode(data).filter { live($0.value.pid) }
    }

    /// Entry by entry: one bad entry (e.g. from another version) mustn't hide the others.
    /// JSONEncoder writes a UUID-keyed dictionary as a flat [key, value, key, value, …] array.
    static func decode(_ data: Data) -> [UUID: Entry] {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [:] }
        var all: [UUID: Entry] = [:]
        for i in stride(from: 0, to: raw.count - 1, by: 2) {
            guard let key = raw[i] as? String, let id = UUID(uuidString: key),
                  let d = try? JSONSerialization.data(withJSONObject: raw[i + 1]),
                  let e = try? JSONDecoder().decode(Entry.self, from: d) else { continue }
            all[id] = e
        }
        return all
    }

    enum WriteResult: Equatable {
        case written
        case heldBy(Entry)
        case failed(String)
    }

    /// Sets (or with nil, clears) this process's entry. Never touches an
    /// entry a *different* live process holds for a healthy bridge — the
    /// check sits under the lock, so a `.written` claim is exclusive.
    @discardableResult
    static func write(_ id: UUID, _ entry: Entry?, in dir: URL = ProfileStore.directory, live: Liveness = isRoamRun) -> WriteResult {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("status.json")
        let fd = open(dir.appendingPathComponent("status.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return .failed("can't open status.lock: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return .failed("can't lock status.lock: \(String(cString: strerror(errno)))") }
        defer { flock(fd, LOCK_UN) }
        var all = read(in: dir, live: live)
        if let held = all[id], !mayReplace(held, with: entry, by: getpid()) { return .heldBy(held) }
        all[id] = entry
        do {
            try JSONEncoder().encode(all).write(to: url, options: .atomic)
        } catch {
            return .failed("can't write status.json: \(error.localizedDescription)")
        }
        // Every atomic write makes a new file: umask would decide its mode otherwise.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return .written
    }

    /// Only the owner clears or changes an entry; another process may take a
    /// device over only while it's errored or standing aside.
    static func mayReplace(_ held: Entry, with entry: Entry?, by pid: Int32) -> Bool {
        held.pid == pid || (entry != nil && !held.holdsDevice)
    }

    /// PID of *another* live process bridging this device. An errored bridge
    /// (e.g. iPhone asleep) doesn't hold the device.
    static func otherOwner(of id: UUID) -> Int32? {
        guard let e = read()[id], e.pid != getpid(), e.holdsDevice else { return nil }
        return e.pid
    }


    static func isRoamRun(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        // Any RoamRun.app copy (proc_pidpath resolves symlinks, so a
        // `.build/…` path never shows here); a recycled PID is ignored.
        let path = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return path.hasSuffix(".app/Contents/MacOS/RoamRun")
    }
}
