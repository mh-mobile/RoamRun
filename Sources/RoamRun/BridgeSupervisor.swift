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

    /// Of two starts waiting for the same thing (a `roamrun up` to end), the one that does
    /// more: a rescan clears the scan pause and the wait; an edit or a new network the wait.
    /// A tie goes to the later.
    static func stronger(_ a: StartReason, _ b: StartReason) -> StartReason {
        func rank(_ r: StartReason) -> Int {
            switch r {
            case .manual: 4
            case .rescan: 3
            case .edit, .networkChange: 2
            case .restore, .retry, .resume: 1
            }
        }
        return rank(a) > rank(b) ? a : b
    }
}

/// Why retrying stopped: an error that starting again can't fix.
enum RetryBlock: String, CaseIterable, Sendable {
    case none
    case needsAdmin          // `log stream` needs an administrator account
    case pairingLost         // remotepairingd doesn't recognize the device
    case cliYieldedToOther   // a `roamrun up` refused: another process has the device
}

/// What a start may do, by reason.
struct StartPolicy: Equatable {
    /// May take a device whose errored or standing-aside entry a live `roamrun up` holds.
    var mayTakeFromCLI: Bool
    /// The retry blocks it lifts. A block it leaves in place stops the start.
    var clears: Set<RetryBlock>
    /// Scans for the RemotePairing port within 10 minutes of a scan that found nothing.
    var clearsScanPause: Bool
    /// Stops a running bridge first: its relays are bound to the old address.
    var restarts: Bool
    /// Back to the first, short wait between retries.
    var resetsBackoff: Bool

    static func of(_ reason: StartReason) -> StartPolicy {
        switch reason {
        case .manual:          // a person asked: everything goes
            StartPolicy(mayTakeFromCLI: true, clears: Set(RetryBlock.allCases), clearsScanPause: true,
                        restarts: false, resetsBackoff: true)
        case .rescan:          // asked for too, but it found a port: it neither fixes a pairing nor takes from a CLI
            StartPolicy(mayTakeFromCLI: false, clears: [], clearsScanPause: true, restarts: false, resetsBackoff: true)
        case .edit:
            StartPolicy(mayTakeFromCLI: false, clears: [], clearsScanPause: false, restarts: false, resetsBackoff: true)
        case .networkChange:
            StartPolicy(mayTakeFromCLI: false, clears: [], clearsScanPause: false, restarts: true, resetsBackoff: true)
        case .restore, .retry, .resume:
            StartPolicy(mayTakeFromCLI: false, clears: [], clearsScanPause: false, restarts: false, resetsBackoff: false)
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
    var now: () -> Date
    private var timers: [Timer] = []

    init(all: @escaping () -> [ProxyBridge], wanted: @escaping (ProxyBridge) -> Bool,
         start: @escaping ([ProxyBridge], StartReason) -> Void, gaveUp: ((ProxyBridge) -> Void)? = nil,
         now: @escaping () -> Date = { .now }) {
        self.all = all
        self.wanted = wanted
        self.start = start
        self.gaveUp = gaveUp
        self.now = now
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
    /// Wi‑Fi down) so nobody has to. Failing again and again, each waits longer (up to 10
    /// minutes); meanwhile a cheap look at its port each tick brings it back at once.
    func retry() {
        let errored = all().filter { wanted($0) && $0.status == .error }
        let retryable = errored.filter(\.autoRetry)
        // The wait counts from the tick that started the failed attempt; a second of slack for
        // the timer's own drift.
        let due = retryable.filter { $0.memory.retryDue(now: now() + 1) }
        if !due.isEmpty { start(due, .retry) }
        for b in retryable where !due.contains(where: { $0 === b }) && b.memory.lastFailureUnreachable {
            b.lookForItsPort { [weak self] answered in
                guard answered, let self else { return }
                b.memory.resetBackoff()
                self.start([b], .retry)
            }
        }
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
    /// What failed before the sleep says nothing about now: retries start short again.
    func woke() {
        for b in all() {
            b.memory.resetBackoff()
            b.nudgeAfterWake()
        }
    }
}

/// What RoamRun knows about one saved device, across its bridges: one rebuilt for an edited
/// endpoint or a port found again picks up where the old one left off. Its owner keeps one
/// per profile id; a bridge's own run (relays, timers, checks under way) starts afresh.
@MainActor
final class DeviceMemory {
    private(set) var udid: String?
    /// A Bonjour name known to be the device's own advert, for the cheap stand-aside probe.
    var homeAdvert: String?
    /// Standing aside, the last time the home check confirmed the UDID the slow way.
    var lastFullCheck = Date.distantPast
    /// An error retrying can't fix, until a start whose reason lifts it.
    var block = RetryBlock.none { didSet { if block == .none { blockMessage = nil } } }
    var autoRetry: Bool { block == .none }
    /// What the error said when the block was set, shown again by a start it turns away.
    var blockMessage: String?
    /// Starts that ended in an error in a row, and when the next retry is due.
    private(set) var failures = 0
    private(set) var retryAt = Date.distantPast
    /// The last failure was the device not answering (not something on this Mac): only then
    /// does a port that answers again mean a retry may work.
    private(set) var lastFailureUnreachable = false
    /// A scan that found nothing: no other on that endpoint ("ip:port") until then.
    private var scanPause: (endpoint: String, until: Date)?

    init(udid: String? = nil) { self.udid = udid }

    /// The device this memory is about. Another known device than the one remembered:
    /// nothing here holds for it. A UDID learned for the first time is the same device.
    func adopt(_ udid: String?) {
        guard let udid else { return }
        if let known = self.udid, known.caseInsensitiveCompare(udid) != .orderedSame {
            homeAdvert = nil
            lastFullCheck = .distantPast
            block = .none
            scanPause = nil
            resetBackoff()
        }
        self.udid = udid
    }

    /// 30 s, 1, 2, 4, 8 minutes, then every 10.
    static func backoff(afterFailures n: Int) -> TimeInterval { min(30 * pow(2, Double(max(n, 1) - 1)), 600) }
    /// `since`: when the attempt that failed began, so the wait runs from the tick that
    /// started it rather than slipping by however long the attempt took.
    func failed(at now: Date, since: Date? = nil, unreachable: Bool) {
        lastFailureUnreachable = unreachable
        failures += 1
        retryAt = (since ?? now) + Self.backoff(afterFailures: failures)
    }
    func resetBackoff() {
        failures = 0
        retryAt = .distantPast
    }
    func retryDue(now: Date) -> Bool { now >= retryAt }

    func pauseScans(of endpoint: String, until: Date) { scanPause = (endpoint, until) }
    /// Last seen on cellular (tunnel only, or paused), not yet back on Wi‑Fi: a scan there finds
    /// nothing and costs data, so starts don't scan until it is back or a person asks.
    var onCellular = false

    func clearScanPause() { scanPause = nil; onCellular = false }
    func scansPaused(of endpoint: String, now: Date) -> Bool {
        guard let scanPause, scanPause.endpoint == endpoint else { return false }
        return now <= scanPause.until
    }
}
