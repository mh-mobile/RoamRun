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
    /// Retries, the away check, address changes and wake, shared with `roamrun up`.
    private lazy var supervisor = BridgeSupervisor(
        all: { [unowned self] in
            self.departing.removeAll { !$0.statusWritePending }
            return Array(self.bridges.values) + self.departing
        },
        wanted: { [unowned self] in self.wasActiveIDs.contains($0.profile.id) && self.profile($0.profile.id) != nil },
        start: { [unowned self] list, reason in
            let live = StatusFile.read()
            for b in list { self.autoStart(b.profile.id, live: live, reason) }
        })
    private var bridgeObservers: [UUID: AnyCancellable] = [:]
    /// Per saved device, kept across its bridges: a rebuilt one (edited endpoint, port found
    /// again) remembers what the old one learned.
    private var memories: [UUID: DeviceMemory] = [:]
    /// Deleted devices' bridges whose status removal failed: kept until a retry lands it, or
    /// the entry (this app's own, so never stale) would make the iPhone a duplicate if added again.
    private var departing: [ProxyBridge] = []
    /// Set at launch when bridges left on are being brought back.
    private(set) var isRestoringBridges = false
    private var wasActiveIDs: Set<UUID> {
        get { Set((UserDefaults.standard.array(forKey: "wasActiveIDs") as? [String] ?? []).compactMap(UUID.init)) }
        set { UserDefaults.standard.set(newValue.map { $0.uuidString }, forKey: "wasActiveIDs") }
    }

    init() {
        let saved = UserDefaults.standard.object(forKey: Self.launchAtLoginKey) as? Bool
        let loginStatus = SMAppService.mainApp.status
        // Only the installed copy registers itself: a build run from a folder must not
        // become the login item in place of it.
        let installed = Bundle.main.bundlePath.hasPrefix("/Applications/")
        let login = Self.loginItem(saved: saved, status: loginStatus, canRegister: installed)
        launchAtLogin = login.on
        if saved == nil { UserDefaults.standard.set(login.on, forKey: Self.launchAtLoginKey) }
        if loginStatus == .requiresApproval { loginItemProblem = "Allow RoamRun in System Settings › General › Login Items." }
        if saved == true && !login.on { loginItemProblem = Self.lostLoginItemAdvice(bundlePath: Bundle.main.bundlePath) }
        let savedCLIPath = UserDefaults.standard.string(forKey: "tailscaleCLIPath") ?? ""
        tailscaleClient.binaryPath = savedCLIPath.isEmpty ? nil : savedCLIPath
        tailscaleCLIPath = savedCLIPath

        profiles = Snapshot.fakeProfiles ?? store.load()
        savedProfiles = profiles
        if let copy = store.keptUnreadable {
            logStore.log("couldn't read saved devices; kept the file as \(copy.path)")
            launchWarning = profiles.isEmpty
                ? "RoamRun couldn't read its saved devices, so the list starts empty. The file was kept as \(copy.path)."
                : "RoamRun couldn't read some of its saved devices; the others are here. The file was kept as \(copy.path)."
        } else if store.unreadable {
            logStore.log("couldn't read \(ProfileStore.directory.path)/profiles.json; not writing over it")
            launchWarning = Self.unreadableListWarning
        }
        for p in profiles { install(newBridge(p)) }

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
            MainActor.assumeIsolated { self?.supervisor.woke() }
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

        if login.register { applyLaunchAtLogin() }

        // A snapshot run is a throwaway copy; it must not touch the real app's bridges.
        let live = StatusFile.read()
        for id in wasActiveIDs where Snapshot.path == nil {
            if let p = profiles.first(where: { $0.id == id }) {
                isRestoringBridges = true
                logStore.log("restoring bridge for \"\(p.displayName)\"", device: p.id)
                autoStart(id, live: live, .restore)
            }
        }

        supervisor.run()
        // Pick up bridges started from the command line.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshExternalBridges() }
        }
        refreshExternalBridges()
        if Snapshot.path == nil { startOTAIfNeeded() }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            // The CLI may have added the first build.
            MainActor.assumeIsolated { if Snapshot.path == nil { self?.startOTAIfNeeded() } }
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
    /// The tailnet port and the exact target `tailscale serve` was given. Recorded
    /// because nothing else identifies the entry as ours, and `tailscale serve`
    /// has no undo: only an entry matching this exactly is replaced or released.
    private var otaPublished: (port: Int, target: String)?
    /// Every address RoamRun has registered lately, not just the
    /// last one. A run that crashed, and an attempt that failed, both leave one
    /// behind; recognising any of them is what lets the next run take its own
    /// registration back instead of calling it someone else's.
    nonisolated static let otaServingKey = "otaServing"

    /// Releasing an old path and registering a new one run at the same time, and
    /// both read this list, change it and write it back.
    nonisolated static let servingLock = NSLock()

    /// `<tailnet port> <target>`. The port is half of it: a loopback address on
    /// its own is recycled, and a registration made on a port the app is no
    /// longer configured for can't be found to give back without it.
    nonisolated static func token(_ port: Int, _ target: String) -> String { "\(port) \(target)" }

    /// The pair an entry names. Entries written before the port was part of it
    /// are bare targets, and still match on the target alone.
    nonisolated static func pair(_ entry: String) -> (port: Int?, target: String) {
        let parts = entry.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let port = Int(parts[0]) else { return (nil, entry) }
        return (port, String(parts[1]))
    }

    nonisolated static func rememberServing(_ target: String, on port: Int) {
        servingLock.withLock {
            AppID.settings?.set(remembering(AppID.settings?.stringArray(forKey: otaServingKey) ?? [],
                                            token(port, target)), forKey: otaServingKey)
        }
    }

    nonisolated static func forgetServing(_ target: String, on port: Int) {
        servingLock.withLock {
            AppID.settings?.set((AppID.settings?.stringArray(forKey: otaServingKey) ?? []).filter {
                let p = pair($0)
                return !(p.target == target && (p.port == nil || p.port == port))
            }, forKey: otaServingKey)
        }
    }

    /// Newest last, no repeats, and only the last few: an address is worth
    /// recognising for as long as an entry using it could still be lying around.
    nonisolated static func remembering(_ seen: [String], _ target: String, keep: Int = 5) -> [String] {
        Array((seen.filter { $0 != target } + [target]).suffix(keep))
    }

    nonisolated static func isOurs(_ target: String, on port: Int, in record: [String] = remembered()) -> Bool {
        record.contains { let p = pair($0); return p.target == target && (p.port == nil || p.port == port) }
    }

    nonisolated static func remembered() -> [String] {
        servingLock.withLock { AppID.settings?.stringArray(forKey: otaServingKey) ?? [] }
    }

    /// Gives back registrations this Mac made and never released. Every port the
    /// record names, not only the one configured now: a run that was killed after
    /// `otaPort` changed — or one whose registration was never confirmed — left
    /// an entry where nothing else here would look again.
    ///
    /// nil when Tailscale couldn't be asked, which at launch is ordinary;
    /// false when it was asked and a release didn't take.
    /// What this tick owes `tailscale serve`, in the order the page depends on
    /// it. Looking for leftovers wants the same lock as any of these and comes
    /// last. `published == hasBuilds` was not the same question: a registration
    /// with a dead listener behind it is both of those and still needs work.
    enum Due: Equatable {
        case releaseOldPort     // `otaPort` changed under a live registration
        case stopServing        // `ota/` deleted while one stands
        case restartListener    // registered, but nothing is listening
        case publish            // builds, and nothing registered
        case nothing
    }

    /// `publishJustFailed` gives the sweep a turn between retries: a publish that
    /// can't succeed — the port taken, say — must not defer the release of an old
    /// one for ever, and that release may well be what frees the port.
    nonisolated static func due(portChanged: Bool, published: Bool, listening: Bool,
                                hasBuilds: Bool, publishJustFailed: Bool) -> Due {
        if published && portChanged { return .releaseOldPort }
        if published && !hasBuilds { return .stopServing }
        if published && !listening { return .restartListener }
        if !published && hasBuilds { return publishJustFailed ? .nothing : .publish }
        return .nothing
    }

    nonisolated static func reclaimStrays(keeping live: (port: Int, target: String)?, tools: ServeTools = .live) -> Bool? {
        guard let host = tools.host(5) else { return nil }
        var asked = true, released = true
        for port in Set(tools.remembered().compactMap { pair($0).port } + [tools.otaPort()]).sorted() {
            let state = tools.serving(port, 10)
            guard state != .unknown else { asked = false; continue }
            guard let target = state.root(on: host), isOurs(target, on: port, in: tools.remembered()) else { continue }
            // The one this run is serving from, confirmed or not.
            if live?.port == port, live?.target == target { continue }
            if !releaseServe((port: port, target: target), tools: tools) { released = false }
        }
        return asked ? released : nil
    }
    /// Said once per reason: the retry runs every 30s and the log is a person's.
    private var otaComplaint = ""
    private var verifyingOTA = false
    /// Bumped by each start of the OTA server and by turning it off: a start that
    /// finishes under an older number is no longer wanted.
    private var otaAttempt = 0
    /// Whether to look for registrations a run left behind, and a generation so
    /// a sweep that started earlier can't clear a request made while it ran.
    /// An entry left by a run that didn't give it back is invisible to
    /// `otaPublished`, which only ever exists in memory.
    struct StrayWork: Equatable {
        private(set) var wanted = true
        private(set) var generation = 0

        mutating func askAgain() {
            wanted = true
            generation += 1
        }

        /// A sweep's result, applied only if nothing asked again while it ran.
        mutating func finished(_ done: Bool, startedAt: Int) {
            guard done, startedAt == generation else { return }
            wanted = false
        }
    }

    private var strays = StrayWork()
    /// Every attempt owes the sweep a turn unless its registration is tracked.
    struct PublishWork: Equatable {
        private(set) var yieldToSweep = false

        mutating func began() { yieldToSweep = true }
        mutating func registered() { yieldToSweep = false }

        mutating func offerSweep(due: Due, changeInProgress: Bool, wanted: Bool,
                                 hasRemembered: @autoclosure () -> Bool) -> Bool {
            guard due == .nothing, !changeInProgress else { return false }
            // A running attempt still owes its turn when it finishes.
            // Otherwise offering consumes it, even with nothing to sweep.
            yieldToSweep = false
            return wanted && hasRemembered()
        }
    }

    private var publishWork = PublishWork()
    /// One change to `tailscale serve` at a time, publish or release. Each takes
    /// up to 35 s of shelling out and the timer comes round every 30, so without
    /// this they overlap — and two overlapping releases can each read "the entry
    /// is ours" before either runs `off`, so the second removes whatever took the
    /// port in between. That is the deletion this whole path exists to avoid.
    /// A flag rather than holding a lock: these run in detached tasks that hop
    /// threads, and NSLock must be unlocked by the thread that took it.
    nonisolated static let publishLock = NSLock()
    nonisolated(unsafe) private static var changingServe = false
    /// The change running is the sweep for leftovers, which never touches the live entry.
    nonisolated(unsafe) private static var sweeping = false

    nonisolated static func beginServeChange(sweep: Bool = false) -> Bool {
        publishLock.withLock {
            guard !changingServe else { return false }
            changingServe = true
            sweeping = sweep
            return true
        }
    }

    nonisolated static func endServeChange() { publishLock.withLock { changingServe = false; sweeping = false } }

    /// Whether quitting may give the live entry back now, and whether it took the
    /// flag doing so (then it ends it). A running sweep leaves the live entry alone
    /// — no publish can have made a newer one while it runs — so waiting on it
    /// would only leave that entry behind when the process exits.
    nonisolated static func beginReleaseAtQuit() -> (allowed: Bool, owns: Bool) {
        publishLock.withLock {
            guard changingServe else { changingServe = true; return (true, true) }
            return (sweeping, false)
        }
    }
    nonisolated static let otaPortKey = "otaPort"
    /// A port of RoamRun's own, rather than a path on the tailnet's `:443`.
    /// 443 carries whatever else the user serves, so a mistake there is theirs,
    /// not ours — and Funnel can only publish 443, 8443 and 10000, so a port
    /// outside those three cannot be put on the internet at all, by anyone.
    /// 41443 is in IANA's unassigned 41112-41793 block, below the ephemeral
    /// range macOS hands out, and says what it is for.
    nonisolated static var otaPort: Int {
        otaPort(AppID.settings?.integer(forKey: otaPortKey) ?? 0)
    }

    /// A setting that can't work is ignored rather than retried every 30 s: a
    /// privileged port would put the page on the tailnet's `:22` or `:80`
    /// (tailscaled is root and would take it), and one over 65535 is refused by
    /// `tailscale serve` for ever.
    nonisolated static func otaPort(_ set: Int) -> Int {
        (1024...65535).contains(set) && !funnelCapable.contains(set) ? set : 41443
    }
    nonisolated static let funnelCapable: Set<Int> = [443, 8443, 10000]

    func startOTAIfNeeded() {
        // The port can be changed while we run, so it has to take effect without
        // a restart — and the old one has to be given back, not forgotten.
        if let published = otaPublished, published.port != Self.otaPort {
            guard Self.beginServeChange() else { return }            // one of these is already running
            Task.detached { [weak self] in
                defer { Self.endServeChange() }
                guard Self.releaseServe(published) else {             // the next tick tries again
                    await MainActor.run { self?.couldNotRelease(published.port) }
                    return
                }
                await MainActor.run { if self?.otaPublished?.port == published.port { self?.otaPublished = nil } }
            }
            return
        }
        guard let apps = OTA.appDirectories() else {
            // Couldn't read the folder — a descriptor limit, a permission change.
            // Taking the page down here would cut a download in flight and make
            // the address dead until the next tick; leaving it up costs nothing.
            return
        }
        // Offer cleanup a turn before retrying a failed publish.
        let due = Self.due(portChanged: otaPublished.map { $0.port != Self.otaPort } ?? false,
                           published: otaPublished != nil, listening: otaServer?.listening == true,
                           hasBuilds: !apps.isEmpty, publishJustFailed: publishWork.yieldToSweep)
        let sweep = publishWork.offerSweep(due: due,
                                          changeInProgress: Self.publishLock.withLock { Self.changingServe },
                                          wanted: strays.wanted, hasRemembered: !Self.remembered().isEmpty)
        if sweep, Self.beginServeChange(sweep: true) {
            let live = otaPublished
            let startedAt = strays.generation
            Task.detached { [weak self] in
                defer { Self.endServeChange() }
                let done = Self.reclaimStrays(keeping: live) == true
                await MainActor.run { self?.strays.finished(done, startedAt: startedAt) }
            }
        }
        guard !apps.isEmpty else {
            // Deleting the folder is the off switch, whether or not the page ever
            // got published: the listener goes either way, one still coming up too.
            otaAttempt += 1
            otaServer?.stop()
            otaServer = nil
            if let published = otaPublished, Self.beginServeChange() {
                // Not cleared until it is really gone: an entry left pointing at a
                // port nothing holds any more would otherwise be unfindable.
                Task.detached { [weak self] in                     // shells out twice; not on the main actor
                    defer { Self.endServeChange() }
                    guard Self.releaseServe(published) else {
                        await MainActor.run { self?.couldNotRelease(published.port) }
                        return
                    }
                    await MainActor.run { if self?.otaPublished?.port == published.port { self?.otaPublished = nil } }
                }
            }
            return
        }
        // Not just "is it published": a listener that failed after it was ready
        // leaves the registration pointing at a port nothing holds, and this is
        // the only place that builds a new one. Published *and* listening is the
        // state that needs nothing done.
        if otaPublished != nil, otaServer?.listening == true {
            verifyOTAStillServed()
            return
        }
        if otaPublished != nil {
            // Not released first: the new listener gets a new ephemeral port, and
            // registering that replaces the root handler on the same tailnet port.
            // Releasing in parallel would race the re-registration for it.
            logStore.log("the over-the-air server stopped; starting it again")
            otaPublished = nil
            // The registration outlives the state we just cleared. If the publish
            // that follows doesn't land, nothing else would look for it again —
            // and a port change in between would walk past it entirely.
            strays.askAgain()
            otaServer?.stop()
            otaServer = nil
        }
        // One of these can still be running when the 30 s timer comes round:
        // without the guard the same address is registered twice and the later
        // failure overwrites the earlier success in the log.
        guard Self.beginServeChange() else { return }
        publishWork.began()   // before the listener and every preflight that can return early
        let tailnetPort = Self.otaPort
        // Said out loud rather than just ignored: otherwise `defaults write` looks
        // as if it did nothing.
        if let set = AppID.settings?.integer(forKey: Self.otaPortKey), set != 0, set != tailnetPort {
            complainOnce("otaPort \(set) can't be used — it has to be 1024-65535 and not one of " +
                         "\(Self.funnelCapable.sorted().map(String.init).joined(separator: ", ")), " +
                         "which Tailscale Funnel could publish. Serving on \(tailnetPort).")
        }
        if let running = otaServer, running.tailnetPort != tailnetPort {
            running.stop()
            otaServer = nil
        }
        let server = otaServer ?? OTAServer(tailnetPort: tailnetPort)
        otaAttempt += 1
        let attempt = otaAttempt
        Task.detached { [weak self] in
            defer { Self.endServeChange() }
            // Off the main actor: the listener can take up to 5 s to come up.
            guard let port = server.start() else {
                await MainActor.run { self?.complainOnce("couldn't start the over-the-air server") }
                return
            }
            // Turned off (or quitting) while it came up: a server nobody wants
            // would hold its port until the app quits.
            let wanted = await MainActor.run { () -> Bool in
                guard let self, self.otaAttempt == attempt else { return false }
                self.otaServer = server
                return true
            }
            guard wanted else { server.stop(); return }
            let mine = "http://127.0.0.1:\(port)"
            // Only ever replace an entry we can prove we made — ours from a run
            // that ended without releasing it. Anything else on that port is the
            // user's, and `tailscale serve` has no undo.
            let state = TailscaleClient.serving(port: tailnetPort)
            // Both halves or neither: `serve` acts on this name's key alone, so
            // without it we don't know which entry we would be replacing.
            guard state != .unknown, let host = Self.currentHost() else {
                // tailscaled didn't answer, or there is no tailscale here at all.
                // Publishing now would be deciding the port is free without having
                // looked; the timer asks again — but say so, or this is silent.
                await MainActor.run {
                    self?.complainOnce("can't read `tailscale serve status`, so RoamRun won't touch port " +
                                       "\(tailnetPort) — is Tailscale installed and running? Retrying.")
                }
                return
            }
            // The page answers under this name only; a rename republishes, which sets it again.
            server.servedName = host
            // Never set by RoamRun and not possible on a port Funnel can publish —
            // but that list is Tailscale's policy, and this page would be on the
            // open internet. Loud, and it does not stop us serving: the entry is
            // the user's to turn off.
            if state.funnelled(on: host) {
                await MainActor.run {
                    self?.complainOnce("port \(tailnetPort) has Tailscale Funnel switched on, so the install " +
                                       "page is reachable from the public internet. " +
                                       "`tailscale funnel --https=\(tailnetPort) off` turns it off.")
                }
            }
            switch state {
            case .nothing, .unknown:   // unknown is ruled out above; the switch has to name it
                break
            case .mounted:
                let here = state.root(on: host)
                let beside = state.alongside(host)
                guard beside.isEmpty, here.map({ $0 == mine || Self.isOurs($0, on: tailnetPort) }) ?? true else {
                    // Three different situations, and the user's next move differs
                    // in each: a port they use for something else, one carrying a
                    // registration of ours that outlived its run, or one where the
                    // settings naming our registrations were deleted with the app.
                    let why: String
                    if !beside.isEmpty {
                        why = "port \(tailnetPort) also carries \(beside.joined(separator: ", ")), and RoamRun keeps " +
                              "a port to itself. Give it another one: defaults write \(AppID.bundle) otaPort -int 41444"
                    } else if Self.abandoned(here) {
                        why = "port \(tailnetPort) is serving \(state.described) with nothing behind it, so it is " +
                              "left over from a run that was killed: `tailscale serve --https=\(tailnetPort) " +
                              "--set-path=/ off` clears it and RoamRun publishes again within half a minute"
                    } else {
                        why = "port \(tailnetPort) is serving \(state.described), which isn't RoamRun's — not " +
                              "taking it over. Give RoamRun another port: " +
                              "defaults write \(AppID.bundle) otaPort -int 41444"
                    }
                    await MainActor.run { self?.complainOnce(why) }
                    return
                }
            }
            let step = await Self.publish(mine, on: tailnetPort, expecting: state) {
                await MainActor.run { self?.otaAttempt == attempt }
            }
            let after: TailscaleClient.Serving, said: String
            switch step {
            case .changed:
                await MainActor.run {
                    self?.complainOnce("port \(tailnetPort) changed while RoamRun was checking it; looking again shortly")
                }
                return
            case .notWanted, .withdrawn:
                server.stop()
                return
            case .ran(let state, let output):
                after = state
                said = output
            }
            // The exit code is not the answer; the config is. `tailscale serve`
            // exits 0 without writing anything when the tailnet has no HTTPS
            // certificates: it prints the admin page's link to stdout and calls
            // `os.Exit(0)` (serve_legacy.go, enableFeatureInteractive, reached
            // from serve_v2.go:259 before any config is touched). Reading that as
            // success logged "serving builds over the air" every minute while
            // nothing was served — and `doctor` sent people to that log to find
            // out why the page was missing.
            let landed = after.isRegistered(mine)
            // A status we couldn't read says nothing either way, so it is neither
            // a success nor a reason to drop the one record that can find it again.
            let unsure = after == .unknown
            await MainActor.run {
                guard let self else { return }
                if landed {
                    self.publishWork.registered()
                    self.otaPublished = (tailnetPort, mine)
                    self.otaComplaint = ""
                    self.logStore.log("serving builds over the air on port \(tailnetPort)")
                } else if unsure {
                    // Tracked all the same: it may well be there, and an untracked
                    // registration is one the port-change branch walks past. The
                    // 30 s check either confirms it or clears it.
                    self.publishWork.registered()
                    self.otaPublished = (tailnetPort, mine)
                    self.complainOnce("published port \(tailnetPort), but `tailscale serve status` didn't " +
                                      "answer, so RoamRun can't confirm it. Checking again shortly.")
                } else {
                    // Whatever `tailscale` said, the entry isn't there. Its stdout
                    // carries the only thing that explains the silent case — a link
                    // to the page where HTTPS certificates are turned on.
                    self.complainOnce("port \(tailnetPort) isn't served after asking tailscale to, will retry" +
                                      (said.isEmpty ? ". Does your tailnet have HTTPS certificates turned on?"
                                                    : ": \(said)"))
                    // Remembered before the call in case we died during it. It
                    // didn't take, so drop it: a window full of addresses that
                    // were never registered can't recognise one that was.
                    Self.forgetServing(mine, on: tailnetPort)
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
            // `unknown` says nothing about the entry. Forgetting it on a status we
            // couldn't read would leave it registered with nothing tracking it —
            // and the next port change would have no old port to give back.
            let gone: Bool
            var host: String?
            let state = TailscaleClient.serving(port: published.port)
            switch state {
            case .unknown: gone = false
            case .nothing: gone = true
            // Under this node's name only: the entry we made under a name it has
            // since stopped answering to is one `serve` can no longer reach.
            case .mounted:
                host = Self.currentHost()
                gone = host.map { state.root(on: $0) != published.target } ?? false
            }
            await MainActor.run {
                guard let self else { return }
                self.verifyingOTA = false
                if gone, self.otaPublished?.target == published.target { self.otaPublished = nil }
                // Still ours under the name the node answers to now: the page follows it.
                if !gone, let host { self.otaServer?.servedName = host }
            }
        }
    }

    enum PublishStep: Equatable {
        case changed      // the port isn't as it was checked: nothing written
        case notWanted    // turned off before writing: nothing written
        case withdrawn    // turned off while `serve` ran: given back, or left to the sweep
        case ran(after: TailscaleClient.Serving, said: String)
    }

    /// The write itself, between two looks at whether it is still wanted. `state` is what
    /// the port carried when checked; the reads before can take 20 s, and `serve` replaces
    /// whatever is at `/` by then. Looking again narrows that window; it can't close it, as
    /// `tailscale serve` has no write-if-unchanged. Turned off meanwhile: publishing a
    /// stopped server would leave the address answering 502 until the next tick.
    nonisolated static func publish(_ mine: String, on port: Int, expecting state: TailscaleClient.Serving,
                                    tools: ServeTools = .live,
                                    stillWanted: @Sendable () async -> Bool) async -> PublishStep {
        guard tools.serving(port, 10) == state else { return .changed }
        guard await stillWanted() else { return .notWanted }
        // Written before the call, not after: quitting while `tailscale` is
        // still working would otherwise leave an entry finished by a child
        // that outlived us, with nothing left to say it was ours.
        tools.remember(mine, port)
        let said = tools.serve(port, mine)
        guard await stillWanted() else {
            // False leaves the record, and the next sweep gives it back.
            _ = releaseServe((port: port, target: mine), tools: tools)
            return .withdrawn
        }
        // Here, not after hopping back: `serving` waits on `tailscale` for up to
        // 10 s and the main actor is where the menu bar lives.
        return .ran(after: tools.serving(port, 10), said: said)
    }

    /// Gives a registration back, but only while it is still exactly ours.
    /// `nonisolated` so it can run off the main actor: it shells out twice, and
    /// only the call at quit has to be synchronous.
    /// Whether the entry is gone. False means it is still there and the caller
    /// has to try again — reporting it released when it isn't is how builds stay
    /// reachable while the log says otherwise.
    nonisolated static func releaseServe(_ published: (port: Int, target: String),
                                         timeout: TimeInterval = 10, tools: ServeTools = .live) -> Bool {
        let state = tools.serving(published.port, timeout)
        let host: String
        switch state {
        case .unknown: return false            // couldn't look; saying it's gone is how one survives
        case .nothing: tools.forget(published.target, published.port); return true
        case .mounted:
            // `off` removes this node's current name's mount and nothing else, so
            // that is the only entry we may claim — a root of ours under a name the
            // node has since changed would make us delete whatever took its place.
            // Asked only now: nothing to give back needs no name.
            guard let named = tools.host(timeout) else { return false }
            guard state.root(on: named) == published.target else {
                tools.forget(published.target, published.port)
                return true
            }
            host = named
        }
        // Only once it's really gone. Forgetting it while the entry survives
        // would leave the next run unable to recognise its own registration —
        // and `off` exiting 0 is not that: it is how it reports removing nothing.
        guard tools.off(published.port, timeout) else { return false }
        let after = tools.serving(published.port, timeout)
        guard after != .unknown, after.root(on: host) != published.target else { return false }
        tools.forget(published.target, published.port)
        return true
    }

    /// What giving back and sweeping `tailscale serve` entries touch: Tailscale, and the
    /// record of what this Mac registered. The defaults are the real ones; tests swap them.
    struct ServeTools: Sendable {
        var serving: @Sendable (_ port: Int, _ timeout: TimeInterval) -> TailscaleClient.Serving = {
            TailscaleClient.serving(port: $0, timeout: $1)
        }
        var host: @Sendable (_ timeout: TimeInterval) -> String? = { AppCoordinator.currentHost(timeout: $0) }
        /// `--set-path=/` names the one mount to remove. Without it `off` means every mount
        /// on the port, and `tailscale` then asks for confirmation on a stdin that is
        /// /dev/null here: it removes nothing and still exits 0, reporting a release that
        /// never happened. True when it exited 0.
        var off: @Sendable (_ port: Int, _ timeout: TimeInterval) -> Bool = { port, timeout in
            Proc.run(TailscaleClient.fromSettings().resolvedPath() ?? "/usr/bin/false",
                     ["serve", "--https=\(port)", "--set-path=/", "off"], timeout: timeout).status == 0
        }
        /// What `tailscale` printed, for when the entry isn't there afterwards.
        var serve: @Sendable (_ port: Int, _ target: String) -> String = { port, target in
            let out = Proc.run(TailscaleClient.fromSettings().resolvedPath() ?? "/usr/bin/false",
                               ["serve", "--bg", "--yes", "--https=\(port)", target], timeout: 20)
            return (out.err + "\n" + out.out).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var remember: @Sendable (_ target: String, _ port: Int) -> Void = { AppCoordinator.rememberServing($0, on: $1) }
        var remembered: @Sendable () -> [String] = { AppCoordinator.remembered() }
        var forget: @Sendable (_ target: String, _ port: Int) -> Void = { AppCoordinator.forgetServing($0, on: $1) }
        var otaPort: @Sendable () -> Int = { AppCoordinator.otaPort }

        static let live = ServeTools()
    }

    /// An entry proxying to a loopback port nothing is listening on can't be a
    /// service of anyone's: some run was killed before it gave the port back.
    /// Reported, not reclaimed — "only replace what we can prove is ours" is worth
    /// more than saving the user one command.
    nonisolated static func abandoned(_ target: String?) -> Bool {
        guard let target, target.hasPrefix("http://127.0.0.1:"),
              let port = UInt16(target.dropFirst("http://127.0.0.1:".count)) else { return false }
        return !TailscaleClient.listening(on: port)
    }

    /// The name this node answers to now. `tailscale serve` writes and removes
    /// under it and no other, so it is half of every question about that port.
    nonisolated static func currentHost(timeout: TimeInterval = 5) -> String? {
        (try? TailscaleClient.fromSettings().selfDNSName(timeout: timeout)) ?? nil
    }

    /// Said, or a release `tailscale` keeps not doing retries every tick in silence.
    private func couldNotRelease(_ port: Int) {
        complainOnce("couldn't confirm port \(port) was given back; trying again. " +
                     "`tailscale serve --https=\(port) --set-path=/ off` clears it")
    }

    private func complainOnce(_ line: String) {
        guard line != otaComplaint else { return }
        otaComplaint = line
        logStore.log(line)
    }

    private func stopOTA() {
        // Not guarded on the listener: the off switch clears it first and leaves
        // the registration until the release succeeds, so at quit there can be one
        // to give back with no server left.
        let server = otaServer
        otaServer = nil
        otaAttempt += 1
        if let published = otaPublished {
            otaPublished = nil
            // Before the listener, not after: in between, the address answers 502
            // rather than stopping. Synchronously here, because this runs from
            // willTerminate where a detached task would not outlive the process.
            let release = Self.beginReleaseAtQuit()
            if !release.allowed {
                // One is already on its way out. Racing it is how the `off` that
                // arrives second removes whatever took the port; the record stays,
                // so the next run recognises the entry and gives it back.
                logStore.log("port \(published.port) is already being changed; leaving it to that")
            } else {
                // Short here, unlike the background paths: this runs on the thread
                // the app quits on. Four calls in a row, so ~8 s at worst, and only
                // when tailscaled isn't answering — which is when `off` fails anyway.
                // The record stays, so the next launch reclaims it.
                let gone = Self.releaseServe(published, timeout: 2)
                if release.owns { Self.endServeChange() }   // a leak here would wedge every later change
                if !gone {
                    logStore.log("couldn't give port \(published.port) back; `tailscale serve --https=\(published.port) --set-path=/ off` clears it")
                }
            }
        }
        server?.stop()
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

    /// Where a ready device is, for the status line ("Ready for Xcode · Cellular") —
    /// or a paused one ("Waiting for device · Cellular").
    func network(of id: UUID) -> DeviceNetwork? {
        if let e = externalBridges[id] { return e.deviceNetwork }
        guard let b = bridges[id] else { return nil }
        return b.status == .ready ? b.network : b.pausedOnCellular ? .cellular : nil
    }

    /// The status as the device list shows it.
    func statusText(of id: UUID) -> String {
        let title = status(of: id).title
        return network(of: id).map { "\(title) · \($0.title)" } ?? title
    }

    /// Worst state across all bridges, for the menu bar icon.
    var overallStatus: BridgeStatus {
        let all = profiles.map { status(of: $0.id) }   // CLI-owned devices report the CLI's state
        for s in [BridgeStatus.error, .ready, .waiting, .preparing, .starting, .local] where all.contains(s) { return s }
        return .off
    }

    // MARK: - Profiles

    enum AddResult: Equatable { case added(UUID), refused(String) }

    @discardableResult
    func addDevice(captured: CapturedService, provider: MeshProvider,
                   meshDevice: MeshDevice?, manualIP: String, name: String) -> AddResult {
        let ip = provider == .manual ? manualIP.trimmingCharacters(in: .whitespaces) : (meshDevice?.ipv4 ?? "")
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let displayName = trimmed.isEmpty ? captured.shortHost : trimmed
        // Same checks as the sheet, here too: two profiles for one device would collide.
        // By UDID when remotepairingd knows the advert (instance names rotate), else the exact advert.
        let udid = advertUDIDs[captured.instanceName]
        guard !ip.isEmpty else { return .refused("Choose its VPN address.") }
        if let problem = profiles.nameProblem(displayName) { return .refused(problem) }
        if let same = profiles.first(where: { $0.providerIP == ip || $0.instanceName == captured.instanceName
            || (udid != nil && $0.udid?.caseInsensitiveCompare(udid!) == .orderedSame) }) {
            return .refused("This device is already saved as “\(same.displayName)”.")
        }
        var profile = DeviceProfile(
            displayName: displayName,
            instanceName: captured.instanceName,
            serviceType: captured.serviceType,
            domain: captured.domain,
            remotePairingPort: captured.port,
            bonjourHost: captured.host,
            txt: captured.txt,
            providerID: provider.rawValue,
            providerHostName: provider == .manual ? ip : (meshDevice?.name ?? ""),
            providerIP: ip
        )
        // Known already if remotepairingd matched this advert; else learned on first connect.
        profile.udid = udid
        profiles.append(profile)
        let bridge = install(newBridge(profile))
        capture.ownedHosts.insert(bridge.spoofHost)
        persist()
        logStore.log("added \"\(profile.displayName)\" -> \(ip)", device: profile.id)
        learnDeviceTypes()
        return .added(profile.id)
    }

    func deleteProfile(_ id: UUID) {
        stopExternalBridge(id)   // a `roamrun up` for it would otherwise live on, unstoppable by name
        if let spoof = bridges[id]?.spoofHost { capture.ownedHosts.remove(spoof) }
        if selectedID == id { selectedID = nil }
        if let b = bridges[id] {
            b.stop()   // its status entry would stay, and the same iPhone added again read as a duplicate
            if b.statusWritePending { departing.append(b) }
        }
        bridges[id] = nil
        bridgeObservers[id] = nil
        memories[id] = nil
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
        bridge.requestStart(.manual)
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
    /// Only the latest refresh's answer counts: an earlier, slower one must not overwrite it.
    private var tailscaleRefresh = 0

    func refreshTailscale() {
        let client = tailscaleClient
        tailscaleRefresh += 1
        let mine = tailscaleRefresh
        Task {
            let result = await Task.detached { Result { try client.listDevices() } }.value
            guard mine == tailscaleRefresh else { return }
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

    /// A bridge for `profile` that carries its device's memory.
    private func newBridge(_ profile: DeviceProfile) -> ProxyBridge {
        let memory = memories[profile.id] ?? DeviceMemory()
        memories[profile.id] = memory
        return ProxyBridge(profile: profile, memory: memory)
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
        bridge.onYield = { [weak self] other in self?.startWhenFree(id, after: other, .resume) }
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
    /// What the scan found, also said next to its button (nil while one runs).
    @discardableResult
    func scanRemotePairingPort(_ profile: DeviceProfile) async -> String {
        let host = profile.providerIP
        logStore.log("\"\(profile.displayName)\": scanning \(host) for its RemotePairing port", device: profile.id)
        let found: UInt16
        // Asked for and watched: time enough for every port even on a host that drops probes.
        switch await ReachabilityProbe.findRemotePairingPort(host: host, limit: .seconds(120)) {
        case .found(let port): found = port
        case .notFound:
            logStore.log("\"\(profile.displayName)\": no RemotePairing port responded — is the device on Wi-Fi?", device: profile.id)
            return "No port answered. Is the device on Wi‑Fi and unlocked?"
        case .timedOut:
            logStore.log("\"\(profile.displayName)\": the scan timed out before every port was checked", device: profile.id)
            return "The scan timed out before every port was checked."
        }
        if found == profile.remotePairingPort {
            logStore.log("\"\(profile.displayName)\": RemotePairing port is still \(found)", device: profile.id)
            return "Still on port \(found)."
        } else {
            // Before persist(): it may rebuild the bridge, and a new one reads as off.
            let wasOn = bridges[profile.id].map { $0.state != .off } == true
            guard let updated = Self.saveScannedPort(found, for: profile.id, in: profiles, save: { changed in
                profiles = changed
                persist()
                return profiles
            }) else { return "Found port \(found), but the device is no longer saved." }
            logStore.log("\"\(profile.displayName)\": RemotePairing port updated to \(found)", device: profile.id)
            // ProxyBridge holds its profile by value — swap it in or the
            // new port only takes effect after a relaunch.
            // Also errored / standing aside: the scan is how you fix a bridge that can't reach the device.
            bridges[profile.id]?.stop()
            install(newBridge(updated))
            // Through autoStart: a live `roamrun up` holding the device keeps it (F16).
            if wasOn { autoStart(profile.id, live: StatusFile.read(), .rescan) }
            return "Moved to port \(found)\(wasOn ? "; the bridge restarts on it" : "")."
        }
    }

    /// Who runs a device's bridge in another process, for a label: `roamrun up` in a terminal,
    /// or another copy of the app. Nil when this app does (or nobody).
    func runElsewhere(_ id: UUID) -> String? {
        guard let e = externalBridges[id] else { return nil }
        return e.cli == true ? "Terminal" : "another RoamRun"
    }

    /// Saving can restore devices ahead of this one; select the saved profile by ID.
    nonisolated static func saveScannedPort(_ port: UInt16, for id: UUID, in profiles: [DeviceProfile],
                                          save: ([DeviceProfile]) -> [DeviceProfile]) -> DeviceProfile? {
        var changed = profiles
        guard let index = changed.firstIndex(where: { $0.id == id }) else { return nil }
        changed[index].remotePairingPort = port
        return save(changed).first { $0.id == id }
    }

    /// Swaps a running bridge's profile by rebuilding it: `ProxyBridge` holds the
    /// profile by value, so otherwise the new endpoint only takes effect at the
    /// next launch — and the bridge spends a retry finding it out for itself.
    private func replaceBridge(with profile: DeviceProfile) {
        guard let old = bridges[profile.id], old.profile != profile else { return }
        let wasOn = old.state != .off
        old.stop()
        install(newBridge(profile))
        if wasOn { autoStart(profile.id, live: StatusFile.read(), .edit) }
    }

    /// The one way the app starts a bridge by itself (restore at launch, the 30 s
    /// retry, an IP change, a rebuilt bridge): never over a running `roamrun up`,
    /// which retries on its own and gives up (exit 1) if taken over — then once it
    /// has ended. Starts a person asks for (Start, Try Again) use startBridge.
    private func autoStart(_ id: UUID, live: [UUID: StatusFile.Entry], _ reason: StartReason) {
        guard Snapshot.fakeProfiles == nil else { return }   // screenshot mode's devices never bridge
        if let other = HomeRule.cliHolding(id, udid: bridges[id]?.udid ?? profile(id)?.udid, in: live, myPID: getpid()) {
            startWhenFree(id, after: other, reason)
            return
        }
        if StartPolicy.of(reason).restarts { bridges[id]?.stop() }
        bridges[id]?.requestStart(reason)   // the claim itself defers to a CLI that got there first
    }

    /// Devices waiting in startWhenFree: the 30 s retry must not stack a waiter per tick.
    /// For each, the start it will make once free: what a rescan or an edit meant still holds then.
    private var waitingForCLI: [UUID: StartReason] = [:]

    /// Once `other` — that process, not just its PID — has ended, starts `id` again
    /// if it is still wanted and nothing else started it meanwhile.
    private func startWhenFree(_ id: UUID, after other: StatusFile.Entry, _ reason: StartReason) {
        if let pending = waitingForCLI[id] {
            waitingForCLI[id] = StartReason.stronger(pending, reason)
            return
        }
        waitingForCLI[id] = reason
        Task { @MainActor [weak self] in
            while StatusFile.isRoamRun(other) { try? await Task.sleep(for: .seconds(5)) }
            guard let self else { return }
            let reason = self.waitingForCLI.removeValue(forKey: id) ?? .retry
            guard self.wasActiveIDs.contains(id), self.profile(id) != nil,
                  let b = self.bridges[id], b.state == .off || b.status == .error else { return }
            // Through autoStart again: another `roamrun up` may have taken the device meanwhile.
            self.autoStart(id, live: StatusFile.read(), reason)
        }
    }

    // MARK: - Internals

    /// Terminate all helper children (zone dump, proxy registrations, log
    /// watchers, relays) so nothing is orphaned when the app quits.
    func shutdown() {
        capture.stop()
        stopOTA()   // the serve entry would otherwise point at a dead port
        for bridge in bridges.values { bridge.stop() }
    }

    private func onInterfaceLost() {
        logStore.log("local IP lost; bridges paused until Wi-Fi returns")
        supervisor.lanAddressLost()
    }

    private func onInterfaceChange(_ ip: String) {
        logStore.log("local IP changed -> \(ip); restarting active bridges")
        supervisor.lanAddressChanged()
    }

    /// What the toggle shows, and whether to register again. A registration belongs to the
    /// bundle id, so changing it (0.1.12) or replacing the app drops it while the user's choice
    /// stands. `.requiresApproval` still counts as on: that's them switching it off in System
    /// Settings, which we leave alone.
    /// Why "Open at login" shows off although it was on. Registering belongs to one
    /// bundle id, so switching it on from a build run out of a folder would take the
    /// login item from the installed copy (edfe07e): only an installed copy is invited.
    nonisolated static func lostLoginItemAdvice(bundlePath: String) -> String {
        bundlePath.contains("/Applications/")
            ? "Open at login was lost when RoamRun was replaced or moved, and only the copy in /Applications turns it back on by itself. Switch it on to register this copy."
            : "Open at login is off for this copy. The copy in /Applications turns it back on when it next opens."
    }

    /// `canRegister`: this copy may register itself again (only one in /Applications).
    /// When it can't, a lost registration shows as off — showing it on would say
    /// the app opens at login while nothing is registered.
    nonisolated static func loginItem(saved: Bool?, status: SMAppService.Status,
                                      canRegister: Bool = true) -> (on: Bool, register: Bool) {
        let live = status == .enabled || status == .requiresApproval
        let lost = saved == true && !live
        return (live || (lost && canRegister), lost && canRegister)
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

    nonisolated static var unreadableListWarning: String {
        "RoamRun couldn't read its saved devices (profiles.json in \(ProfileStore.directory.path)), so the list starts empty and nothing is saved over the file. Check its permissions, then reopen RoamRun."
    }
    nonisolated static var saveFailedWarning: String {
        "RoamRun couldn't save your devices (\(ProfileStore.directory.path)). Changes will be lost when it quits — check the disk and folder permissions."
    }

    /// Saves the device list; a failed write would lose changes at the next launch, so say so.
    private func persist() {
        guard Snapshot.fakeProfiles == nil else { return }   // screenshot mode's fake devices never reach disk
        if let saved = store.save(base: savedProfiles, wanted: profiles) {
            savedProfiles = saved
            if saved != profiles {   // `roamrun up` had saved a newer endpoint, or devices we never read came back
                let mine = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let wanted = wasActiveIDs
                let stale = saved.filter { p in mine[p.id].map { $0 != p } ?? false }
                profiles = saved
                for p in stale { replaceBridge(with: p) }   // it holds its profile by value
                // Kept from disk rather than dropped (the list we started from was unreadable): they need bridges.
                for p in saved where bridges[p.id] == nil {
                    capture.ownedHosts.insert(install(newBridge(p)).spoofHost)
                    if wanted.contains(p.id) { autoStart(p.id, live: StatusFile.read(), .restore) }   // left on before it went unread
                }
            }
            // Saved, so the file is readable and written again: those two warnings no longer hold.
            if launchWarning == Self.unreadableListWarning || launchWarning == Self.saveFailedWarning { launchWarning = nil }
            return
        }
        logStore.log("couldn't save the device list to \(ProfileStore.directory.path)")
        launchWarning = Self.saveFailedWarning
    }

    /// Stops helpers a crashed run left behind, off the main thread; says what it did.
    func cleanUpLeftoverHelpers() {
        Task {
            let killed = await Task.detached { DNSServiceProxy.killOrphanedHelpers() }.value
            logStore.log(killed == 0 ? "no leftover helpers found" : "stopped \(killed) leftover helper process(es)")
        }
    }
}
