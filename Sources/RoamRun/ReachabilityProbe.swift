import Foundation
import Network

/// macOS gates local-network access per app. With it off for RoamRun every probe
/// to this Wi-Fi fails at once, which looks exactly like the device being away —
/// so a "no" from the home check can't be trusted while this is set. Only a
/// local-network destination is ever refused this way, so any probe may report.
enum LocalNetwork {
    static let advice = "macOS is blocking RoamRun's access to the local network, so it can't tell whether the device is on this Wi-Fi. Allow RoamRun in System Settings › Privacy & Security › Local Network; if it is already on, reinstall RoamRun."

    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastDenial: Date?

    static var denied: Bool { isDenied(last: lock.withLock { lastDenial }, now: .now) }

    static func note(_ path: NWPath?) {
        guard let path, path.status == .unsatisfied, path.unsatisfiedReason == .localNetworkDenied else { return }
        lock.withLock { lastDenial = .now }
    }

    /// Ages out instead of being cleared: once access is allowed again no probe
    /// reports another denial, so nothing has to notice that it stopped.
    static func isDenied(last: Date?, now: Date) -> Bool {
        guard let last else { return false }
        return now.timeIntervalSince(last) < 120
    }
}

enum ReachabilityProbe {
    /// Plain TCP connect check against the device's RemotePairing port on its
    /// mesh IP. Confirms the route exists and remotepairingd is listening
    /// before we commit to publishing the proxy.
    static func checkTCP(host: String, port: UInt16, timeout: TimeInterval = 4) async -> Bool {
        guard let p = NWEndpoint.Port(rawValue: port) else { return false }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        return await withCheckedContinuation { cont in
            let box = ProbeBox()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.done { conn.stateUpdateHandler = nil; conn.cancel(); cont.resume(returning: true) }
                // Refused: no need to sit out the timeout. Other .waiting (the path still
                // settling after wake or a network switch) may still turn .ready.
                case .failed, .cancelled, .waiting(.posix(.ECONNREFUSED)):
                    box.done { conn.stateUpdateHandler = nil; conn.cancel(); cont.resume(returning: false) }
                case .waiting:
                    LocalNetwork.note(conn.currentPath)
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.done { conn.stateUpdateHandler = nil; conn.cancel(); cont.resume(returning: false) }
            }
        }
    }
}

extension ReachabilityProbe {
    /// An open port isn't enough — other services live in the same range.
    /// Send RemotePairing's opening handshake and check the reply's magic.
    static func speaksRemotePairing(host: String, port: UInt16, timeout: TimeInterval = 4) async -> Bool {
        guard let p = NWEndpoint.Port(rawValue: port) else { return false }
        return await speaksRemotePairing(.hostPort(host: NWEndpoint.Host(host), port: p), timeout: timeout)
    }

    /// Same, for any endpoint — e.g. a Bonjour service, resolved by Network.framework.
    static func speaksRemotePairing(_ endpoint: NWEndpoint, timeout: TimeInterval = 4) async -> Bool {
        let hello = #"{"message":{"plain":{"_0":{"request":{"_0":{"handshake":{"_0":{"hostOptions":{"attemptPairVerify":true},"wireProtocolVersion":19}}}}}}},"originatedBy":"host","sequenceNumber":0}"#
        var frame = Data("RPPairing".utf8)
        frame.append(contentsOf: [UInt8(hello.utf8.count >> 8), UInt8(hello.utf8.count & 0xff)])
        frame.append(Data(hello.utf8))
        let payload = frame

        let conn = NWConnection(to: endpoint, using: .tcp)
        return await withCheckedContinuation { cont in
            let box = ProbeBox()
            let finish: @Sendable (Bool) -> Void = { ok in box.done { conn.stateUpdateHandler = nil; conn.cancel(); cont.resume(returning: ok) } }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: payload, completion: .contentProcessed { _ in })
                    conn.receive(minimumIncompleteLength: 9, maximumLength: 64) { data, _, _, _ in
                        finish(data.map { $0.starts(with: Data("RPPairing".utf8)) } ?? false)
                    }
                // As in checkTCP: other .waiting (a path settling after wake) may still turn .ready.
                case .failed, .cancelled, .waiting(.posix(.ECONNREFUSED)): finish(false)
                case .waiting: LocalNetwork.note(conn.currentPath)
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}

private final class ProbeBox: @unchecked Sendable {
    private var fired = false
    private let lock = NSLock()
    /// Runs `body` once; outside the lock, so cancel() or a resume can't re-enter it.
    func done(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            guard !fired else { return false }
            fired = true
            return true
        }
        if first { body() }
    }
}

extension ReachabilityProbe {
    enum PortScan: Equatable {
        case found(UInt16)
        case notFound   // every port checked
        case timedOut   // gave up before the end; the port may be further on
    }

    /// The device's RemotePairing port, which can change when it restarts: the
    /// usual range first (49152…), 256 ports at a time. An open port may be another
    /// service, so each is confirmed with the handshake as its batch comes in.
    /// Every probe gets only the time left: a host that drops probes would
    /// otherwise cost 1.2 s per batch, ~80 s in all, plus 4 s per silent port.
    static func findRemotePairingPort(host: String, limit: Duration = .seconds(30)) async -> PortScan {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        func left() -> TimeInterval { (deadline - clock.now) / .seconds(1) }
        var next = 49152
        while next <= 65535 {
            guard left() > 0, !Task.isCancelled else { return .timedOut }
            let batch = UInt16(next)...UInt16(min(next + 255, 65535))
            let timeout = min(1.2, left())
            let open = await withTaskGroup(of: UInt16?.self) { group in
                for port in batch {
                    group.addTask { await ReachabilityProbe.checkTCP(host: host, port: port, timeout: timeout) ? port : nil }
                }
                var hits: [UInt16] = []
                for await r in group { if let r { hits.append(r) } }
                return hits.sorted()
            }
            for port in open {
                guard left() > 0, !Task.isCancelled else { return .timedOut }
                if await speaksRemotePairing(host: host, port: port, timeout: min(4, left())) { return .found(port) }
            }
            next += 256
        }
        return .notFound
    }
}
