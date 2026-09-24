import Foundation

/// `roamrun devices | up <name> | status [name]` — the same bridge as the menu
/// bar app, headless, for SSH sessions and scripts.
@MainActor
enum CLI {
    /// This process was started as the CLI (vs. the menu bar app).
    nonisolated static var isRunning: Bool { commands.contains(CommandLine.arguments.dropFirst().first ?? "") }
    nonisolated static let commands: Set<String> = ["devices", "up", "down", "status", "doctor", "init", "help", "--help", "-h"]
    /// Posted by `roamrun down`; the app stops the bridge whose id is `object`.
    static let stopNotification = Notification.Name("com.roamrun.app.stopBridge")

    private static let usage = """
    Usage: roamrun <command>

    AI agents: `roamrun init` installs the RoamRun skill for Claude Code, Codex,
    Cursor, Gemini CLI and Copilot (`roamrun init --print` to read it now).

      devices [--json]               List saved iPhones (with UDID) and their bridge status
      up <name> [-v] [-d]            Bridge an iPhone until Ctrl-C (-v: activity log, -d: run in the background)
      down <name>                    Stop a bridge, whether the app or another `roamrun up` runs it
      status [name] [--wait N] [--json]
                                     Bridge status, UDID and lock state; exits 0 only if ready for Xcode
                                     (--wait: wait up to N seconds for ready)
      doctor [name] [--json]         Check each step from this Mac to the iPhone and say what to fix
      init [--client <name>] [--print] [--uninstall]
                                     Install the agent skill (clients: claude, codex, cursor, gemini, copilot)

    Exit codes: 0 ok/ready, 1 not ready or a check failed, 2 usage error.

    Add iPhones in the RoamRun app first (one-time, needs the iPhone on this Wi-Fi).
    """

    // Kept alive for the lifetime of `up`.
    private static var bridge: ProxyBridge?
    private static var keepAlive: [AnyObject] = []

    nonisolated static func run(_ args: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        MainActor.assumeIsolated {
            if args[0] == "init" { initSkill(args) }   // takes no iPhone name
            let profiles = ProfileStore().load()
            let json = args.contains("--json")
            let waitIdx = args.firstIndex(of: "--wait")
            let wait = waitIdx.flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil }
            if waitIdx != nil && wait == nil { fail("--wait needs a number of seconds") }
            // First argument after the command that isn't a flag or --wait's value.
            let name = args.indices.dropFirst().first { i in
                !args[i].hasPrefix("-") && i != waitIdx.map { $0 + 1 }
            }.map { args[$0] }
            var targets = profiles
            if let name {
                guard let p = find(name, in: profiles) else { fail("no iPhone named “\(name)”. " + names(profiles)) }
                targets = [p]
            }
            switch args[0] {
            case "devices": devices(profiles, json: json)
            case "status": status(targets, json: json, wait: wait)
            case "doctor": Task { exit(await doctor(targets, json: json) ? 0 : 1) }
            case "down":
                guard name != nil, let p = targets.first else { fail("which iPhone? " + names(profiles)) }
                down(p)
            case "up":
                guard name != nil, let p = targets.first else { fail("which iPhone? " + names(profiles)) }
                if args.contains("-d") {
                    detach(p, verbose: args.contains("-v"))
                } else {
                    up(p, verbose: args.contains("-v"), detachedChild: args.contains(detachedFlag))
                }
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
            detail = "The bridge is up but Xcode can't reach the iPhone (asleep, locked, off Wi-Fi, or Tailscale stuck on the iPhone). Run `roamrun doctor` for the cause."
        }
        return Row(name: p.displayName, id: p.id.uuidString, vpnAddress: p.providerIP, udid: udid,
                   status: status, ready: ready,
                   owner: e.map(owner), pid: e?.pid, tunnelPorts: e?.tunnelPorts ?? [],
                   coreDevice: core, detail: detail,
                   locked: ready ? udid.flatMap(isLocked) : nil)
    }

