import AppKit
import CoreImage
import Foundation

/// `roamrun devices | up <name> | status [name]` — the same bridge as the menu
/// bar app, headless, for SSH sessions and scripts.
@MainActor
enum CLI {
    /// This process was started as the CLI (vs. the menu bar app).
    nonisolated static var isRunning: Bool { commands.contains(CommandLine.arguments.dropFirst().first ?? "") }
    nonisolated static let commands: Set<String> = {
        var all: Set<String> = ["devices", "up", "down", "status", "doctor", "run", "install", "ota", "logs", "screenshot", "init", "version", "--version", "help", "--help", "-h"]
        #if DEVICE_CONTROL
        all.formUnion(["look", "tap"])
        #endif
        return all
    }()
    /// Posted by `roamrun down`; the app stops the bridge whose id is `object`.
    static let stopNotification = Notification.Name(AppID.bundle + ".stopBridge")
    /// What a RoamRun before 0.1.12 listens for, should it still run next to this CLI.
    // ponytail: bundle-id migration only; drop after a few releases.
    static let legacyStopNotification = Notification.Name(AppID.legacy + ".stopBridge")

    private static let usage = """
    Usage: roamrun <command>

    AI agents: `roamrun init` installs the RoamRun skill for Claude Code, Codex,
    Cursor, Gemini CLI and Copilot (`roamrun init --print` to read it now).

      devices [--json]               List saved devices (with UDID) and their bridge status
      up <name> [-v] [-d]            Bridge a device until Ctrl-C (-v: activity log; -d: run in the background —
                                     waits up to 60s for Ready and exits 1 if it isn't, but keeps trying)
      down <name>                    Stop a bridge, whether the app or another `roamrun up` runs it
      status [name] [--wait N] [--json]
                                     Bridge status, UDID and lock state; exits 0 only if Xcode can use
                                     the device (bridged and ready, or a bridge standing aside on this Wi-Fi);
                                     without a name it lists every saved device and exits 0 if any one of
                                     them is ready (--wait: wait up to N seconds for ready; each round runs
                                     one devicectl list, plus a lock check per ready device, before the
                                     deadline is looked at again, so it can return several seconds after N)
      doctor [name] [--json]         Check each step from this Mac to the device and say what to fix
                                     (without a name: devices with a running bridge, or all if none runs)
      run <name> [--scheme S] [--workspace W | --project P] [--configuration C] [--logs] [launch options]
                                     Build the project in this folder for the device, install and launch it
                                     (--logs: then stream its output like `logs`)
      install <name> <App.ipa|App.app>
                                     Install an .ipa or .app signed for the device (Debugging, Release
                                     Testing / Ad Hoc or Enterprise); checks the signing first
      logs <name> <bundle-id> [launch options]
                                     Relaunch the app with its console attached (print and os_log)
                                     until Ctrl-C — it restarts the app; it can't join one already running
      launch options (run, logs), e.g. to open one screen before a screenshot:
        --arg A                      pass A to the app (repeat for more; may start with “-”)
        --env NAME=value             set an environment variable for the app (repeatable)
        --url URL                    open URL in the app (its URL scheme or a universal link)
      screenshot <name> [file.png]   Save the device's screen as PNG (default: ./<name>-<time>.png) and
                                     print its path — to check what an app shows (Xcode 26.3+)
      ota [<name>] <App.ipa> [--replace]
                                     Publish a build for installing from the device itself, without the
                                     bridge — over Wi-Fi or cellular, and on devices that were never paired.
                                     Install only: no debugger, no logs, no screenshots. Needs an Ad Hoc or
                                     Enterprise .ipa, `tailscale serve` for HTTPS, and RoamRun.app running —
                                     it serves the page. Says which of your devices the build covers, and
                                     prints the page's address. Anyone on your tailnet can install from it
                                     (<name>: check one device rather than all; --replace: drop builds
                                     already listed under the same version and build)
      version                        Print the version (also --version)
      init [--client <name>] [--print] [--uninstall]
                                     Install the agent skill (clients: claude, codex, cursor, gemini, copilot)

    Exit codes: 0 ok/ready, 1 not ready or a check failed, 2 usage error.
    Name a device when a script needs the answer to be about that one.

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
            if wantsHelp(args) { print(usage); exit(0) }
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
            } else if store.unreadable {
                FileHandle.standardError.write(Data("roamrun: couldn't read \(ProfileStore.directory.path)/profiles.json — check its permissions\n".utf8))
            }
            let parsed: Parsed
            switch parse(args) {
            case .success(let p): parsed = p
            case .failure(let e): fail(e.message)
            }
            let (json, wait, words) = (parsed.flags.contains("--json"), parsed.wait, parsed.words)
            // `ota` is the one command whose first word may be the path: it does
            // nothing to a device, so naming one is optional there. By the count,
            // not the extension — a device may well be called "iPhone.ipa".
            let name = args[0] == "ota" && words.count < 2 ? nil : words.first
            var targets = profiles
            if let name {
                guard let p = find(name, in: profiles) else { fail("no device named \(shellName(name)). " + names(profiles)) }
                targets = [p]
            }
            switch args[0] {
            case "devices": devices(profiles, json: json)
            case "status":
                noteStaleSkills()
                status(targets, json: json, wait: wait)
            case "doctor":
                noteStaleSkills()
                // No name and nothing running: check every device rather than report "All good." unchecked.
                let running = StatusFile.read()
                let checkAll = name != nil || !targets.contains { running[$0.id] != nil }
                Task { exit(await doctor(targets, json: json, checkAll: checkAll) ? 0 : 1) }
            case "down":
                guard name != nil, let p = targets.first else { fail("which device? " + names(profiles)) }
                down(p)
            case "up":
                guard name != nil, let p = targets.first else { fail("which device? " + names(profiles)) }
                if parsed.flags.contains("-d") {
                    detach(p, verbose: parsed.flags.contains("-v"))
                } else {
                    up(p, verbose: parsed.flags.contains("-v"), detachedChild: parsed.flags.contains(detachedFlag))
                }
            case "logs":
                guard name != nil, let p = targets.first, words.count >= 2 else {
                    fail("usage: roamrun logs <name> <bundle-id>. " + names(profiles))
                }
                logs(p, bundleID: words[words.startIndex + 1], launch: parsed.launch)
            case "run":
                guard name != nil, let p = targets.first else { fail("usage: roamrun run <name> [--scheme S]. " + names(profiles)) }
                Proc.Passing.shared.begin()   // nothing it waits on may outlive it
                let v = parsed.values
                runApp(p, scheme: v["--scheme"], workspace: v["--workspace"], project: v["--project"],
                       configuration: v["--configuration"] ?? "Debug", logs: parsed.flags.contains("--logs"), launch: parsed.launch)
            case "screenshot":
                guard name != nil, let p = targets.first else {
                    fail("usage: roamrun screenshot <name> [file.png]. " + names(profiles))
                }
                screenshot(p, path: words.count >= 2 ? words[words.startIndex + 1] : nil)
            case "install":
                guard name != nil, let p = targets.first, words.count >= 2 else {
                    fail("usage: roamrun install <name> <path to .ipa or .app>. " + names(profiles))
                }
                Proc.Passing.shared.begin()
                install(p, path: words[words.startIndex + 1])
            case "ota":
                // The name is optional here, unlike every command above: nothing is
                // done *to* a device, so the .ipa is the only required argument and
                // the check runs against every device RoamRun knows.
                guard let path = words.last, path.lowercased().hasSuffix(".ipa") else {
                    fail("usage: roamrun ota [<name>] <path to .ipa>")
                }
                ota(targets, path: path, replacing: parsed.flags.contains("--replace"))
            #if DEVICE_CONTROL
            case "look":
                guard name != nil, let p = targets.first else { fail("usage: roamrun look <name> [file.png]. " + names(profiles)) }
                look(p, path: words.count >= 2 ? words[words.startIndex + 1] : nil)
            case "tap":
                guard name != nil, let p = targets.first, words.count == 3,
                      let x = Double(words[words.startIndex + 1]), let y = Double(words[words.startIndex + 2]) else {
                    fail("usage: roamrun tap <name> <x> <y> — pixels of the last `roamrun look`. " + names(profiles))
                }
                tap(p, x: x, y: y)
            #endif
            default: print(usage); exit(0)
            }
        }
        // RunLoop, not dispatchMain(): the status Timers need a running run loop.
        RunLoop.main.run()
        exit(0)
    }

    // MARK: - Arguments

    /// What each command accepts: options (value-taking ones marked) and how many words.
    nonisolated private static let specs: [String: (options: Set<String>, words: ClosedRange<Int>)] = {
        var all = baseSpecs
        #if DEVICE_CONTROL
        all["look"] = ([], 0...2)
        all["tap"] = ([], 0...3)
        #endif
        return all
    }()

    nonisolated private static let baseSpecs: [String: (options: Set<String>, words: ClosedRange<Int>)] = [
        "devices": (["--json"], 0...0),
        "status": (["--json", "--wait="], 0...1),
        "doctor": (["--json"], 0...1),
        "down": ([], 0...1),
        "up": (["-v", "-d", detachedFlag], 0...1),
        "logs": (["--arg=", "--env=", "--url="], 0...2),
        "run": (["--scheme=", "--workspace=", "--project=", "--configuration=", "--logs", "--arg=", "--env=", "--url="], 0...1),
        "screenshot": ([], 0...2),
        "install": ([], 0...2),
        "ota": (["--replace"], 0...2),
    ]

    struct Parsed: Equatable {
        var words: [String] = []
        var flags: Set<String> = []
        var values: [String: String] = [:]
        /// Every value of an option given more than once (--arg, --env), in order.
        var lists: [String: [String]] = [:]
        var wait: Double?
        var launch: Launch { Launch(args: lists["--arg"] ?? [], env: lists["--env"] ?? [], url: values["--url"]) }
    }

    /// What the app is launched with: arguments after the bundle id, environment
    /// (NAME=value) and a URL it opens — e.g. to go straight to one screen.
    struct Launch: Equatable {
        var args: [String] = []
        var env: [String] = []
        var url: String?

        /// devicectl's launch command; the environment goes through DEVICECTL_CHILD_*.
        func argv(udid: String, bundleID: String, console: Bool) -> [String] {
            ["/usr/bin/xcrun", "devicectl", "device", "process", "launch"] + (console ? ["--console"] : [])
                + ["--terminate-existing", "--device", udid] + (url.map { ["--payload-url", $0] } ?? [])
                + [bundleID] + (args.isEmpty ? [] : ["--"] + args)   // "--": devicectl would read "-Flag" as its own
        }

        /// NAME=value pairs split at the first "=": a value may contain more.
        var environment: [(name: String, value: String)] {
            env.compactMap { pair in
                pair.firstIndex(of: "=").map { (String(pair[..<$0]), String(pair[pair.index(after: $0)...])) }
            }
        }

        func exportEnvironment() {
            for (name, value) in environment { setenv("DEVICECTL_CHILD_" + name, value, 1) }
        }
    }

    struct ArgumentError: Error, Equatable { let message: String }

    /// `--help` anywhere, except as the value of `--arg` (`--arg -h` is for the app).
    nonisolated static func wantsHelp(_ args: [String]) -> Bool {
        ["help", "--help", "-h"].contains(args[0])
            || args.indices.dropFirst().contains { ["--help", "-h"].contains(args[$0]) && args[$0 - 1] != "--arg" }
    }

    /// Too few words is left to each command (its message lists the saved devices).
    nonisolated static func parse(_ args: [String]) -> Result<Parsed, ArgumentError> {
        guard let spec = specs[args[0]] else { return .success(Parsed()) }
        var p = Parsed()
        var i = 1
        while i < args.count {
            let a = args[i]
            // `--name=value`, split at the first "=": `--env=A=b` is --env with A=b.
            if a.hasPrefix("--"), let eq = a.firstIndex(of: "="), spec.options.contains(a[...eq] + "") {
                let name = String(a[..<eq]), value = String(a[a.index(after: eq)...])
                guard !value.isEmpty else {
                    return .failure(.init(message: name == "--wait" ? "--wait needs a number of seconds" : "\(name) needs a value"))
                }
                p.values[name] = value
                p.lists[name, default: []].append(value)
                i += 1
                continue
            }
            if spec.options.contains(a + "=") {
                // --arg values are often flags themselves (-ShowScreen), --wait may be negative (refused below).
                guard i + 1 < args.count, !args[i + 1].hasPrefix("-") || a == "--wait" || a == "--arg" else {
                    return .failure(.init(message: a == "--wait" ? "--wait needs a number of seconds" : "\(a) needs a value"))
                }
                p.values[a] = args[i + 1]
                p.lists[a, default: []].append(args[i + 1])
                i += 2
                continue
            }
            if a.hasPrefix("-") {
                guard !a.hasSuffix("="), spec.options.contains(a) else {
                    let hint = spec.words.upperBound > 0 ? " (a device name starting with “-”? use its id, see roamrun devices)" : ""
                    return .failure(.init(message: "\(args[0]) doesn't take \(a) — see roamrun --help\(hint)"))
                }
                p.flags.insert(a)
            } else {
                guard p.words.count < spec.words.upperBound else {
                    return .failure(.init(message: "unexpected \(shellName(a)) — see roamrun --help"))
                }
                p.words.append(a)
            }
            i += 1
        }
        // Only the name is checked: a value may be anything, even several lines.
        for pair in p.lists["--env"] ?? [] where pair.prefixMatch(of: #/[A-Za-z_][A-Za-z0-9_]*=/#) == nil {
            return .failure(.init(message: "--env takes NAME=value, not \(shellName(pair))"))
        }
        if let u = p.values["--url"], URL(string: u)?.scheme == nil {
            return .failure(.init(message: "--url needs a URL with a scheme, e.g. myapp://settings"))
        }
        if let w = p.values["--wait"] {
            guard let n = Double(w), n.isFinite, n >= 0 else { return .failure(.init(message: "--wait needs a number of seconds")) }
            p.wait = n
        }
        return .success(p)
    }

    // MARK: - Commands

    /// One device as `status --json` / `devices --json` report it. Every key is always
    /// there — an unknown value is `null`, as SKILL.md says, not a missing key.
    struct Row: Encodable {
        let name: String
        /// Stable key for scripts: off, starting, waiting, preparing, ready, error, local (on this Wi-Fi).
        let state: String
        let id: String
        let vpnAddress: String
        let udid: String?
        let status: String
        let ready: Bool
        let owner: String?
        let pid: Int32?
        let tunnelPorts: [UInt16]
        /// "wifi" or "cellular" while ready over the bridge; "cellular" also while waiting
        /// because it closed the tunnel on cellular (see `detail`); nil otherwise.
        let network: String?
        /// CoreDevice's view: "connected", "disconnected" (reachable, no tunnel yet) or "unavailable".
        let coreDevice: String?
        let detail: String?
        /// nil when unknown (not queried, or the iPhone is unreachable).
        let locked: Bool?

        private enum CodingKeys: String, CodingKey {
            case name, state, id, vpnAddress, udid, status, ready, owner, pid, tunnelPorts, network, coreDevice, detail, locked
        }

        /// `encode`, not the synthesized `encodeIfPresent`: nil becomes `null`.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(state, forKey: .state)
            try c.encode(id, forKey: .id)
            try c.encode(vpnAddress, forKey: .vpnAddress)
            try c.encode(udid, forKey: .udid)
            try c.encode(status, forKey: .status)
            try c.encode(ready, forKey: .ready)
            try c.encode(owner, forKey: .owner)
            try c.encode(pid, forKey: .pid)
            try c.encode(tunnelPorts, forKey: .tunnelPorts)
            try c.encode(network, forKey: .network)
            try c.encode(coreDevice, forKey: .coreDevice)
            try c.encode(detail, forKey: .detail)
            try c.encode(locked, forKey: .locked)
        }
    }

    /// With `deep`, `ready` means Xcode can use the device right now: the bridge is up
    /// *and* CoreDevice sees the iPhone. The bridge alone can look ready for a while
    /// after the iPhone falls asleep (its relayed connections linger). Without it
    /// (`devices --json`), `ready` is only the bridge's word, or "on this Wi‑Fi".
    private static func row(_ p: DeviceProfile, _ e: StatusFile.Entry?, deep: Bool, by deadline: Date? = nil,
                            coreState: ((String) -> String?)? = nil) -> Row {
        let udid = e?.udid ?? p.udid
        let usable = e?.ready == true || e?.kind == .local   // on this Wi-Fi: Xcode sees it directly
        let core = deep && usable ? udid.flatMap { u in coreState.map { $0(u) } ?? coreDeviceState(u, by: deadline) } : nil
        let r = readiness(e, udid: udid, core: core, deep: deep)
        return Row(name: p.displayName, state: r.kind.rawValue, id: p.id.uuidString, vpnAddress: p.providerIP, udid: udid,
                   status: r.status, ready: r.ready,
                   owner: e.map(owner), pid: e?.pid, tunnelPorts: e?.tunnelPorts ?? [],
                   network: r.ready || e?.kind == .waiting ? e?.network : nil,
                   coreDevice: core, detail: r.detail,
                   locked: deep && r.ready ? udid.flatMap { isLocked($0, by: deadline) } : nil)
    }

    /// Whether Xcode can use the device now, and what `status` shows for it.
    /// `core` is CoreDevice's tunnelState (nil: not asked, or devicectl failed).
    nonisolated static func readiness(_ e: StatusFile.Entry?, udid: String?, core: String?, deep: Bool)
        -> (ready: Bool, kind: BridgeStatus, status: String, detail: String?) {
        let usable = e?.ready == true || e?.kind == .local   // on this Wi-Fi: Xcode sees it directly
        // No UDID yet (standing aside before it ever connected): nothing to ask CoreDevice, trust the bridge.
        let ready = usable && (!deep || udid == nil || core.map { $0 != "unavailable" } ?? false)
        var status = e?.status ?? BridgeStatus.off.title
        var kind = e?.kind ?? .off
        var detail = e.flatMap { $0.detail.isEmpty ? nil : $0.detail }
        if e?.ready == true && !ready {
            status = BridgeStatus.waiting.title
            kind = .waiting
            detail = "The bridge is up but Xcode can't reach the device (asleep, locked, off Wi-Fi, or Tailscale stuck on the device). Run `roamrun doctor` for the cause."
            // Exactly the state a blocked local network produces, so don't lose the reason.
            if e?.detail.contains(LocalNetwork.advice) == true { detail! += " — " + LocalNetwork.advice }
        } else if e?.kind == .local && !ready {
            // Still on this Wi‑Fi (so `state` stays local), but not usable right now.
            detail = "On this Wi‑Fi, but Xcode can't reach the device right now (asleep or locked, or CoreDevice didn't answer). Ask the user to unlock it and keep the screen on, then check again."
        }
        return (ready, kind, status, detail)
    }

    /// devicectl's tunnelState for this UDID; nil if devicectl failed.
    nonisolated static func coreDeviceState(_ udid: String, by deadline: Date? = nil) -> String? {
        devicectl(["list", "devices"], by: deadline).flatMap { tunnelState(in: $0, udid: udid) }
    }

    /// devicectl with only as much time as a `--wait` has left; without one, the
    /// timeouts it has always had.
    nonisolated private static func devicectl(_ args: [String], by deadline: Date?) -> [String: Any]? {
        let secs = probeSeconds(by: deadline)
        let timed = ["--timeout", "\(secs)"] + args
        guard deadline != nil else { return Proc.devicectl(timed) }
        return Proc.devicectl(timed, timeout: Double(secs) + 5)
    }

    /// How long a `status` probe may take. Each round of `--wait N` runs one
    /// `devicectl list devices` plus a lock check per ready device before the
    /// deadline is looked at again, so without this a `--wait 1` could sit for
    /// ~20s per call. devicectl
    /// refuses a --timeout below 5, which is the floor here too.
    nonisolated static func probeSeconds(by deadline: Date?, now: Date = .now) -> Int {
        guard let deadline else { return 10 }
        // Clamped as a Double first: --wait only has to be finite, and Int(1e19) traps.
        return Int(max(5, min(10, deadline.timeIntervalSince(now))).rounded(.up))
    }

    /// From `devicectl list devices` JSON's result; UDIDs compared in any case.
    nonisolated static func tunnelState(in result: [String: Any], udid: String) -> String? {
        let device = (result["devices"] as? [[String: Any]])?.first {
            (($0["hardwareProperties"] as? [String: Any])?["udid"] as? String)?.caseInsensitiveCompare(udid) == .orderedSame
        }
        return (device?["connectionProperties"] as? [String: Any])?["tunnelState"] as? String
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: (try? enc.encode(value)) ?? Data(), as: UTF8.self))
    }

    private static func devices(_ profiles: [DeviceProfile], json: Bool) -> Never {
        let live = StatusFile.read()
        if json { printJSON(profiles.map { row($0, live[$0.id], deep: false) }); exit(0) }
        guard !profiles.isEmpty else { print(noDevices); exit(0) }
        let w = max(4, profiles.map(\.displayName.count).max() ?? 4)
        print("NAME".padding(toLength: w + 2, withPad: " ", startingAt: 0)
              + "VPN ADDRESS      UDID                       ID                                    STATUS")
        for p in profiles {
            let e = live[p.id]
            let status = e.map { "\($0.status) (\(owner($0)))" } ?? BridgeStatus.off.title
            print(p.displayName.padding(toLength: w + 2, withPad: " ", startingAt: 0)
                  + p.providerIP.padding(toLength: 17, withPad: " ", startingAt: 0)
                  + (e?.udid ?? p.udid ?? "-").padding(toLength: 27, withPad: " ", startingAt: 0)
                  + p.id.uuidString.padding(toLength: 38, withPad: " ", startingAt: 0) + status)
        }
        exit(0)
    }

    private static func status(_ targets: [DeviceProfile], json: Bool, wait: Double?) -> Never {
        if targets.isEmpty && !json { stop(noDevices) }
        var rows: [Row]
        let deadline = Date.now.addingTimeInterval(wait ?? 0)
        let budget = wait == nil ? nil : deadline   // no --wait: the probes keep their own timeouts
        repeat {
            let live = StatusFile.read()
            // One `devicectl list devices` a round, not one per device, and none if no row needs it.
            var listed: [String: Any]??
            let coreState = { (udid: String) -> String? in
                if listed == nil { listed = .some(devicectl(["list", "devices"], by: budget)) }
                return listed!.flatMap { tunnelState(in: $0, udid: udid) }
            }
            rows = targets.map { row($0, live[$0.id], deep: true, by: budget, coreState: coreState) }
            if rows.contains(where: \.ready) || Date.now >= deadline { break }
            usleep(useconds_t(min(3, max(0.1, deadline.timeIntervalSinceNow)) * 1_000_000))   // each round spawns devicectl
        } while true
        if json {
            printJSON(rows)
        } else {
            for r in rows {
                var line = "\(r.name): \(r.status)"
                if let n = r.network.flatMap(DeviceNetwork.init(rawValue:)) { line += " · \(n.title)" }
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
    private static func isLocked(_ udid: String, by deadline: Date? = nil) -> Bool? {
        devicectl(["device", "info", "lockState", "--device", udid], by: deadline)?["passcodeRequired"] as? Bool
    }

    /// Keeps a build where the device can fetch it over HTTPS, bridge or no
    /// bridge. Nothing is built here: exporting an .ipa needs the project's own
    /// signing settings.
    private static func ota(_ profiles: [DeviceProfile], path given: String, replacing: Bool) -> Never {
        guard FileManager.default.fileExists(atPath: given) else { stop("\(given) doesn't exist") }
        sweepStaleUnpacks(in: FileManager.default.temporaryDirectory)   // an interrupted earlier run's unpacking
        // A build script's `latest.ipa -> MyApp-1.2.ipa` would otherwise be stored
        // as the link itself: a few bytes, and nothing to serve.
        let path = URL(fileURLWithPath: given).resolvingSymlinksInPath().path
        // A trailing slash is how a shell completes a directory; .ipa is a file either way.
        guard path.lowercased().trimmingCharacters(in: ["/"]).hasSuffix(".ipa") else {
            stop("\(given) isn't an .ipa — over-the-air installs need an archive, not an .app bundle")
        }
        let running = StatusFile.read()
        let devices = profiles.map { OTA.Device(name: $0.displayName, udid: running[$0.id]?.udid ?? $0.udid) }
        do {
            var build = try OTA.read(ipa: path)
            let checked = try OTA.check(CLI.profilePlist(of: path), against: devices, path: given)
            build.expires = checked.expires
            // Not while nothing of yours can take it: `--replace` would remove the
            // build people are running to make room for one they can't install,
            // and there would be no way back to it.
            var noneOfYours = false
            if case .noneOfYours = checked.coverage { noneOfYours = true }
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
               !(beside.isEmpty && (here == nil || AppCoordinator.isOurs(here!, on: tailnetPort))) {
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
            if isatty(STDOUT_FILENO) != 0 { print(qr(url)) }
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
        func dark(_ x: Int, _ y: Int) -> Bool { y < 0 || y >= h ? false : pixels[y * w + x] < 128 }
        let quiet = 2
        // Black on white, said explicitly: a block character takes the terminal's
        // own foreground colour, so on a dark theme the code would come out
        // inverted — which a camera won't read.
        let paper = "\u{1b}[30;47m", plain = "\u{1b}[0m"
        var out = ""
        for row in stride(from: -quiet * 2, to: h + quiet * 2, by: 2) {
            out += paper + String(repeating: " ", count: quiet)
            for x in -quiet..<(w + quiet) {
                let top = x < 0 || x >= w ? false : dark(x, row)
                let bottom = x < 0 || x >= w ? false : dark(x, row + 1)
                out += top && bottom ? "\u{2588}" : top ? "\u{2580}" : bottom ? "\u{2584}" : " "
            }
            out += String(repeating: " ", count: quiet) + plain + "\n"
        }
        return out
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
            stop("\(profile.displayName)'s UDID isn't known yet — start its bridge once: roamrun up \(commandName(profile)) -d")
        }
        let core = coreDeviceState(udid)
        guard let core, core != "unavailable" else {
            stop("Xcode can't reach \(profile.displayName) (\(core ?? "unknown")). If it's away, start the bridge: roamrun up \(commandName(profile)) -d; otherwise run roamrun doctor \(commandName(profile)).")
        }
        if isLocked(udid) == true { stop("\(profile.displayName) is locked — ask the user to unlock it and keep the screen on.") }
        return udid
    }

    /// Hands over to devicectl so Ctrl-C and kill reach it directly.
    private static func exec(_ argv: [String]) -> Never {
        Proc.Passing.shared.endForExec()
        var cargs = argv.map { strdup($0) } + [nil]
        execv(argv[0], &cargs)
        stop("could not run \(argv[0]): \(String(cString: strerror(errno)))")
    }

    /// Through the tunnel like everything else: works over the bridge.
    #if DEVICE_CONTROL
    // Experimental (device control): the app holds the connection; these ask it.

    private static func askApp(_ request: DeviceControlWire.Request) -> DeviceControlWire.Response {
        do {
            return try DeviceControlWire.ask(request, in: ProfileStore.directory)
        } catch DeviceControlWire.WireError.noApp {
            stop("the RoamRun app isn't running (or is a build without device control): it holds the connection to the device")
        } catch {
            stop("couldn't ask the RoamRun app: \(error)")
        }
    }

    /// The device's screen now, as PNG. Prints the path, then the size a tap's point is in.
    private static func look(_ profile: DeviceProfile, path: String?) -> Never {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let file = URL(fileURLWithPath: path ?? "\(fileSafe(profile.displayName))-look-\(f.string(from: .now)).png").standardizedFileURL
        guard file.pathExtension.lowercased() == "png" else { fail("the file must end in .png") }
        let r = askApp(.init(op: "look", device: profile.id, path: file.path))
        guard r.ok, let w = r.width, let h = r.height else { stop("look failed: \(r.error ?? "no answer")") }
        print(file.path)
        print("\(w) x \(h)")
        exit(0)
    }

    /// One tap, at a point in the pixels of the last look. Operates the device.
    private static func tap(_ profile: DeviceProfile, x: Double, y: Double) -> Never {
        let r = askApp(.init(op: "tap", device: profile.id, x: x, y: y))
        guard r.ok else { stop("tap failed: \(r.error ?? "no answer")") }
        exit(0)
    }
    #endif

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
        let tmp = FileManager.default.temporaryDirectory
        sweepStaleUnpacks(in: tmp)   // a Ctrl-C during an earlier install (or ota) skipped its cleanUp
        let udid = reachableUDID(profile)
        guard path.lowercased().hasSuffix(".ipa") else {
            checkSigning(profile, udid: udid, path: path)
            exec(["/usr/bin/xcrun", "devicectl", "device", "install", "app", "--device", udid, path])
        }
        // devicectl documents .app bundles only: unpack the .ipa and hand it the .app inside.
        let dir = tmp.appendingPathComponent("roamrun-ipa-\(UUID().uuidString)")
        let cleanUp = { try? FileManager.default.removeItem(at: dir) }   // exit() skips defer
        let unzip = Proc.run("/usr/bin/ditto", ["-x", "-k", path, dir.path], timeout: 300)
        guard unzip.status == 0 else { cleanUp(); stop("couldn't unpack \(path): \(firstLine(unzip.err) ?? "ditto exited \(unzip.status)")") }
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
        checkSigning(profile, udid: udid, path: appURL.path, shown: path, cleanUp: { _ = cleanUp() })
        let status = visible(["/usr/bin/xcrun", "devicectl", "device", "install", "app", "--device", udid,
                              payload.appendingPathComponent(app).path])
        cleanUp()
        exit(status)
    }

    /// Unpacked archives an interrupted `install` or `ota` (or their signing and icon
    /// checks) left behind. An hour is longer than any of them, so one running in
    /// another terminal is never touched.
    nonisolated static func sweepStaleUnpacks(in tmp: URL, now: Date = .now) {
        let fm = FileManager.default
        let ours = ["roamrun-ipa-", "roamrun-install-", "roamrun-ota-", "roamrun-icon-"]
        for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where ours.contains(where: name.hasPrefix) {
            let url = tmp.appendingPathComponent(name)
            let made = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? now
            if made < now.addingTimeInterval(-3600) { try? fm.removeItem(at: url) }
        }
    }

    /// App Store builds and builds not provisioned for this device fail with a
    /// cryptic devicectl error — say what's wrong before trying.
    /// `shown`: how to name it (the .ipa it came from); `cleanUp` runs before a refusal exits.
    private static func checkSigning(_ profile: DeviceProfile, udid: String, path: String, shown: String? = nil,
                                     cleanUp: () -> Void = {}) {
        let name = shown ?? path
        switch provisioning(of: path) {
        case .appStore:
            cleanUp(); stop("\(name) is signed for App Store / TestFlight and can't be installed directly. Export it for Debugging, Release Testing (Ad Hoc) or Enterprise.")
        case .devices(let list) where !list.contains(where: { $0.caseInsensitiveCompare(udid) == .orderedSame }):
            cleanUp(); stop("\(name) isn't signed for \(profile.displayName) (UDID \(udid) is not in its provisioning profile). Add the device to the profile and export again.")
        case .unknown:
            let info = NSDictionary(contentsOfFile: (path as NSString).appendingPathComponent("Info.plist"))
            if (info?["DTPlatformName"] as? String)?.hasSuffix("simulator") == true {
                cleanUp(); stop("\(name) is a Simulator build — build for a device (Any iOS Device / the device itself).")
            }
            FileHandle.standardError.write(Data("roamrun: couldn't read \(name)'s provisioning profile — if the install fails, check it's a device build signed for \(profile.displayName)\n".utf8))
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
    private static func runApp(_ profile: DeviceProfile, scheme: String?, workspace: String?, project: String?,
                               configuration: String, logs: Bool, launch: Launch) -> Never {
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
            + ["-scheme", chosen, "-configuration", configuration, "-destination", "id=\(udid)", "-allowProvisioningUpdates"]
        print("Building \(chosen) for \(profile.displayName)…")
        guard visible(build + ["-quiet", "build"]) == 0 else { stop("the build failed (see above)") }

        // The built .app: the build settings of the target that produces one.
        let settings = Proc.run(build[0], Array(build.dropFirst()) + ["-showBuildSettings", "-json"], timeout: 300)
        let targets = (try? JSONSerialization.jsonObject(with: Data(settings.out.utf8))) as? [[String: Any]] ?? []
        guard let s = appTarget(in: targets, scheme: chosen), let dir = s["TARGET_BUILD_DIR"], let wrapper = s["WRAPPER_NAME"] else {
            stop("built, but couldn't find the .app in the build settings (\(firstLine(settings.err) ?? "no app target"))")
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
        if logs { launchWithConsole(udid: udid, bundleID: bundleID, launch: launch) }
        launch.exportEnvironment()
        exec(launch.argv(udid: udid, bundleID: bundleID, console: false))
    }

    /// The target `run` installs: an application (not an App Clip, extension or
    /// watch app), the scheme's own target first.
    nonisolated static func appTarget(in targets: [[String: Any]], scheme: String) -> [String: String]? {
        let apps = targets.compactMap { $0["buildSettings"] as? [String: String] }
            .filter { $0["WRAPPER_EXTENSION"] == "app" && $0["PLATFORM_NAME"] != "watchos" }
        let real = apps.filter { $0["PRODUCT_TYPE"] == "com.apple.product-type.application" }
        let pool = real.isEmpty ? apps : real
        return pool.first { $0["TARGET_NAME"] == scheme } ?? pool.first
    }

    private static func firstLine(_ s: String) -> String? {
        s.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init)
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
            _ = Proc.run("/usr/bin/unzip", ["-qo", path, "Payload/*.app/embedded.mobileprovision", "-d", dir.path], timeout: 30)
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
        stop("\(profile.displayName) is being bridged by \(owner(e)) (\(e.status)). Use it once it's ready, or run roamrun down \(commandName(profile)) first.")
    }

    /// devicectl can't attach to a running process, so this relaunches the app
    /// with `--console`. OS_ACTIVITY_DT_MODE mirrors os_log to stderr, as Xcode does.
    private static func logs(_ profile: DeviceProfile, bundleID: String, launch: Launch) -> Never {
        launchWithConsole(udid: reachableUDID(profile), bundleID: bundleID, launch: launch)
    }

    /// Relaunch with print / os_log streamed here until Ctrl-C.
    private static func launchWithConsole(udid: String, bundleID: String, launch: Launch) -> Never {
        setenv("DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE", "enable", 1)
        launch.exportEnvironment()   // after: the caller's --env OS_ACTIVITY_DT_MODE=… wins
        exec(launch.argv(udid: udid, bundleID: bundleID, console: true))
    }

    private static func down(_ profile: DeviceProfile) -> Never {
        guard let e = StatusFile.read()[profile.id] else {
            print("\(profile.displayName) is not bridged."); exit(0)
        }
        let who = owner(e)   // before it exits and the pid stops resolving
        // Always tell the app too: even when the CLI owns the device, the app
        // may still have it on its restore list and would take it back.
        for name in [stopNotification, legacyStopNotification] {
            DistributedNotificationCenter.default().postNotificationName(
                name, object: profile.id.uuidString, userInfo: nil, deliverImmediately: true)
        }
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
    nonisolated private static let detachedFlag = "--detached-child"

    /// `up -d`: re-launch ourselves in a new session with output going to a
    /// log file, wait until the bridge settles, then hand the prompt back.
    private static func detach(_ profile: DeviceProfile, verbose: Bool) -> Never {
        if StatusFile.otherOwner(of: profile.id) != nil, let e = StatusFile.read()[profile.id] {
            alreadyBridged(profile, e)
        }
        // Another `roamrun up` already watches it (standing aside on this Wi‑Fi): a second would just yield.
        if let e = StatusFile.read()[profile.id], e.cli == true, e.pid != getpid(), e.kind == .local {
            print("\(profile.displayName) is on this Wi\u{2011}Fi and already watched by roamrun up (pid \(e.pid)) — it takes over when the device leaves.")
            exit(0)
        }
        let logURL = detachedLog(profile)
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep the previous run's log (an earlier failure may point at it).
        let previous = logURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: logURL, to: previous)
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
        var last = "", lastKind = BridgeStatus.off
        for _ in 0..<120 {
            usleep(500_000)
            guard child.isRunning else {
                // It exits on an error retrying can't fix (see up); its last line says which.
                let tail = (try? String(contentsOf: logURL, encoding: .utf8)).flatMap { $0.split(separator: "\n").last.map(String.init) }
                stop("the background bridge exited\(tail.map { ": \($0)" } ?? "") — see \(logURL.path)")
            }
            guard let e = StatusFile.read()[profile.id], e.pid == child.processIdentifier else { continue }
            if e.status != last { last = e.status; print("  \(e.status)") }
            lastKind = e.kind
            if e.ready || e.kind == .local { break }
        }
        let pid = child.processIdentifier
        switch lastKind {
        case .ready:
            print("\(profile.displayName) is bridged in the background (pid \(pid)).")
        case .local:
            print("\(profile.displayName) is on this Wi‑Fi, so Xcode reaches it directly. The bridge waits in the background (pid \(pid)) and takes over when it leaves.")
        default:
            print("\(profile.displayName) isn't ready yet (\(last.isEmpty ? "no status" : last)). The bridge keeps trying in the background (pid \(pid)).")
        }
        print("""
          Log:  \(logURL.path)
          Stop: roamrun down \(commandName(profile))
        """)
        exit(lastKind == .ready || lastKind == .local ? 0 : 1)
    }

    /// Where `up -d`'s bridge writes; the previous run's is kept beside it as `.log.1`.
    private static func detachedLog(_ profile: DeviceProfile) -> URL {
        let safeName = fileSafe(profile.displayName)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/RoamRun", isDirectory: true)
            .appendingPathComponent("\(safeName.isEmpty ? profile.id.uuidString : safeName).log")
    }

    /// The background bridge's stdout and stderr are its log file; one left running for weeks
    /// would fill the disk. Past `limit`, the file becomes `.log.1` (replacing that) and a new
    /// one is opened under the same descriptors. A rename that fails changes nothing: the
    /// writing goes on where it was, and nothing is deleted.
    nonisolated static func rotateLog(at url: URL, limit: Int64 = 10 << 20, fds: [Int32] = [STDOUT_FILENO, STDERR_FILENO]) {
        var st = stat()
        guard let first = fds.first, fstat(first, &st) == 0, st.st_size > limit else { return }
        let fm = FileManager.default
        let previous = url.appendingPathExtension("1")
        let rolling = url.appendingPathExtension("rolling"), backup = url.appendingPathExtension("1.backup")
        // Each step can be undone until the new file is open; only then does the old `.1` go.
        try? fm.removeItem(at: rolling)
        try? fm.removeItem(at: backup)
        guard (try? fm.moveItem(at: url, to: rolling)) != nil else { return }
        let hadPrevious = fm.fileExists(atPath: previous.path)
        func undo() {
            if fm.fileExists(atPath: previous.path), !fm.fileExists(atPath: rolling.path) {
                try? fm.moveItem(at: previous, to: rolling)   // step 3 had happened
            }
            if hadPrevious { try? fm.moveItem(at: backup, to: previous) }
            try? fm.moveItem(at: rolling, to: url)
        }
        guard !hadPrevious || (try? fm.moveItem(at: previous, to: backup)) != nil else { return undo() }
        guard (try? fm.moveItem(at: rolling, to: previous)) != nil else { return undo() }
        let fresh = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fresh >= 0 else { return undo() }   // still writing to the renamed file: it gets its name back
        try? fm.removeItem(at: backup)
        for fd in fds { dup2(fresh, fd) }
        close(fresh)
    }

    private static func up(_ profile: DeviceProfile, verbose: Bool, detachedChild: Bool = false) {
        if StatusFile.otherOwner(of: profile.id) != nil, let e = StatusFile.read()[profile.id] {
            alreadyBridged(profile, e)
        }
        var logRotation: Timer?
        if detachedChild {
            // Own session: closing the terminal / ending SSH doesn't reach us.
            setsid()
            signal(SIGHUP, SIG_IGN)
            let log = detachedLog(profile)
            logRotation = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in rotateLog(at: log) }
        }
        let bridge = ProxyBridge(profile: profile)
        self.bridge = bridge
        bridge.onLog = { m in if verbose { print("    \(m)") } }
        bridge.onYield = { other in
            print("\(profile.displayName): another roamrun up (pid \(other.pid)) is already handling it — exiting.")
            exit(0)
        }
        bridge.onUDID = { udid in   // the app saves it too; without this, CLI-only use never learns it
            _ = ProfileStore().update { all in
                guard let i = all.firstIndex(where: { $0.id == profile.id }), all[i].udid == nil else { return }
                all[i].udid = udid
            }
        }
        bridge.onProfileChange = { moved in   // save where the device answers now, as the app does
            var found = false
            let saved = ProfileStore().update { all in
                guard let i = all.firstIndex(where: { $0.id == moved.id }) else { return }
                found = true
                all[i].providerIP = moved.providerIP
                all[i].remotePairingPort = moved.remotePairingPort
                all[i].providerHostName = moved.providerHostName
            }
            guard found || !saved else { return }   // a lock we couldn't take never ran the closure
            print("  \(moved.displayName) now answers at \(moved.providerIP):\(moved.remotePairingPort)\(saved ? " (saved)" : " (couldn't save it)")")
        }

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
                if bridge.status == .ready, let n = bridge.network { line += " · \(n.title)" }
                if bridge.status == .ready { line += " — pick “\(profile.displayName)” in Xcode. Ctrl-C to stop." }
                if bridge.status == .local { line += " — Xcode sees it directly; bridging resumes when it leaves." }
                if bridge.status == .waiting, bridge.pausedOnCellular {
                    line += " — on cellular, so the tunnel was closed to save data; it reconnects on Wi‑Fi."
                }
                guard line != last else { return }
                last = line
                print("[\(Date.now.formatted(date: .omitted, time: .standard))] \(line)")
            }
        }
        // Same recovery as the app: retry errors, rebind when the Mac's IP changes, re-announce on wake.
        let supervisor = BridgeSupervisor(all: { [bridge] }, wanted: { _ in true }, start: { list, reason in
            for b in list {
                if StartPolicy.of(reason).restarts { b.stop() }
                b.requestStart(reason)
            }
        }, gaveUp: { b in
            // Retrying can't fix it (lost pairing, no admin rights): say why and stop.
            let reason = { if case .error(let m) = b.state { m } else { "the bridge failed" } }()
            b.stop()   // before printing: its "bridge stopped" line mustn't be the log's last
            FileHandle.standardError.write(Data("roamrun: \(reason)\n".utf8))
            exit(1)
        })
        supervisor.run()
        let wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                     object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { supervisor.woke() }
        }
        let monitor = InterfaceMonitor()
        monitor.onLost = { Task { @MainActor in supervisor.lanAddressLost() } }
        monitor.onChange = { _ in Task { @MainActor in supervisor.lanAddressChanged() } }
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
        keepAlive = [ticker, supervisor, monitor, wake] + sources + (logRotation.map { [$0] } ?? [])

        print("Bridging \(profile.displayName) over \(profile.providerIP)…")
        bridge.requestStart(.manual)
    }

    /// Walks the path Xcode → this Mac → Tailscale → iPhone and reports the
    /// first thing to fix at each hop.
    struct Check: Encodable {
        let scope: String          // "mac" or the device's name
        let result: String         // "ok", "warning", "fail" or "skipped"
        let message: String
        let fix: String?

        private enum CodingKeys: String, CodingKey { case scope, result, message, fix }

        /// `fix` is `null` when there is nothing to do, like Row's unknowns.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(scope, forKey: .scope)
            try c.encode(result, forKey: .result)
            try c.encode(message, forKey: .message)
            try c.encode(fix, forKey: .fix)
        }
    }

    /// Unless checkAll, devices whose bridge is off are skipped: an unused device
    /// isn't a problem to report.
    private static func doctor(_ profiles: [DeviceProfile], json: Bool, checkAll: Bool) async -> Bool {
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
              "Xcode's devicectl is available", fix: "Install Xcode and run it once (sudo xcode-select -s /Applications/Xcode.app).")
        let ip = InterfaceMonitor.currentIPv4()
        let lan = InterfaceMonitor.lanInterface
        check(ip != nil, "LAN address (\(lan)): \(ip ?? "none")",
              fix: "Connect \(lan) to the network — the bridge listens where Xcode looks for devices. To use another interface, pick it in RoamRun (Open RoamRun › ⚙ Settings › Network).")
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
            if profiles.contains(where: { viaTailscale($0) && (checkAll || live[$0.id] != nil) }) {
                check(false, "Tailscale: \(error.localizedDescription)", fix: "Install Tailscale and sign in, or set its CLI path in RoamRun (Open RoamRun › ⚙ Settings).")
                return finish()
            }
            note("Tailscale not checked (no device uses it)")
        }

        if profiles.isEmpty { check(false, "No devices saved", fix: "Add one in the RoamRun app.") }
        for p in profiles {
            section("\n\(p.displayName) (\(p.providerIP))", p.displayName)
            if !checkAll, live[p.id] == nil {
                note("Bridge is off — not checked (roamrun doctor \(commandName(p)) checks it anyway)")
                continue
            }
            // On this Wi‑Fi Xcode reaches the device directly: the VPN path doesn't matter.
            if live[p.id]?.kind == .local {
                note("On this Wi\u{2011}Fi — VPN checks skipped (Xcode reaches the device directly)")
            } else {
                if viaTailscale(p) {
                    guard let peer = peers.first(where: { $0.ips.contains(p.providerIP) }) else {
                        check(false, "Not found on this tailnet", fix: "Sign the device into the same tailnet, or remove and re-add it in RoamRun.")
                        continue
                    }
                    check(peer.online, "Tailscale peer “\(peer.name)” is \(peer.online ? "online" : "offline")",
                          fix: "Unlock the device and keep its screen on — while it sleeps, iOS pauses the Tailscale VPN too.")
                    // On this Wi-Fi Xcode reaches the device directly; the Tailscale path doesn't matter.
                    if peer.online, live[p.id]?.kind != .local {
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
            }
            // How remotepairingd last resolved our record (nil = pairing lost), or any
            // advert matched to this UDID. Only plain hex/UUIDs go into the predicates.
            let plain = { (s: String) in !s.isEmpty && s.allSatisfy { $0.isHexDigit || $0 == "-" } }
            let udid = live[p.id]?.udid ?? p.udid
            // Through the hardened parser: instance names in these lines come from the LAN.
            let adverts = { (phrase: String) in TunnelPortWatcher.recentAdverts(last: "15m", containing: phrase) }
            let ours = plain(p.instanceName) ? adverts("Resolved bonjour advert \(p.instanceName) to identity").last { $0.0 == p.instanceName } : nil
            if let ours, ours.1 == nil {
                check(false, "This Mac does not recognize the device's pairing (identity nil)",
                      fix: "Put the device on this Mac's Wi-Fi, remove it in RoamRun and add it again. If Xcode lost it too, pair it in Xcode first.")
            } else if ours != nil || (udid.map(plain) == true && adverts("associated with udid \(udid ?? "")")
                .contains { $0.1?.caseInsensitiveCompare(udid ?? "") == .orderedSame }) {
                check(true, "This Mac recognizes the device's pairing")
            } else {
                note("Pairing not checked — no advert of this device was matched in the last 15 minutes")
            }
            if let e = live[p.id] {
                let own = LocalNetwork.withoutAdvice(e.detail)   // it gets its own line below
                let over = e.deviceNetwork.map { " over \($0 == .wifi ? "Wi‑Fi" : "cellular")" } ?? ""
                check(e.ready || e.kind == .local, "Mac-side bridge: \(e.status)\(over) (\(owner(e)))", fix: own.isEmpty ? "Wait a few seconds and run doctor again." : own)
                if e.deviceNetwork == .cellular, e.kind == .ready {
                    note("The device is on cellular: Xcode keeps the tunnel set up on Wi‑Fi, but a new one needs Wi‑Fi again")
                }
                if e.detail.contains(LocalNetwork.advice) {
                    check(false, "macOS is blocking RoamRun's local network access, so it can't tell whether the device is on this Wi-Fi",
                          fix: LocalNetwork.advice, warnOnly: true)
                }
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
                check(false, "Bridge is off", fix: "roamrun up \(commandName(p)) -d  (or Start Bridge in the app)")
            }
        }
        otaSection(section: section, check: check, note: note)
        return finish()
    }

    enum OTAIssue { case notPublished, noHTTPSCertificates, funnel }

    /// Which over-the-air findings fail `doctor` (exit 1). Scripts read that as "the
    /// device isn't usable", so only a page exposed to the internet does; the page
    /// not being up — or the reason it can't be — is a warning, whatever device was named.
    nonisolated static func failsDoctor(_ issue: OTAIssue) -> Bool { issue == .funnel }

    /// Only when there is something stored: the address to reopen, what is kept,
    /// and whether the page is actually being served. Nothing to say otherwise.
    private static func otaSection(section: (String, String) -> Void,
                                   check: (Bool, String, String, Bool) -> Void,
                                   note: (String) -> Void) {
        guard let apps = OTA.builds() else {
            section("\nOver the air", "ota")
            check(false, "Can't read \(OTA.directory.path)",
                  "The install page answers 503 while this is true. Check the folder's permissions.", true)
            return
        }
        // Counted over the folders, not over `apps`: an app whose every build has
        // metadata this version can't decode has no entry in `apps` at all, and
        // that is precisely the app this count exists for.
        let undecodable = (OTA.appDirectories() ?? []).reduce(0) { $0 + OTA.unreadableBuilds(of: $1) }
        guard !apps.isEmpty || undecodable > 0 else { return }
        let mine: Bool
        var stray = false
        section("\nOver the air", "ota")
        let builds = apps.flatMap(\.builds)
        let bytes = builds.reduce(Int64(0)) { $0 + $1.size }
        note("\(builds.count) build\(builds.count == 1 ? "" : "s") of \(apps.count) app\(apps.count == 1 ? "" : "s"), " +
             "\(OTA.size(bytes)) in \(OTA.directory.path)")
        // Shown nowhere, pruned never, in no total: at least say it is there.
        if undecodable > 0 {
            note("\(undecodable) more with metadata this version can't read — a later one may; " +
                 "delete the folder to be rid of it")
        }
        let tailnetPort = AppCoordinator.otaPort
        let served = TailscaleClient.serving(port: tailnetPort)
        let host = AppCoordinator.currentHost()   // asked once; `serve` acts on this name alone
        let live = host.map { TailscaleClient.servingLive(port: tailnetPort, host: $0) } ?? false
        var unreadable = false
        switch served {
        case .unknown: mine = true; unreadable = true
        case .nothing: mine = true             // nothing of the user's to get in the way
        case .mounted:
            let here = host.flatMap { served.root(on: $0) }
            let beside = host.map { served.alongside($0) } ?? []
            // The same reading the app and `roamrun ota` use: no root under this
            // name is a free port, but anything else sharing it is not.
            mine = host != nil && beside.isEmpty && (here == nil || AppCoordinator.isOurs(here!, on: tailnetPort))
            stray = !mine && beside.isEmpty && AppCoordinator.abandoned(here)
        }
        check(live, live ? "The install page is published on port \(tailnetPort)"
                         : "The install page isn't published on port \(tailnetPort)",
              unreadable
                  ? "`tailscale serve status` didn't answer, so this can't be checked — is Tailscale running?"
                  : host == nil
                  ? "Tailscale didn't give this Mac a name — turn MagicDNS on for your tailnet."
                  : mine
                  ? "RoamRun publishes it while it runs — open RoamRun, then look in ⚙ Settings › Troubleshooting › Recent messages if it doesn't appear."
                  : stray
                  ? "port \(tailnetPort) carries an entry with nothing behind it, left by a run that was killed: tailscale serve --https=\(tailnetPort) --set-path=/ off"
                  : "port \(tailnetPort) is serving \(served.described), which isn't RoamRun's. Give RoamRun another port: defaults write \(AppID.bundle) otaPort -int 41444",
              !failsDoctor(.notPublished))
        if !live, TailscaleClient.httpsEnabled() == false {
            check(false, "This tailnet doesn't issue HTTPS certificates",
                  "`tailscale serve --https` writes nothing without them and still exits 0. Turn them on in the Tailscale admin console › DNS › HTTPS Certificates.",
                  !failsDoctor(.noHTTPSCertificates))
        }
        if let host, served.funnelled(on: host) {
            check(false, "Tailscale Funnel is on for port \(tailnetPort)",
                  "The install page is on the public internet. tailscale funnel --https=\(tailnetPort) off", !failsDoctor(.funnel))
        }
        // Not only while it is live: forgetting the address and asking `doctor`
        // for it is most likely exactly when RoamRun isn't open.
        if let host {
            note("Open on the device: https://\(host):\(tailnetPort)/")
        }
    }

    /// How to name a device in a command we suggest: a name starting with "-" would be taken
    /// for an option, so its id stands in (every command takes one).
    nonisolated static func commandName(_ p: DeviceProfile) -> String {
        p.displayName.hasPrefix("-") ? p.id.uuidString : shellName(p.displayName)
    }

    /// A name as it must be typed in a shell: 'iPhone mh', 'it'\''s'.
    nonisolated static func shellName(_ name: String) -> String {
        guard name.isEmpty || !name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else { return name }
        return "'" + name.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private static func shell(_ path: String, _ args: [String]) -> String? {
        let r = Proc.run(path, args)
        return r.status == 0 ? r.out : nil
    }

    /// Global skill directories of agents that follow the Agent Skills layout.
    nonisolated private static let skillClients: [(name: String, home: String)] = [
        ("claude", ".claude"), ("codex", ".codex"), ("cursor", ".cursor"),
        ("gemini", ".gemini"), ("copilot", ".copilot"),
    ]

    /// The skill shipped in this app, which matches this CLI.
    nonisolated static func bundledSkill() -> Data? {
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath()
        return exe.flatMap { try? Data(contentsOf: $0.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/roamrun-skill.md")) }
    }

    nonisolated static var homeDir: URL {
        // $HOME first, like other CLIs (homeDirectoryForCurrentUser ignores it).
        ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Skills `roamrun init` put there that differ from this version's (links belong to other tools).
    nonisolated static func staleSkills(home: URL, bundled: Data) -> [String] {
        let fm = FileManager.default
        return skillClients.compactMap { c in
            let dir = home.appendingPathComponent("\(c.home)/skills/roamrun")
            let file = dir.appendingPathComponent("SKILL.md")
            guard ![dir, file].contains(where: { (try? fm.destinationOfSymbolicLink(atPath: $0.path)) != nil }),
                  let data = try? Data(contentsOf: file), data.starts(with: Data("---\nname: roamrun\n".utf8)),
                  data != bundled else { return nil }
            return dir.path
        }
    }

    /// One line on stderr (JSON output stays clean) when an installed skill is from another version.
    private static func noteStaleSkills() {
        guard let bundled = bundledSkill() else { return }
        let stale = staleSkills(home: homeDir, bundled: bundled)
        guard !stale.isEmpty else { return }
        let home = homeDir.path
        let shown = stale.map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 }.joined(separator: ", ")
        FileHandle.standardError.write(Data("roamrun: the agent skill in \(shown) is from another RoamRun version — run `roamrun init` to update it\n".utf8))
    }

    /// Installs the bundled SKILL.md for every detected (or named) agent.
    private static func initSkill(_ args: [String]) -> Never {
        // A typo (e.g. --uninstal) must not fall through to installing everywhere.
        for (i, a) in args.enumerated().dropFirst() where args[i - 1] != "--client" {
            // Also bare words: `init claude` must not install into every client.
            guard ["--client", "--print", "--uninstall"].contains(a) else {
                fail(a.hasPrefix("-") ? "unknown option \(a) — see roamrun --help" : "unexpected \(shellName(a)) — to pick a client: roamrun init --client \(shellName(a))")
            }
        }
        if let i = args.lastIndex(of: "--client"), !args.indices.contains(i + 1) || args[i + 1].hasPrefix("-") {
            fail("--client needs a value (\(skillClients.map(\.name).joined(separator: ", ")))")
        }
        guard let skill = bundledSkill() else {
            stop("skill not found in the app bundle — build with `make app`")
        }
        if args.contains("--print") { FileHandle.standardOutput.write(skill); exit(0) }

        let home = homeDir
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
                do { try fm.removeItem(at: file) } catch { print("Couldn't remove \(file.path): \(error.localizedDescription)"); continue }
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

    private static let noDevices = "No devices saved yet — add one in the RoamRun app."

    /// By name (any case), else by an id prefix of 8+ characters (shorter is more likely a typo).
    nonisolated static func matches(_ name: String, in profiles: [DeviceProfile]) -> [DeviceProfile] {
        let byName = profiles.filter { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }
        guard byName.isEmpty, name.count >= 8 else { return byName }
        return profiles.filter { $0.id.uuidString.lowercased().hasPrefix(name.lowercased()) }
    }

    private static func find(_ name: String, in profiles: [DeviceProfile]) -> DeviceProfile? {
        let matches = matches(name, in: profiles)
        if matches.count > 1 {
            fail("“\(name)” matches more than one device — rename one in the app, or use its id: "
                 + matches.map { "\($0.id.uuidString.prefix(8))" }.joined(separator: ", "))
        }
        return matches.first
    }

    private static func names(_ profiles: [DeviceProfile]) -> String {
        profiles.isEmpty ? noDevices
            : "Saved: " + profiles.map { commandName($0) }.joined(separator: ", ")
    }

    private static func owner(_ e: StatusFile.Entry) -> String {
        e.pid == getpid() ? "this process" : e.cli == true ? "roamrun CLI, pid \(e.pid)" : "RoamRun app"
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("roamrun: \(message)\n".utf8))
        exit(2)
    }
}
