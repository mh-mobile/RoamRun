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
        #expect(r.status == 0 && r.out == "hello\n")
        #expect(t < 2.5, "t=\(t)")   // it returns at once; the bound is for a busy machine
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
/// One request over a real socket, because `readHead`, the connection count and
/// `stop()` are the parts of OTAServer that only exist at runtime — and they are
/// the parts that were rewritten with nothing exercising them.
/// Sends `request` raw, reads until the server closes, returns what came back.
private func ask(_ port: UInt16, _ request: String, hold: TimeInterval = 0) async -> String? {
    let conn = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    defer { conn.cancel() }
    conn.start(queue: .global())
    if hold > 0 { try? await Task.sleep(for: .seconds(hold)) }
    if !request.isEmpty {
        conn.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
    }
    var got = Data()
    while got.count < 1 << 20 {
        let (chunk, done): (Data?, Bool) = await withCheckedContinuation { c in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, isDone, err in
                c.resume(returning: (d, isDone || err != nil))
            }
        }
        if let chunk { got.append(chunk) }
        if done { break }
    }
    return got.isEmpty ? nil : String(decoding: got, as: UTF8.self)
}

@Suite(.serialized) struct OTAServerOverASocket {
    private func started() throws -> (OTAServer, UInt16) {
        let server = OTAServer(tailnetPort: 41443)
        let port = try #require(server.start())
        return (server, port)
    }

    @Test func itAnswersOnlyTheMethodsAndRequestsItServes() async throws {
        let (server, port) = try started()
        defer { server.stop() }
        // A path it doesn't serve: nothing here touches stored builds.
        #expect(await ask(port, "GET /nope HTTP/1.1\r\nHost: m:41443\r\n\r\n")?.hasPrefix("HTTP/1.1 404") == true)
        #expect(await ask(port, "POST / HTTP/1.1\r\nHost: m:41443\r\n\r\n")?.hasPrefix("HTTP/1.1 405") == true)
        // Without a Host every link in the manifest would point the device at itself.
        #expect(await ask(port, "GET /nope HTTP/1.1\r\n\r\n")?.hasPrefix("HTTP/1.1 400") == true)
        #expect(await ask(port, "GET /nope HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n")?
            .hasPrefix("HTTP/1.1 400") == true)
        // A head that never ends.
        let huge = "GET /nope HTTP/1.1\r\nHost: m\r\nX: " + String(repeating: "y", count: 40_000) + "\r\n"
        #expect(await ask(port, huge)?.hasPrefix("HTTP/1.1 431") == true)
        // Still answering afterwards: none of those wedged it.
        #expect(await ask(port, "HEAD /nope HTTP/1.1\r\nHost: m:41443\r\n\r\n")?
            .hasPrefix("HTTP/1.1 404") == true)
    }

    @Test func aPeerThatSaysNothingLetsGoOfItsSlot() async throws {
        let (server, port) = try started()
        defer { server.stop() }
        // Eight is every connection there is, and a peer that connects and stays
        // quiet produces no callback to check a deadline in — which is why the
        // deadline is on the idle timer rather than inside the read loop.
        let silent = (0..<8).map { _ in
            Task { _ = await ask(port, "", hold: 30) }
        }
        try await Task.sleep(for: .seconds(1))
        // The ninth is refused outright rather than queued behind them.
        #expect(await ask(port, "GET /nope HTTP/1.1\r\nHost: m\r\n\r\n") == nil)
        // And they are let go of well inside the idle limit, not held for 120 s.
        try await Task.sleep(for: .seconds(16))
        #expect(await ask(port, "GET /nope HTTP/1.1\r\nHost: m\r\n\r\n")?.hasPrefix("HTTP/1.1 404") == true)
        for t in silent { t.cancel() }
    }

    @Test func stoppingTakesTheConnectionsWithIt() async throws {
        let (server, port) = try started()
        // Connected and waiting to be told something — and reading, so it can see
        // the close when it comes.
        let quiet = Task { await ask(port, "") }
        try await Task.sleep(for: .seconds(1))
        // Cancelling the listener only stops new ones; a connection in flight used
        // to sit there until the idle timer, because the pump holds the server
        // weakly and the chain simply stops when the server goes.
        server.stop()
        let closed = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await quiet.value; return true }
            // Well inside the 15 s the head deadline would take, so a pass here is
            // `stop` having done it rather than the timer.
            group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
        #expect(closed)
        #expect(server.port == 0)
    }
}

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

