import Foundation
import OSLog

/// Runs one device bridge end to end:
///
///   probe remote port → bind local TCP relays on en0 → publish a
///   `dns-sd -P` proxy record pointing remotepairingd at this Mac → watch the
///   log for the real tunnel port and relay that too.
///
/// remotepairingd still sees a Bonjour service on the discovery interface
/// (en0), so its interface-scoped connect succeeds — the bytes just continue
/// onward to the iPhone over the mesh VPN.
@MainActor
final class ProxyBridge: ObservableObject {
    @Published private(set) var state: BridgeState = .off
    /// How the device is connected; changes only through `evaluate()`.
    @Published private(set) var link = Link.waiting { didSet { if link != oldValue { linkChanged(from: oldValue) } } }
    /// A control channel through us, or a tunnel it set up that the device still answers on.
    var phoneConnected: Bool { link == .wifi || link == .cellular }
    /// Where the device is: nil while waiting; cellular also while paused there.
    var network: DeviceNetwork? {
        switch link {
        case .waiting: return nil
        case .wifi: return .wifi
        case .cellular, .paused: return .cellular
        }
    }
    var pausedOnCellular: Bool { if case .paused = link { true } else { false } }
    // Observations `evaluate()` and the renewals work from — not state of their own.
    private var controlGoneSince: Date?
    private var lastRenewal = Date.distantPast
    private var probingNetwork = false
    private var lastNetworkProbe = Date.distantPast
    private var lastHeldRenewal = Date.distantPast
    /// A tunnel has been negotiated at least once, so relays are primed.
    @Published private(set) var tunnelReady = false { didSet { publishStatus() } }

    private(set) var profile: DeviceProfile
    var onLog: ((String) -> Void)?
    /// Called when remotepairingd reports a (new) UDID for this device.
    var onUDID: ((String) -> Void)?
    /// Called when the bridge found the device at a new address or port; save it.
    var onProfileChange: ((DeviceProfile) -> Void)?
    /// Called after this bridge stopped because another process stands aside for the same device.
    var onYield: ((StatusFile.Entry) -> Void)?
    /// Learned from remotepairingd, or saved with the profile.
    var udid: String? { memory.udid }
    let memory: DeviceMemory

    /// False after an error retrying can't fix (unrecognized pairing) — the
    /// auto-retry loops leave it alone. Same-LAN / CLI-owner refusals stay
    /// retryable: they clear by themselves once the iPhone leaves or the CLI stops.
    var autoRetry: Bool { memory.autoRetry }

    private var dnsProxy: any BonjourRecord
    /// TCP only: since iOS 17.4 the CoreDevice tunnel is TCP (17.0–17.3 used
    /// QUIC over UDP, which RoamRun doesn't support).
    private var controlRelay: Relay?
    private var tunnelRelays: [UInt16: Relay] = [:]
    private var coveredPorts = Set<UInt16>()
    private var localPort: UInt16 = 0
    private(set) var generation = 0
    private var warmingUp = false
    private var renewTimer: Timer?
    /// From the claim on, while starting too: gives the device up if another process claimed it.
    private var claimTimer: Timer?
    private var checkingLAN = false
    // Home detection. Each signal is only trusted in the state it's valid in (HomeRule).
    /// When this bridge last went active; bridging trusts only adverts seen after it.
    private var activatedAt = Date.distantFuture
    /// Latest of the device's own adverts the watcher saw. Written only by the watcher.
    private var seenAdvert: (instance: String, at: Date)?
    /// Standing aside, consecutive checks that found the device away.
    private var awayTicks = 0
    /// Re-announcements in a row without a control channel.
    private var stuckRenewals = 0
    /// First "identity nil" for our record; a second one within minutes is believed.
    private var unrecognizedSince: Date?
    private static let homeLog = Logger(subsystem: AppID.bundle, category: "home")
    /// Lookahead hit/miss and port jumps (debug level): the data to retune +16 / -32
    /// if a future iOS allocates tunnel ports differently.
    private static let tunnelLog = Logger(subsystem: AppID.bundle, category: "tunnel")
    private var lastTunnelPort: UInt16?

    /// Spoofed SRV target whose A record we publish pointing at this Mac.
    var spoofHost: String {
        "rr-\(profile.id.uuidString.prefix(8).lowercased()).roamrun.local"
    }

    /// Where status.json lives, and which of its entries count as live; tests pass
    /// a scratch folder and owners that aren't RoamRun.app.
    private let statusDir: URL
    private let statusLive: StatusFile.Liveness
    private let env: BridgeEnv

    init(profile: DeviceProfile, statusDir: URL = ProfileStore.directory,
         statusLive: @escaping StatusFile.Liveness = StatusFile.isRoamRun, env: BridgeEnv = .live,
         memory: DeviceMemory = DeviceMemory()) {
        self.profile = profile
        self.memory = memory
        memory.adopt(profile.udid)
        self.statusDir = statusDir
        self.statusLive = statusLive
        self.env = env
        self.dnsProxy = env.makeRecord()
        Self.all.add(self)
        env.listenForClaims()
    }

    /// Every bridge in this process: they all listen on the same address, so a
    /// tunnel port one discovers may sit in another's lookahead window.
    private static let all = NSHashTable<ProxyBridge>.weakObjects()
    /// Ports given to another bridge here; a bind still in flight must not keep them.
    private var yielded = Set<UInt16>()
    /// This generation's binds under way, per port: one that fails must not uncover a
    /// port another is still binding. Reset with the rest at teardown.
    private var binding: [UInt16: Int] = [:]

