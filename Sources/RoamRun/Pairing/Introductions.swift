import Foundation
import Network

extension Introduction {
    /// What a device announces while it waits, as a line; nil when it isn't whole.
    static func pairable(_ service: CapturedService) -> Pairable? {
        let txt = service.txt.filter { Pairable.keys.contains($0.key) }
        let made = Pairable(instance: service.instanceName, port: service.port, txt: txt)
        if case .success(let read) = pairable(from: line(made)) { return read }
        return nil
    }

    /// A Mac's name and, with an offer, the offer by its parts under short names: what a code
    /// drawn in a terminal holds (the line itself makes one too large for it).
    static func codeURL(mac: String, offer: Offer? = nil) -> String? {
        var url = URLComponents()
        url.scheme = "roamrun-introducer"; url.host = mac
        if let offer {
            url.queryItems = [URLQueryItem(name: "p", value: String(offer.port))]
                + [("i", "identifier"), ("a", "authTag"), ("m", "model"), ("n", "name"), ("f", "flags"), ("v", "ver"), ("w", "minVer")]
                    .map { URLQueryItem(name: $0.0, value: offer.txt[$0.1]) }
        }
        return url.string
    }

    /// Of the offers seen on the network, those that can be this Mac's: not ones whose host is
    /// known to be elsewhere. Xcode's names a host the browse gives no address for, so the
    /// caller also asks whether the port is listened on here.
    static func ownOffers(among services: [CapturedService], ownIPs: Set<String>) -> [CapturedService] {
        services.filter { $0.serviceType == hostService && ($0.hostIPs.isEmpty || !ownIPs.isDisjoint(with: $0.hostIPs)) }
            .sorted { $0.instanceName < $1.instanceName }
    }

    /// Whose connections a stand-in takes: the device's alone when its address on this LAN is
    /// known (`endpoint`: Tailscale's direct "ip:port" for it), else that LAN's hosts.
    static func accept(deviceEndpoint endpoint: String, local: String, mask: String) -> Relay.Accept {
        let host = endpoint.split(separator: ":").first.map(String.init) ?? ""
        guard endpoint.split(separator: ":").count == 2, let from = IPv4Address(host), host != local,
              Relay.accepts(from: from, local: local, policy: .subnet(mask: mask)) else { return .subnet(mask: mask) }
        return .only(host)
    }

    /// What a ping of the device said of its direct path ("192.168.0.19", an IPv6 address, or
    /// nil: relayed or silent), in the form Tailscale's list gives one.
    static func endpoint(pinged host: String?) -> String {
        guard let host, !host.isEmpty else { return "" }
        return host.contains(":") ? "[\(host)]:0" : "\(host):0"
    }

    /// A saved device as a line for another Mac; nil when what was saved of its announcement isn't
    /// whole, or it was saved by an address: the line names a device by its Tailscale name.
    static func device(of profile: DeviceProfile) -> Device? {
        guard profile.providerID == MeshProvider.tailscale.rawValue else { return nil }
        let txt = profile.txt.filter { Device.keys.contains($0.key) }
        let device = Device(name: profile.displayName, peer: profile.providerHostName, port: profile.remotePairingPort, txt: txt)
        guard case .success(let whole) = Introduction.device(from: line(device)) else { return nil }
        return whole
    }

    /// What this Mac offers right now, of the offers found to be its own: what doesn't read as
    /// an offer isn't one (yet: its port arrives before its values), and two are not chosen between.
    static func current(among own: [CapturedService]) -> PairByName.Offers {
        let whole = own.map { line(Offer(port: $0.port, txt: $0.txt)) }.filter { if case .success = offer(from: $0) { true } else { false } }
        return whole.count > 1 ? .several : whole.first.map(PairByName.Offers.one) ?? .none
    }

    /// A line the device sent of itself, as the device named here: its Tailscale name and the name
    /// it is saved under are this Mac's to say. What doesn't read as a device's line stays as it came.
    static func line(_ sent: String, ofDevice peer: String, named name: String?) -> String {
        guard case .success(var device) = device(from: sent) else { return sent }
        device.peer = peer
        device.name = name ?? device.name
        return line(device)
    }

