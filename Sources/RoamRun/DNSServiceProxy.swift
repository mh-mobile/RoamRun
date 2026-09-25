import Foundation

/// Publishes a fake `_remotepairing._tcp` announcement by spawning
/// `/usr/bin/dns-sd -P`. The registration lives in the child process: as long
/// as it runs, mDNSResponder announces the service on the LAN, pointing the
/// SRV target at *this Mac's* IP so remotepairingd connects to our local relay.
///
///   dns-sd -P <name> <type> <domain> <port> <host> <ip> [k=v ...]
final class DNSServiceProxy {
    private var process: Process?
    private var lastArgs: [String] = []
    /// `dns-sd -P` died on its own (not via stop()/renew()): the record is gone.
    var onExit: ((Int32) -> Void)?

    /// - Parameters:
    ///   - instanceName: captured service instance name (republished verbatim)
    ///   - port: local relay port advertised in the fake SRV record
    ///   - host: spoof hostname ending in `.local` (its A record becomes `ip`)
    ///   - ip: this Mac's address on the LAN interface (e.g. en0 IPv4)
    ///   - txt: captured TXT entries republished verbatim
    func register(instanceName: String, serviceType: String, domain: String,
                  port: UInt16, host: String, ip: String,
                  txt: [String: String]) throws {
        var args = ["-P", instanceName, serviceType, domain, String(port), host, ip]
        args += txt.map { "\($0.key)=\($0.value)" }
        lastArgs = args
        guard spawn(args) else { throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "dns-sd -P failed to launch"]) }
    }

    @discardableResult
    private func spawn(_ args: [String]) -> Bool {
        let task = Proc.tied("/usr/bin/dns-sd", args)
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self] t in
            DispatchQueue.main.async {
                guard let self, self.process === t else { return }
                self.process = nil
                self.onExit?(t.terminationStatus)
            }
        }
        guard (try? task.run()) != nil else { return false }
        process = task
        return true
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    /// Withdraw and re-announce the same record. remotepairingd won't
    /// re-discover a record that simply stays up after it gave up on a
    /// control channel (e.g. the iPhone switched networks); a fresh
    /// announcement is the only nudge it listens to.
    func renew() {
        guard !lastArgs.isEmpty else { return }
        // Let the old registration go first, or mDNSResponder may rename ours.
        if let old = process {
            old.terminate()
            // Poll rather than waitUntilExit(): that spins the run loop, and a
            // stop() re-entering here would be undone by the spawn below.
            var tries = 0
            while old.isRunning && tries < 100 { usleep(10_000); tries += 1 }
        }
        process = nil
        if !spawn(lastArgs) { onExit?(-1) }
    }

    /// Kill helper processes left behind by a crashed/killed previous launch:
    /// `dns-sd -P` proxy registrations (matched by our spoof-host marker) and
    /// `log stream` watchers for the tunnel endpoint.
    @discardableResult
    static func killOrphanedHelpers(matching marker: String = ".roamrun.local",
                                    onLog: ((String) -> Void)? = nil) -> Int {
        var killed = 0
        for pid in orphanedHelpers(matching: marker) where kill(pid, SIGTERM) == 0 {
            killed += 1
            onLog?("Killed leftover helper process (pid \(pid))")
        }
        return killed
    }

    /// PIDs of our helper processes whose parent died (re-parented to
    /// launchd). Helpers of a live `roamrun up` or app instance don't count.
    private static func orphanedHelpers(matching marker: String) -> [Int32] {
        let out = Proc.run("/bin/ps", ["-axo", "pid=,ppid=,command="]).out
        return out.split(separator: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            let isProxy = l.contains("dns-sd") && l.contains("-P") && l.contains(marker)
            let isLogWatch = l.contains("log stream") && l.contains("Got tunnel endpoint") && l.contains("Resolved bonjour advert")
            // Only processes that are unmistakably ours (our host marker / our
            // exact log predicate) — never a user's own dns-sd or log session.
            guard isProxy || isLogWatch else { return nil }
            let parts = l.split(whereSeparator: { $0 == " " })
            guard parts.count > 2, let pid = Int32(parts[0]), parts[1] == "1" else { return nil }
            return pid
        }
    }

    /// Leftover helpers without killing them (for `roamrun doctor`).
    static func orphanedHelperCount(matching marker: String = ".roamrun.local") -> Int {
        orphanedHelpers(matching: marker).count
    }

}
