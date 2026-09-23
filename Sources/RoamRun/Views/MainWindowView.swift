import SwiftUI
import AppKit

struct MainWindowView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var selection: DeviceProfile.ID?
    @State private var showAddDevice = false
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(coordinator.profiles) { profile in
                    SidebarRow(profile: profile)
                        .tag(profile.id)
                        .contextMenu {
                            Button("Delete Device", role: .destructive) {
                                coordinator.deleteProfile(profile.id)
                            }
                        }
                }
                .onDelete { indexSet in
                    indexSet
                        .map { coordinator.profiles[$0].id }
                        .forEach { coordinator.deleteProfile($0) }
                }
            }
            // Wide enough for "Ready for Xcode" and for the toolbar buttons,
            // which otherwise spill into an overflow (») menu.
            .navigationSplitViewColumnWidth(min: 230, ideal: 250)
            .toolbar {
                ToolbarItem {
                    Button { showAddDevice = true } label: {
                        Label("Add iPhone", systemImage: "plus")
                    }
                    .help("Add iPhone")
                }
            }
        } detail: {
            if let id = selection, let profile = coordinator.profile(id),
               let bridge = coordinator.bridges[id] {
                DeviceDetailView(profile: profile, bridge: bridge)
            } else if coordinator.profiles.isEmpty {
                WelcomeView { showAddDevice = true }
            } else {
                Text("Select an iPhone")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $showAddDevice) {
            AddDeviceView { newID in selection = newID }
                .environmentObject(coordinator)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(coordinator)
        }
        .onAppear {
            if selection == nil { selection = coordinator.profiles.first?.id }
            switch ProcessInfo.processInfo.environment["MB_SNAPSHOT_SHEET"] {
            case "add": showAddDevice = true
            case "settings": showSettings = true
            default: break
            }
            // A menu-bar app has no Dock icon, so its window gets lost behind
            // Xcode. Behave like a regular app while the window is open.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

private struct SidebarRow: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let profile: DeviceProfile

    var body: some View {
        let status = coordinator.status(of: profile.id)
        let viaCLI = coordinator.externalBridges[profile.id] != nil
        HStack(spacing: 10) {
            Image(systemName: "iphone")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName).fontWeight(.medium)
                Label(viaCLI ? "\(status.title) · Terminal" : status.title, systemImage: status.symbol)
                    .labelStyle(StatusLabelStyle(color: status.color))
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Colored icon, secondary text — reads well in sidebars and menus.
struct StatusLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(color)
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

extension BridgeStatus {
    var color: Color {
        switch self {
        case .off: return .secondary
        case .starting, .preparing: return .orange
        case .waiting: return .yellow
        case .ready: return .green
        case .error: return .red
        }
    }
}

private struct WelcomeView: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 6) {
                Text("Debug your iPhone from anywhere")
                    .font(.title2.weight(.semibold))
                Text("Xcode's wireless debugging only works on the same Wi‑Fi.\nRoamRun carries it over Tailscale, so the iPhone can be on any network.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Step(n: 1, text: "Pair the iPhone with Xcode once (USB), with “Connect via network” on.")
                Step(n: 2, text: "Install Tailscale on this Mac and the iPhone, signed in to the same tailnet.")
                Step(n: 3, text: "Add the iPhone here while it's on this Mac's Wi‑Fi.")
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
            Button("Add iPhone…", action: onAdd)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct Step: View {
        let n: Int
        let text: String
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(n)")
                    .font(.caption.weight(.bold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.accentColor.opacity(0.2)))
                Text(text)
            }
        }
    }
}
