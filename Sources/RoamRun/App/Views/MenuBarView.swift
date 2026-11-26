import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        if coordinator.profiles.isEmpty {
            Text("No devices added yet")
            Button("Add Device…") {
                openMain()
            }
        }
        ForEach(coordinator.profiles) { profile in
            if let bridge = coordinator.bridges[profile.id] {
                BridgeMenuItem(bridge: bridge, profile: profile)
            }
        }
        if coordinator.profiles.count > 1 {
            Button("Reconnect Active Bridges") {
                coordinator.reconnectActiveBridges()
            }
            .disabled(coordinator.runningProfiles.isEmpty)
            Button("Stop All Bridges") {
                coordinator.stopAllBridges()
            }
            .disabled(coordinator.runningProfiles.isEmpty && coordinator.externalBridges.isEmpty)
        }
        Divider()
        Text("RoamRun \(Bundle.main.versionText)")
        if let newer = updates.available {
            Button {
                NSWorkspace.shared.open(UpdateCheck.page(newer))
            } label: {
                Text("RoamRun \(newer) Is Available…")
                Text("You have \(updates.current); opens its release page")
            }
        } else {
            Button("Check for Updates…") {
                updates.checkNow()
                openWindow(id: "updates")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        Button("Open RoamRun") {
            openMain()
        }
        .keyboardShortcut("o")
        Button("Quit RoamRun") {
            AppDelegate.quit()
        }
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
                +
                Text(
                    " \(coordinator.statusText(of: profile.id))\(coordinator.runElsewhere(profile.id).map { " (\($0))" } ?? "")"
                )
        }
        if viaCLI {
            Button("Stop Bridge") {
                coordinator.stopExternalBridge(profile.id)
            }
        } else if bridge.state == .off {
            Button("Start Bridge") {
                coordinator.startBridge(profile)
            }
        } else {
            Button("Stop Bridge") {
                coordinator.stopBridge(profile)
            }
        }
        Divider()
    }
}

/// What a check the user asked for came to. A window, not an alert: a modal alert would hold up
/// the bridges' timers while it is open.
struct UpdateWindowView: View {
    @ObservedObject private var updates = UpdateChecker.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch updates.lastAnswer {
            case nil where updates.checking:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Asking GitHub for the newest release…")
                }
            case nil: // reopened with the app, before any check
                Text(
                    "RoamRun asks GitHub for its newest release only when you check, or once a day if Settings says so."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            case .success(.upToDate):
                Text("RoamRun is up to date").font(.headline)
                Text("You have \(updates.current); no newer release is out.").foregroundStyle(.secondary)
            case .success(.newer(let version)):
                Text("RoamRun \(version) is available").font(.headline)
                Text("You have \(updates.current). Its release page tells how to update; RoamRun downloads nothing.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .failure(let failure):
                Text("Couldn't check for updates").font(.headline)
                Text(failure.reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if updates.lastAnswer == nil && !updates.checking {
                    Button("Check Now") {
                        updates.checkNow()
                    }
                }
                if case .failure = updates.lastAnswer {
                    Button("Try Again") {
                        updates.checkNow()
                    }
                }
                if case .success(.newer(let version)) = updates.lastAnswer {
                    Button("Later") {
                        dismiss()
                    }
                    Button("Open Release Page") {
                        NSWorkspace.shared.open(UpdateCheck.page(version))
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("OK") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(updates.checking)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
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
            AppDelegate.launchWarning = coordinator.launchWarning != nil
            AppDelegate.openWindowIfLaunchWants()
        }
    }

    private var icon: some View {
        Group {
            switch coordinator.overallStatus {
            case .ready: Image(systemName: "iphone.radiowaves.left.and.right")
            case .error: Image(systemName: "exclamationmark.triangle")
            case .off: Image(systemName: "iphone.slash")
            default: Image(systemName: "iphone")
            }
        }
        .accessibilityLabel("RoamRun: \(coordinator.overallStatus.title)")
    }
}
