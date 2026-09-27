import Foundation

/// Builds kept for installing over the air, when the device can't be on Wi-Fi
/// and so can't be bridged. iOS fetches a manifest over HTTPS and installs from
/// it, which works on cellular — the Wi-Fi requirement belongs to RemotePairing,
/// not to the mesh VPN.
///
/// Layout, one directory per build:
///
///     ota/<bundle id>/<version>-<build>-<yyyyMMdd-HHmm>/app.ipa
///                                                      /meta.json
///
/// The manifest and the page are generated when they're asked for, so a build
/// keeps working when the tailnet name changes.
enum OTA {
    static var directory: URL { ProfileStore.directory.appendingPathComponent("ota", isDirectory: true) }

    /// How many builds of one app are kept. An .ipa is tens of megabytes, and
    /// what the extra ones buy you is going back one or two versions, not an archive.
    static let keepPerApp = 5

    struct Build: Codable, Equatable {
        var bundleID: String
        var title: String
        var version: String
        var build: String
        var added: Date
        var size: Int64
        /// UDIDs the profile covers; nil for Enterprise, which covers every device.
        var devices: [String]?

        /// `1.2.0 (45)`, the way Xcode shows it.
        var label: String { build.isEmpty || build == version ? version : "\(version) (\(build))" }
        var slug: String { "\(version)-\(build)-\(Self.stamp.string(from: added))" }

        static let stamp: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmm"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()
    }

    enum Problem: Error, LocalizedError {
        case notAnArchive(String)
        case development
        case appStore
        case unreadable(String)
        case notForDevice(name: String, udid: String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notAnArchive(let p): return "\(p) has no Payload/*.app inside — not an iOS app archive?"
            case .development:
                return "That build is signed for Development, which can only be installed through the bridge. Export it for Release Testing (Ad Hoc) or Enterprise to install it over the air."
            case .appStore:
                return "That build is signed for App Store / TestFlight and can't be installed over the air. Export it for Release Testing (Ad Hoc) or Enterprise."
            case .unreadable(let p): return "couldn't read \(p)"
            case .notForDevice(let name, let udid):
                return "That build isn't signed for \(name) (UDID \(udid) is not in its provisioning profile). Add the device to the profile and export again."
            case .failed(let why): return why
            }
        }
    }

    // MARK: - Reading an archive

    /// What the .ipa says about itself, or why it can't be served.
    static func read(ipa path: String) throws -> Build {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-ota-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = Proc.run("/usr/bin/unzip", ["-qo", path, "Payload/*.app/Info.plist", "-d", dir.path], timeout: 60)
        let payload = dir.appendingPathComponent("Payload")
        guard let app = (try? FileManager.default.contentsOfDirectory(atPath: payload.path))?.first(where: { $0.hasSuffix(".app") }),
              let info = NSDictionary(contentsOf: payload.appendingPathComponent(app).appendingPathComponent("Info.plist")) as? [String: Any]
        else { throw Problem.notAnArchive(path) }

        guard let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty else { throw Problem.unreadable(path) }
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64) ?? 0

        return Build(bundleID: bundleID,
                     title: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? bundleID,
                     version: (info["CFBundleShortVersionString"] as? String) ?? "0",
                     build: (info["CFBundleVersion"] as? String) ?? "",
                     added: .now, size: size, devices: nil)
    }

    /// Only a build iOS will accept over the air, and for this device if the
    /// profile names devices at all.
    static func check(_ plist: [String: Any]?, against udid: String?, name: String) throws -> [String]? {
        guard let plist else { throw Problem.unreadable("the provisioning profile") }
        let entitlements = plist["Entitlements"] as? [String: Any]
        switch CLI.parseProvisioning(plist) {
        case .appStore: throw Problem.appStore
        case .allDevices, .unknown: return nil   // Enterprise covers every device
        case .devices(let list):
            // Development and Ad Hoc both name devices; only the debuggable one is Development.
            if entitlements?["get-task-allow"] as? Bool == true { throw Problem.development }
            if let udid, !list.contains(where: { $0.caseInsensitiveCompare(udid) == .orderedSame }) {
                throw Problem.notForDevice(name: name, udid: udid)
            }
            return list
        }
    }

    // MARK: - Storing

    @discardableResult
    static func add(ipa path: String, _ build: Build) throws -> URL {
        let dir = directory.appendingPathComponent(build.bundleID, isDirectory: true)
            .appendingPathComponent(build.slug, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            excludeFromBackup(directory)   // .ipa files are big and can be rebuilt
            let ipa = dir.appendingPathComponent("app.ipa")
            try? FileManager.default.removeItem(at: ipa)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: ipa)
            try JSONEncoder().encode(build).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        } catch {
            throw Problem.failed("couldn't store the build in \(dir.path): \(error.localizedDescription)")
        }
        prune(build.bundleID)
        return dir
    }

    /// Newest first, per app.
    static func builds() -> [(bundleID: String, builds: [Build])] {
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return apps.sorted().compactMap { app in
            let list = builds(of: app)
            return list.isEmpty ? nil : (app, list)
        }
    }

    static func builds(of bundleID: String) -> [Build] {
        let app = directory.appendingPathComponent(bundleID, isDirectory: true)
        let slugs = (try? FileManager.default.contentsOfDirectory(atPath: app.path)) ?? []
        return slugs.compactMap { slug -> Build? in
            guard let data = try? Data(contentsOf: app.appendingPathComponent(slug).appendingPathComponent("meta.json")),
                  let build = try? JSONDecoder().decode(Build.self, from: data) else { return nil }
            return build
        }.sorted { $0.added > $1.added }
    }

    /// Keeps the newest `keepPerApp`; the rest go with their .ipa.
    static func prune(_ bundleID: String) {
        let app = directory.appendingPathComponent(bundleID, isDirectory: true)
        for old in builds(of: bundleID).dropFirst(keepPerApp) {
            try? FileManager.default.removeItem(at: app.appendingPathComponent(old.slug))
        }
    }

    /// Time Machine would otherwise carry every build; they're rebuildable.
    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
