import AppKit
import Foundation

extension CLI {
    // Kept alive for the lifetime of `up`.
    private static var bridge: ProxyBridge?
    /// Another process bridges the device. Ready → nothing to do; still coming up → say so.
    /// Another `roamrun up` already runs for it, in any state. Its errors are retried, not
    /// given up: a second would take the entry back and forth with it, and `down` stops only
    /// whichever holds the entry then — the other bridges again once the device answers.
    private static func refuseSecondUp(_ profile: DeviceProfile) {
        guard let e = otherUp(StatusFile.read()[profile.id], me: getpid()) else { return }
        if e.kind == .local {
            print(
                "\(profile.displayName) is on this Wi\u{2011}Fi and already watched by roamrun up (pid \(e.pid)) — it takes over when the device leaves."
            )
            exit(0)
        }
        stop("\(profile.displayName) is already handled by roamrun up (pid \(e.pid)): \(e.status). It keeps retrying; " +
            "roamrun down \(commandName(profile)) stops it.")
    }

    /// The entry when it is another live `roamrun up`'s (`read` drops dead ones), in any state.
    nonisolated static func otherUp(_ e: StatusFile.Entry?, me: Int32) -> StatusFile.Entry? {
        guard let e, e.cli == true, e.pid != me else { return nil }
        return e
    }

    private static func alreadyBridged(_ profile: DeviceProfile, _ e: StatusFile.Entry) -> Never {
        if e.ready {
            print("\(profile.displayName) is already bridged by \(owner(e)) — ready for Xcode.")
            exit(0)
        }
        stop(
            "\(profile.displayName) is being bridged by \(owner(e)) (\(e.status)). Use it once it's ready, or run roamrun down \(commandName(profile)) first."
        )
    }

    static func down(_ profile: DeviceProfile) -> Never {
        guard let e = StatusFile.read()[profile.id] else {
            print("\(profile.displayName) is not bridged.")
            exit(0)
        }
        let who = owner(e) // before it exits and the pid stops resolving
        // Always tell the app too: even when the CLI owns the device, the app
        // may still have it on its restore list and would take it back.
        for name in [stopNotification, legacyStopNotification] {
            DistributedNotificationCenter.default().postNotificationName(
                name, object: profile.id.uuidString, userInfo: nil, deliverImmediately: true
            )
        }
        if e.cli == true, e.pid != getpid() {
            kill(e.pid, SIGTERM)
        } // its handler tears down dns-sd / log children
        // Wait for the owner to clear its status entry.
        var tries = 0
        while StatusFile.read()[profile.id] != nil && tries < 50 {
            usleep(100_000)
            tries += 1
        }
        guard StatusFile.read()[profile.id] == nil else { stop("\(who) did not stop the bridge") }
        print("Stopped \(profile.displayName) (\(who)).")
        exit(0)
    }

    /// The display name is user/network supplied: keep it to one safe path component.
    static func fileSafe(_ name: String) -> String {
        String(name.map {
            $0.isLetter || $0.isNumber || "-_ ".contains($0) ? $0 : "_"
        })
    }

    /// Internal: marks the background copy spawned by `up -d`.
    nonisolated static let detachedFlag = "--detached-child"

    /// `up -d`: re-launch ourselves in a new session with output going to a
    /// log file, wait until the bridge settles, then hand the prompt back.
    static func detach(_ profile: DeviceProfile, verbose: Bool) -> Never {
        if StatusFile.otherOwner(of: profile.id) != nil, let e = StatusFile.read()[profile.id] {
            alreadyBridged(profile, e)
        }
        // Two started together both found nobody, and the second rotated the first's log away
        // from under it: from the check to the child's own claim, one at a time per device.
        var turn = upTurn(for: profile.id, in: ProfileStore.directory)
        refuseSecondUp(profile) // before the log below is rotated away from the one running
        let logURL = detachedLog(profile)
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Keep the previous run's log (an earlier failure may point at it).
        let previous = logURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: logURL, to: previous)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let log = try? FileHandle(forWritingTo: logURL) else { stop("can't write \(logURL.path)") }

        let child = Process()
        child.executableURL = Bundle.main.executableURL?.resolvingSymlinksInPath()
        child.arguments = ["up", profile.id.uuidString, detachedFlag] + (verbose ? ["-v"] : [])
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = log
        child.standardError = log
        do { try child.run() } catch { stop("could not start the background bridge: \(error.localizedDescription)") }

