import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var cliPath = ""
    @State private var cliState = CLIInstaller.state
    @State private var cliError: String?

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

            GroupBox("General") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Open at login", isOn: $coordinator.launchAtLogin)
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
                    Button("Clean Up Leftover Helpers") {
                        DNSServiceProxy.killOrphanedHelpers { m in coordinator.logStore.log(m) }
                    }
                    Text("Stops dns-sd / log processes left behind by a crash.")
                        .font(.caption).foregroundStyle(.secondary)
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
