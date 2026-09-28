import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Builds a device can install by itself, without the bridge. iOS fetches a
/// manifest over HTTPS and installs from it, which the mesh VPN carries over
/// Wi-Fi and cellular alike — the Wi-Fi requirement belongs to RemotePairing,
/// not to this.
///
/// Layout, one directory per build, plus a lock the writers share:
///
///     ota/<bundle id>/.lock
///                    /<version>-<build>-<yyyyMMdd-HHmmss>/app.ipa
///                                                        /meta.json
///                                                        /icon.png   (if it has one)
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
            let safe = String(plain.map { urlSafe($0) ? $0 : "-" })
            // A leading dot would make a directory that everything walking the
            // folder skips, so the build would vanish the moment it was stored.
            return safe.hasPrefix(".") ? "v" + safe : safe
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
            added = try c.decodeIfPresent(Date.self, forKey: .added) ?? .distantPast
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

    enum Problem: Error, LocalizedError, Equatable {
        case notAnArchive(String)
        case development(String)
        case appStore(String)
        case unreadable(String)
        case notForDevice(path: String, names: [String])
        case udidUnknown([String])
        case oddBundleID(path: String, id: String)
        case expired(path: String, on: Date)
        case failed(String)

        /// "a, b and c" — a list a person reads, not an array printed.
        private func list(_ names: [String]) -> String {
            names.count < 2 ? (names.first ?? "")
                : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }

        var errorDescription: String? {
            switch self {
            case .notAnArchive(let p): return "\(p) has no Payload/*.app inside — not an iOS app archive?"
            case .development(let path):
                return "\(path) is signed for Development, which can only be installed through the bridge. Export it for Release Testing (Ad Hoc) or Enterprise to install it over the air."
            case .appStore(let path):
                return "\(path) is signed for App Store / TestFlight and can't be installed over the air. Export it for Release Testing (Ad Hoc) or Enterprise."
            case .unreadable(let p): return "couldn't read \(p)"
            case .notForDevice(let path, let names):
                let who = names.count == 1 ? names[0] : "any of \(list(names))"
                return "\(path) isn't signed for \(who) — its provisioning profile doesn't name \(names.count == 1 ? "that device" : "them"). Add the device in Apple's developer account and export again; bridging it once (roamrun up <name> -d) lets Xcode register it for you."
            case .oddBundleID(let path, let id):
                return "\(path)'s bundle identifier (\(id)) has characters that can't go in a web address, so the device couldn't fetch it. Apple's own rule is letters, digits, hyphens and dots; RoamRun also allows underscores."
            case .udidUnknown(let names):
                let who = names.isEmpty ? "any device" : (names.count == 1 ? names[0] : "any of \(list(names))")
                let how = names.count == 1 ? "Bridge it once from any Wi-Fi (roamrun up \(CLI.shellName(names[0])) -d)"
                                           : "Bridge one once from any Wi-Fi (roamrun up <name> -d)"
                return "RoamRun doesn't know the UDID of \(who) yet, so it can't tell whether that Ad Hoc build covers \(names.count == 1 ? "it" : "one") — and iOS would just refuse it on the device. \(how) and the UDID is saved; roamrun devices shows it. An Enterprise build needs none of this."
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
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        // `try?` here would surface as "couldn't unpack", which names the wrong thing.
        catch { throw Problem.failed("couldn't make \(dir.path): \(error.localizedDescription)") }
        let unzip = Proc.run("/usr/bin/unzip", ["-qo", path, "Payload/*.app/Info.plist", "-d", dir.path], timeout: 60)
        // 1 is "warnings, but it worked" and 11 is "nothing matched", which the
        // guard below reports better. Anything above that is a broken archive.
        if unzip.status < 0 || (unzip.status > 1 && unzip.status != 11) {
            throw Problem.failed("couldn't unpack \(path): \(unzip.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let payload = dir.appendingPathComponent("Payload")
        guard let app = appBundle(in: payload),
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

    /// The one `.app` an archive's `Payload/` is about. Sorted, because
    /// `contentsOfDirectory` isn't: `CLI.profilePlist` unpacks the same archive
    /// separately and has to land on the same bundle, or the identifier and the
    /// provisioning profile would come from two different apps.
    static func appBundle(in payload: URL) -> String? {
        ((try? FileManager.default.contentsOfDirectory(atPath: payload.path)) ?? [])
            .filter { $0.hasSuffix(".app") }.sorted().first
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

    /// A device an Ad Hoc profile may or may not name. RoamRun knows the UDID of
    /// every device it has bridged, and the page offers a build to all of them at
    /// once, so the question is which of yours it covers — not which you named.
    struct Device {
        let name: String
        let udid: String?
    }

    /// Which of your devices a build will install on.
    enum Coverage: Equatable {
        /// Enterprise: every device there is, yours or not.
        case everyDevice
        /// Ad Hoc, and it names these of yours. `unchecked` are the ones RoamRun
        /// hasn't learned a UDID for, so a `covers` list isn't read as "and no others".
        case devices(covers: [String], unchecked: [String])
        /// It names devices and none of them are yours — or RoamRun knows no UDID
        /// at all. Still storable: the page is open to the whole tailnet and the
        /// build may be for a device this Mac has never seen. The caller says so.
        case noneOfYours(known: [String], unchecked: [String])
    }

    /// Only a build iOS will accept over the air at all. What it will *not*
    /// install — App Store signing, Development signing, an expired profile — is
    /// an error; which of your devices it covers is an answer, not a verdict.
    static func check(_ plist: [String: Any]?, against devices: [Device],
                      path: String = "That build") throws -> (expires: Date?, coverage: Coverage) {
        guard let plist else {
            throw Problem.unreadable("the provisioning profile in \(path) — the archive may be unsigned. " +
                                     "Export it for Release Testing (Ad Hoc) or Enterprise.")
        }
        let expiry = plist["ExpirationDate"] as? Date
        if let expiry, expiry < .now { throw Problem.expired(path: path, on: expiry) }
        let entitlements = plist["Entitlements"] as? [String: Any]
        switch CLI.parseProvisioning(plist) {
        case .appStore: throw Problem.appStore(path)
        case .allDevices: return (expiry, .everyDevice)
        case .unknown: throw Problem.unreadable("the provisioning profile in \(path)")
        case .devices(let list):
            // Development and Ad Hoc both name devices; only the debuggable one is
            // Development. Without entitlements there is nothing to tell them
            // apart by, and guessing Ad Hoc means iOS refuses it with no reason given.
            guard let entitlements else { throw Problem.unreadable("the entitlements in \(path)'s provisioning profile") }
            if entitlements["get-task-allow"] as? Bool == true { throw Problem.development(path) }
            let known = devices.compactMap { d in d.udid.map { (name: d.name, udid: $0) } }
            let unchecked = devices.filter { $0.udid == nil }.map(\.name)
            let covers = known.filter { d in
                list.contains { $0.caseInsensitiveCompare(d.udid) == .orderedSame }
            }.map(\.name)
            guard !covers.isEmpty else {
                return (expiry, .noneOfYours(known: known.map(\.name), unchecked: unchecked))
            }
            return (expiry, .devices(covers: covers, unchecked: unchecked))
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
        guard let app = appBundle(in: payload) else { return nil }
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

    /// Where it landed, and how many builds `--replace` was meant to remove but
    /// couldn't (nil: couldn't even look). Storing succeeded and the replacing
    /// didn't are different answers, and only one of them is in the return value.
    @discardableResult
    static func add(ipa path: String, _ build: Build, replacing: Bool = false,
                    in root: URL? = nil) throws -> (dir: URL, notReplaced: Int?) {
        guard !build.slug.isEmpty else { throw Problem.unreadable(path) }
        let store = root ?? directory
        let app = store.appendingPathComponent(build.bundleID, isDirectory: true)
        do {
            // Not `try?`: when this fails, the `open` below fails too, and
            // "couldn't lock" is a strange thing to tell someone whose disk is full.
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        } catch {
            throw Problem.failed("couldn't make \(app.path): \(error.localizedDescription)")
        }
        excludeFromBackup(store)   // .ipa files are big and can be rebuilt
        // Signed builds of the user's own apps; no other account here needs them.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path)
        // One writer per app, taken before anything is looked at: two of these at
        // once could each delete what the other had just put in place, and both
        // report success. That includes the same-archive path below, which also
        // writes and deletes.
        let lock = open(app.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else {
            throw Problem.failed("couldn't lock \(app.path) (\(String(cString: strerror(errno)))) — " +
                                 "storing without it could lose a build another roamrun is writing")
        }
        defer { flock(lock, LOCK_UN); close(lock) }
        var held = flock(lock, LOCK_EX)
        while held != 0 && errno == EINTR { held = flock(lock, LOCK_EX) }
        guard held == 0 else {
            throw Problem.failed("couldn't lock \(app.path) (\(String(cString: strerror(errno)))) — " +
                                 "storing without it could lose a build another roamrun is writing")
        }

        // Under the lock and before anything else: the read paths no longer reap,
        // and a run whose adds are all duplicates used to reach neither sweep.
        sweepStaging(app)
        reapOrphans(app)

        // The same archive handed over twice: two rows the eye can't tell apart,
        // and one fewer slot for a build that is actually different. A rebuild
        // that kept its version number is not the same archive and still stacks,
        // unless the caller says it is a redo of the one already there.
        if let same = sameArchive(as: path, bundleID: build.bundleID, in: store) {
            // Already here byte for byte, so the archive doesn't need storing
            // again — but asking for it now is what going back to it means, and
            // the page puts the most recently added build on top.
            var again = build
            again.slug = same.lastPathComponent
            again.added = .now
            do {
                try JSONEncoder().encode(again).write(to: same.appendingPathComponent("meta.json"), options: .atomic)
            } catch {
                // Nothing else happens on this path, so a swallowed failure here is
                // "Stored." for a build that didn't move, still the oldest row, and
                // first in line to be pruned.
                throw Problem.failed("couldn't update \(same.path): \(error.localizedDescription)")
            }
            let missed = replacing ? drop(build.bundleID, labelled: build.label, keeping: again.slug, in: store) : 0
            return (same, missed)
        }
        // The slug counts in seconds, so a script adding two different archives
        // back to back can land on a name that exists. `moveItem` would fail with
        // "File exists", which says nothing about what happened.
        var stored = build
        var n = 1
        while FileManager.default.fileExists(atPath: app.appendingPathComponent(stored.slug).path) {
            n += 1
            stored.slug = "\(build.slug)-\(n)"
        }
        let dir = app.appendingPathComponent(stored.slug, isDirectory: true)
        // Built somewhere else first: a copy that runs out of disk halfway must
        // not leave a half-written build in the list, and with --replace it must
        // not have taken the working one away before it got there.
        let staging = app.appendingPathComponent(".adding-\(UUID().uuidString)", isDirectory: true)
        var missed: Int?
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: staging.appendingPathComponent("app.ipa"))
            try JSONEncoder().encode(stored).write(to: staging.appendingPathComponent("meta.json"), options: .atomic)
            if let png = icon(ipa: path) { try? png.write(to: staging.appendingPathComponent("icon.png"), options: .atomic) }
            try FileManager.default.moveItem(at: staging, to: dir)
            // Only now: until the new build is in place, the old one is what the
            // user has, and taking it away first would leave nothing installable.
            missed = replacing ? drop(stored.bundleID, labelled: stored.label, keeping: stored.slug, in: store) : 0
        } catch {
            try? FileManager.default.removeItem(at: staging)
            // The app folder stays, empty or not: it holds the `.lock` this call
            // is holding, and removing it would let the next two writers take
            // locks on different inodes. `appDirectories` already refuses to
            // publish a folder with nothing but dot files in it.
            throw Problem.failed("couldn't store the build in \(dir.path): \(error.localizedDescription)")
        }
        prune(stored.bundleID, keeping: stored.slug, in: store)
        return (dir, missed)
    }

    static func hasIcon(_ build: Build, in root: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (root ?? directory).appendingPathComponent(build.bundleID)
            .appendingPathComponent(build.slug).appendingPathComponent("icon.png").path)
    }

    /// Everything already stored under the same `1.2.0 (45)`. Returns how many it
    /// couldn't remove — a locked folder means `--replace` didn't replace, and
    /// reporting success then leaves the old build on the page — or nil when the
    /// folder couldn't be read, where "nothing to remove" would be a guess.
    @discardableResult
    static func drop(_ bundleID: String, labelled label: String, keeping: String? = nil,
                     in root: URL? = nil) -> Int? {
        let app = (root ?? directory).appendingPathComponent(bundleID, isDirectory: true)
        guard let all = builds(of: bundleID, in: root) else { return nil }
        var missed = 0
        for old in all where old.label == label && old.slug != keeping {
            do { try FileManager.default.removeItem(at: app.appendingPathComponent(old.slug)) }
            catch { missed += 1 }
        }
        return missed
    }

    /// `.adding-*` is hidden from `builds(of:)` so a running add is safe from it,
    /// which also means nothing ever reaps one left by a kill. An hour is longer
    /// than any copy.
    static func sweepStaging(_ app: URL) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: app.path)) ?? []
        where name.hasPrefix(".adding-") {
            let url = app.appendingPathComponent(name)
            let made = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if made < Date.now.addingTimeInterval(-3600) { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Where an identical .ipa already sits, if it does.
    private static func sameArchive(as path: String, bundleID: String, in root: URL) -> URL? {
        let incomingURL = URL(fileURLWithPath: path)
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64) ?? -1
        let app = root.appendingPathComponent(bundleID, isDirectory: true)
        let candidates = (builds(of: bundleID, in: root) ?? []).filter { $0.size == size }   // the cheap half first
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
        // Not `try?`: a read that fails halfway would return a well-formed digest
        // of a prefix, and two of those can match archives that don't.
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        } catch { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The app folders with something in them, or nil when the directory is there
    /// but couldn't be read — a descriptor limit, a permission change anywhere
    /// above it. Callers treat nil as "ask again later": reading it as "nothing
    /// stored" is what takes a live page down mid-download.
    ///
    /// The error says which it is. `fileExists` can't: it is false both for a
    /// path that isn't there and for one whose parent you can't get into.
    static func appDirectories(in root: URL? = nil) -> [String]? {
        let store = root ?? directory
        guard let found = entries(of: store) else { return nil }
        var apps: [String] = []
        for name in found where !name.hasPrefix(".") {
            // Every level, not just the top one: `try?` here would have said "no
            // such app" for a folder that was merely unreadable, which is the
            // whole defect this function exists to avoid.
            guard let inside = entries(of: store.appendingPathComponent(name)) else { return nil }
            // A folder holding nothing but `.lock` is one an add made and then
            // failed in, or one whose builds were removed by hand. Counting it
            // keeps the page published with nothing on it.
            if inside.contains(where: { !$0.hasPrefix(".") }) { apps.append(name) }
        }
        return apps
    }

    /// What is in a directory: `[]` when it isn't there, nil when it is but
    /// couldn't be read. `fileExists` can't tell those apart — it is false for a
    /// path that is absent and for one whose parent you can't get into — and
    /// reading the second as the first is what takes a live page down.
    private static func entries(of url: URL) -> [String]? {
        do { return try FileManager.default.contentsOfDirectory(atPath: url.path) }
        catch CocoaError.fileReadNoSuchFile { return [] }   // deleting it is the off switch
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return []
        }
        catch { return nil }
    }

    /// Newest first, per app. nil when something couldn't be read, at any level —
    /// an empty page is a lie about a folder we simply couldn't open.
    static func builds(in root: URL? = nil) -> [(bundleID: String, builds: [Build])]? {
        guard let apps = appDirectories(in: root) else { return nil }
        var out: [(bundleID: String, builds: [Build])] = []
        for app in apps.sorted() {
            guard let list = builds(of: app, in: root) else { return nil }
            if !list.isEmpty { out.append((app, list)) }
        }
        return out
    }

    /// nil when the folder couldn't be enumerated. Purely a read: a build with no
    /// `meta.json` is left where it is, because deciding that from a request the
    /// tailnet sent is not the place to delete anything. `add` reaps them.
    static func builds(of bundleID: String, in root: URL? = nil) -> [Build]? {
        let app = (root ?? directory).appendingPathComponent(bundleID, isDirectory: true)
        guard let slugs = entries(of: app) else { return nil }
        return slugs.compactMap { slug -> Build? in
            guard !slug.hasPrefix(".") else { return nil }
            let dir = app.appendingPathComponent(slug)
            // A read that failed for another reason (out of descriptors, say) must
            // not cost someone their build, and one that fails to decode may be
            // readable by a later version.
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
                  var build = try? JSONDecoder().decode(Build.self, from: data) else { return nil }
            build.slug = slug              // where it actually is, whatever the name was built from
            build.bundleID = bundleID      // and under which folder; the manifest's URLs are made from both
            return build
        }.sorted { $0.added > $1.added }
    }

    /// Build folders whose `meta.json` is there but no version here can decode —
    /// kept, because a later one may read it, and so invisible to everything else.
    static func unreadableBuilds(of bundleID: String, in root: URL? = nil) -> Int {
        let app = (root ?? directory).appendingPathComponent(bundleID, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: app.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .count { slug in
                guard let data = try? Data(contentsOf: app.appendingPathComponent(slug)
                    .appendingPathComponent("meta.json")) else { return false }
                return (try? JSONDecoder().decode(Build.self, from: data)) == nil
            }
    }

    /// A build directory with no `meta.json` at all: an add that died before
    /// writing it. Nothing can show it and nothing else would ever remove it.
    /// Only from `add`, which holds the lock — a half-written build is exactly
    /// what this would delete if it ran while one was being made.
    private static func reapOrphans(_ app: URL) {
        for slug in (try? FileManager.default.contentsOfDirectory(atPath: app.path)) ?? []
        where !slug.hasPrefix(".") {
            let dir = app.appendingPathComponent(slug)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
                  !FileManager.default.fileExists(atPath: dir.appendingPathComponent("meta.json").path)
            else { continue }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Keeps the newest `keepPerApp`; the rest go with their .ipa. The one being
    /// kept counts towards the limit: `added` is taken before the lock, so a build
    /// that waited can sort last, and dropping it from the tail left six.
    static func prune(_ bundleID: String, keeping: String? = nil, in root: URL? = nil) {
        let app = (root ?? directory).appendingPathComponent(bundleID, isDirectory: true)
        let all = builds(of: bundleID, in: root) ?? []
        let kept = all.filter { $0.slug == keeping } + all.filter { $0.slug != keeping }
        for old in kept.dropFirst(keepPerApp) {
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
