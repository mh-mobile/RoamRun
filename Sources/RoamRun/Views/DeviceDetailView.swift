import SwiftUI
import AppKit

struct DeviceDetailView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let profile: DeviceProfile
    @ObservedObject var bridge: ProxyBridge
    @State private var scanning = false
    @State private var confirmDelete = false
    @State private var showDetails = Snapshot.expand
    @State private var renaming = false
    @State private var newName = ""
    @State private var showLog = Snapshot.expand

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                StatusCard(profile: profile, bridge: bridge, external: external)
                ConnectionPath(profile: profile, status: status)

                VStack(alignment: .leading, spacing: 0) {
                    DisclosureGroup("Technical details", isExpanded: $showDetails) {
                        technicalDetails.padding(.top, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider().padding(.vertical, 10)
                    DisclosureGroup("Activity log", isExpanded: $showLog) {
                        DeviceLog(filter: profile.displayName).padding(.top, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack {
                    Spacer()
                    Button("Remove iPhone…", role: .destructive) { confirmDelete = true }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            // Full-width scroll content: macOS 26's scroll-edge effect under
            // the toolbar follows the content width, so a narrow column left
            // a half-width band at the top.
            .frame(maxWidth: .infinity)
        }
        .alert("Rename iPhone", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { coordinator.rename(profile.id, to: newName) }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                          || coordinator.isNameTaken(newName, except: profile.id))
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Used in the menu and the CLI (roamrun up <name>). Must be unique.")
        }
        .alert("Remove “\(profile.displayName)”?", isPresented: $confirmDelete) {
            Button("Remove", role: .destructive) { coordinator.deleteProfile(profile.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The bridge stops and the saved pairing details are deleted. You can add the iPhone again later.")
        }
    }

    private var external: StatusFile.Entry? { coordinator.externalBridges[profile.id] }
    private var status: BridgeStatus { coordinator.status(of: profile.id) }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "iphone")
                .font(.system(size: 28))
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.displayName).font(.title2.weight(.semibold))
                    Button {
                        newName = profile.displayName
                        renaming = true
                    } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Rename")
                }
                Text(peerDescription).foregroundStyle(.secondary)
            }
            Spacer()
            if external != nil {
                Button("Stop Bridge") { coordinator.stopExternalBridge(profile.id) }
                    .controlSize(.large)
            } else if bridge.state == .off || bridge.status == .error {
                Button("Start Bridge") { coordinator.startBridge(profile) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button("Stop Bridge") { coordinator.stopBridge(profile) }
                    .controlSize(.large)
            }
        }
    }

    private var peerDescription: String {
        let provider = MeshProvider(rawValue: profile.providerID)?.displayName ?? profile.providerID
        let host = profile.providerHostName
        return host.isEmpty || host == profile.providerIP
            ? "\(provider) · \(profile.providerIP)"
            : "\(provider) · \(host) · \(profile.providerIP)"
    }

    private var technicalDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("UDID", bridge.udid ?? profile.udid ?? "Learned on first connection")
                row("Bonjour instance", profile.instanceName)
                row("Bonjour host", profile.bonjourHost)
                row("RemotePairing port", "\(profile.remotePairingPort)")
                if case .active(let local, let tunnels) = bridge.state {
                    row("Local relay", "\(InterfaceMonitor.currentIPv4() ?? "en0"):\(local)")
                    row("Tunnel relays", tunnelSummary(tunnels))
                }
            }
            HStack {
                Button(scanning ? "Scanning…" : "Find RemotePairing Port") {
                    scanning = true
                    Task {
                        await coordinator.scanRemotePairingPort(profile)
                        scanning = false
                    }
                }
                .disabled(scanning)
                Text("Use if the iPhone restarted and the bridge can't reach it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).font(.system(.callout, design: .monospaced))
        }
    }

    private func tunnelSummary(_ ports: [UInt16]) -> String {
        guard let lo = ports.min(), let hi = ports.max() else { return "none yet" }
        return lo == hi ? "\(lo)" : "\(lo)–\(hi) (\(ports.count) ports)"
    }
}

private struct StatusCard: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let profile: DeviceProfile
    @ObservedObject var bridge: ProxyBridge
    /// Set when `roamrun up` in a terminal owns this device.
    let external: StatusFile.Entry?

    var body: some View {
        let status = external.map { BridgeStatus(title: $0.status) } ?? bridge.status
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: status.symbol)
                .font(.system(size: 26))
                .foregroundStyle(status.color)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text(status.title).font(.headline)
                Text(message(for: status))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let external {
                    Label("Running from Terminal (roamrun up, pid \(external.pid))", systemImage: "terminal")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if status == .error && external == nil {
                    Button("Try Again") { coordinator.startBridge(profile) }
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(StatusSurface(color: status.color))
    }

    private func message(for status: BridgeStatus) -> String {
        switch status {
        case .off:
            return "Start the bridge when the iPhone is away from this Mac's Wi‑Fi. While it's on the same network, Xcode reaches it directly."
        case .starting:
            if let external, !external.detail.isEmpty { return external.detail + "…" }
            if case .starting(let step) = bridge.state { return step + "…" }
            return "Setting things up…"
        case .waiting:
            return "Unlock the iPhone and keep its screen on (it can't be reached while asleep). Tailscale must be connected and the iPhone on a Wi‑Fi network — tethering is fine, cellular alone is not."
        case .preparing:
            return "Paired over Tailscale. Preparing the debug tunnel — this takes a few seconds."
        case .ready:
            return "In Xcode, pick “\(profile.displayName)” as the run destination and press Run."
        case .local:
            return "\(profile.displayName) is on this Mac's network, so Xcode reaches it directly — no bridge needed. RoamRun resumes the bridge by itself when it leaves."
        case .error:
            if let external { return external.detail }
            if case .error(let m) = bridge.state { return m + "\nRoamRun retries automatically every 30 seconds." }
            return ""
        }
    }
}

/// Liquid Glass tinted by status on macOS 26+, a tinted card before that.
private struct StatusSurface: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular.tint(color.opacity(0.35)), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(color.opacity(0.45)))
        } else {
            content
                .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.25)))
        }
    }
}

/// Mac ── Tailscale ── iPhone, lit up as far as the connection reaches.
private struct ConnectionPath: View {
    let profile: DeviceProfile
    let status: BridgeStatus

    var body: some View {
        let linked = status == .ready || status == .preparing
        HStack(spacing: 0) {
            node("laptopcomputer", "This Mac", active: status != .off)
            link(active: linked, label: profile.providerID == MeshProvider.tailscale.rawValue ? "Tailscale" : "Mesh VPN")
            node("iphone", profile.displayName, active: linked)
        }
        .padding(.horizontal, 8)
    }

    private func node(_ symbol: String, _ title: String, active: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .frame(height: 30)
                .foregroundStyle(active ? Color.primary : Color.secondary.opacity(0.5))
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 96)
    }

    private func link(active: Bool, label: String) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Capsule()
                .fill(active ? Color.green : Color.secondary.opacity(0.25))
                .frame(height: 3)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 18)
    }
}

/// This device's lines from the shared log, with a copy button for bug reports.
private struct DeviceLog: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let filter: String

    var body: some View {
        let lines = coordinator.logStore.lines.filter {
            $0.contains("[\(filter)]") || $0.contains("\"\(filter)\"")
        }
        VStack(alignment: .trailing, spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(8)
                    .textSelection(.enabled)
                }
                .frame(height: 160)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
                .onChange(of: lines.count) { _ in
                    if let last = lines.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            Button("Copy Log") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            }
            .controlSize(.small)
        }
    }
}