    /// A device's line fit to show: read and written again, never the bytes that came.
    static func shown(_ text: String) -> String? {
        guard case .success(let device) = device(from: text) else { return nil }
        return line(device)
    }

    enum Added: Equatable {
        case added
        case unchanged(String)
        /// Saved already, where it was: only its announcement was put in the older one's place.
        case renewed(String)
        case already(String)
        case nameProblem(String)
    }

    /// Adds a device to the list as it is at that moment — under the store's lock, so two
    /// commands adding one device leave one.
    /// `renewing`: one saved already may take the line's announcement in the older one's place. Not
    /// for a line turned to a device other than the one it names: nothing in a line says whose it is.
    static func add(_ new: DeviceProfile, from device: Device, to all: inout [DeviceProfile], renewing: Bool = true) -> Added {
        // Before the name: a device saved already is the likelier reason its name is taken.
        if let i = all.firstIndex(where: { ProfileStore.sameDevice($0, new) }) {
            if unchanged(all[i], by: device, as: new) { return .unchanged(all[i].displayName) }
            // One saved device and no other: with two that match, whose announcement this is can't be told.
            guard renewing, all.filter({ ProfileStore.sameDevice($0, new) }).count == 1,
                  announcedAnew(all[i], by: device, as: new) else { return .already(all[i].displayName) }
            all[i].instanceName = new.instanceName; all[i].txt = new.txt
            return .renewed(all[i].displayName)
        }
        if let problem = all.nameProblem(new.displayName) { return .nameProblem(problem) }
        all.append(new)
        return .added
    }

    enum Replaced: Equatable {
        case replaced
        /// Removed since it was looked up.
        case gone
        /// Another saved device is the one the line is for.
        case already(String)
    }

    /// Puts what a line says in a saved device's place, in the list as it is at that moment.
    static func replace(_ id: UUID, with new: DeviceProfile, in all: inout [DeviceProfile]) -> Replaced {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return .gone }
        if let other = all.first(where: { $0.id != id && ProfileStore.sameDevice($0, new) }) { return .already(other.displayName) }
        all[i].instanceName = new.instanceName; all[i].txt = new.txt
        all[i].remotePairingPort = new.remotePairingPort
        all[i].providerIP = new.providerIP; all[i].providerHostName = new.providerHostName
        all[i].providerID = new.providerID   // one saved by its address is a Tailscale device from here on
        return .replaced
    }

    /// What is saved of a device already says all a line for it does (`new`: the line as it
    /// would be saved here, with the device's address and name on this tailnet).
    static func unchanged(_ saved: DeviceProfile, by device: Device, as new: DeviceProfile) -> Bool {
        guard let have = Introduction.device(of: saved) else { return false }
        return have.port == device.port && have.txt == device.txt
            && saved.providerIP == new.providerIP && saved.providerHostName == new.providerHostName
    }

    /// The same device where it was, announced under another name with that name's tag: the device
    /// makes new ones all the time, and the newest is what a Mac should hold.
    static func announcedAnew(_ saved: DeviceProfile, by device: Device, as new: DeviceProfile) -> Bool {
        guard let have = Introduction.device(of: saved) else { return false }
        func lasting(_ txt: [String: String]) -> [String: String] { txt.filter { $0.key != "identifier" && $0.key != "authTag" } }
        return have.port == device.port && lasting(have.txt) == lasting(device.txt)
            && saved.providerIP == new.providerIP && saved.providerHostName == new.providerHostName
    }

    /// The device to save from a line: where it is comes from this Mac's own Tailscale (`peer`), never the line.
    static func profile(from device: Device, peer: MeshDevice, name: String) -> DeviceProfile? {
        guard let ip = peer.ipv4, let identifier = device.txt["identifier"] else { return nil }
        return DeviceProfile(displayName: name, instanceName: identifier, serviceType: deviceService, domain: "local",
                             remotePairingPort: device.port, bonjourHost: "", txt: device.txt, providerID: "tailscale",
                             providerHostName: peer.name, providerIP: ip)
    }
}

