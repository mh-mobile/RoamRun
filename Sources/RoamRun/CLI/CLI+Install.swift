import CoreImage
import Foundation

extension CLI {
    /// Keeps a build where the device can fetch it over HTTPS, bridge or no
    /// bridge. Nothing is built here: exporting an .ipa needs the project's own
    /// signing settings.
    static func ota(_ profiles: [DeviceProfile], path given: String, replacing: Bool) -> Never {
        guard FileManager.default.fileExists(atPath: given) else { stop("\(given) doesn't exist") }
        sweepStaleUnpacks(in: FileManager.default.temporaryDirectory) // an interrupted earlier run's unpacking
        // A build script's `latest.ipa -> MyApp-1.2.ipa` would otherwise be stored
        // as the link itself: a few bytes, and nothing to serve.
        let path = URL(fileURLWithPath: given).resolvingSymlinksInPath().path
        // A trailing slash is how a shell completes a directory; .ipa is a file either way.
        guard path.lowercased().trimmingCharacters(in: ["/"]).hasSuffix(".ipa") else {
            stop("\(given) isn't an .ipa — over-the-air installs need an archive, not an .app bundle")
        }
        let running = StatusFile.read()
        let devices = profiles.map {
            OTA.Device(name: $0.displayName, udid: running[$0.id]?.udid ?? $0.udid)
        }
        do {
            var build = try OTA.read(ipa: path)
            let checked = try OTA.check(CLI.profilePlist(of: path), against: devices, path: given)
            build.expires = checked.expires
            // Not while nothing of yours can take it: `--replace` would remove the
            // build people are running to make room for one they can't install,
            // and there would be no way back to it.
            var noneOfYours = false
            if case .noneOfYours = checked.coverage {
                noneOfYours = true
            }
            let added = try OTA.add(ipa: path, build, replacing: replacing && !noneOfYours)

            print("Stored \(build.title) \(build.label) (\(OTA.size(build.size))).")
            // Which devices, not whether: an Ad Hoc profile covers the ones it
            // names, and the page offers the build to all of them at once.
            switch checked.coverage {
            case .everyDevice:
                print("  Enterprise signing — it installs on any device.")
            case .devices(let covers, let unchecked):
                print("  Installs on: \(covers.joined(separator: ", ")).")
                // Said out loud, or the line above reads as "and on no others".
                if !unchecked.isEmpty {
                    print("  Can't tell for \(unchecked.joined(separator: ", ")) — " +
                        "bridge one once and RoamRun learns its UDID.")
                }
            case .noneOfYours(let known, let unchecked):
                // Stored, not refused: the page is open to the whole tailnet and
                // the profile may name a device this Mac has never seen. But
                // nobody here can install it, and that has to be said plainly —
                // without claiming anything about the ones it couldn't check.
                print("  WARNING: its provisioning profile doesn't name " +
                    (known.isEmpty ? "any device RoamRun has a UDID for" : known.joined(separator: ", ")) + ".")
                if !unchecked.isEmpty {
                    print("  Can't tell for \(unchecked.joined(separator: ", ")) — " +
                        "bridge one once and RoamRun learns its UDID.")
                }
                print("  Whoever installs it needs a device that is in the profile; iOS refuses the rest.")
                if replacing {
                    print("  --replace was ignored: it would have removed a build that does install.")
                }
            }
            switch added.notReplaced {
            case nil:
                print("  Couldn't read the folder, so --replace may not have removed the older builds.")
            case .some(let n) where n > 0:
                print("  Couldn't remove \(n) older build\(n == 1 ? "" : "s") under that version — " +
                    "--replace left \(n == 1 ? "it" : "them") on the page.")
            default: break
            }
            let tailnetPort = AppCoordinator.otaPort
            let host: String?
            do { host = try TailscaleClient.fromSettings().selfDNSName() } catch {
                stop("\(error.localizedDescription). The build is stored; run this again once Tailscale can answer.")
            }
            guard let host else {
                stop("Tailscale didn't give this Mac a name — turn MagicDNS on for your tailnet. The build is stored.")
            }
            let url = "https://\(host):\(tailnetPort)/"
            let state = TailscaleClient.serving(port: tailnetPort)
            let here = state.root(on: host)
            let beside = state.alongside(host)
            if state.funnelled(on: host) {
                print("  WARNING: Tailscale Funnel is on for port \(tailnetPort), so that page is on the")
                print("  public internet. Turn it off: tailscale funnel --https=\(tailnetPort) off")
            }
            // `here == nil` is a free port under this name, the same reading the app
            // uses: a root left under a name the tailnet no longer knows is inert.
            if case .mounted = state,
               !(beside.isEmpty && (here == nil || AppCoordinator.isOurs(here!, on: tailnetPort)))
            {
                // Same three situations the app distinguishes, same three answers.
                let why: String
                if !beside.isEmpty {
                    why = "port \(tailnetPort) also carries \(beside.joined(separator: ", ")), and RoamRun keeps\n" +
                        "  a port to itself. Give it another one:\n" +
                        "    defaults write \(AppID.bundle) otaPort -int 41444"
                } else if AppCoordinator.abandoned(here) {
                    why = "port \(tailnetPort) is serving \(state.described) with nothing behind it, so a run\n" +
                        "  was killed before it gave the port back:\n" +
                        "    tailscale serve --https=\(tailnetPort) --set-path=/ off"
                } else {
                    why = "port \(tailnetPort) is serving \(state.described), which isn't RoamRun's, so that\n" +
                        "  address won't reach it. Give RoamRun another port:\n" +
                        "    defaults write \(AppID.bundle) otaPort -int 41444"
                }
                stop("the build is stored, but \(why)")
            }
            if !TailscaleClient.servingLive(port: tailnetPort, host: host) {
                // Named first when it is the cause: without certificates
                // `tailscale serve` writes nothing and still exits 0, so waiting
                // for the page is waiting for something that will never appear.
                if TailscaleClient.httpsEnabled() == false {
                    print("  Your tailnet doesn't issue HTTPS certificates, so the page can't be served.")
                    print("  Turn them on for the tailnet (Tailscale admin console › DNS › HTTPS Certificates).")
                } else {
                    print("  RoamRun publishes the page while it runs, so it has to be open; it can take")
                    print("  half a minute to appear. If it doesn't, look in Open RoamRun › ⚙ Settings ›")
                    print("  Troubleshooting › Recent messages.")
                }
            }
            print("  Open on the device: \(url)")
            print("  Anyone on your tailnet can open that page and install these builds.")
            if isatty(STDOUT_FILENO) != 0 {
                print(qr(url))
            }
            exit(0)
        } catch {
            stop(error.localizedDescription)
        }
    }

