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
    func selfDNSName(timeout: TimeInterval = 5) throws -> String? {
        guard let path = resolvedPath() else { throw TailscaleClientError.cliNotFound }
        let out = try run(path, ["status", "--json"], timeout: timeout)
        if let problem = Self.stateProblem(inStatusJSON: out) { throw TailscaleClientError.commandFailed(problem) }
        guard let data = out.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = (root["Self"] as? [String: Any])?["DNSName"] as? String, !name.isEmpty else { return nil }
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }

    /// Whether this tailnet issues HTTPS certificates. Off by default, and
    /// without it `tailscale serve --https=…` writes nothing at all: it prints a
    /// link to the page that turns it on and exits 0 (serve_legacy.go,
    /// `enableFeatureInteractive`). So it is worth naming before anything else.
    /// nil when Tailscale couldn't be asked.
    static func httpsEnabled() -> Bool? {
        let out = Proc.run(fromSettings().resolvedPath() ?? "/usr/bin/false", ["status", "--json"], timeout: 5)
        guard out.status == 0, let data = out.out.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        // Absent and empty mean the same thing here: the field is `omitempty`,
        // so an empty list simply isn't in the JSON.
        return !((root["CertDomains"] as? [String] ?? []).isEmpty)
    }

    /// What `tailscale serve` has on one port. `unknown` is a case of its own on
    /// purpose: tailscaled not answering is not the same as the port being free,
    /// and reading one as the other is how RoamRun would overwrite an entry of
    /// the user's — which `tailscale serve` cannot undo.
    enum Serving: Equatable {
        case unknown
        case nothing
        /// Every `/` proxy on that port, each with the host key it sits under —
        /// a tailnet rename leaves the old name behind, so there can be more than
        /// one — and the other mounts.
        case mounted(roots: [Root], others: [Mount], funnelled: [String] = [])

        /// A root and the name it is registered under. The name is half the
        /// identity: `tailscale serve --https=P …` and `… off` both act on
        /// `st.Self.DNSName` and nothing else, so a root under a name the node
        /// used to have is neither ours to replace nor ours to remove.
        struct Root: Equatable {
            let host: String
            let target: String
        }

        /// What those two commands would replace or remove, under the name the
        /// node has now.
        func root(on host: String) -> String? {
            guard case .mounted(let roots, _, _) = self else { return nil }
            return roots.first { $0.host == host }?.target
        }

        /// A mount that isn't a root. `host` is nil for one that isn't tied to a
        /// name at all — a TCP forward belongs to the port itself, and `tailscale`
        /// refuses to serve web on a port carrying one whatever it is called.
        struct Mount: Equatable {
            let host: String?
            let path: String
        }

        /// Whether `target` is registered under any name at all. For "did my
        /// registration land", where the name it landed under doesn't matter and
        /// scoping to one would read a rename as a failure.
        func isRegistered(_ target: String) -> Bool {
            guard case .mounted(let roots, _, _) = self else { return false }
            return roots.contains { $0.target == target }
        }
        /// Whether Tailscale Funnel is on for that port under this name. RoamRun
        /// never turns it on and picks a port Funnel can't publish — but that list
        /// is Tailscale's current policy, not a law, and a page of unreleased
        /// builds on the public internet is worth checking rather than assuming.
        func funnelled(on host: String) -> Bool {
            guard case .mounted(_, _, let funnel) = self else { return false }
            return funnel.contains(host)
        }

        /// What else is on that port under this name, and so would sit beside the
        /// page. RoamRun keeps a port to itself, so anything here means it stays
        /// away — not because sharing would break something, but because a port of
        /// its own is the whole reason it doesn't use your `:443`.
        ///
        /// What sits under a name the node used to have is not here and not
        /// anyone's problem: `serve` can't reach it and the name no longer
        /// resolves, so it is inert config, not a port in use.
        func alongside(_ host: String) -> [String] {
            guard case .mounted(_, let others, _) = self else { return [] }
            return others.filter { $0.host == nil || $0.host == host }.map(\.path)
        }

        /// For the one sentence every caller has to write about a port it can't have.
        var described: String {
            switch self {
            case .unknown: return "something RoamRun couldn't read"
            case .nothing: return "nothing"
            case .mounted(let roots, let others, _):
                let all = roots.map { $0.target.isEmpty ? "\($0.host)/" : $0.target } + others.map(\.path)
                return all.count > 3 ? "\(all.count) mounts" : all.joined(separator: ", ")
            }
        }
    }

    /// A port of RoamRun's own rather than a path on `:443`: that port carries
    /// whatever else the user serves, and Funnel can only publish 443, 8443 and
    /// 10000 — so a port outside those cannot reach the internet at all.
    static func serving(port: Int, timeout: TimeInterval = 10) -> Serving {
        let out = Proc.run(fromSettings().resolvedPath() ?? "/usr/bin/false",
                           ["serve", "status", "--json"], timeout: timeout)
        guard out.status == 0 else { return .unknown }
        return serving(port: port, inJSON: out.out)
    }

    /// From the JSON, not the display output: a wording change there would read
    /// as "nothing is here", which is exactly when RoamRun would overwrite
    /// something of the user's. A bare `null` is what tailscale marshals when
    /// there is no serve config at all — the one case where "nothing" is right,
    /// and it needs `fragmentsAllowed` to parse as JSON.
    static func serving(port: Int, inJSON out: String) -> Serving {
        guard let data = out.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return .unknown }
        if parsed is NSNull { return .nothing }
        guard let root = parsed as? [String: Any] else { return .unknown }
        var roots: [Serving.Root] = []
        var others: [Serving.Mount] = []
        // Not only `Web`: `tailscale serve --tcp=P` puts a forward in `TCP` with no
        // Web entry at all, and a port carrying one is not an empty port. Reading
        // a section we don't look at as "nothing here" is the same mistake one
        // layer down.
        if let tcp = (root["TCP"] as? [String: Any])?["\(port)"] as? [String: Any],
           tcp["TCPForward"] != nil || tcp["TerminateTLS"] != nil {   // ipn.TCPPortHandler's keys
            others.append(.init(host: nil, path: "TCP forwarding"))   // no Web entry of its own
        }
        // Every host key for that port, not the first the dictionary happens to
        // yield: a tailnet rename leaves the old name behind.
        var funnelled: [String] = []
        for (hostPort, on) in (root["AllowFunnel"] as? [String: Any] ?? [:])
        where hostPort.hasSuffix(":\(port)") && (on as? Bool) == true {
            funnelled.append(String(hostPort.dropLast(":\(port)".count)))
        }
        for (hostPort, value) in (root["Web"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key })
        where hostPort.hasSuffix(":\(port)") {
            // Every host's root, not the first one found: the second would
            // otherwise be invisible, and invisible is what gets overwritten.
            let host = String(hostPort.dropLast(":\(port)".count))
            guard let handlers = (value as? [String: Any])?["Handlers"] as? [String: Any] else {
                // An entry for this port whose inside we can't read. Not nothing:
                // reading it that way is how RoamRun would take a port in use.
                others.append(.init(host: host, path: "\(host) (unreadable)"))
                continue
            }
            if let here = handlers["/"] as? [String: Any] {
                roots.append(.init(host: host, target: (here["Proxy"] as? String) ?? ""))
            }
            others += handlers.keys.filter { $0 != "/" }.map { .init(host: host, path: $0) }
        }
        guard !roots.isEmpty || !others.isEmpty || !funnelled.isEmpty else { return .nothing }
        return .mounted(roots: roots.sorted { $0.host < $1.host },
                        others: others.sorted { $0.path < $1.path }, funnelled: funnelled.sorted())
    }

    /// Whether RoamRun's own entry is there *and* something is listening behind
    /// it. A crash leaves the entry pointing at a port nothing holds any more, and
    /// then `serve status` alone says the page works when it 502s.
    static func servingLive(port: Int, host: String? = nil) -> Bool {
        guard let host = host ?? AppCoordinator.currentHost(),
              let target = serving(port: port).root(on: host),
              AppCoordinator.isOurs(target, on: port),
              let local = UInt16(target.split(separator: ":").last ?? "") else { return false }
        return listening(on: local)
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
        let r = Proc.run(path, Self.pingArgs(ip))
        return r.status == 0 && r.out.contains("pong")
    }

    /// `--until-direct` defaults to true: a pong via DERP then exits 1 ("direct
    /// connection not established"), and a relayed device would read as down.
    static func pingArgs(_ ip: String) -> [String] {
        ["ping", "-c", "1", "--timeout", "3s", "--until-direct=false", ip]
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

    private func run(_ path: String, _ args: [String], timeout: TimeInterval = 5) throws -> String {
        let r = Proc.run(path, args, timeout: timeout)   // a wedged tailscaled must not hang a bridge start
        guard r.status == 0 else {
            throw TailscaleClientError.commandFailed("tailscale \(args.joined(separator: " ")): \(r.err)")
        }
        return r.out
    }
}
