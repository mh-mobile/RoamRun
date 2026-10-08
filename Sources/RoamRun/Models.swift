import Foundation

/// An iPhone's `_remotepairing._tcp` announcement captured from the local network
/// via `dns-sd -Z` zone dump.
struct CapturedService: Identifiable, Hashable {
    /// Service instance name, e.g. "43B54AC2-B696-427E-9B14-37066798330F".
    let instanceName: String
    let serviceType: String
    let domain: String
    var port: UInt16
    /// SRV target host, e.g. "iPhone.local".
    var host: String
    /// Addresses observed for `host` via A/AAAA records in the same dump.
    var hostIPs: [String]
    var txt: [String: String]
    var lastSeen: Date

    var id: String { instanceName }
    var shortHost: String { host.replacingOccurrences(of: ".local", with: "") }
}

/// A peer on the mesh VPN (Tailscale for now; shape is provider-agnostic).
struct MeshDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let os: String
    let ips: [String]
    let online: Bool
    /// Tailscale's current direct endpoint; empty when traffic goes via DERP.
    var curAddr = ""
    /// Home DERP region, e.g. "tok".
    var relay = ""

    var ipv4: String? { ips.first(where: { $0.contains(".") }) }
    var pathDescription: String {
        curAddr.isEmpty ? "via DERP relay (\(relay.isEmpty ? "?" : relay)) — works, but slower" : "direct (\(curAddr))"
    }
    var label: String {
        let suffix = ipv4.map { " (\($0))" } ?? ""
        return "\(name)\(suffix)\(online ? "" : " — offline")"
    }
}

extension Array where Element == MeshDevice {
    /// The device Tailscale reaches directly at one of these addresses — which, on this Mac's
    /// LAN, says which Tailscale device a host seen there is. nil for none, and for more than one.
    func reached(at addresses: [String]) -> MeshDevice? {
        let found = filter { device in
            let parts = device.curAddr.split(separator: ":")
            return parts.count == 2 && addresses.contains(String(parts[0]))
        }
        return found.count == 1 ? found[0] : nil
    }
}

/// A saved pairing between a captured Bonjour identity and a mesh-VPN address.
struct DeviceProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var displayName: String

    // Captured Bonjour identity (republished verbatim through the proxy).
    var instanceName: String
    var serviceType: String
    var domain: String
    var remotePairingPort: UInt16
    var bonjourHost: String
    var txt: [String: String]

    // Mesh endpoint.
    var providerID: String
    var providerHostName: String
    var providerIP: String
    /// Hardware UDID (xcodebuild `-destination id=`, devicectl `--device`),
    /// learned from remotepairingd once the bridge first connects.
    var udid: String?
    /// devicectl's deviceType ("iPhone", "iPad", "realityDevice"), learned by UDID.
    var deviceType: String?

    var symbol: String { Self.symbol(for: deviceType) }

    static func symbol(for deviceType: String?) -> String {
        switch deviceType {
        case "iPad": return "ipad"
        case "realityDevice": if #available(macOS 14, *) { return "vision.pro" } else { return "eyeglasses" }
        default: return "iphone"
        }
    }
}

enum BridgeState: Equatable {
    case off
    case starting(String)
    case active(localPort: UInt16, tunnelPorts: [UInt16])
    case error(String)
    /// The iPhone is on this Mac's LAN: Xcode reaches it directly, so the
    /// bridge stands aside (no fake record) until it leaves.
    case local

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

/// Which network a bridged device is on, as far as the bridge can tell: Wi‑Fi while
/// it answers RemotePairing, cellular when only a tunnel set up before still runs.
enum DeviceNetwork: String, Codable {
    case wifi, cellular

    var title: String { self == .wifi ? "Wi‑Fi" : "Cellular" }

    /// Off unless the user turned it on: over cellular every Run is paid for.
    static let keepOnCellularKey = "keepDebuggingOnCellular"
    static var keepOnCellular: Bool { AppID.settings?.bool(forKey: keepOnCellularKey) ?? false }

    /// The control channel drops for ~0.5 s every ~40 s on Wi‑Fi too: only this long
    /// without it, with the tunnel still carrying traffic, is worth asking where the device is.
    static let cellularAfter: TimeInterval = 30
}

/// How a bridged device is connected. One value, so no mix of flags can say two things
/// at once; `next` is the only way it changes.
enum Link: Equatable {
    /// Neither a control channel nor a tunnel the device answers on.
    case waiting
    case wifi
    /// Only the tunnel set up on Wi‑Fi still runs, and the user wants to keep it.
    case cellular
    /// It was on cellular with Keep debugging on cellular off: its tunnel was closed.
    /// Until a control channel is back (Wi‑Fi), whatever the setting says by then.
    case paused(since: Date)

