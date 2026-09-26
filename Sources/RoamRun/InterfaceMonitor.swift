import Foundation
import Network

/// Tracks the Mac's IPv4 address on the LAN interface (en0 by default) and
/// notifies when it changes, so active bridges can re-bind their relays and
/// re-publish the proxy registration with the new address.
/// State touched only on `queue` (checks) or before start().
final class InterfaceMonitor: @unchecked Sendable {
    var onChange: ((String) -> Void)?
    /// en0 had an address and lost it.
    var onLost: (() -> Void)?

    /// nil: follow `lanInterface`, which Settings (or a cable) can change.
    private let fixedInterface: String?
    private var monitor: NWPathMonitor?
    /// Path updates and the initial check run here, never concurrently.
    private let queue = DispatchQueue(label: "com.roamrun.app.interface-monitor")
    private(set) var lastKnownIP: String?

    init(interfaceName: String? = nil) {
        self.fixedInterface = interfaceName
    }

    func start() {
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] _ in
            self?.check()
        }
        monitor.start(queue: queue)
        queue.async { self.check() }
    }

    /// The chosen interface changed: take its current address as known, without
    /// reporting a change (the caller restarts the bridges once).
    func resync() {
        queue.sync { lastKnownIP = Self.currentIPv4(on: fixedInterface ?? Self.lanInterface) ?? "" }
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    private func check() {
        guard let ip = Self.currentIPv4(on: fixedInterface ?? Self.lanInterface) else {
            // Remember the gap so getting the *same* IP back (sleep/wake,
            // Wi-Fi rejoin) still counts as a change — listeners bound to
            // the vanished address don't come back on their own.
            if let old = lastKnownIP, !old.isEmpty { onLost?() }
            lastKnownIP = ""   // also when there was never an IP, so its arrival counts
            return
        }
        if ip != lastKnownIP {
            let old = lastKnownIP
            lastKnownIP = ip
            if old != nil { onChange?(ip) }
        }
    }

    /// The app's defaults; the CLI reads the app's domain by suite name.
    static var settings: UserDefaults? {
        Bundle.main.bundleIdentifier == "com.roamrun.app" ? .standard : UserDefaults(suiteName: "com.roamrun.app")
    }

    /// The LAN interface Xcode's Bonjour sees and the relays listen on: the one
    /// chosen in Settings; else en0 whenever it has an address (every setup so far);
    /// else the first other Ethernet/Wi‑Fi port (en1, en2, …) that has one.
    static var lanInterface: String {
        pickLAN(chosen: settings?.string(forKey: "networkInterface"), available: Set(ipv4Addresses().keys))
    }

    nonisolated static func pickLAN(chosen: String?, available: Set<String>) -> String {
        if let chosen, !chosen.isEmpty { return chosen }
        if available.contains("en0") { return "en0" }
        return available.filter { $0.hasPrefix("en") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.first ?? "en0"
    }

    static func currentIPv4(on interfaceName: String = lanInterface) -> String? { ipv4Addresses()[interfaceName] }

    /// Interface name → its (last) non-loopback IPv4 address, via getifaddrs.
    static func ipv4Addresses() -> [String: String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [:] }
        defer { freeifaddrs(ifaddr) }
        var result: [String: String] = [:]
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let addr = ptr.pointee
            guard let sa = addr.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if !ip.hasPrefix("127.") { result[String(cString: addr.ifa_name)] = ip }
        }
        return result
    }
}
