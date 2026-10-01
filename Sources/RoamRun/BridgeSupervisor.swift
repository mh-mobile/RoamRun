import Foundation

/// Why a bridge is started. What each may do is StartPolicy's to say, in one place.
enum StartReason: String, CaseIterable, Sendable {
    case manual          // Start in the app, `roamrun up`
    case rescan          // Find RemotePairing Port found it on another port
    case edit            // its saved endpoint changed, so the bridge was rebuilt
    case restore         // the app's launch, or a device the saved list had lost
    case retry           // the 30 s retry, or a `roamrun up` that held it ended
    case networkChange   // this Mac's LAN address changed
    case resume          // it left this Wi‑Fi while standing aside
}

/// What a start may do, by reason.
struct StartPolicy: Equatable {
    /// May take a device whose errored or standing-aside entry a live `roamrun up` holds.
    var mayTakeFromCLI: Bool
    /// Turns retries back on after an error retrying can't fix.
    var clearsRetryBlock: Bool
    /// Scans for the RemotePairing port within 10 minutes of a scan that found nothing.
    var clearsScanPause: Bool
    /// Stops a running bridge first: its relays are bound to the old address.
    var restarts: Bool

    static func of(_ reason: StartReason) -> StartPolicy {
        switch reason {
        case .manual, .rescan:
            StartPolicy(mayTakeFromCLI: true, clearsRetryBlock: true, clearsScanPause: false, restarts: false)
        case .networkChange:
            StartPolicy(mayTakeFromCLI: false, clearsRetryBlock: true, clearsScanPause: false, restarts: true)
        case .edit, .restore, .retry, .resume:
            StartPolicy(mayTakeFromCLI: false, clearsRetryBlock: true, clearsScanPause: false, restarts: false)
        }
    }
}

/// The recovery every bridge gets, in the app and in `roamrun up` alike: errors retried every
/// 30 s, a standing-aside device looked at every 10 s, a restart on a new LAN address, a pause
/// while there is none, a re-announcement on wake. How a bridge is started stays with the
/// owner: the app first checks whether a `roamrun up` holds the device.
@MainActor
final class BridgeSupervisor {
    /// Every bridge here.
    var all: () -> [ProxyBridge]
    /// Left on by the user: those errors are retried, and restarted on a new address.
    var wanted: (ProxyBridge) -> Bool
    /// Starts these for `reason` (restarting them if its policy says so).
    var start: ([ProxyBridge], StartReason) -> Void
    /// An errored bridge retrying can't fix. Nil: it is left as it is.
    var gaveUp: ((ProxyBridge) -> Void)?
    private var timers: [Timer] = []

    init(all: @escaping () -> [ProxyBridge], wanted: @escaping (ProxyBridge) -> Bool,
         start: @escaping ([ProxyBridge], StartReason) -> Void, gaveUp: ((ProxyBridge) -> Void)? = nil) {
        self.all = all
        self.wanted = wanted
        self.start = start
        self.gaveUp = gaveUp
    }

    func run() {
        timers = [
            Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.retry() }
            },
            Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.lookAgainIfAway() }
            },
        ]
    }

    /// Bridges the user left on retry quietly after errors (iPhone asleep, Tailscale paused,
    /// Wi‑Fi down) so nobody has to.
    func retry() {
        let errored = all().filter { wanted($0) && $0.status == .error }
        let retryable = errored.filter(\.autoRetry)
        if !retryable.isEmpty { start(retryable, .retry) }
        if let gaveUp { errored.filter { !$0.autoRetry }.forEach(gaveUp) }
    }

    /// Standing aside: resume soon after the device leaves this Wi‑Fi.
    func lookAgainIfAway() {
        for b in all() where b.state == .local { Task { await b.resumeIfAway() } }
    }

    /// Relays are bound to the old address. Errored ones too: they may have failed for want of one.
    func lanAddressChanged() {
        let restart = all().filter { $0.state.isActive || wanted($0) }
        if !restart.isEmpty { start(restart, .networkChange) }
    }

    /// Relays are bound to the LAN address; show the pause instead of a stale "active".
    func lanAddressLost() {
        for b in all() where b.state.isActive {
            b.stop()
            b.fail(ProxyBridge.noAddressMessage)
        }
    }

    /// After sleep, relayed connections can look open while dead: re-announce right away.
    func woke() { all().forEach { $0.nudgeAfterWake() } }
}
