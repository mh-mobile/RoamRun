import Foundation
import Testing
@testable import RoamRun

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
        #expect(!StatusFile.mayReplace(entry(pid: 100, s), with: entry(pid: 200, .starting), by: 200, claim: true))
    }
}

@Test func otherProcessMayTakeOverErroredOrStandingAside() {
    for s in [BridgeStatus.error, .local] {
        #expect(StatusFile.mayReplace(entry(pid: 100, s), with: entry(pid: 200, .starting), by: 200, claim: true))
    }
}

@Test func ordinaryUpdatesNeverTakeAnotherOwnersEntry() {
    for held in [BridgeStatus.error, .local, .ready, .starting] {
        for next in [BridgeStatus.error, .local, .starting] {
            #expect(!StatusFile.mayReplace(entry(pid: 100, held), with: entry(pid: 200, next), by: 200))
        }
        #expect(!StatusFile.mayReplace(entry(pid: 100, held), with: nil, by: 200, claim: true))
    }
}

@Test func aReusedPIDIsNotTheProcessThatWroteTheEntry() {
    let mine = StatusFile.startTime(of: getpid())
    #expect(mine != nil) // the kernel knows when we started
    #expect(StatusFile.sameProcess(entry: mine, live: mine))
    #expect(StatusFile.sameProcess(entry: nil, live: mine)) // written before 0.1.13: can't tell, allow it
    #expect(!StatusFile.sameProcess(entry: mine, live: nil)) // that PID is gone
    #expect(!StatusFile.sameProcess(entry: mine, live: mine! + 60)) // same PID, a process that started later
    #expect(StatusFile.startTime(of: Int32.max) == nil) // no such process
}

@Test func otherProcessNeverClearsAnEntry() {
    for s in [BridgeStatus.ready, .error, .local] {
        #expect(!StatusFile.mayReplace(entry(pid: 100, s), with: nil, by: 200))
    }
}

@Test func stateKeysAndStatusTitlesStayFixed() {
    #expect(BridgeStatus.allCases.map(\.rawValue) == [
        "off",
        "starting",
        "waiting",
        "preparing",
        "ready",
        "error",
        "local"
    ])
    for s in BridgeStatus.allCases {
        #expect(BridgeStatus(title: s.title) == s)
    }
    // Written to status.json and read by other (possibly older) RoamRun processes.
    #expect(BridgeStatus.local.title == "On this Wi\u{2011}Fi")
    #expect(BridgeStatus.error.title == "Needs attention")
}

@Test func statusFileKeepsGoodEntriesNextToABadOne() throws {
    let good = StatusFile.Entry(
        pid: 1,
        cli: false,
        udid: nil,
        status: "Off",
        detail: "",
        ready: false,
        tunnelPorts: [],
        updated: .now
    )
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
    let cli = StatusFile.Entry(
        pid: 200,
        cli: true,
        udid: nil,
        status: "On this Wi\u{2011}Fi",
        detail: "",
        ready: false,
        tunnelPorts: [],
        updated: .now
    )
    var app = cli; app.cli = false
    #expect(HomeRule.yields(meCLI: false, myPID: 100, to: cli)) // the app yields to roamrun up
    #expect(!HomeRule.yields(meCLI: true, myPID: 300, to: app)) // roamrun up keeps it
    #expect(HomeRule.yields(meCLI: true, myPID: 300, to: cli)) // of two CLIs the newer steps back
    #expect(!HomeRule.yields(meCLI: true, myPID: 100, to: cli))
}

@Test func statusEntriesCarryAStableStateAndOldOnesStillRead() throws {
    var e = StatusFile.Entry(
        pid: 1,
        cli: false,
        udid: nil,
        status: "On this Wi\u{2011}Fi",
        detail: "",
        ready: false,
        tunnelPorts: [],
        updated: .now
    )
    #expect(e.kind == .local && !e.holdsDevice) // written by 0.1.7 and older: title only
    e.state = "ready"
    #expect(e.kind == .ready && e.holdsDevice) // the stable key wins
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
    let ids = (0 ..< 24).map { _ in
        UUID()
    }
    DispatchQueue.concurrentPerform(iterations: ids.count) { i in
        let e = StatusFile.Entry(pid: 1, cli: false, udid: nil, status: "Ready for Xcode", detail: "", ready: true,
                                 tunnelPorts: [], updated: .now, state: "ready")
        StatusFile.write(ids[i], e, in: dir, live: { _ in
            true
        })
    }
    #expect(StatusFile.read(in: dir, live: { _ in
        true
    })
    .count == ids.count)
    let mode = try FileManager.default
        .attributesOfItem(atPath: dir.appendingPathComponent("status.json").path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
}

