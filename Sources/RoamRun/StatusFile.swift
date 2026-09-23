import Foundation

/// Bridge status shared between the menu bar app and the CLI, so either one
/// can report on — and refuse to collide with — a bridge the other runs.
// ponytail: whole-file rewrite, last writer wins; fine for a handful of devices.
enum StatusFile {
    struct Entry: Codable {
        var pid: Int32
        /// Written by `roamrun up` (vs. the app) — decides how to stop it.
        var cli: Bool?
        var status: String
        var detail: String
        var ready: Bool
        var tunnelPorts: [UInt16]
        var updated: Date

        var isError: Bool { status == BridgeStatus.error.title }
    }

    static let url = ProfileStore.directory.appendingPathComponent("status.json")

    /// Entries whose owner is still a live RoamRun process. Checking the
    /// executable, not just liveness, guards against recycled PIDs — these
    /// PIDs get SIGTERM from `roamrun down` and the app's Stop button.
    static func read() -> [UUID: Entry] {
        guard let data = try? Data(contentsOf: url),
              let all = try? JSONDecoder().decode([UUID: Entry].self, from: data) else { return [:] }
        return all.filter { isRoamRun($0.value.pid) }
    }

    /// Sets (or with nil, clears) this process's entry. Never touches an
    /// entry a *different* live process holds for a healthy bridge — the
    /// check sits under the lock so app and CLI can't both claim a device.
    static func write(_ id: UUID, _ entry: Entry?) {
        try? FileManager.default.createDirectory(at: ProfileStore.directory, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        var all = read()
        if let held = all[id], held.pid != getpid(), entry == nil || !held.isError { return }
        all[id] = entry
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: url, options: .atomic) }
    }

    /// PID of *another* live process bridging this device. An errored bridge
    /// (e.g. iPhone asleep) doesn't hold the device.
    static func otherOwner(of id: UUID) -> Int32? {
        guard let e = read()[id], e.pid != getpid(), !e.isError else { return nil }
        return e.pid
    }

    private static let lockURL = ProfileStore.directory.appendingPathComponent("status.lock")

    static func isRoamRun(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        // Any copy of RoamRun (the app in /Applications and a dev build can
        // both be around); anything else holding a recycled PID is ignored.
        let path = String(cString: buf)
        return path.hasSuffix("/Contents/MacOS/RoamRun") || path == Bundle.main.executablePath
    }
}
