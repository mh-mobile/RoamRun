import Foundation
import Testing
@testable import RoamRun

// MARK: - Tunnel port attribution

private let phoneA = "00008101-000A00000000A001"
private let phoneB = "00008102-000B00000000B002"

private func establish(_ udid: String) -> String {
    "remotepairingd[1950:1] [com.apple.dt.remotepairing:remotepairingd] device-896 (\(udid)): Sending tunnel establish request"
}

private func endpoint(_ port: Int) -> String {
    "remotepairingd[1950:1] [com.apple.dt.remotepairing:networktunnelmanager] tunnel-437: Got tunnel endpoint: '192.168.1.15%en0:\(port)', includePeerToPeer: false"
}

private func ports(_ lines: [(String, TimeInterval)]) -> [(UInt16, String?)] {
    let watcher = TunnelPortWatcher()
    var got: [(UInt16, String?)] = []
    watcher.onPort = { got.append(($0, $1)); _ = $2 }
    let start = Date()
    for (line, at) in lines { watcher.handle(line, now: start + at) }
    return got
}

@Test func endpointBelongsToTheIPhoneThatAsked() {
    let got = ports([(establish(phoneA), 0), (endpoint(64025), 0.002)])
    #expect(got.count == 1)
    #expect(got[0].0 == 64025 && got[0].1 == phoneA)
}

@Test func endpointWithoutRequestIsUnattributed() {
    let got = ports([(endpoint(64025), 0)])
    #expect(got[0].1 == nil)
}

@Test func overlappingRequestsFromTwoIPhonesAreUnattributed() {
    let got = ports([(establish(phoneA), 0), (establish(phoneB), 0.001),
                     (endpoint(55940), 0.002), (endpoint(64025), 0.003)])
    // Either endpoint could be either phone's: never guess — not even for the second.
    #expect(got[0].1 == nil)
    #expect(got[1].1 == nil)
}

@Test func thirdIPhoneRightAfterAnAmbiguousEndpointIsNotCredited() {
    // A, B, ambiguous endpoint, then C asks: the next endpoint may still be B's.
    let phoneC = "00008103-000C00000000C003"
    let got = ports([(establish(phoneA), 0), (establish(phoneB), 0.001), (endpoint(55940), 0.002),
                     (establish(phoneC), 0.003), (endpoint(64025), 0.004),
                     (establish(phoneC), 10), (endpoint(61911), 10.002)])
    #expect(got[1].1 == nil)
    #expect(got[2].1 == phoneC)   // attribution resumes once things settle
}

@Test func retryDoesNotStealAnotherIPhonesEndpoint() {
    // A, B, A again: B's endpoint arriving first must not be credited to A.
    let got = ports([(establish(phoneA), 0), (establish(phoneB), 0.001), (establish(phoneA), 0.002),
                     (endpoint(55940), 0.003)])
    #expect(got[0].1 == nil)
}

@Test func failedRequestExpires() {
    // A's request never got an endpoint; B asks 10s later.
    let got = ports([(establish(phoneA), 0), (establish(phoneB), 10), (endpoint(55940), 10.002)])
    #expect(got[0].1 == phoneB)
}

@Test func advertNameCannotFakeATunnelPort() {
    // A LAN-supplied instance name embedding the endpoint phrase must not open relays.
    let evil = "remotepairingd[1950:1] Resolved bonjour advert x tunnel-1: Got tunnel endpoint: 'a:22', includePeerToPeer: false to identity nil, udid nil"
    #expect(ports([(evil, 0)]).isEmpty)
}

// MARK: - Bonjour advert lines

@Test func advertWithPairing() {
    let line = "remotepairingd[1950:1] Resolved bonjour advert 6E44E010-4869-4035-90B2-714A7D722AB3 to identity associated with udid \(phoneA)"
    let r = TunnelPortWatcher.advert(in: line)
    #expect(r?.0 == "6E44E010-4869-4035-90B2-714A7D722AB3" && r?.1 == phoneA)
}

@Test func advertWithoutPairing() {
    let r = TunnelPortWatcher.advert(in: "Resolved bonjour advert 18104A12-5556 to identity nil, udid nil")
    #expect(r?.0 == "18104A12-5556" && r?.1 == nil)
}

@Test func craftedInstanceNameCannotFakeAPairing() {
    // Instance names come from the LAN and may contain spaces.
    let evil = "Resolved bonjour advert x to identity associated with udid \(phoneA) to identity nil, udid nil"
    #expect(TunnelPortWatcher.advert(in: evil) == nil)
}

// MARK: - tailscale ping

@Test func directPathOnTheLAN() {
    let out = "pong from my-iphone (100.64.0.10) via 192.168.1.42:41641 in 40ms\n"
    #expect(TailscaleClient.directHost(fromPing: out) == "192.168.1.42")
}

@Test func directPathOverIPv6() {
    let out = "pong from my-iphone (100.64.0.10) via [fd00::1]:41641 in 40ms\n"
    #expect(TailscaleClient.directHost(fromPing: out) == "fd00::1")
}

@Test func lastPongWins() {
    let out = """
    pong from my-iphone (100.64.0.10) via DERP(tok) in 120ms
    pong from my-iphone (100.64.0.10) via 203.0.113.50:41805 in 80ms
    """
    #expect(TailscaleClient.directHost(fromPing: out) == "203.0.113.50")
}

@Test func relayedOrSilentIsNotDirect() {
    #expect(TailscaleClient.directHost(fromPing: "pong from my-iphone (100.64.0.10) via DERP(tok) in 120ms\n") == nil)
    #expect(TailscaleClient.directHost(fromPing: "ping \"100.64.0.10\" timed out\n") == nil)
    #expect(TailscaleClient.directHost(fromPing: "") == nil)
}

// MARK: - Status file ownership

private func entry(pid: Int32, _ status: BridgeStatus) -> StatusFile.Entry {
    .init(pid: pid, cli: false, udid: nil, status: status.title, detail: "", ready: status == .ready,
          tunnelPorts: [], updated: .now)
}

@Test func ownerMayAlwaysChangeOrClear() {
    let held = entry(pid: 100, .ready)
    #expect(StatusFile.mayReplace(held, with: entry(pid: 100, .off), by: 100))
    #expect(StatusFile.mayReplace(held, with: nil, by: 100))
}

@Test func otherProcessCannotTakeAHealthyBridge() {
    for s in [BridgeStatus.ready, .waiting, .starting, .preparing] {
        #expect(!StatusFile.mayReplace(entry(pid: 100, s), with: entry(pid: 200, .starting), by: 200))
    }
}