@Test func writeSaysWhetherTheClaimIsOurs() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = UUID(), other: Int32 = getpid() + 1
    func e(_ pid: Int32, _ s: BridgeStatus) -> StatusFile.Entry {
        .init(
            pid: pid,
            cli: false,
            udid: nil,
            status: s.title,
            detail: "",
            ready: false,
            tunnelPorts: [],
            updated: .now,
            state: s.rawValue
        )
    }
    let live: StatusFile.Liveness = { _ in
        true
    }
    #expect(StatusFile.write(id, e(other, .ready), in: dir, live: live) == .written) // nobody held it
    // Healthy elsewhere: refused, and told who holds it — also for a later attempt.
    func holder(_ r: StatusFile.WriteResult) -> Int32? {
        if case .heldBy(let e) = r {
            e.pid
        } else {
            nil
        }
    }
    #expect(holder(StatusFile.write(id, e(getpid(), .starting), in: dir, live: live)) == other)
    #expect(holder(StatusFile.write(id, nil, in: dir, live: live)) == other)
    // Errored elsewhere: ours to take.
    let errored = UUID()
    #expect(StatusFile.write(errored, e(other, .error), in: dir, live: live) == .written)
    #expect(StatusFile.write(errored, e(getpid(), .starting), in: dir, live: live, claim: true) == .written)
    // A second profile for the same iPhone (same UDID) can't bridge it too; standing aside is fine.
    func withUDID(_ x: StatusFile.Entry) -> StatusFile
        .Entry
    {
        var x = x; x.udid = "00008130-000d00000000d004"; return x
    }
    let first = UUID(), second = UUID()
    #expect(StatusFile.write(first, withUDID(e(other, .ready)), in: dir, live: live) == .written)
    #expect(holder(StatusFile.write(second, withUDID(e(getpid(), .starting)), in: dir, live: live)) == other)
    #expect(StatusFile.write(second, withUDID(e(getpid(), .local)), in: dir, live: live) == .written)
    // Can't write at all: a failure, not a silent success.
    let file = dir.appendingPathComponent("not-a-dir"); try Data().write(to: file)
    if case .failed = StatusFile.write(id, e(getpid(), .starting), in: file, live: live) {}
    else {
        Issue.record("expected .failed")
    }
}

@Test func theAppLeavesADeviceToARunningRoamrunUp() {
    let me = getpid(), other: Int32 = 4242
    func entry(_ pid: Int32, cli: Bool?, _ s: BridgeStatus) -> StatusFile.Entry {
        .init(pid: pid, cli: cli, udid: nil, status: s.title, detail: "", ready: false, tunnelPorts: [],
              updated: .now, state: s.rawValue)
    }
    // Errored or standing aside, a live `roamrun up` retries by itself.
    #expect(HomeRule.leftToCLI(entry(other, cli: true, .error), myPID: me))
    #expect(HomeRule.leftToCLI(entry(other, cli: true, .local), myPID: me))
    #expect(!HomeRule.leftToCLI(entry(other, cli: false, .error), myPID: me))
    #expect(!HomeRule.leftToCLI(entry(me, cli: true, .error), myPID: me))
    #expect(!HomeRule.leftToCLI(nil, myPID: me))
}

/// Old status files have no network; `roamrun status` then shows none.
@Test func aStatusEntryWithoutANetworkDecodes() throws {
    let json = #"{"pid":1,"status":"Ready for Xcode","detail":"","ready":true,"tunnelPorts":[],"updated":0}"#
    let e = try JSONDecoder().decode(StatusFile.Entry.self, from: Data(json.utf8))
    #expect(e.deviceNetwork == nil)
    var cellular = e; cellular.network = "cellular"
    let back = try JSONDecoder().decode(StatusFile.Entry.self, from: JSONEncoder().encode(cellular))
    #expect(back.deviceNetwork == .cellular)
}

@Test func anAutomaticClaimNeverTakesARunningRoamrunUpsDevice() {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = UUID(), cliPID: Int32 = 4242
    func entry(_ pid: Int32, cli: Bool, _ s: BridgeStatus) -> StatusFile.Entry {
        .init(
            pid: pid,
            cli: cli,
            udid: nil,
            status: s.title,
            detail: "",
            ready: false,
            tunnelPorts: [],
            updated: .now,
            state: s.rawValue
        )
    }
    let live: StatusFile.Liveness = { _ in
        true
    }
    for held in [BridgeStatus.error, .local] {
        #expect(StatusFile.write(id, entry(cliPID, cli: true, held), in: dir, live: live) == .written)
        // The app on its own: refused, decided under the lock.
        if case .heldBy = StatusFile.write(
            id,
            entry(getpid(), cli: false, .starting),
            in: dir,
            live: live,
            claim: true,
            deferToCLI: true
        ) {} else {
            Issue.record("an automatic start took a \(held) roamrun up's device")
        }
        // Start pressed by a person may still take an errored / standing-aside one, as README says.
        #expect(StatusFile
            .write(id, entry(getpid(), cli: false, .starting), in: dir, live: live, claim: true) == .written)
        StatusFile.write(id, nil, in: dir, live: live)
    }
    // Only a CLI is deferred to: another app copy's errored entry is taken as before.
    #expect(StatusFile.write(id, entry(cliPID, cli: false, .error), in: dir, live: live) == .written)
    #expect(StatusFile.write(
        id,
        entry(getpid(), cli: false, .starting),
        in: dir,
        live: live,
        claim: true,
        deferToCLI: true
    ) == .written)
}

