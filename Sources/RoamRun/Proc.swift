import Foundation

/// The one way RoamRun runs short-lived helper tools.
enum Proc {
    struct Result {
        let status: Int32
        let out: String
        let err: String
    }

    /// Runs to completion. Both pipes are drained before waiting — waiting
    /// first deadlocks once a tool writes more than the ~64KB pipe buffer.
    static func run(_ path: String, _ args: [String]) -> Result {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do { try task.run() } catch { return Result(status: -1, out: "", err: error.localizedDescription) }

        var errData = Data()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) { errData = err.fileHandleForReading.readDataToEndOfFile() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        task.waitUntilExit()
        return Result(status: task.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self))
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
