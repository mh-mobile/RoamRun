import Foundation
import Network

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
                case .failed, .cancelled, .waiting: finish(false)
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
    /// The device's RemotePairing port, which can change when it restarts:
    /// the usual range first, then the rest. An open port may be another
    /// service, so each is confirmed with the handshake.
    static func findRemotePairingPort(host: String) async -> UInt16? {
        for range in [UInt16(49152)...49255, UInt16(49256)...UInt16.max] {
            for port in await openPorts(host: host, in: range) where await speaksRemotePairing(host: host, port: port) {
                return port
            }
        }
        return nil
    }

    /// Probes `range` 256 ports at a time.
    private static func openPorts(host: String, in range: ClosedRange<UInt16>) async -> [UInt16] {
        var open: [UInt16] = []
        var next = Int(range.lowerBound)
        while next <= Int(range.upperBound) {
            let batch = UInt16(next)...UInt16(min(next + 255, Int(range.upperBound)))
            open += await withTaskGroup(of: UInt16?.self) { group in
                for port in batch {
                    group.addTask { await ReachabilityProbe.checkTCP(host: host, port: port, timeout: 1.2) ? port : nil }
                }
                var hits: [UInt16] = []
                for await r in group { if let r { hits.append(r) } }
                return hits
            }
            next += 256
        }
        return open.sorted()
    }
}