    /// The address, for pointing the device's camera at instead of typing it.
    /// Two rows of pixels per line, so it fits a terminal.
    static func qr(_ text: String) -> String {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return "" }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return "" }
        let context = CIContext()
        guard let cg = context.createCGImage(image, from: image.extent) else { return "" }
        let w = cg.width, h = cg.height
        guard let gray = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return "" }
        gray.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let pixels = gray.data?.assumingMemoryBound(to: UInt8.self) else { return "" }
        func dark(_ x: Int, _ y: Int) -> Bool {
            y < 0 || y >= h ? false : pixels[y * w + x] < 128
        }
        let quiet = 2
        // Black on white, said explicitly: a block character takes the terminal's
        // own foreground colour, so on a dark theme the code would come out
        // inverted — which a camera won't read.
        let paper = "\u{1b}[30;47m", plain = "\u{1b}[0m"
        var out = ""
        for row in stride(from: -quiet * 2, to: h + quiet * 2, by: 2) {
            out += paper + String(repeating: " ", count: quiet)
            for x in -quiet ..< (w + quiet) {
                let top = x < 0 || x >= w ? false : dark(x, row)
                let bottom = x < 0 || x >= w ? false : dark(x, row + 1)
                out += top && bottom ? "\u{2588}" : top ? "\u{2580}" : bottom ? "\u{2584}" : " "
            }
            out += String(repeating: " ", count: quiet) + plain + "\n"
        }
        return out
    }

    /// devicectl installs any .app or .ipa signed for this device. Check the
    /// signing first: the usual failure, and devicectl's error for it is cryptic.
    static func install(_ profile: DeviceProfile, path: String) -> Never {
        guard FileManager.default.fileExists(atPath: path) else { stop("no such file: \(path)") }
        guard [".ipa", ".app"].contains(where: path.lowercased().trimmingCharacters(in: ["/"]).hasSuffix) else {
            stop("\(path) is not an .ipa or .app")
        }
        let tmp = FileManager.default.temporaryDirectory
        sweepStaleUnpacks(in: tmp) // a Ctrl-C during an earlier install (or ota) skipped its cleanUp
        let udid = reachableUDID(profile)
        guard path.lowercased().hasSuffix(".ipa") else {
            checkSigning(profile, udid: udid, path: path)
            exec(["/usr/bin/xcrun", "devicectl", "device", "install", "app", "--device", udid, path])
        }
        // devicectl documents .app bundles only: unpack the .ipa and hand it the .app inside.
        // Our pid in the name: the install can outlast the sweep's hour (a big app over a slow link).
        let dir = tmp.appendingPathComponent("roamrun-ipa-\(getpid())-\(UUID().uuidString)")
        let cleanUp = {
            try? FileManager.default.removeItem(at: dir)
        } // exit() skips defer
        let unzip = Proc.run("/usr/bin/ditto", ["-x", "-k", path, dir.path], timeout: 300)
        guard unzip.status == 0
        else {
            cleanUp(); stop("couldn't unpack \(path): \(firstLine(unzip.err) ?? "ditto exited \(unzip.status)")")
        }
        let payload = dir.appendingPathComponent("Payload")
        guard let app = OTA.appBundle(in: payload)
        else { cleanUp(); stop("\(path) has no Payload/*.app inside — not an iOS app archive?") }
        // A crafted archive could make Payload or Payload/X.app a link to somewhere else on this Mac.
        let appURL = payload.appendingPathComponent(app)
        guard appURL.resolvingSymlinksInPath().path.hasPrefix(dir.resolvingSymlinksInPath().path + "/Payload/") else {
            cleanUp(); stop("\(path)'s Payload/\(app) links outside the archive — not installing it")
        }
        // Checked on this very .app: a separate partial unpack could land on another
        // bundle of a multi-app archive and vouch for one that isn't installed.
        checkSigning(profile, udid: udid, path: appURL.path, shown: path, cleanUp: {
            _ = cleanUp()
        })
        let status = visible(["/usr/bin/xcrun", "devicectl", "device", "install", "app", "--device", udid,
                              payload.appendingPathComponent(app).path])
        cleanUp()
        exit(status)
    }

    /// Unpacked archives an interrupted `install` or `ota` (or their signing and icon
    /// checks) left behind. An hour is longer than the checks; an install can take longer,
    /// so its folder carries its pid and stays while that process lives — that process: one
    /// that started after the folder was made only has its pid.
    nonisolated static func sweepStaleUnpacks(in tmp: URL, now: Date = .now,
                                              started: (Int32) -> Double? = StatusFile.startTime(of:))
    {
        let fm = FileManager.default
        let ours = ["roamrun-ipa-", "roamrun-install-", "roamrun-ota-", "roamrun-icon-"]
        for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where ours.contains(where: name.hasPrefix) {
            let url = tmp.appendingPathComponent(name)
            let made = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? now
            if name.hasPrefix("roamrun-ipa-"), let pid = Int32(name.dropFirst(12).prefix {
                   $0 != "-"
               }),
               let since = started(pid), since <= made.timeIntervalSince1970 + 1
            {
                continue
            }
            if made < now.addingTimeInterval(-3600) {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// App Store builds and builds not provisioned for this device fail with a
    /// cryptic devicectl error — say what's wrong before trying.
    /// `shown`: how to name it (the .ipa it came from); `cleanUp` runs before a refusal exits.
    private static func checkSigning(_ profile: DeviceProfile, udid: String, path: String, shown: String? = nil,
                                     cleanUp: () -> Void = {})
    {
        let name = shown ?? path
        switch provisioning(of: path) {
        case .appStore:
            cleanUp(); stop(
                "\(name) is signed for App Store / TestFlight and can't be installed directly. Export it for Debugging, Release Testing (Ad Hoc) or Enterprise."
            )
        case .devices(let list) where !list.contains(where: {
            $0.caseInsensitiveCompare(udid) == .orderedSame
        }):
            cleanUp(); stop(
                "\(name) isn't signed for \(profile.displayName) (UDID \(udid) is not in its provisioning profile). Add the device to the profile and export again."
            )
        case .unknown:
            let info = NSDictionary(contentsOfFile: (path as NSString).appendingPathComponent("Info.plist"))
            if (info?["DTPlatformName"] as? String)?.hasSuffix("simulator") == true {
                cleanUp(); stop(
                    "\(name) is a Simulator build — build for a device (Any iOS Device / the device itself)."
                )
            }
            FileHandle.standardError
                .write(
                    Data("roamrun: couldn't read \(name)'s provisioning profile — if the install fails, check it's a device build signed for \(profile.displayName)\n"
                        .utf8)
                )
        default:
            break
        }
    }

    /// Runs a tool with its output going straight to this terminal.
    private static func visible(_ argv: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: argv[0])
        task.arguments = Array(argv.dropFirst())
        Proc.Passing.shared.launching()
        do { try task.run() } catch {
            Proc.Passing.shared.launched(nil)
            stop("could not run \(argv[0]): \(error.localizedDescription)")
        }
        Proc.Passing.shared.launched(task)
        task.waitUntilExit()
        Proc.Passing.shared.childEnded()
        return task.terminationStatus
    }

    /// Build → install → launch, for the project in the current folder.
    static func runApp(_ profile: DeviceProfile, scheme: String?, workspace: String?, project: String?,
                       configuration: String, logs: Bool, launch: Launch) -> Never
    {
        let udid = reachableUDID(profile)
        let container: [String]
        if let workspace {
            container = ["-workspace", workspace]
        } else if let project {
            container = ["-project", project]
        } else {
            let here = (try? FileManager.default.contentsOfDirectory(atPath: ".")) ?? []
            let workspaces = here.filter {
                $0.hasSuffix(".xcworkspace")
            },
                projects = here.filter {
                    $0.hasSuffix(".xcodeproj")
                }
            if workspaces.count == 1 {
                container = ["-workspace", workspaces[0]]
            } else if workspaces.isEmpty, projects.count == 1 {
                container = ["-project", projects[0]]
            } else if workspaces.isEmpty && projects
                .isEmpty
            {
                stop("no .xcworkspace or .xcodeproj here — cd into the project, or pass --workspace / --project")
            } else {
                stop(
                    "more than one project here: \((workspaces + projects).joined(separator: ", ")) — pass --workspace or --project"
                )
            }
        }
        let chosen: String
        if let scheme {
            chosen = scheme
        } else {
            // Generous: the first -list of a project can resolve its packages.
            let list = Proc.run("/usr/bin/xcrun", ["xcodebuild", "-list", "-json"] + container, timeout: 300)
            let root = (try? JSONSerialization.jsonObject(with: Data(list.out.utf8))) as? [String: Any]
            let schemes = ((root?["workspace"] ?? root?["project"]) as? [String: Any])?["schemes"] as? [String] ?? []
            guard schemes.count == 1 else {
                stop(schemes.isEmpty ? "couldn't list the schemes (\(firstLine(list.err) ?? "xcodebuild exited \(list.status)")) — pass --scheme"
                    : "which scheme? \(schemes.joined(separator: ", ")) — pass --scheme")
            }
            chosen = schemes[0]
        }
        let build = ["/usr/bin/xcrun", "xcodebuild"] + container
            + [
                "-scheme",
                chosen,
                "-configuration",
                configuration,
                "-destination",
                "id=\(udid)",
                "-allowProvisioningUpdates"
            ]
        print("Building \(chosen) for \(profile.displayName)…")
        guard visible(build + ["-quiet", "build"]) == 0 else { stop("the build failed (see above)") }

        // The built .app: the build settings of the target that produces one.
        let settings = Proc.run(build[0], Array(build.dropFirst()) + ["-showBuildSettings", "-json"], timeout: 300)
        let targets = (try? JSONSerialization.jsonObject(with: Data(settings.out.utf8))) as? [[String: Any]] ?? []
        guard let s = appTarget(in: targets, scheme: chosen), let dir = s["TARGET_BUILD_DIR"],
              let wrapper = s["WRAPPER_NAME"]
        else {
            stop(
                "built, but couldn't find the .app in the build settings (\(firstLine(settings.err) ?? "no app target"))"
            )
        }
        let app = (dir as NSString).appendingPathComponent(wrapper)
        guard let bundleID = NSDictionary(contentsOfFile: (app as NSString)
            .appendingPathComponent("Info.plist"))?["CFBundleIdentifier"] as? String
        else { stop("built, but \(app) has no bundle identifier") }

        _ = reachableUDID(profile) // a long build: it may have locked or dropped off meanwhile
        checkSigning(profile, udid: udid, path: app)
        print("Installing \(wrapper)…")
        guard visible(["/usr/bin/xcrun", "devicectl", "device", "install", "app", "--device", udid, app]) == 0 else {
            stop("the install failed (see above)")
        }
        print("Launching \(bundleID)…")
        if logs {
            launchWithConsole(udid: udid, bundleID: bundleID, launch: launch)
        }
        launch.exportEnvironment()
        exec(launch.argv(udid: udid, bundleID: bundleID, console: false))
    }

    /// The target `run` installs: an application (not an App Clip, extension or
    /// watch app), the scheme's own target first.
    nonisolated static func appTarget(in targets: [[String: Any]], scheme: String) -> [String: String]? {
        let apps = targets.compactMap {
            $0["buildSettings"] as? [String: String]
        }
        .filter {
            $0["WRAPPER_EXTENSION"] == "app" && $0["PLATFORM_NAME"] != "watchos"
        }
        let real = apps.filter {
            $0["PRODUCT_TYPE"] == "com.apple.product-type.application"
        }
        let pool = real.isEmpty ? apps : real
        return pool.first {
            $0["TARGET_NAME"] == scheme
        } ?? pool.first
    }

    private static func firstLine(_ s: String) -> String? {
        s.split(separator: "\n")
            .first {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }
            .map(String.init)
    }

    enum Provisioning: Equatable { case devices([String]), allDevices, appStore, unknown }

    /// Reads embedded.mobileprovision from an .app or (unzipping) an .ipa.
    static func provisioning(of path: String) -> Provisioning {
        profilePlist(of: path).map(parseProvisioning) ?? .unknown
    }

    /// The whole profile: OTA also needs the entitlements, which tell a
    /// Development build (installs only through the bridge) from an Ad Hoc one.
    static func profilePlist(of path: String) -> [String: Any]? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var profile = URL(fileURLWithPath: path).appendingPathComponent("embedded.mobileprovision")
        if path.lowercased().hasSuffix(".ipa") {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = Proc.run(
                "/usr/bin/unzip",
                ["-qo", path, "Payload/*.app/embedded.mobileprovision", "-d", dir.path],
                timeout: 30
            )
            let payload = dir.appendingPathComponent("Payload")
            guard let app = OTA.appBundle(in: payload) else { return nil }
            guard let real = OTA.inside(payload.appendingPathComponent(app)
                .appendingPathComponent("embedded.mobileprovision"), dir) else { return nil }
            profile = real
        }
        let decoded = Proc.run("/usr/bin/security", ["cms", "-D", "-i", profile.path], timeout: 10).out
        guard let data = decoded.data(using: .utf8) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    nonisolated static func parseProvisioning(_ plist: [String: Any]) -> Provisioning {
        if let devices = plist["ProvisionedDevices"] as? [String] {
            return .devices(devices)
        }
        if plist["ProvisionsAllDevices"] as? Bool == true {
            return .allDevices
        }
        return .appStore // neither a device list nor Enterprise: App Store / TestFlight
    }

    /// devicectl can't attach to a running process, so this relaunches the app
    /// with `--console`. OS_ACTIVITY_DT_MODE mirrors os_log to stderr, as Xcode does.
    static func logs(_ profile: DeviceProfile, bundleID: String, launch: Launch) -> Never {
        launchWithConsole(udid: reachableUDID(profile), bundleID: bundleID, launch: launch)
    }

    /// Relaunch with print / os_log streamed here until Ctrl-C.
    private static func launchWithConsole(udid: String, bundleID: String, launch: Launch) -> Never {
        setenv("DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE", "enable", 1)
        launch.exportEnvironment() // after: the caller's --env OS_ACTIVITY_DT_MODE=… wins
        exec(launch.argv(udid: udid, bundleID: bundleID, console: true))
    }
}