/// Stands in, once, for a Mac that offers to pair: announces its offer on this Mac's LAN and
/// carries what connects there to it. Says what happens; shows nothing itself.
@MainActor
final class Introducer {
    enum End: Equatable {
        /// A connection that carried bytes both ways has closed (or, for a device that is picked, Device Hub
        /// said it paired): a pairing was tried. Whether it was made, only the other Mac knows.
        case carried
        case deadline
        case stopped
        case addressLost
        case announcementLost
    }
    enum Event: Equatable {
        case announced(interface: String, name: String, port: UInt16)
        case connected(from: String)
        case farDidNotAnswer(String)
        /// `clean`: nothing of this is announced or listening any more.
        case ended(End, clean: Bool)
    }
    struct Plan {
        var offer: Introduction.Offer
        var farIP: String
        var localIP: String
        var interface: String
        var accept: Relay.Accept
        var deadline: TimeInterval = 300
        /// What is announced, and under which name: a Mac's offer under its identifier, unless said.
        var service = Introduction.hostService
        var instance: String?
        /// Whether a connection that carried bytes both ways and closed ends it: so for a Mac's offer.
        var endsWhenCarried = true
    }

    private let plan: Plan
    private let record: any BonjourRecord
    private let addressNow: () -> String?
    private let onEvent: (Event) -> Void
    private var relay: Relay?
    private var watches: [Task<Void, Never>] = []
    private(set) var ended = false

    /// `addressNow`: the interface's address at this moment (nil: it has none).
    init(_ plan: Plan, record: any BonjourRecord, addressNow: @escaping () -> String?, onEvent: @escaping (Event) -> Void) {
        self.plan = plan
        self.record = record
        self.addressNow = addressNow
        self.onEvent = onEvent
    }

    /// Throws where it can't listen, or the record can't be announced on that interface alone.
    func start() async throws {
        let identifier = plan.offer.txt["identifier"] ?? ""
        var failure = "no port"
        // The far Mac's own port if it is free here, else one of the next few: the record says which.
        let ports = plan.offer.port...UInt16(min(Int(plan.offer.port) + 20, Int(UInt16.max)))
        for port in ports {
            let relay = Relay(localIP: plan.localIP, localPort: port, remoteIP: plan.farIP, remotePort: plan.offer.port,
                              accept: plan.accept, cap: 2,
                              onFailure: { [weak self] _ in Task { @MainActor in await self?.end(.announcementLost) } },
                              onPair: { [weak self] event in Task { @MainActor in self?.pair(event) } })
            do { try await relay.start() } catch { failure = error.localizedDescription; continue }
            // Ended while that waited: nothing may be announced after it was said nothing is.
            if ended { relay.stop(); throw CancellationError() }
            self.relay = relay
            break
        }
        guard let relay else {
            throw RelayError.bindFailed("no port of \(ports.lowerBound)–\(ports.upperBound) on \(plan.localIP) could be listened on (\(failure))")
        }
        do {
            try record.registerOnItsInterface(instanceName: plan.instance ?? identifier, serviceType: plan.service, domain: "local",
                                              port: relay.localPort, host: Introduction.standInHost(identifier),
                                              ip: plan.localIP, txt: plan.offer.txt)
        } catch {
            relay.stop()
            self.relay = nil
            throw error
        }
        record.onExit = { [weak self] _ in Task { @MainActor in await self?.end(.announcementLost) } }
        onEvent(.announced(interface: plan.interface, name: plan.offer.txt["name"] ?? "", port: relay.localPort))
        let (deadline, local) = (plan.deadline, plan.localIP)
        watches = [
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(deadline))
                if !Task.isCancelled { await self?.end(.deadline) }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, !Task.isCancelled else { return }
                    if self.addressNow() != local { await self.end(.addressLost); return }
                }
            },
        ]
    }

    private func pair(_ event: Relay.PairEvent) {
        guard !ended else { return }
        switch event {
        case .opened(let from): onEvent(.connected(from: from))
        case .closed(_, let up, let down, let why):
            if up > 0, down > 0, plan.endsWhenCarried { Task { await end(.carried) } }
            else if let why { onEvent(.farDidNotAnswer(why)) }
        }
    }

    func end(_ why: End) async {
        guard !ended else { return }
        ended = true
        watches.forEach { $0.cancel() }
        relay?.stop()
        relay = nil
        record.onExit = nil
        record.stop()
        onEvent(.ended(why, clean: await record.previousExited()))
    }
}
