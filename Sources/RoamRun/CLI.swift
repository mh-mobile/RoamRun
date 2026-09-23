import Foundation

/// `roamrun devices | up <name> | status [name]` — the same bridge as the menu
/// bar app, headless, for SSH sessions and scripts.
@MainActor
enum CLI {
    /// This process was started as the CLI (vs. the menu bar app).
    nonisolated static var isRunning: Bool { commands.contains(CommandLine.arguments.dropFirst().first ?? "") }
    nonisolated static let commands: Set<String> = ["devices", "up", "down", "status", "doctor", "help", "--help", "-h"]
    /// Posted by `roamrun down`; the app stops the bridge whose id is `object`.
    static let stopNotification = Notification.Name("com.roamrun.app.stopBridge")

    private static let usage = """
    Usage: roamrun <command>

      devices              List saved iPhones and their bridge status
      up <name> [-v] [-d]  Bridge an iPhone until Ctrl-C (-v: activity log, -d: run in the background)
      down <name>          Stop a bridge, whether the app or another `roamrun up` runs it
      status [name]        Show bridge status; exits 0 only if the iPhone is ready for Xcode
      doctor [name]        Check each step from this Mac to the iPhone and say what to fix

    Add iPhones in the RoamRun app first (one-time, needs the iPhone on this Wi-Fi).
    """

    // Kept alive for the lifetime of `up`.
    private static var bridge: ProxyBridge?
    private static var keepAlive: [AnyObject] = []

