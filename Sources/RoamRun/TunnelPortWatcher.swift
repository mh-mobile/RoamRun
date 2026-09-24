import Foundation

/// Watches `log stream` for remotepairingd's "Got tunnel endpoint" line and
/// reports the UDP/TCP port the CoreDevice tunnel actually landed on, so we
/// can relay exactly that port instead of forwarding a blind range.
final class TunnelPortWatcher {
    /// (port, UDID of the iPhone it belongs to — nil if not seen).
    var onPort: ((UInt16, String?) -> Void)?
    /// (Bonjour instance, UDID) each time remotepairingd authenticates a
    /// control channel — i.e. the device just became reachable.
    var onDevice: ((String, String) -> Void)?
    /// Bonjour instance that remotepairingd could NOT match to a pairing —
    /// the Mac no longer trusts it, or its TXT (authTag) is stale.
    var onUnrecognized: ((String) -> Void)?
    var onLog: ((String) -> Void)?

    private var process: Process?
    private var reader: LineReader?
    private static let pattern = #/Got tunnel endpoint: '[^']*:(\d+)'/#
    /// The endpoint line doesn't name the device; the line right before it does.
    /// Requests still waiting for their endpoint; two different iPhones among
    /// them means we can't tell whose it is, so the port stays unattributed.
    private static let establishPattern = #/\(([0-9A-Fa-f-]+)\): Sending tunnel establish request/#
    private var pending: [(udid: String, at: Date)] = []
    /// After an ambiguous endpoint, any request in flight may be answered by
    /// the wrong one — attribute nothing for a while.
    private var ambiguousUntil = Date.distantPast
    /// What follows the first "Resolved bonjour advert " must be *exactly*
    /// "<uuid> to identity …" to the end of the line. The instance name comes
    /// from the LAN and may contain spaces, so a loose search could be fooled
    /// by a crafted name that embeds a fake "… to identity nil" phrase.
    private static let advertMarker = "Resolved bonjour advert "
    private static let advertPattern = #/([0-9A-Fa-f-]+) to identity (?:associated with udid ([0-9A-Fa-f-]+)|nil, udid nil)/#

    func start() {
        guard process == nil else { return }
        let task = Proc.tied("/usr/bin/log", [
            "stream", "--style", "compact",
            "--predicate",
            #"process == "remotepairingd" AND (eventMessage CONTAINS "Got tunnel endpoint" OR eventMessage CONTAINS "Sending tunnel establish request" OR eventMessage CONTAINS "Resolved bonjour advert")"#
        ])
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        reader = LineReader(pipe) { [weak self] line in self?.handle(line) }
        do {
            try task.run()
            process = task
            onLog?("Watching remotepairingd for tunnel endpoint")
        } catch {
            onLog?("Failed to start log stream: \(error.localizedDescription)")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    func handle(_ line: String, now: Date = .now) {
        pending.removeAll { now.timeIntervalSince($0.at) > 5 }   // a failed request never gets an endpoint
        if let m = line.firstMatch(of: Self.pattern), let port = UInt16(m.1) {
            let owners = Set(pending.map(\.udid))
            if owners.count > 1 { ambiguousUntil = now + 5 }
            onPort?(port, owners.count == 1 && now >= ambiguousUntil ? owners.first : nil)
            // Unknown whose request this answered, so the rest can't be trusted either.
            if owners.count > 1 { pending.removeAll() } else if !pending.isEmpty { pending.removeFirst() }
        } else if let m = line.firstMatch(of: Self.establishPattern) {
            pending.append((String(m.1), now))
        } else if let (instance, udid) = Self.advert(in: line) {
            if let udid { onDevice?(instance, udid) } else { onUnrecognized?(instance) }
        }
    }

    /// (instance, UDID — nil when remotepairingd has no pairing for it).
    static func advert(in line: String) -> (String, String?)? {
        guard let r = line.range(of: advertMarker),
              let m = line[r.upperBound...].trimmingCharacters(in: .whitespaces).wholeMatch(of: advertPattern) else { return nil }
        return (String(m.1), m.2.map(String.init))
    }
}
