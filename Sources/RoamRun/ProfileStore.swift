import Foundation

final class ProfileStore {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RoamRun", isDirectory: true)
    private let dir: URL
    private let url: URL

    init(directory: URL = ProfileStore.directory) {
        dir = directory
        url = directory.appendingPathComponent("profiles.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Set when profiles.json couldn't be read and was kept aside under this name.
    private(set) var keptUnreadable: URL?

    func load() -> [DeviceProfile] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let profiles = try? JSONDecoder().decode([DeviceProfile].self, from: data) { return profiles }
        // One malformed entry shouldn't cost the others: keep what decodes (and a copy of the file below).
        let salvaged = ((try? JSONSerialization.jsonObject(with: data)) as? [Any])?.compactMap { item in
            (try? JSONSerialization.data(withJSONObject: item)).flatMap { try? JSONDecoder().decode(DeviceProfile.self, from: $0) }
        }
        // The next save would replace it with an empty list: keep a copy, once per distinct content.
        let fm = FileManager.default
        let kept = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        if let same = kept.first(where: { $0.lastPathComponent.hasPrefix("profiles.json.unreadable") && (try? Data(contentsOf: $0)) == data }) {
            keptUnreadable = same
        } else {
            let copy = url.appendingPathExtension("unreadable-\(Int(Date.now.timeIntervalSince1970))")
            if (try? fm.copyItem(at: url, to: copy)) != nil { keptUnreadable = copy }
        }
        return salvaged ?? []
    }

    /// Reads, changes and writes the list under the lock, so nothing another
    /// process wrote in between is lost. For a caller that reads the file only
    /// to change it — as `roamrun up` does when a device has moved — this is the
    /// one to use: reading first and merging afterwards would still drop a
    /// device the app added in between, since membership follows the caller.
    func update(_ change: (inout [DeviceProfile]) -> Void) -> Bool {
        withLock {
            var all = load()
            change(&all)
            return save(all)
        } ?? false
    }

    /// Saves `wanted` without dropping what another process wrote since `base`
    /// was read. The app keeps its list in memory for as long as it runs, so a
    /// plain whole-list write would undo the endpoint `roamrun up` had saved
    /// meanwhile. nil if it couldn't be written; otherwise what is on disk now.
    func save(base: [DeviceProfile], wanted: [DeviceProfile]) -> [DeviceProfile]? {
        withLock { () -> [DeviceProfile]? in
            let merged = Self.merge(base: base, wanted: wanted, disk: load())
            return save(merged) ? merged : nil
        } ?? nil   // the outer nil is a lock that couldn't be taken; both mean "not saved"
    }

    /// nil when the lock itself couldn't be taken.
    private func withLock<T>(_ body: () -> T) -> T? {
        let fd = open(dir.appendingPathComponent("profiles.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    /// Membership follows this process — it is the one that added or deleted a
    /// device. For the endpoint fields, which `roamrun up` also writes, a value
    /// this process left alone keeps whatever is on disk.
    static func merge(base: [DeviceProfile], wanted: [DeviceProfile], disk: [DeviceProfile]) -> [DeviceProfile] {
        let was = byID(base), onDisk = byID(disk)
        return wanted.map { mine in
            guard let old = was[mine.id], let theirs = onDisk[mine.id] else { return mine }
            var out = mine
            if mine.providerIP == old.providerIP { out.providerIP = theirs.providerIP }
            if mine.remotePairingPort == old.remotePairingPort { out.remotePairingPort = theirs.remotePairingPort }
            if mine.providerHostName == old.providerHostName { out.providerHostName = theirs.providerHostName }
            return out
        }
    }

    /// Last one wins: a duplicated id would trap `Dictionary(uniqueKeysWithValues:)`.
    private static func byID(_ profiles: [DeviceProfile]) -> [UUID: DeviceProfile] {
        profiles.reduce(into: [:]) { $0[$1.id] = $1 }
    }

    /// False if it couldn't be written (disk full, permissions). Private so that
    /// every write goes through the lock above.
    private func save(_ profiles: [DeviceProfile]) -> Bool {
        guard let data = try? JSONEncoder().encode(profiles), (try? data.write(to: url, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }
}
