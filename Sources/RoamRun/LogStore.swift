import Foundation
import OSLog

@MainActor
final class LogStore: ObservableObject {
    /// Each line with the device it's about (nil: app-wide), so a rename doesn't hide its history.
    @Published private(set) var lines: [(device: UUID?, text: String)] = []
    /// Lines logged so far, for scrolling: the count of `lines` stops growing at the limit.
    @Published private(set) var appended = 0
    private let limit = 500
    private static let logger = Logger(subsystem: AppID.bundle, category: "bridge")

    func log(_ message: String, device: UUID? = nil) {
        // Private in the system log: lines carry UDIDs and addresses. The in-app log shows them in full.
        Self.logger.log("\(message, privacy: .private)")
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        lines.append((device, "\(stamp)  \(message)"))
        appended += 1
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }
}
