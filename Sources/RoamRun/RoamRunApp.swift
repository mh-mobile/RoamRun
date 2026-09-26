import SwiftUI
import AppKit

/// The bundle identifier, also the defaults domain, log subsystem and notification prefix.
enum AppID {
    static let bundle = "io.github.mh-mobile.roamrun"
    /// Before 0.1.12. roamrun.com isn't ours, so the id moved to our GitHub namespace.
    static let legacy = "com.roamrun.app"

    /// The app's defaults, from the app or from the CLI (which may not run as the app bundle).
    static var settings: UserDefaults? {
        Bundle.main.bundleIdentifier == bundle ? .standard : UserDefaults(suiteName: bundle)
    }

    /// Settings saved under the old id carry over once, the first time either the app or the CLI runs.
    static func migrateDefaults() {
        let d = UserDefaults.standard
        guard var old = d.persistentDomain(forName: legacy),
              let moved = carriedOver(old: old, new: d.persistentDomain(forName: bundle)) else { return }
        d.setPersistentDomain(moved, forName: bundle)
        old[movedKey] = bundle   // once: settings deleted later mustn't come back from here
        d.setPersistentDomain(old, forName: legacy)
    }

    static let movedKey = "RoamRunMovedTo"

    /// What the new domain should become, or nil to leave it: only an empty one takes the old
    /// settings, and only if they haven't been carried over before.
    static func carriedOver(old: [String: Any]?, new: [String: Any]?) -> [String: Any]? {
        guard new?.isEmpty ?? true, let old, !old.isEmpty, old[movedKey] == nil else { return nil }
        return old
    }
}

/// One binary, two faces: `roamrun <command>` runs the CLI, anything else
/// (Finder, `open`, login item) starts the menu bar app.
@main
enum Entry {
    static func main() {
        AppID.migrateDefaults()
        // GUI apps start with 256 file descriptors; relays use two per connection.
        var limit = rlimit()
        if getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < 4096 {
            limit.rlim_cur = min(4096, limit.rlim_max)
            setrlimit(RLIMIT_NOFILE, &limit)
        }
        let args = Array(CommandLine.arguments.dropFirst())
        // Called as `roamrun` (the PATH link) it's always the command line, even
        // bare — the app's own launch runs …/MacOS/RoamRun. Any other argument
        // also means the command line; only ones macOS adds start the app.
        let invokedAsCLI = (CommandLine.arguments.first as NSString?)?.lastPathComponent == "roamrun"
        if invokedAsCLI || args.first.map({ first in !["-psn_", "-NS", "-Apple"].contains(where: first.hasPrefix) }) == true {
            CLI.run(args.isEmpty ? ["help"] : args)
        } else {
            // A RoamRun from before 0.1.12 (the old bundle id) would restore the same
            // bridges and ignore this version's stop requests: ask it to quit first.
            let old = NSRunningApplication.runningApplications(withBundleIdentifier: AppID.legacy)
            if !old.isEmpty, Snapshot.path == nil {
                old.forEach { $0.terminate() }
                for _ in 0..<100 where old.contains(where: { !$0.isTerminated }) {
                    RunLoop.current.run(until: .now + 0.1)   // isTerminated updates on the run loop
                }
            }
            // One app at a time: macOS only checks this for Finder/open launches,
            // not when the binary is run directly. A second copy would restore
            // the same bridges and show a second menu bar icon.
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .filter { $0.processIdentifier != getpid() }
            if let running = others.first, Snapshot.path == nil {
                // A menu bar app has no window to bring forward: ask it to open one.
                DistributedNotificationCenter.default().postNotificationName(
                    AppDelegate.showNotification, object: nil, userInfo: nil, deliverImmediately: true)
                running.activate()
                exit(0)
            }
            RoamRunApp.main()
        }
    }
}

extension Bundle {
    /// The marketing version, as in the release notes and `roamrun --version`.
    var versionText: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}

struct RoamRunApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(coordinator)
        } label: {
            MenuBarIcon(coordinator: coordinator)
        }
        .menuBarExtraStyle(.menu)

        Window("RoamRun", id: "main") {
            MainWindowView()
                .environmentObject(coordinator)
                .frame(minWidth: 680, minHeight: 500)
        }
        .defaultSize(width: 860, height: 620)
    }
}