@Test func otherProcessMayTakeOverErroredOrStandingAside() {
    for s in [BridgeStatus.error, .local] {
        #expect(StatusFile.mayReplace(entry(pid: 100, s), with: entry(pid: 200, .starting), by: 200))
    }
}

@Test func aReusedPIDIsNotTheProcessThatWroteTheEntry() {
    let mine = StatusFile.startTime(of: getpid())
    #expect(mine != nil)                                              // the kernel knows when we started
    #expect(StatusFile.sameProcess(entry: mine, live: mine))
    #expect(StatusFile.sameProcess(entry: nil, live: mine))           // written before 0.1.13: can't tell, allow it
    #expect(!StatusFile.sameProcess(entry: mine, live: nil))          // that PID is gone
    #expect(!StatusFile.sameProcess(entry: mine, live: mine! + 60))   // same PID, a process that started later
    #expect(StatusFile.startTime(of: Int32.max) == nil)               // no such process
}

@Test func otherProcessNeverClearsAnEntry() {
    for s in [BridgeStatus.ready, .error, .local] {
        #expect(!StatusFile.mayReplace(entry(pid: 100, s), with: nil, by: 200))
    }
}

// MARK: - Device names

private func profile(_ name: String) -> DeviceProfile {
    DeviceProfile(displayName: name, instanceName: "", serviceType: "_remotepairing._tcp", domain: "local",
                  remotePairingPort: 49152, bonjourHost: "", txt: [:], providerID: "tailscale",
                  providerHostName: "", providerIP: "")
}

@Test func nameClashIgnoresCaseAndSurroundingSpaces() {
    let saved = [profile("iPhone")]
    #expect(saved.isNameTaken("iphone"))
    #expect(saved.isNameTaken(" iPhone "))
    #expect(!saved.isNameTaken("iPhone 2"))
}

@Test func renamingToYourOwnNameIsFine() {
    let p = profile("iPhone")
    #expect(![p].isNameTaken("iPhone", except: p.id))
}

@Test func uniqueNameCountsUp() {
    #expect([profile("iPad")].uniqueName("iPhone") == "iPhone")
    #expect([profile("iPhone"), profile("iPhone 2")].uniqueName("iPhone") == "iPhone 3")
}

// MARK: - Device icons

@Test func iconFollowsDeviceType() {
    var p = profile("x")
    #expect(p.symbol == "iphone")
    p.deviceType = "iPad"
    #expect(p.symbol == "ipad")
    p.deviceType = "appleTV"   // unknown kinds fall back
    #expect(p.symbol == "iphone")
}

// MARK: - Suggested commands

@Test func namesAreQuotedForTheShell() {
    #expect(CLI.shellName("MyiPhone") == "MyiPhone")
    #expect(CLI.shellName("iPhone mh") == "'iPhone mh'")
    #expect(CLI.shellName("Hiro's \"iPad\" $1") == #"'Hiro'\''s "iPad" $1'"#)
}

// MARK: - Install: which signing a provisioning profile allows

@Test func provisioningKinds() {
    #expect(CLI.parseProvisioning(["ProvisionedDevices": ["00008102-000B00000000B002"]]) == .devices(["00008102-000B00000000B002"]))
    #expect(CLI.parseProvisioning(["ProvisionsAllDevices": true]) == .allDevices)   // Enterprise
    #expect(CLI.parseProvisioning(["Name": "App Store"]) == .appStore)             // no device list
}

// MARK: - Helper processes never hang us

private func timed(_ path: String, _ args: [String]) -> (Proc.Result, TimeInterval) {
    let start = Date()
    let r = Proc.run(path, args, timeout: 1)
    return (r, Date().timeIntervalSince(start))
}

// Timing tests run one at a time: in parallel on a small CI runner they'd skew each other.
@Suite(.serialized) struct ProcTiming {
    @Test func slowToolsFillingTheTaskPoolStillTimeOut() async {
        // runAsync blocks a Swift concurrency thread per call; with every one of
        // them blocked, the timeout timers must still get to run.
        // Each run is timed from its own start: other tests may hold the pool first.
        let longest = await withTaskGroup(of: TimeInterval.self) { group in
            for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
                group.addTask { await Task.detached { timed("/bin/sleep", ["20"]).1 }.value }
            }
            return await group.reduce(0, max)
        }
        #expect(longest < 4)
    }

    @Test func quickToolReturnsItsOutput() {
        let (r, t) = timed("/bin/echo", ["hello"])
        #expect(r.status == 0 && r.out == "hello\n" && t < 1)
    }

    @Test func slowToolIsStoppedAtTheTimeout() {
        let (r, t) = timed("/bin/sleep", ["20"])
        #expect(r.status != 0 && r.err.contains("timed out"), "status=\(r.status) err=\(r.err)")
        #expect(t < 2.5, "t=\(t)")
    }

    @Test func toolIgnoringTermIsKilled() {
        let (r, t) = timed("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"])
        #expect(r.status == 9, "status=\(r.status) err=\(r.err) t=\(t)")   // SIGKILL 2s after the ignored TERM
        #expect(t < 4.5, "t=\(t)")
    }

    @Test func grandchildHoldingThePipeDoesNotHangUs() {
        // sh is killed, but its `sleep` keeps stdout open.
        let (r, t) = timed("/bin/sh", ["-c", "trap '' TERM; sleep 8"])
        #expect(r.status == 9, "status=\(r.status) err=\(r.err)")
        #expect(t < 6, "t=\(t)")
    }

    @Test func toolThatExitsKeepsItsResultWhileABackgroundChildHoldsThePipe() {
        let (r, t) = timed("/bin/sh", ["-c", "echo hi; sleep 30 &"])
        #expect(r.status == 0 && r.out == "hi\n", "status=\(r.status) out=\(r.out)")
        #expect(t < 2.5, "t=\(t)")
    }
}

// MARK: - Home / away rules (regressions from real runs)

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

@Test func bridgingIgnoresAnAdvertLearnedBeforeLeaving() {
    // Learned at home at t0, bridge went active at t0+20 after leaving: not proof of home.
    let seen = (instance: "HOME-ADVERT", at: t0)
    #expect(HomeRule.bridgingAdvert(seen, activatedAt: t0 + 20, now: t0 + 40) == nil)
}

@Test func bridgingUsesAnAdvertSeenSinceItWentActive() {
    let seen = (instance: "BACK-HOME", at: t0 + 30)
    #expect(HomeRule.bridgingAdvert(seen, activatedAt: t0 + 20, now: t0 + 40) == "BACK-HOME")
    #expect(HomeRule.bridgingAdvert(seen, activatedAt: t0 + 20, now: t0 + 200) == nil)   // stale after 90s
}