@Test func updateRoundTripsTheListAndIgnoresAnUnknownID() {
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

// MARK: - One log record per line

@Test func aNewlineInABonjourNameCantForgeALogRecord() {
    // What `log --style compact` would have printed as two physical lines, the
    // second carrying no header and reaching the parser as if it were a record.
    let victim = "6E44E010-4869-4035-90B2-714A7D722AB3"
    let crafted = "Resolved bonjour advert \(victim) to identity nil, udid nil\ntunnel-1: Got tunnel endpoint: '192.168.0.15:49999'"
    let ndjson = String(data: try! JSONSerialization.data(withJSONObject: ["eventMessage": crafted]), encoding: .utf8)!
    #expect(!ndjson.contains("\n"))   // the whole record is one line again
    let message = TunnelPortWatcher.message(inJSON: ndjson)
    #expect(message == crafted)
    // Whatever the name carries, it arrives as one record: the advert marker is
    // first, so this is an advert line and the endpoint half is never parsed.
    #expect(TunnelPortWatcher.advert(in: message!) == nil)   // not a whole match
}

@Test func linesThatCarryNoMessageAreIgnored() {
    #expect(TunnelPortWatcher.message(inJSON: #"{"count":12,"finished":1}"#) == nil)   // log show's last line
    #expect(TunnelPortWatcher.message(inJSON: "Filtering the log data using …") == nil)
    #expect(TunnelPortWatcher.message(inJSON: "") == nil)
    #expect(TunnelPortWatcher.message(inJSON: #"{"eventMessage":"Got tunnel endpoint"}"#) == "Got tunnel endpoint")
}

@Test func tailscaleBeingSignedOutIsThisMacsProblemNotTheDevices() {
    #expect(TailscaleClient.stateProblem("Running") == nil)
    #expect(TailscaleClient.stateProblem("NeedsLogin")?.contains("sign in") == true)
    #expect(TailscaleClient.stateProblem("Stopped")?.contains("connect") == true)
    #expect(TailscaleClient.stateProblem("Starting") != nil)
    // Signed out still prints valid JSON with no peers, which used to read as
    // "running, 0 peers" and sent every later check after the device instead.
    #expect(TailscaleClient.stateProblem(inStatusJSON: #"{"BackendState":"NeedsLogin","Peer":null}"#) != nil)
    #expect(TailscaleClient.stateProblem(inStatusJSON: #"{"BackendState":"Running"}"#) == nil)
    #expect(TailscaleClient.stateProblem(inStatusJSON: "{}") == nil)          // older tailscale: leave it be
    #expect(TailscaleClient.stateProblem(inStatusJSON: "not json") == nil)
}

// MARK: - Over-the-air builds

@Test func onlyBuildsIOSWillInstallOverTheAirAreAccepted() throws {
    func profile(_ entitlements: [String: Any], _ devices: [String]?) -> [String: Any] {
        var p: [String: Any] = ["Entitlements": entitlements]
        if let devices { p["ProvisionedDevices"] = devices }
        return p
    }
    let udid = "00008130-000C1C5C307A8D3A"
    let mine = [OTA.Device(name: "iPhone", udid: udid)]
    // Enterprise: no device list, installs anywhere.
    #expect(try OTA.check(["ProvisionsAllDevices": true, "Entitlements": [:]], against: mine).coverage == .everyDevice)
    // Ad Hoc for this device.
    #expect(try OTA.check(profile(["get-task-allow": false], [udid]), against: mine).coverage
            == .devices(covers: ["iPhone"], unchecked: []))
    // Which problem, not just "a problem": every one of these used to pass if the
    // build were rejected for some entirely different reason.
    #expect(throws: OTA.Problem.development("That build")) {
        try OTA.check(profile(["get-task-allow": true], [udid]), against: mine)
    }
    #expect(throws: OTA.Problem.appStore("That build")) { try OTA.check(["Entitlements": [:]], against: mine) }
    // A device list with no entitlements can't be told from a Development profile.
    #expect(throws: OTA.Problem.unreadable("the entitlements in That build's provisioning profile")) {
        try OTA.check(["ProvisionedDevices": [udid]], against: mine)
    }
    #expect(throws: OTA.Problem.unreadable(
        "the provisioning profile in That build — the archive may be unsigned. " +
        "Export it for Release Testing (Ad Hoc) or Enterprise.")) {
        try OTA.check(nil, against: mine)
    }
}

@Test func aBuildIsCheckedAgainstEveryDeviceBecauseThePageOffersItToAll() throws {
    // The page has no idea which device is asking, so "does it cover the one you
    // named" was never the question — this is which of yours can take it.
    let a = "00008130-000C1C5C307A8D3A", b = "00008120-001A2B3C4D5E6F70"
    let devices = [OTA.Device(name: "iPhone", udid: a),
                   OTA.Device(name: "iPad", udid: b),
                   OTA.Device(name: "Vision Pro", udid: nil)]   // never bridged, so unknown
    let adHoc: [String: Any] = ["ProvisionedDevices": [a], "Entitlements": ["get-task-allow": false]]
    #expect(try OTA.check(adHoc, against: devices).coverage
            == .devices(covers: ["iPhone"], unchecked: ["Vision Pro"]))
    let both: [String: Any] = ["ProvisionedDevices": [a, b], "Entitlements": ["get-task-allow": false]]
    #expect(try OTA.check(both, against: devices).coverage
            == .devices(covers: ["iPhone", "iPad"], unchecked: ["Vision Pro"]))
    // None of yours is an answer, not a refusal: the page is open to the whole
    // tailnet, and the profile may name a device this Mac has never seen.
    let other: [String: Any] = ["ProvisionedDevices": ["OTHER"], "Entitlements": ["get-task-allow": false]]
    #expect(try OTA.check(other, against: devices).coverage
            == .noneOfYours(known: ["iPhone", "iPad"], unchecked: ["Vision Pro"]))
    // Same when RoamRun knows no UDID at all, and when nothing is saved: neither
    // is a reason to refuse a build someone else's device can take.
    #expect(try OTA.check(adHoc, against: [devices[2]]).coverage
            == .noneOfYours(known: [], unchecked: ["Vision Pro"]))
    #expect(try OTA.check(adHoc, against: []).coverage == .noneOfYours(known: [], unchecked: []))
    // Enterprise needs no device at all — not even a saved one.
    #expect(try OTA.check(["ProvisionsAllDevices": true], against: []).coverage == .everyDevice)
}

@Test func theManifestPointsAtTheBuildItDescribes() throws {
    let build = OTA.Build(bundleID: "com.example.App", title: "App & Co", version: "1.2.0", build: "45",
                          added: .now, size: 3_200_000, slug: "1.2.0-45-20260928-0730")
    let data = try #require(OTA.manifest(for: build, base: "https://mac.tail1234.ts.net/roamrun"))
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    let item = (plist?["items"] as? [[String: Any]])?.first
    let url = ((item?["assets"] as? [[String: String]])?.first)?["url"]
    #expect(url == "https://mac.tail1234.ts.net/roamrun/com.example.App/\(build.slug)/app.ipa")
    let metadata = item?["metadata"] as? [String: String]
    #expect(metadata?["bundle-identifier"] == "com.example.App")
    #expect(metadata?["kind"] == "software")          // iOS refuses the manifest without it
    #expect(metadata?["bundle-version"] == "45")      // CFBundleVersion, not the marketing one
    #expect(metadata?["title"] == "App & Co")
    #expect(OTA.installLink(for: build, base: "https://x/p").hasPrefix("itms-services://?action=download-manifest&url=https://x/p/"))
}