    /// What it may do follows from `reason` (StartPolicy). One that may not take the device
    /// from a live `roamrun up` is refused when the claim is written, so it can't race a
    /// check made earlier.
    func start(_ reason: StartReason) async {
        let policy = StartPolicy.of(reason)
        generation += 1
        let gen = generation
        teardown()   // a failed or repeated start must not leave relays/timers behind
        warmingUp = false
        awayTicks = 0
        stuckRenewals = 0
        unrecognizedSince = nil
        lastTunnelPort = nil
        activatedAt = .distantFuture
        if policy.clearsRetryBlock { memory.autoRetry = true }
        if policy.clearsScanPause { memory.clearScanPause() }
        link = .waiting
        tunnelReady = false
        // One bridge per iPhone across processes — claimed here so every path
        // (Start, retries, restore, network change, CLI) goes through it. The
        // claim is one step under status.lock; only `.written` means it's ours.
        switch claimDevice(reason) {
        case .written:
            claimTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkClaim() }
            }
        case .heldBy(let other):
            yieldClaim(to: other, "is already bridging")
            return
        case .failed(let why):
            setState(.error("Couldn't record this bridge, so another RoamRun could start it too: \(why)"))
            return
        }
        // A SIGKILLed app or `roamrun up` leaves dns-sd advertising a dead relay.
        // Off the main actor: `ps` can take a while.
        let killOrphans = env.killOrphanedHelpers
        let killed = await Blocking.run { killOrphans() }
        guard gen == generation else { return }
        if killed > 0 { log("killed \(killed) leftover helper process(es)") }

        guard let localIP = env.lanIPv4() else {
            setState(.error(Self.noAddressMessage))
            return
        }

        // Home again? Xcode sees the real iPhone; a fake record would only collide.
        if await isHome() {
            guard gen == generation else { return }
            claimTimer?.invalidate()   // nothing held while standing aside
            claimTimer = nil
            setState(.local)
            log("on this Mac's network — standing aside until it leaves")
            return
        }
        guard gen == generation else { return }

        setState(.starting("Probing \(profile.providerIP):\(profile.remotePairingPort)"))
        var reachable = await env.checkTCP(profile.providerIP, profile.remotePairingPort)
        guard gen == generation else { return }   // stopped or restarted meanwhile
        if !reachable {
            let (moved, answers) = await relocate(gen: gen)
            guard gen == generation else { return }
            if moved.providerIP != profile.providerIP || moved.remotePairingPort != profile.remotePairingPort
                || moved.providerHostName != profile.providerHostName {
                // Only these: a rename in RoamRun during the (possibly long) lookup must survive.
                profile.providerIP = moved.providerIP
                profile.remotePairingPort = moved.remotePairingPort
                profile.providerHostName = moved.providerHostName
                onProfileChange?(profile)   // kept even if it doesn't answer right now
            }
            reachable = answers
        }
        guard gen == generation else { return }
        guard reachable else {
            setState(.error("\(profile.providerIP) did not respond on RemotePairing port \(profile.remotePairingPort) — the device may be locked or asleep (unlock it and keep the screen on), off Wi-Fi, or its mesh VPN may be off"))
            return
        }

        // Control channel: prefer the real port number (49152), fall back
        // to the next free ones if it is taken locally.
        setState(.starting("Opening relays"))
        var control: Relay?
        var lastError = ""
        let first = profile.remotePairingPort
        for port in first...UInt16(min(Int(first) + 20, Int(UInt16.max))) {
            do {
                control = try await bindRelay(localIP: localIP, localPort: port, remotePort: first) { [weak self] _ in
                    Task { @MainActor in self?.controlConnectionsChanged(gen: gen) }
                }
                break
            } catch {
                lastError = error.localizedDescription
            }
        }
        guard gen == generation else { control?.stop(); return }
        guard let control else {
            setState(.error("No usable local port: \(lastError)"))
            return
        }
        controlRelay = control
        localPort = control.localPort
        coveredPorts.insert(localPort)

        // Watch before publishing: remotepairingd resolves the record (and
        // logs the UDID the warm-up needs) within ~1s of it appearing.
        // Lines already queued when the bridge stops or restarts still arrive;
        // the generation check drops them.
        // One watcher per process routes each tunnel port to the bridge whose device asked for it.
        // Lines already queued when the bridge stops or restarts still arrive; the generation check drops them.
        let me = Weak(self)
        let subscribed = env.subscribe(profile.id, .init(
            udid: { me.value?.udid },
            onPort: { port, host in
                guard let self = me.value, gen == self.generation else { return }
                // Our relays answer on this Mac's en0 address; any other endpoint isn't ours to open.
                guard host == localIP else { return }
                self.onTunnelPortDiscovered(port, localIP: localIP)
            },
            onDevice: { instance, udid in
                guard let self = me.value, gen == self.generation else { return }
                self.onDeviceReachable(instance: instance, udid: udid)
            },
            onUnrecognized: { instance in
                guard let self = me.value, gen == self.generation else { return }
                self.onUnrecognized(instance)
            },
            onLog: { m in me.value?.log(m) },
            onExit: { m in me.value?.helperDied(m, gen: gen) }))
        dnsProxy.onExit = { [weak self] status in
            let what = status == -1 ? "dns-sd couldn't be replaced (the old registration didn't stop, or the new one didn't launch)"
                                    : "dns-sd exited (status \(status))"
            Task { @MainActor in self?.helperDied(what, gen: gen) }
        }
        guard subscribed else {
            teardown()
            setState(.error("Couldn't watch remotepairingd's log (see Activity log). Retrying shortly."))
            return
        }

        let previousGone = await dnsProxy.previousExited()
        guard gen == generation else { return }
        guard previousGone else {
            generation += 1   // drop late callbacks from this attempt
            teardown()
            setState(.error("The previous Bonjour registration didn't stop, so a second isn't published next to it. Retrying shortly."))
            return
        }
        setState(.starting("Publishing Bonjour proxy"))
        checkClaim()   // lost the device while starting? Don't advertise it next to its new owner.
        guard gen == generation else { return }
        do {
            try dnsProxy.register(instanceName: profile.instanceName,
                                  serviceType: profile.serviceType,
                                  domain: profile.domain,
                                  port: localPort,
                                  host: spoofHost,
                                  ip: localIP,
                                  txt: profile.txt)
            log("published \(profile.instanceName) -> \(localIP):\(localPort) via \(spoofHost)")
        } catch {
            generation += 1   // drop late callbacks from this attempt
            teardown()   // don't hold relays/watcher under an error another process may clear
            setState(.error(error.localizedDescription))
            return
        }

        activatedAt = env.now()
        setState(.active(localPort: localPort, tunnelPorts: []))
        log("bridge active: \(profile.providerIP) relayed locally on \(localIP):\(localPort)")
        lastRenewal = env.now()
        evaluate()   // a control channel may have opened while starting, when evaluate() ignores it
        renewTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// The 10 s check while active (internal: tests drive it instead of the timer).
    func tick() {
        evaluate()
        renewIfStuck()
        standAsideIfHome()
    }

    /// Takeover permission belongs to this claim, never to subsequent status updates.
    @discardableResult
    func claimDevice(_ reason: StartReason) -> StatusFile.WriteResult {
        state = .starting("Checking local interface")   // publish only with the claim's policy
        return publishStatus(claim: true, deferToCLI: !StartPolicy.of(reason).mayTakeFromCLI && !env.cliRunning())
    }

    /// A start's progress, unless that start was stopped or replaced while it
    /// awaited — writing then would put a stopped bridge back to Starting, or
    /// an active one back for good. False when stale.
    @discardableResult
    func step(_ what: String, gen: Int) -> Bool {
        guard gen == generation else { return false }
        setState(.starting(what))
        return true
    }

    /// Start from synchronous code. A stop() before the task gets to run wins.
    func requestStart(_ reason: StartReason) {
        let g = generation
        Task { guard g == generation else { return }; await start(reason) }
    }

    func stop() {
        generation += 1
        teardown()
        setState(.off)
        log("bridge stopped")
    }

    /// Releases everything a start acquired; safe to call when nothing is up.
    private func teardown() {
        renewTimer?.invalidate()
        renewTimer = nil
        claimTimer?.invalidate()
        claimTimer = nil
        env.unsubscribe(profile.id)
        dnsProxy.stop()
        controlRelay?.stop()
        controlRelay = nil
        for pair in tunnelRelays.values { pair.stop() }
        tunnelRelays = [:]
        coveredPorts = []
        yielded = []
        binding = [:]
        localPort = 0
        link = .waiting
        tunnelReady = false
        controlGoneSince = nil
        lastNetworkProbe = .distantPast
        lastHeldRenewal = .distantPast
    }

    /// `tunnelPort` nil is the control relay. A listener that dies once up is
    /// reported to relayFailed (for the generation that bound it).
    private func bindRelay(localIP: String, localPort: UInt16, remotePort: UInt16, tries: Int = 1,
                           tunnelPort: UInt16? = nil,
                           onOpenCountChange: ((Int) -> Void)? = nil) async throws -> Relay {
        let gen = generation
        var attempt = 1
        while true {
            let relay = Relay(localIP: localIP, localPort: localPort, remoteIP: profile.providerIP,
                              remotePort: remotePort, spare: tunnelPort != nil, clock: env.relayClock,
                              onOpenCountChange: onOpenCountChange,
                              onFailure: { [weak self] relay in Task { @MainActor in self?.relayFailed(relay, tunnelPort: tunnelPort, gen: gen) } })
            do {
                try await relay.start()
                return relay
            } catch {
                guard attempt < tries else { throw error }
                attempt += 1
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Takes `port` from the other bridges here that hold it only as an idle
    /// lookahead. True if one gave it up.
    private static func claim(_ port: UInt16, by me: ProxyBridge) -> Bool {
        all.allObjects.filter { $0 !== me }.reduce(false) { $1.yield(port) || $0 }
    }

    /// Other RoamRun processes on this Mac listen on the same address, and their
    /// idle lookahead can hold a port another process's device owns.
    static let claimNotification = Notification.Name(AppID.bundle + ".claimTunnelPorts")
    private static var listeningForClaims = false

    /// Tells the other RoamRun processes that bridge a device — the app, a `roamrun
    /// up` — that `window` is this device's. False when none does.
    private static func announceClaim(_ window: ClosedRange<UInt16>, statusDir: URL, live: StatusFile.Liveness,
                                      post: (String) -> Void) -> Bool {
        let me = getpid()
        guard StatusFile.read(in: statusDir, live: live).values.contains(where: { $0.pid != me && $0.holdsDevice }) else { return false }
        post("\(me) \(window.lowerBound)-\(window.upperBound)")
        return true
    }

    static func postClaim(_ text: String) {
        DistributedNotificationCenter.default().postNotificationName(claimNotification, object: text, userInfo: nil,
                                                                     deliverImmediately: true)
    }

    static func listenForClaims() {
        guard !listeningForClaims else { return }
        listeningForClaims = true
        DistributedNotificationCenter.default().addObserver(forName: claimNotification, object: nil, queue: .main) { note in
            let text = note.object as? String   // read before crossing into the main actor
            MainActor.assumeIsolated { _ = handleClaim(text, myPID: getpid()) }
        }
    }

    /// "<pid> <first>-<last>" from another process: its device owns those ports, so
    /// bridges here let go of the ones they hold only ahead. Anything else is ignored;
    /// a sender can take no more than an idle lookahead. How many were given (tests).
    @discardableResult
    static func handleClaim(_ text: String?, myPID: Int32) -> Int {
        guard let parts = text?.split(separator: " "), parts.count == 2,
              let pid = Int32(parts[0]), pid != myPID else { return 0 }
        let range = parts[1].split(separator: "-")
        guard range.count == 2, let lo = UInt16(range[0]), let hi = UInt16(range[1]),
              lo <= hi, hi - lo <= 16 else { return 0 }
        var given = 0
        for bridge in all.allObjects {
            let n = (lo...hi).filter { bridge.yield($0) }.count
            if n > 0 { bridge.log("gave \(n) tunnel port(s) from \(lo) to a device bridged by another RoamRun process (pid \(pid))") }
            given += n
        }
        return given
    }

    /// Another device's bridge found `port` to be its tunnel: let it go, unless a
    /// connection runs on it (then it is this device's after all).
    private func yield(_ port: UInt16) -> Bool {
        guard port != localPort, coveredPorts.contains(port) else { return false }
        if let relay = tunnelRelays[port] {
            guard relay.openCount == 0 else { return false }
            relay.stop()
            tunnelRelays[port] = nil
            if case .active(let lp, let existing) = state {
                setState(.active(localPort: lp, tunnelPorts: existing.filter { $0 != port }))
            }
        } else {
            yielded.insert(port)   // its bind is still in flight
        }
        coveredPorts.remove(port)
        return true
    }

    /// Tunnel ports whose relay is listening (tests).
    var tunnelRelayPorts: Set<UInt16> { Set(tunnelRelays.keys) }
    /// Ports counted as relayed or being bound (tests check it matches reality).
    var coveredPortsForTests: Set<UInt16> { coveredPorts }
    /// Relay binds still under way (tests wait for them to settle).
    var bindsInFlight: Int { binding.values.reduce(0, +) }

    /// remotepairingd connects ~5ms after logging the endpoint, so the port we
    /// just saw is always too late. The iPhone hands out tunnel ports
    /// sequentially, so pre-open the next ones for the retry.
    // ponytail: fixed lookahead of 16; widen if the device skips further ahead.
    func onTunnelPortDiscovered(_ port: UInt16, localIP: String) {   // internal for tests
        // Hit: a lookahead relay was already listening when remotepairingd dialed this port.
        let hit = tunnelRelays[port] != nil
        let jump = lastTunnelPort.map { Int(port) - Int($0) }
        lastTunnelPort = port
        Self.tunnelLog.debug("\(self.profile.displayName, privacy: .public): tunnel port \(port) \(hit ? "hit" : "miss", privacy: .public), jump \(jump.map(String.init) ?? "first", privacy: .public)")
        // The control relay fell back to a port above the device's own (it was taken
        // here) and the device now tunnels on that very number: it can't be relayed.
        if port == localPort {
            log("tunnel port \(port) is where this bridge's control relay listens (\(profile.remotePairingPort) was taken on this Mac), so that tunnel can't be relayed — free port \(profile.remotePairingPort) and reconnect")
        }
        // The device just said this port is its own: another bridge's idle lookahead
        // relay would hand remotepairingd's connection to the wrong iPhone.
        // So is the window after it: the next attempt dials one of those.
        let window = port...UInt16(min(Int(port) + 16, Int(UInt16.max)))
        yielded.subtract(window)
        let handedOver = Set(window.filter { Self.claim($0, by: self) })
        if !handedOver.isEmpty {
            log("took \(handedOver.count) tunnel port(s) from \(handedOver.min()!) held ahead by another device's bridge")
        }
        // Another RoamRun process (the app, a `roamrun up`) listens on this address too.
        let announced = Self.announceClaim(window, statusDir: statusDir, live: statusLive, post: env.postClaim)
        // First: if ports jumped (e.g. lower after a device reboot), the old window must go.
        let reaped = reapTunnelRelays(around: port)
        if !reaped.isEmpty, case .active(let lp, let existing) = state {
            setState(.active(localPort: lp, tunnelPorts: existing.filter { !reaped.contains($0) }))
        }
        let upper = UInt16(min(Int(port) + 16, Int(UInt16.max)))
        let ports = (port...upper).filter { !coveredPorts.contains($0) }
        guard !ports.isEmpty else { return }
        // Bounded whatever the log says; the window above keeps normal use near 49.
        // coveredPorts includes binds still in flight, and the control port (hence - 1).
        guard coveredPorts.count - 1 + ports.count <= 64 else { log("tunnel port \(port) ignored: 64 relays already open"); return }
        coveredPorts.formUnion(ports)
        log("live tunnel port \(port) discovered, relaying \(ports.first!)-\(ports.last!)")
        let gen = generation
        Task {
            var opened: [UInt16] = []
            var todo = ports, again: [UInt16] = []
            // Two passes when another process was asked to let go: the ports it still
            // held get one more try once the rest are up, so the usual case stays fast.
            for pass in 0..<(announced ? 2 : 1) {
                if pass == 1 {
                    guard !again.isEmpty else { break }
                    try? await Task.sleep(for: .milliseconds(300))
                    (todo, again) = (again, [])
                }
                for p in todo {
                    guard gen == generation else { return }   // restarted: coveredPorts is the new bridge's now
                    // A port just taken from another bridge frees once its listener is cancelled.
                    let tries = handedOver.contains(p) ? 20 : 1
                    binding[p, default: 0] += 1
                    let bound: Result<Relay, Error>
                    do { bound = .success(try await bindRelay(localIP: localIP, localPort: p, remotePort: p, tries: tries, tunnelPort: p)) }
                    catch { bound = .failure(error) }
                    // Counted per generation: teardown resets it, and a bind from a start that is
                    // gone touches neither the count nor coveredPorts (both are the new start's).
                    if gen == generation { binding[p] = binding[p, default: 1] > 1 ? binding[p]! - 1 : nil }
                    do {
                        let pair = try bound.get()
                        guard gen == generation else { pair.stop(); return }   // bridge stopped meanwhile
                        if yielded.remove(p) != nil { pair.stop(); continue }   // given away while binding
                        tunnelRelays[p] = pair
                        opened.append(p)
                        tunnelReady = true
                    } catch {
                        guard gen == generation else { return }
                        if pass == 0, announced, tunnelRelays[p] == nil, !yielded.contains(p) { again.append(p); continue }
                        yielded.remove(p)
                        // Still covered while a relay is on it (an earlier bind of the same port
                        // won) or another bind of it is under way (it was taken back meanwhile).
                        if tunnelRelays[p] == nil && binding[p] == nil { coveredPorts.remove(p) }
                        // Every bridge listens on the same address, so the usual cause is
                        // another device's bridge whose lookahead window covers this port.
                        log("failed to open relay for tunnel port \(p) — another device's bridge may already hold it: \(error.localizedDescription)")
                    }
                }
            }
            guard gen == generation else { return }   // restarted meanwhile: these ports aren't the new bridge's
            if case .active(let lp, let existing) = state {
                // Not one handed to another bridge while the rest were binding.
                setState(.active(localPort: lp, tunnelPorts: existing + opened.filter { tunnelRelays[$0] != nil }))
            }
        }
    }

    /// Tunnel ports move forward, so relays well behind the newest one — or
    /// ahead of it after a jump back — won't be dialed again. Close those
    /// that carry nothing: remotepairingd's standbys keep such a relay open but
    /// silent, so an old tunnel's relay would otherwise stay for good.
    // ponytail: fixed window of newest-32...newest+16; widen if old tunnels get reused.
    private func reapTunnelRelays(around newest: UInt16) -> Set<UInt16> {
        var reaped = Set<UInt16>()
        let window = (Int(newest) - 32)...(Int(newest) + 16)
        for (port, pair) in tunnelRelays where !window.contains(Int(port)) && (pair.openCount == 0 || pair.quiet(for: 300)) {
            pair.stop()
            tunnelRelays[port] = nil
            coveredPorts.remove(port)
            reaped.insert(port)
        }
        if !reaped.isEmpty { log("closed \(reaped.count) idle tunnel relays outside \(window.lowerBound)-\(window.upperBound)") }
        return reaped
    }

    /// The first tunnel after a bridge start always fails: we only learn the
    /// device's tunnel port from the log, ~5ms after remotepairingd already
    /// dialed it. Burn that attempt ourselves so the lookahead relays are up
    /// before the user's first Run.
    private func onDeviceReachable(instance: String, udid: String) {
        guard instance == profile.instanceName else {
            // The device's own advert, seen live while bridging: lets isHome skip `log show`.
            if let mine = self.udid, udid.caseInsensitiveCompare(mine) == .orderedSame {
                seenAdvert = (instance, env.now())
                memory.homeAdvert = instance
            }
            return
        }
        unrecognizedSince = nil   // recognized after all
        if udid != self.udid {
            // Learned once; a different one later is suspicious (spoofed log line) — don't save it.
            if let known = self.udid, known.caseInsensitiveCompare(udid) != .orderedSame {
                log("ignoring UDID \(udid) reported for our record (saved: \(known))")
                return
            }
            memory.adopt(udid)
            onUDID?(udid)
            publishStatus()
        }
        // Also when the device only connects long after the bridge started (it
        // left home minutes later): without a first tunnel it sits at Connecting.
        guard !warmingUp, !tunnelReady else { return }
        warmingUp = true
        let gen = generation
        Task {
            await warmUp(udid: udid, gen: gen)
            if gen == generation { warmingUp = false }   // retry on the next resolution if still no tunnel
        }
    }

    /// Right after the record appears CoreDevice may not list the device yet,
    /// so devicectl bails before asking for a tunnel. Retry until a tunnel
    /// port shows up (the relay set grows past the control channel).
    private func warmUp(udid: String, gen: Int) async {
        for attempt in 1...5 {
            guard gen == generation, !tunnelReady else { return }
            log("warming up tunnel for \(udid) (attempt \(attempt))")
            let r = await env.warmUp(udid)
            if gen != generation || tunnelReady { return }
            let err = r.err.split(separator: "\n").first.map(String.init) ?? ""
            log("warm-up: devicectl exited \(r.status)\(err.isEmpty ? "" : ": \(err)")")
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// remotepairingd drops the control channel every ~42s (its ARP check
    /// can't see this Mac's own IP) and reconnects within ~0.5s — `Link.next` waits
    /// `waitAfter` before calling that gone, so the UI doesn't flicker; look again then.
    private func controlConnectionsChanged(gen: Int) {
        guard gen == generation else { return }
        evaluate()
        guard (controlRelay?.openCount ?? 0) == 0 else { return }
        Task {
            try? await Task.sleep(for: .seconds(Link.waitAfter + 0.5))
            if gen == generation { evaluate() }
        }
    }

    /// On cellular the iPhone doesn't answer RemotePairing, so the control channel is
    /// gone for good — yet a tunnel set up on Wi‑Fi keeps carrying Xcode's session (its
    /// live pair moves heartbeats; standbys are silent). The device is in use then, not
    /// lost: tearing down to look for it again would end that session.
    /// Only bytes from the device count: remotepairingd keeps writing into a tunnel
    /// whose far end is gone (phone off, Tailscale down) until TCP gives up.
    private var tunnelCarriesTraffic: Bool {
        tunnelRelays.values.contains { $0.openCount > 0 && $0.heardFromDevice(within: 30) }
    }

    /// The one place `link` changes: from what the relays show now, and a probe's answer.
    /// Runs on every control-count change, 5 s after a close, each 10 s tick, and when a
    /// probe ends.
    private func evaluate(probe: Link.Probe? = nil) {
        guard state.isActive else { return }
        let controlOpen = (controlRelay?.openCount ?? 0) > 0
        if controlOpen { controlGoneSince = nil } else if controlGoneSince == nil { controlGoneSince = env.now() }
        let gone = controlGoneSince.map { env.now().timeIntervalSince($0) } ?? 0
        let heard = tunnelCarriesTraffic
        let next = Link.next(link, .init(controlOpen: controlOpen, heard: heard, controlGoneFor: gone, probe: probe,
                                         keepOnCellular: env.keepOnCellular(), now: env.now()))
        if next != link { link = next }   // @Published would redraw every view on each tick otherwise
        if pausedOnCellular {
            // Whatever remotepairingd dials into the tunnel relays meanwhile goes too.
            for relay in tunnelRelays.values where relay.openCount > 0 { relay.dropConnections() }
        } else if !controlOpen, heard, gone >= DeviceNetwork.cellularAfter, probe == nil {
            probeNetwork()   // keeps asking: the device may be back on Wi‑Fi with no control channel
        }
    }

    /// Where a device is that only the tunnel holds. On Wi‑Fi too remotepairingd sometimes
    /// stops dialing the control channel: a RemotePairing port that answers means Wi‑Fi;
    /// one that doesn't, from a device the mesh still reaches, means cellular. A device it
    /// can't reach is neither — it is going, and the tunnel will close.
    private func probeNetwork() {
        // Once a minute: while the port keeps answering, this would otherwise dial it every tick.
        guard !probingNetwork, env.now().timeIntervalSince(lastNetworkProbe) >= 60 else { return }
        probingNetwork = true
        lastNetworkProbe = env.now()
        let gen = generation, ip = profile.providerIP, port = profile.remotePairingPort
        let tailscale = profile.providerID == MeshProvider.tailscale.rawValue
        Task {
            // Twice, 5 s apart: one lost probe (a Tailscale stall, a Wi‑Fi hiccup) must not
            // close a Wi‑Fi session.
            var answers = await env.checkTCP(ip, port)
            if !answers {
                try? await Task.sleep(for: .seconds(5))
                answers = await env.checkTCP(ip, port)
            }
            let reached = answers ? true
                : await Self.stillReached(tailscale: tailscale,
                                          heardJustNow: tunnelRelays.values.contains { $0.heardFromDevice(within: 10) },
                                          ping: { [ping = env.ping] in await Blocking.run { ping(ip) } == .pong })
            probingNetwork = false
            guard gen == generation else { return }
            evaluate(probe: answers ? .answers : reached ? .silentReachable : .unreachable)
        }
    }

    /// Effects of a change, in one place: the tunnel closed on pausing, the renewal clock
    /// restarted on losing the device, and one status write.
    /// A device whose RemotePairing port is silent: does the mesh still reach it? Tailscale
    /// can ping it; any other mesh VPN (Manual IP) has no such check, but bytes from the
    /// device on its tunnel just now say the same.
    static func stillReached(tailscale: Bool, heardJustNow: Bool, ping: () async -> Bool) async -> Bool {
        tailscale ? await ping() : heardJustNow
    }

    private func linkChanged(from old: Link) {
        if pausedOnCellular {
            if case .paused = old {} else {
                log("on cellular — closed the tunnel (Keep debugging on cellular is off); back on Wi‑Fi it reconnects")
                for relay in tunnelRelays.values { relay.dropConnections() }
            }
        }
        let wasConnected = old == .wifi || old == .cellular
        if wasConnected, !phoneConnected { lastRenewal = env.now() }
        publishStatus()
    }

    var status: BridgeStatus {
        switch state {
        case .off: return .off
        case .starting: return .starting
        case .error: return .error
        case .local: return .local
        case .active:
            if !phoneConnected { return .waiting }
            return tunnelReady ? .ready : .preparing
        }
    }

    @discardableResult
    private func publishStatus(claim: Bool = false, deferToCLI: Bool = false) -> StatusFile.WriteResult {
        let s = status
        guard s != .off else { return StatusFile.write(profile.id, nil, in: statusDir, live: statusLive) }
        var detail = ""
        var ports: [UInt16] = []
        switch state {
        case .starting(let step): detail = step
        case .error(let m): detail = m
        case .active(_, let t): ports = t
        case .off, .local: break
        }
        if s == .waiting, pausedOnCellular {
            detail = "On cellular, so the tunnel was closed to save data. It reconnects on Wi‑Fi."
                + (env.keepOnCellular() ? "" : " To keep the session next time the device leaves Wi‑Fi, turn on Keep debugging on cellular in Settings.")
        }
        // Not an error: the bridge itself works over the mesh VPN. But the home
        // check is blind while this lasts, so say so wherever status is read.
        // Not while standing aside: getting to .local means the LAN answered, so the
        // gate is open again and the flag is only waiting to age out.
        if env.localNetworkDenied(), s != .local {
            detail = detail.isEmpty ? LocalNetwork.advice : detail + " — " + LocalNetwork.advice
        }
        return StatusFile.write(profile.id, .init(pid: getpid(), cli: env.cliRunning(), udid: udid, status: s.title, detail: detail,
                                                  ready: s == .ready, tunnelPorts: ports, updated: env.now(),
                                                  state: s.rawValue, started: StatusFile.myStart,
                                                  network: s == .ready || pausedOnCellular ? network?.rawValue : nil), in: statusDir,
                                 live: statusLive, claim: claim, deferToCLI: deferToCLI)
    }

    /// The device answers nowhere we know: it may have a new Tailscale address
    /// (re-registered) or RemotePairing port (restarted). Returns the profile
    /// with whatever was learned, and whether the device answers there.
    private func relocate(gen: Int) async -> (DeviceProfile, Bool) {
        var p = profile
        if p.providerID == MeshProvider.tailscale.rawValue, !p.providerHostName.isEmpty {
            setState(.starting("Looking up \(p.providerHostName) on Tailscale"))
            let list = env.listDevices
            let peers = await Blocking.run { try? list() } ?? []
            // Renamed on Tailscale (same address): follow the new name, so a later address change is found.
            if let current = peers.first(where: { $0.ips.contains(p.providerIP) }), current.name != p.providerHostName {
                log("Tailscale name is now \(current.name) (was \(p.providerHostName))")
                p.providerHostName = current.name
            }
            if let ip = peers.first(where: { $0.name == p.providerHostName })?.ipv4, ip != p.providerIP {
                log("\(p.providerHostName) has a new address: \(p.providerIP) → \(ip)")
                p.providerIP = ip
                if await env.checkTCP(ip, p.remotePairingPort) { return (p, true) }
            }
        }
        // Only scan a device that is up (answers Tailscale) — not one that's asleep or
        // offline — and not again soon after a scan found nothing (e.g. it's on cellular).
        let ip = p.providerIP
        let ping = env.ping
        let endpoint = "\(p.providerIP):\(p.remotePairingPort)"
        guard p.providerID == MeshProvider.tailscale.rawValue, !memory.scansPaused(of: endpoint, now: env.now()),
              await Blocking.run({ ping(ip) }) == .pong else { return (p, false) }
        // Awaited twice above: a Stop or a restart meanwhile owns the state now.
        guard step("Looking for \(profile.displayName)'s RemotePairing port", gen: gen) else { return (p, false) }
        let port: UInt16
        switch await env.findRemotePairingPort(p.providerIP) {
        case .found(let found): port = found
        case .notFound:
            log("no port on \(p.providerIP) answered as RemotePairing")
            if gen == generation { memory.pauseScans(of: endpoint, until: env.now() + 600) }
            return (p, false)
        case .timedOut:
            // A rescan starts over and would stall at the same place: same pause.
            log("RemotePairing port scan timed out before the full range was checked (Find RemotePairing Port in the app checks it all)")
            if gen == generation { memory.pauseScans(of: endpoint, until: env.now() + 600) }
            return (p, false)
        }
        if port != p.remotePairingPort { log("RemotePairing port moved: \(p.remotePairingPort) → \(port)") }
        p.remotePairingPort = port
        return (p, true)
    }

    /// Waiting for a minute with the record up usually means remotepairingd
    /// gave up on this device ("Not attempting to reconnect…"). Re-announce.
    private func renewIfStuck() {
        guard state.isActive else { stuckRenewals = 0; return }
        switch link {
        case .wifi, .cellular:
            stuckRenewals = 0
            // Held up by the tunnel alone, on Wi‑Fi: remotepairingd stopped dialing the control
            // channel, and a new tunnel needs it. Nudge it as a waiting bridge would. Not on
            // cellular, where 49152 doesn't answer anyway.
            if link == .wifi, (controlRelay?.openCount ?? 0) == 0,
               let gone = controlGoneSince, env.now().timeIntervalSince(gone) > 60,
               env.now().timeIntervalSince(lastHeldRenewal) > 60 {
                lastHeldRenewal = env.now()
                log("no control channel for 60s — re-announcing Bonjour record")
                dnsProxy.renew()
            }
            return
        case .waiting where tunnelCarriesTraffic:
            // Heard again, the probe still out (Link.next waits for it): not stuck, and the
            // relocation below would tear down a tunnel still in use on cellular.
            stuckRenewals = 0
            return
        case .waiting, .paused:
            break
        }
        guard env.now().timeIntervalSince(lastRenewal) > 60 else { return }
        lastRenewal = env.now()
        stuckRenewals += 1
        // Three minutes and still nothing: the device may have moved port or address. The
        // error retry runs start() again, which finds it (relocate).
        // Paused on cellular, it hasn't moved: RemotePairing answers again on Wi‑Fi.
        // For half an hour: its port may have changed meanwhile (a reboot), and only this finds it.
        let pausedLong = if case .paused(let since) = link { env.now().timeIntervalSince(since) > 1800 } else { true }
        if stuckRenewals >= 3, pausedLong {
            stuckRenewals = 0
            let gen = generation
            let ip = profile.providerIP
            let ping = env.ping
            Task {
                // Port closed while the device answers Tailscale: it moved. Asleep: keep waiting.
                guard !(await env.checkTCP(ip, profile.remotePairingPort)),
                      profile.providerID == MeshProvider.tailscale.rawValue,
                      await Blocking.run({ ping(ip) }) == .pong,
                      gen == generation, state.isActive, !phoneConnected, !tunnelCarriesTraffic else {
                    if gen == generation, state.isActive, !phoneConnected { dnsProxy.renew() }   // asleep: keep nudging
                    return
                }
                log("\(profile.providerIP):\(profile.remotePairingPort) no longer answers — looking for the device again")
                generation += 1
                teardown()
                setState(.error("\(profile.displayName) no longer answers on \(profile.providerIP):\(profile.remotePairingPort). Retrying shortly."))
            }
            return
        }
        log("no control channel for 60s — re-announcing Bonjour record")
        dnsProxy.renew()
    }

    /// After the Mac wakes, relayed connections may be dead while still looking open:
    /// re-announce now instead of waiting for keepalive and the 60 s renew.
    func nudgeAfterWake() {
        guard state.isActive else { return }
        log("Mac woke — re-announcing Bonjour record")
        lastRenewal = env.now()
        dnsProxy.renew()
    }

    /// The iPhone came back to this Mac's LAN while bridged: withdraw the fake
    /// record so it can't collide with the real one.
    private func standAsideIfHome() {
        guard !checkingLAN else { return }
        checkingLAN = true
        let gen = generation
        Task {
            defer { checkingLAN = false }
            guard await isHome(), gen == generation, state.isActive else { return }
            log("back on this Mac's network — standing aside until it leaves")
            memory.lastFullCheck = env.now()   // just proved; no full check on the next tick
            awayTicks = 0
            generation += 1
            teardown()
            setState(.local)
        }
    }

    /// Standing aside: start again only once the iPhone has left this LAN.
    func resumeIfAway() async {
        guard state == .local, !checkingLAN else { return }
        // Two processes standing aside for one device would keep overwriting each
        // other's status entry (and `down` could stop only one): one steps back.
        if let other = StatusFile.read(in: statusDir, live: statusLive)[profile.id], other.pid != getpid(),
           HomeRule.yields(meCLI: env.cliRunning(), myPID: getpid(), to: other) {
            log("another RoamRun process (pid \(other.pid)) watches this device too — stopping here")
            stop()
            onYield?(other)
            return
        }
        publishStatus()   // another process standing aside for the same iPhone may have cleared ours on exit
        checkingLAN = true
        let gen = generation
        let home = await isHome()
        checkingLAN = false
        guard gen == generation, state == .local else { return }
        // A device can miss a check (e.g. while locking): resume only after a few
        // misses in a row. Not CoreDevice — it keeps a just-closed bridge's link for minutes.
        awayTicks = home ? 0 : awayTicks + 1
        guard HomeRule.shouldResume(awayTicks: awayTicks) else { return }
        awayTicks = 0
        // Checked again after the wait: a `roamrun up` may have started meanwhile.
        if let other = StatusFile.read(in: statusDir, live: statusLive)[profile.id], other.pid != getpid(),
           HomeRule.yields(meCLI: env.cliRunning(), myPID: getpid(), to: other) {
            log("another RoamRun process (pid \(other.pid)) watches this device too — stopping here")
            stop()
            onYield?(other)
            return
        }
        await start(.resume)
    }

    /// Home if the iPhone itself advertises on this LAN — Tailscale may keep a
    /// cellular path after it joins Wi-Fi — or if Tailscale's path says so.
    private func isHome() async -> Bool {
        // The memory outlives this bridge: a write after it was stopped or rebuilt is stale.
        let bridging = state.isActive, now = env.now(), gen = generation
        // Not bridging: try a name known to be the device's advert before any `log show`.
        // iOS doesn't withdraw rotated _remotepairing names: 15-min-old instance
        // names still resolved and answered in ~0.1s (measured). The name is
        // per-device, so an answer means this device is on the LAN. Every 5 min
        // the full check below re-confirms the UDID, so a mistake can't persist.
        if !bridging, HomeRule.useCheapProbe(known: memory.homeAdvert, lastFullCheck: memory.lastFullCheck, now: now),
           let known = memory.homeAdvert, await answers(known) {
            return decided(true, "cached advert \(known.prefix(8))")
        }
        if !bridging, gen == generation { memory.lastFullCheck = now }
        if let udid {
            let fake = profile.instanceName
            // A resolved advert may be a stale cache entry (or a sleep proxy's):
            // only an answer from it proves the device is here.
            let recent = env.recentAdvert
            let instance = bridging
                ? HomeRule.bridgingAdvert(seenAdvert, activatedAt: activatedAt, now: now)
                : await Blocking.run { recent(udid, fake) }
            if !bridging, let instance, gen == generation { memory.homeAdvert = instance }
            if let instance, await answers(instance) { return decided(true, "advert \(instance.prefix(8))") }
        }
        if env.localNetworkDenied() {
            if !saidLocalNetworkDenied { saidLocalNetworkDenied = true; log(LocalNetwork.advice) }
        } else {
            saidLocalNetworkDenied = false
        }
        return decided(await env.isOnLAN(profile), "Tailscale path")
    }

    /// Said once per spell, not every check.
    private var saidLocalNetworkDenied = false

    private func answers(_ instance: String) async -> Bool {
        await env.answers(.service(name: instance, type: profile.serviceType, domain: profile.domain, interface: nil))
    }

    /// One line per decision at debug level (off by default): which signal decided.
    private func decided(_ home: Bool, _ by: String) -> Bool {
        Self.homeLog.debug("\(self.profile.displayName, privacy: .public): \(home ? "home" : "away", privacy: .public) (\(by, privacy: .public), \(self.state.isActive ? "bridging" : "not bridging", privacy: .public))")
        return home
    }

    /// At home the iPhone re-announces itself every ~30s under a fresh name,
    /// and remotepairingd matches each one to its UDID.
    // ponytail: can't tell another Mac's RoamRun record for the same iPhone from the real one.
    nonisolated static func recentAdvert(udid: String, besides fake: String) -> String? {
        TunnelPortWatcher.recentAdverts(last: "90s", timeout: 5).reversed().first { instance, owner in
            instance != fake && owner?.caseInsensitiveCompare(udid) == .orderedSame
        }?.0
    }

    /// True when the iPhone's Tailscale endpoint sits directly on en0's link
    /// and answers RemotePairing — i.e. Xcode can see it without us. Works
    /// even after the iPhone rotated its Bonjour instance name.
    static func isOnLAN(_ profile: DeviceProfile) async -> Bool {
        let ip = profile.providerIP
        let direct = await Blocking.run { Result { try TailscaleClient.fromSettings().directHost(ip) } }
        guard profile.providerID == MeshProvider.tailscale.rawValue, case .success(let found) = direct else {
            // ponytail: no Tailscale CLI (or a manual IP) — probe the host name seen at Add. Misses a
            // renamed iPhone and can hit another iPhone of the same name; set the CLI path to avoid.
            return await ReachabilityProbe.speaksRemotePairing(host: profile.bonjourHost, port: profile.remotePairingPort, timeout: 2)
        }
        guard let host = found, await Blocking.run({ isOnLink(host) }) else { return false }
        return await ReachabilityProbe.speaksRemotePairing(host: host, port: profile.remotePairingPort, timeout: 2)
    }

    /// Reached through en0 without a gateway — the link Xcode's mDNS sees.
    nonisolated private static func isOnLink(_ host: String) -> Bool {
        let out = Proc.run("/sbin/route", ["-n", "get"] + (host.contains(":") ? ["-inet6"] : []) + [host], timeout: 3).out
        let iface = out.split(separator: "\n").lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("interface:") }?.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
        return iface == InterfaceMonitor.lanInterface && !out.contains("gateway:")   // exact: en1 isn't en10
    }

    /// Without `log stream` no tunnel port is ever found; without `dns-sd` the
    /// record is gone. Either way the bridge only looks alive: fail it, and the
    /// error retry starts it afresh.
    private func helperDied(_ what: String, gen: Int) {
        guard gen == generation else { return }
        log(what)
        generation += 1
        teardown()
        // Retrying can't fix this one: `log stream` needs an admin account.
        if what.contains("Must be admin") {
            memory.autoRetry = false
            setState(.error("Reading remotepairingd's log needs an administrator account on this Mac (\(what))."))
            return
        }
        setState(.error("Helper stopped: \(what). Retrying shortly."))
    }

    /// A relay's listener died after it was up. The control one gone, the record
    /// points at nothing: restart like a dead helper. A tunnel one is dropped, and
    /// bound again when that port comes up again.
    private func relayFailed(_ failed: Relay, tunnelPort: UInt16?, gen: Int) {
        guard gen == generation else { return }
        guard let port = tunnelPort else {
            guard failed === controlRelay else { return }
            return helperDied("the relay on port \(localPort) stopped listening", gen: gen)
        }
        // That relay, not whatever holds the port now: it may have been bound afresh meanwhile.
        guard let relay = tunnelRelays[port], relay === failed else { return }
        relay.stop()
        tunnelRelays[port] = nil
        coveredPorts.remove(port)
        if case .active(let lp, let existing) = state {
            setState(.active(localPort: lp, tunnelPorts: existing.filter { $0 != port }))
        }
        log("the relay for tunnel port \(port) stopped listening; it reopens when that port comes up again")
    }

    /// remotepairingd saw our record but found no pairing for it. Waiting
    /// won't help; say what will.
    private func onUnrecognized(_ instance: String) {
        guard instance == profile.instanceName, state.isActive else { return }
        // Once can be a hiccup (e.g. right after remotepairingd restarts); act on a second
        // sighting — a later one, not the same announcement logged twice.
        if let first = unrecognizedSince, env.now().timeIntervalSince(first) < 20 { return }
        guard let first = unrecognizedSince, env.now().timeIntervalSince(first) < 300 else {
            unrecognizedSince = env.now()
            log("remotepairingd did not recognize this device (identity nil) — waiting to see it again")
            return
        }
        log("remotepairingd does not recognize this device (identity nil)")
        stop()
        memory.autoRetry = false
        setState(.error("This Mac doesn't recognize \(profile.displayName)'s pairing — its Bonjour identity changed or the pairing was reset. Put the device on this Mac's Wi‑Fi, remove it here and add it again. If Xcode also lost it, pair it in Xcode first."))
    }

    static var noAddressMessage: String {
        "This Mac has no address on \(InterfaceMonitor.lanInterface) (its LAN interface), so there is nothing to relay on. The bridge resumes when it reconnects."
    }

    func rename(_ name: String) { profile.displayName = name }

    /// Surface a refusal the coordinator decided on (e.g. same-LAN conflict).
    func fail(_ message: String) { setState(.error(message)) }

    /// Restores our entry if status.json was lost — unless another process claimed
    /// the device meanwhile (e.g. the file was deleted): then it's theirs. Standing
    /// aside or errored we don't hold it, so there's nothing to check.
    private func checkClaim() {
        guard ![BridgeStatus.off, .error, .local].contains(status) else { return }
        if case .heldBy(let other) = publishStatus() {
            stop()
            yieldClaim(to: other, "took over")
        }
    }

    /// Another process holds the device. The app keeps retrying (it shows the error, and
    /// takes over once the other ends); `roamrun up` gives up: refused, it isn't in
    /// status.json, so `down` couldn't stop it.
    private func yieldClaim(to other: StatusFile.Entry, _ what: String) {
        if env.cliRunning() { memory.autoRetry = false }
        setState(.error(other.pid == getpid()
            ? "Another saved device here (same UDID) is bridging \(profile.displayName). Remove the duplicate."
            : "Another RoamRun process (pid \(other.pid)) \(what) \(profile.displayName). Stop it there first."))
    }

    private func setState(_ s: BridgeState) { state = s; publishStatus() }
    private func log(_ m: String) { onLog?("[\(profile.displayName)] \(m)") }
}

/// The home/away rules, pure so they're tested (RoamRunTests). Each signal is
/// trusted only where it's valid:
/// - bridging: only adverts the watcher saw after this bridge went active —
///   a name learned at home before leaving must not bring it back;
/// - standing aside: a known advert name, re-confirmed by UDID every 5 min;
/// - resuming: several misses in a row, never CoreDevice (it keeps a
///   just-closed bridge's link for minutes, looking like a direct one).
enum HomeRule {
    static let fullCheckEvery: TimeInterval = 300
    static let missesBeforeResume = 3

    static func bridgingAdvert(_ seen: (instance: String, at: Date)?, activatedAt: Date, now: Date) -> String? {
        guard let seen, seen.at > activatedAt, now.timeIntervalSince(seen.at) <= 90 else { return nil }
        return seen.instance
    }

    static func useCheapProbe(known: String?, lastFullCheck: Date, now: Date) -> Bool {
        known != nil && now.timeIntervalSince(lastFullCheck) < fullCheckEvery
    }

    static func shouldResume(awayTicks: Int) -> Bool { awayTicks >= missesBeforeResume }

    /// A live `roamrun up` holds this device's entry, in any state: the app's
    /// automatic restarts leave it alone. Its errors are its own to retry, and a
    /// takeover makes it give up (exit 1) — the Start button still can.
    static func leftToCLI(_ entry: StatusFile.Entry?, myPID: Int32) -> Bool {
        guard let entry else { return false }
        return entry.cli == true && entry.pid != myPID
    }

    /// The `roamrun up` this device is left to: its own entry's, or one on another
    /// saved profile for the same device (same UDID).
    static func cliHolding(_ id: UUID, udid: String?, in live: [UUID: StatusFile.Entry], myPID: Int32) -> StatusFile.Entry? {
        if let own = live[id], leftToCLI(own, myPID: myPID) { return own }
        guard let udid else { return nil }
        return live.first { $0.key != id && leftToCLI($0.value, myPID: myPID)
            && $0.value.udid?.caseInsensitiveCompare(udid) == .orderedSame }?.value
    }

    /// Of two processes watching one device, which steps back: the app yields
    /// to `roamrun up` (the user just asked for it); of two CLIs, the newer (higher pid).
    static func yields(meCLI: Bool, myPID: Int32, to other: StatusFile.Entry) -> Bool {
        let otherCLI = other.cli == true
        if meCLI != otherCLI { return !meCLI }
        return myPID > other.pid
    }
}