@Test func standingAsideProbesAKnownNameButReconfirmsEveryFiveMinutes() {
    #expect(HomeRule.useCheapProbe(known: "A", lastFullCheck: t0, now: t0 + 60))
    #expect(!HomeRule.useCheapProbe(known: "A", lastFullCheck: t0, now: t0 + 301))
    #expect(!HomeRule.useCheapProbe(known: nil, lastFullCheck: t0, now: t0 + 60))
}

@Test func oneMissedCheckAtHomeDoesNotResume() {
    #expect(!HomeRule.shouldResume(awayTicks: 1))
    #expect(!HomeRule.shouldResume(awayTicks: 2))
}

@Test func leavingResumesAfterSeveralMissesWhateverCoreDeviceSays() {
    // No CoreDevice input at all: a just-closed bridge's link can't hold it back.
    #expect(HomeRule.shouldResume(awayTicks: 3))
}


// MARK: - Contracts other processes and scripts rely on

@Test func stateKeysAndStatusTitlesStayFixed() {
    #expect(BridgeStatus.allCases.map(\.rawValue) == ["off", "starting", "waiting", "preparing", "ready", "error", "local"])
    for s in BridgeStatus.allCases { #expect(BridgeStatus(title: s.title) == s) }
    // Written to status.json and read by other (possibly older) RoamRun processes.
    #expect(BridgeStatus.local.title == "On this Wi\u{2011}Fi")
    #expect(BridgeStatus.error.title == "Needs attention")
}

@Test func namesTheCLICanUse() {
    let saved = [profile("iPhone")]
    #expect(saved.nameProblem("  ") != nil)
    #expect(saved.nameProblem(" -x") != nil)       // trimmed first, still an option to the CLI
    #expect(saved.nameProblem("iphone") != nil)
    #expect(saved.nameProblem("iPhone", except: saved[0].id) == nil)
    #expect(saved.nameProblem("iPad") == nil)
}

@Test func emptyAndNonASCIINamesAreQuoted() {
    #expect(CLI.shellName("") == "''")
    #expect(CLI.shellName("Hiro’s iPhone") == "'Hiro’s iPhone'")
    #expect(CLI.shellName("my-iPad_2.0") == "my-iPad_2.0")
}

@Test func homeRuleBoundaries() {
    #expect(HomeRule.bridgingAdvert(nil, activatedAt: t0, now: t0 + 10) == nil)
    #expect(HomeRule.bridgingAdvert((instance: "A", at: t0), activatedAt: t0, now: t0 + 10) == nil)   // must be after going active
    #expect(HomeRule.bridgingAdvert((instance: "A", at: t0 + 1), activatedAt: t0, now: t0 + 91) == "A")   // 90 s still counts
}

@Test func endpointLineVariants() {
    let p2p = "remotepairingd[1950:1] [com.apple.dt.remotepairing:networktunnelmanager] tunnel-437: Got tunnel endpoint: '192.168.1.15%en0:64025', includePeerToPeer: true"
    #expect(ports([(establish(phoneA), 0), (p2p, 0.002)]).first?.0 == 64025)
    // An advert name embedding the request phrase must not count as a pending request.
    let evil = "remotepairingd[1950:1] Resolved bonjour advert x device-1 (\(phoneB)): Sending tunnel establish request to identity nil, udid nil"
    #expect(ports([(evil, 0), (endpoint(64025), 0.002)]).first?.1 == nil)
}

@Test func knownEndpointFormatsDontWarnButNewOnesDo() {
    let watcher = TunnelPortWatcher()
    var logged: [String] = []
    watcher.onLog = { logged.append($0) }
    watcher.handle("remotepairingd[1950:1] [com.apple.dt.remotepairing:networktunnelmanager] tunnel-593: Got tunnel endpoint: 'fe80::14a2:5da8:a26:9bb4%en0.64106', includePeerToPeer: false")
    #expect(logged.isEmpty)
    watcher.handle("remotepairingd[1950:1] tunnel-9: Got tunnel endpoint: <nw_endpoint 10.0.0.2:5000>")
    #expect(logged.count == 1)
}

// MARK: - Argument parsing

private extension Result { var isSuccess: Bool { if case .success = self { true } else { false } } }

private func parsed(_ s: String) -> Result<CLI.Parsed, CLI.ArgumentError> { CLI.parse(s.split(separator: " ").map(String.init)) }

@Test func argumentsPerCommand() throws {
    #expect(try parsed("status --wait 5 iPhone").get().words == ["iPhone"])
    #expect(try parsed("status --wait 5 iPhone").get().wait == 5)
    #expect(try parsed("logs iPhone com.x").get().words == ["iPhone", "com.x"])
    let run = try? parsed("run iPhone --scheme S --logs").get()
    #expect(run?.words == ["iPhone"] && run?.values["--scheme"] == "S" && run?.flags == ["--logs"])
}

@Test func argumentsThatAreRejected() {
    for bad in ["devices -d", "status --wait=", "run x --scheme=", "status --scheme X", "up a b", "status x --wait", "status x --wait inf",
                "status x --wait -1", "run x --scheme", "run x --scheme --logs", "screenshot x a.png b"] {
        #expect((try? parsed(bad).get()) == nil, "\(bad)")
    }
}

@Test func launchOptionsReachDevicectl() throws {
    let p = try parsed("run iPhone --arg -ShowScreen --arg settings --env DEMO=1 --env EMPTY= --url myapp://settings/a=b").get()
    #expect(p.words == ["iPhone"])
    #expect(p.launch == CLI.Launch(args: ["-ShowScreen", "settings"], env: ["DEMO=1", "EMPTY="], url: "myapp://settings/a=b"))
    #expect(p.launch.argv(udid: "U", bundleID: "com.x", console: false) == [
        "/usr/bin/xcrun", "devicectl", "device", "process", "launch", "--terminate-existing", "--device", "U",
        "--payload-url", "myapp://settings/a=b", "com.x", "--", "-ShowScreen", "settings"])
    // logs takes them too, and without any the command is the plain launch.
    #expect(try parsed("logs iPhone com.x --arg -v").get().launch.args == ["-v"])
    #expect(CLI.Launch().argv(udid: "U", bundleID: "com.x", console: true) == [
        "/usr/bin/xcrun", "devicectl", "device", "process", "launch", "--console", "--terminate-existing", "--device", "U", "com.x"])
    // With the console and a URL: devicectl's own options first, the app's after "--".
    let both = CLI.Launch(args: ["-h"], url: "myapp://x").argv(udid: "U", bundleID: "com.x", console: true)
    #expect(both.suffix(8) == ["--terminate-existing", "--device", "U", "--payload-url", "myapp://x", "com.x", "--", "-h"])
    // Split at the first "=", values may hold more (and newlines).
    let env = CLI.Launch(env: ["A=b=c", "E=", "J=line1\nline2"]).environment
    #expect(env.map(\.name) == ["A", "E", "J"] && env.map(\.value) == ["b=c", "", "line1\nline2"])
    #expect(CLI.parse(["run", "x", "--env", "J={\n\"a\": 1\n}"]).isSuccess)
    // "--arg -h" is for the app, not our help.
    #expect(!CLI.wantsHelp(["run", "x", "--arg", "-h"]) && CLI.wantsHelp(["run", "x", "-h"]) && CLI.wantsHelp(["help"]))
    for bad in ["run x --env DEMO", "run x --env 1A=2", "run x --env", "run x --env -X=1", "run x --url settings",
                "run x --url -x", "run x --arg", "screenshot x --arg a", "install x a.ipa --url myapp://x"] {
        #expect((try? parsed(bad).get()) == nil, "\(bad)")
    }
}

