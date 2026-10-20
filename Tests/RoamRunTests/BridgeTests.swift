import Foundation
import Testing
@testable import RoamRun

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


@Test func homeRuleBoundaries() {
    #expect(HomeRule.bridgingAdvert(nil, activatedAt: t0, now: t0 + 10) == nil)
    #expect(HomeRule.bridgingAdvert((instance: "A", at: t0), activatedAt: t0, now: t0 + 10) == nil)   // must be after going active
    #expect(HomeRule.bridgingAdvert((instance: "A", at: t0 + 1), activatedAt: t0, now: t0 + 91) == "A")   // 90 s still counts
}

@Test func automaticInterfaceKeepsEn0() {
    #expect(InterfaceMonitor.pickLAN(chosen: nil, available: ["en0", "en1", "utun3"]) == "en0")     // unchanged for everyone with en0
    #expect(InterfaceMonitor.pickLAN(chosen: "", available: ["en10", "en2", "utun3"]) == "en2")     // e.g. a Mac mini on Ethernet
    #expect(InterfaceMonitor.pickLAN(chosen: "en5", available: ["en0"]) == "en5")                  // Settings wins
    #expect(InterfaceMonitor.pickLAN(chosen: nil, available: []) == "en0")
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

@MainActor @Test func aStartStoppedWhileItAwaitedDoesntPutTheBridgeBack() {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bridge = ProxyBridge(profile: profile("iPhone"), statusDir: dir)
    let started = bridge.generation
    bridge.stop()   // Stop pressed while relocate() waited on Tailscale
    #expect(!bridge.step("Looking for the port", gen: started))
    #expect(bridge.state == .off)
    #expect(StatusFile.read(in: dir, live: { _ in true }).isEmpty)   // and it doesn't hold the device
    // The current start still reports its progress.
    #expect(bridge.step("Looking for the port", gen: bridge.generation))
    #expect(bridge.state == .starting("Looking for the port"))
    bridge.stop()
}

/// The table agreed before `Link` was written: every row is a case the reviews found.
/// (from, control open, heard, control gone for, probe, keep on cellular) → to
private let linkT0 = Date(timeIntervalSince1970: 1_000)
private let linkTable: [(String, Link, Bool, Bool, TimeInterval, Link.Probe?, Bool, Link)] = [
    ("control open, from anywhere", .waiting, true, false, 0, nil, false, .wifi),
    ("control back while paused", .paused(since: linkT0), true, true, 0, nil, false, .wifi),
    ("a Wi‑Fi flap", .wifi, false, true, 1, nil, false, .wifi),
    ("control just closed, device quiet", .wifi, false, false, 2, nil, false, .wifi),
    ("control gone 5 s, device quiet", .wifi, false, false, 5, nil, false, .waiting),
    ("cellular, device gone quiet", .cellular, false, false, 60, nil, true, .waiting),
    ("port answers: Wi‑Fi without a control channel", .wifi, false, true, 40, .answers, false, .wifi),
    ("port answers again after cellular", .cellular, false, true, 90, .answers, true, .wifi),
    ("port silent, Tailscale reaches it, setting off", .wifi, false, true, 40, .silentReachable, false, .paused(since: linkT0)),
    ("port silent, Tailscale reaches it, setting on", .wifi, false, true, 40, .silentReachable, true, .cellular),
    ("Tailscale can't reach it: never cellular", .wifi, false, true, 40, .unreachable, false, .wifi),
    ("waiting for the probe, no answer yet", .wifi, false, true, 40, nil, false, .wifi),
    ("setting turned off while on cellular", .cellular, false, true, 90, nil, false, .paused(since: linkT0)),
    ("paused: a redial is heard, setting on", .paused(since: linkT0 - 60), false, true, 90, nil, true, .paused(since: linkT0 - 60)),
    ("paused: device quiet", .paused(since: linkT0 - 60), false, false, 90, nil, false, .paused(since: linkT0 - 60)),
    ("paused: a probe that answers changes nothing either", .paused(since: linkT0 - 60), false, true, 90, .answers, false, .paused(since: linkT0 - 60)),
    ("cellular, setting off, device gone quiet: gone, not paused", .cellular, false, false, 90, nil, false, .waiting),
    ("waiting, heard, Tailscale can't reach it: still waiting", .waiting, false, true, 45, .unreachable, false, .waiting),
    ("heard again at exactly 30 s: wait for the probe", .waiting, false, true, 30, nil, false, .waiting),
    ("heard again just under 30 s", .waiting, false, true, 29.9, nil, false, .wifi),
    ("paused: a probe result changes nothing, setting on", .paused(since: linkT0 - 60), false, true, 90, .silentReachable, true, .paused(since: linkT0 - 60)),
    ("heard again soon after a drop", .waiting, false, true, 10, nil, false, .wifi),
    ("heard again after a long silence: wait for the probe (B)", .waiting, false, true, 40, nil, false, .waiting),
    ("…and the probe says cellular", .waiting, false, true, 45, .silentReachable, true, .cellular),
    ("…or Wi‑Fi", .waiting, false, true, 45, .answers, false, .wifi),
]

@Test(arguments: linkTable.indices)
func linkFollowsTheTable(_ row: Int) {
    let (name, from, open, heard, gone, probe, keep, to) = linkTable[row]
    let got = Link.next(from, .init(controlOpen: open, heard: heard, controlGoneFor: gone, probe: probe,
                                    keepOnCellular: keep, now: linkT0))
    #expect(got == to, "\(name): \(from) → \(got), expected \(to)")
}

/// Cellular needs a device the mesh still reaches. Only Tailscale can be pinged; with a
/// Manual IP mesh, the device's own bytes on the tunnel stand in — or a device on cellular
/// behind any other VPN would read as unreachable, and never be paused.
@Test func aSilentPortOnAnyMeshStillCountsAsReachedWhenTheDeviceTalks() async {
    let pinged = Counter()
    #expect(await ProxyBridge.stillReached(tailscale: false, heardJustNow: true, ping: { pinged.bump(); return .noPong }))
    #expect(!(await ProxyBridge.stillReached(tailscale: false, heardJustNow: false, ping: { pinged.bump(); return .pong })))
    #expect(pinged.value == 0)   // Manual IP: never a tailscale ping
    #expect(await ProxyBridge.stillReached(tailscale: true, heardJustNow: false, ping: { .pong }))
    #expect(!(await ProxyBridge.stillReached(tailscale: true, heardJustNow: true, ping: { .noPong })))
    // A ping that couldn't run (no CLI, it hung) says nothing: the device's bytes decide (2b: F2).
    #expect(await ProxyBridge.stillReached(tailscale: true, heardJustNow: true, ping: { .couldNotRun("no tailscale CLI") }))
    #expect(!(await ProxyBridge.stillReached(tailscale: true, heardJustNow: false, ping: { .couldNotRun("no tailscale CLI") })))
}

/// Paused on cellular, the stuck-renewal path never looks for the device elsewhere, however
/// long: before, after 30 minutes it scanned (over cellular, finding nothing) and failed.
@Test func pausedOnCellularNeverRelocates() {
    #expect(HomeRule.relocatesWhenStuck(renewals: 3, paused: false))
    #expect(!HomeRule.relocatesWhenStuck(renewals: 2, paused: false))
    #expect(!HomeRule.relocatesWhenStuck(renewals: 3, paused: true))
    #expect(!HomeRule.relocatesWhenStuck(renewals: 300, paused: true))
}

/// Last seen on cellular, a start doesn't scan over cellular for a port it won't find;
/// back on Wi‑Fi, or Start, it does again (2b review).
@MainActor @Test func aDeviceLastSeenOnCellularIsntScannedFor() async {
    let rig = Rig()
    defer { rig.done() }
    rig.bridge.memory.onCellular = true
    rig.world.answering = []; rig.world.ping = .pong
    await rig.bridge.start(.retry)
    #expect(rig.world.scans == 0 && rig.bridge.status == .error)
    await rig.bridge.start(.manual)                        // a person asked: look
    #expect(rig.world.scans == 1 && !rig.bridge.memory.onCellular)
}

/// "Last seen on cellular" ends where Wi‑Fi is proved: standing aside on this Mac's Wi‑Fi,
/// and with another device's memory (2b review).
@MainActor @Test func standingAsideOrAnotherDeviceForgetsCellular() async {
    let rig = Rig()
    defer { rig.done() }
    rig.bridge.memory.onCellular = true
    rig.world.onLAN = true
    await rig.bridge.start(.retry)
    #expect(rig.bridge.status == .local && !rig.bridge.memory.onCellular)
    let m = DeviceMemory()
    m.adopt("00008130-000D00000000D004"); m.onCellular = true
    m.adopt("00008101-000A00000000A001")
    #expect(!m.onCellular)
}

/// The status log follows what `status` says, change by change.
@MainActor @Test func eachStatusChangeIsSaidOnce() async {
    let rig = Rig()
    defer { rig.done() }
    #expect(rig.bridge.lastSaid == "off")
    rig.world.onLAN = true
    await rig.bridge.start(.retry)
    #expect(rig.bridge.status == .local && rig.bridge.lastSaid == "local")
    rig.bridge.stop()
    #expect(rig.bridge.lastSaid == "off")
    #expect(ProxyBridge.said(.ready, .cellular) == "ready/cellular" && ProxyBridge.said(.waiting, nil) == "waiting")
}

enum AfterReady: String, CaseIterable { case cellular, paused, stopped, helperDied }

/// From Ready on Wi‑Fi, the one line each change leaves — with what the relays showed
/// before it, and no "waiting" of teardown's own in between.
@MainActor @Test(arguments: AfterReady.allCases)
func whatFollowsReadyIsSaidAsOneChange(_ c: AfterReady) async {
    let rig = Rig()
    defer { rig.done() }
    var lines: [String] = []
    rig.bridge.onStatusLine = { lines.append($0) }
    await rig.bridge.start(.manual)
    rig.watcher.subscribers[rig.id]?.onPort(rig.bridge.profile.remotePairingPort + 2, "127.0.0.1")
    // Not all 17 of the window, necessarily: a parallel test's bridge may hold one of the ports.
    #expect(await eventuallyOnMain { rig.bridge.bindsInFlight == 0 && !rig.bridge.tunnelRelayPorts.isEmpty })
    let relays = rig.bridge.tunnelRelayPorts.count
    rig.bridge.setLinkForTests(.wifi)
    #expect(rig.bridge.status == .ready && lines.last?.contains("waiting -> ready/wifi") == true)
    lines = []
    switch c {
    case .cellular: rig.bridge.setLinkForTests(.cellular)
    case .paused: rig.bridge.setLinkForTests(.paused(since: rig.world.now))
    case .stopped: rig.bridge.stop()
    case .helperDied: rig.watcher.subscribers[rig.id]?.onExit("log stream exited")
    }
    let to = switch c {
    case .cellular: "ready/cellular"
    case .paused: "waiting/cellular"
    case .stopped: "off"
    case .helperDied: "error"
    }
    #expect(lines.count == 1, "\(c): \(lines)")
    #expect(lines.first?.contains("ready/wifi -> \(to) ") == true, "\(c): \(lines)")
    #expect(lines.first?.contains("of \(relays) tunnel relays") == true, "\(c): \(lines)")   // as they were before it
}

/// A new address that doesn't answer at the known port: scanned (it pings), and taken only
/// with the port the scan found there; a scan that finds nothing keeps the old address.
@MainActor @Test(arguments: [true, false])
func aNewAddressAndPortAreFoundTogether(scanFinds: Bool) async {
    var p = inertProfile("iPhone"); p.providerHostName = "iphone"
    let rig = Rig(p)
    defer { rig.done() }
    rig.world.answering = []
    rig.world.advertAnswers = false
    rig.world.ping = .pong
    let found = rig.bridge.profile.remotePairingPort + 20   // in this rig's own band
    rig.world.scan = scanFinds ? .found(found) : .notFound
    rig.world.peers = [MeshDevice(id: "1", name: "iphone", os: "iOS", ips: ["127.0.0.2"], online: true)]
    var saved: DeviceProfile?
    rig.bridge.onProfileChange = { saved = $0 }
    await rig.bridge.start(.manual)
    #expect(rig.world.scannedHost == "127.0.0.2")         // the new address is what was scanned
    if scanFinds {
        #expect(saved?.providerIP == "127.0.0.2" && saved?.remotePairingPort == found)
    } else {
        #expect(saved == nil && rig.bridge.profile.providerIP == "127.0.0.1")
    }
}

/// This Mac's Tailscale couldn't be asked twice in a row: the status says so, rather than
/// leaving it to read as the device's fault (2c: F34).
@MainActor @Test func aPingThatCantRunTwiceIsSaidInTheStatus() async {
    let rig = Rig()
    defer { rig.done() }
    rig.world.answering = []
    rig.world.ping = .couldNotRun("failed to connect to local Tailscale daemon")
    await rig.bridge.start(.manual)
    #expect(!(rig.entry()?.detail.contains("Tailscale on this Mac") ?? true))   // once: could be a blip
    await rig.bridge.start(.manual)
    #expect(rig.entry()?.detail.contains("Tailscale on this Mac couldn't be asked") == true)
    rig.world.ping = .noPong
    await rig.bridge.start(.manual)
    #expect(!(rig.entry()?.detail.contains("Tailscale on this Mac") ?? true))
    // Recovered with no ping made (the device answered straight away): no stale message.
    rig.world.ping = .couldNotRun("failed to connect to local Tailscale daemon")
    await rig.bridge.start(.manual); await rig.bridge.start(.manual)
    rig.world.answering = ["127.0.0.1"]
    await rig.bridge.start(.manual)
    #expect(rig.bridge.status == .waiting && !(rig.entry()?.detail.contains("Tailscale on this Mac") ?? true))
}

/// Recovered at a new address after two pings that couldn't run: the count starts over, so a
/// later error for another reason doesn't carry the stale Mac-side message (2c review).
@MainActor @Test func aRecoveryAtANewAddressClearsTheMacSideCount() async {
    var p = inertProfile("iPhone"); p.providerHostName = "iphone"
    let rig = Rig(p)
    defer { rig.done() }
    rig.world.answering = []
    rig.world.ping = .couldNotRun("failed to connect to local Tailscale daemon")
    await rig.bridge.start(.manual); await rig.bridge.start(.manual)
    #expect(rig.entry()?.detail.contains("Tailscale on this Mac") == true)
    rig.world.peers = [MeshDevice(id: "1", name: "iphone", os: "iOS", ips: ["127.0.0.2"], online: true)]
    rig.world.advertAnswers = true                          // RemotePairing answers at the new address
    await rig.bridge.start(.manual)
    #expect(rig.bridge.status == .waiting)
    rig.bridge.fail("something else")
    #expect(!(rig.entry()?.detail.contains("Tailscale on this Mac") ?? true))
}

/// A status write that failed is made again on the next tick, as things are then (2c: F39).
@MainActor @Test func aFailedStatusWriteIsMadeAgain() async throws {
    let rig = Rig()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.dir.path)
        rig.done()
    }
    await rig.bridge.start(.manual)
    try FileManager.default.removeItem(at: rig.dir.appendingPathComponent("status.lock"))
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: rig.dir.path)
    try #require(!FileManager.default.isWritableFile(atPath: rig.dir.path))   // not running as root
    rig.bridge.fail("the device went away")
    #expect(rig.bridge.statusWritePending)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.dir.path)
    rig.bridge.retryStatusWriteIfPending()
    #expect(!rig.bridge.statusWritePending)
    #expect(rig.entry()?.state == BridgeStatus.error.rawValue)
}

