import Foundation
import Network

/// Tracks the Mac's IPv4 address on the LAN interface (en0 by default) and
/// notifies when it changes, so active bridges can re-bind their relays and
/// re-publish the proxy registration with the new address.
final class InterfaceMonitor {
    var onChange: ((String) -> Void)?

    private let interfaceName: String
    private var monitor: NWPathMonitor?
    /// Path updates and the initial check run here, never concurrently.
    private let queue = DispatchQueue(label: "com.roamrun.app.interface-monitor")
    private(set) var lastKnownIP: String?

    init(interfaceName: String = "en0") {
        self.interfaceName = interfaceName
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

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    private func check() {
        guard let ip = Self.currentIPv4(on: interfaceName) else {
            // Remember the gap so getting the *same* IP back (sleep/wake,
            // Wi-Fi rejoin) still counts as a change — listeners bound to
            // the vanished address don't come back on their own.
            lastKnownIP = ""   // also when there was never an IP, so its arrival counts
            return
        }
        if ip != lastKnownIP {
            let old = lastKnownIP
            lastKnownIP = ip
            if old != nil { onChange?(ip) }
        }
    }

    /// First non-loopback IPv4 address on the given interface via getifaddrs.
    static func currentIPv4(on interfaceName: String = "en0") -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var result: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let addr = ptr.pointee
            guard let sa = addr.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: addr.ifa_name)
            guard name == interfaceName else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if !ip.hasPrefix("127.") { result = ip }
        }
        return result
    }
}
