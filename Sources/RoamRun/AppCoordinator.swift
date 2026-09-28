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

    nonisolated static func rememberServing(_ target: String) {
        servingLock.withLock {
            AppID.settings?.set(remembering(AppID.settings?.stringArray(forKey: otaServingKey) ?? [], target),
                                forKey: otaServingKey)
        }
    }

    nonisolated static func forgetServing(_ target: String) {
        servingLock.withLock {
            AppID.settings?.set((AppID.settings?.stringArray(forKey: otaServingKey) ?? []).filter { $0 != target },
                                forKey: otaServingKey)
        }
    }

    /// Newest last, no repeats, and only the last few: an address is worth
    /// recognising for as long as an entry using it could still be lying around.
    nonisolated static func remembering(_ seen: [String], _ target: String, keep: Int = 5) -> [String] {
        Array((seen.filter { $0 != target } + [target]).suffix(keep))
    }

    nonisolated static func isOurs(_ target: String) -> Bool { remembered().contains(target) }

    nonisolated static func remembered() -> [String] {
        servingLock.withLock { AppID.settings?.stringArray(forKey: otaServingKey) ?? [] }
    }

    /// Gives back a registration this Mac made and never released — the last run
    /// was killed, or quit while `tailscale` was still thinking. Nothing else
    /// looks: `otaPublished` is this run's, and when `ota/` is empty the rest of
    /// `startOTAIfNeeded` returns before it would.
    @discardableResult
    nonisolated static func reclaimStray(on port: Int) -> Bool {
        guard let host = currentHost() else { return false }
        guard let target = TailscaleClient.serving(port: port).root(on: host), isOurs(target) else { return false }
        return releaseServe((port: port, target: target))
    }
    /// Said once per reason: the retry runs every 30s and the log is a person's.
    private var otaComplaint = ""
    private var verifyingOTA = false
    /// Once a launch: an entry left by a run that didn't give it back is invisible
    /// to `otaPublished`, which only ever exists in memory.
    private var lookedForStrays = false
    /// One change to `tailscale serve` at a time, publish or release. Each takes
    /// up to 35 s of shelling out and the timer comes round every 30, so without
    /// this they overlap — and two overlapping releases can each read "the entry
    /// is ours" before either runs `off`, so the second removes whatever took the
    /// port in between. That is the deletion this whole path exists to avoid.
    /// A flag rather than holding a lock: these run in detached tasks that hop
    /// threads, and NSLock must be unlocked by the thread that took it.
    nonisolated static let publishLock = NSLock()
    nonisolated(unsafe) private static var changingServe = false

    nonisolated static func beginServeChange() -> Bool {
        publishLock.withLock {
            guard !changingServe else { return false }
            changingServe = true
            return true
        }
    }

    nonisolated static func endServeChange() { publishLock.withLock { changingServe = false } }
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
                guard Self.releaseServe(published) else { return }   // else the next tick tries again
                await MainActor.run { if self?.otaPublished?.port == published.port { self?.otaPublished = nil } }
            }
            return
        }
        // Before the off switch, not after it: with `ota/` deleted the branch below
        // returns, and a registration from a previous run would never be looked for.
        if !lookedForStrays, !Self.remembered().isEmpty {
            lookedForStrays = true
            let port = Self.otaPort
            if Self.beginServeChange() {
                Task.detached {
                    defer { Self.endServeChange() }
                    _ = Self.reclaimStray(on: port)
                }
            } else {
                lookedForStrays = false   // busy; the timer comes round again
            }
        }
        guard let apps = OTA.appDirectories() else {
            // Couldn't read the folder — a descriptor limit, a permission change.
            // Taking the page down here would cut a download in flight and make
            // the address dead until the next tick; leaving it up costs nothing.
            return
        }
        guard !apps.isEmpty else {
            // Deleting the folder is the off switch, whether or not the page ever
            // got published: the listener goes either way.
            otaServer?.stop()
            otaServer = nil
            if let published = otaPublished, Self.beginServeChange() {
                // Not cleared until it is really gone: an entry left pointing at a
                // port nothing holds any more would otherwise be unfindable.
                Task.detached { [weak self] in                     // shells out twice; not on the main actor
                    defer { Self.endServeChange() }
                    guard Self.releaseServe(published) else { return }
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
            otaServer?.stop()
            otaServer = nil
        }
        // One of these can still be running when the 30 s timer comes round:
        // without the guard the same address is registered twice and the later
        // failure overwrites the earlier success in the log.
        guard Self.beginServeChange() else { return }
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
        // ponytail: opening the listener waits on the network stack, so this can
        // hold the main actor for up to 5 s if it never comes up. Moving it off
        // needs OTAServer out of this actor's region; do that if it ever shows.
        guard let port = server.start() else {
            Self.endServeChange()
            complainOnce("couldn't start the over-the-air server")
            return
        }
        otaServer = server
        Task.detached { [weak self] in
            defer { Self.endServeChange() }
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
                guard beside.isEmpty, here.map({ $0 == mine || Self.isOurs($0) }) ?? true else {
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
            // Written before the call, not after: quitting while `tailscale` is
            // still working would otherwise leave an entry finished by a child
            // that outlived us, with nothing left to say it was ours.
            Self.rememberServing(mine)
            let out = Proc.run(TailscaleClient.fromSettings().resolvedPath() ?? "/usr/bin/false",
                               ["serve", "--bg", "--yes", "--https=\(tailnetPort)", mine], timeout: 20)
            // Before hopping back: `serving` waits on `tailscale` for up to 10 s,
            // and the main actor is where the menu bar lives. A status we couldn't
            // read says nothing about whether the registration landed, so it is
            // not a reason to drop the one record that can find it again.
            var strayRecord = false
            if out.status != 0 {
                let after = TailscaleClient.serving(port: tailnetPort)
                strayRecord = after != .unknown && !after.isRegistered(mine)
            }
            await MainActor.run {
                guard let self else { return }
                if out.status == 0 {
                    self.otaPublished = (tailnetPort, mine)
                    self.otaComplaint = ""
                    self.logStore.log("serving builds over the air on port \(tailnetPort)")
                } else {
                    // No HTTPS in this tailnet, tailscaled still coming up, or no
                    // Tailscale at all. The timer tries again, so this recovers.
                    self.complainOnce("couldn't publish port \(tailnetPort) with tailscale serve, will retry: " +
                        out.err.trimmingCharacters(in: .whitespacesAndNewlines))
                    // Remembered before the call in case we died during it. It
                    // didn't take, so drop it: a window full of addresses that
                    // were never registered can't recognise one that was.
                    if strayRecord { Self.forgetServing(mine) }
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
            let state = TailscaleClient.serving(port: published.port)
            switch state {
            case .unknown: gone = false
            case .nothing: gone = true
            // Under this node's name only: the entry we made under a name it has
            // since stopped answering to is one `serve` can no longer reach.
            case .mounted: gone = Self.currentHost().map { state.root(on: $0) != published.target } ?? false
            }
            await MainActor.run {
                guard let self else { return }
                self.verifyingOTA = false
                if gone, self.otaPublished?.target == published.target { self.otaPublished = nil }
            }
        }
    }

    /// Gives a registration back, but only while it is still exactly ours.
    /// `nonisolated` so it can run off the main actor: it shells out twice, and
    /// only the call at quit has to be synchronous.
    /// Whether the entry is gone. False means it is still there and the caller
    /// has to try again — reporting it released when it isn't is how builds stay
    /// reachable while the log says otherwise.
    nonisolated static func releaseServe(_ published: (port: Int, target: String),
                                         timeout: TimeInterval = 10) -> Bool {
        let state = TailscaleClient.serving(port: published.port, timeout: timeout)
        switch state {
        case .unknown: return false            // couldn't look; saying it's gone is how one survives
        case .nothing: forgetServing(published.target); return true
        case .mounted:
            // `off` removes this node's current name's mount and nothing else, so
            // that is the only entry we may claim — a root of ours under a name the
            // node has since changed would make us delete whatever took its place.
            // Asked only now: nothing to give back needs no name.
            guard let host = currentHost(timeout: timeout) else { return false }
            guard state.root(on: host) == published.target else { forgetServing(published.target); return true }
        }
        // `--set-path=/` names the one mount to remove. Without it `off` means
        // every mount on the port, and `tailscale` then asks for confirmation on
        // a stdin that is /dev/null here: it removes nothing and still exits 0,
        // so this would report a release that never happened.
        let out = Proc.run(TailscaleClient.fromSettings().resolvedPath() ?? "/usr/bin/false",
                           ["serve", "--https=\(published.port)", "--set-path=/", "off"], timeout: timeout)
        // Only once it's really gone. Forgetting it while the entry survives
        // would leave the next run unable to recognise its own registration.
        guard out.status == 0 else { return false }
        forgetServing(published.target)
        return true
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
        if let published = otaPublished {
            otaPublished = nil
            // Before the listener, not after: in between, the address answers 502
            // rather than stopping. Synchronously here, because this runs from
            // willTerminate where a detached task would not outlive the process.
            if !Self.beginServeChange() {
                // One is already on its way out. Racing it is how the `off` that
                // arrives second removes whatever took the port; the record stays,
                // so the next run recognises the entry and gives it back.
                logStore.log("a release of port \(published.port) was already running; leaving it to that one")
            } else {
                // Short here, unlike the background paths: this runs on the thread
                // the app quits on, and the long wait only happens when tailscaled
                // isn't answering — which is exactly when `off` fails anyway. The
                // record stays, so the next launch reclaims it.
                let gone = Self.releaseServe(published, timeout: 2)
                Self.endServeChange()   // both callers terminate, but a leak here would wedge every later change
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
