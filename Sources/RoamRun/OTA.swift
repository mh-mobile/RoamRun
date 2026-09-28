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
///     ota/<bundle id>/<version>-<build>-<yyyyMMdd-HHmmss>/app.ipa
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
        /// When the provisioning profile stops working. Checked when the build is
        /// stored, but it is kept for months, so the page has to say it too.
        var expires: Date?

        /// The directory this build lives in. Stored, not derived: it is in URLs
        /// the device already has, and recomputing it from a date would move it
        /// when the Mac changes time zone.
        var slug: String = ""

        /// `1.2.0 (45)`, the way Xcode shows it.
        var label: String { build.isEmpty || build == version ? version : "\(version) (\(build))" }

        /// Only what survives a URL and a file name unchanged; a version like
        /// `1.0 beta` would otherwise be percent-encoded on the way back in.
        static func slug(version: String, build: String, at date: Date) -> String {
            let plain = "\(version)-\(build)-\(stamp.string(from: date))"
            return String(plain.map { urlSafe($0) ? $0 : "-" })
        }

        /// Field by field, like `DeviceProfile`: a build people are relying on
        /// must survive this struct gaining a field, and the only thing here that
        /// can't be guessed is the archive it describes.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bundleID = try c.decode(String.self, forKey: .bundleID)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? bundleID
            version = try c.decodeIfPresent(String.self, forKey: .version) ?? "0"
            build = try c.decodeIfPresent(String.self, forKey: .build) ?? ""
            added = try c.decodeIfPresent(Date.self, forKey: .added) ?? .now
            size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
            expires = try c.decodeIfPresent(Date.self, forKey: .expires)
            slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""   // the directory name replaces it
        }

        init(bundleID: String, title: String, version: String, build: String, added: Date, size: Int64,
             expires: Date? = nil, slug: String = "") {
            self.bundleID = bundleID
            self.title = title
            self.version = version
            self.build = build
            self.added = added
            self.size = size
            self.expires = expires
            self.slug = slug
        }

        /// What goes into a URL without being re-encoded on the way back.
        /// `Character.isLetter` is true for every script there is, and a version
        /// like `1.0-テスト` would come back percent-encoded and match nothing.
        static func urlSafe(_ c: Character) -> Bool {
            c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "-")
        }

        static let stamp: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            return f
        }()
    }

    enum Problem: Error, LocalizedError {
        case notAnArchive(String)
        case development(String)
        case appStore(String)
        case unreadable(String)
        case notForDevice(path: String, name: String, udid: String)
        case udidUnknown(String)
        case oddBundleID(path: String, id: String)
        case expired(path: String, on: Date)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notAnArchive(let p): return "\(p) has no Payload/*.app inside — not an iOS app archive?"
            case .development(let path):
                return "\(path) is signed for Development, which can only be installed through the bridge. Export it for Release Testing (Ad Hoc) or Enterprise to install it over the air."
            case .appStore(let path):
                return "\(path) is signed for App Store / TestFlight and can't be installed over the air. Export it for Release Testing (Ad Hoc) or Enterprise."
            case .unreadable(let p): return "couldn't read \(p)"
            case .notForDevice(let path, let name, let udid):
                return "\(path) isn't signed for \(name) (UDID \(udid) is not in its provisioning profile). Add the device to the profile and export again."
            case .oddBundleID(let path, let id):
                return "\(path)'s bundle identifier (\(id)) has characters that can't go in a web address, so the device couldn't fetch it. Apple's own rule is letters, digits, hyphens and dots."
            case .udidUnknown(let name):
                return "RoamRun doesn't know \(name)'s UDID yet, so it can't tell whether that Ad Hoc build covers it — and iOS would just refuse it on the device. Bridge it once from any Wi-Fi (roamrun up \(CLI.shellName(name)) -d) and the UDID is saved; roamrun devices shows it. An Enterprise build needs none of this."
            case .expired(let path, let date):
                return "\(path)'s provisioning profile expired on \(date.formatted(date: .abbreviated, time: .omitted)) — iOS won't install it. Export it again with a current profile."
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
        let unzip = Proc.run("/usr/bin/unzip", ["-qo", path, "Payload/*.app/Info.plist", "-d", dir.path], timeout: 60)
        // 1 is "warnings, but it worked" and 11 is "nothing matched", which the
        // guard below reports better. Anything above that is a broken archive.
        if unzip.status > 1 && unzip.status != 11 {
            throw Problem.failed("couldn't unpack \(path): \(unzip.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let payload = dir.appendingPathComponent("Payload")
        guard let app = (try? FileManager.default.contentsOfDirectory(atPath: payload.path))?.first(where: { $0.hasSuffix(".app") }),
              let plist = inside(payload.appendingPathComponent(app).appendingPathComponent("Info.plist"), dir),
              let info = NSDictionary(contentsOf: plist) as? [String: Any]
        else { throw Problem.notAnArchive(path) }

        guard let bundleID = info["CFBundleIdentifier"] as? String else { throw Problem.unreadable(path) }
        guard isPlainName(bundleID) else { throw Problem.oddBundleID(path: path, id: bundleID) }
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64) ?? 0

        let version = (info["CFBundleShortVersionString"] as? String) ?? "0"
        let number = (info["CFBundleVersion"] as? String) ?? ""
        let now = Date.now
        return Build(bundleID: bundleID,
                     title: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? bundleID,
                     version: version, build: number, added: now, size: size,
                     slug: Build.slug(version: version, build: number, at: now))
    }

    /// nil when the archive made that name a link to somewhere else on this Mac.
    /// `install` guards its own extraction the same way.
    static func inside(_ url: URL, _ root: URL) -> URL? {
        url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") ? url : nil
    }

    /// A bundle id becomes a directory name, so it may not climb out of `ota/`
    /// or hide the directory from everything that walks it.
    static func isPlainName(_ s: String) -> Bool {
        // A directory name and a URL component both. An `&` would end the
        // itms-services query early; anything non-ASCII comes back encoded.
        !s.isEmpty && !s.hasPrefix(".") && s.count < 200 && s.allSatisfy { Build.urlSafe($0) || $0 == "_" }
    }

    /// Only a build iOS will accept over the air, and for this device if the
    /// profile names devices at all.
    @discardableResult
    static func check(_ plist: [String: Any]?, against udid: String?, name: String, path: String = "That build") throws -> Date? {
        guard let plist else { throw Problem.unreadable("the provisioning profile") }
        let expiry = plist["ExpirationDate"] as? Date
        if let expiry, expiry < .now { throw Problem.expired(path: path, on: expiry) }
        let entitlements = plist["Entitlements"] as? [String: Any]
        switch CLI.parseProvisioning(plist) {
        case .appStore: throw Problem.appStore(path)
        case .allDevices, .unknown: return expiry   // Enterprise covers every device
        case .devices(let list):
            // Development and Ad Hoc both name devices; only the debuggable one is Development.
            if entitlements?["get-task-allow"] as? Bool == true { throw Problem.development(path) }
            guard let udid else { throw Problem.udidUnknown(name) }
            guard list.contains(where: { $0.caseInsensitiveCompare(udid) == .orderedSame }) else {
                throw Problem.notForDevice(path: path, name: name, udid: udid)
            }
            return expiry
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
        guard let best = biggestIcon(icons), let png = inside(appDir.appendingPathComponent(best), dir) else { return nil }
        return repack(png)
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
        if let same = sameArchive(as: path, bundleID: build.bundleID) {
            // Already here byte for byte, so the archive doesn't need storing
            // again — but asking for it now is what going back to it means, and
            // the page puts the most recently added build on top.
            var again = build
            again.slug = same.lastPathComponent
            again.added = .now
            try? JSONEncoder().encode(again).write(to: same.appendingPathComponent("meta.json"), options: .atomic)
            if replacing { drop(build.bundleID, labelled: build.label, keeping: again.slug) }
            return same
        }
        guard !build.slug.isEmpty else { throw Problem.unreadable(path) }
        let app = directory.appendingPathComponent(build.bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        // One writer per app. Two of these at once could each delete what the
        // other had just put in place and both report success.
        let lock = open(app.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        defer { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }
        if lock >= 0 { flock(lock, LOCK_EX) }
        let dir = app.appendingPathComponent(build.slug, isDirectory: true)
        sweepStaging(app)   // a previous add that was killed mid-copy
        // Built somewhere else first: a copy that runs out of disk halfway must
        // not leave a half-written build in the list, and with --replace it must
        // not have taken the working one away before it got there.
        let staging = app.appendingPathComponent(".adding-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            excludeFromBackup(directory)   // .ipa files are big and can be rebuilt
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: staging.appendingPathComponent("app.ipa"))
            try JSONEncoder().encode(build).write(to: staging.appendingPathComponent("meta.json"), options: .atomic)
            if let png = icon(ipa: path) { try? png.write(to: staging.appendingPathComponent("icon.png"), options: .atomic) }
            try FileManager.default.moveItem(at: staging, to: dir)
            // Only now: until the new build is in place, the old one is what the
            // user has, and taking it away first would leave nothing installable.
            if replacing { drop(build.bundleID, labelled: build.label, keeping: build.slug) }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw Problem.failed("couldn't store the build in \(dir.path): \(error.localizedDescription)")
        }
        prune(build.bundleID, keeping: build.slug)
        return dir
    }

    static func hasIcon(_ build: Build) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(build.bundleID)
            .appendingPathComponent(build.slug).appendingPathComponent("icon.png").path)
    }

    /// Everything already stored under the same `1.2.0 (45)`.
    static func drop(_ bundleID: String, labelled label: String, keeping: String? = nil, in root: URL? = nil) {
        let app = (root ?? directory).appendingPathComponent(bundleID, isDirectory: true)
        for old in builds(of: bundleID, in: root) where old.label == label && old.slug != keeping {
            try? FileManager.default.removeItem(at: app.appendingPathComponent(old.slug))
        }
    }

    /// `.adding-*` is hidden from `builds(of:)` so a running add is safe from it,
    /// which also means nothing ever reaps one left by a kill. An hour is longer
    /// than any copy.
    private static func sweepStaging(_ app: URL) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: app.path)) ?? []
        where name.hasPrefix(".adding-") {
            let url = app.appendingPathComponent(name)
            let made = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if made < Date.now.addingTimeInterval(-3600) { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Where an identical .ipa already sits, if it does.
    private static func sameArchive(as path: String, bundleID: String) -> URL? {
        let incomingURL = URL(fileURLWithPath: path)
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64) ?? -1
        let app = directory.appendingPathComponent(bundleID, isDirectory: true)
        let candidates = builds(of: bundleID).filter { $0.size == size }   // the cheap half first
        guard !candidates.isEmpty, let incoming = digest(of: incomingURL) else { return nil }
        for build in candidates {
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

    static func builds(of bundleID: String, in root: URL? = nil) -> [Build] {
        let app = (root ?? directory).appendingPathComponent(bundleID, isDirectory: true)
        let slugs = (try? FileManager.default.contentsOfDirectory(atPath: app.path)) ?? []
        return slugs.compactMap { slug -> Build? in
            guard !slug.hasPrefix(".") else { return nil }
            let dir = app.appendingPathComponent(slug)
            let meta = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: meta) else {
                // Only when it truly isn't there: an add that died before writing
                // it, which nothing can show and nothing would ever remove. A read
                // that failed for another reason (out of descriptors, say) must not
                // cost someone their build, and one that fails to decode may be
                // readable by a later version.
                if !FileManager.default.fileExists(atPath: meta.path) {
                    try? FileManager.default.removeItem(at: dir)
                }
                return nil
            }
            guard var build = try? JSONDecoder().decode(Build.self, from: data) else { return nil }
            build.slug = slug   // where it actually is, whatever the name was built from
            return build
        }.sorted { $0.added > $1.added }
    }

    /// Keeps the newest `keepPerApp`; the rest go with their .ipa.
    static func prune(_ bundleID: String, keeping: String? = nil) {
        let app = directory.appendingPathComponent(bundleID, isDirectory: true)
        for old in builds(of: bundleID).dropFirst(keepPerApp) where old.slug != keeping {
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