@Test func onlyOurOutdatedSkillsAreReported() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-home-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let current = Data("---\nname: roamrun\ndescription: now\n---\n".utf8)
    func put(_ client: String, _ text: String) throws {
        let dir = home.appendingPathComponent("\(client)/skills/roamrun")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent("SKILL.md"))
    }
    try put(".claude", "---\nname: roamrun\ndescription: older\n---\n")   // ours, another version
    try put(".codex", String(decoding: current, as: UTF8.self))              // ours, this version
    try put(".cursor", "---\nname: something-else\n---\n")                // not ours
    let linked = home.appendingPathComponent(".gemini/skills")                  // managed by another tool
    try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("roamrun"),
                                               withDestinationURL: home.appendingPathComponent(".claude/skills/roamrun"))
    #expect(CLI.staleSkills(home: home, bundled: current) == [home.appendingPathComponent(".claude/skills/roamrun").path])
}

@Test func infoPlistMatchesAppID() throws {
    // AppID.bundle names the defaults domain, log subsystem and notifications: it must be the real id.
    let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Info.plist")
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
    #expect(info?["CFBundleIdentifier"] as? String == AppID.bundle)
}

@Test func settingsCarryOverFromTheOldBundleID() {
    let old: [String: Any] = ["networkInterface": "en1", "wasActiveIDs": ["A"]]
    #expect(AppID.carriedOver(old: nil, new: nil) == nil)                         // nothing saved yet
    #expect(AppID.carriedOver(old: [:], new: nil) == nil)
    #expect(AppID.carriedOver(old: old, new: nil)?["networkInterface"] as? String == "en1")
    #expect(AppID.carriedOver(old: old, new: [:])?["networkInterface"] as? String == "en1")   // an empty domain file
    #expect(AppID.carriedOver(old: old, new: ["networkInterface": "en0"]) == nil)             // never overwrites
    var marked = old; marked[AppID.movedKey] = AppID.bundle                                     // already carried over once:
    #expect(AppID.carriedOver(old: marked, new: nil) == nil)                                   // deleted settings stay deleted
}

import ServiceManagement

@Test func openAtLoginSurvivesALostRegistration() {
    // Never chosen here: whatever the system says.
    #expect(AppCoordinator.loginItem(saved: nil, status: .notRegistered) == (on: false, register: false))
    #expect(AppCoordinator.loginItem(saved: nil, status: .enabled) == (on: true, register: false))
    // Chosen and still registered. .requiresApproval is the user switching it off in System
    // Settings: still "on" here, and we don't register over their choice.
    #expect(AppCoordinator.loginItem(saved: true, status: .enabled) == (on: true, register: false))
    #expect(AppCoordinator.loginItem(saved: true, status: .requiresApproval) == (on: true, register: false))
    // The registration went with the old bundle id (0.1.12) or a replaced app: put it back.
    #expect(AppCoordinator.loginItem(saved: true, status: .notRegistered) == (on: true, register: true))
    #expect(AppCoordinator.loginItem(saved: true, status: .notFound) == (on: true, register: true))
    // Switched off stays off.
    #expect(AppCoordinator.loginItem(saved: false, status: .notRegistered) == (on: false, register: false))
}

@Test func deviceLookup() {
    let a = profile("iPhone"), b = profile("iPad")
    #expect(CLI.matches("IPHONE", in: [a, b]).map(\.id) == [a.id])
    #expect(CLI.matches(String(a.id.uuidString.prefix(7)), in: [a, b]).isEmpty)      // too short for an id
    #expect(CLI.matches(String(a.id.uuidString.prefix(8)), in: [a, b]).map(\.id) == [a.id])
    let named = profile(b.id.uuidString.prefix(8).lowercased())                          // a name wins over an id prefix
    #expect(CLI.matches(String(b.id.uuidString.prefix(8)), in: [b, named]).map(\.id) == [named.id])
}

// MARK: - Output of other tools

@Test func orphansAreOnlyOurHelpersWithADeadParent() {
    let ps = """
      101     1 /usr/bin/dns-sd -P 6E44 _remotepairing._tcp local 49152 rr-1.roamrun.local 192.168.1.2
      102   500 /usr/bin/dns-sd -P 6E44 _remotepairing._tcp local 49152 rr-2.roamrun.local 192.168.1.2
      103     1 /usr/bin/dns-sd -P Mine _http._tcp local 80 myhost.local 192.168.1.2
      104     1 /usr/bin/log stream --predicate process == "remotepairingd" AND (eventMessage CONTAINS "Got tunnel endpoint" OR eventMessage CONTAINS "Resolved bonjour advert")
      105     1 /usr/bin/log stream --predicate subsystem == "x"
    """
    #expect(DNSServiceProxy.orphans(fromPS: ps) == [101, 104])
}

@Test func tailscalePeersFromStatusJSON() {
    let json = #"{"Peer":{"k1":{"DNSName":"mac.tail.ts.net.","OS":"macOS","TailscaleIPs":["100.64.0.2"],"Online":true},"k2":{"DNSName":"my-iphone.tail.ts.net.","OS":"iOS","TailscaleIPs":["100.64.0.10"],"Online":false,"CurAddr":"203.0.113.50:41641"}}}"#
    let d = TailscaleClient.devices(fromStatusJSON: json)
    #expect(d?.map(\.name) == ["my-iphone", "mac"])   // iOS first
    #expect(d?.first?.curAddr == "203.0.113.50:41641" && d?.last?.curAddr == "")
    #expect(TailscaleClient.devices(fromStatusJSON: "not json") == nil)
}

