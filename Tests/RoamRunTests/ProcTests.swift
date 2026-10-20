import Foundation
import Testing
@testable import RoamRun

// MARK: - Helper processes never hang us

private func timed(_ path: String, _ args: [String]) -> (Proc.Result, TimeInterval) {
    let start = Date()
    let r = Proc.run(path, args, timeout: 1)
    return (r, Date().timeIntervalSince(start))
}

// Timing tests run one at a time: in parallel on a small CI runner they'd skew each other.
extension TimingSensitive {
    @Suite(.serialized) struct ProcTiming {
        @Test func slowToolsFillingTheTaskPoolStillTimeOut() async {
            // A Proc.run called from a task blocks a Swift concurrency thread; with every one of
            // them blocked, the timeout timers must still get to run.
            // Each run is timed from its own start: other tests may hold the pool first.
            let longest = await withTaskGroup(of: TimeInterval.self) { group in
                for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
                    group.addTask { await Task.detached { timed("/bin/sleep", ["20"]).1 }.value }
                }
                return await group.reduce(0, max)
            }
            #expect(longest < 4)
        }

        /// #32: blocking tools wait off Swift's cooperative pool. On it, twice as many as it
        /// has threads (one per core) ran in two waves, each bridge's check behind another's.
        @Test func blockingToolsDontQueueBehindEachOther() async {
            let n = min(ProcessInfo.processInfo.activeProcessorCount * 2, Blocking.limit)
            let clock = ContinuousClock(), start = clock.now
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<n { group.addTask { _ = await Blocking.run { usleep(1_000_000) } } }
            }
            let took = clock.now - start
            #expect(took < .milliseconds(1_800), "\(n) one-second waits took \(took)")
        }

        /// Beyond the limit, tools wait their turn: two permits, four half-second jobs, two
        /// waves, and never more than two at once.
        @Test func blockingWorkBeyondTheLimitWaitsItsTurn() async {
            let gate = Blocking.Gate(2)
            final class Count: @unchecked Sendable { let l = NSLock(); var now = 0, peak = 0 }
            let count = Count()
            let clock = ContinuousClock(), start = clock.now
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<4 {
                    group.addTask {
                        await gate.enter()
                        count.l.withLock { count.now += 1; count.peak = max(count.peak, count.now) }
                        try? await Task.sleep(for: .milliseconds(500))
                        count.l.withLock { count.now -= 1 }
                        gate.leave()
                    }
                }
            }
            let took = clock.now - start
            #expect(count.peak == 2)
            #expect(took >= .milliseconds(950) && took < .milliseconds(1_800), "\(took)")
        }

        @Test func quickToolReturnsItsOutput() {
            let (r, t) = timed("/bin/echo", ["hello"])
            #expect(r.status == 0 && r.out == "hello\n")
            #expect(t < 2.5, "t=\(t)")   // it returns at once; the bound is for a busy machine
        }

        @Test func slowToolIsStoppedAtTheTimeout() {
            let (r, t) = timed("/bin/sleep", ["20"])
            #expect(r.status != 0 && r.err.contains("timed out"), "status=\(r.status) err=\(r.err)")
            #expect(t < 2.5, "t=\(t)")
        }

        @Test func toolIgnoringTermIsKilled() {
            let (r, t) = timed("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"])
            #expect(r.status == 9, "status=\(r.status) err=\(r.err) t=\(t)")   // SIGKILL 2s after the ignored TERM
            #expect(t < 4.5, "t=\(t)")
        }

        @Test func grandchildHoldingThePipeDoesNotHangUs() {
            // sh is killed, but its `sleep` keeps stdout open.
            let (r, t) = timed("/bin/sh", ["-c", "trap '' TERM; sleep 8"])
            #expect(r.status == 9, "status=\(r.status) err=\(r.err)")
            #expect(t < 6, "t=\(t)")
        }

        /// TERM right after launch, before the watchdog has even noted its child's pid:
        /// the child must still go, and the watchdog with it.
        @Test func aWatchdogStoppedAtOnceTakesItsChildAlong() async throws {
            let marker = "41.\(Int.random(in: 100_000...999_999))"   // sleep's argument, to find strays
            // The TERM comes later each round, from before the shell has set its trap (it just
            // dies) on through the moment between the trap and `c=$!`, until enough rounds
            // were the watchdog's own to end: those take the fifth of a second its loop sleeps.
            var its = 0
            for i in 0..<160 where its < 12 {
                let t = Proc.tied("/bin/sleep", [marker])
                t.standardOutput = FileHandle.nullDevice
                try t.run()
                usleep(useconds_t(i) * 250)   // 0–40 ms
                let sent = ContinuousClock().now
                t.terminate()
                // That it ends, not how fast: a busy machine takes its time over the shell's own
                // forks. Never killed from here — that is what would leave its child behind.
                let clock = ContinuousClock(), start = clock.now
                while t.isRunning && clock.now - start < .seconds(10) { try await Task.sleep(for: .milliseconds(20)) }
                if t.isRunning {
                    let pid = t.processIdentifier
                    let family = Proc.run("/bin/sh", ["-c", "ps -o pid,ppid,stat,etime,command -p \(pid) $(pgrep -P \(pid) | sed 's/^/-p /')"]).out
                    Issue.record("round \(i): the watchdog outlived its TERM by 10 s:\n\(family)")
                    _ = await Proc.ensureGone(t, grace: .zero)
                    break
                }
                if ContinuousClock().now - sent > .milliseconds(100) { its += 1 }
            }
            #expect(its > 0, "no TERM came after the trap was set: nothing of the watchdog was tried")
            try await Task.sleep(for: .milliseconds(200))
            // `sleep <marker>` as a command of its own: the watchdog's own line holds the words too.
            let strays = Proc.run("/usr/bin/pgrep", ["-fl", "^/bin/sleep \(marker)"]).out
            #expect(strays.isEmpty, "left behind: \(strays)")
            _ = Proc.run("/usr/bin/pkill", ["-f", "sleep \(marker)"])
        }

        /// The watchdog's shell must not lose a TERM sent while it sets its trap, as bash 3.2
        /// (/bin/sh) does: it ignores the signal meanwhile, once for each signal named.
        @Test func aTermWhileTheWatchdogSetsItsTrapIsntLost() async throws {
            let shell = try #require(Proc.tied("/usr/bin/true", []).executableURL)
            let marker = "42.\(Int.random(in: 100_000...999_999))"   // sleep's argument, to find strays
            defer { _ = Proc.run("/usr/bin/pkill", ["-f", "^/bin/sleep \(marker)"]) }
            // A long trap command named eight times: setting it takes long enough to be hit.
            let script = #"b=x; i=0; while [ $i -lt 20 ]; do b=$b$b; i=$((i+1)); done; echo; trap "exit 3 #$b" TERM TERM TERM TERM TERM TERM TERM TERM; /bin/sleep "$0" >/dev/null 2>&1 & wait $!"#
            // A round the TERM ended before the trap sends the next one later, a round the trap
            // took sends it sooner: so the TERMs keep landing while it is set, however fast the machine.
            var delay: useconds_t = 0, early = 0, trapped = 0
            for round in 0..<200 where trapped < 30 {
                let t = Process()
                t.executableURL = shell
                t.arguments = ["-c", script, marker]
                let out = Pipe()
                t.standardOutput = out
                try t.run()
                _ = out.fileHandleForReading.readData(ofLength: 1)   // about to set the trap
                usleep(delay)
                t.terminate()
                let clock = ContinuousClock(), start = clock.now
                while t.isRunning && clock.now - start < .seconds(5) { try await Task.sleep(for: .milliseconds(10)) }
                if t.isRunning {
                    Issue.record("round \(round): the TERM sent \(delay) µs after the echo was lost")
                    kill(t.processIdentifier, SIGKILL)
                    return
                }
                if t.terminationReason == .uncaughtSignal {
                    early += 1
                    delay += trapped == 0 ? 500 : 100
                } else {
                    #expect(t.terminationStatus == 3, "round \(round)")
                    trapped += 1
                    delay -= min(delay, 100)
                }
            }
            #expect(early > 0 && trapped > 0, "early=\(early) trapped=\(trapped): the TERMs never straddled the trap")
        }

        /// A child that ignores TERM: the watchdog can't stop it, so the caller does.
        @Test func aRegistrationThatWontStopIsKilledAndConfirmedGone() async throws {
            let t = Proc.tied("/bin/sh", ["-c", "trap '' TERM; exec /bin/sleep 30"])
            t.standardOutput = FileHandle.nullDevice
            try t.run()
            try await Task.sleep(for: .milliseconds(300))   // the trap is set
            let child = Proc.run("/usr/bin/pgrep", ["-P", "\(t.processIdentifier)"]).out
            t.terminate()
            // A second signal (Ctrl-C to the group, then stop()) must not let it leave the child.
            try await Task.sleep(for: .milliseconds(300))
            t.terminate()
            #expect(await Proc.ensureGone(t))
            #expect(!t.isRunning)
            let pids = child.split(separator: "\n").compactMap { Int32($0) }   // may include its `sleep 0.5`
            #expect(!pids.isEmpty)
            for pid in pids { #expect(kill(pid, 0) != 0, "pid \(pid) outlived the watchdog") }
            // Only what is still there: a pid that has gone may be another process's by now.
            for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }

        @Test func toolThatExitsKeepsItsResultWhileABackgroundChildHoldsThePipe() {
            let (r, t) = timed("/bin/sh", ["-c", "echo hi; sleep 30 &"])
            #expect(r.status == 0 && r.out == "hi\n", "status=\(r.status) out=\(r.out)")
            #expect(t < 2.5, "t=\(t)")
        }
    }
}

@Test func orphansAreOnlyOurHelpersWithADeadParent() {
    let ps = """
      101     1 /usr/bin/dns-sd -P 6E44 _remotepairing._tcp local 49152 rr-1.roamrun.local 192.168.1.2
      106     1 /usr/bin/dns-sd -i en0 -P 6E44 _remotepairing._tcp local 49152 rr-3.roamrun.local 192.168.1.2
      102   500 /usr/bin/dns-sd -P 6E44 _remotepairing._tcp local 49152 rr-2.roamrun.local 192.168.1.2
      103     1 /usr/bin/dns-sd -P Mine _http._tcp local 80 myhost.local 192.168.1.2
      104     1 /usr/bin/log stream --predicate process == "remotepairingd" AND (eventMessage CONTAINS "Got tunnel endpoint" OR eventMessage CONTAINS "Resolved bonjour advert")
      105     1 /usr/bin/log stream --predicate subsystem == "x"
    """
    #expect(DNSServiceProxy.orphans(fromPS: ps) == [101, 106, 104])
}
