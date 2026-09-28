import Foundation
import AppKit
import ServiceManagement
import Combine

@MainActor
final class AppCoordinator: ObservableObject {
    @Published private(set) var profiles: [DeviceProfile] = []
    /// `profiles` as it was last read from or written to disk, so a save can tell
    /// which fields this process changed from ones `roamrun up` changed meanwhile.
    private var savedProfiles: [DeviceProfile] = []
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
        didSet {
            guard !syncingLoginItem else { return }
            UserDefaults.standard.set(launchAtLogin, forKey: Self.launchAtLoginKey)   // outlives the registration
            applyLaunchAtLogin()
        }
    }
    static let launchAtLoginKey = "launchAtLogin"
    /// Why "Open at login" isn't in effect (an error, or approval needed), for Settings.
    @Published private(set) var loginItemProblem: String?
    private var syncingLoginItem = false
    /// Shown once at launch, e.g. the saved devices couldn't be read.
    @Published var launchWarning: String?

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
        let saved = UserDefaults.standard.object(forKey: Self.launchAtLoginKey) as? Bool
        let loginStatus = SMAppService.mainApp.status
        let login = Self.loginItem(saved: saved, status: loginStatus)
        launchAtLogin = login.on
        if saved == nil { UserDefaults.standard.set(login.on, forKey: Self.launchAtLoginKey) }
        if loginStatus == .requiresApproval { loginItemProblem = "Allow RoamRun in System Settings › General › Login Items." }
        let savedCLIPath = UserDefaults.standard.string(forKey: "tailscaleCLIPath") ?? ""
        tailscaleClient.binaryPath = savedCLIPath.isEmpty ? nil : savedCLIPath
        tailscaleCLIPath = savedCLIPath

        profiles = Snapshot.fakeProfiles ?? store.load()
        savedProfiles = profiles
        if let copy = store.keptUnreadable {
            logStore.log("couldn't read saved devices; kept the file as \(copy.path)")
            launchWarning = "RoamRun couldn't read its saved devices, so the list starts empty. The file was kept as \(copy.path)."
        }
        for p in profiles { install(ProxyBridge(profile: p)) }

        capture.onLog = { [weak self] m in self?.logStore.log(m) }
        capture.ownedHosts = Set(profiles.map { ProxyBridge(profile: $0).spoofHost })

        // Helpers orphaned by a previous launch. Off the main actor: `ps` can take a
        // while, and every bridge start sweeps them again before it publishes anything.
        Task.detached { [weak self] in
            let killed = DNSServiceProxy.killOrphanedHelpers()
            guard killed > 0 else { return }
            await MainActor.run { self?.logStore.log("killed \(killed) leftover helper process(es)") }
        }

        // After sleep, relayed connections can look open while dead: re-announce right away.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.bridges.values.forEach { $0.nudgeAfterWake() } }
        }

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            // Must run synchronously — the process exits before a queued
            // MainActor task would get a chance to run.
            MainActor.assumeIsolated { self?.shutdown() }
        }

        // `roamrun down <name>` asks the app to stop one of its bridges.
        DistributedNotificationCenter.default().addObserver(forName: CLI.stopNotification,
                                                            object: nil, queue: .main) { [weak self] note in
            let target = (note.object as? String).flatMap(UUID.init)   // read before crossing into the main actor
            MainActor.assumeIsolated {
                guard let self, let id = target,
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

        // Only the installed copy registers itself: a build run from a folder must not
        // become the login item in place of it.
        if login.register, Bundle.main.bundlePath.hasPrefix("/Applications/") { applyLaunchAtLogin() }

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
        startOTAIfNeeded()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startOTAIfNeeded() }   // the CLI may have added the first build
        }
    }

    private func refreshExternalBridges() {
        let now = StatusFile.read().filter { $0.value.pid != getpid() }
        if now != externalBridges { externalBridges = now }   // detail changes too (Probing…, errors)
        // Nothing else tells the user: over the mesh VPN everything still works,
        // so a blocked local network only shows up as the device looking away.
        if LocalNetwork.denied, launchWarning == nil, !warnedLocalNetwork {
            warnedLocalNetwork = true
            launchWarning = LocalNetwork.advice
            logStore.log(LocalNetwork.advice)
        }
    }

    // MARK: - Over the air

    /// Serves the OTA page while the app runs. Started only when there is
    /// something to serve, so a user who never uses it never has a listener or a
    /// `tailscale serve` entry.
    private var otaServer: OTAServer?
    /// The path and the exact target `tailscale serve` was given. Recorded because
    /// nothing else identifies the entry as ours: on this kind of Mac every path
    /// people serve points at a loopback port, so "loopback" proves nothing. Only
    /// an entry matching this exactly is replaced, re-registered or given back.
    private var otaPublished: (path: String, target: String)?
    nonisolated static let otaServingKey = "otaServing"
    /// Said once per reason: the retry runs every 30s and the log is a person's.
    private var otaComplaint = ""
    private var verifyingOTA = false
    static let otaPathKey = "otaPath"
    var otaPath: String { UserDefaults.standard.string(forKey: Self.otaPathKey) ?? "/roamrun" }

    func startOTAIfNeeded() {
        // The path can be changed while we run; the advice for a clash says to do
        // exactly that, so it has to take effect without a restart.
        if let published = otaPublished, published.path != otaPath {
            release(published)   // or the old path 502s for ever, with nothing left to claim it
            otaPublished = nil
        }
        guard !OTA.builds().isEmpty else {
            stopOTA()   // nothing left to serve; deleting the folder is the off switch
            return
        }
        guard otaPublished == nil else {
            verifyOTAStillServed()
            return
        }
        // The path can change between attempts, and the server puts it into every
        // link it writes, so a stale one would send the device somewhere else.
        if let running = otaServer, running.prefix != otaPath {
            running.stop()
            otaServer = nil
        }
        let server = otaServer ?? OTAServer(prefix: otaPath)
        guard let port = server.start() else {
            complainOnce("couldn't start the over-the-air server")
            return
        }
        otaServer = server
        let path = otaPath
        Task.detached { [weak self] in
            let mine = "http://127.0.0.1:\(port)"
            let existing = TailscaleClient.servedPaths()[path]
            let ours = AppID.settings?.string(forKey: Self.otaServingKey)
            // A serve call on a port that carries a funnel can switch the funnel
            // off, taking a public service private. Not worth any feature.
            if TailscaleClient.funnelPorts().contains("443") {
                await MainActor.run {
                    self?.complainOnce("not publishing the install page: this Mac serves something on 443 " +
                        "through Tailscale Funnel, and registering a path there could turn that off.")
                }
                return
            }
            // Only ever replace an entry we can prove we made — ours from a run
            // that ended without releasing it. Anything else there is the user's,
            // and `tailscale serve` has no undo.
            if let existing, existing != ours, existing != mine {
                await MainActor.run {
                    self?.complainOnce("\(path) is already serving \(existing), which isn't RoamRun's — not taking it over. " +
                        "Give RoamRun another path: defaults write \(AppID.bundle) otaPath -string /some/path")
                }
                return
            }
            let out = Proc.run(TailscaleClient.fromSettings().resolvedPath() ?? "/usr/bin/false",
                               ["serve", "--bg", "--yes", "--set-path", path, mine], timeout: 20)
            await MainActor.run {
                guard let self else { return }
                if out.status == 0 {
                    self.otaPublished = (path, mine)
                    AppID.settings?.set(mine, forKey: Self.otaServingKey)
                    self.otaComplaint = ""
                    self.logStore.log("serving builds over the air at \(path)")
                } else {
                    // No HTTPS in this tailnet, tailscaled still coming up, or no
                    // Tailscale at all. The timer tries again, so this recovers.
                    self.complainOnce("couldn't publish \(path) with tailscale serve, will retry: " +
                        out.err.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
    }

    /// Something else can take the path away — another `tailscale serve` call, or
    /// `serve reset` — and the page is then dead until the app restarts. Off the
    /// main actor: reading the config shells out and blocks.
    private func verifyOTAStillServed() {
        guard let published = otaPublished, !verifyingOTA else { return }
        verifyingOTA = true
        Task.detached { [weak self] in
            let live = TailscaleClient.servedPaths()[published.path] == published.target
            await MainActor.run {
                guard let self else { return }
                self.verifyingOTA = false
                if !live, self.otaPublished?.target == published.target { self.otaPublished = nil }
            }
        }
    }

    /// Gives a registration back, but only while it is still exactly ours.
    /// Synchronous: this also runs from willTerminate, where a detached task
    /// would not outlive the process.
    private func release(_ published: (path: String, target: String)) {
        guard TailscaleClient.servedPaths()[published.path] == published.target else { return }
        let out = Proc.run(TailscaleClient.fromSettings().resolvedPath() ?? "/usr/bin/false",
                           ["serve", "--set-path", published.path, "off"], timeout: 10)
        // Only once it's really gone. Forgetting the target while the entry
        // survives would leave the next run unable to recognise its own
        // registration, and it would refuse to take it back.
        if out.status == 0, AppID.settings?.string(forKey: Self.otaServingKey) == published.target {
            AppID.settings?.removeObject(forKey: Self.otaServingKey)
        }
    }

    private func complainOnce(_ line: String) {
        guard line != otaComplaint else { return }
        otaComplaint = line
        logStore.log(line)
    }

    private func stopOTA() {
        guard let server = otaServer else { return }
        otaServer = nil
        server.stop()
        
        guard let published = otaPublished else { return }
        otaPublished = nil
        release(published)
    }

    /// The alert is shown once a run; the activity log and `roamrun status` keep saying it.
    private var warnedLocalNetwork = false

    /// Stops a bridge run by `roamrun up` (its SIGTERM handler cleans up).
    func stopExternalBridge(_ id: UUID) {
        // An explicit stop: the app must not pick the device back up on its
        // next retry once the CLI lets go.
        wasActiveIDs.remove(id)
        bridges[id]?.stop()
        // The status file, not the 2s-polled copy: a bridge started a moment ago counts too.
        guard let e = StatusFile.read()[id] ?? externalBridges[id], e.pid != getpid() else { return }
        if e.cli == true {
            // The cached entry above was validated when it was polled, not now: a PID
            // that has been reused since would get the signal meant for the bridge.
            guard StatusFile.isRoamRun(e) else { externalBridges[id] = nil; return }
            kill(e.pid, SIGTERM)   // its handler cleans up
        }
        else {
            DistributedNotificationCenter.default().postNotificationName(
                CLI.stopNotification, object: id.uuidString, userInfo: nil, deliverImmediately: true)
        }
    }

    /// App bridge status, or the CLI's when the command line owns the device.
    func status(of id: UUID) -> BridgeStatus {
        if let e = externalBridges[id] { return e.kind }
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
        // By UDID when remotepairingd knows the advert (instance names rotate), else the exact advert.
        let udid = advertUDIDs[captured.instanceName]
        guard !ip.isEmpty, profiles.nameProblem(displayName) == nil,
              !profiles.contains(where: { $0.providerIP == ip || $0.instanceName == captured.instanceName
                  || (udid != nil && $0.udid?.caseInsensitiveCompare(udid!) == .orderedSame) }) else { return nil }
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
        profile.udid = udid
        profiles.append(profile)
        let bridge = install(ProxyBridge(profile: profile))
        capture.ownedHosts.insert(bridge.spoofHost)
        persist()
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
        persist()
    }

    // MARK: - Bridging

    func bridge(for profile: DeviceProfile) -> ProxyBridge? { bridges[profile.id] }

    func startBridge(_ profile: DeviceProfile) {
        // Screenshot mode's fake devices are for looking at: no real bridge, no saved state.
        guard Snapshot.fakeProfiles == nil, let bridge = bridges[profile.id] else { return }

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

    /// Settings › Network changed: rebind once on the new interface.
    func lanInterfaceChanged() {
        interfaceMonitor.resync()
        reconnectActiveBridges()
    }

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
            if changed { persist() }
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
        if filled { persist(); learnDeviceTypes() }
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
            self.persist()
            self.learnDeviceTypes()
        }
        // Stepped back for a `roamrun up` watching the same device: take over again once it's gone.
        bridge.onYield = { [weak self] other in
            Task { @MainActor in
                while StatusFile.isRoamRun(other) { try? await Task.sleep(for: .seconds(5)) }   // that process, not just its PID
                guard let self, self.wasActiveIDs.contains(id), let p = self.profile(id),
                      self.bridges[id]?.state == .off else { return }
                self.startBridge(p)
            }
        }
        bridge.onProfileChange = { [weak self] moved in
            guard let self, let i = self.profiles.firstIndex(where: { $0.id == id }) else { return }
            self.profiles[i].providerIP = moved.providerIP
            self.profiles[i].remotePairingPort = moved.remotePairingPort
            self.profiles[i].providerHostName = moved.providerHostName
            self.persist()
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
        persist()
        bridges[id]?.rename(n)
        return true
    }

    // MARK: - Port scan

    /// Probe a bounded range for the RemotePairing control channel when the
    /// captured port doesn't answer. Updates the profile on success.
    func scanRemotePairingPort(_ profile: DeviceProfile) async {
        let host = profile.providerIP
        logStore.log("\"\(profile.displayName)\": scanning \(host) for its RemotePairing port", device: profile.id)
        let found: UInt16
        // Asked for and watched: time enough for every port even on a host that drops probes.
        switch await ReachabilityProbe.findRemotePairingPort(host: host, limit: .seconds(120)) {
        case .found(let port): found = port
        case .notFound:
            logStore.log("\"\(profile.displayName)\": no RemotePairing port responded — is the device on Wi-Fi?", device: profile.id)
            return
        case .timedOut:
            logStore.log("\"\(profile.displayName)\": the scan timed out before every port was checked", device: profile.id)
            return
        }
        if found == profile.remotePairingPort {
            logStore.log("\"\(profile.displayName)\": RemotePairing port is still \(found)", device: profile.id)
        } else if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx].remotePairingPort = found
            persist()
            logStore.log("\"\(profile.displayName)\": RemotePairing port updated to \(found)", device: profile.id)
            // ProxyBridge holds its profile by value — swap it in or the
            // new port only takes effect after a relaunch.
            // Also errored / standing aside: the scan is how you fix a bridge that can't reach the device.
            let wasOn = bridges[profile.id].map { $0.state != .off } == true
            bridges[profile.id]?.stop()
            let bridge = install(ProxyBridge(profile: profiles[idx]))
            if wasOn { bridge.requestStart() }
        }
    }

    /// Swaps a running bridge's profile by rebuilding it: `ProxyBridge` holds the
    /// profile by value, so otherwise the new endpoint only takes effect at the
    /// next launch — and the bridge spends a retry finding it out for itself.
    private func replaceBridge(with profile: DeviceProfile) {
        guard let old = bridges[profile.id], old.profile != profile else { return }
        let wasOn = old.state != .off
        old.stop()
        let bridge = install(ProxyBridge(profile: profile))
        if wasOn { bridge.requestStart() }
    }

    // MARK: - Internals

    /// Terminate all helper children (zone dump, proxy registrations, log
    /// watchers, relays) so nothing is orphaned when the app quits.
    func shutdown() {
        capture.stop()
        stopOTA()   // the serve entry would otherwise point at a dead port
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

    /// What the toggle shows, and whether to register again. A registration belongs to the
    /// bundle id, so changing it (0.1.12) or replacing the app drops it while the user's choice
    /// stands. `.requiresApproval` still counts as on: that's them switching it off in System
    /// Settings, which we leave alone.
    nonisolated static func loginItem(saved: Bool?, status: SMAppService.Status) -> (on: Bool, register: Bool) {
        let live = status == .enabled || status == .requiresApproval
        let lost = saved == true && !live
        return (live || lost, lost)
    }

    private func applyLaunchAtLogin() {
        loginItemProblem = nil
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemProblem = error.localizedDescription
            logStore.log("launch at login: \(error.localizedDescription)")
        }
        // Show what's actually in effect, not what was asked for.
        let status = SMAppService.mainApp.status
        if status == .requiresApproval { loginItemProblem = "Allow RoamRun in System Settings › General › Login Items." }
        let on = status == .enabled || status == .requiresApproval
        if on != launchAtLogin { syncingLoginItem = true; launchAtLogin = on; syncingLoginItem = false }
    }

    /// Saves the device list; a failed write would lose changes at the next launch, so say so.
    private func persist() {
        guard Snapshot.fakeProfiles == nil else { return }   // screenshot mode's fake devices never reach disk
        if let saved = store.save(base: savedProfiles, wanted: profiles) {
            savedProfiles = saved
            if saved != profiles {   // `roamrun up` had saved a newer endpoint
                let stale = zip(profiles, saved).filter { $0 != $1 }.map(\.1)
                profiles = saved
                for p in stale { replaceBridge(with: p) }   // it holds its profile by value
            }
            return
        }
        logStore.log("couldn't save the device list to \(ProfileStore.directory.path)")
        launchWarning = "RoamRun couldn't save your devices (\(ProfileStore.directory.path)). Changes will be lost when it quits — check the disk and folder permissions."
    }

    /// Stops helpers a crashed run left behind, off the main thread; says what it did.
    func cleanUpLeftoverHelpers() {
        Task {
            let killed = await Task.detached { DNSServiceProxy.killOrphanedHelpers() }.value
            logStore.log(killed == 0 ? "no leftover helpers found" : "stopped \(killed) leftover helper process(es)")
        }
    }
}
