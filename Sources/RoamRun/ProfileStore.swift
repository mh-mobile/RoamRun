import Foundation

final class ProfileStore {
    static let directory: URL = {
        #if DEBUG
        // Tests pass their own folder. This one holds the person's real devices and status.
        let runner = ["xctest", "swiftpm-testing-helper"].contains(ProcessInfo.processInfo.processName)
        if runner { Thread.callStackSymbols.forEach { print("STACK", $0) } }
        precondition(!runner, "a test reached the real Application Support folder; pass a scratch directory")
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RoamRun", isDirectory: true)
    }()
    private let dir: URL
    private let url: URL

    init(directory: URL = ProfileStore.directory) {
        dir = directory
        url = directory.appendingPathComponent("profiles.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Set when profiles.json couldn't be read and was kept aside under this name.
    private(set) var keptUnreadable: URL?
    /// profiles.json is there but couldn't be read at all (permissions, I/O), as of
    /// the last load. Nothing may be written then: the list it would replace is unseen.
    private(set) var unreadable = false

    func load() -> [DeviceProfile] {
        unreadable = false
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return [] }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return [] }
        catch {
            unreadable = true
            return []
        }
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
            guard !unreadable else { return false }
            let before = all
            change(&all)
            return all == before || save(all)   // nothing changed: nothing to write
        } ?? false
    }

    /// Saves `wanted` without dropping what another process wrote since `base`
    /// was read. The app keeps its list in memory for as long as it runs, so a
    /// plain whole-list write would undo the endpoint `roamrun up` had saved
    /// meanwhile. nil if it couldn't be written; otherwise what is on disk now.
    func save(base: [DeviceProfile], wanted: [DeviceProfile]) -> [DeviceProfile]? {
        withLock { () -> [DeviceProfile]? in
            let disk = load()
            guard !unreadable else { return nil }
            let merged = Self.merge(base: base, wanted: wanted, disk: disk)
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
    /// device. For the fields `roamrun up` also writes — where the device is, and
    /// the UDID it learned while bridging — a value this process left alone keeps
    /// whatever is on disk. Without the UDID here, an app that loaded a profile
    /// before the CLI learned one writes its own `nil` back over it, and `roamrun
    /// ota` goes back to not knowing the device.
    static func merge(base: [DeviceProfile], wanted: [DeviceProfile], disk: [DeviceProfile]) -> [DeviceProfile] {
        let was = byID(base), onDisk = byID(disk)
        // A device this process never saw (not in `base`) isn't its to drop: the list
        // it started from was unreadable, or someone else added it. Deleting one here
        // means it was in `base`, so that still sticks.
        let wantedIDs = Set(wanted.map(\.id))
        // …unless it was added here again meanwhile (the list looked empty): that one wins.
        let unseen = disk.filter { d in
            was[d.id] == nil && !wantedIDs.contains(d.id) && !wanted.contains { Self.sameDevice($0, d) }
        }
        return unseen + wanted.map { mine in
            guard let old = was[mine.id], let theirs = onDisk[mine.id] else { return mine }
            var out = mine
            if mine.providerIP == old.providerIP { out.providerIP = theirs.providerIP }
            if mine.remotePairingPort == old.remotePairingPort { out.remotePairingPort = theirs.remotePairingPort }
            if mine.providerHostName == old.providerHostName { out.providerHostName = theirs.providerHostName }
            if mine.udid == old.udid { out.udid = theirs.udid }
            return out
        }
    }

    /// The checks Add Device refuses a second profile on: same address, advert or UDID.
    static func sameDevice(_ a: DeviceProfile, _ b: DeviceProfile) -> Bool {
        (!a.providerIP.isEmpty && a.providerIP == b.providerIP)
            || (!a.instanceName.isEmpty && a.instanceName == b.instanceName)
            || (a.udid != nil && a.udid?.caseInsensitiveCompare(b.udid ?? "") == .orderedSame)
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
