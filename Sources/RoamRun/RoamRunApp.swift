import SwiftUI
import AppKit

/// One binary, two faces: `roamrun <command>` runs the CLI, anything else
/// (Finder, `open`, login item) starts the menu bar app.
@main
enum Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        // Called as `roamrun` (the PATH link) it's always the command line, even
        // bare — the app's own launch runs …/MacOS/RoamRun. Any other argument
        // also means the command line; only ones macOS adds start the app.
        let invokedAsCLI = (CommandLine.arguments.first as NSString?)?.lastPathComponent == "roamrun"
        if invokedAsCLI || args.first.map({ first in !["-psn_", "-NS", "-Apple"].contains(where: first.hasPrefix) }) == true {
            CLI.run(args.isEmpty ? ["help"] : args)
        } else {
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
    static var openMain: (() -> Void)?

    /// Posted by a second launch; the running app opens its window.
    static let showNotification = Notification.Name("com.roamrun.app.showWindow")

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
        Self.quit()
    }

    /// Closes any open sheet first — otherwise AppKit won't let the app quit.
    static func quit() {
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
enum Snapshot {
    #if SNAPSHOT
    static let path = ProcessInfo.processInfo.environment["MB_SNAPSHOT"]
    static let sheet = ProcessInfo.processInfo.environment["MB_SNAPSHOT_SHEET"]
    static let expand = ProcessInfo.processInfo.environment["MB_SNAPSHOT_EXPAND"] != nil
    #else
    static let path: String? = nil
    static let sheet: String? = nil
    static let expand = false
    #endif

    static func scheduleIfRequested() {
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
