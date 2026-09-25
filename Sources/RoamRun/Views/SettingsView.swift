import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var cliPath = ""
    @State private var cliState = CLIInstaller.state
    @State private var cliError: String?

    @AppStorage("networkInterface") private var networkInterface = ""
    private let interfaces = InterfaceMonitor.ipv4Addresses()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.title2)

            GroupBox("Tailscale CLI") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Auto-detect", text: $cliPath)
                        .textFieldStyle(.roundedBorder)
                    Text("Leave empty to find it automatically (Tailscale.app, Homebrew, /usr/local/bin). Set a path only if you installed the CLI elsewhere.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Network") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Interface", selection: $networkInterface) {
                        Text("Automatic (\(InterfaceMonitor.pickLAN(chosen: nil, available: Set(interfaces.keys))))").tag("")
                        // Also a chosen one that's gone now (e.g. an unplugged adapter), so the choice stays visible.
                        ForEach(Set(interfaces.keys.filter { $0.hasPrefix("en") } + (networkInterface.isEmpty ? [] : [networkInterface])).sorted(), id: \.self) { name in
                            Text("\(name) — \(interfaces[name] ?? "not connected")").tag(name)
                        }
                    }
                    .onChange(of: networkInterface) { _ in coordinator.lanInterfaceChanged() }
                    Text("Where the bridge listens: the network Xcode looks for devices on. Automatic uses en0 (Wi‑Fi on most Macs) when it's connected.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("General") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Open at login", isOn: $coordinator.launchAtLogin)
                    if let problem = coordinator.loginItemProblem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                    Text("Keeps bridges you left on running in the menu bar after a restart.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Command line tool") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(cliStatusText).foregroundStyle(.secondary)
                        Spacer()
                        Button(cliState == .notInstalled ? "Install…" : "Reinstall") {
                            do { try CLIInstaller.install(); cliError = nil }
                            catch { cliError = error.localizedDescription }
                            cliState = CLIInstaller.state
                        }
                        .disabled(cliState == .installed || cliState == .blockedByFile)
                    }
                    if let cliError {
                        Text(cliError).font(.caption).foregroundStyle(.red)
                    }
                    Text("Run bridges from Terminal or over SSH: `roamrun up <name>`, `roamrun status`, `roamrun devices`.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Troubleshooting") {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Clean Up Leftover Helpers") { coordinator.cleanUpLeftoverHelpers() }
                    Text("Stops dns-sd / log processes left behind by a crash.")
                        .font(.caption).foregroundStyle(.secondary)
                    RecentMessages(log: coordinator.logStore)
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Done") {
                    coordinator.tailscaleCLIPath = cliPath
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { cliPath = coordinator.tailscaleCLIPath }
        .onDisappear { coordinator.tailscaleCLIPath = cliPath }   // Esc closes too
    }

    private var cliStatusText: String {
        switch cliState {
        case .notInstalled: return "Not installed"
        case .installed: return "Installed at \(CLIInstaller.installedPath ?? CLIInstaller.linkPath)"
        case .pointsElsewhere: return "Linked to another copy of RoamRun"
        case .blockedByFile: return "\(CLIInstaller.linkPath) is taken by another file"
        }
    }
}

/// App-wide messages (not about one device): launch problems, cleanup, Tailscale.
/// Observes the log itself so a result logged later (e.g. Clean Up) shows up.
private struct RecentMessages: View {
    @ObservedObject var log: LogStore

    var body: some View {
        let recent = log.lines.filter { $0.device == nil }.suffix(8).map(\.text)
        if !recent.isEmpty {
            Text("Recent messages").font(.caption.weight(.semibold)).padding(.top, 4)
            Text(recent.joined(separator: "\n"))
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