@Test func tunnelStateMatchesUDIDInAnyCase() {
    let result: [String: Any] = ["devices": [["hardwareProperties": ["udid": phoneA],
                                              "connectionProperties": ["tunnelState": "connected"]]]]
    #expect(CLI.tunnelState(in: result, udid: phoneA.lowercased()) == "connected")
    #expect(CLI.tunnelState(in: result, udid: phoneB) == nil)
}

@Test func namesWithControlCharactersAreRejected() {
    #expect([DeviceProfile]().nameProblem("iPhone\u{1B}[31m") != nil)
    #expect([DeviceProfile]().nameProblem("👩\u{200D}💻 iPhone") == nil)   // ZWJ emoji is fine
}

@Test func appendedEndpointFieldsStillYieldThePort() {
    let line = "remotepairingd[1950:1] tunnel-9: Got tunnel endpoint: '10.0.0.2:5000', includePeerToPeer: false, protocol: tcp"
    #expect(ports([(line, 0)]).first?.0 == 5000)
}

// MARK: - dns-sd -Z zone dump

@MainActor @Test func zoneDumpBecomesServices() {
    let c = BonjourCapture()
    c.ownedHosts = ["rr-1.roamrun.local"]
    for line in [
        "_remotepairing._tcp PTR 6E44._remotepairing._tcp",
        "6E44._remotepairing._tcp SRV 0 0 49152 my-iphone.local. ; Replace with unicast FQDN of target host",
        #"6E44._remotepairing._tcp TXT "identifier=AB" "authTag=k=v=w" "flag""#,
        "my-iphone.local. A 192.168.1.42",
        "_remotepairing._tcp PTR FAKE._remotepairing._tcp",
        "FAKE._remotepairing._tcp SRV 0 0 49152 rr-1.roamrun.local.",   // our own record
    ] { c.parse(line: line) }
    let s = c.services["6E44._remotepairing._tcp"]
    #expect(s?.instanceName == "6E44" && s?.port == 49152 && s?.host == "my-iphone.local")
    #expect(s?.txt["authTag"] == "k=v=w" && s?.txt["flag"] == "" && s?.hostIPs == ["192.168.1.42"])
    #expect(c.services["FAKE._remotepairing._tcp"] == nil)
}

@MainActor @Test func aFloodingPeerCantGrowTheTablesOrLockOutARealDevice() {
    let c = BonjourCapture()
    for i in 0..<600 { c.parse(line: "I\(i)._remotepairing._tcp SRV 0 0 49152 h\(i).local.") }
    #expect(c.services.count == 500)
    c.parse(line: "REAL._remotepairing._tcp SRV 0 0 49152 my-iphone.local.")   // arrives after the flood
    #expect(c.services["REAL._remotepairing._tcp"] != nil && c.services.count == 500)
}

@Test func endpointReportsTheAddressDialed() {
    let watcher = TunnelPortWatcher()
    var host = ""
    watcher.onPort = { _, _, h in host = h }
    watcher.handle(endpoint(64025))
    #expect(host == "192.168.1.15")
}

@Test func statusFileKeepsGoodEntriesNextToABadOne() throws {
    let good = StatusFile.Entry(pid: 1, cli: false, udid: nil, status: "Off", detail: "", ready: false, tunnelPorts: [], updated: .now)
    let id = UUID()
    // The real file's shape, as written by StatusFile.write.
    let written = try JSONEncoder().encode([id: good])
    #expect(StatusFile.decode(written)[id] == good)
    var raw = try #require(JSONSerialization.jsonObject(with: written) as? [Any])
    raw += [UUID().uuidString, ["pid": "not a number"]]
    let decoded = StatusFile.decode(try JSONSerialization.data(withJSONObject: raw))
    #expect(decoded.keys.contains(id) && decoded.count == 1)
}

@Test func oneOfTwoWatchersStepsBack() {
    let cli = StatusFile.Entry(pid: 200, cli: true, udid: nil, status: "On this Wi\u{2011}Fi", detail: "", ready: false, tunnelPorts: [], updated: .now)
    var app = cli; app.cli = false
    #expect(HomeRule.yields(meCLI: false, myPID: 100, to: cli))    // the app yields to roamrun up
    #expect(!HomeRule.yields(meCLI: true, myPID: 300, to: app))    // roamrun up keeps it
    #expect(HomeRule.yields(meCLI: true, myPID: 300, to: cli))     // of two CLIs the newer steps back
    #expect(!HomeRule.yields(meCLI: true, myPID: 100, to: cli))
}

@Test func runInstallsTheApplicationNotAnAppClip() {
    let t = { (name: String, type: String) -> [String: Any] in
        ["buildSettings": ["WRAPPER_EXTENSION": "app", "PLATFORM_NAME": "iphoneos", "TARGET_NAME": name,
                           "PRODUCT_TYPE": type, "WRAPPER_NAME": "\(name).app", "TARGET_BUILD_DIR": "/b"]]
    }
    let clip = t("Clip", "com.apple.product-type.application.on-demand-install-capable")
    let app = t("App", "com.apple.product-type.application")
    #expect(CLI.appTarget(in: [clip, app], scheme: "App (Staging)")?["TARGET_NAME"] == "App")
    #expect(CLI.appTarget(in: [app, clip], scheme: "Clip")?["TARGET_NAME"] == "App")   // never the clip
    #expect(CLI.appTarget(in: [], scheme: "App") == nil)
}

// MARK: - Saved file compatibility

@Test func profilesFromOlderAndNewerVersionsDecode() throws {
    // As 0.1.x writes it.
    let v01 = #"[{"id":"940F4303-91B8-4C9C-9861-763E5429DDC6","displayName":"iPad","instanceName":"6E44","serviceType":"_remotepairing._tcp","domain":"local","remotePairingPort":49152,"bonjourHost":"my-ipad.local","txt":{"identifier":"AB"},"providerID":"tailscale","providerHostName":"my-ipad","providerIP":"100.64.0.10","udid":"00008101-000A00000000A001"}]"#
    let old = try JSONDecoder().decode([DeviceProfile].self, from: Data(v01.utf8))
    #expect(old.first?.displayName == "iPad" && old.first?.remotePairingPort == 49152 && old.first?.deviceType == nil)
    // Fields missing, or added by a later version: still readable.
    let sparse = #"[{"id":"940F4303-91B8-4C9C-9861-763E5429DDC6","instanceName":"6E44","providerIP":"100.64.0.10","futureField":true}]"#
    let p = try JSONDecoder().decode([DeviceProfile].self, from: Data(sparse.utf8))
    #expect(p.first?.serviceType == "_remotepairing._tcp" && p.first?.providerID == "tailscale")
    // Not a device at all: refused, so the file is kept aside rather than turned into a ghost entry.
    #expect((try? JSONDecoder().decode([DeviceProfile].self, from: Data("[{}]".utf8))) == nil)
    // And what we write reads back the same.
    #expect(try JSONDecoder().decode([DeviceProfile].self, from: JSONEncoder().encode(old)) == old)
}

