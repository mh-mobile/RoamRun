import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if coordinator.profiles.isEmpty {
            Text("No devices added yet")
            Button("Add Device…") { openMain() }
        }
        ForEach(coordinator.profiles) { profile in
            if let bridge = coordinator.bridges[profile.id] {
                BridgeMenuItem(bridge: bridge, profile: profile)
            }
        }
        if coordinator.profiles.count > 1 {
            Button("Reconnect Active Bridges") { coordinator.reconnectActiveBridges() }
                .disabled(coordinator.runningProfiles.isEmpty)
            Button("Stop All Bridges") { coordinator.stopAllBridges() }
                .disabled(coordinator.runningProfiles.isEmpty && coordinator.externalBridges.isEmpty)
        }
        Divider()
        Text("RoamRun \(Bundle.main.versionText)")
        Button("Open RoamRun") { openMain() }
            .keyboardShortcut("o")
        Button("Quit RoamRun") { AppDelegate.quit() }
            .keyboardShortcut("q")
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct BridgeMenuItem: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var bridge: ProxyBridge
    let profile: DeviceProfile

    var body: some View {
        let status = coordinator.status(of: profile.id)
        let viaCLI = coordinator.externalBridges[profile.id] != nil
        // Menus only render plain text; the status rides along in the title.
        // A button row reads as live (a plain text row is greyed like a header).
        Button {
            coordinator.selectedID = profile.id
            AppDelegate.openMain?()
        } label: {
            // A colored symbol glyph sits on the text baseline like the device icon.
            Text("\(Image(systemName: profile.symbol)) \(profile.displayName) — ")
                + Text(Image(systemName: status.symbol)).foregroundColor(status.color)
                + Text(" \(status.title)\(viaCLI ? " (Terminal)" : "")")
        }
        if viaCLI {
            Button("Stop Bridge") { coordinator.stopExternalBridge(profile.id) }
        } else if bridge.state == .off {
            Button("Start Bridge") { coordinator.startBridge(profile) }
        } else {
            Button("Stop Bridge") { coordinator.stopBridge(profile) }
        }
        Divider()
    }
}

/// Menu bar icon: one glance tells whether Xcode can reach the iPhone.
struct MenuBarIcon: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        icon.onAppear {
            AppDelegate.openMain = {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            // A launch that restores running bridges is a login/background
            // launch — stay in the menu bar. Otherwise the user opened the
            // app on purpose (or it's the first run): show the window.
            if !coordinator.isRestoringBridges || Snapshot.path != nil { AppDelegate.openMain?() }
        }
    }

    @ViewBuilder private var icon: some View {
        switch coordinator.overallStatus {
        case .ready: Image(systemName: "iphone.radiowaves.left.and.right")
        case .error: Image(systemName: "exclamationmark.triangle")
        case .off: Image(systemName: "iphone.slash")
        default: Image(systemName: "iphone")
        }
    }
}
