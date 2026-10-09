import Foundation
import Network
import os

// Platform-neutral (Network.framework only): the same file is compiled for macOS by Checks/relay-check.swift.

let standInLog = Logger(subsystem: "io.github.mh-mobile.roamrun.introducer", category: "standin")

/// The addresses this device has, as raw bytes (4 for IPv4, 16 for IPv6), loopback among them.
enum OwnAddresses {
    static func all() -> Set<Data> {
        var out: Set<Data> = [IPv4Address.loopback.rawValue, IPv6Address.loopback.rawValue]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return out }
        defer { freeifaddrs(first) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr else { continue }
            switch Int32(sa.pointee.sa_family) {
            case AF_INET: out.insert(withUnsafeBytes(of: UnsafeRawPointer(sa).loadUnaligned(as: sockaddr_in.self).sin_addr) { Data($0) })
            case AF_INET6: out.insert(withUnsafeBytes(of: UnsafeRawPointer(sa).loadUnaligned(as: sockaddr_in6.self).sin6_addr) { Data($0) })
            default: break
            }
        }
        return out
    }

    /// An endpoint's address as raw bytes; a v4-mapped IPv6 one as the IPv4 it is. Nil for a name.
    static func raw(_ endpoint: NWEndpoint?) -> Data? {
        guard case .hostPort(let host, _)? = endpoint else { return nil }
        switch host {
        case .ipv4(let a): return a.rawValue
        case .ipv6(let a): return a.asIPv4?.rawValue ?? a.rawValue
        case .name: return nil
        @unknown default: return nil
        }
    }

    static func shown(_ endpoint: NWEndpoint?) -> String {
        guard case .hostPort(let host, let port)? = endpoint else { return endpoint.map { String(describing: $0) } ?? "nowhere" }
        return "\(host):\(port)"
    }
}

/// Stands in, once, for a Mac that offers to pair: announces its offer on this device's network and
/// carries what connects there to that Mac over Tailscale. Says what happens; shows nothing itself.
// ponytail: @unchecked Sendable because every handler runs on the one serial `queue`; an actor if that changes.
final class StandIn: @unchecked Sendable {
    enum End: Equatable {
        /// A connection that carried bytes both ways has closed: a pairing was tried. Whether it
        /// was made, only the far Mac knows.
        case carried(up: Int, down: Int)
        case deadline
        case stopped
        /// iOS ended the app's time in the background.
        case expired
        case announcementLost(String)
    }
    enum Event: Equatable {
        case announced(name: String, port: UInt16)
        case connected(from: String)
        case refused(from: String)
        case farDidNotAnswer(String)
        /// Nothing of this is announced or listening any more.
        case ended(End)
    }

    let queue = DispatchQueue(label: "io.github.mh-mobile.roamrun.introducer.standin")
    private let offer: Introduction.Offer
    private let farHost: String
    private let serviceType: String
    private let allowed: Set<Data>
    private let deadline: TimeInterval
    private let onEvent: @Sendable (Event) -> Void
    private var listener: NWListener?
    private var pairs: [Pair] = []
    private var deadlineWork: DispatchWorkItem?
    private var ended = false
    private var loggedFirst = false
    private let anywhere: Bool

    /// `offer`: as it is to be announced (name substituted already). `farHost`: the far Mac's Tailscale
    /// IPv4 or MagicDNS name. `allowed`: whose connections are carried (this device's own addresses).
    /// `anywhere`: for the check on a Mac, whose far Mac is 127.0.0.1; otherwise what the name leads to must be an address of Tailscale's.
    init(offer: Introduction.Offer, farHost: String, serviceType: String = Introduction.hostService,
         allowed: Set<Data> = OwnAddresses.all(), deadline: TimeInterval = 300, anywhere: Bool = false, onEvent: @escaping @Sendable (Event) -> Void) {
        self.anywhere = anywhere
        self.offer = offer
        self.farHost = farHost
        self.serviceType = serviceType
        self.allowed = allowed
        self.deadline = deadline
        self.onEvent = onEvent
    }

    /// Throws where no TCP listener can be made at all; everything after that arrives as events.
    func start() throws {
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let listener = try NWListener(using: params, on: .any)
        var service = NWListener.Service(name: offer.txt["identifier"], type: serviceType, domain: nil, txtRecord: NWTXTRecord(offer.txt))
        service.noAutoRename = true
        listener.service = service
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            guard let self else { return }
            switch change {
            case .add(let endpoint):
                guard case .service(let name, _, _, _) = endpoint else { return }
                standInLog.notice("announced as \(name, privacy: .public) on port \(listener.port?.rawValue ?? 0)")
                self.onEvent(.announced(name: name, port: listener.port?.rawValue ?? 0))
            case .remove: standInLog.notice("announcement withdrawn")
            @unknown default: break
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: standInLog.debug("listening on port \(listener.port?.rawValue ?? 0)")
            case .waiting(let error):
                if case .dns(-65570) = error { self.endOnQueue(.announcementLost("Local Network permission needed")) }
                else { standInLog.notice("waiting: \(error.localizedDescription, privacy: .public)") }
            case .failed(let error): self.endOnQueue(.announcementLost(error.localizedDescription))
            case .setup, .cancelled: break
            @unknown default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.take(connection) }
        self.listener = listener
        let work = DispatchWorkItem { [weak self] in self?.endOnQueue(.deadline) }
        deadlineWork = work
        queue.asyncAfter(deadline: .now() + deadline, execute: work)
        listener.start(queue: queue)
    }

