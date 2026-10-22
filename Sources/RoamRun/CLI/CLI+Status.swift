import Foundation

extension CLI {
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
        /// Device control, in `status` and `devices`: connected, notConnected, refused (pair again), switchedOff,
        /// another (not the paired device answers), noApp, keptOut; null where it isn't set up.
        var deviceControl: String?

        private enum CodingKeys: String, CodingKey {
            case name, state, id, vpnAddress, udid, status, ready, owner, pid, tunnelPorts, network, coreDevice, detail,
                 locked, deviceControl
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
            try c.encode(deviceControl, forKey: .deviceControl)
        }
    }

    /// With `deep`, `ready` means Xcode can use the device right now: the bridge is up
    /// *and* CoreDevice sees the iPhone. The bridge alone can look ready for a while
    /// after the iPhone falls asleep (its relayed connections linger). Without it
    /// (`devices --json`), `ready` is only the bridge's word, or "on this Wi‑Fi".
    private static func row(_ p: DeviceProfile, _ e: StatusFile.Entry?, deep: Bool, by deadline: Date? = nil,
                            coreState: ((String) -> String?)? = nil) -> Row
    {
        let udid = e?.udid ?? p.udid
        let usable = e?.ready == true || e?.kind == .local // on this Wi-Fi: Xcode sees it directly
        let core = deep && usable ? udid.flatMap { u in
            coreState.map {
                $0(u)
            } ?? coreDeviceState(u, by: deadline)
        } : nil
        let r = readiness(e, udid: udid, core: core, deep: deep)
        return Row(
            name: p.displayName,
            state: r.kind.rawValue,
            id: p.id.uuidString,
            vpnAddress: p.providerIP,
            udid: udid,
            status: r.status,
            ready: r.ready,
            owner: e.map(owner),
            pid: e?.pid,
            tunnelPorts: e?.tunnelPorts ?? [],
            network: r.ready || e?.kind == .waiting ? e?.network : nil,
            coreDevice: core,
            detail: r.detail,
            locked: deep && r.ready ? udid.flatMap {
                isLocked($0, by: deadline)
            } : nil
        )
    }

    /// Whether Xcode can use the device now, and what `status` shows for it.
    /// `core` is CoreDevice's tunnelState (nil: not asked, or devicectl failed).
    nonisolated static func readiness(_ e: StatusFile.Entry?, udid: String?, core: String?, deep: Bool)
        -> (ready: Bool, kind: BridgeStatus, status: String, detail: String?)
    {
        let usable = e?.ready == true || e?.kind == .local // on this Wi-Fi: Xcode sees it directly
        // No UDID yet (standing aside before it ever connected): nothing to ask CoreDevice, trust the bridge.
        let ready = usable && (!deep || udid == nil || core.map {
            $0 != "unavailable"
        } ?? false)
        var status = e?.status ?? BridgeStatus.off.title
        var kind = e?.kind ?? .off
        var detail = e.flatMap {
            $0.detail.isEmpty ? nil : $0.detail
        }
        if e?.ready == true && !ready {
            status = BridgeStatus.waiting.title
            kind = .waiting
            detail = "The bridge is up but Xcode can't reach the device (asleep, locked, off Wi-Fi, or Tailscale stuck on the device). Run `roamrun doctor` for the cause."
            // Exactly the state a blocked local network produces, so don't lose the reason.
            if e?.detail.contains(LocalNetwork.advice) == true {
                detail! += " — " + LocalNetwork.advice
            }
        } else if e?.kind == .local && !ready {
            // Still on this Wi‑Fi (so `state` stays local), but not usable right now.
            detail = "On this Wi‑Fi, but Xcode can't reach the device right now (asleep or locked, or CoreDevice didn't answer). Ask the user to unlock it and keep the screen on, then check again."
        }
        return (ready, kind, status, detail)
    }

    /// devicectl's tunnelState for this UDID; nil if devicectl failed.
    nonisolated static func coreDeviceState(_ udid: String, by deadline: Date? = nil) -> String? {
        devicectl(["list", "devices"], by: deadline).flatMap {
            tunnelState(in: $0, udid: udid)
        }
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

    /// Device Hub's line for a pairing it tried, as `log stream` is asked for it.
    /// Written by CoreDevice's own framework, where Xcode installs it (not a user's to write): by name alone any process could.
    nonisolated static let pairingLog = #"subsystem == "com.apple.dt.coredevice" AND category == "pairing" AND senderImagePath BEGINSWITH "/Library/Developer/PrivateFrameworks/CoreDevice.framework/" AND eventMessage BEGINSWITH "Pairing attempt completed with error ""#
    /// From that line: true when the pairing was made, false when it wasn't; nil for any other line.
    nonisolated static func pairingEnded(_ message: String) -> Bool? {
        guard message.hasPrefix("Pairing attempt completed with error ") else { return nil }
        return message == "Pairing attempt completed with error nil"
    }

    /// From `devicectl list devices` JSON's result; UDIDs compared in any case.
    nonisolated static func tunnelState(in result: [String: Any], udid: String) -> String? {
        let device = (result["devices"] as? [[String: Any]])?.first {
            (($0["hardwareProperties"] as? [String: Any])?["udid"] as? String)?
                .caseInsensitiveCompare(udid) == .orderedSame
        }
        return (device?["connectionProperties"] as? [String: Any])?["tunnelState"] as? String
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: (try? enc.encode(value)) ?? Data(), as: UTF8.self))
    }

    static func devices(_ profiles: [DeviceProfile], json: Bool) -> Never {
        let live = StatusFile.read()
        if json {
            // Device control too, asked of the app as `status` does: the key is in every row, and null only where it isn't set up.
            printJSON(profiles.map { p -> Row in
                var r = row(p, live[p.id], deep: false)
                r.deviceControl = controlState(p.id, udid: r.udid).key
                return r
            })
            exit(0)
        }
        guard !profiles.isEmpty else { print(noDevices)
            exit(0)
        }
        let w = max(4, profiles.map(\.displayName.count).max() ?? 4)
        print("NAME".padding(toLength: w + 2, withPad: " ", startingAt: 0)
            + "VPN ADDRESS      UDID                       ID                                    STATUS")
        for p in profiles {
            let e = live[p.id]
            let status = e.map {
                "\($0.status) (\(owner($0)))"
            } ?? BridgeStatus.off.title
            print(p.displayName.padding(toLength: w + 2, withPad: " ", startingAt: 0)
                + p.providerIP.padding(toLength: 17, withPad: " ", startingAt: 0)
                + (e?.udid ?? p.udid ?? "-").padding(toLength: 27, withPad: " ", startingAt: 0)
                + p.id.uuidString.padding(toLength: 38, withPad: " ", startingAt: 0) + status)
        }
        exit(0)
    }

    static func status(_ targets: [DeviceProfile], json: Bool, wait: Double?) -> Never {
        if targets.isEmpty && !json {
            stop(noDevices)
        }
        var rows: [Row]
        let deadline = Date.now.addingTimeInterval(wait ?? 0)
        let budget = wait == nil ? nil : deadline // no --wait: the probes keep their own timeouts
        repeat {
            let live = StatusFile.read()
            // One `devicectl list devices` a round, not one per device, and none if no row needs it.
            var listed: [String: Any]??
            let coreState = { (udid: String) -> String? in
                if listed == nil {
                    listed = .some(devicectl(["list", "devices"], by: budget))
                }
                return listed!.flatMap {
                    tunnelState(in: $0, udid: udid)
                }
            }
            rows = targets.map {
                row($0, live[$0.id], deep: true, by: budget, coreState: coreState)
            }
            if rows.contains(where: \.ready) || Date.now >= deadline {
                break
            }
            usleep(useconds_t(min(3, max(0.1, deadline.timeIntervalSinceNow)) *
                    1_000_000)) // each round spawns devicectl
        } while true
        // Asked of the app once a device, for both ways of saying it.
        let controls = rows.map { r in
            UUID(uuidString: r.id).map {
                controlState($0, udid: r.udid)
            }
        }
        rows = zip(rows, controls).map { r, c in
            var r = r
            r.deviceControl = c?.key
            return r
        }
        // Not connected for this Mac's own Tailscale being down reads, from the app's side, like
        // the device being away: asked once, and said, where a device not connected goes over it.
        var mesh: String??
        let lines = Dictionary(zip(rows.map(\.id), controls.map { c -> String? in
            guard c == .notConnected else { return c?.line }
            if mesh == nil {
                let overTailscale = targets.contains {
                    $0.providerID == MeshProvider.tailscale.rawValue
                }
                mesh = .some(overTailscale ? Self.meshProblem {
                    try TailscaleClient.fromSettings().listDevices()
                } : nil)
            }
            return ControlState.notConnectedLine(mesh: mesh ?? nil)
        }), uniquingKeysWith: { a, _ in
            a
        })
        if json {
            printJSON(rows)
        } else {
            for r in rows {
                var line = "\(r.name): \(r.status)"
                if let n = r.network.flatMap(DeviceNetwork.init(rawValue:)) {
                    line += " · \(n.title)"
                }
                if let owner = r.owner {
                    line += " — \(owner)"
                }
                if let lo = r.tunnelPorts.min(), let hi = r.tunnelPorts.max() {
                    line += ", tunnel ports \(lo)–\(hi)"
                }
                print(line)
                if let udid = r.udid {
                    print("  UDID: \(udid)")
                }
                if let detail = r.detail {
                    print("  \(detail)")
                }
                if r
                    .locked ==
                    true
                {
                    print(
                        "  ⚠ The device is locked — ask the user to unlock it and keep the screen on before installing or launching."
                    )
                }
                if let line = lines[r.id] ?? nil {
                    print("  Device control: \(line)")
                }
            }
        }
        exit(rows.contains {
            $0.ready
        } ? 0 : 1)
    }

    /// Needs the tunnel; nil when devicectl can't reach the device.
    static func isLocked(_ udid: String, by deadline: Date? = nil) -> Bool? {
        devicectl(["device", "info", "lockState", "--device", udid], by: deadline)?["passcodeRequired"] as? Bool
    }

    /// Walks the path Xcode → this Mac → Tailscale → iPhone and reports the
    /// first thing to fix at each hop.
    struct Check: Encodable {
        let scope: String // "mac" or the device's name
        let result: String // "ok", "warning", "fail" or "skipped"
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
    static func doctor(_ profiles: [DeviceProfile], json: Bool, checkAll: Bool) async -> Bool {
        var checks: [Check] = []
        var scope = "mac"
        func section(_ title: String, _ name: String) {
            scope = name
            if !json {
                print(title)
            }
        }
        func check(_ ok: Bool, _ line: String, fix: String = "", warnOnly: Bool = false) {
            let result = ok ? "ok" : warnOnly ? "warning" : "fail"
            checks.append(Check(scope: scope, result: result, message: line, fix: ok || fix.isEmpty ? nil : fix))
            guard !json else { return }
            print(" \(paint(ok ? "✓" : warnOnly ? "!" : "✗", ok ? 32 : warnOnly ? 33 : 31)) \(line)")
            if !ok, !fix.isEmpty {
                print("     → \(fix)")
            }
        }
        /// Not a result: why a check didn't run.
        func note(_ line: String) {
            checks.append(Check(scope: scope, result: "skipped", message: line, fix: nil))
            if !json {
                print(" – \(line)")
            }
        }
        /// ANSI color on a terminal only (not when piped, or with NO_COLOR set).
        func paint(_ s: String, _ code: Int) -> String {
            isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo
                .environment["NO_COLOR"] == nil ? "\u{1B}[\(code);1m\(s)\u{1B}[0m" : s
        }
        func finish() -> Bool {
            let healthy = !checks.contains {
                $0.result == "fail"
            }
            if json {
                struct Report: Encodable { let healthy: Bool
                    let checks: [Check]
                }
                printJSON(Report(healthy: healthy, checks: checks))
            } else {
                print(healthy ? "\n" + paint("All good.", 32) :
                    "\nFix the first failed check (\(paint("✗", 31))) first — the ones below it are often caused by it.")
            }
            return healthy
        }

        section("This Mac", "mac")
        check(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") && shell(
                "/usr/bin/xcrun",
                ["--find", "devicectl"]
            ) != nil,
            "Xcode's devicectl is available",
            fix: "Install Xcode and run it once (sudo xcode-select -s /Applications/Xcode.app)."
        )
        let ip = InterfaceMonitor.currentIPv4()
        let lan = InterfaceMonitor.lanInterface
        check(ip != nil, "LAN address (\(lan)): \(ip ?? "none")",
              fix: "Connect \(lan) to the network — the bridge listens where Xcode looks for devices. To use another interface, pick it in RoamRun (Open RoamRun › ⚙ Settings › Network).")
        let orphans = DNSServiceProxy.orphanedHelperCount()
        check(
            orphans == 0,
            orphans == 0 ? "No leftover helper processes" : "\(orphans) leftover helper process(es) from a crash",
            fix: "Open RoamRun (it cleans them up at launch) or ⚙ Settings › Troubleshooting › Clean Up Leftover Helpers.",
            warnOnly: true
        )

        let live = StatusFile.read()
        let cli = TailscaleClient.fromSettings()
        let viaTailscale = { (p: DeviceProfile) in
            p.providerID == MeshProvider.tailscale.rawValue
        }
        var peers: [MeshDevice] = []
        do {
            peers = try cli.listDevices()
            check(true, "Tailscale is running (\(peers.count) peers)")
        } catch {
            // Devices entered by IP (another mesh VPN) don't need Tailscale.
            if profiles.contains(where: {
                viaTailscale($0) && (checkAll || live[$0.id] != nil)
            }) {
                check(
                    false,
                    "Tailscale: \(error.localizedDescription)",
                    fix: "Install Tailscale and sign in, or set its CLI path in RoamRun (Open RoamRun › ⚙ Settings)."
                )
                return finish()
            }
            note("Tailscale not checked (no device uses it)")
        }

        if profiles.isEmpty {
            check(false, "No devices saved", fix: "Add one in the RoamRun app.")
        }
        for p in profiles {
            section("\n\(p.displayName) (\(p.providerIP))", p.displayName)
            switch controlState(p.id, udid: p.udid ?? live[p.id]?.udid) {
            case .notSetUp: break
            case .connected: check(true, "Device control: connected")
            case .notConnected:
                check(false,
                      "Device control: paired, but not connected",
                      fix: "It connects while the device is on a Wi‑Fi, awake and reachable over the VPN — and then stays connected on cellular. Ask the user to unlock it on Wi‑Fi.",
                      warnOnly: true)
            case .refused:
                check(false,
                      "Device control: RoamRun's pairing can no longer be used",
                      fix: "It was removed on the device, was made by a build that didn't keep the device's key with it, or this Mac can't read what it saved (its key is gone from the Keychain, or was refused). Ask the user to pair again: the RoamRun app, the device's page, Device control › Pair Again… (same Wi‑Fi, iOS 27 or later).",
                      warnOnly: true)
            case .another:
                check(
                    false,
                    "Device control: what answers at the device's address isn't the device RoamRun paired with",
                    fix: "It is told nothing of this Mac's and sent no input. If the device was erased or replaced, ask the user to pair again (the RoamRun app, the device's page); if not, something else on the network has the device's address — check the address saved for it."
                )
            case .listUnreadable:
                check(false,
                      "Device control: the Keychain didn't give RoamRun its list of devices switched on",
                      fix: "Nothing is switched on until it does. Ask the user to open the device's page in the RoamRun app: it says what to do (a question from macOS about that item is not to be allowed).",
                      warnOnly: true)
            case .switchedOff:
                check(false,
                      "Device control: switched off for this device",
                      fix: "Commands and agents are refused while its switch is off. Ask the user to switch it on: the RoamRun app, the device's page, Device control.",
                      warnOnly: true)
            case .noApp:
                check(false, "Device control: the RoamRun app isn't running (or is a build without it)",
                      fix: "Open RoamRun: it holds the connection that look, tap and the rest use.", warnOnly: true)
            case .keptOut:
                check(false,
                      "Device control: this process isn't allowed to reach the RoamRun app",
                      fix: "A sandbox around it keeps it from the app's socket (the app may well be running). Run roamrun outside the sandbox, or use the MCP tools (`roamrun mcp`).",
                      warnOnly: true)
            }
            if !checkAll, live[p.id] == nil {
                note("Bridge is off — not checked (roamrun doctor \(commandName(p)) checks it anyway)")
                continue
            }
            // On this Wi‑Fi Xcode reaches the device directly: the VPN path doesn't matter.
            if live[p.id]?.kind == .local {
                note("On this Wi\u{2011}Fi — VPN checks skipped (Xcode reaches the device directly)")
            } else {
                if viaTailscale(p) {
                    guard let peer = peers.first(where: {
                        $0.ips.contains(p.providerIP)
                    }) else {
                        check(
                            false,
                            "Not found on this tailnet",
                            fix: "Sign the device into the same tailnet, or remove and re-add it in RoamRun."
                        )
                        continue
                    }
                    check(peer.online, "Tailscale peer “\(peer.name)” is \(peer.online ? "online" : "offline")",
                          fix: "Unlock the device and keep its screen on — while it sleeps, iOS pauses the Tailscale VPN too.")
                    // On this Wi-Fi Xcode reaches the device directly; the Tailscale path doesn't matter.
                    if peer.online, live[p.id]?.kind != .local {
                        check(!peer.curAddr.isEmpty, "Path: \(peer.pathDescription)",
                              fix: "Direct paths are much faster. Some networks (hotel, carrier NAT) force DERP.",
                              warnOnly: true)
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
                    check(
                        false,
                        "Tailscale reaches the device, but RemotePairing port \(p.remotePairingPort) does not answer",
                        fix: "Ask the user to (1) toggle the VPN off and on in the device's Tailscale app — iOS Tailscale can show \"MagicSock function ReceiveIPv4 is not running\" and stop passing data while still looking connected; (2) check the device is on Wi-Fi (cellular alone is not enough). If it restarted, run Find RemotePairing Port in the app."
                    )
                } else {
                    check(false, "The device does not answer over \(viaTailscale(p) ? "Tailscale" : "the VPN")",
                          fix: "Ask the user to unlock the device, keep the screen on and make sure Tailscale is on. If the Tailscale app shows a \"MagicSock … not running\" warning, toggle its VPN off and on.")
                }
                if open {
                    let speaks = await ReachabilityProbe.speaksRemotePairing(
                        host: p.providerIP,
                        port: p.remotePairingPort
                    )
                    check(speaks, "Device \(speaks ? "answers" : "does not answer") the RemotePairing handshake",
                          fix: "Another service holds this port. Run Find RemotePairing Port in the app.")
                }
            }
            // How remotepairingd last resolved our record (nil = pairing lost), or any
            // advert matched to this UDID. Only plain hex/UUIDs go into the predicates.
            let plain = { (s: String) in
                !s.isEmpty && s.allSatisfy {
                    $0.isHexDigit || $0 == "-"
                }
            }
            let udid = live[p.id]?.udid ?? p.udid
            // Through the hardened parser: instance names in these lines come from the LAN.
            let adverts = { (phrase: String) in
                TunnelPortWatcher.recentAdverts(last: "15m", containing: phrase)
            }
            let ours = plain(p.instanceName) ? adverts("Resolved bonjour advert \(p.instanceName) to identity").last {
                $0.0 == p.instanceName
            } : nil
            if let ours, ours.1 == nil {
                check(false, "This Mac does not recognize the device's pairing (identity nil)",
                      fix: "Put the device on this Mac's Wi-Fi, remove it in RoamRun and add it again; a Mac never on its Wi-Fi takes it again from one that is (`roamrun devices export <name>` there, `roamrun devices add <line> --replace <name>` here). If Xcode lost it too, pair it in Xcode first (from afar: `roamrun pair xcode`, and have this Mac introduced again).")
            } else if ours != nil || (udid.map(plain) == true && adverts("associated with udid \(udid ?? "")")
                .contains {
                    $0.1?.caseInsensitiveCompare(udid ?? "") == .orderedSame
                })
            {
                check(true, "This Mac recognizes the device's pairing")
            } else {
                note("Pairing not checked — no advert of this device was matched in the last 15 minutes")
            }
            if let e = live[p.id] {
                let own = LocalNetwork.withoutAdvice(e.detail) // it gets its own line below
                let over = e.deviceNetwork.map {
                    " over \($0 == .wifi ? "Wi‑Fi" : "cellular")"
                } ?? ""
                check(
                    e.ready || e.kind == .local,
                    "Mac-side bridge: \(e.status)\(over) (\(owner(e)))",
                    fix: own.isEmpty ? "Wait a few seconds and run doctor again." : own
                )
                if e.deviceNetwork == .cellular, e.kind == .ready {
                    note(
                        "The device is on cellular: Xcode keeps the tunnel set up on Wi‑Fi, but a new one needs Wi‑Fi again"
                    )
                }
                if e.detail.contains(LocalNetwork.advice) {
                    check(
                        false,
                        "macOS is blocking RoamRun's local network access, so it can't tell whether the device is on this Wi-Fi",
                        fix: LocalNetwork.advice,
                        warnOnly: true
                    )
                }
                if udid == nil {
                    note("UDID not known yet — learned the first time the bridge connects")
                }
                if let udid {
                    check(true, "UDID: \(udid)")
                    let core = coreDeviceState(udid)
                    check(
                        core != nil && core != "unavailable",
                        "Xcode (CoreDevice) sees the device as \(core ?? "unknown")",
                        fix: "Ask the user to unlock the device and keep the screen on; then run doctor again."
                    )
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
    nonisolated static func failsDoctor(_ issue: OTAIssue) -> Bool {
        issue == .funnel
    }

    /// Only when there is something stored: the address to reopen, what is kept,
    /// and whether the page is actually being served. Nothing to say otherwise.
    private static func otaSection(section: (String, String) -> Void,
                                   check: (Bool, String, String, Bool) -> Void,
                                   note: (String) -> Void)
    {
        guard let apps = OTA.builds() else {
            section("\nOver the air", "ota")
            check(false, "Can't read \(OTA.directory.path)",
                  "The install page answers 503 while this is true. Check the folder's permissions.", true)
            return
        }
        // Counted over the folders, not over `apps`: an app whose every build has
        // metadata this version can't decode has no entry in `apps` at all, and
        // that is precisely the app this count exists for.
        let undecodable = (OTA.appDirectories() ?? []).reduce(0) {
            $0 + OTA.unreadableBuilds(of: $1)
        }
        guard !apps.isEmpty || undecodable > 0 else { return }
        let mine: Bool
        var stray = false
        section("\nOver the air", "ota")
        let builds = apps.flatMap(\.builds)
        let bytes = builds.reduce(Int64(0)) {
            $0 + $1.size
        }
        note("\(builds.count) build\(builds.count == 1 ? "" : "s") of \(apps.count) app\(apps.count == 1 ? "" : "s"), " +
            "\(OTA.size(bytes)) in \(OTA.directory.path)")
        // Shown nowhere, pruned never, in no total: at least say it is there.
        if undecodable > 0 {
            note("\(undecodable) more with metadata this version can't read — a later one may; " +
                "delete the folder to be rid of it")
        }
        let tailnetPort = AppCoordinator.otaPort
        let served = TailscaleClient.serving(port: tailnetPort)
        let host = AppCoordinator.currentHost() // asked once; `serve` acts on this name alone
        let live = host.map {
            TailscaleClient.servingLive(port: tailnetPort, host: $0)
        } ?? false
        var unreadable = false
        switch served {
        case .unknown: mine = true
            unreadable = true
        case .nothing: mine = true // nothing of the user's to get in the way
        case .mounted:
            let here = host.flatMap {
                served.root(on: $0)
            }
            let beside = host.map {
                served.alongside($0)
            } ?? []
            // The same reading the app and `roamrun ota` use: no root under this
            // name is a free port, but anything else sharing it is not.
            mine = host != nil && beside.isEmpty && (here == nil || AppCoordinator.isOurs(here!, on: tailnetPort))
            stray = !mine && beside.isEmpty && AppCoordinator.abandoned(here)
        }
        check(live,
              live ? "The install page is published on port \(tailnetPort)"
                  : "The install page isn't published on port \(tailnetPort)",
              unreadable
                  ? "`tailscale serve status` didn't answer, so this can't be checked — is Tailscale running?"
                  : host == nil
                  ? "Tailscale didn't give this Mac a name — turn MagicDNS on for your tailnet."
                  : mine
                  ? "RoamRun publishes it while it runs — open RoamRun, then look in ⚙ Settings › Troubleshooting › Recent messages if it doesn't appear."
                  : stray
                  ? "port \(tailnetPort) carries an entry with nothing behind it, left by a run that was killed: tailscale serve --https=\(tailnetPort) --set-path=/ off"
                  :
                  "port \(tailnetPort) is serving \(served.described), which isn't RoamRun's. Give RoamRun another port: defaults write \(AppID.bundle) otaPort -int 41444",
              !failsDoctor(.notPublished))
        if !live, TailscaleClient.httpsEnabled() == false {
            check(false,
                  "This tailnet doesn't issue HTTPS certificates",
                  "`tailscale serve --https` writes nothing without them and still exits 0. Turn them on in the Tailscale admin console › DNS › HTTPS Certificates.",
                  !failsDoctor(.noHTTPSCertificates))
        }
        if let host, served.funnelled(on: host) {
            check(false, "Tailscale Funnel is on for port \(tailnetPort)",
                  "The install page is on the public internet. tailscale funnel --https=\(tailnetPort) off",
                  !failsDoctor(.funnel))
        }
        // Not only while it is live: forgetting the address and asking `doctor`
        // for it is most likely exactly when RoamRun isn't open.
        if let host {
            note("Open on the device: https://\(host):\(tailnetPort)/")
        }
    }

    private static func shell(_ path: String, _ args: [String]) -> String? {
        let r = Proc.run(path, args)
        return r.status == 0 ? r.out : nil
    }
}
