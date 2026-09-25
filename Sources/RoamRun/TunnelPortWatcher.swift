import Foundation

/// Watches `log stream` for remotepairingd's "Got tunnel endpoint" line and
/// reports the UDP/TCP port the CoreDevice tunnel actually landed on, so we
/// can relay exactly that port instead of forwarding a blind range.
final class TunnelPortWatcher {
    /// (port, UDID of the iPhone it belongs to — nil if not seen, the IPv4 address remotepairingd dials).
    var onPort: ((UInt16, String?, String) -> Void)?
    /// (Bonjour instance, UDID) each time remotepairingd authenticates a
    /// control channel — i.e. the device just became reachable.
    var onDevice: ((String, String) -> Void)?
    /// Bonjour instance that remotepairingd could NOT match to a pairing —
    /// the Mac no longer trusts it, or its TXT (authTag) is stale.
    var onUnrecognized: ((String) -> Void)?
    var onLog: ((String) -> Void)?
    /// `log stream` died on its own (not via stop()), with the reason.
    var onExit: ((String) -> Void)?

    private var process: Process?
    private var reader: LineReader?
    private var errReader: LineReader?
    // Advert lines (LAN-supplied names) are routed away before these run; the
    // prefix keeps them strict without breaking if macOS appends a field.
    private static let pattern = #/tunnel-\d+: Got tunnel endpoint: '([0-9.]+)(?:%[^' :]*)?:(\d+)'/#
    /// The endpoint line doesn't name the device; the line right before it does.
    /// Requests still waiting for their endpoint; two different iPhones among
    /// them means we can't tell whose it is, so the port stays unattributed.
    /// Any endpoint in the known format, e.g. a link-local IPv6 one ('fe80::…%en0.64106') we don't relay.
    private static let anyEndpoint = #/tunnel-\d+: Got tunnel endpoint: '[^' ]*'/#
    private static let establishPattern = #/device-\d+ \(([0-9A-Fa-f-]+)\): Sending tunnel establish request/#
    private var pending: [(udid: String, at: Date)] = []
    /// After an ambiguous endpoint, any request in flight may be answered by
    /// the wrong one — attribute nothing for a while.
    private var ambiguousUntil = Date.distantPast
    /// What follows the first "Resolved bonjour advert " must be *exactly*
    /// "<uuid> to identity …" to the end of the line. The instance name comes
    /// from the LAN and may contain spaces, so a loose search could be fooled
    /// by a crafted name that embeds a fake "… to identity nil" phrase.
    private static let advertMarker = "Resolved bonjour advert "
    private static let advertPattern = #/([0-9A-Fa-f-]+) to identity (?:associated with udid ([0-9A-Fa-f-]+)|nil, udid nil)/#

    /// False if `log stream` couldn't be launched.
    @discardableResult
    func start() -> Bool {
        guard process == nil else { return true }
        let task = Proc.tied("/usr/bin/log", [
            "stream", "--style", "compact",
            "--predicate",
            #"process == "remotepairingd" AND (eventMessage CONTAINS "Got tunnel endpoint" OR eventMessage CONTAINS "Sending tunnel establish request" OR eventMessage CONTAINS "Resolved bonjour advert")"#
        ])
        let pipe = Pipe(), errPipe = Pipe()
        task.standardOutput = pipe
        task.standardError = errPipe   // e.g. "Must be admin to run 'stream' command"
        reader = LineReader(pipe) { [weak self] line in self?.handle(line) }
        let firstErr = FirstLine()
        errReader = LineReader(errPipe) { firstErr.offer($0) }
        task.terminationHandler = { [weak self] t in
            // Give the stderr reader a moment to deliver the reason.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard let self, self.process === t else { return }   // stop() isn't a failure
                self.process = nil
                let err = firstErr.value
                self.onExit?("log stream exited (status \(t.terminationStatus))" + (err.isEmpty ? "" : ": \(err)"))
            }
        }
        do {
            try task.run()
            process = task
            onLog?("Watching remotepairingd for tunnel endpoint")
            return true
        } catch {
            onLog?("Failed to start log stream: \(error.localizedDescription)")
            return false
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    func handle(_ line: String, now: Date = .now) {
        pending.removeAll { now.timeIntervalSince($0.at) > 5 }   // a failed request never gets an endpoint
        // Advert lines first: their instance name comes from the LAN.
        if line.contains(Self.advertMarker) {
            if let (instance, udid) = Self.advert(in: line) {
                if let udid { onDevice?(instance, udid) } else { onUnrecognized?(instance) }
            }
            return
        }
        if let m = line.firstMatch(of: Self.pattern), let port = UInt16(m.2) {
            let owners = Set(pending.map(\.udid))
            if owners.count > 1 { ambiguousUntil = now + 5 }
            onPort?(port, owners.count == 1 && now >= ambiguousUntil ? owners.first : nil, String(m.1))
            // Unknown whose request this answered, so the rest can't be trusted either.
            if owners.count > 1 { pending.removeAll() } else if !pending.isEmpty { pending.removeFirst() }
        } else if let m = line.firstMatch(of: Self.establishPattern) {
            pending.append((String(m.1), now))
        } else if line.contains("Got tunnel endpoint"), line.firstMatch(of: Self.anyEndpoint) == nil {
            // The format changed (a macOS update?): say so rather than silently find no ports.
            onLog?("unrecognized tunnel endpoint line: \(line.suffix(160))")
        }
    }

    /// remotepairingd's advert resolutions in the last `window`, oldest first.
    /// `phrase` narrows the query and goes into a log predicate: callers pass fixed text or plain hex.
    static func recentAdverts(last window: String, containing phrase: String = "Resolved bonjour advert",
                              timeout: TimeInterval = 10) -> [(String, String?)] {
        Proc.run("/usr/bin/log", ["show", "--last", window, "--style", "compact", "--predicate",
                                  "process == \"remotepairingd\" AND eventMessage CONTAINS[c] \"\(phrase)\""], timeout: timeout)
            .out.split(separator: "\n").compactMap { advert(in: String($0)) }
    }

    /// (instance, UDID — nil when remotepairingd has no pairing for it).
    static func advert(in line: String) -> (String, String?)? {
        guard let r = line.range(of: advertMarker),
              let m = line[r.upperBound...].trimmingCharacters(in: .whitespaces).wholeMatch(of: advertPattern) else { return nil }
        return (String(m.1), m.2.map(String.init))
    }
}

private final class FirstLine: @unchecked Sendable {
    private let lock = NSLock()
    private var line = ""
    var value: String { lock.withLock { line } }
    func offer(_ l: String) { lock.withLock { if line.isEmpty { line = l } } }
}
