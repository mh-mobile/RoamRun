import Foundation

/// The one way RoamRun runs short-lived helper tools.
enum Proc {
    struct Result {
        let status: Int32
        let out: String
        let err: String
        /// Stopped at the timeout rather than finished.
        var timedOut = false
    }

    /// Its own queue gets a thread even while callers block
    /// every Swift concurrency / global-queue thread.
    private static let timers = DispatchQueue(label: AppID.bundle + ".proc-timers")

    /// Runs to completion. Both pipes are drained while it runs — waiting
    /// first deadlocks once a tool writes more than the ~64KB pipe buffer.
    /// Never unbounded: a wedged tool must not hang the CLI or a bridge's checks.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 45) -> Result {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let out = Pipe(), err = Pipe()
        task.standardInput = FileHandle.nullDevice   // an interactive shell must not read the CLI's terminal
        task.standardOutput = out
        task.standardError = err
        // Not waitUntilExit(): it spins the caller's run loop (often the main one).
        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }
        Passing.shared.launching()
        do { try task.run() } catch {
            Passing.shared.launched(nil)
            return Result(status: -1, out: "", err: error.localizedDescription)
        }
        Passing.shared.launched(task)
        let box = OutputBox()
        timers.asyncAfter(deadline: .now() + timeout) { if task.isRunning { box.timedOut = true; task.terminate() } }
        timers.asyncAfter(deadline: .now() + timeout + 2) {   // ignored TERM
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        }

        // Blocking reads get their own threads: on the shared GCD pool they
        // can use up every worker and hold back the timers above.
        let group = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            group.enter()
            Thread.detachNewThread {
                while case let d = pipe.fileHandleForReading.availableData, !d.isEmpty { box.append(d, out: isOut) }
                group.leave()
            }
        }
        exited.wait()   // bounded by the TERM/KILL timers
        Passing.shared.childEnded()
        // A grandchild can keep the pipes open after the tool exited: keep what
        // it wrote so far (the readers finish whenever that one exits).
        _ = group.wait(timeout: .now() + 1)
        let stderr = String(decoding: box.err, as: UTF8.self)
        return Result(status: task.terminationStatus,
                      out: String(decoding: box.out, as: UTF8.self),
                      err: box.timedOut ? "\(path) timed out after \(Int(timeout))s" + (stderr.isEmpty ? "" : "\n" + stderr) : stderr,
                      timedOut: box.timedOut)
    }

    /// A long-running helper that can't outlive RoamRun: a tiny `sh` watchdog
    /// runs it and kills it once RoamRun is gone — even after a crash or
    /// SIGKILL. Otherwise a leftover `dns-sd -P` keeps advertising the iPhone
    /// until reboot and can collide with the real one on the LAN.
    static func tied(_ path: String, _ args: [String]) -> Process {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The trap only raises a flag: a TERM between `&` and `c=$!` would find no pid to
        // kill, so the loop, which runs after `c` is set, does the killing. The TERM is
        // repeated until the child is gone: one sent before the child's exec meets the
        // trap it inherited and is lost, and a second signal mustn't end the wait early.
        let watchdog = #"t=; trap 't=1' TERM INT HUP; "$0" "$@" & c=$!; while [ -z "$t" ] && kill -0 $PPID 2>/dev/null && kill -0 $c 2>/dev/null; do sleep 0.5 & wait $!; done; kill $c 2>/dev/null; while kill -0 $c 2>/dev/null; do sleep 0.2 & wait $!; kill $c 2>/dev/null; done; wait $c; s=$?; [ -n "$t" ] && exit 0; exit $s"#
        task.arguments = ["-c", watchdog, path] + args
        return task
    }

    /// After a TERM to a `tied` watchdog: true once it has exited, which it does only
    /// after its child. A child that ignored TERM gets KILL after `grace`. The watchdog
    /// itself is never KILLed while it has a child: that would leave the child behind.
    static func ensureGone(_ watchdog: Process, grace: Duration = .seconds(1)) async -> Bool {
        func exited(within d: Duration) async -> Bool {
            let clock = ContinuousClock(), end = clock.now + d
            while watchdog.isRunning && clock.now < end {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { break }   // cancelled: don't spin
            }
            return !watchdog.isRunning
        }
        if await exited(within: grace) { return true }
        if Task.isCancelled { return !watchdog.isRunning }   // given up on: no KILL on the way out
        let pid = watchdog.processIdentifier
        let children = await Blocking.run { run("/usr/bin/pgrep", ["-P", "\(pid)"], timeout: 5).out }
        for pid in children.split(separator: "\n").compactMap({ Int32($0) }) { kill(pid, SIGKILL) }
        return await exited(within: .seconds(2))   // its loop notices within 0.5 s
    }

    /// `xcrun devicectl <args> --json-output …`: its "result" object; nil if it failed.
    static func devicectl(_ args: [String], timeout: TimeInterval = 45) -> [String: Any]? {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = run("/usr/bin/xcrun", ["devicectl", "--quiet"] + args + ["--json-output", out.path], timeout: timeout)
        guard let data = try? Data(contentsOf: out),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["result"] as? [String: Any]
    }

}

