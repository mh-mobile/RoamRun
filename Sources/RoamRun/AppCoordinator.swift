import Foundation
import AppKit
import ServiceManagement
import Combine

@MainActor
final class AppCoordinator: ObservableObject {
    @Published private(set) var profiles: [DeviceProfile] = []
    @Published private(set) var bridges: [UUID: ProxyBridge] = [:]
    @Published private(set) var tailscaleDevices: [MeshDevice] = []
    @Published private(set) var tailscaleError: String?
    /// Bridges another process (`roamrun up`) is running, by profile id.
    @Published private(set) var externalBridges: [UUID: StatusFile.Entry] = [:]
    /// Sidebar selection — shared so the menu bar can open a given device.
    @Published var selectedID: UUID?
    @Published var tailscaleCLIPath: String {
        didSet {
            UserDefaults.standard.set(tailscaleCLIPath, forKey: "tailscaleCLIPath")
            tailscaleClient.binaryPath = tailscaleCLIPath.isEmpty ? nil : tailscaleCLIPath
        }
    }
    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    let capture = BonjourCapture()
    let logStore = LogStore()

    private let store = ProfileStore()
    private var tailscaleClient = TailscaleClient()
    private let interfaceMonitor = InterfaceMonitor()
    private var bridgeObservers: [UUID: AnyCancellable] = [:]
    /// Set at launch when bridges left on are being brought back.
    private(set) var isRestoringBridges = false
    private var wasActiveIDs: Set<UUID> {
        get { Set((UserDefaults.standard.array(forKey: "wasActiveIDs") as? [String] ?? []).compactMap(UUID.init)) }
        set { UserDefaults.standard.set(newValue.map { $0.uuidString }, forKey: "wasActiveIDs") }
    }

    init() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        let savedCLIPath = UserDefaults.standard.string(forKey: "tailscaleCLIPath") ?? ""
        tailscaleClient.binaryPath = savedCLIPath.isEmpty ? nil : savedCLIPath
        tailscaleCLIPath = savedCLIPath

        profiles = store.load()
        if let copy = store.keptUnreadable { logStore.log("couldn't read saved devices; kept the file as \(copy.path)") }
        for p in profiles { install(ProxyBridge(profile: p)) }

        capture.onLog = { [weak self] m in self?.logStore.log(m) }
        capture.ownedHosts = Set(profiles.map { ProxyBridge(profile: $0).spoofHost })