/// While bridging, the 10 s home check asks Tailscale's path (a ping) once a minute at
/// most; in between it doesn't stand aside on that score (2b: F32/F4).
@MainActor @Test func theBridgingHomeCheckPingsOnceAMinute() async {
    let rig = Rig()
    defer { rig.done() }
    await rig.bridge.start(.manual)
    #expect(rig.world.pathChecks == 1)                     // starting always looks
    for _ in 0..<12 {                                      // two minutes of 10 s ticks
        rig.world.now += 10
        rig.bridge.tick()
        #expect(await eventuallyOnMain { !rig.bridge.checkingHomeForTests })   // its check ran
    }
    #expect(rig.world.pathChecks == 3, "\(rig.world.pathChecks)")   // at 60 s and 120 s
}

// MARK: - A bridge with nothing real behind it (BridgeEnv)

/// Stands in for the shared remotepairingd watcher: the test feeds its subscriber.
@MainActor private final class FakeWatcher {
    var subscribers: [UUID: TunnelCoordinator.Subscriber] = [:]
}

/// Every field replaced: a bridge on this env runs no tool and reads no setting. Its relays
/// are real, listening on 127.0.0.1, but nothing is told to connect to them.
/// The device answers on its port unless `reachable` says otherwise.
@MainActor private func inertEnv(record: FakeRecord, watcher: FakeWatcher, reachable: Bool = true,
                                 now: @escaping @Sendable () -> Date = { .now }) -> BridgeEnv {
    var e = BridgeEnv()
    e.now = now
    e.relayClock = { Relay.continuousNow() }
    e.lanIPv4 = { "127.0.0.1" }
    e.keepOnCellular = { false }
    e.cliRunning = { false }
    e.localNetworkDenied = { false }
    e.checkTCP = { _, _ in reachable }
    e.findRemotePairingPort = { _ in .notFound }
    e.answers = { _ in false }
    e.isOnLAN = { _ in false }
    e.warmUp = { _ in Proc.Result(status: 0, out: "", err: "") }
    e.ping = { _ in .noPong }
    e.listDevices = { [] }
    e.recentAdvert = { _, _ in nil }
    e.killOrphanedHelpers = { 0 }
    e.subscribe = { id, s in watcher.subscribers[id] = s; return true }
    e.unsubscribe = { id in watcher.subscribers[id] = nil }
    e.makeRecord = { record }
    e.postClaim = { _ in }
    e.listenForClaims = {}
    return e
}