/// Feeds a long-running child's stdout to `onLine`, one complete line at a
/// time. readabilityHandler calls are already serial; bytes are buffered and
/// split on "\n" so a UTF-8 character split across chunks stays intact.
/// Detaches itself at EOF so a dead pipe doesn't spin the handler.
final class LineReader: @unchecked Sendable {
    private var pending = Data()

    init(_ pipe: Pipe, onLine: @escaping (String) -> Void) {
        // readabilityHandler calls are serial, so onLine never runs concurrently with itself.
        nonisolated(unsafe) let onLine = onLine
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            pending.append(data)
            while let nl = pending.firstIndex(of: 0x0A) {
                onLine(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...nl)
            }
        }
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _out = Data(), _err = Data(), _timedOut = false
    var timedOut: Bool {
        get { lock.withLock { _timedOut } }
        set { lock.withLock { _timedOut = newValue } }
    }
    var out: Data { lock.withLock { _out } }
    var err: Data { lock.withLock { _err } }
    func append(_ d: Data, out: Bool) { lock.withLock { if out { _out.append(d) } else { _err.append(d) } } }
}

/// A weak reference that can cross into a background callback and hop back to main.
final class Weak<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

extension Proc {
    /// For the CLI's `run` and `install`: a child they wait on (devicectl, ditto, xcodebuild, an
    /// install) must not outlive them. Once begun, TERM and HUP (a `kill`, a closed terminal)
    /// go to the child running now; when it has ended, the process stops the same way. INT
    /// isn't caught: Ctrl-C reaches the whole foreground group already. Inactive until
    /// `begin()`, so the app and `up` are untouched.
    final class Passing: @unchecked Sendable {
        static let shared = Passing()
        private let lock = NSLock()
        private var active = false
        private var starting = 0
        private var child: Process?
        private var caught: Int32?
        private var sources: [DispatchSourceSignal] = []

        func begin() {
            let srcs = [SIGTERM, SIGHUP].map { sig -> DispatchSourceSignal in
                signal(sig, SIG_IGN)
                let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
                src.setEventHandler { [self] in received(sig) }
                src.resume()
                return src
            }
            lock.withLock { active = true; sources = srcs }
        }

        /// What `exec` replaces us with gets the signals back: an ignored one survives exec.
        func endForExec() {
            for sig in [SIGTERM, SIGHUP] { signal(sig, SIG_DFL) }
        }

        func launching() { lock.withLock { if active { starting += 1 } } }
        func launched(_ task: Process?) {
            lock.withLock {
                guard active else { return }
                starting = max(0, starting - 1)
                if let task { child = task }
            }
        }

        /// Right after a child ends: one stopped by our signal means we stop too, by it, rather
        /// than carry on and report the child's failure as if it were the cause.
        func childEnded() {
            guard let sig = lock.withLock({ caught }) else { return }
            signal(sig, SIG_DFL)
            kill(getpid(), sig)
        }

        private func received(_ sig: Int32) {
            lock.withLock { caught = sig }
            // A child being launched right now: let it start, then it gets the signal too.
            for _ in 0..<200 where lock.withLock({ starting > 0 }) { usleep(10_000) }
            if let task = lock.withLock({ child }), task.isRunning {
                kill(task.processIdentifier, sig)
                while task.isRunning { usleep(20_000) }
            }
            signal(sig, SIG_DFL)
            kill(getpid(), sig)
        }
    }
}
