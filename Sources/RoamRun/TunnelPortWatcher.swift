import Foundation

/// Watches `log stream` for remotepairingd's "Got tunnel endpoint" line and
/// reports the UDP/TCP port the CoreDevice tunnel actually landed on, so we
/// can relay exactly that port instead of forwarding a blind range.
/// Started/stopped on the main actor; `handle` runs on the pipe reader's serial queue,
/// and its termination handler hops back to main.
final class TunnelPortWatcher: @unchecked Sendable {
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
    nonisolated(unsafe) private static let pattern = #/tunnel-\d+: Got tunnel endpoint: '([0-9.]+)(?:%[^' :]*)?:(\d+)'/#
    /// The endpoint line doesn't name the device; the line right before it does.
    /// Requests still waiting for their endpoint; two different iPhones among
    /// them means we can't tell whose it is, so the port stays unattributed.
    /// Any endpoint in the known format, e.g. a link-local IPv6 one ('fe80::…%en0.64106') we don't relay.
    nonisolated(unsafe) private static let anyEndpoint = #/tunnel-\d+: Got tunnel endpoint: '[^' ]*'/#
    nonisolated(unsafe) private static let establishPattern = #/device-\d+ \(([0-9A-Fa-f-]+)\): Sending tunnel establish request/#
    private var pending: [(udid: String, at: Date)] = []
    /// After an ambiguous endpoint, any request in flight may be answered by
    /// the wrong one — attribute nothing for a while.
    private var ambiguousUntil = Date.distantPast
    /// What follows the first "Resolved bonjour advert " must be *exactly*
    /// "<uuid> to identity …" to the end of the line. The instance name comes
    /// from the LAN and may contain spaces, so a loose search could be fooled
    /// by a crafted name that embeds a fake "… to identity nil" phrase.
    private static let advertMarker = "Resolved bonjour advert "
    nonisolated(unsafe) private static let advertPattern = #/([0-9A-Fa-f-]+) to identity (?:associated with udid ([0-9A-Fa-f-]+)|nil, udid nil)/#

    /// Apple's own remotepairingd only: any process can be named that and log lines
    /// like these, but only Apple's lives in these SIP-protected places.
    static let fromRemotepairingd = #"process == "remotepairingd" AND (processImagePath BEGINSWITH "/System/" OR processImagePath BEGINSWITH "/Library/Apple/")"#

    /// nil when running; otherwise why `log stream` couldn't be launched.
    @discardableResult
    func start() -> String? {
        guard process == nil else { return nil }
        let task = Proc.tied("/usr/bin/log", [
            "stream", "--style", "compact",
            "--predicate",
            Self.fromRemotepairingd + #" AND (eventMessage CONTAINS "Got tunnel endpoint" OR eventMessage CONTAINS "Sending tunnel establish request" OR eventMessage CONTAINS "Resolved bonjour advert")"#
        ])
        let pipe = Pipe(), errPipe = Pipe()
        task.standardOutput = pipe
        task.standardError = errPipe   // e.g. "Must be admin to run 'stream' command"
        reader = LineReader(pipe) { [weak self] line in self?.handle(line) }
        let firstErr = FirstLine()
        errReader = LineReader(errPipe) { firstErr.offer($0) }
        let me = Weak(self)
        task.terminationHandler = { t in
            // Give the stderr reader a moment to deliver the reason.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard let self = me.value, self.process === t else { return }   // stop() isn't a failure
                self.process = nil
                let err = firstErr.value
                self.onExit?("log stream exited (status \(t.terminationStatus))" + (err.isEmpty ? "" : ": \(err)"))
            }
        }
        do {
            try task.run()
            process = task
            onLog?("Watching remotepairingd for tunnel endpoint")
            return nil
        } catch {
            return "log stream failed to start: \(error.localizedDescription)"
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
                                  fromRemotepairingd + " AND eventMessage CONTAINS[c] \"\(phrase)\""], timeout: timeout)
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

