import Foundation

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
    private var warmedUp = false
    private var waitingSince: Date?
    private var renewTimer: Timer?

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
        warmedUp = false
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
        DNSServiceProxy.killOrphanedHelpers { [weak self] m in self?.log(m) }

        guard let localIP = InterfaceMonitor.currentIPv4() else {
            setState(.error(Self.noAddressMessage))
            return
        }

        // Home again? Xcode sees the real iPhone; a fake record would only collide.
        if await Self.isOnLAN(profile) {
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
            setState(.error("\(profile.providerIP) did not respond on RemotePairing port \(profile.remotePairingPort) — check the mesh VPN and that the iPhone is on Wi-Fi"))
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
        watcher.onPort = { [weak self] port in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
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
        watcher.start()

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
            teardown()   // don't hold relays/watcher under an error another process may clear
            setState(.error(error.localizedDescription))
            return
        }

        setState(.active(localPort: localPort, tunnelPorts: []))
        log("bridge active: \(profile.providerIP) relayed locally on \(localIP):\(localPort)")
        waitingSince = .now
        renewTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.renewIfStuck()
                self?.standAsideIfHome()
            }
        }
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
        guard instance == profile.instanceName else { return }
        if udid != self.udid {
            self.udid = udid
            onUDID?(udid)
            publishStatus()
        }
        guard !warmedUp else { return }
        warmedUp = true
        Task { await warmUp(udid: udid, gen: generation) }
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
        let gen = generation
        Task {
            guard await Self.isOnLAN(profile), gen == generation, state.isActive else { return }
            log("back on this Mac's network — stopping the bridge until it leaves")
            stop()
            setState(.local)
        }
    }

    /// True when the iPhone's Tailscale endpoint is a private LAN address that
    /// itself answers RemotePairing, i.e. the iPhone sits on this Mac's LAN.
    /// (Behind another NAT — or away — that address doesn't answer.) Works even
    /// after the iPhone rotated its Bonjour instance name.
    static func isOnLAN(_ profile: DeviceProfile) async -> Bool {
        let path = (UserDefaults(suiteName: "com.roamrun.app") ?? .standard).string(forKey: "tailscaleCLIPath")
        let client = TailscaleClient(binaryPath: path?.isEmpty == false ? path : nil)
        let peers = await Task.detached { (try? client.listDevices()) ?? [] }.value
        guard let addr = peers.first(where: { $0.ips.contains(profile.providerIP) })?.curAddr,
              let host = addr.split(separator: ":").first.map(String.init),
              host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.range(of: #"^172\.(1[6-9]|2\d|3[01])\."#, options: .regularExpression) != nil
        else { return false }
        return await ReachabilityProbe.speaksRemotePairing(host: host, port: profile.remotePairingPort, timeout: 2)
    }

    /// remotepairingd saw our record but found no pairing for it. Waiting
    /// won't help; say what will.
    private func onUnrecognized(_ instance: String) {
        guard instance == profile.instanceName, state.isActive else { return }
        log("remotepairingd does not recognize this iPhone (identity nil)")
        stop()
        autoRetry = false
        setState(.error("This Mac doesn't recognize \(profile.displayName)'s pairing — its Bonjour identity changed or the pairing was reset. Put the iPhone on this Mac's Wi‑Fi, remove it here and add it again. If Xcode also lost it, pair it in Xcode first."))
    }

    static let noAddressMessage = "This Mac has no Wi‑Fi address (en0), so there is nothing to relay on. The bridge resumes when Wi‑Fi reconnects."

    func rename(_ name: String) { profile.displayName = name }

    /// Surface a refusal the coordinator decided on (e.g. same-LAN conflict).
    func fail(_ message: String) { setState(.error(message)) }

    private func setState(_ s: BridgeState) { state = s }
    private func log(_ m: String) { onLog?("[\(profile.displayName)] \(m)") }
}