@Test func aTitleXmlCantHoldNeverReachesTheManifest() throws {
    // `title` is CFBundleDisplayName, straight out of someone's .ipa. XML 1.0
    // has no way to carry most control characters, so this is the one input
    // that can make the manifest unserialisable — and a 200 with an empty body
    // is exactly the silent failure the whole feature exists to avoid.
    let odd = OTA.Build(bundleID: "com.example.App", title: "App\u{0}Name", version: "1.0", build: "1",
                        added: .now, size: 1, slug: "1.0-1-x")
    // Whether Foundation refuses such a title or emits it anyway depends on the
    // machine — this assertion, pinned to one of them, went red on CI. So the
    // characters don't reach it: the manifest is always produced and always
    // parses back, everywhere.
    let made = try #require(OTA.manifest(for: odd, base: "https://m.ts.net:41443"))
    let back = try PropertyListSerialization.propertyList(from: made, format: nil) as? [String: Any]
    let title = ((back?["items"] as? [[String: Any]])?.first?["metadata"] as? [String: String])?["title"]
    #expect(title == "AppName")
    #expect(OTA.printable("a\u{0}b\u{7}c") == "abc")
    #expect(OTA.printable("tab\tnewline\nfine") == "tab\tnewline\nfine")
    // And the page doesn't carry them either.
    #expect(!OTA.escape("App\u{0}Name").contains("\u{0}"))
    // An ordinary title is unaffected.
    let fine = OTA.Build(bundleID: "com.example.App", title: "App", version: "1.0", build: "1",
                         added: .now, size: 1, slug: "1.0-1-x")
    #expect(OTA.manifest(for: fine, base: "https://m.ts.net:41443") != nil)
}

@Test func thePageEscapesWhatCameFromTheArchive() {
    let build = OTA.Build(bundleID: "com.example.App", title: "<script>alert(1)</script>", version: "1.0", build: "1",
                          added: .now, size: 1)
    let html = OTA.indexHTML([(bundleID: "com.example.App", builds: [build])], base: "https://x/p")
    #expect(!html.contains("<script>alert"))
    #expect(html.contains("&lt;script&gt;"))
    #expect(html.contains("NEWEST"))
    #expect(OTA.indexHTML([], base: "https://x/p").contains("No builds yet"))
}

@Test func theServerWontServeAnythingOutsideItsOwnDirectory() {
    #expect(OTAServer.segments("/") == [])
    #expect(OTAServer.segments("/com.example.App/1.0-1-x/app.ipa") == ["com.example.App", "1.0-1-x", "app.ipa"])
    // A climb out has its dots dropped, so the path can no longer name a parent.
    #expect(OTAServer.segments("/../../etc/passwd") == ["etc", "passwd"])
    #expect(OTAServer.segments("/a/./b") == ["a", "b"])
    let (method, path, host) = OTAServer.request("GET /x/y?z=1 HTTP/1.1\r\nHost: mac.ts.net\r\n\r\n")
    #expect(method == "GET")
    #expect(path == "/x/y")
    #expect(host == "mac.ts.net")
    // Percent-encoding doesn't get a second chance to climb: appendingPathComponent
    // encodes rather than decodes, so these are ordinary names and miss everything.
    #expect(OTAServer.segments("/%2e%2e/%2e%2e/etc") == ["%2e%2e", "%2e%2e", "etc"])
    // The head is found from where the last receive stopped, less the three bytes
    // the terminator can straddle: a peer sending one byte at a time would
    // otherwise have the whole buffer rescanned on every one of them.
    let whole = Data("GET / HTTP/1.1\r\nHost: m\r\n\r\nbody".utf8)
    #expect(OTAServer.endOfHead(whole) == 23)
    #expect(OTAServer.endOfHead(whole, from: 20) == 23)        // straddling the boundary
    #expect(OTAServer.endOfHead(whole, from: 24) == nil)       // already past it
    #expect(OTAServer.endOfHead(Data("GET / HTTP/1.1\r\nHost: m\r\n".utf8)) == nil)
    #expect(OTAServer.endOfHead(Data()) == nil)
    // No Host, or two of them, and the manifest would send the device to itself.
    #expect(OTAServer.request("GET / HTTP/1.0\r\n").2 == nil)
    #expect(OTAServer.request("GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n").2 == nil)
}

@Test func theBiggestIconIsPickedAndTheIpadOneOnlyIfItIsAllThereIs() {
    // The page is read on a phone, so an iPad icon is the last resort.
    #expect(OTA.biggestIcon(["AppIcon60x60@2x.png", "AppIcon76x76@2x~ipad.png"]) == "AppIcon60x60@2x.png")
    #expect(OTA.biggestIcon(["AppIcon76x76@2x~ipad.png"]) == "AppIcon76x76@2x~ipad.png")
    // Higher scale wins at the same size, and a bigger source scales down well.
    #expect(OTA.biggestIcon(["AppIcon60x60@2x.png", "AppIcon60x60@3x.png"]) == "AppIcon60x60@3x.png")
    #expect(OTA.biggestIcon(["AppIcon40x40@2x.png", "AppIcon60x60@2x.png"]) == "AppIcon60x60@2x.png")
    #expect(OTA.biggestIcon([]) == nil)
}

@Test func twoFilesAreTheSameArchiveOnlyIfEveryByteMatches() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b"), c = dir.appendingPathComponent("c")
    // Bigger than the 1 MB read, so the whole file is really hashed.
    let payload = Data(repeating: 0x41, count: 3_000_000)
    try payload.write(to: a)
    try payload.write(to: b)
    try (payload + Data([0x42])).write(to: c)
    #expect(OTA.digest(of: a) == OTA.digest(of: b))
    #expect(OTA.digest(of: a) != OTA.digest(of: c))
    #expect(OTA.digest(of: dir.appendingPathComponent("missing")) == nil)
}

@Test func theLabelReplaceMatchesOnIsVersionAndBuildNumber() {
    // The label is what a reader sees, so it is what --replace collapses.
    func build(_ v: String, _ b: String) -> OTA.Build {
        .init(bundleID: "com.example.App", title: "App", version: v, build: b, added: .now, size: 1)
    }
    #expect(build("1.2.0", "45").label == "1.2.0 (45)")
    #expect(build("1.2.0", "").label == "1.2.0")          // no build number to show
    #expect(build("1.2.0", "1.2.0").label == "1.2.0")     // Xcode's default, not worth repeating
    #expect(build("1.2.0", "45").label != build("1.2.0", "46").label)
}

@Test func aSlugSurvivesBeingPutInAURLAndAFileName() {
    let when = Date(timeIntervalSince1970: 1_790_000_000)
    // Whatever a version string contains, the slug has to go into a URL and come
    // back unchanged. Asserted against ASCII directly, not against the same
    // predicate the implementation uses.
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    for version in ["1.0 beta", "1.0-テスト", "١٢", "a/b", "v#1", "100%"] {
        #expect(OTA.Build.slug(version: version, build: "45", at: when).allSatisfy(allowed.contains))
    }
    #expect(OTA.Build.slug(version: "1.2.0", build: "45", at: when).hasPrefix("1.2.0-45-"))
    #expect(!OTA.Build.slug(version: "a/b", build: "#", at: when).contains("/"))
    // UTC, so the name doesn't move when the Mac changes time zone.
    #expect(OTA.Build.slug(version: "1", build: "1", at: when) == "1-1-20260921-141320")
}

