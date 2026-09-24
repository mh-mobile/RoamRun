import Foundation

final class ProfileStore {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RoamRun", isDirectory: true)
    private let url = directory.appendingPathComponent("profiles.json")

    init() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
    }

    func load() -> [DeviceProfile] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([DeviceProfile].self, from: data)) ?? []
    }

    func save(_ profiles: [DeviceProfile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
