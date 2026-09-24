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
    var identifier: String? { txt["identifier"] }
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

    var shortLabel: String {
        switch self {
        case .off: return "Off"
        case .starting(let step): return step
        case .active: return "Bridge active"
        case .error: return "Error"
        case .local: return "On this Wi‑Fi"
        }
    }
}

/// What the user needs to know, derived from the bridge internals.
enum BridgeStatus: Equatable, CaseIterable {
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

extension Array where Element == DeviceProfile {
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