@Test func statusEntriesCarryAStableStateAndOldOnesStillRead() throws {
    var e = StatusFile.Entry(pid: 1, cli: false, udid: nil, status: "On this Wi\u{2011}Fi", detail: "", ready: false, tunnelPorts: [], updated: .now)
    #expect(e.kind == .local && !e.holdsDevice)            // written by 0.1.7 and older: title only
    e.state = "ready"
    #expect(e.kind == .ready && e.holdsDevice)             // the stable key wins
    let round = try JSONDecoder().decode(StatusFile.Entry.self, from: JSONEncoder().encode(e))
    #expect(round.state == "ready")
    // What an older reader sees: the extra key is ignored, the title is still there.
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(e)) as? [String: Any])
    #expect(json["status"] as? String == "On this Wi\u{2011}Fi")
}

// MARK: - Status file under concurrent writers (flock is per open file description,
// so threads that each open() the lock exclude each other like processes do)

@Test func concurrentWritersDontLoseEachOthersEntries() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let ids = (0..<24).map { _ in UUID() }
    DispatchQueue.concurrentPerform(iterations: ids.count) { i in
        let e = StatusFile.Entry(pid: 1, cli: false, udid: nil, status: "Ready for Xcode", detail: "", ready: true,
                                 tunnelPorts: [], updated: .now, state: "ready")
        StatusFile.write(ids[i], e, in: dir, live: { _ in true })
    }
    #expect(StatusFile.read(in: dir, live: { _ in true }).count == ids.count)
    let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("status.json").path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
}

@Test func writeSaysWhetherTheClaimIsOurs() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = UUID(), other: Int32 = getpid() + 1
    func e(_ pid: Int32, _ s: BridgeStatus) -> StatusFile.Entry {
        .init(pid: pid, cli: false, udid: nil, status: s.title, detail: "", ready: false, tunnelPorts: [], updated: .now, state: s.rawValue)
    }
    let live: StatusFile.Liveness = { _ in true }
    #expect(StatusFile.write(id, e(other, .ready), in: dir, live: live) == .written)   // nobody held it
    // Healthy elsewhere: refused, and told who holds it — also for a later attempt.
    func holder(_ r: StatusFile.WriteResult) -> Int32? { if case .heldBy(let e) = r { e.pid } else { nil } }
    #expect(holder(StatusFile.write(id, e(getpid(), .starting), in: dir, live: live)) == other)
    #expect(holder(StatusFile.write(id, nil, in: dir, live: live)) == other)
    // Errored elsewhere: ours to take.
    let errored = UUID()
    #expect(StatusFile.write(errored, e(other, .error), in: dir, live: live) == .written)
    #expect(StatusFile.write(errored, e(getpid(), .starting), in: dir, live: live) == .written)
    // A second profile for the same iPhone (same UDID) can't bridge it too; standing aside is fine.
    func withUDID(_ x: StatusFile.Entry) -> StatusFile.Entry { var x = x; x.udid = "00008130-000c1c5c307a8d3a"; return x }
    let first = UUID(), second = UUID()
    #expect(StatusFile.write(first, withUDID(e(other, .ready)), in: dir, live: live) == .written)
    #expect(holder(StatusFile.write(second, withUDID(e(getpid(), .starting)), in: dir, live: live)) == other)
    #expect(StatusFile.write(second, withUDID(e(getpid(), .local)), in: dir, live: live) == .written)
    // Can't write at all: a failure, not a silent success.
    let file = dir.appendingPathComponent("not-a-dir"); try Data().write(to: file)
    if case .failed = StatusFile.write(id, e(getpid(), .starting), in: file, live: live) {} else { Issue.record("expected .failed") }
}

// MARK: - Relay, end to end on localhost (fake device = an echo server)

import Network

/// Echoes everything back (or, `silent`, accepts and never answers). Keeps its
/// connections, so a test can close them all at a moment of its choosing.
private final class EchoServer: @unchecked Sendable {
    let listener: NWListener
    private let lock = NSLock()
    private var conns: [NWConnection] = []
    var accepted: Int { lock.withLock { conns.count } }