    /// What a probe of the RemotePairing port found, while only the tunnel holds the device.
    enum Probe { case answers, silentReachable, unreachable }

    struct Inputs {
        var controlOpen: Bool
        /// The device sent bytes on a tunnel within the last 30 s.
        var heard: Bool
        var controlGoneFor: TimeInterval
        /// A probe that just finished, if any.
        var probe: Probe?
        var keepOnCellular: Bool
        var now: Date
    }

    /// A control channel gone this long, with nothing from the device, means it's gone:
    /// on Wi‑Fi remotepairingd redials within ~0.5 s.
    static let waitAfter: TimeInterval = 5

    static func next(_ link: Link, _ i: Inputs) -> Link {
        if i.controlOpen { return .wifi }
        if case .paused = link { return link }
        guard i.heard else { return i.controlGoneFor >= waitAfter ? .waiting : link }
        switch i.probe {
        case .answers: return .wifi
        case .silentReachable: return i.keepOnCellular ? .cellular : .paused(since: i.now)
        case .unreachable, nil: break   // a device Tailscale can't reach is going, not on cellular
        }
        if link == .cellular, !i.keepOnCellular { return .paused(since: i.now) }
        // Heard again after a long silence: which network is for the probe to say.
        if link == .waiting { return i.controlGoneFor >= DeviceNetwork.cellularAfter ? .waiting : .wifi }
        return link
    }
}

/// What the user needs to know, derived from the bridge internals.
/// Raw values are the `state` key of `--json` output: scripts depend on them.
enum BridgeStatus: String, CaseIterable {
    case off, starting, waiting, preparing, ready, error, local

    /// Parses the title written to the shared status file.
    init(title: String) {
        self = Self.allCases.first { $0.title == title } ?? .starting
    }

    var title: String {
        switch self {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .waiting: return "Waiting for device"
        case .preparing: return "Connecting…"
        case .ready: return "Ready for Xcode"
        case .error: return "Needs attention"
        case .local: return "On this Wi‑Fi"
        }
    }

    var isWorking: Bool { self == .starting || self == .preparing }

    var symbol: String {
        switch self {
        case .off: return "pause.circle"
        case .starting, .preparing: return "arrow.triangle.2.circlepath"
        case .waiting: return "iphone.slash"
        case .ready: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .local: return "wifi"
        }
    }
}

/// Beyond id, instance name and address, every field is optional on disk: a field added in a later
/// version (or missing from an older file) must not make the whole list unreadable.
/// The on-disk shape stays a plain array so older RoamRun versions still read it.
extension DeviceProfile {
    private enum CodingKeys: String, CodingKey {
        case id, displayName, instanceName, serviceType, domain, remotePairingPort, bonjourHost, txt
        case providerID, providerHostName, providerIP, udid, deviceType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Required: without these it isn't a device (and a random id would change every load).
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "Device"
        instanceName = try c.decode(String.self, forKey: .instanceName)
        serviceType = try c.decodeIfPresent(String.self, forKey: .serviceType) ?? "_remotepairing._tcp"
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? "local"
        remotePairingPort = try c.decodeIfPresent(UInt16.self, forKey: .remotePairingPort) ?? 49152
        bonjourHost = try c.decodeIfPresent(String.self, forKey: .bonjourHost) ?? ""
        txt = try c.decodeIfPresent([String: String].self, forKey: .txt) ?? [:]
        providerID = try c.decodeIfPresent(String.self, forKey: .providerID) ?? MeshProvider.tailscale.rawValue
        providerHostName = try c.decodeIfPresent(String.self, forKey: .providerHostName) ?? ""
        providerIP = try c.decode(String.self, forKey: .providerIP)
        udid = try c.decodeIfPresent(String.self, forKey: .udid)
        deviceType = try c.decodeIfPresent(String.self, forKey: .deviceType)
    }
}

extension Array where Element == DeviceProfile {
    /// Why a (trimmed) name can't be used, or nil. The CLI takes a leading "-" for an option.
    func nameProblem(_ name: String, except id: UUID? = nil) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return "Enter a name." }
        if n.hasPrefix("-") { return "A name can't start with “-” (the CLI would read it as an option)." }
        if n.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return "A name can't contain control characters." }
        if isNameTaken(n, except: id) { return "Another device already uses this name — pick a different one." }
        return nil
    }

    /// Names are how the CLI addresses devices, so they must be unique.
    func isNameTaken(_ name: String, except id: UUID? = nil) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return contains { $0.id != id && $0.displayName.caseInsensitiveCompare(n) == .orderedSame }
    }

    /// "iPhone", then "iPhone 2", "iPhone 3", …
    func uniqueName(_ base: String) -> String {
        guard isNameTaken(base) else { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !isNameTaken($0) }!
    }
}
