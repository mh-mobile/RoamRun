import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

    // MARK: - Icon

    /// The app's icon, re-encoded as a PNG a browser will draw. Xcode rewrites
    /// icons into Apple's CgBI variant, which only Apple's decoders understand —
    /// CoreGraphics reads it here and writes an ordinary PNG back out.
    /// nil when the archive has no icon; the page just shows the name then.
    static func icon(ipa path: String) -> Data? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-icon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = Proc.run("/usr/bin/unzip", ["-qo", path, "Payload/*.app/AppIcon*.png", "-d", dir.path], timeout: 60)
        let payload = dir.appendingPathComponent("Payload")
        guard let app = (try? FileManager.default.contentsOfDirectory(atPath: payload.path))?.first(where: { $0.hasSuffix(".app") })
        else { return nil }
        let appDir = payload.appendingPathComponent(app)
        let icons = (try? FileManager.default.contentsOfDirectory(atPath: appDir.path))?.filter { $0.hasPrefix("AppIcon") } ?? []
        guard let best = biggestIcon(icons) else { return nil }
        return repack(appDir.appendingPathComponent(best))
    }

    /// iPhone icons before iPad ones, then the highest scale: the page is read on
    /// a phone, and a larger source only ever looks better scaled down.
    static func biggestIcon(_ names: [String]) -> String? {
        func score(_ n: String) -> (Int, Int) {
            let scale = n.contains("@3x") ? 3 : n.contains("@2x") ? 2 : 1
            let size = Int(n.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })) ?? 0
            return (n.contains("~ipad") ? 0 : 1, size * scale)
        }
        return names.sorted { score($0) > score($1) }.first
    }

    private static func repack(_ url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - Storing

    @discardableResult
    static func add(ipa path: String, _ build: Build, replacing: Bool = false) throws -> URL {
        // The same archive handed over twice: two rows the eye can't tell apart,
        // and one fewer slot for a build that is actually different. A rebuild
        // that kept its version number is not the same archive and still stacks,
        // unless the caller says it is a redo of the one already there.
        // Dropping first: otherwise handing back the identical archive already
        // stored would return before --replace got a chance to clear the rest.
        if replacing { drop(build.bundleID, labelled: build.label) }
        if let same = sameArchive(as: path, bundleID: build.bundleID) { return same }
        let dir = directory.appendingPathComponent(build.bundleID, isDirectory: true)
            .appendingPathComponent(build.slug, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            excludeFromBackup(directory)   // .ipa files are big and can be rebuilt
            let ipa = dir.appendingPathComponent("app.ipa")
            try? FileManager.default.removeItem(at: ipa)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: ipa)
            try JSONEncoder().encode(build).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
            if let png = icon(ipa: path) { try? png.write(to: dir.appendingPathComponent("icon.png"), options: .atomic) }
        } catch {
            throw Problem.failed("couldn't store the build in \(dir.path): \(error.localizedDescription)")
        }
        prune(build.bundleID)
        return dir
    }

    static func hasIcon(_ build: Build) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(build.bundleID)
            .appendingPathComponent(build.slug).appendingPathComponent("icon.png").path)
    }

    /// Everything already stored under the same `1.2.0 (45)`.
    private static func drop(_ bundleID: String, labelled label: String) {
        let app = directory.appendingPathComponent(bundleID, isDirectory: true)
        for old in builds(of: bundleID) where old.label == label {
            try? FileManager.default.removeItem(at: app.appendingPathComponent(old.slug))
        }
    }

    /// Where an identical .ipa already sits, if it does.
    private static func sameArchive(as path: String, bundleID: String) -> URL? {
        guard let incoming = digest(of: URL(fileURLWithPath: path)) else { return nil }
        let app = directory.appendingPathComponent(bundleID, isDirectory: true)
        for build in builds(of: bundleID) {
            let dir = app.appendingPathComponent(build.slug)
            if digest(of: dir.appendingPathComponent("app.ipa")) == incoming { return dir }
        }
        return nil
    }

    /// Read in pieces: an .ipa can be hundreds of megabytes.
    static func digest(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
