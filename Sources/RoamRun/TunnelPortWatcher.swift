import Foundation

/// Watches `log stream` for remotepairingd's "Got tunnel endpoint" line and
/// reports the UDP/TCP port the CoreDevice tunnel actually landed on, so we
/// can relay exactly that port instead of forwarding a blind range.
final class TunnelPortWatcher {
    var onPort: ((UInt16) -> Void)?
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
            #"process == "remotepairingd" AND (eventMessage CONTAINS "Got tunnel endpoint" OR eventMessage CONTAINS "Resolved bonjour advert")"#
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

    private func handle(_ line: String) {
        if let m = line.firstMatch(of: Self.pattern), let port = UInt16(m.1) {
            onPort?(port)
        } else if let r = line.range(of: Self.advertMarker),
                  let m = line[r.upperBound...].trimmingCharacters(in: .whitespaces).wholeMatch(of: Self.advertPattern) {
            if let udid = m.2 { onDevice?(String(m.1), String(udid)) } else { onUnrecognized?(String(m.1)) }
        }
    }
}