@MainActor @Test func aBridgeStartedAutomaticallyLeavesTheDeviceToRoamrunUp() {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let p = profile("iPhone")
    let live: StatusFile.Liveness = { _ in
        true
    }
    let cli = StatusFile.Entry(
        pid: 4242,
        cli: true,
        udid: nil,
        status: BridgeStatus.error.title,
        detail: "",
        ready: false,
        tunnelPorts: [],
        updated: .now,
        state: BridgeStatus.error.rawValue
    )
    #expect(StatusFile.write(p.id, cli, in: dir, live: live) == .written)
    let bridge = ProxyBridge(profile: p, statusDir: dir, statusLive: live)
    defer { bridge.stop() }
    // The claim an automatic start makes (restore, retry, resume), not start() itself:
    // that would ping and run devicectl on this Mac.
    if case .heldBy = bridge.claimDevice(.retry) {} else {
        Issue.record("an automatic claim took roamrun up's device")
    }
    #expect(StatusFile.read(in: dir, live: live)[p.id]?.pid == 4242) // still roamrun up's
}

@MainActor @Test func aManualClaimDoesntAuthorizeLaterUpdatesOrTeardownToTakeOver() {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let p = profile("iPhone")
    let live: StatusFile.Liveness = { _ in
        true
    }
    let bridge = ProxyBridge(profile: p, statusDir: dir, statusLive: live)
    defer { bridge.stop() }

    for held in [BridgeStatus.error, .local] {
        #expect(bridge.claimDevice(.manual) == .written)
        bridge.fail("the app's bridge is retryable")
        let cli = StatusFile.Entry(pid: 4242, cli: true, udid: nil, status: held.title, detail: "CLI's entry",
                                   ready: false, tunnelPorts: [], updated: .now, state: held.rawValue)
        #expect(StatusFile.write(p.id, cli, in: dir, live: live, claim: true) == .written)

        bridge.fail("a later status update")
        #expect(StatusFile.read(in: dir, live: live)[p.id] == cli)
        bridge.stop() // teardown publishes changes before the state becomes Off
        #expect(StatusFile.read(in: dir, live: live)[p.id] == cli)
        #expect(bridge.claimDevice(.retry) == .heldBy(cli))
        #expect(StatusFile.read(in: dir, live: live)[p.id] == cli)
        // A new Start action may still take over. Its later updates stay ours too.
        #expect(bridge.claimDevice(.manual) == .written)
        bridge.fail("owned update")
        #expect(StatusFile.read(in: dir, live: live)[p.id]?.detail == "owned update")
        bridge.stop()
        #expect(StatusFile.read(in: dir, live: live).isEmpty)
    }
}

@MainActor @Test func aRefusedAutomaticClaimDoesntPublishStartingBeforeCheckingItsTwin() {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    var p = profile("iPhone")
    p.udid = "00008130-000D00000000D004"
    let live: StatusFile.Liveness = { _ in
        true
    }
    let twin = UUID()
    let cli = StatusFile.Entry(pid: 4242, cli: true, udid: p.udid, status: BridgeStatus.error.title,
                               detail: "", ready: false, tunnelPorts: [], updated: .now,
                               state: BridgeStatus.error.rawValue)
    #expect(StatusFile.write(twin, cli, in: dir, live: live) == .written)
    let bridge = ProxyBridge(profile: p, statusDir: dir, statusLive: live)
    defer { bridge.stop() }
    #expect(bridge.claimDevice(.retry) == .heldBy(cli))
    #expect(StatusFile.read(in: dir, live: live) == [twin: cli])
}

@Test func anAutomaticStartLeavesATwinProfilesRoamrunUpAlone() {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let live: StatusFile.Liveness = { _ in
        true
    }
    let udid = "00008130-000D00000000D004", mine = UUID(), twin = UUID()
    func entry(_ pid: Int32, cli: Bool, _ s: BridgeStatus) -> StatusFile.Entry {
        .init(
            pid: pid,
            cli: cli,
            udid: udid,
            status: s.title,
            detail: "",
            ready: false,
            tunnelPorts: [],
            updated: .now,
            state: s.rawValue
        )
    }
    // `roamrun up` bridges the same iPhone through another saved profile, and is errored.
    #expect(StatusFile.write(twin, entry(4242, cli: true, .error), in: dir, live: live) == .written)
    if case .heldBy = StatusFile.write(
        mine,
        entry(getpid(), cli: false, .starting),
        in: dir,
        live: live,
        claim: true,
        deferToCLI: true
    ) {} else {
        Issue.record("an automatic start took a twin roamrun up's device")
    }
    #expect(StatusFile
        .write(mine, entry(getpid(), cli: false, .starting), in: dir, live: live, claim: true) ==
        .written) // Start pressed
    // And the app waits for it rather than retrying into the refusal.
    let entries = StatusFile.read(in: dir, live: live)
    #expect(HomeRule.cliHolding(UUID(), udid: udid.lowercased(), in: entries, myPID: getpid())?.pid == 4242)
    #expect(HomeRule.cliHolding(UUID(), udid: nil, in: entries, myPID: getpid()) == nil)
}