@MainActor @Test func aBridgeRunsEndToEndOnAnInertEnv() async {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let record = FakeRecord(), watcher = FakeWatcher()
    let p = inertProfile("iPhone")
    let bridge = ProxyBridge(profile: p, statusDir: dir, statusLive: { _ in true },
                             env: inertEnv(record: record, watcher: watcher))
    defer { bridge.stop() }
    await bridge.start(.manual)
    #expect(bridge.state.isActive)
    #expect(record.registered == 1)
    #expect(watcher.subscribers[p.id] != nil)
    // The watcher says remotepairingd resolved our record: the UDID is learned.
    watcher.subscribers[p.id]?.onDevice(p.instanceName, "00008130-000D00000000D004")
    #expect(bridge.udid == "00008130-000D00000000D004")
    bridge.tick()
    #expect(bridge.status == .waiting)   // no control channel through it
    bridge.stop()
    #expect(record.stopped >= 1)
    #expect(watcher.subscribers[p.id] == nil)
    #expect(StatusFile.read(in: dir, live: { _ in true })[p.id] == nil)
}

@MainActor @Test func aBridgeWithNoLANAddressSaysSoOnAnInertEnv() async {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let record = FakeRecord(), watcher = FakeWatcher()
    var env = inertEnv(record: record, watcher: watcher)
    env.lanIPv4 = { nil }
    let bridge = ProxyBridge(profile: inertProfile("iPhone"), statusDir: dir, statusLive: { _ in true }, env: env)
    defer { bridge.stop() }
    await bridge.start(.manual)
    #expect(bridge.status == .error)
    #expect(record.registered == 0)
}

// MARK: - How a bridge behaves today (1.5b): pinned before 1.6 / 2a / 2b change it

/// What the faked world answers; the test turns these between steps. Read from the env's
/// closures, which may run off the main actor, but never while the test writes them.
private final class World: @unchecked Sendable {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var answering: Set<String> = ["127.0.0.1"]   // hosts whose RemotePairing port answers
    var ping = TailscaleClient.Ping.noPong
    var onLAN = false
    var cli = false
    var lan: String? = "127.0.0.1"
    var advertAnswers = false
    var pathChecks = 0
    var scan = ReachabilityProbe.PortScan.notFound
    var scans = 0
    var scannedHost = ""
    var peers: [MeshDevice] = []
}

@MainActor private struct Rig {
    let world = World(), record = FakeRecord(), watcher = FakeWatcher()
    let dir = scratchDir()
    let bridge: ProxyBridge
    var id: UUID { bridge.profile.id }

    /// `keepPort`: a bridge rebuilt for a profile another rig ran keeps its endpoint.
    init(_ given: DeviceProfile = inertProfile("iPhone"), memory: DeviceMemory = DeviceMemory(), keepPort: Bool = false) {
        var p = given
        if !keepPort { p.remotePairingPort = Ports.band() }   // `given` may be one another rig runs
        var e = inertEnv(record: record, watcher: watcher)
        let w = world
        e.now = { w.now }
        e.lanIPv4 = { w.lan }
        e.checkTCP = { host, _ in w.answering.contains(host) }
        e.ping = { _ in w.ping }
        e.isOnLAN = { _ in w.pathChecks += 1; return w.onLAN }
        e.cliRunning = { w.cli }
        e.findRemotePairingPort = { host in w.scans += 1; w.scannedHost = host; return w.scan }
        e.listDevices = { w.peers }
        e.answers = { _ in w.advertAnswers }
        bridge = ProxyBridge(profile: p, statusDir: dir, statusLive: { _ in true }, env: e, memory: memory)
    }

    func entry() -> StatusFile.Entry? { StatusFile.read(in: dir, live: { _ in true })[id] }
    func done() { bridge.stop(); try? FileManager.default.removeItem(at: dir) }
}

enum StartCase: String, CaseIterable {
    case answers, onThisWiFi, silentAndUnreached, silentScanFindsNothing, silentScanTimesOut, silentScanFindsAPort,
         noLANAddress
}

/// start() from Off, one row per situation it meets.
@MainActor @Test(arguments: StartCase.allCases)
func startOutcomes(_ c: StartCase) async {
    let rig = Rig()
    defer { rig.done() }
    let found = rig.bridge.profile.remotePairingPort + 20   // in this rig's own band
    switch c {
    case .answers: break
    case .onThisWiFi: rig.world.onLAN = true
    case .silentAndUnreached: rig.world.answering = []
    case .silentScanFindsNothing: rig.world.answering = []; rig.world.ping = .pong
    case .silentScanTimesOut: rig.world.answering = []; rig.world.ping = .pong; rig.world.scan = .timedOut
    case .silentScanFindsAPort: rig.world.answering = []; rig.world.ping = .pong; rig.world.scan = .found(found)
    case .noLANAddress: rig.world.lan = nil
    }
    var saved: DeviceProfile?
    rig.bridge.onProfileChange = { saved = $0 }
    await rig.bridge.start(.manual)
    let expected: (BridgeStatus, registered: Int, scans: Int) = switch c {
    case .answers: (.waiting, 1, 0)
    case .onThisWiFi: (.local, 0, 0)
    case .silentAndUnreached: (.error, 0, 0)          // not pinged up: no scan
    case .silentScanFindsNothing, .silentScanTimesOut: (.error, 0, 1)
    case .silentScanFindsAPort: (.waiting, 1, 1)
    case .noLANAddress: (.error, 0, 0)
    }
    #expect(rig.bridge.status == expected.0, "\(c)")
    #expect(rig.record.registered == expected.registered, "\(c)")
    #expect(rig.world.scans == expected.scans, "\(c)")
    #expect(rig.bridge.autoRetry, "\(c)")              // none of these stops the retries
    if c == .silentScanFindsAPort {
        #expect(rig.bridge.profile.remotePairingPort == found && saved?.remotePairingPort == found)
    } else {
        #expect(saved == nil, "\(c)")
    }
}

