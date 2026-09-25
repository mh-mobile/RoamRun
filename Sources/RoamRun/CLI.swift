import Foundation

/// `roamrun devices | up <name> | status [name]` — the same bridge as the menu
/// bar app, headless, for SSH sessions and scripts.
@MainActor
enum CLI {
    /// This process was started as the CLI (vs. the menu bar app).
    nonisolated static var isRunning: Bool { commands.contains(CommandLine.arguments.dropFirst().first ?? "") }
    nonisolated static let commands: Set<String> = ["devices", "up", "down", "status", "doctor", "run", "install", "logs", "screenshot", "init", "version", "--version", "help", "--help", "-h"]
    /// Posted by `roamrun down`; the app stops the bridge whose id is `object`.
    static let stopNotification = Notification.Name("com.roamrun.app.stopBridge")

    private static let usage = """
    Usage: roamrun <command>

    AI agents: `roamrun init` installs the RoamRun skill for Claude Code, Codex,
    Cursor, Gemini CLI and Copilot (`roamrun init --print` to read it now).

      devices [--json]               List saved devices (with UDID) and their bridge status
      up <name> [-v] [-d]            Bridge a device until Ctrl-C (-v: activity log, -d: run in the background)
      down <name>                    Stop a bridge, whether the app or another `roamrun up` runs it
      status [name] [--wait N] [--json]
                                     Bridge status, UDID and lock state; exits 0 only if Xcode can use
                                     the device (bridged and ready, or on this Wi-Fi)
                                     (--wait: wait up to N seconds for ready)
      doctor [name] [--json]         Check each step from this Mac to the device and say what to fix
                                     (without a name, only devices with a running bridge)
      run <name> [--scheme S] [--workspace W | --project P] [--configuration C] [--logs]
                                     Build the project in this folder for the device, install and launch it
                                     (--logs: then stream its output like `logs`)
      install <name> <App.ipa|App.app>
                                     Install an .ipa or .app signed for the device (Debugging, Release
                                     Testing / Ad Hoc or Enterprise); checks the signing first
      logs <name> <bundle-id>        Relaunch the app with its console attached (print and os_log)
                                     until Ctrl-C — it restarts the app; it can't join one already running
      screenshot <name> [file.png]   Save the device's screen as PNG (default: ./<name>-<time>.png) and
                                     print its path — to check what an app shows (Xcode 27)
      version                        Print the version (also --version)
      init [--client <name>] [--print] [--uninstall]
                                     Install the agent skill (clients: claude, codex, cursor, gemini, copilot)

    Exit codes: 0 ok/ready, 1 not ready or a check failed, 2 usage error.

    Add devices (iPhone, iPad, Vision Pro) in the RoamRun app first (one-time, with the device on this
    Wi-Fi or USB).
    """

    // Kept alive for the lifetime of `up`.
    private static var bridge: ProxyBridge?
    private static var keepAlive: [AnyObject] = []

