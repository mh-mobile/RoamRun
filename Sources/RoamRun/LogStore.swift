import Foundation
import OSLog

@MainActor
final class LogStore: ObservableObject {
    /// Each line with the device it's about (nil: app-wide), so a rename doesn't hide its history.
    @Published private(set) var lines: [(device: UUID?, text: String)] = []
    private let limit = 500
    private static let logger = Logger(subsystem: "com.roamrun.app", category: "bridge")

    func log(_ message: String, device: UUID? = nil) {
        Self.logger.log("\(message, privacy: .public)")
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        lines.append((device, "\(stamp)  \(message)"))
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }
}