/// Double-clicking the app while it's already running should show the window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var openMain: (() -> Void)?

    /// Posted by a second launch; the running app opens its window.
    static let showNotification = Notification.Name(AppID.bundle + ".showWindow")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Snapshot.scheduleIfRequested()
        DistributedNotificationCenter.default().addObserver(forName: Self.showNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppDelegate.openMain?() }
        }
        // AppKit rejects the system Quit event (Dock, Activity Monitor,
        // AppleScript) with "user canceled" while a sheet is open.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleQuitEvent(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }

    @objc private func handleQuitEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        MainActor.assumeIsolated { Self.quit() }   // Apple Events arrive on the main thread
    }

    /// Closes any open sheet first — otherwise AppKit won't let the app quit.
    @MainActor static func quit() {
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        NSApp.terminate(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.openMain?() }
        return true
    }
}

/// Dev builds only (`make app SNAPSHOT=1`); release builds contain none of this.
/// `MB_SNAPSHOT=/path/shot.png` renders the main window to a PNG and quits —
/// for UI checks without screen-recording rights.
/// `MB_SNAPSHOT_SHEET=add|settings` opens that sheet first; `MB_SNAPSHOT_EXPAND`
/// opens the detail sections. `MB_APPEARANCE=dark|light`; `MB_SNAPSHOT_DELAY` (s).
/// `MB_FAKE_PROFILES` / `MB_FAKE_DEVICES`: see below (also without MB_SNAPSHOT, to look live).
enum Snapshot {
    #if SNAPSHOT
    static let path = ProcessInfo.processInfo.environment["MB_SNAPSHOT"]
    static let sheet = ProcessInfo.processInfo.environment["MB_SNAPSHOT_SHEET"]
    static let expand = ProcessInfo.processInfo.environment["MB_SNAPSHOT_EXPAND"] != nil
    /// `MB_FAKE_PROFILES=n` / `MB_FAKE_DEVICES=n`: that many saved devices / devices on the
    /// network (the first and every fifth with a long name), to check the UI at scale. Never saved.
    static let fakeProfiles: [DeviceProfile]? = count("MB_FAKE_PROFILES").map { n in
        (0..<n).map { DeviceProfile(displayName: name($0), instanceName: "fake-\($0)", serviceType: "_remotepairing._tcp",
                                     domain: "local", remotePairingPort: 49152, bonjourHost: "", txt: [:], providerID: "tailscale",
                                     providerHostName: "", providerIP: "100.64.\($0 / 250).\($0 % 250 + 1)") }
    }
    static let fakeServices: [CapturedService]? = count("MB_FAKE_DEVICES").map { n in
        (0..<n).map { CapturedService(instanceName: "fake-\($0)", serviceType: "_remotepairing._tcp", domain: "local", port: 49152,
                                      host: name($0).replacingOccurrences(of: " ", with: "-") + ".local",
                                      hostIPs: ["192.168.\($0 / 250).\($0 % 250 + 1)"], txt: [:], lastSeen: .now) }
    }
    private static func count(_ key: String) -> Int? { ProcessInfo.processInfo.environment[key].flatMap(Int.init) }
    private static func name(_ i: Int) -> String {
        i % 5 == 0 ? "Engineering Team Shared iPhone 15 Pro Max for QA \(i)" : "Test iPhone \(i)"
    }
    #else
    static let path: String? = nil
    static let sheet: String? = nil
    static let expand = false
    static let fakeProfiles: [DeviceProfile]? = nil
    static let fakeServices: [CapturedService]? = nil
    #endif

    @MainActor static func scheduleIfRequested() {
        #if SNAPSHOT
        guard let path else { return }
        if let a = ProcessInfo.processInfo.environment["MB_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua)
        }
        let delay = Double(ProcessInfo.processInfo.environment["MB_SNAPSHOT_DELAY"] ?? "") ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // Main window first, then any sheet as <path>-sheet.png.
            let windows = NSApp.windows.filter { $0.isVisible && ($0.canBecomeMain || $0.isSheet) }
            for (i, w) in windows.enumerated() {
                guard let view = w.contentView?.superview,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let out = i == 0 ? path : path.replacingOccurrences(of: ".png", with: "-sheet.png")
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            }
            // terminate() stalls while a sheet is up; run the normal teardown
            // (stops dns-sd / log children) and exit directly.
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
            exit(0)
        }
        #endif
    }
}
