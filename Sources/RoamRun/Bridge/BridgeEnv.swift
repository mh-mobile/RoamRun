import Foundation
import Network

/// What a bridge reaches outside itself: the network, helper processes, settings and
/// the clock. The defaults are the real ones; tests swap them so a bridge touches
/// nothing on the Mac. Blocking tools stay synchronous here: callers keep running
/// them off the main actor, as before.
struct BridgeEnv: Sendable {
    var now: @Sendable () -> Date = { .now }
    /// The relays' clock for last-byte times (ns), running on through sleep (Relay.continuousNow).
    var relayClock: @Sendable () -> UInt64 = { Relay.continuousNow() }
    var lanIPv4: @Sendable () -> String? = { InterfaceMonitor.currentIPv4() }
    var keepOnCellular: @Sendable () -> Bool = { DeviceNetwork.keepOnCellular }
    var cliRunning: @Sendable () -> Bool = { CLI.isRunning }
    /// macOS refused a probe to this Wi‑Fi lately (process-wide).
    var localNetworkDenied: @Sendable () -> Bool = { LocalNetwork.denied }

    var checkTCP: @Sendable (_ host: String, _ port: UInt16) async -> Bool = {
        await ReachabilityProbe.checkTCP(host: $0, port: $1)
    }
    var findRemotePairingPort: @Sendable (_ host: String) async -> ReachabilityProbe.PortScan = {
        await ReachabilityProbe.findRemotePairingPort(host: $0)
    }
    /// A Bonjour instance that answers the RemotePairing handshake.
    var answers: @Sendable (_ endpoint: NWEndpoint) async -> Bool = {
        await ReachabilityProbe.speaksRemotePairing($0, timeout: 2)
    }
    var isOnLAN: @MainActor (DeviceProfile) async -> Bool = { await ProxyBridge.isOnLAN($0) }
    /// `devicectl device info details`, which makes CoreDevice ask for a tunnel.
    var warmUp: @Sendable (_ udid: String) async -> Proc.Result = { udid in
        await Blocking.run {
            Proc.run("/usr/bin/xcrun", ["devicectl", "--quiet", "--timeout", "30",
                                        "device", "info", "details", "--device", udid])
        }
    }

    // Blocking.
    var ping: @Sendable (_ ip: String) -> TailscaleClient.Ping = { TailscaleClient.fromSettings().pingResult($0) }
    var listDevices: @Sendable () throws -> [MeshDevice] = { try TailscaleClient.fromSettings().listDevices() }
    /// The device's own advert remotepairingd resolved in the last 90 s, not `besides`.
    var recentAdvert: @Sendable (_ udid: String, _ besides: String) -> String? = {
        ProxyBridge.recentAdvert(udid: $0, besides: $1)
    }
    var killOrphanedHelpers: @Sendable () -> Int = { DNSServiceProxy.killOrphanedHelpers() }

    var subscribe: @MainActor (UUID, TunnelCoordinator.Subscriber) -> Bool = {
        TunnelCoordinator.shared.subscribe($0, $1)
    }
    var unsubscribe: @MainActor (UUID) -> Void = { TunnelCoordinator.shared.unsubscribe($0) }
    var makeRecord: @MainActor () -> any BonjourRecord = { DNSServiceProxy() }
    /// Tunnel-port claims between RoamRun processes (system-wide notifications).
    var postClaim: @MainActor (String) -> Void = { ProxyBridge.postClaim($0) }
    var listenForClaims: @MainActor () -> Void = { ProxyBridge.listenForClaims() }

    static let live = BridgeEnv()
}

/// Where a bridge's blocking tools run: a thread of their own each, never the main actor or
/// Swift's cooperative pool. That pool has a thread per core; a tool waiting there (a ping
/// up to 8 s, devicectl up to 45 s) held one, and with several bridges checking at once
/// their tools queued behind each other (#32). Not a GCD queue either: blocked work there
/// counts toward GCD's 64 threads, which the relays' connections and the probes'
/// timeouts also run on. A thread costs little next to the process it waits for.
enum Blocking {
    /// At most this many at once; more wait their turn without holding a thread. Tools aren't
    /// cancelled, so a stopped bridge's still run out their timeouts beside the new ones'.
    static let limit = 48
    private static let gate = Gate(limit)

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await gate.enter()
        return await withCheckedContinuation { done in
            // A thread of our own has no autorelease pool: what Foundation autoreleases in the
            // tool (Process, pipes, strings) would leak, every check, for as long as RoamRun runs.
            Thread.detachNewThread {
                let result = autoreleasepool { work() }
                gate.leave()
                done.resume(returning: result)
            }
        }
    }

    /// Counts permits; a task without one waits, first come first served.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var free: Int
        private var waiting: [CheckedContinuation<Void, Never>] = []

        init(_ permits: Int) { free = permits }

        func enter() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let now: Bool = lock.withLock {
                    guard free > 0 else { waiting.append(c); return false }
                    free -= 1
                    return true
                }
                if now { c.resume() }
            }
        }

        /// The permit goes straight to the longest waiter, if any.
        func leave() {
            let next: CheckedContinuation<Void, Never>? = lock.withLock {
                if waiting.isEmpty { free += 1; return nil }
                return waiting.removeFirst()
            }
            next?.resume()
        }
    }
}

/// The fake `_remotepairing._tcp` record a bridge publishes (DNSServiceProxy; tests fake it).
@MainActor
protocol BonjourRecord: AnyObject {
    /// It ended on its own (not by stop()/renew()); -1: a renew couldn't replace it.
    var onExit: ((Int32) -> Void)? { get set }
    func register(instanceName: String, serviceType: String, domain: String,
                  port: UInt16, host: String, ip: String, txt: [String: String]) throws
    /// On the one interface that has `ip`, or not at all (throws): for a record that isn't a bridge's.
    func registerOnItsInterface(instanceName: String, serviceType: String, domain: String,
                                port: UInt16, host: String, ip: String, txt: [String: String]) throws
    func stop()
    func renew()
    /// The record stop() ended is gone; false when that couldn't be confirmed.
    func previousExited() async -> Bool
}
