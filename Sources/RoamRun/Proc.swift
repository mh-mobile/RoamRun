import Foundation

/// The one way RoamRun runs short-lived helper tools.
enum Proc {
    struct Result {
        let status: Int32
        let out: String
        let err: String
    }

    /// Its own queue gets a thread even while callers (e.g. runAsync) block
    /// every Swift concurrency / global-queue thread.
    private static let timers = DispatchQueue(label: "com.roamrun.app.proc-timers")

    /// Runs to completion. Both pipes are drained before waiting — waiting
    /// first deadlocks once a tool writes more than the ~64KB pipe buffer.
    /// Never unbounded: a wedged tool must not hang the CLI or a bridge's checks.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 45) -> Result {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do { try task.run() } catch { return Result(status: -1, out: "", err: error.localizedDescription) }
        timers.asyncAfter(deadline: .now() + timeout) { if task.isRunning { task.terminate() } }
        timers.asyncAfter(deadline: .now() + timeout + 2) {   // ignored TERM
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        }

        // Blocking reads get their own threads: on the shared GCD pool they
        // can use up every worker and hold back the timers above.
        let box = OutputBox()
        let group = DispatchGroup()
        group.enter(); group.enter()
        Thread.detachNewThread { box.set(err: err.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        Thread.detachNewThread { box.set(out: out.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        // A grandchild can keep the pipes open after we killed the tool: stop
        // waiting then (the readers finish whenever that one exits).
        guard group.wait(timeout: .now() + timeout + 4) == .success else {
            return Result(status: -1, out: "", err: "\(path) timed out after \(Int(timeout))s")
        }
        task.waitUntilExit()
        return Result(status: task.terminationStatus,
                      out: String(decoding: box.out, as: UTF8.self),
                      err: String(decoding: box.err, as: UTF8.self))
    }

    /// A long-running helper that can't outlive RoamRun: a tiny `sh` watchdog
    /// runs it and kills it once RoamRun is gone — even after a crash or
    /// SIGKILL. Otherwise a leftover `dns-sd -P` keeps advertising the iPhone
    /// until reboot and can collide with the real one on the LAN.
    static func tied(_ path: String, _ args: [String]) -> Process {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        let watchdog = #"trap 'kill $c 2>/dev/null; wait $c; exit 0' TERM INT HUP; "$0" "$@" & c=$!; while kill -0 $PPID 2>/dev/null && kill -0 $c 2>/dev/null; do sleep 0.5 & wait $!; done; kill $c 2>/dev/null; wait $c"#
        task.arguments = ["-c", watchdog, path] + args
        return task
    }

    /// Same, off the calling actor.
    static func runAsync(_ path: String, _ args: [String]) async -> Result {
        await Task.detached { run(path, args) }.value
    }
}

/// Feeds a long-running child's stdout to `onLine`, one complete line at a
/// time. readabilityHandler calls are already serial; bytes are buffered and
/// split on "\n" so a UTF-8 character split across chunks stays intact.
/// Detaches itself at EOF so a dead pipe doesn't spin the handler.
final class LineReader: @unchecked Sendable {
    private var pending = Data()

    init(_ pipe: Pipe, onLine: @escaping (String) -> Void) {
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
    private var _out = Data(), _err = Data()
    var out: Data { lock.withLock { _out } }
    var err: Data { lock.withLock { _err } }
    func set(out: Data) { lock.withLock { _out = out } }
    func set(err: Data) { lock.withLock { _err = err } }
}