    nonisolated static func run(_ args: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        MainActor.assumeIsolated {
            if !commands.contains(args[0]) {
                FileHandle.standardError.write(Data("roamrun: unknown command “\(args[0])”\n\n\(usage)\n".utf8))
                exit(2)
            }
            if ["help", "--help", "-h"].contains(args[0]) || args.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" }) {
                print(usage); exit(0)
            }
            if args[0] == "version" || args[0] == "--version" {
                // Through the /usr/local/bin link, Bundle.main isn't the app: resolve it.
                let app = Bundle.main.executableURL?.resolvingSymlinksInPath()
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let info = app.flatMap(Bundle.init(url:))?.infoDictionary ?? Bundle.main.infoDictionary
                print("roamrun \(info?["CFBundleShortVersionString"] as? String ?? "dev")")
                exit(0)
            }
            if args[0] == "init" { initSkill(args) }   // takes no iPhone name
            let store = ProfileStore()
            let profiles = store.load()
            if let copy = store.keptUnreadable {
                FileHandle.standardError.write(Data("roamrun: couldn't read saved devices; kept the file as \(copy.path)\n".utf8))
            }
            let known: Set<String> = ["--json", "--wait", "-v", "-d", "--scheme", "--workspace", "--project",
                                      "--configuration", "--logs", detachedFlag]
            for (i, a) in args.enumerated().dropFirst() where a.hasPrefix("-") && !known.contains(a) && args[i - 1] != "--wait" {
                fail("unknown option \(a) — see roamrun --help")
            }
            let json = args.contains("--json")
            let waitIdx = args.firstIndex(of: "--wait")
            let wait = waitIdx.flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil }
            if waitIdx != nil && !(wait.map { $0.isFinite && $0 >= 0 } ?? false) { fail("--wait needs a number of seconds") }
            for flag in ["--scheme", "--workspace", "--project", "--configuration"] {
                if let i = args.firstIndex(of: flag), !args.indices.contains(i + 1) || args[i + 1].hasPrefix("-") {
                    fail("\(flag) needs a value")
                }
            }
            // Words after the command that aren't flags or a flag's value.
            let valued: Set<String> = ["--wait", "--scheme", "--workspace", "--project", "--configuration"]
            let words = args.indices.dropFirst().filter { i in
                !args[i].hasPrefix("-") && !valued.contains(args[i - 1])
            }.map { args[$0] }
            let name = words.first
            var targets = profiles
            if let name {
                guard let p = find(name, in: profiles) else { fail("no device named “\(name)”. " + names(profiles)) }
                targets = [p]
            }
            switch args[0] {
            case "devices": devices(profiles, json: json)
            case "status": status(targets, json: json, wait: wait)
            case "doctor": Task { exit(await doctor(targets, json: json, named: name != nil) ? 0 : 1) }
            case "down":
                guard name != nil, let p = targets.first else { fail("which device? " + names(profiles)) }
                down(p)
            case "up":
                guard name != nil, let p = targets.first else { fail("which device? " + names(profiles)) }
                if args.contains("-d") {
                    detach(p, verbose: args.contains("-v"))
                } else {
                    up(p, verbose: args.contains("-v"), detachedChild: args.contains(detachedFlag))
                }
            case "logs":
                guard name != nil, let p = targets.first, words.count >= 2 else {
                    fail("usage: roamrun logs <name> <bundle-id>. " + names(profiles))
                }
                logs(p, bundleID: words[words.startIndex + 1])
            case "run":
                guard name != nil, let p = targets.first else { fail("usage: roamrun run <name> [--scheme S]. " + names(profiles)) }
                func value(_ flag: String) -> String? {
                    args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
                }
                runApp(p, scheme: value("--scheme"), workspace: value("--workspace"), project: value("--project"),
                       configuration: value("--configuration") ?? "Debug", logs: args.contains("--logs"))
            case "screenshot":
                guard name != nil, let p = targets.first else {
                    fail("usage: roamrun screenshot <name> [file.png]. " + names(profiles))
                }
                screenshot(p, path: words.count >= 2 ? words[words.startIndex + 1] : nil)
            case "install":
                guard name != nil, let p = targets.first, words.count >= 2 else {
                    fail("usage: roamrun install <name> <path to .ipa or .app>. " + names(profiles))
                }
                install(p, path: words[words.startIndex + 1])
            default: print(usage); exit(0)
            }
        }
        // RunLoop, not dispatchMain(): the status Timers need a running run loop.
        RunLoop.main.run()
        exit(0)
    }

    // MARK: - Commands

    /// One device as `status --json` / `devices --json` report it.
    private struct Row: Encodable {
        let name: String
        let id: String
        let vpnAddress: String
        let udid: String?
        let status: String
        let ready: Bool
        let owner: String?
        let pid: Int32?
        let tunnelPorts: [UInt16]
        /// CoreDevice's view: "connected", "disconnected" (reachable, no tunnel yet) or "unavailable".
        let coreDevice: String?
        let detail: String?
        /// nil when unknown (not queried, or the iPhone is unreachable).
        let locked: Bool?
    }

    /// `ready` means Xcode can use the device right now: the bridge is up *and*
    /// CoreDevice sees the iPhone. The bridge alone can look ready for a while
    /// after the iPhone falls asleep (its relayed connections linger).
    private static func row(_ p: DeviceProfile, _ e: StatusFile.Entry?, deep: Bool) -> Row {
        let udid = e?.udid ?? p.udid
        let usable = e?.ready == true || e?.status == BridgeStatus.local.title   // on this Wi-Fi: Xcode sees it directly
        let core = deep && usable ? udid.flatMap(coreDeviceState) : nil
        let ready = usable && (!deep || core.map { $0 != "unavailable" } ?? false)
        var status = e?.status ?? BridgeStatus.off.title
        var detail = e.flatMap { $0.detail.isEmpty ? nil : $0.detail }
        if e?.ready == true && !ready {
            status = BridgeStatus.waiting.title
            detail = "The bridge is up but Xcode can't reach the device (asleep, locked, off Wi-Fi, or Tailscale stuck on the device). Run `roamrun doctor` for the cause."
        }
        return Row(name: p.displayName, id: p.id.uuidString, vpnAddress: p.providerIP, udid: udid,
                   status: status, ready: ready,
                   owner: e.map(owner), pid: e?.pid, tunnelPorts: e?.tunnelPorts ?? [],
                   coreDevice: core, detail: detail,
                   locked: deep && ready ? udid.flatMap(isLocked) : nil)
    }

    /// devicectl's tunnelState for this UDID; nil if devicectl failed.
    nonisolated static func coreDeviceState(_ udid: String) -> String? {
        guard let devices = Proc.devicectl(["--timeout", "10", "list", "devices"])?["devices"] as? [[String: Any]],
              let device = devices.first(where: { ($0["hardwareProperties"] as? [String: Any])?["udid"] as? String == udid })
        else { return nil }
        return (device["connectionProperties"] as? [String: Any])?["tunnelState"] as? String
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: (try? enc.encode(value)) ?? Data(), as: UTF8.self))
    }

    private static func devices(_ profiles: [DeviceProfile], json: Bool) -> Never {
        let live = StatusFile.read()
        if json { printJSON(profiles.map { row($0, live[$0.id], deep: false) }); exit(0) }
        guard !profiles.isEmpty else { print("No devices saved yet — add one in the RoamRun app."); exit(0) }
        let w = max(4, profiles.map(\.displayName.count).max() ?? 4)
        print("NAME".padding(toLength: w + 2, withPad: " ", startingAt: 0) + "VPN ADDRESS      UDID                       STATUS")
        for p in profiles {
            let e = live[p.id]
            let status = e.map { "\($0.status) (\(owner($0)))" } ?? "Off"
            print(p.displayName.padding(toLength: w + 2, withPad: " ", startingAt: 0)
                  + p.providerIP.padding(toLength: 17, withPad: " ", startingAt: 0)
                  + (e?.udid ?? p.udid ?? "-").padding(toLength: 27, withPad: " ", startingAt: 0) + status)
        }
        exit(0)
    }

    private static func status(_ targets: [DeviceProfile], json: Bool, wait: Double?) -> Never {
        if targets.isEmpty && !json { stop("no devices saved yet — add one in the RoamRun app") }
        var rows: [Row]
        let deadline = Date.now.addingTimeInterval(wait ?? 0)
        repeat {
            let live = StatusFile.read()
            rows = targets.map { row($0, live[$0.id], deep: true) }
            if rows.contains(where: \.ready) || Date.now >= deadline { break }
            usleep(3_000_000)   // each round spawns devicectl
        } while true
        if json {
            printJSON(rows)
        } else {
            for r in rows {
                var line = "\(r.name): \(r.status)"
                if let owner = r.owner { line += " — \(owner)" }
                if let lo = r.tunnelPorts.min(), let hi = r.tunnelPorts.max() { line += ", tunnel ports \(lo)–\(hi)" }
                print(line)
                if let udid = r.udid { print("  UDID: \(udid)") }
                if let detail = r.detail { print("  \(detail)") }
                if r.locked == true { print("  ⚠ The device is locked — ask the user to unlock it and keep the screen on before installing or launching.") }
            }
        }
        exit(rows.contains { $0.ready } ? 0 : 1)
    }

    /// Needs the tunnel; nil when devicectl can't reach the device.
    private static func isLocked(_ udid: String) -> Bool? {
        Proc.devicectl(["--timeout", "10", "device", "info", "lockState", "--device", udid])?["passcodeRequired"] as? Bool
    }

    /// A runtime failure (exit 1). `fail` is for usage errors (exit 2).
    private static func stop(_ why: String) -> Never {
        FileHandle.standardError.write(Data("roamrun: \(why)\n".utf8))
        exit(1)
    }

    /// The UDID of a device Xcode can reach right now (bridged, or on this
    /// Wi-Fi without a bridge) and that is unlocked; otherwise says what to do.
    private static func reachableUDID(_ profile: DeviceProfile) -> String {
        guard let udid = StatusFile.read()[profile.id]?.udid ?? profile.udid else {
            stop("\(profile.displayName)'s UDID isn't known yet — start its bridge once: roamrun up \(shellName(profile.displayName)) -d")
        }
        let core = coreDeviceState(udid)
        guard let core, core != "unavailable" else {
            stop("Xcode can't reach \(profile.displayName) (\(core ?? "unknown")). If it's away, start the bridge: roamrun up \(shellName(profile.displayName)) -d; otherwise run roamrun doctor \(shellName(profile.displayName)).")
        }
        if isLocked(udid) == true { stop("\(profile.displayName) is locked — ask the user to unlock it and keep the screen on.") }
        return udid
    }

    /// Hands over to devicectl so Ctrl-C and kill reach it directly.
    private static func exec(_ argv: [String]) -> Never {
        var cargs = argv.map { strdup($0) } + [nil]
        execv(argv[0], &cargs)
        stop("could not run \(argv[0]): \(String(cString: strerror(errno)))")
    }

    /// Through the tunnel like everything else: works over the bridge.
    private static func screenshot(_ profile: DeviceProfile, path: String?) -> Never {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: .now)
        let file = URL(fileURLWithPath: path ?? "\(fileSafe(profile.displayName))-\(stamp).png").standardizedFileURL
        guard file.pathExtension.lowercased() == "png" else { fail("the file must end in .png") }
        let udid = reachableUDID(profile)
        let capture = ["devicectl", "--quiet", "device", "capture", "screenshot", "--device", udid, "--destination", file.path]
        var r = Proc.run("/usr/bin/xcrun", capture, timeout: 60)
        if r.status != 0, r.err.contains("CoreDeviceError") {   // e.g. the ~42s control-channel rebuild: once more
            sleep(2)
            r = Proc.run("/usr/bin/xcrun", capture, timeout: 60)
        }
        guard r.status == 0, FileManager.default.fileExists(atPath: file.path) else {
            stop("screenshot failed: " + (r.err.split(separator: "\n").first.map(String.init) ?? "devicectl exited \(r.status)"))
        }
        print(file.path)
        exit(0)
    }

    /// devicectl installs any .app or .ipa signed for this device. Check the
    /// signing first: the usual failure, and devicectl's error for it is cryptic.
    private static func install(_ profile: DeviceProfile, path: String) -> Never {
        guard FileManager.default.fileExists(atPath: path) else { stop("no such file: \(path)") }
        guard [".ipa", ".app"].contains(where: path.lowercased().trimmingCharacters(in: ["/"]).hasSuffix) else {
            stop("\(path) is not an .ipa or .app")
        }
        let udid = reachableUDID(profile)
        checkSigning(profile, udid: udid, path: path)
        guard path.lowercased().hasSuffix(".ipa") else {
            exec(["/usr/bin/xcrun", "devicectl", "device", "install", "app", "--device", udid, path])
        }
        // devicectl documents .app bundles only: unpack the .ipa and hand it the .app inside.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-ipa-\(UUID().uuidString)")
        let cleanUp = { try? FileManager.default.removeItem(at: dir) }   // exit() skips defer
        _ = Proc.run("/usr/bin/ditto", ["-x", "-k", path, dir.path], timeout: 300)
        let payload = dir.appendingPathComponent("Payload")
        guard let app = try? FileManager.default.contentsOfDirectory(atPath: payload.path).first(where: { $0.hasSuffix(".app") })
        else { cleanUp(); stop("\(path) has no Payload/*.app inside — not an iOS app archive?") }
        let status = visible(["/usr/bin/xcrun", "devicectl", "device", "install", "app", "--device", udid,
                              payload.appendingPathComponent(app).path])
        cleanUp()
        exit(status)
    }

    /// App Store builds and builds not provisioned for this device fail with a
    /// cryptic devicectl error — say what's wrong before trying.
    private static func checkSigning(_ profile: DeviceProfile, udid: String, path: String) {
        switch provisioning(of: path) {
        case .appStore:
            stop("\(path) is signed for App Store / TestFlight and can't be installed directly. Export it for Debugging, Release Testing (Ad Hoc) or Enterprise.")
        case .devices(let list) where !list.contains(where: { $0.caseInsensitiveCompare(udid) == .orderedSame }):
            stop("\(path) isn't signed for \(profile.displayName) (UDID \(udid) is not in its provisioning profile). Add the device to the profile and export again.")
        default:
            break
        }
    }

    /// Runs a tool with its output going straight to this terminal.
    private static func visible(_ argv: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: argv[0])
        task.arguments = Array(argv.dropFirst())
        do { try task.run() } catch { stop("could not run \(argv[0]): \(error.localizedDescription)") }
        task.waitUntilExit()
        return task.terminationStatus
    }

    /// Build → install → launch, for the project in the current folder.
    private static func runApp(_ profile: DeviceProfile, scheme: String?, workspace: String?, project: String?,
                               configuration: String, logs: Bool) -> Never {
        let udid = reachableUDID(profile)
        let container: [String]
        if let workspace { container = ["-workspace", workspace] }
        else if let project { container = ["-project", project] }
        else {
            let here = (try? FileManager.default.contentsOfDirectory(atPath: ".")) ?? []
            let workspaces = here.filter { $0.hasSuffix(".xcworkspace") }, projects = here.filter { $0.hasSuffix(".xcodeproj") }
            if workspaces.count == 1 { container = ["-workspace", workspaces[0]] }
            else if workspaces.isEmpty, projects.count == 1 { container = ["-project", projects[0]] }
            else if workspaces.isEmpty && projects.isEmpty { stop("no .xcworkspace or .xcodeproj here — cd into the project, or pass --workspace / --project") }
            else { stop("more than one project here: \((workspaces + projects).joined(separator: ", ")) — pass --workspace or --project") }
        }
        let chosen: String
        if let scheme { chosen = scheme }
        else {
            let list = Proc.run("/usr/bin/xcrun", ["xcodebuild", "-list", "-json"] + container, timeout: 120).out
            let root = (try? JSONSerialization.jsonObject(with: Data(list.utf8))) as? [String: Any]
            let schemes = ((root?["workspace"] ?? root?["project"]) as? [String: Any])?["schemes"] as? [String] ?? []
            guard schemes.count == 1 else {
                stop(schemes.isEmpty ? "couldn't list the schemes — pass --scheme"
                                     : "which scheme? \(schemes.joined(separator: ", ")) — pass --scheme")
            }
            chosen = schemes[0]
        }
        let build = ["/usr/bin/xcrun", "xcodebuild"] + container
            + ["-scheme", chosen, "-configuration", configuration, "-destination", "id=\(udid)"]
        print("Building \(chosen) for \(profile.displayName)…")
        guard visible(build + ["-quiet", "build"]) == 0 else { stop("the build failed (see above)") }

        // The built .app: the build settings of the target that produces one.
        let settings = Proc.run(build[0], Array(build.dropFirst()) + ["-showBuildSettings", "-json"], timeout: 120).out
        let targets = (try? JSONSerialization.jsonObject(with: Data(settings.utf8))) as? [[String: Any]] ?? []
        // The scheme's own target first: a watchOS companion is an .app too.
        let apps = targets.compactMap { $0["buildSettings"] as? [String: String] }
            .filter { $0["WRAPPER_EXTENSION"] == "app" && $0["PLATFORM_NAME"] != "watchos" }
        guard let s = apps.first(where: { $0["TARGET_NAME"] == chosen }) ?? apps.first,
              let dir = s["TARGET_BUILD_DIR"], let wrapper = s["WRAPPER_NAME"] else {
            stop("built, but couldn't find the .app in the build settings")
        }
        let app = (dir as NSString).appendingPathComponent(wrapper)
        guard let bundleID = NSDictionary(contentsOfFile: (app as NSString).appendingPathComponent("Info.plist"))?["CFBundleIdentifier"] as? String
        else { stop("built, but \(app) has no bundle identifier") }

        _ = reachableUDID(profile)   // a long build: it may have locked or dropped off meanwhile
        checkSigning(profile, udid: udid, path: app)
        print("Installing \(wrapper)…")
        guard visible(["/usr/bin/xcrun", "devicectl", "device", "install", "app", "--device", udid, app]) == 0 else {
            stop("the install failed (see above)")
        }
        print("Launching \(bundleID)…")
        if logs {
            setenv("DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE", "enable", 1)
            exec(["/usr/bin/xcrun", "devicectl", "device", "process", "launch", "--console",
                  "--terminate-existing", "--device", udid, bundleID])
        }
        exec(["/usr/bin/xcrun", "devicectl", "device", "process", "launch", "--terminate-existing", "--device", udid, bundleID])
    }

    enum Provisioning: Equatable { case devices([String]), allDevices, appStore, unknown }

    /// Reads embedded.mobileprovision from an .app or (unzipping) an .ipa.
    static func provisioning(of path: String) -> Provisioning {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var profile = URL(fileURLWithPath: path).appendingPathComponent("embedded.mobileprovision")
        if path.lowercased().hasSuffix(".ipa") {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = Proc.run("/usr/bin/unzip", ["-qo", path, "Payload/*.app/embedded.mobileprovision", "-d", dir.path], timeout: 30)
            let payload = dir.appendingPathComponent("Payload")
            guard let app = try? FileManager.default.contentsOfDirectory(atPath: payload.path).first(where: { $0.hasSuffix(".app") })
            else { return .unknown }
            profile = payload.appendingPathComponent(app).appendingPathComponent("embedded.mobileprovision")
        }
        let decoded = Proc.run("/usr/bin/security", ["cms", "-D", "-i", profile.path], timeout: 10).out
        guard let data = decoded.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return .unknown }
        return parseProvisioning(plist)
    }

    nonisolated static func parseProvisioning(_ plist: [String: Any]) -> Provisioning {
        if let devices = plist["ProvisionedDevices"] as? [String] { return .devices(devices) }
        if plist["ProvisionsAllDevices"] as? Bool == true { return .allDevices }
        return .appStore   // neither a device list nor Enterprise: App Store / TestFlight
    }

    /// Another process bridges the device. Ready → nothing to do; still coming up → say so.
    private static func alreadyBridged(_ profile: DeviceProfile, _ e: StatusFile.Entry) -> Never {
        if e.ready {
            print("\(profile.displayName) is already bridged by \(owner(e)) — ready for Xcode.")
            exit(0)
        }
        stop("\(profile.displayName) is being bridged by \(owner(e)) (\(e.status)). Use it once it's ready, or run roamrun down \(shellName(profile.displayName)) first.")
    }

    /// devicectl can't attach to a running process, so this relaunches the app
    /// with `--console`. OS_ACTIVITY_DT_MODE mirrors os_log to stderr, as Xcode does.
    private static func logs(_ profile: DeviceProfile, bundleID: String) -> Never {
        let udid = reachableUDID(profile)
        setenv("DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE", "enable", 1)
        exec(["/usr/bin/xcrun", "devicectl", "device", "process", "launch", "--console",
              "--terminate-existing", "--device", udid, bundleID])
    }

    private static func down(_ profile: DeviceProfile) -> Never {
        guard let e = StatusFile.read()[profile.id] else {
            print("\(profile.displayName) is not bridged."); exit(0)
        }
        let who = owner(e)   // before it exits and the pid stops resolving
        // Always tell the app too: even when the CLI owns the device, the app
        // may still have it on its restore list and would take it back.
        DistributedNotificationCenter.default().postNotificationName(
            stopNotification, object: profile.id.uuidString, userInfo: nil, deliverImmediately: true)
        if e.cli == true, e.pid != getpid() { kill(e.pid, SIGTERM) }   // its handler tears down dns-sd / log children
        // Wait for the owner to clear its status entry.
        var tries = 0
        while StatusFile.read()[profile.id] != nil && tries < 50 { usleep(100_000); tries += 1 }
        guard StatusFile.read()[profile.id] == nil else { stop("\(who) did not stop the bridge") }
        print("Stopped \(profile.displayName) (\(who)).")
        exit(0)
    }

    /// The display name is user/network supplied: keep it to one safe path component.
    private static func fileSafe(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || "-_ ".contains($0) ? $0 : "_" })
    }

    /// Internal: marks the background copy spawned by `up -d`.
    private static let detachedFlag = "--detached-child"

    /// `up -d`: re-launch ourselves in a new session with output going to a
    /// log file, wait until the bridge settles, then hand the prompt back.
    private static func detach(_ profile: DeviceProfile, verbose: Bool) -> Never {
        if StatusFile.otherOwner(of: profile.id) != nil, let e = StatusFile.read()[profile.id] {
            alreadyBridged(profile, e)
        }
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/RoamRun", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let safeName = fileSafe(profile.displayName)
        let logURL = logDir.appendingPathComponent("\(safeName.isEmpty ? profile.id.uuidString : safeName).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let log = try? FileHandle(forWritingTo: logURL) else { stop("can't write \(logURL.path)") }

        let child = Process()
        child.executableURL = Bundle.main.executableURL?.resolvingSymlinksInPath()
        child.arguments = ["up", profile.id.uuidString, detachedFlag] + (verbose ? ["-v"] : [])
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = log
        child.standardError = log
        do { try child.run() } catch { stop("could not start the background bridge: \(error.localizedDescription)") }

        // Wait (≤60s) for Ready; a slower start keeps going in the background.
        var last = ""
        for _ in 0..<120 {
            usleep(500_000)
            guard child.isRunning else { stop("the background bridge exited — see \(logURL.path)") }
            guard let e = StatusFile.read()[profile.id], e.pid == child.processIdentifier else { continue }
            if e.status != last { last = e.status; print("  \(e.status)") }
            if e.ready || e.status == BridgeStatus.local.title { break }
        }
        let pid = child.processIdentifier
        switch last {
        case BridgeStatus.ready.title:
            print("\(profile.displayName) is bridged in the background (pid \(pid)).")
        case BridgeStatus.local.title:
            print("\(profile.displayName) is on this Wi‑Fi, so Xcode reaches it directly. The bridge waits in the background (pid \(pid)) and takes over when it leaves.")
        default:
            print("\(profile.displayName) isn't ready yet (\(last.isEmpty ? "no status" : last)). The bridge keeps trying in the background (pid \(pid)).")
        }
        print("""
          Log:  \(logURL.path)
          Stop: roamrun down \(shellName(profile.displayName))
        """)
        exit(last == BridgeStatus.ready.title || last == BridgeStatus.local.title ? 0 : 1)
    }

    private static func up(_ profile: DeviceProfile, verbose: Bool, detachedChild: Bool = false) {
        if StatusFile.otherOwner(of: profile.id) != nil, let e = StatusFile.read()[profile.id] {
            alreadyBridged(profile, e)
        }
        if detachedChild {
            // Own session: closing the terminal / ending SSH doesn't reach us.
            setsid()
            signal(SIGHUP, SIG_IGN)
        }
        let bridge = ProxyBridge(profile: profile)
        self.bridge = bridge
        bridge.onLog = { m in if verbose { print("    \(m)") } }

        // Print status transitions, not a stream of identical lines.
        var last = ""
        let ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                var line = bridge.status.title
                switch bridge.state {
                case .error(let m): line += " — \(m)"
                case .starting(let step): line += " — \(step)"
                default: break
                }
                if bridge.status == .ready { line += " — pick “\(profile.displayName)” in Xcode. Ctrl-C to stop." }
                if bridge.status == .local { line += " — Xcode sees it directly; bridging resumes when it leaves." }
                guard line != last else { return }
                last = line
                print("[\(Date.now.formatted(date: .omitted, time: .standard))] \(line)")
            }
        }
        // Same recovery as the app: retry errors, rebind when the Mac's IP changes.
        let retry = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                if bridge.status == .error && bridge.autoRetry { bridge.requestStart() }
            }
        }
        let away = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated {
                if bridge.state == .local { Task { await bridge.resumeIfAway() } }
            }
        }
        let monitor = InterfaceMonitor()
        monitor.onLost = {
            Task { @MainActor in
                guard bridge.state.isActive else { return }
                bridge.stop()
                bridge.fail(ProxyBridge.noAddressMessage)
            }
        }
        monitor.onChange = { _ in
            Task { @MainActor in bridge.stop(); await bridge.start() }
        }
        monitor.start()

        // Ctrl-C must tear down dns-sd / log children, or the fake Bonjour
        // record outlives us.
        var sources: [AnyObject] = []
        for sig in detachedChild ? [SIGINT, SIGTERM] : [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                MainActor.assumeIsolated {
                    bridge.stop()
                    print("\nBridge stopped.")
                    exit(0)
                }
            }
            src.resume()
            sources.append(src as AnyObject)
        }
        keepAlive = [ticker, retry, away, monitor] + sources

        print("Bridging \(profile.displayName) over \(profile.providerIP)…")
        bridge.requestStart()
    }

    /// Walks the path Xcode → this Mac → Tailscale → iPhone and reports the
    /// first thing to fix at each hop.
    private struct Check: Encodable {
        let scope: String          // "mac" or the device's name
        let result: String         // "ok", "warning", "fail" or "skipped"
        let message: String
        let fix: String?
    }

    /// Without a name, devices whose bridge is off are skipped: an unused device
    /// being unreachable isn't a problem to fix.
    private static func doctor(_ profiles: [DeviceProfile], json: Bool, named: Bool) async -> Bool {
        var checks: [Check] = []
        var scope = "mac"
        func section(_ title: String, _ name: String) {
            scope = name
            if !json { print(title) }
        }
        func check(_ ok: Bool, _ line: String, fix: String = "", warnOnly: Bool = false) {
            let result = ok ? "ok" : warnOnly ? "warning" : "fail"
            checks.append(Check(scope: scope, result: result, message: line, fix: ok || fix.isEmpty ? nil : fix))
            guard !json else { return }
            print(" \(paint(ok ? "✓" : warnOnly ? "!" : "✗", ok ? 32 : warnOnly ? 33 : 31)) \(line)")
            if !ok, !fix.isEmpty { print("     → \(fix)") }
        }
        /// Not a result: why a check didn't run.
        func note(_ line: String) {
            checks.append(Check(scope: scope, result: "skipped", message: line, fix: nil))
            if !json { print(" – \(line)") }
        }
        /// ANSI color on a terminal only (not when piped, or with NO_COLOR set).
        func paint(_ s: String, _ code: Int) -> String {
            isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil ? "\u{1B}[\(code);1m\(s)\u{1B}[0m" : s
        }
        func finish() -> Bool {
            let healthy = !checks.contains { $0.result == "fail" }
            if json {
                struct Report: Encodable { let healthy: Bool; let checks: [Check] }
                printJSON(Report(healthy: healthy, checks: checks))
            } else {
                print(healthy ? "\n" + paint("All good.", 32) : "\nFix the first failed check (\(paint("✗", 31))) first — the ones below it are often caused by it.")
            }
            return healthy
        }

        section("This Mac", "mac")
        check(FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") && shell("/usr/bin/xcrun", ["--find", "devicectl"]) != nil,
              "Xcode's devicectl is available", fix: "Install Xcode and run it once (xcode-select -s /Applications/Xcode.app).")
        let ip = InterfaceMonitor.currentIPv4()
        check(ip != nil, "Wi-Fi address (en0): \(ip ?? "none")",
              fix: "Connect en0 (Wi-Fi on most Macs, Ethernet on a Mac mini/Studio) to the network — the bridge listens there because Xcode only looks there.")
        let orphans = DNSServiceProxy.orphanedHelperCount()
        check(orphans == 0, orphans == 0 ? "No leftover helper processes" : "\(orphans) leftover helper process(es) from a crash",
              fix: "Open RoamRun (it cleans them up at launch) or Settings › Clean Up Leftover Helpers.", warnOnly: true)

        let live = StatusFile.read()
        let cli = TailscaleClient.fromSettings()
        let viaTailscale = { (p: DeviceProfile) in p.providerID == MeshProvider.tailscale.rawValue }
        var peers: [MeshDevice] = []
        do {
            peers = try cli.listDevices()
            check(true, "Tailscale is running (\(peers.count) peers)")
        } catch {
            // Devices entered by IP (another mesh VPN) don't need Tailscale.
            if profiles.contains(where: { viaTailscale($0) && (named || live[$0.id] != nil) }) {
                check(false, "Tailscale: \(error.localizedDescription)", fix: "Install Tailscale and sign in, or set its CLI path in RoamRun › Settings.")
                return finish()
            }
            note("Tailscale not checked (no device uses it)")
        }

        if profiles.isEmpty { check(false, "No devices saved", fix: "Add one in the RoamRun app.") }
        for p in profiles {
            section("\n\(p.displayName) (\(p.providerIP))", p.displayName)
            if !named, live[p.id] == nil {
                note("Bridge is off — not checked (roamrun doctor \(shellName(p.displayName)) checks it anyway)")
                continue
            }
            if viaTailscale(p) {
                guard let peer = peers.first(where: { $0.ips.contains(p.providerIP) }) else {
                    check(false, "Not found on this tailnet", fix: "Sign the device into the same tailnet, or remove and re-add it in RoamRun.")
                    continue
                }
                check(peer.online, "Tailscale peer “\(peer.name)” is \(peer.online ? "online" : "offline")",
                      fix: "Unlock the device and keep its screen on — while it sleeps, iOS pauses the Tailscale VPN too.")
                // On this Wi-Fi Xcode reaches the device directly; the Tailscale path doesn't matter.
                if peer.online, live[p.id]?.status != BridgeStatus.local.title {
                    check(!peer.curAddr.isEmpty, "Path: \(peer.pathDescription)",
                          fix: "Direct paths are much faster. Some networks (hotel, carrier NAT) force DERP.", warnOnly: true)
                }
            } else {
                note("VPN address entered by hand — Tailscale checks skipped")
            }
            let open = await ReachabilityProbe.checkTCP(host: p.providerIP, port: p.remotePairingPort, timeout: 4)
            if open {
                check(true, "RemotePairing port \(p.remotePairingPort) is reachable")
            } else if viaTailscale(p), cli.ping(p.providerIP) {
                // Tailscale answers but the iPhone's service doesn't: the iOS
                // Tailscale data plane is stuck, or the iPhone left Wi-Fi.
                check(false, "Tailscale reaches the device, but RemotePairing port \(p.remotePairingPort) does not answer",
                      fix: "Ask the user to (1) toggle the VPN off and on in the device's Tailscale app — iOS Tailscale can show \"MagicSock function ReceiveIPv4 is not running\" and stop passing data while still looking connected; (2) check the device is on Wi-Fi (cellular alone is not enough). If it restarted, run Find RemotePairing Port in the app.")
            } else {
                check(false, "The device does not answer over \(viaTailscale(p) ? "Tailscale" : "the VPN")",
                      fix: "Ask the user to unlock the device, keep the screen on and make sure Tailscale is on. If the Tailscale app shows a \"MagicSock … not running\" warning, toggle its VPN off and on.")
            }
            if open {
                let speaks = await ReachabilityProbe.speaksRemotePairing(host: p.providerIP, port: p.remotePairingPort)
                check(speaks, "Device \(speaks ? "answers" : "does not answer") the RemotePairing handshake",
                      fix: "Another service holds this port. Run Find RemotePairing Port in the app.")
            }
            // How remotepairingd last resolved our record (nil = pairing lost), or any
            // advert matched to this UDID. Only plain hex/UUIDs go into the predicates.
            let plain = { (s: String) in !s.isEmpty && s.allSatisfy { $0.isHexDigit || $0 == "-" } }
            let udid = live[p.id]?.udid ?? p.udid
            let ours = plain(p.instanceName) ? shell("/usr/bin/log", ["show", "--last", "15m", "--style", "compact", "--predicate",
                "process == \"remotepairingd\" AND eventMessage CONTAINS \"Resolved bonjour advert \(p.instanceName) to identity\""])?
                .split(separator: "\n").last(where: { $0.contains("to identity") }) : nil
            if let ours, !ours.contains("associated with udid") {
                check(false, "This Mac does not recognize the device's pairing (identity nil)",
                      fix: "Put the device on this Mac's Wi-Fi, remove it in RoamRun and add it again. If Xcode lost it too, pair it in Xcode first.")
            } else if ours != nil || (udid.map(plain) == true && shell("/usr/bin/log", ["show", "--last", "15m", "--style", "compact", "--predicate",
                "process == \"remotepairingd\" AND eventMessage CONTAINS \"associated with udid \(udid!)\""])?.contains("associated with udid") == true) {
                check(true, "This Mac recognizes the device's pairing")
            } else {
                note("Pairing not checked — no advert of this device was matched in the last 15 minutes")
            }
            if let e = live[p.id] {
                check(e.ready || e.status == BridgeStatus.local.title, "Mac-side bridge: \(e.status) (\(owner(e)))", fix: e.detail.isEmpty ? "Wait a few seconds and run doctor again." : e.detail)
                if udid == nil { note("UDID not known yet — learned the first time the bridge connects") }
                if let udid {
                    check(true, "UDID: \(udid)")
                    let core = coreDeviceState(udid)
                    check(core != nil && core != "unavailable", "Xcode (CoreDevice) sees the device as \(core ?? "unknown")",
                          fix: "Ask the user to unlock the device and keep the screen on; then run doctor again.")
                    if e.ready, let locked = isLocked(udid) {
                        check(!locked, locked ? "Device is locked" : "Device is unlocked",
                              fix: "Ask the user to unlock the device and keep the screen on — installs and launches fail while it is locked.")
                    }
                }
            } else {
                check(false, "Bridge is off", fix: "roamrun up \(shellName(p.displayName)) -d  (or Start Bridge in the app)")
            }
        }
        return finish()
    }

    /// A name as it must be typed in a shell: 'iPhone mh', 'it'\''s'.
    nonisolated static func shellName(_ name: String) -> String {
        guard name.contains(where: { " '\"$`\\!*?&;|<>()".contains($0) }) else { return name }
        return "'" + name.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private static func shell(_ path: String, _ args: [String]) -> String? {
        let r = Proc.run(path, args)
        return r.status == 0 ? r.out : nil
    }

    /// Global skill directories of agents that follow the Agent Skills layout.
    private static let skillClients: [(name: String, home: String)] = [
        ("claude", ".claude"), ("codex", ".codex"), ("cursor", ".cursor"),
        ("gemini", ".gemini"), ("copilot", ".copilot"),
    ]

    /// Installs the bundled SKILL.md for every detected (or named) agent.
    private static func initSkill(_ args: [String]) -> Never {
        // A typo (e.g. --uninstal) must not fall through to installing everywhere.
        for (i, a) in args.enumerated().dropFirst() where a.hasPrefix("-") && args[i - 1] != "--client" {
            guard ["--client", "--print", "--uninstall"].contains(a) else { fail("unknown option \(a) — see roamrun --help") }
        }
        if let i = args.lastIndex(of: "--client"), !args.indices.contains(i + 1) || args[i + 1].hasPrefix("-") {
            fail("--client needs a value (\(skillClients.map(\.name).joined(separator: ", ")))")
        }
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath()
        let bundled = exe?.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/roamrun-skill.md")
        guard let bundled, let skill = try? Data(contentsOf: bundled) else {
            stop("skill not found in the app bundle — build with `make app`")
        }
        if args.contains("--print") { FileHandle.standardOutput.write(skill); exit(0) }

        // $HOME first, like other CLIs (homeDirectoryForCurrentUser ignores it).
        let home = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let named = args.indices.filter { args[$0] == "--client" && args.indices.contains($0 + 1) }.map { args[$0 + 1] }
        if let unknown = named.first(where: { n in !skillClients.contains { $0.name == n } }) {
            fail("unknown client “\(unknown)”. Known: \(skillClients.map(\.name).joined(separator: ", "))")
        }
        let targets = skillClients.filter { c in
            named.isEmpty ? FileManager.default.fileExists(atPath: home.appendingPathComponent(c.home).path) : named.contains(c.name)
        }
        guard !targets.isEmpty else {
            stop("no supported agent found in ~ (.claude, .codex, .cursor, .gemini, .copilot). Use --client, or --print and paste it yourself.")
        }
        let fm = FileManager.default
        for c in targets {
            let dir = home.appendingPathComponent("\(c.home)/skills/roamrun")
            let file = dir.appendingPathComponent("SKILL.md")
            // Only ever touch our own plain file: a linked dir/file is managed
            // elsewhere (npx skills, a checkout), and a foreign SKILL.md is the user's.
            if [dir, file].contains(where: { (try? fm.destinationOfSymbolicLink(atPath: $0.path)) != nil }) {
                print("Skipped \(dir.path): it is a link managed elsewhere")
                continue
            }
            let existing = try? String(contentsOf: file, encoding: .utf8)
            let ours = existing?.hasPrefix("---\nname: roamrun\n") ?? false
            if args.contains("--uninstall") {
                guard ours else { print("Skipped \(dir.path): no RoamRun skill there"); continue }
                try? fm.removeItem(at: file)
                rmdir(dir.path)   // only if now empty
                print("Removed \(file.path)")
                continue
            }
            if existing != nil && !ours {
                print("Skipped \(dir.path): its SKILL.md isn't RoamRun's")
                continue
            }
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try skill.write(to: file, options: .atomic)
                print("Installed \(file.path)")
            } catch {
                stop("could not write \(dir.path): \(error.localizedDescription)")
            }
        }
        exit(0)
    }

    // MARK: - Helpers

    private static func find(_ name: String, in profiles: [DeviceProfile]) -> DeviceProfile? {
        let byName = profiles.filter { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }
        let matches = byName.isEmpty ? profiles.filter { $0.id.uuidString.lowercased().hasPrefix(name.lowercased()) } : byName
        if matches.count > 1 {
            fail("“\(name)” matches more than one device — rename one in the app, or use its id: "
                 + matches.map { "\($0.id.uuidString.prefix(8))" }.joined(separator: ", "))
        }
        return matches.first
    }

    private static func names(_ profiles: [DeviceProfile]) -> String {
        profiles.isEmpty ? "No devices saved yet — add one in the RoamRun app."
            : "Saved: " + profiles.map { "“\($0.displayName)”" }.joined(separator: ", ")
    }

    private static func owner(_ e: StatusFile.Entry) -> String {
        e.pid == getpid() ? "this process" : e.cli == true ? "roamrun CLI, pid \(e.pid)" : "RoamRun app"
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("roamrun: \(message)\n".utf8))
        exit(2)
    }
}
