import Foundation
import Network

/// What one Mac hands another, as a line a person carries, so that a Mac that never shared a
/// network with a device can be introduced to it. Neither holds a key, and neither says where
/// anything is to go: the Mac that reads one finds that out from its own Tailscale.
enum Introduction {
    /// A Mac's offer to pair, as Xcode announces it: what to announce in its place, and the
    /// port it listens on.
    struct Offer: Codable, Equatable {
        var v = 1
        var port: UInt16
        var txt: [String: String]

        static let prefix = "rr-xcode-offer-v1:"
        static let keys: Set<String> = ["identifier", "authTag", "model", "name", "flags", "ver", "minVer"]
    }

    /// A saved device without its UDID or any key: what a bridge announces for it, and the
    /// name Tailscale knows it by.
    struct Device: Codable, Equatable {
        var v = 1
        var name: String
        var peer: String
        var port: UInt16
        var txt: [String: String]

        static let prefix = "rr-device-v1:"
        static let keys: Set<String> = ["identifier", "authTag", "flags", "ver", "minVer"]
    }

    static func line(_ offer: Offer) -> String { Offer.prefix + packed(offer) }
    static func line(_ device: Device) -> String { Device.prefix + packed(device) }

    enum Unreadable: Error, Equatable {
        /// The other kind of line, or a key file's path: named, so the message can say which.
        case another(String)
        case notOne
        case refused(String)
    }

    static func offer(from line: String) -> Result<Offer, Unreadable> {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix(Device.prefix) { return .failure(.another("a saved device (for `roamrun devices add`)")) }
        guard line.hasPrefix(Offer.prefix), let offer: Offer = unpacked(line.dropFirst(Offer.prefix.count)), offer.v == 1 else {
            return .failure(.notOne)
        }
        if let problem = portProblem(offer.port) ?? txtProblem(offer.txt, keys: Offer.keys) { return .failure(.refused(problem)) }
        return .success(offer)
    }

    static func device(from line: String) -> Result<Device, Unreadable> {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix(Offer.prefix) { return .failure(.another("a Mac's offer to pair (for `roamrun pair introduce`)")) }
        guard line.hasPrefix(Device.prefix), let device: Device = unpacked(line.dropFirst(Device.prefix.count)), device.v == 1 else {
            return .failure(.notOne)
        }
        if let problem = portProblem(device.port) ?? txtProblem(device.txt, keys: Device.keys) { return .failure(.refused(problem)) }
        if let problem = [DeviceProfile]().nameProblem(device.name) { return .failure(.refused("its name: \(problem)")) }
        guard device.name.utf8.count <= 64, shows(device.name) else { return .failure(.refused("its name can't be shown as it is")) }
        let peer = device.peer.lowercased()
        guard (1...253).contains(peer.utf8.count), !peer.hasPrefix("-"), !peer.hasPrefix("."),
              peer.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == ".") }) else {
            return .failure(.refused("its Tailscale name isn't one"))
        }
        return .success(device)
    }

    /// Nothing below 1024 is a port either kind of listener takes.
    private static func portProblem(_ port: UInt16) -> String? {
        port >= 1024 ? nil : "port \(port) isn't one a pairing listens on"
    }

    /// Exactly the keys this was built for, each a value of its kind. A record made of these
    /// is announced on a LAN and its name shown on a device: nothing that isn't plainly a
    /// value gets there.
    static func txtProblem(_ txt: [String: String], keys: Set<String>) -> String? {
        let given = Set(txt.keys)
        if given != keys {
            let missing = keys.subtracting(given).sorted(), extra = given.subtracting(keys).sorted()
            return "its announcement isn't the kind this RoamRun knows"
                + (missing.isEmpty ? "" : " (missing: \(missing.joined(separator: ", ")))")
                + (extra.isEmpty ? "" : " (not known: \(extra.count))")
        }
        for (key, value) in txt {
            let ok: Bool
            switch key {
            case "identifier": ok = UUID(uuidString: value) != nil
            case "authTag": ok = (1...32).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "+" || $0 == "/") }
            case "model": ok = (1...40).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ",._-".unicodeScalars.contains($0)) }
            case "name": ok = (1...63).contains(value.utf8.count) && shows(value) && !value.contains("=") && !value.contains("\\")
            default: ok = (1...6).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
            }
            if !ok { return "its announcement's \(key) isn't one" }
        }
        return nil
    }

    /// Whether text reads on a screen as what it is: no control characters, none that format
    /// or reorder what is around them, and no line breaks.
    static func shows(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy {
            switch $0.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: return false
            default: return true
            }
        }
    }

    private static func packed<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(value)) ?? Data()
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // ponytail: 4 KB is many times either line; nothing longer is read at all.
    private static func unpacked<T: Decodable>(_ text: Substring) -> T? {
        guard text.utf8.count <= 4096 else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

extension Introduction {
    /// What a Mac announces while it waits to be paired with.
    static let hostService = "_remotepairing-pairable-host._tcp"
    static let deviceService = "_remotepairing._tcp"

    /// A stand-in's host name: under `.roamrun.local`, which is how a leftover helper is known for ours.
    static func standInHost(_ identifier: String) -> String {
        "rr-intro-\(identifier.prefix(8).lowercased()).roamrun.local"
    }

    /// The offer as a stand-in announces it: under the name Tailscale has for that Mac, which
    /// is what the device then shows. The name the Mac gave itself in its offer is its own to
    /// choose, and could be anyone's; this one is the name the person just used for it.
    static func announced(_ offer: Offer, as tailscaleName: String) -> Offer {
        var out = offer
        let name = String(tailscaleName.prefix(63))
        if !name.isEmpty, shows(name), !name.contains("="), !name.contains("\\") { out.txt["name"] = name }
        return out
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

    /// A device's line fit to show: read and written again, never the bytes that came.
    static func shown(_ text: String) -> String? {
        guard case .success(let device) = device(from: text) else { return nil }
        return line(device)
    }

    enum Added: Equatable {
        case added
        case unchanged(String)
        case already(String)
        case nameProblem(String)
    }

    /// Adds a device to the list as it is at that moment — under the store's lock, so two
    /// commands adding one device leave one.
    static func add(_ new: DeviceProfile, from device: Device, to all: inout [DeviceProfile]) -> Added {
        // Before the name: a device saved already is the likelier reason its name is taken.
        if let same = all.first(where: { ProfileStore.sameDevice($0, new) }) {
            return unchanged(same, by: device, as: new) ? .unchanged(same.displayName) : .already(same.displayName)
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
        /// A connection that carried bytes both ways has closed: a pairing was tried. Whether it
        /// was made, only the other Mac knows.
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
            try record.registerOnItsInterface(instanceName: identifier, serviceType: Introduction.hostService, domain: "local",
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
            if up > 0, down > 0 { Task { await end(.carried) } }
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