/// A scan that found nothing, or ran out of time, isn't repeated for 10 minutes by an
/// automatic start; Start (and Find RemotePairing Port) scans regardless (2a: F3/R5). The
/// pause lives with the device's memory: a new device (removed and added again) scans at once.
@MainActor @Test(arguments: [ReachabilityProbe.PortScan.notFound, .timedOut])
func aFruitlessScanIsNotRepeatedForTenMinutesOnThisBridge(_ result: ReachabilityProbe.PortScan) async {
    let rig = Rig()
    defer { rig.done() }
    rig.world.answering = []; rig.world.ping = .pong; rig.world.scan = result
    await rig.bridge.start(.retry)
    #expect(rig.world.scans == 1)
    rig.world.now += 599
    await rig.bridge.start(.retry)
    #expect(rig.world.scans == 1)
    await rig.bridge.start(.manual)
    #expect(rig.world.scans == 2)                          // a person asked
    rig.world.now += 601
    await rig.bridge.start(.retry)
    #expect(rig.world.scans == 3)

    let fresh = Rig()
    defer { fresh.done() }
    fresh.world.answering = []; fresh.world.ping = .pong; fresh.world.scan = result
    await fresh.bridge.start(.manual)
    #expect(fresh.world.scans == 1)
}

/// Found under its Tailscale name at a new address: followed and saved.
/// Found under its Tailscale name at a new address: followed and saved only once RemotePairing
/// answers there (2c: F37); a name now on a device that doesn't answer leaves the address alone.
@MainActor @Test(arguments: [true, false])
func aDeviceWithANewTailscaleAddressIsFollowed(answersThere: Bool) async {
    var p = inertProfile("iPhone"); p.providerHostName = "iphone"
    let rig = Rig(p)
    defer { rig.done() }
    rig.world.answering = ["127.0.0.2"]
    rig.world.advertAnswers = answersThere                 // the RemotePairing handshake at the new address
    rig.world.peers = [MeshDevice(id: "1", name: "iphone", os: "iOS", ips: ["127.0.0.2"], online: true)]
    var saved: DeviceProfile?
    rig.bridge.onProfileChange = { saved = $0 }
    await rig.bridge.start(.manual)
    if answersThere {
        #expect(rig.bridge.status == .waiting)
        #expect(rig.bridge.profile.providerIP == "127.0.0.2" && saved?.providerIP == "127.0.0.2")
    } else {
        #expect(rig.bridge.status == .error)
        #expect(rig.bridge.profile.providerIP == "127.0.0.1" && saved == nil)
    }
    #expect(rig.world.scans == 0)
}

/// What the command line saved while the app runs is taken in as a save takes it, without one.
@Test func whatTheCommandLineSavedIsTakenInAsASaveTakesIt() {
    let a = inertProfile("iPhone")
    var b = a; b.instanceName += "-b"
    var c = a; c.instanceName += "-c"
    // Saved anew twice while the app saves nothing: the second is what it holds, and its next save keeps.
    let first = AppCoordinator.takenIn(disk: [b], saved: [a], mine: [a])
    #expect(first.profiles == [b] && first.changed == [b] && first.new.isEmpty)
    let second = AppCoordinator.takenIn(disk: [c], saved: first.base, mine: first.profiles)
    #expect(second.profiles == [c] && ProfileStore.merge(base: second.base, wanted: second.profiles, disk: [c]) == [c])
    // What the app changed and couldn't save stays, with what the command line changed.
    var mine = a; mine.providerIP = "100.64.0.99"
    let kept = AppCoordinator.takenIn(disk: [b], saved: [a], mine: [mine])
    #expect(kept.profiles.first?.providerIP == "100.64.0.99" && kept.profiles.first?.instanceName == b.instanceName)
    #expect(ProfileStore.merge(base: kept.base, wanted: kept.profiles, disk: [b]) == kept.profiles)
    // One never seen here comes in, and a save after keeps it.
    var other = inertProfile("iPad"); other.providerIP = "127.0.0.9"   // another device: another address
    let added = AppCoordinator.takenIn(disk: [other, a], saved: [a], mine: [a])
    #expect(added.new == [other] && added.profiles == [other, a] && added.changed.isEmpty)
    #expect(ProfileStore.merge(base: added.base, wanted: added.profiles, disk: [other, a]) == [other, a])
    // The app's own save read back: nothing to take in.
    let own = AppCoordinator.takenIn(disk: [a], saved: [a], mine: [a])
    #expect(own.new.isEmpty && own.changed.isEmpty)
}

/// A device saved again elsewhere: a running bridge is rebuilt now only where the device is somewhere
/// else; at the same address it stays up and is rebuilt at its next start (#163).
@Test func aRunningBridgeSavedAgainAtTheSameAddressWaitsForItsNextStart() {
    var held = profile("iPhone"); held.providerIP = "100.64.0.9"; held.remotePairingPort = 50000
    var announced = held; announced.instanceName = "renewed"; announced.txt["identifier"] = "another"; announced.udid = "00008130-000D00000000D004"
    var port = held; port.remotePairingPort = 51000
    var ip = held; ip.providerIP = "100.64.0.10"
    let rows: [(String, saved: DeviceProfile, running: DeviceProfile?, waits: Bool)] = [
        ("running, announcement and UDID saved anew", announced, held, true),
        ("off", announced, nil, false),
        ("running, another port", port, held, false),
        ("running, another address", ip, held, false),
    ]
    for row in rows {
        let decided = AppCoordinator.rebuilds([row.saved], running: row.running.map { [held.id: $0] } ?? [:])
        #expect(decided.atStart == (row.waits ? [held.id] : []), "\(row.0)")
        #expect(decided.now == (row.waits ? [] : [row.saved]), "\(row.0)")
    }
    // Two at once, each decided on its own.
    var other = profile("iPad"); other.providerIP = "100.64.0.11"
    var otherMoved = other; otherMoved.remotePairingPort = 51000
    let both = AppCoordinator.rebuilds([announced, otherMoved], running: [held.id: held, other.id: other])
    #expect(both.atStart == [held.id] && both.now == [otherMoved])

    // At its next start, the one waiting is rebuilt with what was saved; a start rebuilds nothing more.
    #expect(AppCoordinator.rebuiltAtStart(waiting: true, holding: held, saved: announced) == announced)
    #expect(AppCoordinator.rebuiltAtStart(waiting: false, holding: held, saved: announced) == nil)
    #expect(AppCoordinator.rebuiltAtStart(waiting: true, holding: announced, saved: announced) == nil)
    #expect(AppCoordinator.rebuiltAtStart(waiting: true, holding: held, saved: nil) == nil)   // deleted meanwhile
    #expect(AppCoordinator.rebuiltAtStart(waiting: true, holding: nil, saved: announced) == nil)
}