    nonisolated static func run(_ args: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        MainActor.assumeIsolated {
            let profiles = ProfileStore().load()
            switch args[0] {
            case "devices": devices(profiles)
            case "status": status(profiles, name: args.dropFirst().first)
            case "doctor":
                var targets = profiles
                if let name = args.dropFirst().first {
                    guard let p = find(name, in: profiles) else { fail("no iPhone named “\(name)”. " + names(profiles)) }
                    targets = [p]
                }
                Task { exit(await doctor(targets) ? 0 : 1) }
            case "down":
                guard let name = args.dropFirst().first, let p = find(name, in: profiles) else {
                    fail("which iPhone? " + names(profiles))
                }
                down(p)
            case "up":
                guard let name = args.dropFirst().first(where: { !$0.hasPrefix("-") }),
                      let p = find(name, in: profiles) else { fail("which iPhone? " + names(profiles)) }
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

    private static func devices(_ profiles: [DeviceProfile]) -> Never {
        guard !profiles.isEmpty else { fail("no iPhones saved yet — add one in the RoamRun app") }
        let live = StatusFile.read()
        let w = max(4, profiles.map(\.displayName.count).max() ?? 4)
        print("NAME".padding(toLength: w + 2, withPad: " ", startingAt: 0) + "VPN ADDRESS      STATUS")
        for p in profiles {
            let status = live[p.id].map { "\($0.status) (\(owner($0)))" } ?? "Off"
            print(p.displayName.padding(toLength: w + 2, withPad: " ", startingAt: 0)
                  + p.providerIP.padding(toLength: 17, withPad: " ", startingAt: 0) + status)
        }
        exit(0)
    }

    private static func status(_ profiles: [DeviceProfile], name: String?) -> Never {
        var targets = profiles
        if let name {
            guard let p = find(name, in: profiles) else { fail("no iPhone named “\(name)”. " + names(profiles)) }
            targets = [p]
        }
        let live = StatusFile.read()
        var anyReady = false
        for p in targets {
            guard let e = live[p.id] else { print("\(p.displayName): Off"); continue }
            anyReady = anyReady || e.ready
            var line = "\(p.displayName): \(e.status) — \(owner(e))"
            if let lo = e.tunnelPorts.min(), let hi = e.tunnelPorts.max() { line += ", tunnel ports \(lo)–\(hi)" }
            print(line)
            if !e.detail.isEmpty { print("  \(e.detail)") }
        }
        exit(anyReady ? 0 : 1)
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
            if e.ready { break }
        }
        print("""
        \(profile.displayName) is bridged in the background (pid \(child.processIdentifier)).
          Log:  \(logURL.path)
          Stop: roamrun down \(profile.displayName)
        """)
        exit(last == BridgeStatus.ready.title ? 0 : 1)
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
                guard line != last else { return }
                last = line
                print("[\(Date.now.formatted(date: .omitted, time: .standard))] \(line)")
            }
        }
        // Same recovery as the app: retry errors, rebind when the Mac's IP changes.
        let retry = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                if case .error = bridge.state, bridge.autoRetry { Task { await bridge.start() } }
            }
        }
        let monitor = InterfaceMonitor()
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
    private static func doctor(_ profiles: [DeviceProfile]) async -> Bool {
        var healthy = true
        func check(_ ok: Bool, _ line: String, fix: String = "", warnOnly: Bool = false) {
            print(" \(ok ? "✓" : warnOnly ? "!" : "✗") \(line)")
            if !ok, !fix.isEmpty { print("     → \(fix)") }
            if !ok && !warnOnly { healthy = false }
        }

        print("This Mac")
        check(FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") && shell("/usr/bin/xcrun", ["--find", "devicectl"]) != nil,
              "Xcode's devicectl is available", fix: "Install Xcode and run it once (xcode-select -s /Applications/Xcode.app).")
        let ip = InterfaceMonitor.currentIPv4()
        check(ip != nil, "Wi-Fi address (en0): \(ip ?? "none")",
              fix: "Connect this Mac to Wi-Fi — the bridge listens on en0 because Xcode only looks there.")
        let orphans = DNSServiceProxy.orphanedHelperCount()
        check(orphans == 0, orphans == 0 ? "No leftover helper processes" : "\(orphans) leftover helper process(es) from a crash",
              fix: "Open RoamRun (it cleans them up at launch) or Settings › Clean Up Leftover Helpers.", warnOnly: true)

        let appDefaults = UserDefaults(suiteName: "com.roamrun.app")
        let cli = TailscaleClient(binaryPath: appDefaults?.string(forKey: "tailscaleCLIPath").flatMap { $0.isEmpty ? nil : $0 })
        let peers: [MeshDevice]
        do { peers = try cli.listDevices() } catch {
            check(false, "Tailscale: \(error.localizedDescription)", fix: "Install Tailscale and sign in, or set its CLI path in RoamRun › Settings.")
            return false
        }
        check(true, "Tailscale is running (\(peers.count) peers)")

        if profiles.isEmpty { check(false, "No iPhones saved", fix: "Add one in the RoamRun app.") }
        let live = StatusFile.read()
        for p in profiles {
            print("\n\(p.displayName) (\(p.providerIP))")
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
            check(open, "RemotePairing port \(p.remotePairingPort) is \(open ? "reachable" : "not reachable")",
                  fix: "Keep the iPhone on a Wi-Fi network (tethering is fine, cellular alone is not) and unlocked. If it restarted, run Find RemotePairing Port in the app.")
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
                check(e.ready, "Bridge: \(e.status) (\(owner(e)))", fix: e.detail.isEmpty ? "Wait a few seconds and run doctor again." : e.detail)
            } else {
                check(false, "Bridge is off", fix: "roamrun up \(p.displayName) -d  (or Start Bridge in the app)")
            }
        }
        print(healthy ? "\nAll good." : "\nFix the ✗ items above, top to bottom.")
        return healthy
    }

    private static func shell(_ path: String, _ args: [String]) -> String? {
        let r = Proc.run(path, args)
        return r.status == 0 ? r.out : nil
    }

    // MARK: - Helpers

    private static func find(_ name: String, in profiles: [DeviceProfile]) -> DeviceProfile? {
        profiles.first { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }
            ?? profiles.first { $0.id.uuidString.lowercased().hasPrefix(name.lowercased()) }
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