@Test func aBundleIdThatCouldNameSomewhereElseIsRefused() {
    #expect(OTA.isPlainName("com.example.App"))
    #expect(!OTA.isPlainName("../../../../tmp/x"))
    #expect(!OTA.isPlainName(".hidden"))          // invisible to everything that walks the directory
    #expect(!OTA.isPlainName("a/b"))
    #expect(!OTA.isPlainName(""))
    // A URL component too: `&` would end the itms-services query early, and
    // anything non-ASCII comes back percent-encoded and matches nothing.
    #expect(!OTA.isPlainName("com.foo&bar"))
    #expect(!OTA.isPlainName("com.foo?bar"))
    #expect(!OTA.isPlainName("com.フー"))
    #expect(OTA.isPlainName("com.example.my_app"))
}

@Test func onlyTheRootOfRoamRunsOwnPortCounts() {
    // One port, one handler. Everything else the user serves is untouched.
    let json = #"""
    {"Web":{"mac.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8788"},
                                          "/roamrun":{"Proxy":"http://127.0.0.1:1"}}},
            "mac.ts.net:41443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:61816"}}}}}
    """#
    let me = "mac.ts.net"
    #expect(TailscaleClient.serving(port: 41443, inJSON: json).root(on: me) == "http://127.0.0.1:61816")
    // The user's own port comes back with its other mounts named, so RoamRun can
    // tell "free" from "carrying something I must not remove".
    #expect(TailscaleClient.serving(port: 443, inJSON: json).root(on: me) == "http://127.0.0.1:8788")
    #expect(TailscaleClient.serving(port: 443, inJSON: json).alongside(me) == ["/roamrun"])
    #expect(TailscaleClient.serving(port: 9999, inJSON: json) == .nothing)
    // Not "nothing": a status we couldn't read is the moment RoamRun would
    // otherwise decide the port is free and overwrite an entry of the user's.
    #expect(TailscaleClient.serving(port: 41443, inJSON: "not json") == .unknown)
    #expect(TailscaleClient.serving(port: 41443, inJSON: "") == .unknown)
    #expect(TailscaleClient.serving(port: 41443, inJSON: "null") == .nothing)   // no serve config at all
    // A port with only a sub-path of the user's on it is not an empty port.
    #expect(TailscaleClient.serving(port: 41443, inJSON: #"{"Web":{"m:41443":{"Handlers":{"/mine":{}}}}}"#)
            == .mounted(roots: [], others: [.init(host: "m", path: "/mine")]))
    // Nor is one carrying a TCP forward, which has no Web entry at all: reading a
    // section we don't look at as "nothing here" is the same mistake one layer down.
    let forwarded = TailscaleClient.serving(port: 41443, inJSON: #"{"TCP":{"41443":{"TCPForward":"localhost:22"}}}"#)
    #expect(forwarded == .mounted(roots: [], others: [.init(host: nil, path: "TCP forwarding")]))
    // It belongs to the port, not to a name, so it is in the way whatever the
    // node is called — `tailscale` refuses to serve web on such a port at all.
    #expect(forwarded.alongside("any") == ["TCP forwarding"])
    // `{"HTTPS": true}` is what a plain https serve puts beside its Web entry.
    #expect(TailscaleClient.serving(port: 41443, inJSON: #"{"TCP":{"41443":{"HTTPS":true}}}"#) == .nothing)
    // An entry for the port whose inside we can't read is not an empty port —
    // reading it that way is how RoamRun would take one that is in use.
    #expect(TailscaleClient.serving(port: 41443, inJSON: #"{"Web":{"m:41443":{"Handlers":"?"}}}"#)
            .alongside("m") == ["m (unreadable)"])
    // Funnel is never something RoamRun turns on, and the port it picks can't be
    // published today — but that list is Tailscale's policy, and being wrong
    // about it means unreleased builds on the open internet.
    let funnelled = TailscaleClient.serving(port: 41443, inJSON:
        #"{"AllowFunnel":{"m:41443":true},"Web":{"m:41443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:1"}}}}}"#)
    #expect(funnelled.funnelled(on: "m"))
    #expect(!funnelled.funnelled(on: "other"))
    #expect(!TailscaleClient.serving(port: 41443, inJSON: #"{"AllowFunnel":{"m:41443":false}}"#).funnelled(on: "m"))
}

@Test func onlyTheMountUnderTheNameThisNodeAnswersToNowIsOurs() {
    // `tailscale serve` adds and removes under st.Self.DNSName and nothing else,
    // so after a rename our old entry is neither ours to replace nor ours to
    // remove — and the root sitting under the *current* name is someone else's.
    let renamed = #"""
    {"Web":{"old:41443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:61816"}}},
            "new:41443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9999"}}}}}
    """#
    let state = TailscaleClient.serving(port: 41443, inJSON: renamed)
    #expect(state == .mounted(roots: [.init(host: "new", target: "http://127.0.0.1:9999"),
                                      .init(host: "old", target: "http://127.0.0.1:61816")], others: []))
    // Ours is visible, but `off` would take the other one: that is not "ours is
    // still there", and answering yes is how the user's service gets deleted.
    #expect(state.root(on: "new") == "http://127.0.0.1:9999")
    #expect(state.root(on: "old") == "http://127.0.0.1:61816")
    // What sits under the old name blocks nothing: `serve` can't reach it and the
    // name no longer resolves, so it is inert config rather than a port in use.
    // Refusing to publish because of it would end the feature at a rename.
    #expect(state.alongside("new").isEmpty)
    #expect(state.alongside("old").isEmpty)
    #expect(state.root(on: "third") == nil)   // a name with nothing of its own
}

@Test func whetherOurRegistrationLandedIsNotAQuestionAboutOneName() {
    // `serve` writes under the name the node has when it runs, which need not be
    // the one we read a moment earlier. Asking only about the old name reads a
    // rename as "it didn't take" and throws away the proof of ownership.
    let state = TailscaleClient.serving(port: 41443, inJSON:
        #"{"Web":{"new:41443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:61816"}}}}}"#)
    #expect(state.root(on: "old") == nil)                      // the question we must not ask here
    #expect(state.isRegistered("http://127.0.0.1:61816"))      // the one we must
    #expect(!state.isRegistered("http://127.0.0.1:1"))
    #expect(!TailscaleClient.Serving.nothing.isRegistered("http://127.0.0.1:61816"))
}

@Test func lookingForLeftoversNeverStandsInFrontOfThePage() {
    // Both share one flag, so whichever asks first wins the tick. Asking
    // `otaServer == nil` had it backwards: at launch that is exactly the state
    // before publishing, so a leftover whose release kept failing kept the page
    // from ever going up.
    #expect(!AppCoordinator.shouldSweep(straysLeft: true, published: false, hasBuilds: true))
    // Published already: publishing won't run this tick, so looking is free.
    #expect(AppCoordinator.shouldSweep(straysLeft: true, published: true, hasBuilds: true))
    // Nothing to publish: same.
    #expect(AppCoordinator.shouldSweep(straysLeft: true, published: false, hasBuilds: false))
    #expect(AppCoordinator.shouldSweep(straysLeft: true, published: true, hasBuilds: false))
    // Nothing left to find.
    #expect(!AppCoordinator.shouldSweep(straysLeft: false, published: true, hasBuilds: false))
    #expect(!AppCoordinator.shouldSweep(straysLeft: false, published: false, hasBuilds: false))
}

@Test func anOwnershipTokenNamesThePortAsWellAsTheTarget() {
    // A loopback address on its own is recycled, and a registration made on a
    // port the app is no longer configured for can't be found to give back.
    #expect(AppCoordinator.token(41443, "http://127.0.0.1:61949") == "41443 http://127.0.0.1:61949")
    #expect(AppCoordinator.pair("41443 http://127.0.0.1:61949").port == 41443)
    #expect(AppCoordinator.pair("41443 http://127.0.0.1:61949").target == "http://127.0.0.1:61949")
    // Written before the port was part of it: still recognised, on any port.
    #expect(AppCoordinator.pair("http://127.0.0.1:61949").port == nil)
    #expect(AppCoordinator.pair("http://127.0.0.1:61949").target == "http://127.0.0.1:61949")
    // Not a token at all.
    #expect(AppCoordinator.pair("").target == "")
    #expect(AppCoordinator.pair("notaport http://x").port == nil)
}

@Test func aHostThatIsNotAHostNameNeverReachesAURL() {
    // It goes into the manifest's asset URL and the install link, where `%`,
    // `\` and `@` all mean something.
    #expect(OTAServer.hostLike("mac.ts.net") == "mac.ts.net")
    #expect(OTAServer.hostLike("mac.ts.net:41443") == "mac.ts.net:41443")
    #expect(OTAServer.hostLike("MAC-1.ts.net:80") == "MAC-1.ts.net:80")
    #expect(OTAServer.hostLike("evil.example/../x") == nil)
    #expect(OTAServer.hostLike("user@evil.example") == nil)
    #expect(OTAServer.hostLike("mac.ts.net:notaport") == nil)
    #expect(OTAServer.hostLike("mac.ts.net:99999") == nil)   // not a port
    #expect(OTAServer.hostLike("a%2f.ts.net") == nil)
    #expect(OTAServer.hostLike(":41443") == nil)
    #expect(OTAServer.hostLike(String(repeating: "a", count: 300)) == nil)
    // And the request parser is what applies it.
    #expect(OTAServer.request("GET / HTTP/1.1\r\nHost: user@evil.example\r\n").2 == nil)
}

@Test func aBuildWhoseMetadataCantBeReadIsNotABuildThatIsGone() throws {
    // The folder lists fine and only the metadata is unreadable: dropping it
    // silently serves "No builds yet" while the .ipa sits right there, and the
    // manifest URL a device already has answers 404.
    let root = otaScratch()
    let dir = root.appendingPathComponent("com.example.App/1.0-1-x")
    let meta = dir.appendingPathComponent("meta.json")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: meta.path)
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONEncoder().encode(build("1.0", "1", "1.0-1-x")).write(to: meta)
    #expect(OTA.builds(of: "com.example.App", in: root)?.count == 1)

    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: meta.path)
    try #require(!FileManager.default.isReadableFile(atPath: meta.path))
    #expect(OTA.builds(of: "com.example.App", in: root) == nil)
    #expect(OTA.builds(in: root) == nil)
    // Absent is still a build that was never finished, and still skipped.
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: meta.path)
    try FileManager.default.removeItem(at: meta)
    #expect(OTA.builds(of: "com.example.App", in: root)?.isEmpty == true)
}

@Test func aBuildFolderThatCantBeEnteredIsNotABuildThatIsGone() throws {
    // One level further in, where `fileExists` was being asked to tell absent
    // from unreadable — and it is false for both, which is why it was taken out
    // of `appDirectories` in the first place.
    let root = otaScratch()
    let dir = root.appendingPathComponent("com.example.App/1.0-1-x")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONEncoder().encode(build("1.0", "1", "1.0-1-x"))
        .write(to: dir.appendingPathComponent("meta.json"))
    #expect(OTA.builds(of: "com.example.App", in: root)?.count == 1)

    // The app folder still lists; only this one can't be entered.
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
    try #require(!FileManager.default.isReadableFile(atPath: dir.appendingPathComponent("meta.json").path))
    #expect(OTA.appDirectories(in: root) == ["com.example.App"])
    #expect(OTA.builds(of: "com.example.App", in: root) == nil)   // not `[]`, which serves "No builds yet"
    #expect(OTA.builds(in: root) == nil)
}

@Test func aPublishIsJudgedByTheConfigNotByTheExitCode() {
    // `tailscale serve --https` writes nothing and exits 0 when the tailnet has
    // no HTTPS certificates: it prints the admin link and calls os.Exit(0) before
    // touching any config. Reading that as success logged "serving builds over
    // the air" once a minute while nothing was served.
    let mine = "http://127.0.0.1:61816"
    let landed = TailscaleClient.serving(port: 41443, inJSON:
        #"{"Web":{"m:41443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:61816"}}}}}"#)
    #expect(landed.isRegistered(mine))
    // What that path actually leaves behind: no serve config at all.
    #expect(!TailscaleClient.serving(port: 41443, inJSON: "null").isRegistered(mine))
    #expect(TailscaleClient.serving(port: 41443, inJSON: "null") != .unknown)   // so it is a failure, not a maybe
    // And a status we couldn't read is neither.
    #expect(!TailscaleClient.serving(port: 41443, inJSON: "not json").isRegistered(mine))
    #expect(TailscaleClient.serving(port: 41443, inJSON: "not json") == .unknown)
}

@Test func aPortThatCantWorkIsIgnoredRatherThanRetriedForEver() {
    #expect(AppCoordinator.otaPort(0) == 41443)         // unset
    #expect(AppCoordinator.otaPort(41444) == 41443 + 1)
    #expect(AppCoordinator.otaPort(8443) == 41443)      // Funnel could publish it
    #expect(AppCoordinator.otaPort(80) == 41443)        // tailscaled is root and would take it
    #expect(AppCoordinator.otaPort(70000) == 41443)     // `tailscale serve` refuses it
}

@Test func aFolderThatCantBeReadIsNotAnEmptyOne() throws {
    // Deleting ota/ is the off switch; failing to read it is not, and treating
    // the two alike takes the page down under a download.
    let gone = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-absent-\(UUID().uuidString)")
    #expect((try? FileManager.default.contentsOfDirectory(atPath: gone.path)) == nil)
    #expect(!FileManager.default.fileExists(atPath: gone.path))   // so appDirectories would say []
}

@Test func anExpiredProfileOrAnUnknownUdidIsRefusedBeforeTheDeviceSeesIt() throws {
    let udid = "00008130-000C1C5C307A8D3A"
    let live: [String: Any] = ["ProvisionedDevices": [udid], "Entitlements": ["get-task-allow": false]]
    let mine = [OTA.Device(name: "iPhone", udid: udid)]
    #expect(throws: Never.self) { try OTA.check(live, against: mine) }
    // The expiry comes back so the page can mark a build that ran out since.
    var dated = live
    let when = Date(timeIntervalSinceNow: 86_400)
    dated["ExpirationDate"] = when
    #expect(try OTA.check(dated, against: mine).expires == when)
    // Expired: iOS would refuse it on the device with nothing to go on.
    var stale = live
    stale["ExpirationDate"] = Date(timeIntervalSinceNow: -86_400)
    #expect(throws: OTA.Problem.self) { try OTA.check(stale, against: mine) }
    // No UDID learned yet: the question can't be answered, so it comes back as
    // unanswered rather than as a refusal — the build may still be someone else's.
    #expect(try OTA.check(live, against: [OTA.Device(name: "iPhone", udid: nil)]).coverage
            == .noneOfYours(known: [], unchecked: ["iPhone"]))
    // Enterprise covers every device, so a missing UDID doesn't matter there.
    #expect(try OTA.check(["ProvisionsAllDevices": true], against: []).expires == nil)
}

@Test func aUdidTheCommandLineLearnedSurvivesTheAppSavingOverIt() {
    // The app can hold a profile it loaded before `roamrun up` learned the UDID.
    // Writing its own nil back leaves `roamrun ota` unable to say what a build
    // covers, on a device that has been bridged.
    let loaded = profile("iPhone")                     // what the app read: no UDID yet
    var onDisk = loaded
    onDisk.udid = "00008130-000C1C5C307A8D3A"          // what `roamrun up` wrote after that
    var renamed = loaded
    renamed.displayName = "iPhone mh"                  // the app changed something else
    #expect(ProfileStore.merge(base: [loaded], wanted: [renamed], disk: [onDisk]).first?.udid == onDisk.udid)
    // A UDID this process did change is this process's answer.
    var cleared = renamed
    cleared.udid = "OTHER"
    #expect(ProfileStore.merge(base: [loaded], wanted: [cleared], disk: [onDisk]).first?.udid == "OTHER")
}

@Test func aStoredBuildSurvivesThisStructGainingAField() throws {
    // What an older RoamRun wrote: no `slug`, no `devices`. Losing someone's
    // build because the schema moved is not an acceptable upgrade.
    let older = #"{"bundleID":"com.example.App","title":"App","version":"1.0","build":"7","added":760000000,"size":123}"#
    let build = try JSONDecoder().decode(OTA.Build.self, from: Data(older.utf8))
    #expect(build.bundleID == "com.example.App")
    #expect(build.label == "1.0 (7)")
    #expect(build.slug.isEmpty)   // the directory it was found in replaces this
    // And the other way: nothing but the bundle id is actually required.
    #expect(throws: Never.self) {
        try JSONDecoder().decode(OTA.Build.self, from: Data(#"{"bundleID":"com.example.App"}"#.utf8))
    }
}

@Test func metadataThatCantBeReadIsNotTheSameAsMetadataThatIsntThere() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let app = dir.appendingPathComponent("com.example.App")
    let kept = app.appendingPathComponent("1.0-1-20260101-0000")
    try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
    // Present but not decodable: a later version may understand it, so it stays.
    try Data("{".utf8).write(to: kept.appendingPathComponent("meta.json"))
    // Absent: an add that died before writing it, and nothing else would ever
    // remove the .ipa beside it.
    let gone = app.appendingPathComponent("1.0-2-20260101-0000")
    try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
    try Data("ipa".utf8).write(to: gone.appendingPathComponent("app.ipa"))

    // Through the production path, not a helper written for the test.
    #expect(OTA.builds(of: "com.example.App", in: dir)?.isEmpty == true)   // neither decodes
    // A read never deletes: it is answering a request from the tailnet, and a
    // build being written is exactly what it would take away.
    #expect(FileManager.default.fileExists(atPath: kept.path))
    #expect(FileManager.default.fileExists(atPath: gone.path))
    // A folder that isn't there at all is empty, not unreadable: deleting it is
    // the documented off switch.
    #expect(OTA.builds(of: "com.example.App", in: dir.appendingPathComponent("nope"))?.isEmpty == true)
    #expect(OTA.appDirectories(in: dir.appendingPathComponent("nope")) == [])
}

/// The write path had no tests at all, which is why every round of fixes here
/// arrived with a new fault. `in:` exists so these can run somewhere harmless.
private func otaScratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-ota-test-\(UUID().uuidString)")
}

private func fakeIPA(_ root: URL, _ bytes: String) throws -> String {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let at = root.appendingPathComponent("\(UUID().uuidString).ipa")
    try Data(bytes.utf8).write(to: at)
    return at.path
}

private func build(_ version: String, _ number: String, _ slug: String,
                   added: Date = .now, size: Int64 = 1) -> OTA.Build {
    OTA.Build(bundleID: "com.example.App", title: "App", version: version, build: number,
              added: added, size: size, expires: nil, slug: slug)
}

/// `sameArchive` filters on size before it hashes, so a Build whose size doesn't
/// describe the file it names can never match one — which is what `OTA.read`
/// guarantees in production and a test has to do for itself.
private func sized(_ path: String, _ b: OTA.Build) -> OTA.Build {
    var b = b
    b.size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64) ?? 0
    return b
}

@Test func storingTheSameArchiveTwiceMovesItBackUpInsteadOfStacking() throws {
    let root = otaScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let ipa = try fakeIPA(root.appendingPathComponent("src"), "one")
    let first = try OTA.add(ipa: ipa, sized(ipa, build("1.0", "1", "1.0-1-a", added: .distantPast)), in: root)
    #expect(OTA.builds(of: "com.example.App", in: root)?.count == 1)
    // Byte for byte the same: the row it already has, re-dated, not a second one.
    let again = try OTA.add(ipa: ipa, sized(ipa, build("1.0", "1", "1.0-1-b")), in: root)
    #expect(again.dir == first.dir)
    #expect(OTA.builds(of: "com.example.App", in: root)?.count == 1)
    #expect((OTA.builds(of: "com.example.App", in: root)?.first?.added ?? .distantPast) > .distantPast)
    // The same size, different bytes: the digest is what decides, so it stacks.
    let other = try fakeIPA(root.appendingPathComponent("src"), "two")
    _ = try OTA.add(ipa: other, sized(other, build("1.0", "1", "1.0-1-c")), in: root)
    #expect(OTA.builds(of: "com.example.App", in: root)?.count == 2)
}

@Test func nothingIsKeptBeyondTheLimitEvenWhenTheNewBuildSortsLast() throws {
    let root = otaScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    // `added` is taken before the lock, so a build that waited its turn can sort
    // behind every other one. Dropping it from the tail used to leave six.
    for i in 0..<OTA.keepPerApp {
        _ = try OTA.add(ipa: try fakeIPA(root.appendingPathComponent("src"), "n\(i)"),
                        build("1.\(i)", "1", "1.\(i)-1-x", added: .now), in: root)
    }
    #expect(OTA.builds(of: "com.example.App", in: root)?.count == OTA.keepPerApp)
    let late = try OTA.add(ipa: try fakeIPA(root.appendingPathComponent("src"), "late"),
                           build("0.9", "1", "0.9-1-x", added: .distantPast), in: root)
    let after = OTA.builds(of: "com.example.App", in: root) ?? []
    #expect(after.count == OTA.keepPerApp)
    #expect(after.contains { $0.slug == late.dir.lastPathComponent })   // the one just asked for stays
}

@Test func aBuildThatWasNeverFinishedIsReapedByTheNextWriteNotByAReader() throws {
    let root = otaScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("com.example.App")
    let orphan = app.appendingPathComponent("1.0-1-dead")
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    try Data("ipa".utf8).write(to: orphan.appendingPathComponent("app.ipa"))
    let stale = app.appendingPathComponent(".adding-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -7200)],
                                          ofItemAtPath: stale.path)
    // A reader leaves both alone: it is answering a request from the tailnet.
    _ = OTA.builds(of: "com.example.App", in: root)
    #expect(FileManager.default.fileExists(atPath: orphan.path))
    // The next add holds the lock, so it is the one that can safely clear them.
    _ = try OTA.add(ipa: try fakeIPA(root.appendingPathComponent("src"), "x"),
                    build("1.0", "2", "1.0-2-x"), in: root)
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
    #expect(!FileManager.default.fileExists(atPath: stale.path))
}

@Test func theOneDeleteInHereIsNotDecidedByFileExists() throws {
    // `reapOrphans` removes a build folder with no `meta.json`. Asking
    // `fileExists` for that answers the same for a folder that can't be entered,
    // and this is the only place in the feature that deletes someone's build.
    let root = otaScratch()
    let app = root.appendingPathComponent("com.example.App")
    let shut = app.appendingPathComponent("1.0-9-locked")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shut.path)
        try? FileManager.default.removeItem(at: root)
    }
    // One that really has no metadata, and one that can't be looked into.
    let orphan = app.appendingPathComponent("1.0-8-orphan")
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    try Data("ipa".utf8).write(to: orphan.appendingPathComponent("app.ipa"))
    try FileManager.default.createDirectory(at: shut, withIntermediateDirectories: true)
    try JSONEncoder().encode(build("1.0", "9", "1.0-9-locked"))
        .write(to: shut.appendingPathComponent("meta.json"))
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: shut.path)
    try #require(!FileManager.default.isReadableFile(atPath: shut.appendingPathComponent("meta.json").path))

    // `add` is what runs the reap, under the lock.
    _ = try? OTA.add(ipa: try fakeIPA(root.appendingPathComponent("src"), "x"),
                     build("2.0", "1", "2.0-1-x"), in: root)
    #expect(!FileManager.default.fileExists(atPath: orphan.path))   // never finished: reaped
    #expect(FileManager.default.fileExists(atPath: shut.path))      // unreadable: left alone
}

@Test func aFolderWithNoBuildsInItIsNotSomethingToPublish() throws {
    let root = otaScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("com.example.App")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    // What a failed first add leaves: the folder and the lock it took, nothing else.
    try Data().write(to: app.appendingPathComponent(".lock"))
    #expect(OTA.appDirectories(in: root) == [])          // so the page isn't published for it
    try FileManager.default.createDirectory(at: app.appendingPathComponent("1.0-1-x"),
                                            withIntermediateDirectories: true)
    #expect(OTA.appDirectories(in: root) == ["com.example.App"])
}

@Test func aFolderThatCantBeOpenedIsNotAnEmptyOne() throws {
    let root = otaScratch()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }
    let app = root.appendingPathComponent("com.example.App")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("1.0-1-x"),
                                            withIntermediateDirectories: true)
    try JSONEncoder().encode(build("1.0", "1", "1.0-1-x"))
        .write(to: app.appendingPathComponent("1.0-1-x/meta.json"))
    #expect(OTA.builds(in: root)?.count == 1)
    // `fileExists` is false both for a path that isn't there and for one whose
    // parent you can't get into, so it can't be what tells these apart.
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
    try #require(!FileManager.default.isReadableFile(atPath: root.path))   // not running as root
    #expect(OTA.appDirectories(in: root) == nil)
    #expect(OTA.builds(in: root) == nil)                 // the page answers 503, not "no builds yet"
}

@Test func anAppFolderThatCantBeOpenedIsNotAnAppThatIsGone() throws {
    // One level down, where `try?` used to turn "couldn't read it" back into
    // "there is no such app" — and an app vanishing from the list is how the
    // coordinator decides the off switch was pressed and takes the page down
    // under a download.
    let root = otaScratch()
    let app = root.appendingPathComponent("com.example.App")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: app.path)
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: app.appendingPathComponent("1.0-1-x"),
                                            withIntermediateDirectories: true)
    try JSONEncoder().encode(build("1.0", "1", "1.0-1-x"))
        .write(to: app.appendingPathComponent("1.0-1-x/meta.json"))
    #expect(OTA.appDirectories(in: root) == ["com.example.App"])

    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: app.path)
    try #require(!FileManager.default.isReadableFile(atPath: app.path))
    #expect(OTA.appDirectories(in: root) == nil)         // not `[]`, which reads as the off switch
    #expect(OTA.builds(in: root) == nil)
    #expect(OTA.builds(of: "com.example.App", in: root) == nil)
    // And `drop` says it couldn't look, rather than "there was nothing to remove".
    #expect(OTA.drop("com.example.App", labelled: "1.0 (1)", in: root) == nil)
}

@Test func replaceSaysSoWhenItCouldntReplace() throws {
    let root = otaScratch()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: root.appendingPathComponent("com.example.App").path)
        try? FileManager.default.removeItem(at: root)
    }
    let app = root.appendingPathComponent("com.example.App")
    let old = app.appendingPathComponent("1.0-1-old")
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    try JSONEncoder().encode(build("1.0", "1", "1.0-1-old")).write(to: old.appendingPathComponent("meta.json"))
    // A folder the old build can't be removed from: --replace didn't replace, and
    // reporting success would leave it on the page under the same version.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: app.path)
    try #require(!FileManager.default.isWritableFile(atPath: app.path))
    #expect(OTA.drop("com.example.App", labelled: "1.0 (1)", keeping: nil, in: root) == 1)
}

@Test func replaceDropsTheOtherBuildsOfThatVersionAndNothingElse() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let app = dir.appendingPathComponent("com.example.App")
    func store(_ version: String, _ number: String, _ slug: String, added: Date) throws {
        let at = app.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
        let build = OTA.Build(bundleID: "com.example.App", title: "App", version: version, build: number,
                              added: added, size: 1, expires: nil, slug: slug)
        try JSONEncoder().encode(build).write(to: at.appendingPathComponent("meta.json"))
    }
    try store("1.0", "1", "1.0-1-a", added: .now.addingTimeInterval(-60))
    try store("1.0", "1", "1.0-1-b", added: .now.addingTimeInterval(-30))
    try store("1.1", "1", "1.1-1-a", added: .now)
    #expect(OTA.builds(of: "com.example.App", in: dir)?.count == 3)
    // What --replace does: everything under that one label except the new build.
    #expect(OTA.drop("com.example.App", labelled: "1.0 (1)", keeping: "1.0-1-b", in: dir) == 0)
    #expect(OTA.builds(of: "com.example.App", in: dir)?.map(\.slug).sorted() == ["1.0-1-b", "1.1-1-a"])
}

@Test func aServeEntryOnlyCountsWhenSomethingIsBehindIt() async throws {
    // A crash leaves the serve entry pointing at a port nothing holds any more,
    // and `serve status` alone can't tell that from a working page.
    let server = try EchoServer()
    let port = await server.start()
    #expect(port > 0)
    #expect(TailscaleClient.listening(on: port))
    server.stop()
    #expect(try await eventually { !TailscaleClient.listening(on: port) })
}

@Test func aBuildWhoseProfileRanOutWhileItSatThereSaysSo() {
    // The check happens when it's stored; a profile lasts a year and builds are
    // kept for months, so the page is the only place left to say it.
    func page(_ expires: Date?) -> String {
        let build = OTA.Build(bundleID: "com.example.App", title: "App", version: "1.0", build: "1",
                              added: .now, size: 1, expires: expires, slug: "1.0-1-x")
        return OTA.indexHTML([(bundleID: "com.example.App", builds: [build])], base: "https://x/p")
    }
    #expect(page(.now.addingTimeInterval(-86_400)).contains("EXPIRED"))
    #expect(!page(.now.addingTimeInterval(86_400)).contains("EXPIRED"))
    #expect(!page(nil).contains("EXPIRED"))   // Enterprise profiles carry no date we act on
}

@Test func aPortOutsideFunnelsThreeCanNeverReachTheInternet() {
    // Funnel only publishes 443, 8443 and 10000, so a port outside them can't be
    // put on the internet by anyone — which is why RoamRun uses one.
    #expect(!AppCoordinator.funnelCapable.contains(AppCoordinator.otaPort))
    #expect(AppCoordinator.funnelCapable == [443, 8443, 10000])
}

@Test func aSlugNeverStartsWithADotOrTheBuildDisappears() {
    let when = Date(timeIntervalSince1970: 1_790_000_000)
    // `builds(of:)` skips dot-directories to keep a running add safe, so a
    // version like `.5` would store a build nothing could ever see again.
    for version in [".5", "..", ".", "-1"] {
        #expect(!OTA.Build.slug(version: version, build: "1", at: when).hasPrefix("."))
    }
    #expect(OTA.Build.slug(version: "1.0", build: "1", at: when).hasPrefix("1.0-"))
}

@Test func everyAddressRoamRunRegisteredStaysRecognisable() {
    // A registration that failed must leave the one before it still ours —
    // otherwise one bad command turns into a page that never comes back.
    var seen = AppCoordinator.remembering([], "port1")
    seen = AppCoordinator.remembering(seen, "port2")
    #expect(seen == ["port1", "port2"])
    // Asking again for one already there moves it to the end, it doesn't repeat.
    #expect(AppCoordinator.remembering(seen, "port1") == ["port2", "port1"])
    // Bounded, newest kept.
    var many: [String] = []
    for port in 1...9 { many = AppCoordinator.remembering(many, "port\(port)", keep: 5) }
    #expect(many == ["port5", "port6", "port7", "port8", "port9"])
}