    init(silent: Bool = false, port: UInt16? = nil) throws {
        listener = try port.map { try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: $0)!) } ?? NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [lock, weak self] c in
            lock.withLock { self?.conns.append(c) }
            c.start(queue: .global())
            guard !silent else { return }
            @Sendable func loop() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, err in
                    if let data, !data.isEmpty { c.send(content: data, completion: .contentProcessed { _ in loop() }) }
                    else if done || err != nil { c.cancel() }
                    else { loop() }
                }
            }
            loop()
        }
    }
    /// The port, or 0 if it couldn't listen (e.g. a fixed port that's taken).
    func start() async -> UInt16 {
        await withCheckedContinuation { cont in
            let once = OnceBox()
            listener.stateUpdateHandler = { [listener] s in
                switch s {
                case .ready: once.run { cont.resume(returning: listener.port!.rawValue) }
                case .failed, .waiting, .cancelled: once.run { listener.cancel(); cont.resume(returning: 0) }
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }
    func closeAll() { lock.withLock { conns }.forEach { $0.cancel() } }
    func stop() { listener.cancel(); closeAll() }
}

/// Polls `condition` for up to 5 s: connection callbacks land when they land.
private func eventually(_ condition: () -> Bool) async throws -> Bool {
    for _ in 0..<50 where !condition() { try await Task.sleep(for: .milliseconds(100)) }
    return condition()
}

/// Sends `payload` to 127.0.0.1:port and returns what comes back before the peer closes (or times out).
private func roundTrip(port: UInt16, payload: Data, timeout: TimeInterval = 5) async -> Data? {
    let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    return await withCheckedContinuation { cont in
        let box = OnceBox()
        let finish: @Sendable (Data?) -> Void = { d in box.run { conn.cancel(); cont.resume(returning: d) } }
        conn.stateUpdateHandler = { s in
            switch s {
            case .ready:
                conn.send(content: payload, completion: .contentProcessed { _ in })
                conn.receive(minimumIncompleteLength: payload.count, maximumLength: 65536) { data, _, _, _ in finish(data) }
            case .failed, .cancelled: finish(nil)
            default: break
            }
        }
        conn.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
    }
}

private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func run(_ body: () -> Void) { if lock.withLock({ let first = !done; done = true; return first }) { body() } }
}

/// A started relay on a free local port (random, retried if taken).
private func startedRelay(upstream: UInt16) async throws -> Relay {
    var lastError: Error?
    for _ in 0..<10 {
        let r = Relay(localIP: "127.0.0.1", localPort: UInt16.random(in: 40000...49000), remoteIP: "127.0.0.1", remotePort: upstream)
        do { try await r.start(); return r } catch { lastError = error }
    }
    throw lastError!
}

@Suite(.serialized) struct RelayOnLocalhost {
    @Test func bytesGoThroughUnchanged() async throws {
        let server = try EchoServer(); let upstream = await server.start(); defer { server.stop() }
        let relay = try await startedRelay(upstream: upstream); defer { relay.stop() }
        let payload = Data((0..<4000).map { UInt8($0 % 251) })
        #expect(await roundTrip(port: relay.localPort, payload: payload) == payload)
    }

    @Test func refusedUpstreamClosesTheLocalSide() async throws {
        let server = try EchoServer(); let dead = await server.start(); server.stop()   // nothing listens there now
        let relay = try await startedRelay(upstream: dead); defer { relay.stop() }
        let start = Date()
        let got = await roundTrip(port: relay.localPort, payload: Data("hi".utf8), timeout: 8)
        #expect(got == nil || got?.isEmpty == true)
        #expect(Date().timeIntervalSince(start) < 7)   // closed, not left hanging until our timeout
    }

    @Test func connectionsBeyondTheCapAreRefused() async throws {
        let server = try EchoServer(); let upstream = await server.start(); defer { server.stop() }
        let relay = try await startedRelay(upstream: upstream); defer { relay.stop() }
        var held: [NWConnection] = []
        defer { held.forEach { $0.cancel() } }
        for _ in 0..<64 {   // the per-relay cap, each kept open
            let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: relay.localPort)!, using: .tcp)
            c.start(queue: .global()); held.append(c)
        }
        try await Task.sleep(for: .seconds(2))   // let all 64 be accepted and tracked
        #expect(await roundTrip(port: relay.localPort, payload: Data("x".utf8), timeout: 3) == nil)
    }

    /// Opens `n` connections to the relay and keeps them until cancelled.
    private func hold(_ n: Int, to relay: Relay) -> [NWConnection] {
        (0..<n).map { _ in
            let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: relay.localPort)!, using: .tcp)
            c.start(queue: .global()); return c
        }
    }

    /// The process-wide pair count must come back to zero whichever side ends a
    /// connection first — stop(), the client, or the upstream — or relays
    /// slowly lose capacity until they refuse everything.
    @Test func pairCountSurvivesStopAndCloseRaces() async throws {
        let server = try EchoServer(); let upstream = await server.start(); defer { server.stop() }
        #expect(try await eventually { Relay.openPairs == 0 })

        // Stop with every connection tracked, then the clients' late closes arrive.
        let a = try await startedRelay(upstream: upstream)
        var held = hold(64, to: a)
        #expect(try await eventually { Relay.openPairs == 64 })
        a.stop()
        held.forEach { $0.cancel() }
        #expect(try await eventually { Relay.openPairs == 0 })

        // stop() and the upstream closing every connection, at the same moment.
        let far = try EchoServer(); let farPort = await far.start(); defer { far.stop() }
        let b = try await startedRelay(upstream: farPort)
        held = hold(40, to: b)
        #expect(try await eventually { far.accepted == 40 && Relay.openPairs == 40 })
        DispatchQueue.concurrentPerform(iterations: 2) { i in if i == 0 { far.closeAll() } else { b.stop() } }
        held.forEach { $0.cancel() }
        #expect(try await eventually { Relay.openPairs == 0 })

        // Full, all closed by the clients: new connections get through again.
        let c = try await startedRelay(upstream: upstream); defer { c.stop() }
        held = hold(64, to: c)
        #expect(try await eventually { Relay.openPairs == 64 })
        #expect(await roundTrip(port: c.localPort, payload: Data("x".utf8), timeout: 2) == nil)
        held.forEach { $0.cancel() }
        #expect(try await eventually { Relay.openPairs == 0 })
        #expect(await roundTrip(port: c.localPort, payload: Data("x".utf8)) == Data("x".utf8))
    }

    /// 256 pairs across all relays: one more is refused anywhere, until one closes.
    @Test func processWideCapSpansRelays() async throws {
        let server = try EchoServer(); let upstream = await server.start(); defer { server.stop() }
        var relays: [Relay] = []
        defer { relays.forEach { $0.stop() } }
        var held: [[NWConnection]] = []
        defer { held.joined().forEach { $0.cancel() } }
        for _ in 0..<4 {
            let r = try await startedRelay(upstream: upstream)
            relays.append(r); held.append(hold(64, to: r))
        }
        #expect(try await eventually { Relay.openPairs == 256 })
        let fifth = try await startedRelay(upstream: upstream); relays.append(fifth)
        #expect(await roundTrip(port: fifth.localPort, payload: Data("x".utf8), timeout: 2) == nil)
        held[0][0].cancel()
        #expect(try await eventually { Relay.openPairs == 255 })
        #expect(await roundTrip(port: fifth.localPort, payload: Data("x".utf8)) == Data("x".utf8))
    }

    /// Here, not top-level: its probes sweep 49152…, where these echo servers listen.
    @Test func portScanKeepsItsDeadlineEvenOnASilentPort() async throws {
        // A port that accepts and never answers the handshake (4 s timeout on its own).
        var silent: EchoServer?
        for port in UInt16(49152)...49160 where silent == nil {
            if let s = try? EchoServer(silent: true, port: port), await s.start() != 0 { silent = s }
        }
        guard let silent else { return }   // all taken: nothing to test here
        defer { silent.stop() }
        let clock = ContinuousClock(), start = clock.now
        let r = await ReachabilityProbe.findRemotePairingPort(host: "127.0.0.1", limit: .seconds(1))
        #expect(r == .timedOut)
        #expect(clock.now - start < .seconds(3.5))   // 1 s alone; slower beside parallel tests, but under the 4 s handshake
    }

    @Test func stopFreesThePort() async throws {
        let server = try EchoServer(); let upstream = await server.start(); defer { server.stop() }
        let first = try await startedRelay(upstream: upstream)
        let port = first.localPort
        first.stop()
        try await Task.sleep(for: .milliseconds(200))
        let again = Relay(localIP: "127.0.0.1", localPort: port, remoteIP: "127.0.0.1", remotePort: upstream)
        try await again.start(); defer { again.stop() }
        #expect(await roundTrip(port: port, payload: Data("x".utf8)) == Data("x".utf8))
    }
}

// MARK: - Which bridge gets a tunnel port (#16)

