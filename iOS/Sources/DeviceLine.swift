import Foundation
import Network

/// Looks for this device's own `_remotepairing._tcp` announcement, which is what the far Mac saves
/// (as an `rr-device-v1:` line). Platform-neutral.
// ponytail: @unchecked Sendable because everything runs on the one serial `queue`.
final class DeviceFinder: @unchecked Sendable {
    enum Found: Equatable {
        case line(String)
        /// No announcement of this device was seen: the far Mac needs the line from another Mac.
        case notSeen
        /// Local Network access is off for this app: nothing can be seen.
        case denied
        case refused(String)
    }

    private let queue = DispatchQueue(label: "io.github.mh-mobile.roamrun.introducer.devices")
    private let browser: NWBrowser
    private let own: Set<Data>
    private var results: Set<NWBrowser.Result> = []
    private var resolution: Resolution?
    private var looking = false, denied = false

    init(serviceType: String = Introduction.deviceService, own: Set<Data> = OwnAddresses.all()) {
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: params)
        self.own = own
    }

    func start() {
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.looking = true
            case .waiting(.dns(-65570)), .failed(.dns(-65570)): self?.denied = true   // Local Network permission
            default: break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.results = results
            self?.resolution?.check(results)
        }
        browser.start(queue: queue)
    }

    /// Ends a search under way too: nothing is said of it afterwards.
    func stop() {
        browser.cancel()
        queue.async { self.resolution?.cancel(); self.resolution = nil }
    }

    /// Watches announcements for 5 s from when it may look (the permission prompt isn't counted, a
    /// minute of it at most); the one at this device's own address is this device.
    func line(name: String, peer: String, completion: @escaping @Sendable (Found) -> Void) {
        queue.async { [self] in
            let box = Resolution(own: self.own, name: name, peer: peer, queue: self.queue) { [weak self] found in
                self?.resolution = nil
                completion(found)
            }
            self.resolution = box
            box.check(self.results)
            self.arm(box, waited: 0)
        }
    }

    /// Whether this app may see the local network: asked before the far Mac is, since the answer
    /// may wait on the person (the first run's prompt), a minute at most.
    func allowed(_ completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { self.ask(completion, waited: 0) }
    }

    private func ask(_ completion: @escaping @Sendable (Bool) -> Void, waited: Int) {
        if denied { completion(false); return }
        // Ready, and still so a moment later: a refusal arrives just after.
        if looking || waited >= 120 { queue.asyncAfter(deadline: .now() + 0.3) { completion(!self.denied) }; return }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.ask(completion, waited: waited + 1) }
    }

    private func arm(_ box: Resolution, waited: Int) {
        if denied { box.end(.denied); return }
        if looking || waited >= 60 { queue.asyncAfter(deadline: .now() + 5) { [weak self] in box.end(self?.denied == true ? .denied : .notSeen) }; return }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.arm(box, waited: waited + 1) }
    }

    /// Keeps checking new records until this device is found or the deadline passes.
    private final class Resolution: @unchecked Sendable {
        private let own: Set<Data>
        private let name: String
        private let peer: String
        private let queue: DispatchQueue
        private var seen: Set<NWBrowser.Result> = []
        private var done = false
        private let completion: @Sendable (Found) -> Void
        private var connections: [NWConnection] = []

        init(own: Set<Data>, name: String, peer: String, queue: DispatchQueue, completion: @escaping @Sendable (Found) -> Void) {
            self.own = own
            self.name = name
            self.peer = peer
            self.queue = queue
            self.completion = completion
        }

        func check(_ results: Set<NWBrowser.Result>) {
            guard !done else { return }
            for result in results {
                guard case .bonjour(let record) = result.metadata else { continue }
                guard seen.insert(result).inserted else { continue }
                let connection = NWConnection(to: result.endpoint, using: .tcp)
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self, !self.done else { return }
                    switch state {
                    case .ready:
                        let endpoint = connection.currentPath?.remoteEndpoint ?? connection.endpoint
                        connection.cancel()
                        guard let raw = OwnAddresses.raw(endpoint), self.own.contains(raw),
                              case .hostPort(_, let port) = endpoint else { return }
                        let txt = record.dictionary.filter { Introduction.Device.keys.contains($0.key) }
                        let device = Introduction.Device(name: self.name, peer: self.peer, port: port.rawValue, txt: txt)
                        switch Introduction.device(from: Introduction.line(device)) {
                        case .success(let whole): self.finish(.line(Introduction.line(whole)))
                        case .failure(.refused(let why)): self.finish(.refused(why))
                        case .failure: self.finish(.refused("its announcement isn't one this RoamRun knows"))
                        }
                    case .waiting, .failed: connection.cancel()
                    default: break
                    }
                }
                connections.append(connection)
                connection.start(queue: queue)
            }
        }

        func end(_ found: Found) { if !done { finish(found) } }

        func cancel() {
            done = true
            connections.forEach { $0.cancel() }
        }

        private func finish(_ found: Found) {
            done = true
            connections.forEach { $0.cancel() }
            completion(found)
        }
    }
}
