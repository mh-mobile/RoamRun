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
    @Published private(set) var state: BridgeState = .off { didSet { publishStatus() } }
    /// remotepairingd holds a control channel to the iPhone through us.
    @Published private(set) var phoneConnected = false { didSet { publishStatus() } }
    /// A tunnel has been negotiated at least once, so relays are primed.
    @Published private(set) var tunnelReady = false { didSet { publishStatus() } }

    private(set) var profile: DeviceProfile
    var onLog: ((String) -> Void)?
    /// Called when remotepairingd reports a (new) UDID for this device.
    var onUDID: ((String) -> Void)?
    private(set) var udid: String?

    /// False after an error retrying can't fix (unrecognized pairing) — the
    /// auto-retry loops leave it alone. Same-LAN / CLI-owner refusals stay
    /// retryable: they clear by themselves once the iPhone leaves or the CLI stops.
    private(set) var autoRetry = true

    /// TCP only: since iOS 17.4 the CoreDevice tunnel is TCP (17.0–17.3
    /// used QUIC over UDP, which RoamRun doesn't support). A UDP relay would
    /// only add an idle, spoofable surface on the LAN.
    private struct RelayPair {
        let tcp: Relay
        func stop() { tcp.stop() }
    }

    private var dnsProxy = DNSServiceProxy()
    private var controlRelay: RelayPair?
    private var tunnelRelays: [UInt16: RelayPair] = [:]
    private var watcher = TunnelPortWatcher()
    private var coveredPorts = Set<UInt16>()
    private var localPort: UInt16 = 0
    private var generation = 0
    private var warmingUp = false
    private var waitingSince: Date?
    private var renewTimer: Timer?
    private var checkingLAN = false
    // Home detection. Each signal is only trusted in the state it's valid in (HomeRule).
    /// When this bridge last went active; bridging trusts only adverts seen after it.
    private var activatedAt = Date.distantFuture
    /// Latest of the device's own adverts the watcher saw. Written only by the watcher.
    private var seenAdvert: (instance: String, at: Date)?
    /// A name known to be the device's advert, for the cheap stand-aside probe.
    private var homeAdvert: String?
    /// Standing aside, the last time isHome confirmed the UDID the slow way.
    private var lastFullCheck = Date.distantPast
    /// Standing aside, consecutive checks that found the device away.
    private var awayTicks = 0
    private static let homeLog = Logger(subsystem: "com.roamrun.app", category: "home")

    /// Spoofed SRV target whose A record we publish pointing at this Mac.
    var spoofHost: String {
        "rr-\(profile.id.uuidString.prefix(8).lowercased()).roamrun.local"
    }

    init(profile: DeviceProfile) {
        self.profile = profile
        self.udid = profile.udid
    }

    func start() async {
        generation += 1
        let gen = generation
        teardown()   // a failed or repeated start must not leave relays/timers behind
        // Fresh watcher: the previous log stream's reader may still be
        // delivering lines on its own queue while we'd reassign callbacks.
        watcher = TunnelPortWatcher()
        warmingUp = false
        awayTicks = 0
        activatedAt = .distantFuture
        autoRetry = true
        phoneConnected = false
        tunnelReady = false
        setState(.starting("Checking local interface"))
        // One bridge per iPhone across processes — checked here so every
        // path (Start, retries, restore, network change, CLI) goes through it.
        if let pid = StatusFile.otherOwner(of: profile.id) {
            setState(.error("Another RoamRun process (pid \(pid)) is already bridging \(profile.displayName). Stop it there first."))
            return
        }
        // A SIGKILLed app or `roamrun up` leaves dns-sd advertising a dead relay.
        // Off the main actor: `ps` can take a while.
        let killed = await Task.detached { DNSServiceProxy.killOrphanedHelpers() }.value
        guard gen == generation else { return }
        if killed > 0 { log("killed \(killed) leftover helper process(es)") }

        guard let localIP = InterfaceMonitor.currentIPv4() else {
            setState(.error(Self.noAddressMessage))
            return
        }

        // Home again? Xcode sees the real iPhone; a fake record would only collide.
        if await isHome() {
            guard gen == generation else { return }
            setState(.local)
            log("on this Mac's network — standing aside until it leaves")
            return
        }
        guard gen == generation else { return }

        setState(.starting("Probing \(profile.providerIP):\(profile.remotePairingPort)"))
        let reachable = await ReachabilityProbe.checkTCP(host: profile.providerIP,
                                                         port: profile.remotePairingPort)
        guard gen == generation else { return }   // stopped or restarted meanwhile
        guard reachable else {
            setState(.error("\(profile.providerIP) did not respond on RemotePairing port \(profile.remotePairingPort) — check the mesh VPN and that the device is on Wi-Fi"))
            return
        }

        // Control channel: prefer the real port number (49152), fall back
        // to the next free ones if it is taken locally.
        setState(.starting("Opening relays"))
        var control: RelayPair?
        var lastError = ""
        let first = profile.remotePairingPort
        for port in first...UInt16(min(Int(first) + 20, Int(UInt16.max))) {
            do {
                control = try await bindPair(localIP: localIP, localPort: port, remotePort: first)
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
        localPort = control.tcp.localPort
        coveredPorts.insert(localPort)
        control.tcp.onOpenCountChange = { [weak self] _ in
            Task { @MainActor in self?.controlConnectionsChanged(gen: gen) }
        }

        // Watch before publishing: remotepairingd resolves the record (and
        // logs the UDID the warm-up needs) within ~1s of it appearing.
        // Lines already queued when the bridge stops or restarts still arrive;
        // the generation check drops them.
        watcher.onPort = { [weak self] port, owner in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                // Another bridged iPhone's tunnel: its port isn't ours to relay.
                if let owner, let mine = self.udid, owner.caseInsensitiveCompare(mine) != .orderedSame { return }
                self.onTunnelPortDiscovered(port, localIP: localIP)
            }
        }
        watcher.onDevice = { [weak self] instance, udid in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                self.onDeviceReachable(instance: instance, udid: udid)
            }
        }
        watcher.onUnrecognized = { [weak self] instance in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                self.onUnrecognized(instance)
            }
        }
        watcher.onLog = { [weak self] m in self?.log(m) }
        watcher.onExit = { [weak self] m in
            Task { @MainActor in self?.helperDied(m, gen: gen) }
        }
        dnsProxy.onExit = { [weak self] status in
            Task { @MainActor in self?.helperDied("dns-sd exited (status \(status))", gen: gen) }
        }
        guard watcher.start() else {
            teardown()
            setState(.error("Couldn't watch remotepairingd's log (see Activity log). Retrying shortly."))
            return
        }

        do {
            setState(.starting("Publishing Bonjour proxy"))
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

        activatedAt = .now
        setState(.active(localPort: localPort, tunnelPorts: []))
        log("bridge active: \(profile.providerIP) relayed locally on \(localIP):\(localPort)")
        waitingSince = .now
        renewTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.renewIfStuck()
                self?.standAsideIfHome()
            }
        }
    }

    /// Start from synchronous code. A stop() before the task gets to run wins.
    func requestStart() {
        let g = generation
        Task { guard g == generation else { return }; await start() }
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
        watcher.stop()
        dnsProxy.stop()
        controlRelay?.stop()
        controlRelay = nil
        for pair in tunnelRelays.values { pair.stop() }
        tunnelRelays = [:]
        coveredPorts = []
        localPort = 0
        phoneConnected = false
        tunnelReady = false
    }

    private func bindPair(localIP: String, localPort: UInt16, remotePort: UInt16) async throws -> RelayPair {
        let tcp = Relay(localIP: localIP, localPort: localPort, remoteIP: profile.providerIP, remotePort: remotePort)
        try await tcp.start()
        return RelayPair(tcp: tcp)
    }

    /// remotepairingd connects ~5ms after logging the endpoint, so the port we
    /// just saw is always too late. The iPhone hands out tunnel ports
    /// sequentially, so pre-open the next ones for the retry.
    // ponytail: fixed lookahead of 16; widen if the device skips further ahead.
    private func onTunnelPortDiscovered(_ port: UInt16, localIP: String) {
        let upper = UInt16(min(Int(port) + 16, Int(UInt16.max)))
        let ports = (port...upper).filter { !coveredPorts.contains($0) }
        guard !ports.isEmpty else { return }
        coveredPorts.formUnion(ports)
        log("live tunnel port \(port) discovered, relaying \(ports.first!)-\(ports.last!)")
        let gen = generation
        Task {
            var opened: [UInt16] = []
            for p in ports {
                do {
                    let pair = try await bindPair(localIP: localIP, localPort: p, remotePort: p)
                    guard gen == generation else { pair.stop(); return }   // bridge stopped meanwhile
                    tunnelRelays[p] = pair
                    opened.append(p)
                    tunnelReady = true
                } catch {
                    coveredPorts.remove(p)
                    log("failed to open relay for tunnel port \(p): \(error.localizedDescription)")
                }
            }
            let reaped = reapTunnelRelays(below: port)
            if case .active(let lp, let existing) = state {
                setState(.active(localPort: lp, tunnelPorts: existing.filter { !reaped.contains($0) } + opened))
            }
        }
    }

    /// Tunnel ports only move forward, so relays well behind the newest one
    /// will not be dialed again. Close those that carry no connection.
    // ponytail: fixed 32-port tail kept; widen if old tunnels get reused.
    private func reapTunnelRelays(below newest: UInt16) -> Set<UInt16> {
        var reaped = Set<UInt16>()
        let cutoff = Int(newest) - 32
        for (port, pair) in tunnelRelays where Int(port) < cutoff && pair.tcp.openCount == 0 {
            pair.stop()
            tunnelRelays[port] = nil
            coveredPorts.remove(port)
            reaped.insert(port)
        }
        if !reaped.isEmpty { log("closed \(reaped.count) idle tunnel relays below \(cutoff)") }
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
                seenAdvert = (instance, .now)
                homeAdvert = instance
            }
            return
        }
        if udid != self.udid {
            self.udid = udid
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
            let r = await Proc.runAsync("/usr/bin/xcrun", ["devicectl", "--quiet", "--timeout", "30",
                                                          "device", "info", "details", "--device", udid])
            if gen != generation || tunnelReady { return }
            let err = r.err.split(separator: "\n").first.map(String.init) ?? ""
            log("warm-up: devicectl exited \(r.status)\(err.isEmpty ? "" : ": \(err)")")
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// remotepairingd drops the control channel every ~42s (its ARP check
    /// can't see this Mac's own IP) and reconnects within ~0.5s — debounce
    /// so the UI doesn't flicker.
    private func controlConnectionsChanged(gen: Int) {
        guard gen == generation else { return }
        // Read the live count: notifications from different threads can
        // arrive out of order, so a passed-in value may be stale.
        if (controlRelay?.tcp.openCount ?? 0) > 0 { phoneConnected = true; waitingSince = nil; return }
        Task {
            try? await Task.sleep(for: .seconds(5))
            if gen == generation, controlRelay?.tcp.openCount == 0 {
                phoneConnected = false
                if waitingSince == nil { waitingSince = .now }
            }
        }
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

    private func publishStatus() {
        let s = status
        guard s != .off else { StatusFile.write(profile.id, nil); return }
        var detail = ""
        var ports: [UInt16] = []
        switch state {
        case .starting(let step): detail = step
        case .error(let m): detail = m
        case .active(_, let t): ports = t
        case .off, .local: break
        }
        StatusFile.write(profile.id, .init(pid: getpid(), cli: CLI.isRunning, udid: udid, status: s.title, detail: detail,
                                           ready: s == .ready, tunnelPorts: ports, updated: .now))
    }

    /// Waiting for a minute with the record up usually means remotepairingd
    /// gave up on this device ("Not attempting to reconnect…"). Re-announce.
    private func renewIfStuck() {
        guard state.isActive, !phoneConnected, let since = waitingSince,
              Date.now.timeIntervalSince(since) > 60 else { return }
        waitingSince = .now
        log("no control channel for 60s — re-announcing Bonjour record")
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
            lastFullCheck = .now   // just proved; no full check on the next tick
            awayTicks = 0
            generation += 1
            teardown()
            setState(.local)
        }
    }

    /// Standing aside: start again only once the iPhone has left this LAN.
    func resumeIfAway() async {
        guard state == .local, !checkingLAN else { return }
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
        await start()
    }

    /// Home if the iPhone itself advertises on this LAN — Tailscale may keep a
    /// cellular path after it joins Wi-Fi — or if Tailscale's path says so.
    private func isHome() async -> Bool {
        let bridging = state.isActive, now = Date.now
        // Not bridging: try a name known to be the device's advert before any `log show`.
        // iOS doesn't withdraw rotated _remotepairing names: 15-min-old instance
        // names still resolved and answered in ~0.1s (measured). The name is
        // per-device, so an answer means this device is on the LAN. Every 5 min
        // the full check below re-confirms the UDID, so a mistake can't persist.
        if !bridging, HomeRule.useCheapProbe(known: homeAdvert, lastFullCheck: lastFullCheck, now: now),
           let known = homeAdvert, await answers(known) {
            return decided(true, "cached advert \(known.prefix(8))")
        }
        if !bridging { lastFullCheck = now }
        if let udid {
            let fake = profile.instanceName
            // A resolved advert may be a stale cache entry (or a sleep proxy's):
            // only an answer from it proves the device is here.
            let instance = bridging
                ? HomeRule.bridgingAdvert(seenAdvert, activatedAt: activatedAt, now: now)
                : await Task.detached(operation: { Self.recentAdvert(udid: udid, besides: fake) }).value
            if !bridging, let instance { homeAdvert = instance }
            if let instance, await answers(instance) { return decided(true, "advert \(instance.prefix(8))") }
        }
        return decided(await Self.isOnLAN(profile), "Tailscale path")
    }

    private func answers(_ instance: String) async -> Bool {
        await ReachabilityProbe.speaksRemotePairing(.service(name: instance, type: profile.serviceType,
                                                             domain: profile.domain, interface: nil), timeout: 2)
    }

    /// One line per decision at debug level (off by default): which signal decided.
    private func decided(_ home: Bool, _ by: String) -> Bool {
        Self.homeLog.debug("\(self.profile.displayName, privacy: .public): \(home ? "home" : "away", privacy: .public) (\(by, privacy: .public), \(self.state.isActive ? "bridging" : "not bridging", privacy: .public))")
        return home
    }

    /// At home the iPhone re-announces itself every ~30s under a fresh name,
    /// and remotepairingd matches each one to its UDID.
    // ponytail: can't tell another Mac's RoamRun record for the same iPhone from the real one.
    nonisolated private static func recentAdvert(udid: String, besides fake: String) -> String? {
        let out = Proc.run("/usr/bin/log", ["show", "--last", "90s", "--style", "compact", "--predicate",
                                            #"process == "remotepairingd" AND eventMessage CONTAINS "Resolved bonjour advert""#],
                           timeout: 5).out
        return out.split(separator: "\n").reversed().lazy.compactMap { line -> String? in
            guard let (instance, owner) = TunnelPortWatcher.advert(in: String(line)),
                  instance != fake, owner?.caseInsensitiveCompare(udid) == .orderedSame else { return nil }
            return instance
        }.first
    }

    /// True when the iPhone's Tailscale endpoint sits directly on en0's link
    /// and answers RemotePairing — i.e. Xcode can see it without us. Works
    /// even after the iPhone rotated its Bonjour instance name.
    static func isOnLAN(_ profile: DeviceProfile) async -> Bool {
        let ip = profile.providerIP
        let direct = await Task.detached { Result { try TailscaleClient.fromSettings().directHost(ip) } }.value
        guard profile.providerID == MeshProvider.tailscale.rawValue, case .success(let found) = direct else {
            // ponytail: no Tailscale CLI (or a manual IP) — probe the host name seen at Add. Misses a
            // renamed iPhone and can hit another iPhone of the same name; set the CLI path to avoid.
            return await ReachabilityProbe.speaksRemotePairing(host: profile.bonjourHost, port: profile.remotePairingPort, timeout: 2)
        }
        guard let host = found, await Task.detached(operation: { isOnLink(host) }).value else { return false }
        return await ReachabilityProbe.speaksRemotePairing(host: host, port: profile.remotePairingPort, timeout: 2)
    }

    /// Reached through en0 without a gateway — the link Xcode's mDNS sees.
    nonisolated private static func isOnLink(_ host: String) -> Bool {
        let out = Proc.run("/sbin/route", ["-n", "get"] + (host.contains(":") ? ["-inet6"] : []) + [host], timeout: 3).out
        return out.contains("interface: en0") && !out.contains("gateway:")
    }

    /// Without `log stream` no tunnel port is ever found; without `dns-sd` the
    /// record is gone. Either way the bridge only looks alive: fail it, and the
    /// error retry starts it afresh.
    private func helperDied(_ what: String, gen: Int) {
        guard gen == generation else { return }
        log(what)
        generation += 1
        teardown()
        setState(.error("Helper stopped: \(what). Retrying shortly."))
    }

    /// remotepairingd saw our record but found no pairing for it. Waiting
    /// won't help; say what will.
    private func onUnrecognized(_ instance: String) {
        guard instance == profile.instanceName, state.isActive else { return }
        log("remotepairingd does not recognize this device (identity nil)")
        stop()
        autoRetry = false
        setState(.error("This Mac doesn't recognize \(profile.displayName)'s pairing — its Bonjour identity changed or the pairing was reset. Put the device on this Mac's Wi‑Fi, remove it here and add it again. If Xcode also lost it, pair it in Xcode first."))
    }

    static let noAddressMessage = "This Mac has no Wi‑Fi address (en0), so there is nothing to relay on. The bridge resumes when Wi‑Fi reconnects."

    func rename(_ name: String) { profile.displayName = name }

    /// Surface a refusal the coordinator decided on (e.g. same-LAN conflict).
    func fail(_ message: String) { setState(.error(message)) }

    private func setState(_ s: BridgeState) { state = s }
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
}