@Test func tunnelPortsGoToTheirOwnDeviceOnly() {
    let a = UUID(), b = UUID()
    let two: [(id: UUID, udid: String?)] = [(a, phoneA), (b, phoneB)]
    #expect(TunnelCoordinator.recipient(owner: phoneB.lowercased(), subscribers: two, othersBridging: false) == b)
    #expect(TunnelCoordinator.recipient(owner: nil, subscribers: two, othersBridging: false) == nil)       // ambiguous: nobody
    #expect(TunnelCoordinator.recipient(owner: nil, subscribers: [(a, phoneA)], othersBridging: false) == a)
    #expect(TunnelCoordinator.recipient(owner: nil, subscribers: [(a, phoneA)], othersBridging: true) == nil)   // the app + a roamrun up
    // A bridge that hasn't learned its UDID yet takes an attributed port only when it's alone.
    #expect(TunnelCoordinator.recipient(owner: phoneB, subscribers: [(a, nil)], othersBridging: false) == a)
    #expect(TunnelCoordinator.recipient(owner: phoneB, subscribers: [(a, nil), (b, phoneA)], othersBridging: false) == nil)
    // Owner known and matched: other processes don't matter.
    #expect(TunnelCoordinator.recipient(owner: phoneA, subscribers: two, othersBridging: true) == a)
}

@Test func automaticInterfaceKeepsEn0() {
    #expect(InterfaceMonitor.pickLAN(chosen: nil, available: ["en0", "en1", "utun3"]) == "en0")     // unchanged for everyone with en0
    #expect(InterfaceMonitor.pickLAN(chosen: "", available: ["en10", "en2", "utun3"]) == "en2")     // e.g. a Mac mini on Ethernet
    #expect(InterfaceMonitor.pickLAN(chosen: "en5", available: ["en0"]) == "en5")                  // Settings wins
    #expect(InterfaceMonitor.pickLAN(chosen: nil, available: []) == "en0")
}

// MARK: - Profiles saved from two processes

@Test func theAppDoesntUndoAnEndpointRoamrunUpSaved() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let app = ProfileStore(directory: dir), cli = ProfileStore(directory: dir)
    var phone = profile("iPhone"), pad = profile("iPad")
    phone.providerIP = "100.64.0.10"
    pad.providerIP = "100.64.0.11"
    #expect(app.save(base: [], wanted: [phone, pad]) != nil)

    // The app keeps its list in memory from here on; `roamrun up` moves the phone.
    let held = [phone, pad]
    var moved = cli.load()
    moved[0].providerIP = "100.64.0.99"
    moved[0].remotePairingPort = 50000
    #expect(cli.save(base: cli.load(), wanted: moved) != nil)

    // Now the app saves for an unrelated reason: a rename of the *other* device.
    var stale = held
    stale[1].displayName = "iPad Pro"
    let saved = app.save(base: held, wanted: stale)
    #expect(saved?.first(where: { $0.id == phone.id })?.providerIP == "100.64.0.99")
    #expect(saved?.first(where: { $0.id == phone.id })?.remotePairingPort == 50000)
    #expect(saved?.first(where: { $0.id == pad.id })?.displayName == "iPad Pro")
    #expect(app.load() == saved)
}

@Test func thisProcessStillOwnsWhatItChangedAndWhoIsInTheList() {
    var phone = profile("iPhone"), pad = profile("iPad")
    phone.providerIP = "old"
    let base = [phone, pad]
    var onDisk = base
    onDisk[0].providerIP = "theirs"
    // Changed here too: ours wins, it is the newer intent.
    var mine = base
    mine[0].providerIP = "mine"
    #expect(ProfileStore.merge(base: base, wanted: mine, disk: onDisk)[0].providerIP == "mine")
    // Deleted here: the disk's copy doesn't come back.
    let without = ProfileStore.merge(base: base, wanted: [pad], disk: onDisk)
    #expect(without.map(\.id) == [pad.id])
    // Added here: kept, even though the disk has never seen it.
    let vision = profile("Vision")
    let added = ProfileStore.merge(base: base, wanted: base + [vision], disk: onDisk)
    #expect(added.map(\.id) == [phone.id, pad.id, vision.id])
}

@Test func aStatusProbeGetsOnlyTheTimeTheWaitHasLeft() {
    let now = Date.now
    #expect(CLI.probeSeconds(by: nil, now: now) == 10)                                  // no --wait: unchanged
    #expect(CLI.probeSeconds(by: now.addingTimeInterval(60), now: now) == 10)            // plenty: capped
    #expect(CLI.probeSeconds(by: now.addingTimeInterval(7), now: now) == 7)
    // devicectl refuses a --timeout below 5 with a usage error, so that's the floor.
    #expect(CLI.probeSeconds(by: now.addingTimeInterval(1), now: now) == 5)
    #expect(CLI.probeSeconds(by: now.addingTimeInterval(-5), now: now) == 5)             // past: still one try
    // --wait is only checked for being finite and non-negative, and Int(1e19) traps.
    #expect(CLI.probeSeconds(by: now.addingTimeInterval(1e19), now: now) == 10)
}

@Test func changingTheListUnderTheLockKeepsWhatAnotherProcessAdded() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProfileStore(directory: dir)
    var phone = profile("iPhone")
    phone.providerIP = "100.64.0.10"
    #expect(store.save(base: [], wanted: [phone]) != nil)
    // What `roamrun up` does. Reading the file first and merging afterwards would
    // drop a device the app added in between, since membership follows the caller.
    #expect(store.update { all in
        guard let i = all.firstIndex(where: { $0.id == phone.id }) else { return }
        all[i].providerIP = "100.64.0.99"
    })
    #expect(store.load().first?.providerIP == "100.64.0.99")
    // An id it doesn't know: nothing is changed, and nothing is lost either.
    #expect(store.update { all in
        guard let i = all.firstIndex(where: { $0.id == UUID() }) else { return }
        all[i].displayName = "never"
    })
    #expect(store.load().map(\.displayName) == ["iPhone"])
}

@Test func theBridgesOwnDetailIsSeparateFromTheLocalNetworkAdvice() {
    #expect(LocalNetwork.withoutAdvice("Opening relays") == "Opening relays")
    #expect(LocalNetwork.withoutAdvice(LocalNetwork.advice).isEmpty)
    #expect(LocalNetwork.withoutAdvice("Opening relays — " + LocalNetwork.advice) == "Opening relays")
}

@Test func aBlockedLocalNetworkAgesOutInsteadOfBeingCleared() {
    let now = Date.now
    #expect(!LocalNetwork.isDenied(last: nil, now: now))
    #expect(LocalNetwork.isDenied(last: now.addingTimeInterval(-5), now: now))
    #expect(!LocalNetwork.isDenied(last: now.addingTimeInterval(-300), now: now))
}