/// A host name two peers have isn't followed: without MagicDNS, iPhones share "iPhone".
@MainActor @Test func aNameTwoPeersHaveIsntFollowed() async {
    var p = inertProfile("iPhone"); p.providerHostName = "iPhone"
    let rig = Rig(p)
    defer { rig.done() }
    rig.world.answering = ["127.0.0.2", "127.0.0.3"]
    rig.world.advertAnswers = true
    rig.world.peers = [MeshDevice(id: "1", name: "iPhone", os: "iOS", ips: ["127.0.0.2"], online: true),
                       MeshDevice(id: "2", name: "iPhone", os: "iOS", ips: ["127.0.0.3"], online: true)]
    var saved: DeviceProfile?
    rig.bridge.onProfileChange = { saved = $0 }
    await rig.bridge.start(.manual)
    #expect(rig.bridge.profile.providerIP == "127.0.0.1" && saved == nil)
}

enum ClaimCase: String, CaseIterable {
    case erroredCLIAutomatic, erroredCLIManual, readyCLIManual, readyCLIFromACLI, erroredAppAutomatic, erroredCLIAutomaticFromACLI
}

/// Who gets a device another process's `roamrun up` has in its entry.
@MainActor @Test(arguments: ClaimCase.allCases)
func claimOutcomes(_ c: ClaimCase) async {
    let rig = Rig()
    defer { rig.done() }
    let held: BridgeStatus = [.readyCLIManual, .readyCLIFromACLI].contains(c) ? .ready : .error
    let other = StatusFile.Entry(pid: 4242, cli: c != .erroredAppAutomatic, udid: nil, status: held.title, detail: "",
                                 ready: held == .ready, tunnelPorts: [], updated: .now, state: held.rawValue)
    #expect(StatusFile.write(rig.id, other, in: rig.dir, live: { _ in true }) == .written)
    rig.world.cli = [.readyCLIFromACLI, .erroredCLIAutomaticFromACLI].contains(c)
    await rig.bridge.start([.erroredCLIAutomatic, .erroredAppAutomatic, .erroredCLIAutomaticFromACLI].contains(c) ? .retry : .manual)
    // Only the app's automatic start defers to a CLI; an errored entry is anyone's otherwise.
    let took = [.erroredCLIManual, .erroredAppAutomatic, .erroredCLIAutomaticFromACLI].contains(c)
    #expect(rig.bridge.status == (took ? .waiting : .error), "\(c)")
    #expect(rig.entry()?.pid == (took ? getpid() : 4242), "\(c)")
    #expect(rig.bridge.autoRetry == (c != .readyCLIFromACLI), "\(c)")   // a refused CLI gives up
}

/// The three ways retries stop today, and that any start() turns them back on.
@MainActor @Test func whatStopsTheRetriesAndWhatResumesThem() async {
    let rig = Rig()
    defer { rig.done() }
    await rig.bridge.start(.manual)
    rig.record.onExit?(1)                                   // dns-sd died
    #expect(await eventuallyOnMain { rig.bridge.status == .error })
    #expect(rig.bridge.autoRetry)

    await rig.bridge.start(.manual)
    rig.watcher.subscribers[rig.id]?.onExit("log stream exited (status 64): Must be admin to run 'stream' command")
    #expect(rig.bridge.status == .error && !rig.bridge.autoRetry)
    let blocked = rig.bridge.state
    for r in StartReason.allCases where r != .manual {
        await rig.bridge.start(r)
        #expect(!rig.bridge.autoRetry && rig.bridge.state == blocked, "\(r)")   // left as it was (2a)
    }
    await rig.bridge.start(.manual)
    #expect(rig.bridge.autoRetry)                           // only Start lifts it

    let mine = rig.bridge.profile.instanceName
    rig.watcher.subscribers[rig.id]?.onUnrecognized(mine)
    #expect(rig.bridge.state.isActive)                      // once can be a hiccup
    rig.world.now += 301
    rig.watcher.subscribers[rig.id]?.onUnrecognized(mine)
    #expect(rig.bridge.state.isActive)                      // too long after: counts as a first sighting again
    rig.world.now += 10
    rig.watcher.subscribers[rig.id]?.onUnrecognized(mine)
    #expect(rig.bridge.state.isActive)                      // the same announcement again
    rig.world.now += 20
    rig.watcher.subscribers[rig.id]?.onUnrecognized(mine)
    #expect(rig.bridge.status == .error && !rig.bridge.autoRetry)
}

/// A record answered by another device than the one saved: its UDID is never taken, and the
/// second sighting stops the bridge with the reason, instead of leaving it at Connecting.
@MainActor @Test func aRecordAnsweredByAnotherDeviceIsSaidNotFollowed() async {
    let saved = "00008130-000D00000000D004", other = "00008027-000E00000000E005"
    var profile = inertProfile("iPhone")
    profile.udid = saved
    let rig = Rig(profile)
    defer { rig.done() }
    await rig.bridge.start(.manual)
    let mine = rig.bridge.profile.instanceName
    rig.watcher.subscribers[rig.id]?.onDevice(mine, other)
    #expect(rig.bridge.state.isActive && rig.bridge.udid == saved)   // once can be a forged line
    rig.world.now += 10
    rig.watcher.subscribers[rig.id]?.onDevice(mine, other)
    #expect(rig.bridge.state.isActive)                               // the same announcement again
    rig.world.now += 5
    rig.watcher.subscribers[rig.id]?.onDevice(mine, saved)
    rig.world.now += 20
    rig.watcher.subscribers[rig.id]?.onDevice(mine, other)
    #expect(rig.bridge.state.isActive)                               // the saved one in between: counted anew
    rig.world.now += 301
    rig.watcher.subscribers[rig.id]?.onDevice(mine, other)
    #expect(rig.bridge.state.isActive)                               // too long after: a first sighting again
    rig.world.now += 20
    rig.watcher.subscribers[rig.id]?.onDevice(mine, other)
    #expect(rig.bridge.status == .error && !rig.bridge.autoRetry && rig.bridge.udid == saved)
    // The point of stopping is the reason: which device, what is wrong, what to do.
    guard case .error(let said) = rig.bridge.state else { Issue.record("no reason given"); return }
    #expect(said.contains("another device") && said.contains("Remove iPhone") && said.contains("add it again"))
}

/// Waiting with the record up: re-announce each minute; on the third, a device the mesh
/// reaches but whose port is shut has moved, so the bridge fails and the retry finds it.
@MainActor @Test(arguments: [TailscaleClient.Ping.noPong, .couldNotRun("no tailscale CLI"), .pong])
func renewalsWhileWaiting(ping: TailscaleClient.Ping) async {
    let meshReachesIt = ping == .pong   // today a ping that couldn't run counts as no answer (2b changes that)
    let rig = Rig()
    defer { rig.done() }
    await rig.bridge.start(.manual)
    #expect(rig.bridge.status == .waiting)
    rig.world.answering = []
    rig.world.ping = ping
    rig.bridge.tick()
    #expect(rig.record.renewed == 0)                        // within the first minute
    for n in 1...2 {
        rig.world.now += 61
        rig.bridge.tick()
        #expect(rig.record.renewed == n)
    }
    rig.world.now += 61
    rig.bridge.tick()
    if meshReachesIt {
        #expect(await eventuallyOnMain { rig.bridge.status == .error })
        #expect(rig.bridge.autoRetry)
    } else {
        #expect(await eventuallyOnMain { rig.record.renewed == 3 })   // asleep: keep nudging
        #expect(rig.bridge.status == .waiting)
    }
}