/// One `log stream` for every bridge in this process: each line is parsed once
/// and a tunnel port goes only to the bridge whose device asked for it. With a
/// watcher per bridge, every bridge saw every port and they raced to relay it.
@MainActor
final class TunnelCoordinator {
    static let shared = TunnelCoordinator()

    struct Subscriber {
        var udid: () -> String?
        var onPort: (UInt16, String) -> Void          // port, address dialed
        var onDevice: (String, String) -> Void        // instance, UDID
        var onUnrecognized: (String) -> Void
        var onLog: (String) -> Void
        var onExit: (String) -> Void
    }

    private var watcher: TunnelPortWatcher?
    private var subscribers: [UUID: Subscriber] = [:]

    /// False if `log stream` couldn't be started.
    func subscribe(_ id: UUID, _ s: Subscriber) -> Bool {
        subscribers[id] = s
        if watcher != nil { return true }
        let w = TunnelPortWatcher()
        w.onPort = { port, owner, host in Task { @MainActor in TunnelCoordinator.shared.route(port, owner: owner, host: host) } }
        w.onDevice = { instance, udid in
            Task { @MainActor in TunnelCoordinator.shared.subscribers.values.forEach { $0.onDevice(instance, udid) } }
        }
        w.onUnrecognized = { instance in
            Task { @MainActor in TunnelCoordinator.shared.subscribers.values.forEach { $0.onUnrecognized(instance) } }
        }
        w.onLog = { m in Task { @MainActor in TunnelCoordinator.shared.subscribers.values.forEach { $0.onLog(m) } } }
        let exited = Weak(w)
        w.onExit = { m in
            Task { @MainActor in
                let c = TunnelCoordinator.shared
                guard let gone = exited.value, c.watcher === gone else { return }   // not a newer watcher's business
                c.watcher = nil   // the next subscribe starts a fresh one
                c.subscribers.values.forEach { $0.onExit(m) }
            }
        }
        watcher = w
        if let failure = w.start() {
            watcher = nil; subscribers[id] = nil
            s.onLog(failure)   // said here: the subscriber is gone before any broadcast arrives
            return false
        }
        return true
    }

    func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
        if subscribers.isEmpty { watcher?.stop(); watcher = nil }
    }

    private func route(_ port: UInt16, owner: String?, host: String) {
        let subs = subscribers.map { (id: $0.key, udid: $0.value.udid()) }
        // A known device that no bridge here is for (e.g. one on this Wi‑Fi Xcode uses directly): not ours, not news.
        if let owner, !subs.contains(where: { $0.udid == nil || $0.udid?.caseInsensitiveCompare(owner) == .orderedSame }) { return }
        // Another process (the app, or a `roamrun up`) bridging a device: an unattributed port may be its.
        let othersBridging = owner == nil || !subs.contains { $0.udid.map { $0.caseInsensitiveCompare(owner!) == .orderedSame } == true }
            ? StatusFile.read().values.contains { $0.pid != getpid() && $0.holdsDevice } : false
        guard let id = Self.recipient(owner: owner, subscribers: subs, othersBridging: othersBridging) else {
            if owner == nil { subscribers.values.first?.onLog("tunnel port \(port) not relayed: can't tell which bridged device it's for") }
            return
        }
        subscribers[id]?.onPort(port, host)
    }

    /// Who relays a tunnel port. Known owner: the bridge for that UDID. Unknown owner (or a
    /// bridge that hasn't learned its UDID yet): only when that bridge is the only one anywhere.
    nonisolated static func recipient(owner: String?, subscribers: [(id: UUID, udid: String?)], othersBridging: Bool) -> UUID? {
        if let owner, let match = subscribers.first(where: { $0.udid?.caseInsensitiveCompare(owner) == .orderedSame }) {
            return match.id
        }
        guard !othersBridging else { return nil }
        if owner == nil { return subscribers.count == 1 ? subscribers[0].id : nil }
        let unknown = subscribers.filter { $0.udid == nil }
        return subscribers.count == 1 && unknown.count == 1 ? unknown[0].id : nil
    }
}
