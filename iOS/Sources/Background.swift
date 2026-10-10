#if canImport(UIKit) && canImport(BackgroundTasks)
import BackgroundTasks
import UIKit
import os

private let log = Logger(subsystem: "io.github.mh-mobile.roamrun.introducer", category: "background")

/// Keeps the app running while the person is in Settings: a grace window from beginBackgroundTask, and
/// a continued-processing task attached when iOS launches it.
@MainActor
final class BackgroundKeeper {
    /// iOS refused the continued task: about 30 seconds in the background, no more.
    private(set) var limited = false
    var onExpire: (() -> Void)?
    /// Said once iOS refused the continued task (after `begin` returns: the submit is asynchronous).
    var onLimited: (() -> Void)?

    private var grace: UIBackgroundTaskIdentifier = .invalid
    private var task: BGContinuedProcessingTask?
    private var ticker: Timer?
    private var started = Date()
    private var total: TimeInterval = 300
    private var title = "", subtitle = ""
    private var active = false
    private var registered: Bool?

    /// From the Info.plist wildcard, so a re-signed build whose plist follows its bundle id still matches.
    static let identifier: String = {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        if let wildcard = permitted.first(where: { $0.hasSuffix(".introduce.*") }) { return String(wildcard.dropLast()) + "session" }
        return (Bundle.main.bundleIdentifier ?? "io.github.mh-mobile.roamrun.introducer") + ".introduce.session"
    }()

    /// Call in the foreground, on the Introduce tap. `total`: how long this part may take at most.
    func begin(title: String, subtitle: String, total: TimeInterval) {
        active = true
        limited = false
        phase(title: title, subtitle: subtitle, total: total)
        grace = UIApplication.shared.beginBackgroundTask(withName: "RoamRun introduce") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // With the continued task attached, the grace window only ends; that task carries on.
                guard self.task == nil, self.active else { self.endGrace(); return }
                self.expire {}
            }
        }
        if registered == nil {
            registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { [weak self] task in
                MainActor.assumeIsolated { self?.attach(task as? BGContinuedProcessingTask) }
            }
            if registered == false { log.error("register refused for \(Self.identifier, privacy: .public)") }
        }
        guard registered == true else { limited = true; return }
        let request = BGContinuedProcessingTaskRequest(identifier: Self.identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        Task { @MainActor in
            do { try await BGTaskScheduler.shared.submitTaskRequest(request) } catch {
                log.error("submit refused: \(error.localizedDescription, privacy: .public)")
                guard active, task == nil else { return }
                limited = true
                onLimited?()
            }
        }
    }

    /// The next part of the same introduction: what iOS shows of it, and its progress from nothing.
    func phase(title: String, subtitle: String, total: TimeInterval) {
        self.title = title
        self.subtitle = subtitle
        self.total = max(total, 2)
        started = Date()
        tick()
    }

    /// Shown where iOS shows the task, which stays in sight over Settings.
    func show(_ title: String) {
        self.title = title
        tick()
    }

    private func attach(_ task: BGContinuedProcessingTask?) {
        guard let task else { return }
        // One at a time, and none for an introduction that is over.
        guard active, self.task == nil else { task.setTaskCompleted(success: false); return }
        self.task = task
        task.expirationHandler = { [weak self] in
            // Whatever queue iOS calls this on.
            DispatchQueue.main.async {
                // Not this one any more: whoever took it away completed it.
                guard let self, self.task === task else { return }
                self.task = nil
                self.expire { task.setTaskCompleted(success: false) }
            }
        }
        tick()
        // Progress that moves is what keeps the scheduler from taking the task for stalled.
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }

    /// Says it is over, and gives what that starts (the record withdrawn, the far Mac told) a moment before letting go.
    private func expire(_ release: @escaping @MainActor () -> Void) {
        // This introduction's window, taken now: a moment later another may have begun and opened its own.
        let ending = grace
        grace = .invalid
        onExpire?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            release()
            if ending != .invalid { UIApplication.shared.endBackgroundTask(ending) }
        }
    }

    private func tick() {
        guard let task else { return }
        let elapsed = min(Date().timeIntervalSince(started), total - 1)
        task.progress.totalUnitCount = Int64(total)
        task.progress.completedUnitCount = Int64(elapsed)
        task.updateTitle(title, subtitle: subtitle)
    }

    /// On the introduction's end: completes the task exactly once, takes back a request iOS hasn't
    /// launched yet, and ends the grace window.
    func finish() {
        active = false
        ticker?.invalidate()
        ticker = nil
        if let task {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: true)
            self.task = nil
        }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        endGrace()
    }

    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }
}
#endif