/// Back on this Mac's Wi‑Fi while bridged: the record goes, the bridge stands aside.
@MainActor @Test func aBridgedDeviceThatComesHomeStandsAside() async {
    let rig = Rig()
    defer { rig.done() }
    await rig.bridge.start(.manual)
    let stopsBefore = rig.record.stopped
    rig.world.onLAN = true
    rig.bridge.tick()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(rig.bridge.status == .waiting)                 // the path was asked at start: not again yet (2b)
    rig.world.now += 60
    rig.bridge.tick()
    #expect(await eventuallyOnMain { rig.bridge.status == .local })
    #expect(rig.record.stopped > stopsBefore)
    #expect(rig.entry()?.state == BridgeStatus.local.rawValue)
}

/// After the Mac wakes: re-announce at once, and the minute restarts from then.
@MainActor @Test func wakingReannouncesAndRestartsTheMinute() async {
    let rig = Rig()
    defer { rig.done() }
    await rig.bridge.start(.manual)
    rig.world.now += 50
    rig.bridge.nudgeAfterWake()
    #expect(rig.record.renewed == 1)
    rig.world.now += 30                                     // 80 s since start, 30 since the nudge
    rig.bridge.tick()
    #expect(rig.record.renewed == 1)
}

/// Renamed on Tailscale at the same address: the new name is followed and saved.
@MainActor @Test func aTailscaleRenameIsFollowed() async {
    var p = inertProfile("iPhone"); p.providerHostName = "iphone"
    let rig = Rig(p)
    defer { rig.done() }
    rig.world.answering = []
    rig.world.peers = [MeshDevice(id: "1", name: "iphone-2", os: "iOS", ips: ["127.0.0.1"], online: true)]
    var saved: DeviceProfile?
    rig.bridge.onProfileChange = { saved = $0 }
    await rig.bridge.start(.manual)
    #expect(rig.bridge.status == .error)                    // still silent, and not pinged up
    #expect(saved?.providerHostName == "iphone-2" && rig.bridge.profile.providerHostName == "iphone-2")
}

/// While bridged, the device's own advert (another instance, same UDID) that answers means
/// it is home — if the watcher saw it within 90 s. HomeObservation's TTL will change this.
@MainActor @Test(arguments: [false, true])
func anAdvertSeenWhileBridgedSendsItHome(stale: Bool) async {
    let rig = Rig()
    defer { rig.done() }
    await rig.bridge.start(.manual)
    let udid = "00008130-000D00000000D004"
    rig.watcher.subscribers[rig.id]?.onDevice(rig.bridge.profile.instanceName, udid)   // ours: learns the UDID
    rig.world.now += 1
    rig.watcher.subscribers[rig.id]?.onDevice("REAL-ADVERT", udid)
    rig.world.advertAnswers = true
    if stale { rig.world.now += 91 }
    rig.bridge.tick()
    if stale {
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.bridge.status == .waiting)
    } else {
        #expect(await eventuallyOnMain { rig.bridge.status == .local })
    }
}

/// Standing aside: three misses in a row before resuming, by an automatic start; and a
/// `roamrun up` watching the same device makes this one step back.
@MainActor @Test func standingAsideResumesAfterThreeMissesAndStepsBackForACLI() async {
    let rig = Rig()
    defer { rig.done() }
    rig.world.onLAN = true
    await rig.bridge.start(.manual)
    #expect(rig.bridge.status == .local)
    rig.world.onLAN = false
    await rig.bridge.resumeIfAway()
    await rig.bridge.resumeIfAway()
    #expect(rig.bridge.status == .local)
    await rig.bridge.resumeIfAway()
    #expect(rig.bridge.status == .waiting)

    let other = Rig()
    defer { other.done() }
    other.world.onLAN = true
    await other.bridge.start(.manual)
    let cli = StatusFile.Entry(pid: 4242, cli: true, udid: nil, status: BridgeStatus.local.title, detail: "", ready: false,
                               tunnelPorts: [], updated: .now, state: BridgeStatus.local.rawValue)
    var yieldedTo: Int32?
    other.bridge.onYield = { yieldedTo = $0.pid }
    _ = StatusFile.write(other.id, nil, in: other.dir, live: { _ in true })
    #expect(StatusFile.write(other.id, cli, in: other.dir, live: { _ in true }) == .written)
    await other.bridge.resumeIfAway()
    #expect(other.bridge.status == .off && yieldedTo == 4242)

    // The app's bridge is started again by the app, which rebuilds one saved anew meanwhile.
    let app = Rig()
    defer { app.done() }
    app.world.onLAN = true
    await app.bridge.start(.manual)
    var resumed = 0
    app.bridge.onResume = { resumed += 1 }
    app.world.onLAN = false
    for _ in 0..<3 { await app.bridge.resumeIfAway() }
    #expect(resumed == 1 && app.bridge.status == .local)
}

// MARK: - What a device's memory keeps across its bridges (1.6)

/// Another known device clears it; learning the UDID for the first time doesn't.
@MainActor @Test func aDeviceMemoryForgetsOnlyForAnotherDevice() {
    let m = DeviceMemory()
    let checked = Date(timeIntervalSinceReferenceDate: 800_000_000)
    m.homeAdvert = "ADVERT"; m.block = .pairingLost; m.lastFullCheck = checked
    m.pauseScans(of: "100.64.0.10:49152", until: .distantFuture)
    m.adopt("00008130-000D00000000D004")                 // first learned: the same device
    #expect(m.homeAdvert == "ADVERT" && !m.autoRetry && m.lastFullCheck == checked)
    #expect(m.scansPaused(of: "100.64.0.10:49152", now: .now))
    m.adopt("00008130-000d00000000d004")                 // case only
    #expect(m.homeAdvert == "ADVERT")
    m.adopt(nil)                                          // a profile without one says nothing
    #expect(m.udid == "00008130-000d00000000d004")
    m.adopt("00008101-000A00000000A001")                 // another device
    #expect(m.homeAdvert == nil && m.autoRetry && m.lastFullCheck == .distantPast)
    #expect(!m.scansPaused(of: "100.64.0.10:49152", now: .now))
    #expect(m.udid == "00008101-000A00000000A001")
}

/// A bridge rebuilt for the same device (an edited endpoint, a port found again) keeps
/// what the old one learned: the UDID, a block on retries, the device's advert name.
@MainActor @Test func aRebuiltBridgeKeepsWhatTheOldOneLearned() async {
    let memory = DeviceMemory()
    let first = Rig(memory: memory)
    await first.bridge.start(.manual)
    first.watcher.subscribers[first.id]?.onDevice(first.bridge.profile.instanceName, "00008130-000D00000000D004")
    first.watcher.subscribers[first.id]?.onExit("log stream exited (status 64): Must be admin")
    #expect(!first.bridge.autoRetry)
    first.done()

    let second = Rig(first.bridge.profile, memory: memory)   // the profile never saved the UDID
    defer { second.done() }
    #expect(second.bridge.udid == "00008130-000D00000000D004")
    #expect(!second.bridge.autoRetry)                      // still blocked
    await second.bridge.start(.edit)
    #expect(!second.bridge.autoRetry && second.record.registered == 0)   // an edit doesn't lift it (2a)
    await second.bridge.start(.manual)
    #expect(second.bridge.autoRetry && second.record.registered == 1)    // Start does
}

/// Standing aside, the device's advert found the slow way is what the next bridge tries
/// first, and a profile that names another device starts it over.
@MainActor @Test func aRebuiltBridgeKeepsTheAdvertUnlessTheDeviceChanged() async {
    let memory = DeviceMemory()
    var p = inertProfile("iPhone"); p.udid = "00008130-000D00000000D004"
    let first = Rig(p, memory: memory)
    first.world.onLAN = true
    await first.bridge.start(.manual)                     // standing aside
    memory.homeAdvert = "REAL-ADVERT"                     // what isHome learns from `log show`
    let checked = memory.lastFullCheck
    #expect(checked != .distantPast)                      // the stand-aside check ran the slow way
    first.done()

    let same = Rig(p, memory: memory)
    defer { same.done() }
    #expect(same.bridge.memory.homeAdvert == "REAL-ADVERT" && same.bridge.memory.lastFullCheck == checked)
    var other = p; other.udid = "00008101-000A00000000A001"
    let replaced = Rig(other, memory: memory)
    defer { replaced.done() }
    #expect(memory.homeAdvert == nil && memory.udid == "00008101-000A00000000A001")
}

