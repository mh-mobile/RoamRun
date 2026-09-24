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

    /// PATH as the user's own shell sets it (rc files included). An app opened
    /// from Finder only gets launchd's minimal PATH, missing e.g. ~/go/bin or Nix.
    static let shellPATH: String = {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        let out = Proc.run(shell, ["-ilc", #"printf '\n__RR_PATH__%s' "$PATH""#], timeout: 3).out
        guard let r = out.range(of: "__RR_PATH__", options: .backwards) else { return "" }
        return out[r.upperBound...].trimmingCharacters(in: .newlines)
    }()

    /// The client with the CLI path from Settings. The app owns the defaults
    /// domain; the CLI reads it by suite name.
    static func fromSettings() -> TailscaleClient {
        let defaults = Bundle.main.bundleIdentifier == "com.roamrun.app" ? .standard : UserDefaults(suiteName: "com.roamrun.app")
        let path = defaults?.string(forKey: "tailscaleCLIPath") ?? ""
        return TailscaleClient(binaryPath: path.isEmpty ? nil : path)
    }

    func resolvedPath() -> String? {
        if let binaryPath, FileManager.default.isExecutableFile(atPath: binaryPath) {
            return binaryPath
        }
        for path in Self.candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Last resort: our PATH, then the one the user's shell sets up.
        for path in [ProcessInfo.processInfo.environment["PATH"] ?? "", Self.shellPATH] {
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

    /// Tailscale-level reachability (disco ping), independent of iPhone services.
    func ping(_ ip: String) -> Bool {
        guard let path = resolvedPath() else { return false }
        let r = Proc.run(path, ["ping", "-c", "1", "--timeout", "3s", ip])
        return r.status == 0 && r.out.contains("pong")
    }

    /// Host of the peer's direct path ("192.168.1.42"), nil when relayed or
    /// unreachable. Pinging also wakes an idle peer, whose CurAddr is empty.
    func directHost(_ ip: String) throws -> String? {
        guard let path = resolvedPath() else { throw TailscaleClientError.cliNotFound }
        return Self.directHost(fromPing: Proc.run(path, ["ping", "-c", "3", "--timeout", "2s", ip], timeout: 8).out)
    }

    /// "pong from my-iphone (100.64.0.10) via 192.168.1.42:41641 in 40ms" / "via DERP(tok) in …" / "via [fd00::1]:41641 in …"
    static func directHost(fromPing out: String) -> String? {
        guard let line = out.split(separator: "\n").last(where: { $0.hasPrefix("pong") }),
              let via = line.range(of: " via ")?.upperBound,
              let port = line[via...].range(of: ":", options: .backwards)?.lowerBound,
              !line[via...].hasPrefix("DERP") else { return nil }
        return line[via..<port].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private func run(_ path: String, _ args: [String]) throws -> String {
        let r = Proc.run(path, args, timeout: 5)   // a wedged tailscaled must not hang a bridge start
        guard r.status == 0 else {
            throw TailscaleClientError.commandFailed("tailscale \(args.joined(separator: " ")): \(r.err)")
        }
        return r.out
    }
}