    /// devicectl's tunnelState for this UDID; nil if devicectl failed.
    private static func coreDeviceState(_ udid: String) -> String? {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-list-\(getpid()).json")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = Proc.run("/usr/bin/xcrun", ["devicectl", "--quiet", "--timeout", "10", "list", "devices", "--json-output", out.path])
        guard let data = try? Data(contentsOf: out),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = (root["result"] as? [String: Any])?["devices"] as? [[String: Any]],
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
        guard !profiles.isEmpty else { fail("no iPhones saved yet — add one in the RoamRun app") }
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
                if r.locked == true { print("  ⚠ The iPhone is locked — ask the user to unlock it and keep the screen on before installing or launching.") }
            }
        }
        exit(rows.contains { $0.ready } ? 0 : 1)
    }

    /// Needs the tunnel; nil when devicectl can't reach the device.
    private static func isLocked(_ udid: String) -> Bool? {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-lock-\(getpid()).json")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = Proc.run("/usr/bin/xcrun", ["devicectl", "--quiet", "--timeout", "10", "device", "info", "lockState",
                                        "--device", udid, "--json-output", out.path])
        guard let data = try? Data(contentsOf: out),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any] else { return nil }
        return result["passcodeRequired"] as? Bool
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
        if e.cli == true { kill(e.pid, SIGTERM) }   // its handler tears down dns-sd / log children
        // Wait for the owner to clear its status entry.
        var tries = 0
        while StatusFile.read()[profile.id] != nil && tries < 50 { usleep(100_000); tries += 1 }
        guard StatusFile.read()[profile.id] == nil else { fail("\(who) did not stop the bridge") }
        print("Stopped \(profile.displayName) (\(who)).")
        exit(0)
    }

    /// Internal: marks the background copy spawned by `up -d`.
    private static let detachedFlag = "--detached-child"

    /// `up -d`: re-launch ourselves in a new session with output going to a
    /// log file, wait until the bridge settles, then hand the prompt back.
    private static func detach(_ profile: DeviceProfile, verbose: Bool) -> Never {
        if StatusFile.otherOwner(of: profile.id) != nil, let e = StatusFile.read()[profile.id] {
            fail("\(profile.displayName) is already bridged by \(owner(e)). Stop it there first.")
        }
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/RoamRun", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        // The display name is user/network supplied: keep it to one safe path component.
        let safeName = String(profile.displayName.map { $0.isLetter || $0.isNumber || "-_ ".contains($0) ? $0 : "_" })
        let logURL = logDir.appendingPathComponent("\(safeName.isEmpty ? profile.id.uuidString : safeName).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let log = try? FileHandle(forWritingTo: logURL) else { fail("can't write \(logURL.path)") }

        let child = Process()
        child.executableURL = Bundle.main.executableURL?.resolvingSymlinksInPath()
        child.arguments = ["up", profile.id.uuidString, detachedFlag] + (verbose ? ["-v"] : [])
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = log
        child.standardError = log
        do { try child.run() } catch { fail("could not start the background bridge: \(error.localizedDescription)") }

        // Wait (≤60s) for Ready; a slower start keeps going in the background.
        var last = ""
        for _ in 0..<120 {
            usleep(500_000)
            guard child.isRunning else { fail("the background bridge exited — see \(logURL.path)") }
            guard let e = StatusFile.read()[profile.id], e.pid == child.processIdentifier else { continue }
            if e.status != last { last = e.status; print("  \(e.status)") }
            if e.ready || e.status == BridgeStatus.local.title { break }
        }
        print("""
        \(profile.displayName) is bridged in the background (pid \(child.processIdentifier)).
          Log:  \(logURL.path)
          Stop: roamrun down \(profile.displayName)
        """)
        exit(last == BridgeStatus.ready.title || last == BridgeStatus.local.title ? 0 : 1)
    }

    private static func up(_ profile: DeviceProfile, verbose: Bool, detachedChild: Bool = false) {
        if StatusFile.otherOwner(of: profile.id) != nil, let e = StatusFile.read()[profile.id] {
            fail("\(profile.displayName) is already bridged by \(owner(e)). Stop it there first.")
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
                if bridge.state == .local { Task { await bridge.resumeIfAway() } }
                else if bridge.status == .error && bridge.autoRetry { Task { await bridge.start() } }
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
        keepAlive = [ticker, retry, monitor] + sources

        print("Bridging \(profile.displayName) over \(profile.providerIP)…")
        Task { await bridge.start() }
    }

    /// Walks the path Xcode → this Mac → Tailscale → iPhone and reports the
    /// first thing to fix at each hop.
    private struct Check: Encodable {
        let scope: String          // "mac" or the iPhone's name
        let result: String         // "ok", "warning" or "fail"
        let message: String
        let fix: String?
    }

    private static func doctor(_ profiles: [DeviceProfile], json: Bool) async -> Bool {
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
                print(healthy ? "\n" + paint("All good.", 32) : "\nFix the \(paint("✗", 31)) items above, top to bottom.")
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

        let cli = TailscaleClient.fromSettings()
        let peers: [MeshDevice]
        do { peers = try cli.listDevices() } catch {
            check(false, "Tailscale: \(error.localizedDescription)", fix: "Install Tailscale and sign in, or set its CLI path in RoamRun › Settings.")
            return finish()
        }
        check(true, "Tailscale is running (\(peers.count) peers)")

        if profiles.isEmpty { check(false, "No iPhones saved", fix: "Add one in the RoamRun app.") }
        let live = StatusFile.read()
        for p in profiles {
            section("\n\(p.displayName) (\(p.providerIP))", p.displayName)
            guard let peer = peers.first(where: { $0.ips.contains(p.providerIP) }) else {
                check(false, "Not found on this tailnet", fix: "Sign the iPhone into the same tailnet, or remove and re-add it in RoamRun.")
                continue
            }
            check(peer.online, "Tailscale peer “\(peer.name)” is \(peer.online ? "online" : "offline")",
                  fix: "Unlock the iPhone and keep its screen on — while it sleeps, iOS pauses the Tailscale VPN too.")
            if peer.online {
                check(!peer.curAddr.isEmpty, "Path: \(peer.pathDescription)",
                      fix: "Direct paths are much faster. Some networks (hotel, carrier NAT) force DERP.", warnOnly: true)
            }
            let open = await ReachabilityProbe.checkTCP(host: p.providerIP, port: p.remotePairingPort, timeout: 4)
            if open {
                check(true, "RemotePairing port \(p.remotePairingPort) is reachable")
            } else if cli.ping(p.providerIP) {
                // Tailscale answers but the iPhone's service doesn't: the iOS
                // Tailscale data plane is stuck, or the iPhone left Wi-Fi.
                check(false, "Tailscale reaches the iPhone, but RemotePairing port \(p.remotePairingPort) does not answer",
                      fix: "Ask the user to (1) toggle the VPN off and on in the iPhone's Tailscale app — iOS Tailscale can show \"MagicSock function ReceiveIPv4 is not running\" and stop passing data while still looking connected; (2) check the iPhone is on Wi-Fi (cellular alone is not enough). If it restarted, run Find RemotePairing Port in the app.")
            } else {
                check(false, "The iPhone does not answer over Tailscale",
                      fix: "Ask the user to unlock the iPhone, keep the screen on and make sure Tailscale is on. If the Tailscale app shows a \"MagicSock … not running\" warning, toggle its VPN off and on.")
            }
            if open {
                let speaks = await ReachabilityProbe.speaksRemotePairing(host: p.providerIP, port: p.remotePairingPort)
                check(speaks, "iPhone \(speaks ? "answers" : "does not answer") the RemotePairing handshake",
                      fix: "Another service holds this port. Run Find RemotePairing Port in the app.")
            }
            // How remotepairingd last resolved our record: to a paired UDID, or nil.
            // instanceName comes from the network; only interpolate a plain UUID into the predicate.
            if p.instanceName.allSatisfy({ $0.isHexDigit || $0 == "-" }),
               let out = shell("/usr/bin/log", ["show", "--last", "15m", "--style", "compact", "--predicate",
                    "process == \"remotepairingd\" AND eventMessage CONTAINS \"Resolved bonjour advert \(p.instanceName) to identity\""]),
               let last = out.split(separator: "\n").last(where: { $0.contains("to identity") }) {
                let known = last.contains("associated with udid")
                check(known, known ? "This Mac recognizes the iPhone's pairing" : "This Mac does not recognize the iPhone's pairing (identity nil)",
                      fix: "Put the iPhone on this Mac's Wi-Fi, remove it in RoamRun and add it again. If Xcode lost it too, pair it in Xcode first.")
            }
            if let e = live[p.id] {
                check(e.ready || e.status == BridgeStatus.local.title, "Mac-side bridge: \(e.status) (\(owner(e)))", fix: e.detail.isEmpty ? "Wait a few seconds and run doctor again." : e.detail)
                if let udid = e.udid ?? p.udid {
                    check(true, "UDID: \(udid)")
                    let core = coreDeviceState(udid)
                    check(core != nil && core != "unavailable", "Xcode (CoreDevice) sees the iPhone as \(core ?? "unknown")",
                          fix: "Ask the user to unlock the iPhone and keep the screen on; then run doctor again.")
                    if e.ready, let locked = isLocked(udid) {
                        check(!locked, locked ? "iPhone is locked" : "iPhone is unlocked",
                              fix: "Ask the user to unlock the iPhone and keep the screen on — installs and launches fail while it is locked.")
                    }
                }
            } else {
                check(false, "Bridge is off", fix: "roamrun up \(p.displayName) -d  (or Start Bridge in the app)")
            }
        }
        return finish()
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
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath()
        let bundled = exe?.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/roamrun-skill.md")
        guard let bundled, let skill = try? Data(contentsOf: bundled) else {
            fail("skill not found in the app bundle — build with `make app`")
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
            fail("no supported agent found in ~ (.claude, .codex, .cursor, .gemini, .copilot). Use --client, or --print and paste it yourself.")
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
                fail("could not write \(dir.path): \(error.localizedDescription)")
            }
        }
        exit(0)
    }

    // MARK: - Helpers

    private static func find(_ name: String, in profiles: [DeviceProfile]) -> DeviceProfile? {
        let byName = profiles.filter { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }
        let matches = byName.isEmpty ? profiles.filter { $0.id.uuidString.lowercased().hasPrefix(name.lowercased()) } : byName
        if matches.count > 1 {
            fail("“\(name)” matches more than one iPhone — rename one in the app, or use its id: "
                 + matches.map { "\($0.id.uuidString.prefix(8))" }.joined(separator: ", "))
        }
        return matches.first
    }

    private static func names(_ profiles: [DeviceProfile]) -> String {
        profiles.isEmpty ? "No iPhones saved yet — add one in the RoamRun app."
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
