import Foundation

enum MeshProvider: String, CaseIterable, Identifiable {
    case tailscale
    case manual

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .tailscale: return "Tailscale"
        case .manual: return "Manual IP"
        }
    }
}

enum TailscaleClientError: LocalizedError {
    case cliNotFound
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound: return "tailscale CLI not found — install Tailscale or set its path in Settings"
        case .commandFailed(let m): return m
        }
    }
}

struct TailscaleClient {
    /// Configurable binary path (Settings); falls back to common locations.
    var binaryPath: String?

    static let candidatePaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    func resolvedPath() -> String? {
        if let binaryPath, FileManager.default.isExecutableFile(atPath: binaryPath) {
            return binaryPath
        }
        for path in Self.candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Last resort: search PATH via login shell environment.
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") where dir.hasPrefix("/") {   // never "." / relative
                let candidate = "\(dir)/tailscale"
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    /// `tailscale status --json` → every peer as a MeshDevice (Self excluded).
    func listDevices() throws -> [MeshDevice] {
        guard let path = resolvedPath() else { throw TailscaleClientError.cliNotFound }
        let out = try run(path, ["status", "--json"])
        guard let data = out.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw TailscaleClientError.commandFailed("tailscale status: bad JSON") }

        var devices: [MeshDevice] = []
        if let peers = root["Peer"] as? [String: Any] {
            for (_, value) in peers {
                guard let p = value as? [String: Any] else { continue }
                let ips = (p["TailscaleIPs"] as? [String]) ?? []
                let name = (p["DNSName"] as? String)?.components(separatedBy: ".").first
                    ?? (p["HostName"] as? String) ?? "unknown"
                let os = (p["OS"] as? String) ?? ""
                let online = (p["Online"] as? Bool) ?? false
                let id = (p["ID"] as? String) ?? (p["StableID"] as? String) ?? ips.first ?? UUID().uuidString
                devices.append(MeshDevice(id: id, name: name, os: os, ips: ips, online: online,
                                          curAddr: (p["CurAddr"] as? String) ?? "",
                                          relay: (p["Relay"] as? String) ?? ""))
            }
        }
        return devices.sorted { ($0.os == "iOS") != ($1.os == "iOS") ? $0.os == "iOS" : $0.name < $1.name }
    }

    private func run(_ path: String, _ args: [String]) throws -> String {
        let r = Proc.run(path, args)
        guard r.status == 0 else {
            throw TailscaleClientError.commandFailed("tailscale \(args.joined(separator: " ")): \(r.err)")
        }
        return r.out
    }
}
