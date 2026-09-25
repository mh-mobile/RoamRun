import Foundation

/// Runs `/usr/bin/dns-sd -Z <type> <domain>` and parses the zone dump into
/// `CapturedService` values: PTR gives the instance names, SRV the port and
/// target host, TXT the pairing metadata, A/AAAA the host addresses.
@MainActor
final class BonjourCapture: ObservableObject {
    /// A flooding LAN peer must not grow the tables without bound.
    private static let cap = 500

    @Published private(set) var services: [String: CapturedService] = [:]

    /// Hostnames we publish ourselves via `dns-sd -P`. Instances resolving to
    /// these are our own registrations, not real devices.
    var ownedHosts = Set<String>()

    var onLog: ((String) -> Void)?

    private var process: Process?
    private var stopped = false
    private var reader: LineReader?
    private var srvByRecord: [String: (host: String, port: UInt16)] = [:]
    private var txtByRecord: [String: [String: String]] = [:]
    private var ipsByHost: [String: [String]] = [:]
    private var ptrs: Set<String> = []
    /// When each record (instance) was last seen: full tables drop the stalest, so a
    /// flood can't lock real devices out.
    private var seen: [String: Date] = [:]
    private var hostSeen: [String: Date] = [:]
    private var serviceType = "_remotepairing._tcp"
    private var domain = "local"

    func start(serviceType: String = "_remotepairing._tcp", domain: String = "local") {
        guard process == nil else { return }
        stopped = false
        self.serviceType = serviceType
        self.domain = domain

        let task = Proc.tied("/usr/bin/dns-sd", ["-Z", serviceType, domain])
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        reader = LineReader(pipe) { [weak self] line in
            Task { @MainActor in self?.parse(line: line) }
        }
        do {
            try task.run()
            process = task
            task.terminationHandler = { [weak self] ended in
                Task { @MainActor in
                    // Only restart if *this* process was the live one — a
                    // late handler from an old one must not drop its successor.
                    guard let self, self.process === ended else { return }
                    self.process = nil
                    self.onLog?("dns-sd -Z exited unexpectedly; restarting in 5s")
                    try? await Task.sleep(for: .seconds(5))
                    guard !self.stopped else { return }   // the sheet closed meanwhile
                    self.start(serviceType: self.serviceType, domain: self.domain)
                }
            }
            onLog?("Bonjour scan started (\(serviceType))")
        } catch {
            onLog?("Failed to start dns-sd -Z: \(error.localizedDescription)")
        }
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    /// Start over from what mDNS holds right now: records we saw earlier may
    /// be gone (device left, cache flushed) and the dump never says so.
    func restart() {
        stop()
        services = [:]
        srvByRecord = [:]
        txtByRecord = [:]
        ipsByHost = [:]
        ptrs = []
        start(serviceType: serviceType, domain: domain)
    }

    func parse(line: String) {   // internal for tests
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(";") else { return }
        let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 3 else { return }
        let kind = tokens[1]
        let recordName = tokens[0]
        switch kind {
        case "PTR":
            // _type PTR <instance>._type
            guard recordName == serviceType else { return }
            let instanceFQDN = tokens[2].trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
            guard !instanceFQDN.isEmpty else { return }
            makeRoom(for: instanceFQDN)
            if ptrs.insert(instanceFQDN).inserted { emit(recordName: instanceFQDN) }
        case "SRV":
            // <instance>._type SRV 0 0 <port> <host>. ; comment
            guard tokens.count >= 6, let port = UInt16(tokens[4]) else { return }
            var host = tokens[5]
            if let c = host.firstIndex(of: ";") { host = String(host[..<c]) }
            host = host.trimmingCharacters(in: .whitespaces)
            if host.hasSuffix(".") { host.removeLast() }
            makeRoom(for: recordName)
            srvByRecord[recordName] = (host, port)
            emit(recordName: recordName)
        case "TXT":
            var dict: [String: String] = [:]
            for match in trimmed.matches(of: #/"([^"]*)"/#) {
                let pair = String(match.1)
                if let eq = pair.firstIndex(of: "=") {
                    dict[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
                } else {
                    dict[pair] = ""
                }
            }
            if !dict.isEmpty { makeRoom(for: recordName); txtByRecord[recordName] = dict }
            emit(recordName: recordName)
        case "A", "AAAA":
            // <host>. A <ip>
            var host = recordName
            if host.hasSuffix(".") { host.removeLast() }
            if ipsByHost[host] == nil, ipsByHost.count >= Self.cap,
               let stalest = hostSeen.min(by: { $0.value < $1.value })?.key {
                ipsByHost[stalest] = nil; hostSeen[stalest] = nil
            }
            hostSeen[host] = .now
            if !(ipsByHost[host] ?? []).contains(tokens[2]), (ipsByHost[host]?.count ?? 0) < 8 { ipsByHost[host, default: []].append(tokens[2]) }
            // host IPs may complete a pending service
            for (rec, srv) in srvByRecord where srv.host == host { emit(recordName: rec) }
        default:
            break
        }
    }

    /// Marks `record` fresh; when the tables are full, forgets the least recently seen record.
    private func makeRoom(for record: String) {
        if seen[record] == nil, seen.count >= Self.cap, let stalest = seen.min(by: { $0.value < $1.value })?.key {
            seen[stalest] = nil
            ptrs.remove(stalest)
            srvByRecord[stalest] = nil
            txtByRecord[stalest] = nil
            services[stalest] = nil
        }
        seen[record] = .now
    }

    private func emit(recordName: String) {
        guard ptrs.contains(recordName) || recordName.hasSuffix(".\(serviceType)") else { return }
        let instance = String(recordName.dropLast(recordName.hasSuffix(".\(serviceType)") ? serviceType.count + 1 : 0))
        guard let srv = srvByRecord[recordName] else { return }
        if ownedHosts.contains(srv.host) { return }
        services[recordName] = CapturedService(
            instanceName: instance,
            serviceType: serviceType,
            domain: domain,
            port: srv.port,
            host: srv.host,
            hostIPs: ipsByHost[srv.host] ?? [],
            txt: txtByRecord[recordName] ?? [:],
            lastSeen: Date()
        )
    }
}