        // Remove helpers orphaned by a previous launch *before* starting ours.
        DNSServiceProxy.killOrphanedHelpers { [weak self] m in self?.logStore.log(m) }

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            // Must run synchronously — the process exits before a queued
            // MainActor task would get a chance to run.
            MainActor.assumeIsolated { self?.shutdown() }
        }

        // `roamrun down <name>` asks the app to stop one of its bridges.
        DistributedNotificationCenter.default().addObserver(forName: CLI.stopNotification,
                                                            object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let id = (note.object as? String).flatMap(UUID.init),
                      let p = self.profile(id) else { return }
                self.logStore.log("\"\(p.displayName)\": stopped from the command line", device: p.id)
                self.stopBridge(p)
            }
        }

        interfaceMonitor.onLost = { [weak self] in
            Task { @MainActor in self?.onInterfaceLost() }
        }
        interfaceMonitor.onChange = { [weak self] ip in
            Task { @MainActor in self?.onInterfaceChange(ip) }
        }
        interfaceMonitor.start()

        learnDeviceTypes()

        // A snapshot run is a throwaway copy; it must not touch the real app's bridges.
        for id in wasActiveIDs where Snapshot.path == nil {
            if let p = profiles.first(where: { $0.id == id }) {
                isRestoringBridges = true
                logStore.log("restoring bridge for \"\(p.displayName)\"", device: p.id)
                self.bridge(for: p)?.requestStart()
            }
        }

        // Bridges the user left on retry quietly after errors (iPhone asleep,
        // Tailscale paused, Wi-Fi down) so nobody has to open the window.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryErroredBridges() }
        }
        // Standing aside: resume soon after the device leaves this Wi-Fi.
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for b in self.bridges.values where b.state == .local { Task { await b.resumeIfAway() } }
            }
        }
        // Pick up bridges started from the command line.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshExternalBridges() }
        }
        refreshExternalBridges()
    }

    private func refreshExternalBridges() {
        let now = StatusFile.read().filter { $0.value.pid != getpid() }
        if now != externalBridges { externalBridges = now }   // detail changes too (Probing…, errors)
    }

    /// Stops a bridge run by `roamrun up` (its SIGTERM handler cleans up).
    func stopExternalBridge(_ id: UUID) {
        // An explicit stop: the app must not pick the device back up on its
        // next retry once the CLI lets go.
        wasActiveIDs.remove(id)
        bridges[id]?.stop()
        // The status file, not the 2s-polled copy: a bridge started a moment ago counts too.
        guard let e = StatusFile.read()[id] ?? externalBridges[id], e.pid != getpid() else { return }
        if e.cli == true { kill(e.pid, SIGTERM) }   // its handler cleans up
        else {
            DistributedNotificationCenter.default().postNotificationName(
                CLI.stopNotification, object: id.uuidString, userInfo: nil, deliverImmediately: true)
        }
    }

    /// App bridge status, or the CLI's when the command line owns the device.
    func status(of id: UUID) -> BridgeStatus {
        if let e = externalBridges[id] { return BridgeStatus(title: e.status) }
        return bridges[id]?.status ?? .off
    }

    private func retryErroredBridges() {
        for id in wasActiveIDs {
            guard let p = profiles.first(where: { $0.id == id }), let b = bridges[id] else { continue }
            if b.status == .error && b.autoRetry { startBridge(p) }
        }
    }

    /// Worst state across all bridges, for the menu bar icon.
    var overallStatus: BridgeStatus {
        let all = profiles.map { status(of: $0.id) }   // CLI-owned devices report the CLI's state
        for s in [BridgeStatus.error, .ready, .waiting, .preparing, .starting, .local] where all.contains(s) { return s }
        return .off
    }

    // MARK: - Profiles

    @discardableResult
    func addDevice(captured: CapturedService, provider: MeshProvider,
                   meshDevice: MeshDevice?, manualIP: String, name: String) -> UUID? {
        let ip = provider == .manual ? manualIP.trimmingCharacters(in: .whitespaces) : (meshDevice?.ipv4 ?? "")
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let displayName = trimmed.isEmpty ? captured.shortHost : trimmed
        // Same checks as the sheet, here too: two profiles for one device would collide.
        guard !ip.isEmpty, !profiles.contains(where: { $0.providerIP == ip }), profiles.nameProblem(displayName) == nil else { return nil }
        var profile = DeviceProfile(
            displayName: displayName,
            instanceName: captured.instanceName,
            serviceType: captured.serviceType,
            domain: captured.domain,
            remotePairingPort: captured.port,
            bonjourHost: captured.host,
            txt: captured.txt,
            providerID: provider.rawValue,
            providerHostName: provider == .manual ? manualIP : (meshDevice?.name ?? ""),
            providerIP: ip
        )
        // Known already if remotepairingd matched this advert; else learned on first connect.
        profile.udid = advertUDIDs[captured.instanceName]
        profiles.append(profile)
        let bridge = install(ProxyBridge(profile: profile))
        capture.ownedHosts.insert(bridge.spoofHost)
        store.save(profiles)
        logStore.log("added \"\(profile.displayName)\" -> \(ip)", device: profile.id)
        learnDeviceTypes()
        return profile.id
    }

    func deleteProfile(_ id: UUID) {
        stopExternalBridge(id)   // a `roamrun up` for it would otherwise live on, unstoppable by name
        if let spoof = bridges[id]?.spoofHost { capture.ownedHosts.remove(spoof) }
        if selectedID == id { selectedID = nil }
        bridges[id] = nil
        bridgeObservers[id] = nil
        profiles.removeAll { $0.id == id }
        wasActiveIDs.remove(id)
        store.save(profiles)
    }

    // MARK: - Bridging

    func bridge(for profile: DeviceProfile) -> ProxyBridge? { bridges[profile.id] }

    func startBridge(_ profile: DeviceProfile) {
        guard let bridge = bridges[profile.id] else { return }

        var ids = wasActiveIDs
        ids.insert(profile.id)
        wasActiveIDs = ids

        // Same-LAN detection lives in ProxyBridge.start (by Tailscale endpoint,
        // which survives the iPhone rotating its Bonjour instance name).
        bridge.requestStart()
    }

    func stopBridge(_ profile: DeviceProfile) {
        bridges[profile.id]?.stop()
        var ids = wasActiveIDs
        ids.remove(profile.id)
        wasActiveIDs = ids
    }

    /// App bridges that are on (any state but Off); Terminal ones are the CLI's.
    var runningProfiles: [DeviceProfile] {
        profiles.filter { externalBridges[$0.id] == nil && bridges[$0.id].map { $0.state != .off } == true }
    }

    /// Tear down and start again — the manual "unstick" after sleep or a network change.
    func reconnectActiveBridges() { runningProfiles.forEach(startBridge) }

    func stopAllBridges() {
        runningProfiles.forEach(stopBridge)
        externalBridges.keys.forEach(stopExternalBridge)
    }

    /// iPhone, iPad or Vision Pro — for the icons. devicectl knows every paired
    /// device's kind by UDID, even while it's away; asked once per profile.
    func learnDeviceTypes() {
        guard profiles.contains(where: { $0.udid != nil && $0.deviceType == nil }) else { return }
        Task {
            let types = await Task.detached { Self.deviceTypes() }.value
            var changed = false
            for i in profiles.indices where profiles[i].deviceType == nil {
                if let u = profiles[i].udid, let t = types[u.uppercased()] { profiles[i].deviceType = t; changed = true }
            }
            if changed { store.save(profiles) }
        }
    }

    /// Bonjour instance → device kind, for the Add sheet's icons: remotepairingd
    /// matches every advert it sees to a UDID, devicectl knows each UDID's kind.
    @Published private(set) var advertTypes: [String: String] = [:]
    /// Bonjour instance → UDID, for telling devices apart in the Add sheet.
    @Published private(set) var advertUDIDs: [String: String] = [:]
    /// UDID → kind; a device's kind never changes, so devicectl is asked only about new UDIDs.
    private var knownTypes: [String: String] = [:]

    func learnAdvertTypes() async {
        let udids = await Task.detached {
            var byInstance: [String: String] = [:]
            for (instance, udid) in TunnelPortWatcher.recentAdverts(last: "15m") { if let udid { byInstance[instance] = udid.uppercased() } }
            return byInstance
        }.value
        if udids.values.contains(where: { knownTypes[$0] == nil }) {
            knownTypes.merge(await Task.detached { Self.deviceTypes() }.value) { _, new in new }
            for u in udids.values where knownTypes[u] == nil { knownTypes[u] = "" }   // unknown: don't ask again
        }
        advertUDIDs = udids
        // Profiles saved before their UDID was known: the advert they were added from names it.
        var filled = false
        for i in profiles.indices where profiles[i].udid == nil {
            if let u = udids[profiles[i].instanceName] { profiles[i].udid = u; filled = true }
        }
        if filled { store.save(profiles); learnDeviceTypes() }
        advertTypes = udids.compactMapValues { knownTypes[$0].flatMap { $0.isEmpty ? nil : $0 } }
    }

    nonisolated private static func deviceTypes() -> [String: String] {
        guard let devices = Proc.devicectl(["list", "devices"], timeout: 30)?["devices"] as? [[String: Any]] else { return [:] }
        var types: [String: String] = [:]
        for d in devices {
            guard let h = d["hardwareProperties"] as? [String: Any], h["reality"] as? String == "physical",
                  let u = h["udid"] as? String, let t = h["deviceType"] as? String else { continue }
            types[u.uppercased()] = t
        }
        return types
    }

    // MARK: - Tailscale

    /// Off the main actor: a hung `tailscale status` must not freeze the UI.
    func refreshTailscale() {
        let client = tailscaleClient
        Task {
            let result = await Task.detached { Result { try client.listDevices() } }.value
            switch result {
            case .success(let devices):
                tailscaleDevices = devices
                tailscaleError = nil
                logStore.log("tailscale: \(devices.count) peer(s)")
            case .failure(let error):
                tailscaleError = error.localizedDescription
                logStore.log("tailscale: \(error.localizedDescription)")
            }
        }
    }

    /// Registers a bridge and re-publishes its changes so views that only
    /// observe the coordinator (menu bar icon, sidebar) stay current.
    @discardableResult
    private func install(_ bridge: ProxyBridge) -> ProxyBridge {
        let id = bridge.profile.id
        bridge.onLog = { [weak self] m in self?.logStore.log(m, device: id) }
        bridge.onUDID = { [weak self] udid in
            guard let self, let i = self.profiles.firstIndex(where: { $0.id == id }) else { return }
            self.profiles[i].udid = udid
            self.store.save(self.profiles)
            self.learnDeviceTypes()
        }
        bridge.onProfileChange = { [weak self] moved in
            guard let self, let i = self.profiles.firstIndex(where: { $0.id == id }) else { return }
            self.profiles[i].providerIP = moved.providerIP
            self.profiles[i].remotePairingPort = moved.remotePairingPort
            self.store.save(self.profiles)
        }
        bridges[bridge.profile.id] = bridge
        bridgeObservers[bridge.profile.id] = bridge.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        return bridge
    }

    func profile(_ id: UUID) -> DeviceProfile? { profiles.first { $0.id == id } }

    func isNameTaken(_ name: String, except id: UUID? = nil) -> Bool { profiles.isNameTaken(name, except: id) }
    func uniqueName(_ base: String) -> String { profiles.uniqueName(base) }

    @discardableResult
    func rename(_ id: UUID, to newName: String) -> Bool {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard profiles.nameProblem(n, except: id) == nil,
              let i = profiles.firstIndex(where: { $0.id == id }) else { return false }
        profiles[i].displayName = n
        store.save(profiles)
        bridges[id]?.rename(n)
        return true
    }

    // MARK: - Port scan

    /// Probe a bounded range for the RemotePairing control channel when the
    /// captured port doesn't answer. Updates the profile on success.
    func scanRemotePairingPort(_ profile: DeviceProfile) async {
        let host = profile.providerIP
        logStore.log("\"\(profile.displayName)\": scanning \(host) for its RemotePairing port", device: profile.id)
        let found = await ReachabilityProbe.findRemotePairingPort(host: host)
        if let found, found == profile.remotePairingPort {
            logStore.log("\"\(profile.displayName)\": RemotePairing port is still \(found)", device: profile.id)
        } else if let found, let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx].remotePairingPort = found
            store.save(profiles)
            logStore.log("\"\(profile.displayName)\": RemotePairing port updated to \(found)", device: profile.id)
            // ProxyBridge holds its profile by value — swap it in or the
            // new port only takes effect after a relaunch.
            // Also errored / standing aside: the scan is how you fix a bridge that can't reach the device.
            let wasOn = bridges[profile.id].map { $0.state != .off } == true
            bridges[profile.id]?.stop()
            let bridge = install(ProxyBridge(profile: profiles[idx]))
            if wasOn { bridge.requestStart() }
        } else {
            logStore.log("\"\(profile.displayName)\": no RemotePairing port responded — is the device on Wi-Fi?", device: profile.id)
        }
    }

    // MARK: - Internals

    /// Terminate all helper children (zone dump, proxy registrations, log
    /// watchers, relays) so nothing is orphaned when the app quits.
    func shutdown() {
        capture.stop()
        for bridge in bridges.values { bridge.stop() }
    }

    /// Relays are bound to en0's address; show the pause instead of a stale "active".
    private func onInterfaceLost() {
        logStore.log("local IP lost; bridges paused until Wi-Fi returns")
        for bridge in bridges.values where bridge.state.isActive {
            bridge.stop()
            bridge.fail(ProxyBridge.noAddressMessage)
        }
    }

    private func onInterfaceChange(_ ip: String) {
        logStore.log("local IP changed -> \(ip); restarting active bridges")
        // Also retry bridges that errored (e.g. started while en0 had no IP).
        let wanted = wasActiveIDs
        for (id, bridge) in bridges where bridge.state.isActive || wanted.contains(id) {
            bridge.stop()
            // Through startBridge, so the CLI-owner and same-LAN checks apply.
            if let p = profile(id) { startBridge(p) }
        }
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logStore.log("launch at login: \(error.localizedDescription)")
        }
    }
}