/// The scan pause belongs to the endpoint: kept by a rebuilt bridge at the same address and
/// port, gone once either changes.
@MainActor @Test func theScanPauseFollowsTheEndpointAcrossBridges() async {
    let memory = DeviceMemory()
    let first = Rig(memory: memory)
    first.world.answering = []; first.world.ping = .pong
    await first.bridge.start(.manual)
    #expect(first.world.scans == 1)
    first.done()

    let same = Rig(first.bridge.profile, memory: memory, keepPort: true)
    same.world.answering = []; same.world.ping = .pong; same.world.now = first.world.now
    await same.bridge.start(.edit)
    #expect(same.world.scans == 0)                         // paused: same endpoint
    same.done()

    var moved = first.bridge.profile
    moved.remotePairingPort += 1
    let other = Rig(moved, memory: memory, keepPort: true)
    defer { other.done() }
    other.world.answering = []; other.world.ping = .pong; other.world.now = first.world.now
    await other.bridge.start(.edit)
    #expect(other.world.scans == 1)                        // another endpoint: not paused
}

/// A tunnel port far from the old window: the idle relays left behind are closed, and the
/// count of covered ports matches what listens.
/// Not tested here: a relay outside the window that still carries traffic stays. That needs a
/// device end that answers, which the faked env doesn't have.
@MainActor @Test func tunnelRelaysLeftBehindAreReaped() async {
    let rig = Rig()
    defer { rig.done() }
    await rig.bridge.start(.manual)
    let a = freeBase(in: 38_000...38_900, count: 140)
    let b = a + 20, far = a + 120
    rig.bridge.onTunnelPortDiscovered(a, localIP: "127.0.0.1")
    #expect(await eventuallyOnMain { rig.bridge.bindsInFlight == 0 && rig.bridge.tunnelRelayPorts.count == 17 })
    // A step ahead: the old ones are still inside newest-32…newest+16, so they stay.
    rig.bridge.onTunnelPortDiscovered(b, localIP: "127.0.0.1")
    #expect(await eventuallyOnMain {
        rig.bridge.bindsInFlight == 0 && rig.bridge.tunnelRelayPorts == Set(a...(a + 16)).union(b...(b + 16))
    })
    // A jump: everything idle outside the new window goes.
    rig.bridge.onTunnelPortDiscovered(far, localIP: "127.0.0.1")
    #expect(await eventuallyOnMain { rig.bridge.bindsInFlight == 0 && rig.bridge.tunnelRelayPorts.min() == far })
    #expect(rig.bridge.tunnelRelayPorts == Set(far...(far + 16)))
    guard case .active(let control, _) = rig.bridge.state else { Issue.record("not active"); return }
    #expect(rig.bridge.coveredPortsForTests == rig.bridge.tunnelRelayPorts.union([control]))
}

// MARK: - Start reasons and the shared supervisor (1.5c)

/// One table for what each reason may do (2a). Only Start lifts a retry block or takes from
/// a `roamrun up`; Find RemotePairing Port and Start skip the scan pause; what a person did,
/// or a new network, starts the retries short again; only a new address restarts.
@Test(arguments: StartReason.allCases)
func startPolicyTable(_ r: StartReason) {
    let p = StartPolicy.of(r)
    #expect(p.mayTakeFromCLI == (r == .manual), "\(r)")
    #expect(p.clears == (r == .manual ? Set(RetryBlock.allCases) : []), "\(r)")
    #expect(p.clearsScanPause == [.manual, .rescan].contains(r), "\(r)")
    #expect(p.resetsBackoff == [.manual, .rescan, .edit, .networkChange].contains(r), "\(r)")
    #expect(p.restarts == (r == .networkChange), "\(r)")
}

/// Retries wait longer after each failure in a row: 30 s, 1, 2, 4, 8 minutes, then 10.
@MainActor @Test func retriesBackOffUpToTenMinutes() {
    #expect((1...7).map { DeviceMemory.backoff(afterFailures: $0) } == [30, 60, 120, 240, 480, 600, 600])
    let m = DeviceMemory(), t = Date(timeIntervalSinceReferenceDate: 800_000_000)
    m.failed(at: t, unreachable: true); m.failed(at: t, unreachable: true)
    #expect(!m.retryDue(now: t + 59) && m.retryDue(now: t + 60))
    m.resetBackoff()
    #expect(m.retryDue(now: t) && m.failures == 0)
}

/// Waiting for a `roamrun up` to end, the start keeps what the strongest reason meant: a
/// rescan or an edit made meanwhile isn't lost to a plain retry.
@Test func aStartWaitingForTheCLIKeepsTheStrongestReason() {
    #expect(StartReason.stronger(.retry, .edit) == .edit)
    #expect(StartReason.stronger(.edit, .retry) == .edit)
    #expect(StartReason.stronger(.networkChange, .rescan) == .rescan)
    #expect(StartReason.stronger(.rescan, .edit) == .rescan)
    #expect(StartReason.stronger(.edit, .networkChange) == .networkChange)   // a tie: the later
    #expect(StartReason.stronger(.resume, .retry) == .retry)
}

/// The wait runs from when the failed attempt began (a tick), so it is never shorter than
/// the step it is on, however long the attempt took to fail.
@MainActor @Test func theWaitRunsFromTheAttemptsStart() {
    let m = DeviceMemory(), tick = Date(timeIntervalSinceReferenceDate: 800_000_000)
    m.failed(at: tick + 12, since: tick, unreachable: true)
    #expect(!m.retryDue(now: tick + 28) && m.retryDue(now: tick + 30))
    m.failed(at: tick + 40, since: tick + 30, unreachable: true)   // second: 60 s
    #expect(!m.retryDue(now: tick + 88) && m.retryDue(now: tick + 90))
}

/// Failing while up (a helper died, the device stopped answering), the first retry is the
/// next tick, as in 0.1.19, not 30 s from the failure, which misses that tick.
@MainActor @Test func failingWhileUpRetriesAtTheNextTick() async {
    let rig = Rig()
    defer { rig.done() }
    await rig.bridge.start(.retry)
    #expect(rig.bridge.memory.failures == 0)
    rig.bridge.fail("the log stream ended")
    #expect(rig.bridge.memory.failures == 1 && rig.bridge.memory.retryDue(now: rig.world.now))
}

/// A bridge that keeps failing to start counts it, and one that comes up starts over.
@MainActor @Test func aFailedStartGrowsTheWaitAndASuccessResetsIt() async {
    let rig = Rig()
    defer { rig.done() }
    rig.world.lan = nil                                      // no LAN address: every start fails
    await rig.bridge.start(.retry)
    await rig.bridge.start(.retry)
    await rig.bridge.start(.retry)
    #expect(rig.bridge.memory.failures == 3)
    #expect(!rig.bridge.memory.retryDue(now: rig.world.now + 119) && rig.bridge.memory.retryDue(now: rig.world.now + 120))
    rig.world.lan = "127.0.0.1"
    await rig.bridge.start(.retry)
    #expect(rig.bridge.status == .waiting && rig.bridge.memory.failures == 0)
}

