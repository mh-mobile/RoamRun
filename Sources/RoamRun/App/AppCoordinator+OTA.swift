import Foundation

extension AppCoordinator {
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
    nonisolated static func token(_ port: Int, _ target: String) -> String {
        "\(port) \(target)"
    }

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
        Array((seen.filter {
            $0 != target
        } + [target]).suffix(keep))
    }

    nonisolated static func isOurs(_ target: String, on port: Int, in record: [String] = remembered()) -> Bool {
        record.contains {
            let p = pair($0); return p.target == target && (p.port == nil || p.port == port)
        }
    }

    nonisolated static func remembered() -> [String] {
        servingLock.withLock {
            AppID.settings?.stringArray(forKey: otaServingKey) ?? []
        }
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
        case releaseOldPort // `otaPort` changed under a live registration
        case stopServing // `ota/` deleted while one stands
        case restartListener // registered, but nothing is listening
        case publish // builds, and nothing registered
        case nothing
    }

    /// `publishJustFailed` gives the sweep a turn between retries: a publish that
    /// can't succeed — the port taken, say — must not defer the release of an old
    /// one for ever, and that release may well be what frees the port.
    nonisolated static func due(portChanged: Bool, published: Bool, listening: Bool,
                                hasBuilds: Bool, publishJustFailed: Bool) -> Due
    {
        if published && portChanged {
            return .releaseOldPort
        }
        if published && !hasBuilds {
            return .stopServing
        }
        if published && !listening {
            return .restartListener
        }
        if !published && hasBuilds {
            return publishJustFailed ? .nothing : .publish
        }
        return .nothing
    }

    nonisolated static func reclaimStrays(keeping live: (port: Int, target: String)?,
                                          tools: ServeTools = .live) -> Bool?
    {
        guard let host = tools.host(5) else { return nil }
        var asked = true, released = true
        for port in Set(tools.remembered().compactMap {
            pair($0).port
        } + [tools.otaPort()]).sorted() {
            let state = tools.serving(port, 10)
            guard state != .unknown else { asked = false; continue }
            guard let target = state.root(on: host), isOurs(target, on: port, in: tools.remembered()) else { continue }
            // The one this run is serving from, confirmed or not.
            if live?.port == port, live?.target == target {
                continue
            }
            if !releaseServe((port: port, target: target), tools: tools) {
                released = false
            }
        }
        return asked ? released : nil
    }

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

    /// Every attempt owes the sweep a turn unless its registration is tracked.
    struct PublishWork: Equatable {
        private(set) var yieldToSweep = false

        mutating func began() {
            yieldToSweep = true
        }

        mutating func registered() {
            yieldToSweep = false
        }

        mutating func offerSweep(due: Due, changeInProgress: Bool, wanted: Bool,
                                 hasRemembered: @autoclosure () -> Bool) -> Bool
        {
            guard due == .nothing, !changeInProgress else { return false }
            // A running attempt still owes its turn when it finishes.
            // Otherwise offering consumes it, even with nothing to sweep.
            yieldToSweep = false
            return wanted && hasRemembered()
        }
    }

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

    nonisolated static func endServeChange() {
        publishLock.withLock {
            changingServe = false; sweeping = false
        }
    }

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
        (1024 ... 65535).contains(set) && !funnelCapable.contains(set) ? set : 41443
    }

    nonisolated static let funnelCapable: Set<Int> = [443, 8443, 10000]

    func startOTAIfNeeded() {
        // The port can be changed while we run, so it has to take effect without
        // a restart — and the old one has to be given back, not forgotten.
        if let published = otaPublished, published.port != Self.otaPort {
            guard Self.beginServeChange() else { return } // one of these is already running
            Task.detached { [weak self] in
                defer { Self.endServeChange() }
                guard Self.releaseServe(published) else { // the next tick tries again
                    await MainActor.run {
                        self?.couldNotRelease(published.port)
                    }
                    return
                }
                await MainActor.run {
                    if self?.otaPublished?.port == published.port {
                        self?.otaPublished = nil
                    }
                }
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
        let due = Self.due(portChanged: otaPublished.map {
            $0.port != Self.otaPort
        } ?? false,
        published: otaPublished != nil, listening: otaServer?.listening == true,
        hasBuilds: !apps.isEmpty, publishJustFailed: publishWork.yieldToSweep)
        let sweep = publishWork.offerSweep(due: due,
                                           changeInProgress: Self.publishLock.withLock {
                                               Self.changingServe
                                           },
                                           wanted: strays.wanted, hasRemembered: !Self.remembered().isEmpty)
        if sweep, Self.beginServeChange(sweep: true) {
            let live = otaPublished
            let startedAt = strays.generation
            Task.detached { [weak self] in
                defer { Self.endServeChange() }
                let done = Self.reclaimStrays(keeping: live) == true
                await MainActor.run {
                    self?.strays.finished(done, startedAt: startedAt)
                }
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
                Task.detached { [weak self] in // shells out twice; not on the main actor
                    defer { Self.endServeChange() }
                    guard Self.releaseServe(published) else {
                        await MainActor.run {
                            self?.couldNotRelease(published.port)
                        }
                        return
                    }
                    await MainActor.run {
                        if self?.otaPublished?.port == published.port {
                            self?.otaPublished = nil
                        }
                    }
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
        publishWork.began() // before the listener and every preflight that can return early
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
                await MainActor.run {
                    self?.complainOnce("couldn't start the over-the-air server")
                }
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
            case .nothing, .unknown: // unknown is ruled out above; the switch has to name it
                break
            case .mounted:
                let here = state.root(on: host)
                let beside = state.alongside(host)
                guard beside.isEmpty, here.map({
                    $0 == mine || Self.isOurs($0, on: tailnetPort)
                }) ?? true else {
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
                    await MainActor.run {
                        self?.complainOnce(why)
                    }
                    return
                }
            }
            let step = await Self.publish(mine, on: tailnetPort, expecting: state) {
                await MainActor.run {
                    self?.otaAttempt == attempt
                }
            }
            let after: TailscaleClient.Serving, said: String
            switch step {
            case .changed:
                await MainActor.run {
                    self?
                        .complainOnce(
                            "port \(tailnetPort) changed while RoamRun was checking it; looking again shortly"
                        )
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
            let adopted = await MainActor.run { () -> Bool in
                // Turned off during that last read: what it wrote is for a stopped server.
                guard let self, self.otaAttempt == attempt else { return false }
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
                return true
            }
            // Still under the lock, so nothing else is changing the port. False leaves
            // the record for the next sweep.
            if !adopted {
                server.stop()
                _ = Self.releaseServe((port: tailnetPort, target: mine))
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
                gone = host.map {
                    state.root(on: $0) != published.target
                } ?? false
            }
            await MainActor.run {
                guard let self else { return }
                self.verifyingOTA = false
                if gone, self.otaPublished?.target == published.target {
                    self.otaPublished = nil
                }
                // Still ours under the name the node answers to now: the page follows it.
                if !gone, let host {
                    self.otaServer?.servedName = host
                }
            }
        }
    }

    enum PublishStep: Equatable {
        case changed // the port isn't as it was checked: nothing written
        case notWanted // turned off before writing: nothing written
        case withdrawn // turned off while `serve` ran: given back, or left to the sweep
        case ran(after: TailscaleClient.Serving, said: String)
    }

    /// The write itself, between two looks at whether it is still wanted. `state` is what
    /// the port carried when checked; the reads before can take 20 s, and `serve` replaces
    /// whatever is at `/` by then. Looking again narrows that window; it can't close it, as
    /// `tailscale serve` has no write-if-unchanged. Turned off meanwhile: publishing a
    /// stopped server would leave the address answering 502 until the next tick.
    nonisolated static func publish(_ mine: String, on port: Int, expecting state: TailscaleClient.Serving,
                                    tools: ServeTools = .live,
                                    stillWanted: @Sendable () async -> Bool) async -> PublishStep
    {
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
                                         timeout: TimeInterval = 10, tools: ServeTools = .live) -> Bool
    {
        let state = tools.serving(published.port, timeout)
        let host: String
        switch state {
        case .unknown: return false // couldn't look; saying it's gone is how one survives
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

        var host: @Sendable (_ timeout: TimeInterval) -> String? = {
            AppCoordinator.currentHost(timeout: $0)
        }

        /// `--set-path=/` names the one mount to remove. Without it `off` means every mount
        /// on the port, and `tailscale` then asks for confirmation on a stdin that is
        /// /dev/null here: it removes nothing and still exits 0, reporting a release that
        /// never happened. True when it exited 0.
        var off: @Sendable (_ port: Int, _ timeout: TimeInterval) -> Bool = { port, timeout in
            Proc.run(TailscaleClient.fromSettings().resolvedPath() ?? "/usr/bin/false",
                     ["serve", "--https=\(port)", "--set-path=/", "off"], timeout: timeout)
                .status == 0
        }

        /// What `tailscale` printed, for when the entry isn't there afterwards.
        var serve: @Sendable (_ port: Int, _ target: String) -> String = { port, target in
            let out = Proc.run(TailscaleClient.fromSettings().resolvedPath() ?? "/usr/bin/false",
                               ["serve", "--bg", "--yes", "--https=\(port)", target], timeout: 20)
            return (out.err + "\n" + out.out).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var remember: @Sendable (_ target: String, _ port: Int) -> Void = {
            AppCoordinator.rememberServing($0, on: $1)
        }

        var remembered: @Sendable () -> [String] = {
            AppCoordinator.remembered()
        }

        var forget: @Sendable (_ target: String, _ port: Int) -> Void = {
            AppCoordinator.forgetServing($0, on: $1)
        }

        var otaPort: @Sendable () -> Int = {
            AppCoordinator.otaPort
        }

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

    func stopOTA() {
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
                if release.owns {
                    Self.endServeChange()
                } // a leak here would wedge every later change
                if !gone {
                    logStore
                        .log(
                            "couldn't give port \(published.port) back; `tailscale serve --https=\(published.port) --set-path=/ off` clears it"
                        )
                }
            }
        }
        server?.stop()
    }
}