    private func take(_ connection: NWConnection) {
        guard !ended else { connection.cancel(); return }
        let endpoint = connection.currentPath?.remoteEndpoint ?? connection.endpoint
        let from = OwnAddresses.shown(endpoint)
        guard let raw = OwnAddresses.raw(endpoint), allowed.contains(raw) else {
            standInLog.notice("refused a connection from \(from, privacy: .public)")
            connection.cancel()
            onEvent(.refused(from: from))
            return
        }
        guard pairs.count < 2 else {
            standInLog.notice("refused a third connection from \(from, privacy: .public)")
            connection.cancel()
            onEvent(.refused(from: "\(from) (two are being carried already)"))
            return
        }
        if !loggedFirst {
            // A device-only unknown worth learning: where a connection from Settings on this same device comes from.
            loggedFirst = true
            standInLog.notice("first accepted connection: path \(String(describing: connection.currentPath?.remoteEndpoint), privacy: .public), endpoint \(String(describing: connection.endpoint), privacy: .public)")
        }
        onEvent(.connected(from: from))
        let pair = Pair(inbound: connection, farHost: farHost, farPort: offer.port, anywhere: anywhere, queue: queue) { [weak self] pair, up, down, why in
            self?.closed(pair, up: up, down: down, why: why)
        }
        pairs.append(pair)
        pair.start()
    }

    private func closed(_ pair: Pair, up: Int, down: Int, why: String?) {
        pairs.removeAll { $0 === pair }
        guard !ended else { return }
        standInLog.notice("pair closed: \(up) bytes up, \(down) down\(why.map { " (\($0))" } ?? "", privacy: .public)")
        if up > 0, down > 0 { endOnQueue(.carried(up: up, down: down)) }
        else { onEvent(.farDidNotAnswer(why ?? "one-sided: \(up) bytes up, \(down) down")) }
    }

    /// Cancels the pairs and the listener (withdrawing the record); says so once.
    func end(_ why: End) { queue.async { self.endOnQueue(why) } }

    private func endOnQueue(_ why: End) {
        guard !ended else { return }
        ended = true
        deadlineWork?.cancel()
        pairs.forEach { $0.close() }
        pairs = []
        listener?.cancel()
        onEvent(.ended(why))
    }
}

/// One connection carried to the far Mac, bytes counted each way; reports once, when both sides are closed.
private final class Pair: @unchecked Sendable {
    private let inbound: NWConnection, outbound: NWConnection, queue: DispatchQueue, farHost: String, anywhere: Bool
    private let onClose: @Sendable (Pair, Int, Int, String?) -> Void
    private var up = 0, down = 0, endedDirections = 0
    private var failure: String?
    private var reported = false
    private var connected = false
    private var connectTimeout: DispatchWorkItem?

    init(inbound: NWConnection, farHost: String, farPort: UInt16, anywhere: Bool, queue: DispatchQueue, onClose: @escaping @Sendable (Pair, Int, Int, String?) -> Void) {
        self.anywhere = anywhere
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        self.inbound = inbound
        self.outbound = NWConnection(host: NWEndpoint.Host(farHost), port: NWEndpoint.Port(rawValue: farPort) ?? .any, using: NWParameters(tls: nil, tcp: tcp))
        self.queue = queue
        self.farHost = farHost
        self.onClose = onClose
    }

    func start() {
        outbound.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                connectTimeout?.cancel()
                // Not a byte of a pairing to an address that isn't Tailscale's, whatever the name led to.
                guard anywhere || Wire.onTailnet(outbound.currentPath?.remoteEndpoint) else { fail("\(farHost) isn't an address on the tailnet"); return }
                connected = true
                pump(inbound, outbound) { self.up += $0 }
                pump(outbound, inbound) { self.down += $0 }
            // Waiting is a refused or unreachable far port: nothing to wait for during a pairing.
            case .waiting(let error), .failed(let error): ended("\(farHost) didn't take it: \(error.localizedDescription)")
            case .cancelled: close()
            case .setup, .preparing: break
            @unknown default: break
            }
        }
        inbound.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error): self?.ended(error.localizedDescription)
            case .cancelled: self?.close()
            default: break
            }
        }
        let timeout = DispatchWorkItem { [weak self] in self?.fail("\(self?.farHost ?? "the far Mac") didn't answer in 10 s") }
        connectTimeout = timeout
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)
        inbound.start(queue: queue)
        outbound.start(queue: queue)
    }

    private func pump(_ from: NWConnection, _ to: NWConnection, count: @escaping @Sendable (Int) -> Void) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let ended = isComplete || error != nil
            if let error { failure = failure ?? error.localizedDescription }
            // Bytes can arrive together with the FIN: forward them first, the FIN after they are sent.
            guard let data, !data.isEmpty else { ended ? endDirection(to) : pump(from, to, count: count); return }
            count(data.count)
            // The next receive waits for this send: backpressure.
            to.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error { fail(error.localizedDescription) } else if ended { endDirection(to) } else { pump(from, to, count: count) }
            })
        }
    }

    private func endDirection(_ to: NWConnection) {
        to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })  // forward the FIN
        endedDirections += 1
        if endedDirections == 2 { close() }
    }

    private func fail(_ why: String) {
        failure = failure ?? why
        close()
    }

    /// A side went. Before the far Mac took the connection, that is the end; after, what it sent
    /// already is still to be read and passed on, and the reading says when it is over.
    private func ended(_ why: String) {
        guard connected else { fail(why); return }
        failure = failure ?? why
    }

    func close() {
        guard !reported else { return }
        reported = true
        connectTimeout?.cancel()
        inbound.cancel()
        outbound.cancel()
        onClose(self, up, down, failure)
    }
}