/// The supervisor's tick: a bridge still in its wait isn't restarted, unless a cheap look
/// finds the port of a device that didn't answer answering again — then at once.
@MainActor @Test func theSupervisorWaitsOutTheBackoffButNotAnAnsweringPort() async {
    let rig = Rig()
    defer { rig.done() }
    rig.world.answering = []                                 // the device doesn't answer: unreachable
    await rig.bridge.start(.manual)
    await rig.bridge.start(.retry)                           // two failures: 60 s to wait
    #expect(rig.bridge.memory.failures == 2 && rig.bridge.memory.lastFailureUnreachable)
    var started: [StartReason] = []
    let sup = BridgeSupervisor(all: { [rig.bridge] }, wanted: { _ in true },
                               start: { _, r in started.append(r) }, now: { rig.world.now })
    sup.retry()
    try? await Task.sleep(for: .milliseconds(200))           // its look at the port, still shut
    #expect(started.isEmpty)
    rig.world.answering = ["127.0.0.1"]
    #expect(await eventuallyOnMain { sup.retry(); return started.contains(.retry) })
    #expect(rig.bridge.memory.failures == 0)
}

/// A failure on this Mac's side (here: no LAN address) isn't fixed by the device answering,
/// so its wait isn't cut short by a port that answers.
@MainActor @Test func aPortThatAnswersDoesntCutAWaitForThisMacsOwnFailure() async {
    let rig = Rig()
    defer { rig.done() }
    rig.world.lan = nil
    await rig.bridge.start(.manual)
    await rig.bridge.start(.retry)
    #expect(!rig.bridge.memory.lastFailureUnreachable)
    var started = 0
    let sup = BridgeSupervisor(all: { [rig.bridge] }, wanted: { _ in true },
                               start: { _, _ in started += 1 }, now: { rig.world.now })
    for _ in 0..<3 { sup.retry(); try? await Task.sleep(for: .milliseconds(50)) }
    #expect(started == 0)
    rig.world.now += 61
    sup.retry()
    #expect(started == 1)                                    // waited out, then retried
}

/// A failure just after a tick is still due on the tick its wait points at, not the one after
/// (the timer's drift is within the second of slack).
@MainActor @Test func aRetryIsntPushedToTheTickAfter() {
    let m = DeviceMemory(), tick = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let rig = Rig(memory: m)
    defer { rig.done() }
    rig.bridge.fail("down")                                  // errored, as it would be
    m.resetBackoff()
    m.failed(at: tick + 0.4, unreachable: true)              // the retry started at the tick failed soon after
    var started = 0
    let sup = BridgeSupervisor(all: { [rig.bridge] }, wanted: { _ in true },
                               start: { _, _ in started += 1 }, now: { tick + 30 })
    sup.retry()
    #expect(started == 1)
}

/// A blocked bridge stopped for a new address, or rebuilt: its start is turned away, it says
/// why again, and stays an error — so `roamrun up` still gives up instead of sitting at Off.
@MainActor @Test func aBlockedBridgeTurnedAwayKeepsItsErrorAndTheCLIStillGivesUp() async {
    let rig = Rig()
    defer { rig.done() }
    await rig.bridge.start(.manual)
    rig.watcher.subscribers[rig.id]?.onExit("log stream exited (status 64): Must be admin")
    guard case .error(let why) = rig.bridge.state else { Issue.record("not an error"); return }
    var gaveUp = 0
    let sup = BridgeSupervisor(all: { [rig.bridge] }, wanted: { _ in true }, start: { list, reason in
        for b in list {                                      // as roamrun up's start does
            if StartPolicy.of(reason).restarts { b.stop() }
            b.requestStart(reason)
        }
    }, gaveUp: { _ in gaveUp += 1 })
    sup.lanAddressChanged()
    #expect(await eventuallyOnMain { rig.bridge.state == .error(why) })
    sup.retry()
    #expect(gaveUp == 1)
}

/// Waking: whatever failed before the sleep, the next retry is a short wait again.
@MainActor @Test func wakingStartsTheRetriesShortAgain() async {
    let rig = Rig()
    defer { rig.done() }
    rig.world.lan = nil
    await rig.bridge.start(.manual)
    await rig.bridge.start(.retry)
    #expect(rig.bridge.memory.failures == 2)
    BridgeSupervisor(all: { [rig.bridge] }, wanted: { _ in true }, start: { _, _ in }).woke()
    #expect(rig.bridge.memory.failures == 0)
}

/// The claim follows the reason: against an errored `roamrun up` entry, the app's only Start
/// takes the device; a `roamrun up` takes it whatever the reason.
@MainActor @Test(arguments: StartReason.allCases, [false, true])
func claimByReason(_ r: StartReason, fromCLI: Bool) {
    let rig = Rig()
    rig.world.cli = fromCLI
    defer { rig.done() }
    let other = StatusFile.Entry(pid: 4242, cli: true, udid: nil, status: BridgeStatus.error.title, detail: "", ready: false,
                                 tunnelPorts: [], updated: .now, state: BridgeStatus.error.rawValue)
    #expect(StatusFile.write(rig.id, other, in: rig.dir, live: { _ in true }) == .written)
    let takes = fromCLI || r == .manual   // 2a: Find RemotePairing Port no longer takes (F16)
    #expect((rig.bridge.claimDevice(r) == .written) == takes, "\(r) fromCLI: \(fromCLI)")
}

/// Which bridges the supervisor hands back, and with which reason.
@MainActor @Test func theSupervisorRetriesRestartsPausesAndNudgesTheRightBridges() async {
    let on = Rig(), off = Rig(), stuck = Rig(), active = Rig()
    defer { [on, off, stuck, active].forEach { $0.done() } }
    for r in [on, off, stuck] { r.world.lan = nil; await r.bridge.start(.manual) }   // errored: no LAN address
    await active.bridge.start(.manual)
    // A block retrying can't clear, on `stuck`: no admin rights for `log stream`.
    stuck.world.lan = "127.0.0.1"
    await stuck.bridge.start(.manual)
    stuck.watcher.subscribers[stuck.id]?.onExit("log stream exited (status 64): Must be admin")
    #expect(!stuck.bridge.autoRetry && stuck.bridge.status == .error)

    var started: [(UUID, StartReason)] = []
    var gaveUp: [UUID] = []
    let wanted: Set<UUID> = [on.id, stuck.id, active.id]
    let sup = BridgeSupervisor(all: { [on.bridge, off.bridge, stuck.bridge, active.bridge] },
                               wanted: { wanted.contains($0.profile.id) },
                               start: { list, reason in started += list.map { ($0.profile.id, reason) } },
                               gaveUp: { gaveUp.append($0.profile.id) })
    sup.retry()
    #expect(started.map(\.0) == [on.id] && started.allSatisfy { $0.1 == .retry })   // not `off`: not left on
    #expect(gaveUp == [stuck.id])

    started = []
    sup.lanAddressChanged()
    #expect(Set(started.map(\.0)) == [on.id, stuck.id, active.id] && started.allSatisfy { $0.1 == .networkChange })

    let renewedBefore = active.record.renewed
    sup.woke()
    #expect(active.record.renewed == renewedBefore + 1)   // only an active one re-announces

    sup.lanAddressLost()
    #expect(active.bridge.status == .error)
    #expect(on.bridge.status == .error)                   // already errored: left as it was
}

/// Standing aside, the supervisor's 10 s look goes to resumeIfAway.
@MainActor @Test func theSupervisorLooksAgainAtBridgesStandingAside() async {
    let rig = Rig()
    defer { rig.done() }
    rig.world.onLAN = true
    await rig.bridge.start(.manual)
    rig.world.onLAN = false
    let sup = BridgeSupervisor(all: { [rig.bridge] }, wanted: { _ in true }, start: { _, _ in })
    // As the 10 s timer would: again and again until three misses in a row resume it. A look
    // while the last one still runs is skipped, as it is in the app.
    #expect(await eventuallyOnMain {
        sup.lookAgainIfAway()
        return rig.bridge.status == .waiting
    })
}
