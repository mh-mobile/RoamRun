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
        let path = AppID.settings?.string(forKey: "tailscaleCLIPath") ?? ""
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
        // Signed out or disconnected still prints valid JSON, just with no peers.
        // Left alone that reads as "running, 0 peers", and every check after it
        // blames the device instead of this Mac.
        if let problem = Self.stateProblem(inStatusJSON: out) { throw TailscaleClientError.commandFailed(problem) }
        guard let devices = Self.devices(fromStatusJSON: out) else {
            throw TailscaleClientError.commandFailed("tailscale status: bad JSON")
        }
        return devices
    }

    /// This Mac's MagicDNS name, which is the host OTA links are built on.
    func selfDNSName() throws -> String? {
        guard let path = resolvedPath() else { throw TailscaleClientError.cliNotFound }
        let out = try run(path, ["status", "--json"])
        if let problem = Self.stateProblem(inStatusJSON: out) { throw TailscaleClientError.commandFailed(problem) }
        guard let data = out.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = (root["Self"] as? [String: Any])?["DNSName"] as? String, !name.isEmpty else { return nil }
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }

    /// The paths `tailscale serve` is proxying, so the CLI can say whether the
    /// OTA page is actually reachable without asking the app.
    static func servedPaths() -> [String: String] {
        served(in: Proc.run(fromSettings().resolvedPath() ?? "/usr/bin/false", ["serve", "status"], timeout: 10).out)
    }

    /// Ports whose serve config is published to the internet. `tailscale serve`
    /// and `tailscale funnel` write the same config, and a serve call can turn
    /// funnel off for the port it touches — which would quietly take someone's
    /// public service private. RoamRun stays away from such a port entirely.
    static func funnelPorts() -> Set<String> {
        funnelled(inJSON: Proc.run(fromSettings().resolvedPath() ?? "/usr/bin/false",
                                   ["serve", "status", "--json"], timeout: 10).out)
    }

    static func funnelled(inJSON out: String) -> Set<String> {
        guard let data = out.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let allow = root["AllowFunnel"] as? [String: Any] else { return [] }
        // Keys are "host:port"; only the port matters to us.
        return Set(allow.filter { ($0.value as? Bool) == true }
            .keys.compactMap { $0.split(separator: ":").last.map(String.init) })
    }

    /// Whether RoamRun's own entry is there *and* something is listening behind
    /// it. A crash leaves the entry pointing at a port nothing holds any more, and
    /// then `serve status` alone says the page works when it 502s.
    static func servingLive(_ path: String) -> Bool {
        guard let target = servedPaths()[path],
              target == AppID.settings?.string(forKey: AppCoordinator.otaServingKey),
              let port = UInt16(target.split(separator: ":").last ?? "") else { return false }
        return listening(on: port)
    }

    /// One connect to loopback; refused comes back at once.
    static func listening(on port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        return ok
    }

    /// path → what it proxies to, for the default https block only: the same path
    /// can also be mounted on another port, and that one isn't the page's address.
    static func served(in out: String) -> [String: String] {
        var result: [String: String] = [:]
        var inDefault = false
        for raw in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("http://") || line.hasPrefix("tcp://") {
                inDefault = false   // another block, not the page's address
                continue
            }
            if line.hasPrefix("https://") {
                // `https://host (tailnet only)` is :443; `https://host:8790` is not.
                let host = line.split(separator: " ").first.map(String.init) ?? ""
                inDefault = !host.dropFirst("https://".count).contains(":")
                continue
            }
            guard inDefault, line.hasPrefix("|--") else { continue }
            let parts = line.dropFirst(3).trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
            if let path = parts.first { result[path] = parts.count > 2 ? parts[2] : "" }
        }
        return result
    }

    /// nil while Tailscale is up; otherwise what to tell the user.
    static func stateProblem(inStatusJSON out: String) -> String? {
        guard let data = out.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let state = root["BackendState"] as? String else { return nil }   // older versions: leave it be
        return stateProblem(state)
    }

    static func stateProblem(_ state: String) -> String? {
        switch state {
        case "Running": return nil
        case "NeedsLogin": return "Tailscale on this Mac isn't signed in — open Tailscale and sign in"
        case "Stopped": return "Tailscale on this Mac is disconnected — open Tailscale and connect"
        default: return "Tailscale on this Mac isn't ready (\(state)) — open Tailscale and check it"
        }
    }

    /// Peers from `tailscale status --json`, iOS first; nil if it isn't that JSON.
    static func devices(fromStatusJSON out: String) -> [MeshDevice]? {
        guard let data = out.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
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