        // Wait (≤60s) for Ready; a slower start keeps going in the background.
        var last = "", lastKind = BridgeStatus.off
        for _ in 0 ..< 120 {
            usleep(500_000)
            guard child.isRunning else {
                // It exits on an error retrying can't fix (see up); its last line says which.
                let tail = (try? String(contentsOf: logURL, encoding: .utf8)).flatMap {
                    $0.split(separator: "\n").last.map(String.init)
                }
                stop("the background bridge exited\(tail.map { ": \($0)" } ?? "") — see \(logURL.path)")
            }
            guard let e = StatusFile.read()[profile.id], e.pid == child.processIdentifier else { continue }
            endTurn(&turn) // the child holds the device now: the next `up` sees it
            if e.status != last {
                last = e.status
                print("  \(e.status)")
            }
            lastKind = e.kind
            if e.ready || e.kind == .local {
                break
            }
        }
        let pid = child.processIdentifier
        switch lastKind {
        case .ready:
            print("\(profile.displayName) is bridged in the background (pid \(pid)).")
        case .local:
            print(
                "\(profile.displayName) is on this Wi‑Fi, so Xcode reaches it directly. The bridge waits in the background (pid \(pid)) and takes over when it leaves."
            )
        default:
            print(
                "\(profile.displayName) isn't ready yet (\(last.isEmpty ? "no status" : last)). The bridge keeps trying in the background (pid \(pid))."
            )
        }
        print("""
          Log:  \(logURL.path)
          Stop: roamrun down \(commandName(profile))
        """)
        exit(lastKind == .ready || lastKind == .local ? 0 : 1)
    }

    /// This `up -d`'s turn at the device: waits for another's to end (it ends when its child has
    /// claimed the device, or with its process). The descriptor to close, or nil when no lock
    /// could be made — then as before, unserialized.
    nonisolated static func upTurn(for id: UUID, in directory: URL, wait: Bool = true) -> Int32? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(
            directory.appendingPathComponent("up-\(id.uuidString).lock").path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            0o600
        )
        guard fd >= 0 else { return nil }
        guard flock(fd, wait ? LOCK_EX : LOCK_EX | LOCK_NB) == 0 else { close(fd)
            return nil
        }
        return fd
    }

    /// Ends a turn, once: asked again (each round of the wait asks) it closes nothing — the
    /// number may be another file's by then.
    nonisolated static func endTurn(_ turn: inout Int32?) {
        if let fd = turn {
            close(fd)
        }
        turn = nil
    }

    /// Where `up -d`'s bridge writes; the previous run's is kept beside it as `.log.1`.
    private static func detachedLog(_ profile: DeviceProfile) -> URL {
        let safeName = fileSafe(profile.displayName)
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/RoamRun", isDirectory: true)
            .appendingPathComponent("\(safeName.isEmpty ? profile.id.uuidString : safeName).log")
    }

    /// The background bridge's stdout and stderr are its log file; one left running for weeks
    /// would fill the disk. Past `limit`, the file becomes `.log.1` (replacing that) and a new
    /// one is opened under the same descriptors. A rename that fails changes nothing: the
    /// writing goes on where it was, and nothing is deleted.
    nonisolated static func rotateLog(
        at url: URL,
        limit: Int64 = 10 << 20,
        fds: [Int32] = [STDOUT_FILENO, STDERR_FILENO]
    ) {
        var st = stat()
        guard let first = fds.first, fstat(first, &st) == 0, st.st_size > limit else { return }
        let fm = FileManager.default
        let previous = url.appendingPathExtension("1")
        let rolling = url.appendingPathExtension("rolling"), backup = url.appendingPathExtension("1.backup")
        // Each step can be undone until the new file is open; only then does the old `.1` go.
        try? fm.removeItem(at: rolling)
        try? fm.removeItem(at: backup)
        guard (try? fm.moveItem(at: url, to: rolling)) != nil else { return }
        let hadPrevious = fm.fileExists(atPath: previous.path)
        func undo() {
            if fm.fileExists(atPath: previous.path), !fm.fileExists(atPath: rolling.path) {
                try? fm.moveItem(at: previous, to: rolling) // step 3 had happened
            }
            if hadPrevious {
                try? fm.moveItem(at: backup, to: previous)
            }
            try? fm.moveItem(at: rolling, to: url)
        }
        guard !hadPrevious || (try? fm.moveItem(at: previous, to: backup)) != nil else { return undo() }
        guard (try? fm.moveItem(at: rolling, to: previous)) != nil else { return undo() }
        let fresh = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fresh >= 0 else { return undo() } // still writing to the renamed file: it gets its name back
        try? fm.removeItem(at: backup)
        for fd in fds {
            dup2(fresh, fd)
        }
        close(fresh)
    }

    static func up(_ profile: DeviceProfile, verbose: Bool, detachedChild: Bool = false) {
        if StatusFile.otherOwner(of: profile.id) != nil, let e = StatusFile.read()[profile.id] {
            alreadyBridged(profile, e)
        }
        refuseSecondUp(profile)
        var logRotation: Timer?
        if detachedChild {
            // Own session: closing the terminal / ending SSH doesn't reach us.
            setsid()
            signal(SIGHUP, SIG_IGN)
            let log = detachedLog(profile)
            logRotation = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
                rotateLog(at: log)
            }
        }
        let bridge = ProxyBridge(profile: profile)
        self.bridge = bridge
        bridge.onLog = { m in
            if verbose {
                print("    \(m)")
            }
        }
        bridge.onYield = { other in
            print("\(profile.displayName): another roamrun up (pid \(other.pid)) is already handling it — exiting.")
            exit(0)
        }
        bridge.onUDID = { udid in // the app saves it too; without this, CLI-only use never learns it
            _ = ProfileStore().update { all in
                guard let i = all.firstIndex(where: {
                    $0.id == profile.id
                }), all[i].udid == nil else { return }
                all[i].udid = udid
            }
        }
        bridge.onProfileChange = { moved in // save where the device answers now, as the app does
            var found = false
            let saved = ProfileStore().update { all in
                guard let i = all.firstIndex(where: {
                    $0.id == moved.id
                }) else { return }
                found = true
                all[i].providerIP = moved.providerIP
                all[i].remotePairingPort = moved.remotePairingPort
                all[i].providerHostName = moved.providerHostName
            }
            guard found || !saved else { return } // a lock we couldn't take never ran the closure
            print(
                "  \(moved.displayName) now answers at \(moved.providerIP):\(moved.remotePairingPort)\(saved ? " (saved)" : " (couldn't save it)")"
            )
        }

        // Print status transitions, not a stream of identical lines.
        var last = ""
        let ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                var line = bridge.status.title
                switch bridge.state {
                case .error(let m): line += " — \(m)"
                case .starting(let step): line += " — \(step)"
                default: break
                }
                if bridge.status == .ready, let n = bridge.network {
                    line += " · \(n.title)"
                }
                if bridge.status == .ready {
                    line += " — pick “\(profile.displayName)” in Xcode. Ctrl-C to stop."
                }
                if bridge.status == .local {
                    line += " — Xcode sees it directly; bridging resumes when it leaves."
                }
                if bridge.status == .waiting, bridge.pausedOnCellular {
                    line += " — on cellular, so the tunnel was closed to save data; it reconnects on Wi‑Fi."
                }
                guard line != last else { return }
                last = line
                print("[\(Date.now.formatted(date: .omitted, time: .standard))] \(line)")
            }
        }
        // Same recovery as the app: retry errors, rebind when the Mac's IP changes, re-announce on wake.
        let supervisor = BridgeSupervisor(all: {
            [bridge]
        }, wanted: { _ in
            true
        }, start: { list, reason in
            for b in list {
                if StartPolicy.of(reason).restarts {
                    b.stop()
                }
                b.requestStart(reason)
            }
        }, gaveUp: { b in
            // Retrying can't fix it (lost pairing, no admin rights): say why and stop.
            let reason = {
                if case .error(let m) = b.state {
                    m
                } else {
                    "the bridge failed"
                }
            }()
            b.stop() // before printing: its "bridge stopped" line mustn't be the log's last
            FileHandle.standardError.write(Data("roamrun: \(reason)\n".utf8))
            exit(1)
        })
        supervisor.run()
        let wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                     object: nil, queue: .main)
        { _ in
            MainActor.assumeIsolated {
                supervisor.woke()
            }
        }
        let monitor = InterfaceMonitor()
        monitor.onLost = {
            Task { @MainActor in
                supervisor.lanAddressLost()
            }
        }
        monitor.onChange = { _ in
            Task { @MainActor in
                supervisor.lanAddressChanged()
            }
        }
        monitor.start()

        // Ctrl-C must tear down dns-sd / log children, or the fake Bonjour
        // record outlives us.
        var sources: [AnyObject] = []
        for sig in detachedChild ? [SIGINT, SIGTERM] : [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                MainActor.assumeIsolated {
                    bridge.stop()
                    print("\nBridge stopped.")
                    exit(0)
                }
            }
            src.resume()
            sources.append(src as AnyObject)
        }
        keepAlive = [ticker, supervisor, monitor, wake] + sources + (logRotation.map {
            [$0]
        } ?? [])

        print("Bridging \(profile.displayName) over \(profile.providerIP)…")
        bridge.requestStart(.manual)
    }
}
