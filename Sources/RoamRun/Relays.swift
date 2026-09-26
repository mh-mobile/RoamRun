import Foundation
import Network
import OSLog

private let relayLog = Logger(subsystem: "com.roamrun.app", category: "relay")

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
    var onOpenCountChange: ((Int) -> Void)?

    private var listener: NWListener?
    private var connections: [NWConnection] = []
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

    init(localIP: String, localPort: UInt16, remoteIP: String, remotePort: UInt16) {
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
        lock.withLock { stopped = false }
        let params = Self.tcpParams()
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(localIP), port: port)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let box = ReadyBox()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: box.resume { cont.resume() }
                // .waiting (e.g. en0 lost its address mid-bind) would otherwise hang start().
                case .failed(let e), .waiting(let e):
                    box.resume { listener.cancel(); cont.resume(throwing: RelayError.bindFailed(e.localizedDescription)) }
                case .cancelled: box.resume { cont.resume(throwing: RelayError.bindFailed("cancelled")) }
                default: break
                }
            }
            // start() only after the handler is installed — states only flow
            // once the listener is started, so awaiting before starting
            // deadlocks.
            listener.start(queue: .global(qos: .utility))
        }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        lock.lock(); stopped = true; let open = connections; connections = []; established = []; lock.unlock()
        Self.totalLock.withLock { Self.total -= open.count / 2 }
        for c in open { c.cancel() }
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
        guard track(inbound, outbound) else {
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

    /// False when stopped (an accept can race listener.cancel()) or full.
    private func track(_ conns: NWConnection...) -> Bool {
        lock.lock()
        guard !stopped, connections.count / 2 < Self.maxConnections else { lock.unlock(); return false }
        let admitted = Self.totalLock.withLock { Self.total < Self.maxTotal ? (Self.total += 1, true).1 : false }
        guard admitted else { lock.unlock(); return false }
        connections += conns
        lock.unlock()
        return true
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

    var up: Int { lock.lock(); defer { lock.unlock() }; return _up }
    var down: Int { lock.lock(); defer { lock.unlock() }; return _down }

    func add(_ n: Int, up isUp: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isUp { _up += n } else { _down += n }
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

/// One-shot resume helper so listener state handlers can't double-resume.
private final class ReadyBox: @unchecked Sendable {
    private var didResume = false
    private let lock = NSLock()
    /// Runs `body` once; outside the lock, so what it calls can't re-enter it.
    func resume(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            guard !didResume else { return false }
            didResume = true
            return true
        }
        if first { body() }
    }
}
