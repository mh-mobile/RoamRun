import Foundation

final class ProfileStore {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RoamRun", isDirectory: true)
    private let url = directory.appendingPathComponent("profiles.json")

    init() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
    }

    /// Set when profiles.json couldn't be read and was kept aside under this name.
    private(set) var keptUnreadable: URL?

    func load() -> [DeviceProfile] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let profiles = try? JSONDecoder().decode([DeviceProfile].self, from: data) { return profiles }
        // The next save would replace it with an empty list: keep a copy, once per distinct content.
        let fm = FileManager.default
        let kept = (try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        if let same = kept.first(where: { $0.lastPathComponent.hasPrefix("profiles.json.unreadable") && (try? Data(contentsOf: $0)) == data }) {
            keptUnreadable = same
        } else {
            let copy = url.appendingPathExtension("unreadable-\(Int(Date.now.timeIntervalSince1970))")
            if (try? fm.copyItem(at: url, to: copy)) != nil { keptUnreadable = copy }
        }
        return []
    }

    /// False if it couldn't be written (disk full, permissions): the caller must say so.
    @discardableResult
    func save(_ profiles: [DeviceProfile]) -> Bool {
        guard let data = try? JSONEncoder().encode(profiles), (try? data.write(to: url, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }
}
