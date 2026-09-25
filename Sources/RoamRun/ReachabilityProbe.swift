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
                case .failed, .cancelled:
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
            let finish: (Bool) -> Void = { ok in box.done { conn.stateUpdateHandler = nil; conn.cancel(); cont.resume(returning: ok) } }
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
    func done(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        body()
    }
}
