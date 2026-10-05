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
    @State private var renameRefusal: String?
    @State private var scanResult: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                StatusCard(profile: profile, bridge: bridge, external: external)
                ConnectionPath(profile: profile, status: status)
                DeviceControlRow(profile: profile)

                VStack(alignment: .leading, spacing: 0) {
                    DisclosureGroup("Technical details", isExpanded: $showDetails) {
                        technicalDetails.padding(.top, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider().padding(.vertical, 10)
                    DisclosureGroup("Activity log", isExpanded: $showLog) {
                        DeviceLog(log: coordinator.logStore, device: profile.id).padding(.top, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack {
                    Spacer()
                    Button("Remove Device…", role: .destructive) { confirmDelete = true }
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
        .alert("Rename Device", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") {
                // Return can reach a disabled alert button: say why instead of closing on nothing.
                if !coordinator.rename(profile.id, to: newName) {
                    let why = coordinator.profiles.nameProblem(newName, except: profile.id) ?? "This device is no longer saved."
                    DispatchQueue.main.async { renameRefusal = why }   // once this alert has gone: two at once may not show
                }
            }
                .disabled(coordinator.profiles.nameProblem(newName, except: profile.id) != nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(coordinator.profiles.nameProblem(newName, except: profile.id).map { $0 + " " } ?? "")
                + Text("Used in the menu and the CLI (roamrun up <name>). Must be unique and not start with “-”.")
        }
        .alert("Couldn't Rename", isPresented: Binding(get: { renameRefusal != nil }, set: { if !$0 { renameRefusal = nil } })) {
            Button("OK") {}
        } message: {
            Text(renameRefusal ?? "")
        }
        .alert("Remove “\(profile.displayName)”?", isPresented: $confirmDelete) {
            Button("Remove", role: .destructive) { coordinator.deleteProfile(profile.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The bridge stops and the saved pairing details are deleted. You can add the device again later.")
        }
    }

    private var external: StatusFile.Entry? { coordinator.externalBridges[profile.id] }
    private var status: BridgeStatus { coordinator.status(of: profile.id) }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: profile.symbol)
                .font(.system(size: 28))
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.displayName).font(.title2.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)   // keeps Rename and the bridge button in view
                        .help(profile.displayName)
                    Button {
                        newName = profile.displayName
                        renaming = true
                    } label: { Label("Rename", systemImage: "pencil").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .help("Rename")
                }
                Text(peerDescription).foregroundStyle(.secondary)
            }
            Spacer()
            if external != nil {
                Button("Stop Bridge") { coordinator.stopExternalBridge(profile.id) }
                    .controlSize(.large)
            } else if bridge.state == .off {   // an errored bridge keeps retrying: offer Stop (Try Again is in the card)
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
                    scanResult = nil
                    Task {
                        scanResult = await coordinator.scanRemotePairingPort(profile)
                        scanning = false
                    }
                }
                .disabled(scanning)
                Text(scanResult ?? "Use if the device restarted and the bridge can't reach it.")
                    .font(.caption).foregroundStyle(scanResult == nil ? .secondary : .primary)
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
        let status = external.map(\.kind) ?? bridge.status
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: status.symbol)
                .font(.system(size: 26))
                .foregroundStyle(status.color)
                .spinning(status.isWorking)
                .frame(width: 30)
                .accessibilityHidden(true)   // the title next to it says the same
            VStack(alignment: .leading, spacing: 6) {
                Text(status.title).font(.headline)
                Text(message(for: status))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let external {
                    Label(external.cli == true ? "Running from Terminal (roamrun up, pid \(external.pid))"
                                               : "Running in another copy of RoamRun (pid \(external.pid))",
                          systemImage: external.cli == true ? "terminal" : "macwindow")
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
        let vpn = MeshProvider(rawValue: profile.providerID) == .tailscale ? "Tailscale" : "the VPN"
        // A bridge run by `roamrun up` detects this in its own process, so the
        // window's alert never fires for it: the only way here is its detail.
        if let external, external.detail.contains(LocalNetwork.advice) { return external.detail }
        switch status {
        case .off:
            return "Start the bridge when the device is away from this Mac's Wi‑Fi. While it's on the same network, Xcode reaches it directly."
        case .starting:
            if let external, !external.detail.isEmpty {
                return external.detail.contains(LocalNetwork.advice) ? external.detail : external.detail + "…"
            }
            if case .starting(let step) = bridge.state { return step + "…" }
            return "Setting things up…"
        case .waiting:
            return "Unlock the device and keep its screen on (it can't be reached while asleep). \(vpn) must be connected and the device on a Wi‑Fi network — tethering is fine, cellular alone is not."
        case .preparing:
            return "Paired over \(vpn). Preparing the debug tunnel — this takes a few seconds."
        case .ready:
            return "In Xcode, pick “\(profile.displayName)” as the run destination and press Run."
        case .local:
            return "\(profile.displayName) is on this Mac's network, so Xcode reaches it directly — no bridge needed. RoamRun resumes the bridge by itself when it leaves."
        case .error:
            if let external { return external.detail.isEmpty ? "The other RoamRun process reported an error — see its log." : external.detail }
            if case .error(let m) = bridge.state { return bridge.autoRetry ? m + "\nRoamRun retries automatically, waiting longer after each failure in a row (up to 10 minutes)." : m }
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
            node(profile.symbol, profile.displayName, active: linked)
        }
        .padding(.horizontal, 8)
        // One element: the line's color is what says "connected".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This Mac to \(profile.displayName) over \(profile.providerID == MeshProvider.tailscale.rawValue ? "Tailscale" : "the mesh VPN")")
        .accessibilityValue(linked ? "Connected" : status == .local ? "Not needed: on this Mac's Wi‑Fi" : "Not connected")
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
/// Observes the log itself: the coordinator doesn't re-publish its changes, so a
/// line logged while nothing else changed showed only on the next unrelated update.
private struct DeviceLog: View {
    private static let end = "end"
    @ObservedObject var log: LogStore
    let device: UUID

    var body: some View {
        let lines = log.lines.filter { $0.device == device }.map(\.text)
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
                        Color.clear.frame(height: 1).id(Self.end)   // below the padding-free last line
                    }
                    .padding(8)
                    .textSelection(.enabled)
                }
                .frame(height: 160)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
                // Only this device's own lines: another's mustn't pull a reader back down.
                .onChange(of: log.appended[device, default: 0]) { _ in
                    // Next turn: the new line isn't laid out yet, so it stopped one line short.
                    DispatchQueue.main.async { proxy.scrollTo(Self.end, anchor: .bottom) }
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

/// Device control: whether this Mac has a pairing of its own with the device,
/// and the way to make one.
private struct DeviceControlRow: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let profile: DeviceProfile
    @State private var confirmRemove = false

    var body: some View {
        // The connection comes and goes with the device; what is said is read anew every few seconds.
        // The sheet and the dialog hang on what stays, not on what is drawn anew.
        TimelineView(.periodic(from: .now, by: 3)) { _ in row }
            .sheet(isPresented: Binding(get: { coordinator.controlPairing?.device == profile.id },
                                        set: { if !$0 { coordinator.endControlPairing() } })) {
                ControlPairingSheet(profile: profile)
            }
            .confirmationDialog("Remove device control for “\(profile.displayName)”?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) { coordinator.removeControlPairing(profile) }
            } message: {
                Text("RoamRun forgets its pairing, and nothing can use the device's side of it any more. To take it off the device's list too: on the device, Settings › Privacy & Security › Developer Mode, choose its entry, then unpair — “\(AppCoordinator.controlHostName)” when it was set up here under this Mac's present name, or the name it was made under (`pairing create --as`) when it was brought in.")
            }
            .onDisappear {   // the sheet goes with this view; so does what it was showing
                if coordinator.controlPairing?.device == profile.id { coordinator.endControlPairing() }
            }
    }

    private var row: some View {
        let state = coordinator.controlState(profile)
        let allowed = coordinator.controlAllowed(profile)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Device control").font(.headline)
                Text(summary(state, allowed: allowed)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if state.paired {
                // Off: every command and agent is refused, whichever asks. Kept in the Keychain,
                // where another program can't switch it back on.
                Toggle("On", isOn: Binding(get: { allowed }, set: { coordinator.setControlAllowed(profile.id, $0) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .help("While off, no command or agent can see or operate this device")
            }
            if state.paired {
                Button("Remove…") { confirmRemove = true }
            }
            Button(state.paired ? "Pair Again…" : "Set Up…") { coordinator.startControlPairing(profile) }
        }
    }

    private func summary(_ state: (paired: Bool, open: Bool, refused: Bool), allowed: Bool) -> String {
        if !state.paired { return "Lets agents see and operate this device (roamrun look, tap, mcp). Needs iOS 27 and a pairing of RoamRun's own." }
        if state.refused { return "This pairing can no longer be used: it was removed on the device, or this Mac can't read what it saved. Pair again." }
        if coordinator.controlAnother(profile) {
            return "What answers at this device's address isn't the device this pairing was made with, so nothing is sent to it. If the device was erased or replaced, pair again; if not, something else has its address."
        }
        if !allowed { return "Paired, switched off: commands and agents are refused. Any program you run on this Mac can use it while it is on." }
        return state.open ? "Paired and connected." : "Paired. Connects while the device is on Wi‑Fi, awake and reachable."
    }
}

private struct ControlPairingSheet: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let profile: DeviceProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Up Device Control").font(.title2.bold())
            switch coordinator.controlPairing?.step {
            case .waiting(let name):
                if !name.isEmpty {   // empty until it listens
                    Text("On “\(profile.displayName)”, with it on the same Wi‑Fi as this Mac:")
                    Text("Settings › Privacy & Security › Developer Mode, then choose “\(name)” to pair.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Needs iOS 27 or later: earlier versions list no devices there, and refuse remote control.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ProgressView("Waiting for the device…")
            case .code(let digits):
                Text("Enter this code on the device:")
                Text(digits).font(.system(size: 40, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity)
            case .checking:
                ProgressView("Checking the connection…")
            case .done(_, nil):
                Label("Device control is set up.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .done(_, let why?):
                Label("Paired. The device can't be reached over the VPN right now, so device control connects when it can.",
                      systemImage: "checkmark.circle").foregroundStyle(.green)
                Text(why).font(.caption).foregroundStyle(.secondary)
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case nil:
                EmptyView()
            }
            HStack {
                Spacer()
                switch coordinator.controlPairing?.step {
                case .done:
                    Button("Done") { coordinator.endControlPairing() }.keyboardShortcut(.defaultAction)
                case .failed:
                    Button("Close") { coordinator.endControlPairing() }.keyboardShortcut(.cancelAction)
                    Button("Try Again") { coordinator.startControlPairing(profile) }.keyboardShortcut(.defaultAction)
                default:
                    Button("Cancel") { coordinator.endControlPairing() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
