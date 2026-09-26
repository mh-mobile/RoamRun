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
    /// Called when the bridge found the device at a new address or port; save it.
    var onProfileChange: ((DeviceProfile) -> Void)?
    /// Called after this bridge stopped because another process stands aside for the same device.
    var onYield: ((StatusFile.Entry) -> Void)?
    private(set) var udid: String?

    /// False after an error retrying can't fix (unrecognized pairing) — the
    /// auto-retry loops leave it alone. Same-LAN / CLI-owner refusals stay
    /// retryable: they clear by themselves once the iPhone leaves or the CLI stops.
    private(set) var autoRetry = true

    private var dnsProxy = DNSServiceProxy()
    /// TCP only: since iOS 17.4 the CoreDevice tunnel is TCP (17.0–17.3 used
    /// QUIC over UDP, which RoamRun doesn't support).
    private var controlRelay: Relay?
    private var tunnelRelays: [UInt16: Relay] = [:]
    private var coveredPorts = Set<UInt16>()
    private var localPort: UInt16 = 0
    private var generation = 0
    private var warmingUp = false
    private var waitingSince: Date?
    private var renewTimer: Timer?
    /// From the claim on, while starting too: gives the device up if another process claimed it.
    private var claimTimer: Timer?
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
    /// Re-announcements in a row without a control channel.
    private var stuckRenewals = 0
    /// First "identity nil" for our record; a second one within minutes is believed.
    private var unrecognizedSince: Date?
    /// A port scan that found nothing isn't repeated for a while (e.g. device on cellular).
    private var noScanUntil = Date.distantPast
    private static let homeLog = Logger(subsystem: AppID.bundle, category: "home")
    /// Lookahead hit/miss and port jumps (debug level): the data to retune +16 / -32
    /// if a future iOS allocates tunnel ports differently.
    private static let tunnelLog = Logger(subsystem: AppID.bundle, category: "tunnel")
    private var lastTunnelPort: UInt16?

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
        warmingUp = false
        awayTicks = 0
        stuckRenewals = 0
        unrecognizedSince = nil
        lastTunnelPort = nil
        activatedAt = .distantFuture
        autoRetry = true
        phoneConnected = false
        tunnelReady = false
        setState(.starting("Checking local interface"))
        // One bridge per iPhone across processes — claimed here so every path
        // (Start, retries, restore, network change, CLI) goes through it. The
        // claim is one step under status.lock; only `.written` means it's ours.
        switch publishStatus() {
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
            claimTimer?.invalidate()   // nothing held while standing aside
            claimTimer = nil
            setState(.local)
            log("on this Mac's network — standing aside until it leaves")
            return
        }
        guard gen == generation else { return }

        setState(.starting("Probing \(profile.providerIP):\(profile.remotePairingPort)"))
        var reachable = await ReachabilityProbe.checkTCP(host: profile.providerIP,
                                                         port: profile.remotePairingPort)
        guard gen == generation else { return }   // stopped or restarted meanwhile
        if !reachable {
            let (moved, answers) = await relocate()
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
            setState(.error("\(profile.providerIP) did not respond on RemotePairing port \(profile.remotePairingPort) — check the mesh VPN and that the device is on Wi-Fi"))
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
                control = try await bindRelay(localIP: localIP, localPort: port, remotePort: first)
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
        control.onOpenCountChange = { [weak self] _ in
            Task { @MainActor in self?.controlConnectionsChanged(gen: gen) }
        }

        // Watch before publishing: remotepairingd resolves the record (and
        // logs the UDID the warm-up needs) within ~1s of it appearing.
        // Lines already queued when the bridge stops or restarts still arrive;
        // the generation check drops them.
        // One watcher per process routes each tunnel port to the bridge whose device asked for it.
        // Lines already queued when the bridge stops or restarts still arrive; the generation check drops them.
        let me = Weak(self)
        let subscribed = TunnelCoordinator.shared.subscribe(profile.id, .init(
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
            Task { @MainActor in self?.helperDied("dns-sd exited (status \(status))", gen: gen) }
        }
        guard subscribed else {
            teardown()
            setState(.error("Couldn't watch remotepairingd's log (see Activity log). Retrying shortly."))
            return
        }

        await dnsProxy.previousExited()
        guard gen == generation else { return }
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
        claimTimer?.invalidate()
        claimTimer = nil
        TunnelCoordinator.shared.unsubscribe(profile.id)
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

    private func bindRelay(localIP: String, localPort: UInt16, remotePort: UInt16) async throws -> Relay {
        let relay = Relay(localIP: localIP, localPort: localPort, remoteIP: profile.providerIP, remotePort: remotePort)
        try await relay.start()
        return relay
    }

    /// remotepairingd connects ~5ms after logging the endpoint, so the port we
    /// just saw is always too late. The iPhone hands out tunnel ports
    /// sequentially, so pre-open the next ones for the retry.
    // ponytail: fixed lookahead of 16; widen if the device skips further ahead.
    private func onTunnelPortDiscovered(_ port: UInt16, localIP: String) {
        // Hit: a lookahead relay was already listening when remotepairingd dialed this port.
        let hit = tunnelRelays[port] != nil
        let jump = lastTunnelPort.map { Int(port) - Int($0) }
        lastTunnelPort = port
        Self.tunnelLog.debug("\(self.profile.displayName, privacy: .public): tunnel port \(port) \(hit ? "hit" : "miss", privacy: .public), jump \(jump.map(String.init) ?? "first", privacy: .public)")
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
            for p in ports {
                guard gen == generation else { return }   // restarted: coveredPorts is the new bridge's now
                do {
                    let pair = try await bindRelay(localIP: localIP, localPort: p, remotePort: p)
                    guard gen == generation else { pair.stop(); return }   // bridge stopped meanwhile
                    tunnelRelays[p] = pair
                    opened.append(p)
                    tunnelReady = true
                } catch {
                    coveredPorts.remove(p)
                    log("failed to open relay for tunnel port \(p): \(error.localizedDescription)")
                }
            }
            guard gen == generation else { return }   // restarted meanwhile: these ports aren't the new bridge's
            if case .active(let lp, let existing) = state {
                setState(.active(localPort: lp, tunnelPorts: existing + opened))
            }
        }
    }

    /// Tunnel ports move forward, so relays well behind the newest one — or
    /// ahead of it after a jump back — won't be dialed again. Close those
    /// that carry no connection.
    // ponytail: fixed window of newest-32...newest+16; widen if old tunnels get reused.
    private func reapTunnelRelays(around newest: UInt16) -> Set<UInt16> {
        var reaped = Set<UInt16>()
        let window = (Int(newest) - 32)...(Int(newest) + 16)
        for (port, pair) in tunnelRelays where !window.contains(Int(port)) && pair.openCount == 0 {
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
                seenAdvert = (instance, .now)
                homeAdvert = instance
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
        if (controlRelay?.openCount ?? 0) > 0 { phoneConnected = true; waitingSince = nil; return }
        Task {
            try? await Task.sleep(for: .seconds(5))
            if gen == generation, controlRelay?.openCount == 0 {
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

    @discardableResult
    private func publishStatus() -> StatusFile.WriteResult {
        let s = status
        guard s != .off else { return StatusFile.write(profile.id, nil) }
        var detail = ""
        var ports: [UInt16] = []
        switch state {
        case .starting(let step): detail = step
        case .error(let m): detail = m
        case .active(_, let t): ports = t
        case .off, .local: break
        }
        return StatusFile.write(profile.id, .init(pid: getpid(), cli: CLI.isRunning, udid: udid, status: s.title, detail: detail,
                                                  ready: s == .ready, tunnelPorts: ports, updated: .now, state: s.rawValue))
    }

    /// The device answers nowhere we know: it may have a new Tailscale address
    /// (re-registered) or RemotePairing port (restarted). Returns the profile
    /// with whatever was learned, and whether the device answers there.
    private func relocate() async -> (DeviceProfile, Bool) {
        var p = profile
        if p.providerID == MeshProvider.tailscale.rawValue, !p.providerHostName.isEmpty {
            setState(.starting("Looking up \(p.providerHostName) on Tailscale"))
            let peers = await Task.detached { try? TailscaleClient.fromSettings().listDevices() }.value ?? []
            // Renamed on Tailscale (same address): follow the new name, so a later address change is found.
            if let current = peers.first(where: { $0.ips.contains(p.providerIP) }), current.name != p.providerHostName {
                log("Tailscale name is now \(current.name) (was \(p.providerHostName))")
                p.providerHostName = current.name
            }
            if let ip = peers.first(where: { $0.name == p.providerHostName })?.ipv4, ip != p.providerIP {
                log("\(p.providerHostName) has a new address: \(p.providerIP) → \(ip)")
                p.providerIP = ip
                if await ReachabilityProbe.checkTCP(host: ip, port: p.remotePairingPort) { return (p, true) }
            }
        }
        // Only scan a device that is up (answers Tailscale) — not one that's asleep or
        // offline — and not again soon after a scan found nothing (e.g. it's on cellular).
        let ip = p.providerIP
        guard p.providerID == MeshProvider.tailscale.rawValue, Date.now > noScanUntil,
              await Task.detached(operation: { TailscaleClient.fromSettings().ping(ip) }).value else { return (p, false) }
        setState(.starting("Looking for \(profile.displayName)'s RemotePairing port"))
        let port: UInt16
        switch await ReachabilityProbe.findRemotePairingPort(host: p.providerIP) {
        case .found(let found): port = found
        case .notFound:
            log("no port on \(p.providerIP) answered as RemotePairing")
            noScanUntil = .now + 600
            return (p, false)
        case .timedOut:
            // A rescan starts over and would stall at the same place: same pause.
            log("RemotePairing port scan timed out before the full range was checked (Find RemotePairing Port in the app checks it all)")
            noScanUntil = .now + 600
            return (p, false)
        }
        if port != p.remotePairingPort { log("RemotePairing port moved: \(p.remotePairingPort) → \(port)") }
        p.remotePairingPort = port
        return (p, true)
    }

    /// Waiting for a minute with the record up usually means remotepairingd
    /// gave up on this device ("Not attempting to reconnect…"). Re-announce.
    private func renewIfStuck() {
        guard state.isActive, !phoneConnected else { stuckRenewals = 0; return }
        guard let since = waitingSince, Date.now.timeIntervalSince(since) > 60 else { return }
        waitingSince = .now
        stuckRenewals += 1
        // Three minutes and still nothing: the device may have moved port or address. The
        // error retry runs start() again, which finds it (relocate).
        if stuckRenewals >= 3 {
            stuckRenewals = 0
            let gen = generation
            let ip = profile.providerIP
            Task {
                // Port closed while the device answers Tailscale: it moved. Asleep: keep waiting.
                guard !(await ReachabilityProbe.checkTCP(host: ip, port: profile.remotePairingPort)),
                      profile.providerID == MeshProvider.tailscale.rawValue,
                      await Task.detached(operation: { TailscaleClient.fromSettings().ping(ip) }).value,
                      gen == generation, state.isActive, !phoneConnected else {
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
        waitingSince = .now
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
        // Two processes standing aside for one device would keep overwriting each
        // other's status entry (and `down` could stop only one): one steps back.
        if let other = StatusFile.read()[profile.id], other.pid != getpid(),
           HomeRule.yields(meCLI: CLI.isRunning, myPID: getpid(), to: other) {
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
        TunnelPortWatcher.recentAdverts(last: "90s", timeout: 5).reversed().first { instance, owner in
            instance != fake && owner?.caseInsensitiveCompare(udid) == .orderedSame
        }?.0
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
            autoRetry = false
            setState(.error("Reading remotepairingd's log needs an administrator account on this Mac (\(what))."))
            return
        }
        setState(.error("Helper stopped: \(what). Retrying shortly."))
    }

    /// remotepairingd saw our record but found no pairing for it. Waiting
    /// won't help; say what will.
    private func onUnrecognized(_ instance: String) {
        guard instance == profile.instanceName, state.isActive else { return }
        // Once can be a hiccup (e.g. right after remotepairingd restarts); act on a second
        // sighting — a later one, not the same announcement logged twice.
        if let first = unrecognizedSince, Date.now.timeIntervalSince(first) < 20 { return }
        guard let first = unrecognizedSince, Date.now.timeIntervalSince(first) < 300 else {
            unrecognizedSince = .now
            log("remotepairingd did not recognize this device (identity nil) — waiting to see it again")
            return
        }
        log("remotepairingd does not recognize this device (identity nil)")
        stop()
        autoRetry = false
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
        if CLI.isRunning { autoRetry = false }
        setState(.error(other.pid == getpid()
            ? "Another saved device here (same UDID) is bridging \(profile.displayName). Remove the duplicate."
            : "Another RoamRun process (pid \(other.pid)) \(what) \(profile.displayName). Stop it there first."))
    }

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

    /// Of two processes watching one device, which steps back: the app yields
    /// to `roamrun up` (the user just asked for it); of two CLIs, the newer (higher pid).
    static func yields(meCLI: Bool, myPID: Int32, to other: StatusFile.Entry) -> Bool {
        let otherCLI = other.cli == true
        if meCLI != otherCLI { return !meCLI }
        return myPID > other.pid
    }
}
