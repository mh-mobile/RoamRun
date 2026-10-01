import Foundation
import Network

/// What a bridge reaches outside itself: the network, helper processes, settings and
/// the clock. The defaults are the real ones; tests swap them so a bridge touches
/// nothing on the Mac. Blocking tools stay synchronous here: callers keep running
/// them off the main actor, as before.
struct BridgeEnv: Sendable {
    var now: @Sendable () -> Date = { .now }
    /// Uptime (ns) for the relays' last-byte times.
    var relayClock: @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    var lanIPv4: @Sendable () -> String? = { InterfaceMonitor.currentIPv4() }
    var keepOnCellular: @Sendable () -> Bool = { DeviceNetwork.keepOnCellular }
    var cliRunning: @Sendable () -> Bool = { CLI.isRunning }

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
    var isOnLAN: @Sendable (DeviceProfile) async -> Bool = { await ProxyBridge.isOnLAN($0) }
    /// `devicectl device info details`, which makes CoreDevice ask for a tunnel.
    var warmUp: @Sendable (_ udid: String) async -> Proc.Result = {
        await Proc.runAsync("/usr/bin/xcrun", ["devicectl", "--quiet", "--timeout", "30",
                                               "device", "info", "details", "--device", $0])
    }

    // Blocking.
    var ping: @Sendable (_ ip: String) -> Bool = { TailscaleClient.fromSettings().ping($0) }
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

    static let live = BridgeEnv()
}

/// The fake `_remotepairing._tcp` record a bridge publishes (DNSServiceProxy; tests fake it).
@MainActor
protocol BonjourRecord: AnyObject {
    /// It ended on its own (not by stop()/renew()); -1: a renew couldn't replace it.
    var onExit: ((Int32) -> Void)? { get set }
    func register(instanceName: String, serviceType: String, domain: String,
                  port: UInt16, host: String, ip: String, txt: [String: String]) throws
    func stop()
    func renew()
    /// The record stop() ended is gone; false when that couldn't be confirmed.
    func previousExited() async -> Bool
}
