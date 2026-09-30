import Foundation
import Network
import OSLog

private let relayLog = Logger(subsystem: AppID.bundle, category: "relay")

enum RelayError: LocalizedError {
    case bindFailed(String)
    case invalidPort(UInt16)

    var errorDescription: String? {
        switch self {
        case .bindFailed(let m): return m
        case .invalidPort(let p): return "Invalid port \(p)"
        }
    }
}

/// Listens on `localIP:localPort` (TCP) and pumps each inbound connection to
/// `remoteIP:remotePort` over whatever route the OS picks — the mesh VPN.
/// Byte relay only; TLS and pairing auth stay end-to-end.
///
/// Only this Mac may use it: remotepairingd dials our own en0 address, so its
/// connections arrive *from* that address. Anyone else on the LAN — who can
/// see the Bonjour record we publish — is refused, rather than being handed
/// this Mac's tailnet route to the iPhone.
/// Connection bookkeeping is under `lock`; NW callbacks run on global queues.
final class Relay: @unchecked Sendable {
    let localIP: String
    let localPort: UInt16
    let remoteIP: String
    let remotePort: UInt16
    /// Number of connections that actually reached the iPhone (called off-main).
    let onOpenCountChange: ((Int) -> Void)?
    /// The listener died after it was up; called once, off-main. Without it nothing
    /// would notice: the bridge keeps advertising a port nobody answers on.
    let onFailure: ((Relay) -> Void)?
    /// A tunnel relay: its pairs may not take the control channels' reserve.
    let spare: Bool
    private var lastRefusalLog: Date?
    /// The start() waiting for the listener's first verdict.
    private var starting: CheckedContinuation<Void, Error>?
    private var failureReported = false

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    /// Each pair's byte counters, by its inbound connection.
    private var stats: [ObjectIdentifier: ConnStats] = [:]
    /// Inbound connections whose upstream leg is established. An accepted
    /// connection that never reaches the iPhone must not count as "connected".
    private var established = Set<ObjectIdentifier>()
    private var stopped = false
    private let lock = NSLock()
    /// Only local remotepairingd uses a relay; a few connections at most.
    // ponytail: flat cap; a flood from a local process just gets refused.
    private static let maxConnections = 64
    /// Across all relays in this process: each pair is two file descriptors.
    private static let maxTotal = 256
    private static let totalLock = NSLock()
    nonisolated(unsafe) private static var total = 0
    /// Connection pairs open across all relays (tests check it returns to zero).
    static var openPairs: Int { totalLock.withLock { total } }

    /// The last pairs of the process-wide budget only control channels may take.
    /// remotepairingd adds a standby connection to a tunnel each time it rebuilds its
    /// control channel (every ~40 s while bridged) and never closes it, so tunnel
    /// relays fill up; without a reserve they could take the slot a control channel
    /// needs to come back, and the device would drop.
    static let controlReserve = 16

    enum Refusal: Equatable {
        case relayFull, processFull, reservedForControl
    }

    /// Why a new pair can't be taken, or nil when it can. `spare`: a tunnel relay's.
    static func refusal(relayPairs: Int, total: Int, spare: Bool) -> Refusal? {
        if relayPairs >= maxConnections { return .relayFull }
        if total >= maxTotal { return .processFull }
        if spare && total >= maxTotal - controlReserve { return .reservedForControl }
        return nil
    }

    /// Pairs a tunnel relay keeps. Past it a standby makes room — the one idle longest.
    /// Without it tunnel relays sat at 64 and filled the budget, so a new device or
    /// tunnel had no room left for its first connection.
    static let spareCap = 8
    /// What tells a standby from the live tunnel: measured, standbys move ~0.5 KB for
    /// their setup and nothing after, the live one ~0.5 KB/s of heartbeats on top of
    /// any debugging. A quiet spell doesn't make the live one a standby — when none
    /// is under this, nothing is evicted and the relay just takes the pair.
    static let standbyBytes = 16 * 1024

    /// A refusal is said at most this often per relay: remotepairingd retries every ~40 s.
    static let refusalLogInterval: TimeInterval = 600

    static func shouldLogRefusal(last: Date?, now: Date) -> Bool {
        last.map { now.timeIntervalSince($0) >= refusalLogInterval } ?? true
    }

