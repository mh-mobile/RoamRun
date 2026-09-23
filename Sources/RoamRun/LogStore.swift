import Foundation
import OSLog

@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var lines: [String] = []
    private let limit = 500
    private static let logger = Logger(subsystem: "com.roamrun.app", category: "bridge")

    func log(_ message: String) {
        Self.logger.log("\(message, privacy: .public)")
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        lines.append("\(stamp)  \(message)")
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }
}