    /// The callback is given here, not assigned afterwards: start() returns with the
    /// listener already accepting, and the calls that read it run off the main actor.
    init(localIP: String, localPort: UInt16, remoteIP: String, remotePort: UInt16, spare: Bool = false,
         onOpenCountChange: ((Int) -> Void)? = nil, onFailure: ((Relay) -> Void)? = nil) {
        self.spare = spare
        self.onOpenCountChange = onOpenCountChange
        self.onFailure = onFailure
        self.localIP = localIP
        self.localPort = localPort
        self.remoteIP = remoteIP
        self.remotePort = remotePort
    }

    /// Nagle off: the tunnel carries lldb's small request/response packets,
    /// and Nagle + delayed ACK added ~150ms to every round trip.
    /// Keepalive (outbound only): a sleeping iPhone never sends a FIN, so
    /// without probes its dead connection kept the bridge looking Ready.
    private static func tcpParams(keepalive: Bool = false) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        if keepalive {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
            tcp.keepaliveInterval = 5
            tcp.keepaliveCount = 3   // dead after ~25s of silence
        }
        return NWParameters(tls: nil, tcp: tcp)
    }

    /// A relay dropped without stop() would keep its pairs in the process-wide count.
    deinit { stop() }

    func start() async throws {
        guard let port = NWEndpoint.Port(rawValue: localPort) else { throw RelayError.invalidPort(localPort) }
        lock.withLock { stopped = false; failureReported = false }
        let params = Self.tcpParams()
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(localIP), port: port)
        let listener = try NWListener(using: params)
        // A relay started again drops the listener before: its late states must not
        // end this start, and its port must not stay bound.
        let older = lock.withLock { () -> NWListener? in
            defer { self.listener = listener }
            return self.listener
        }
        older?.stateUpdateHandler = nil
        older?.cancel()
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // A start still waiting (two at once) ends here rather than never.
            let earlier = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                defer { starting = cont }
                return starting
            }
            earlier?.resume(throwing: RelayError.bindFailed("started again"))
            // Weak: a relay dropped without stop() must still reach deinit, which stops it.
            listener.stateUpdateHandler = { [weak self, weak listener] state in self?.listenerStateChanged(state, listener) }
            // start() only after the handler is installed — states only flow
            // once the listener is started, so awaiting before starting
            // deadlocks.
            listener.start(queue: .global(qos: .utility))
        }
    }

    /// The listener's state: the first verdict ends start(); a failure after it was
    /// ready is reported once (internal for tests, which pass no listener).
    /// A listener this relay has since replaced or stopped speaks for nothing here —
    /// and that is decided in the same locked step as whatever the event then does,
    /// so a start() swapping listeners in between can't be handed an old verdict.
    func listenerStateChanged(_ state: NWListener.State, _ listener: NWListener?) {
        switch state {
        case .ready: finishStart(nil, from: listener)
        // .waiting (e.g. en0 lost its address mid-bind) would otherwise hang start().
        case .failed(let e), .waiting(let e):
            let (ours, pending) = lock.withLock { () -> (Bool, Bool) in
                let ours = isCurrent(listener)
                return (ours, ours && starting != nil)
            }
            guard ours else { return }
            // Once up, .waiting may still recover by itself (a Wi‑Fi roam): only .failed is the end.
            if !pending, case .waiting = state { return }
            listener?.stateUpdateHandler = nil   // the listener is done either way
            listener?.cancel()
            if finishStart(RelayError.bindFailed(e.localizedDescription), from: listener) { return }
            let first = lock.withLock { () -> Bool in
                guard isCurrent(listener), !failureReported, !stopped else { return false }
                failureReported = true
                return true
            }
            if first { onFailure?(self) }
        case .cancelled:
            guard lock.withLock({ isCurrent(listener) }) else { return }
            listener?.stateUpdateHandler = nil
            finishStart(RelayError.bindFailed("cancelled"), from: listener)
        default: break
        }
    }

    /// Under `lock`. Tests pass no listener: that is the current one.
    private func isCurrent(_ listener: NWListener?) -> Bool { listener == nil || self.listener === listener }

    /// Resumes a waiting start() — only for `listener`'s verdict if one is given;
    /// false when none was waiting (it was ready already) or the listener is stale.
    @discardableResult
    private func finishStart(_ error: Error?, from listener: NWListener? = nil) -> Bool {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard isCurrent(listener) else { return nil }
            defer { starting = nil }
            return starting
        }
        guard let cont else { return false }
        if let error { cont.resume(throwing: error) } else { cont.resume() }
        return true
    }

    func stop() {
        let listener = lock.withLock { () -> NWListener? in
            defer { self.listener = nil }
            return self.listener
        }
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        lock.withLock { stopped = true }
        dropConnections()
        finishStart(RelayError.bindFailed("stopped"))   // its handler is gone: nothing else would end a start in flight
    }

    /// No pair has moved a byte for `seconds` (or there are none). Standbys stay open
    /// but silent, so a relay the tunnel has left behind is quiet, not empty.
    func quiet(for seconds: TimeInterval) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds, span = UInt64(seconds * 1e9)
        let since = now > span ? now - span : 0
        return lock.withLock { stats.values.allSatisfy { $0.lastActive < since } }
    }

    /// Closes every pair; the listener stays, for whatever connects next.
    func dropConnections() {
        lock.lock(); let open = connections; let had = !established.isEmpty
        connections = []; established = []; stats = [:]; lock.unlock()
        Self.totalLock.withLock { Self.total -= open.count / 2 }
        for c in open { c.cancel() }
        if had, !lock.withLock({ stopped }) { onOpenCountChange?(0) }
    }

    var openCount: Int {
        lock.lock(); defer { lock.unlock() }
        return established.count
    }

    private func accept(_ inbound: NWConnection) {
        // Compare raw bytes: IPv4Address == also compares an interface scope.
        guard case .hostPort(let host, _) = inbound.endpoint, case .ipv4(let from) = host,
              from.rawValue == IPv4Address(localIP)?.rawValue else {
            relayLog.log("refused :\(self.localPort) connection from \(String(describing: inbound.endpoint), privacy: .private)")
            inbound.cancel()
            return
        }
        guard let rport = NWEndpoint.Port(rawValue: remotePort) else { inbound.cancel(); return }
        let outbound = NWConnection(host: NWEndpoint.Host(remoteIP), port: rport, using: Self.tcpParams(keepalive: true))
        let stats = ConnStats()
        let port = remotePort
        let finish: @Sendable (String) -> Void = { [weak self] reason in
            stats.logOnce("tcp :\(port) sent=\(stats.up)B recv=\(stats.down)B \(reason)")
            outbound.stateUpdateHandler = nil   // it holds this closure, which holds outbound
            inbound.cancel(); outbound.cancel()
            self?.untrack(inbound, outbound)
        }
        // Upstream refused/unreachable: drop the local side too, otherwise
        // remotepairingd sits on an accepted socket that leads nowhere.
        outbound.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.markEstablished(inbound)
            case .waiting(let e), .failed(let e): finish("upstream \(e.localizedDescription)")
            default: break
            }
        }
        guard track(inbound, outbound, stats: stats) else {
            // Also breaks the handler → finish → outbound retain cycle.
            outbound.stateUpdateHandler = nil
            outbound.cancel()
            inbound.cancel()
            return
        }
        inbound.start(queue: .global(qos: .utility))
        outbound.start(queue: .global(qos: .utility))
        relayLog.log("tcp relay open :\(self.localPort) -> \(self.remoteIP):\(self.remotePort)")
        pump(from: inbound, to: outbound, stats: stats, isUp: true, finish: finish)
        pump(from: outbound, to: inbound, stats: stats, isUp: false, finish: finish)
    }

    private func pump(from: NWConnection, to: NWConnection, stats: ConnStats,
                      isUp: Bool, finish: @escaping @Sendable (String) -> Void) {
        let handle: @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = { [weak self] data, _, isComplete, error in
            if let error {
                finish("err=\(error.localizedDescription)")
                return
            }
            // isComplete is EOF — pass the FIN on after the queued data and
            // keep the other direction flowing until it ends too.
            if isComplete {
                if let data, !data.isEmpty { stats.add(data.count, up: isUp); to.send(content: data, completion: .idempotent) }
                to.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in
                            if stats.directionDone() { finish("eof") }
                        })
                return
            }
            guard let data, !data.isEmpty else {
                self?.pump(from: from, to: to, stats: stats, isUp: isUp, finish: finish)
                return
            }
            stats.add(data.count, up: isUp)
            // Backpressure: read the next chunk only once this one is handed
            // off, so a fast side can't buffer a whole install in memory.
            to.send(content: data, completion: .contentProcessed { [weak self] sendError in
                if let sendError { finish("send err=\(sendError.localizedDescription)"); return }
                self?.pump(from: from, to: to, stats: stats, isUp: isUp, finish: finish)
            })
        }
        // Stream read: receiveMessage on TCP only returns at EOF, which
        // held the handshake back until remotepairingd gave up.
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536, completion: handle)
    }

    /// False when stopped (an accept can race listener.cancel()) or full — said in
    /// the log, since remotepairingd only reports a reset connection.
    private func track(_ inbound: NWConnection, _ outbound: NWConnection, stats pairStats: ConnStats) -> Bool {
        lock.lock()
        guard !stopped else { lock.unlock(); return false }
        let pairs = connections.count / 2
        if spare && pairs >= Self.spareCap, let (victim, wasEstablished) = evictIdlestStandby() {
            // The new pair takes the evicted one's place in the count.
            stats[ObjectIdentifier(inbound)] = pairStats
            connections += [inbound, outbound]
            let n = established.count
            lock.unlock()
            victim.forEach { $0.cancel() }
            if wasEstablished { onOpenCountChange?(n) }
            return true
        }
        let (refused, total) = Self.totalLock.withLock { () -> (Refusal?, Int) in
            let why = Self.refusal(relayPairs: pairs, total: Self.total, spare: spare)
            if why == nil { Self.total += 1 }
            return (why, Self.total)
        }
        if let refused {
            let say = Self.shouldLogRefusal(last: lastRefusalLog, now: .now)
            if say { lastRefusalLog = .now }
            lock.unlock()
            if say {
                relayLog.log("refused a connection on :\(self.localPort, privacy: .public): \(String(describing: refused), privacy: .public) (\(pairs) pairs here, \(total) in all)")
            }
            return false
        }
        stats[ObjectIdentifier(inbound)] = pairStats
        connections += [inbound, outbound]
        lock.unlock()
        return true
    }

    /// Under `lock`: takes the standby idle longest out of the books (its finish then
    /// finds nothing to untrack) and returns it to cancel once unlocked; nil if none.
    private func evictIdlestStandby() -> ([NWConnection], Bool)? {
        let standbys = stride(from: 0, to: connections.count, by: 2).compactMap { i -> (Int, UInt64)? in
            guard let s = stats[ObjectIdentifier(connections[i])], s.up + s.down < Self.standbyBytes else { return nil }
            return (i, s.lastActive)
        }
        guard let i = standbys.min(by: { $0.1 < $1.1 })?.0 else { return nil }
        let victim = Array(connections[i...i + 1])
        connections.removeSubrange(i...i + 1)
        stats[ObjectIdentifier(victim[0])] = nil
        return (victim, established.remove(ObjectIdentifier(victim[0])) != nil)
    }

    private func markEstablished(_ inbound: NWConnection) {
        lock.lock()
        // .ready can arrive after finish() untracked the pair; don't count a ghost.
        guard !stopped, connections.contains(where: { $0 === inbound }) else { lock.unlock(); return }
        let inserted = established.insert(ObjectIdentifier(inbound)).inserted
        let n = established.count
        lock.unlock()
        if inserted { onOpenCountChange?(n) }
    }

    private func untrack(_ conns: NWConnection...) {
        lock.lock()
        let before = connections.count
        connections.removeAll { c in conns.contains { $0 === c } }
        conns.forEach { stats[ObjectIdentifier($0)] = nil }
        let wasEstablished = conns.contains { established.remove(ObjectIdentifier($0)) != nil }
        let changed = connections.count != before, n = established.count
        lock.unlock()
        if changed { Self.totalLock.withLock { Self.total -= 1 } }
        if changed && wasEstablished { onOpenCountChange?(n) }
    }
}

/// Byte counters for one relayed connection; logs once on close.
private final class ConnStats: @unchecked Sendable {
    private let lock = NSLock()
    private var _up = 0, _down = 0, doneDirections = 0
    private var logged = false
    /// Uptime (ns) of the last bytes either way, or of the pair's start.
    private var _lastActive = DispatchTime.now().uptimeNanoseconds

    var lastActive: UInt64 { lock.lock(); defer { lock.unlock() }; return _lastActive }

    var up: Int { lock.lock(); defer { lock.unlock() }; return _up }
    var down: Int { lock.lock(); defer { lock.unlock() }; return _down }

    func add(_ n: Int, up isUp: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isUp { _up += n } else { _down += n }
        _lastActive = DispatchTime.now().uptimeNanoseconds
    }

    /// True once both directions have seen EOF.
    func directionDone() -> Bool {
        lock.lock(); defer { lock.unlock() }
        doneDirections += 1
        return doneDirections == 2
    }

    func logOnce(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !logged else { return }
        logged = true
        relayLog.log("\(message, privacy: .public)")
    }
}
