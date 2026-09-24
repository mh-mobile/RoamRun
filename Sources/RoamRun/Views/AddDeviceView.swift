import SwiftUI

struct AddDeviceView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    var onAdded: (UUID) -> Void = { _ in }

    @State private var captured: CapturedService?
    @State private var provider: MeshProvider = .tailscale
    @State private var meshDevice: MeshDevice?
    @State private var manualIP = ""
    @State private var name = ""
    /// instanceName -> whether the advertised host:port actually answers.
    /// mDNS cache keeps dead records for ~75min, so zone-dump hits alone
    /// don't mean the device is still here.
    @State private var liveness: [String: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add iPhone").font(.title2.weight(.semibold))
                Text("Do this once, while the iPhone is on this Mac's Wi‑Fi (or plugged in by USB).")
                    .foregroundStyle(.secondary)
            }

            section("1", "Choose the iPhone") { iphonePicker }
            section("2", "Match it to its Tailscale device") { meshPicker }
            section("3", "Name") {
                TextField("My iPhone", text: $name)
                    .textFieldStyle(.roundedBorder)
                Text(coordinator.isNameTaken(name)
                     ? "Another iPhone already uses this name — pick a different one."
                     : "Used in the menu and the CLI: roamrun up <name>")
                    .font(.caption)
                    .foregroundStyle(coordinator.isNameTaken(name) ? Color.red : .secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add iPhone") {
                    guard let captured else { return }
                    if let id = coordinator.addDevice(captured: captured, provider: provider,
                                                      meshDevice: meshDevice, manualIP: manualIP,
                                                      name: name) {
                        onAdded(id)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { coordinator.refreshTailscale() }
        .task { await probeLoop() }
        .onChange(of: captured) { new in
            if name.isEmpty, let new { name = coordinator.uniqueName(new.shortHost) }
        }
    }

    // MARK: - Step 1

    @ViewBuilder
    private var iphonePicker: some View {
        if servicesSorted.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for iPhones on this network…").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Not showing up? Check that:").font(.callout.weight(.medium))
                    Text("• The iPhone is unlocked and on the same Wi‑Fi as this Mac (or on USB)")
                    Text("• Developer Mode is on (Settings › Privacy & Security)")
                    Text("• It has been paired with this Mac (USB, or Xcode 27 Device Hub › Pair Nearby Device)")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 0) {
                ForEach(servicesSorted) { s in
                    ServiceRow(service: s, live: liveness[s.instanceName],
                               selected: captured?.instanceName == s.instanceName)
                        .contentShape(Rectangle())
                        .onTapGesture { captured = s }
                    if s.id != servicesSorted.last?.id { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
        }
    }

    private struct ServiceRow: View {
        let service: CapturedService
        let live: Bool?
        let selected: Bool

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Image(systemName: "iphone").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(service.shortHost)
                    Text(service.hostIPs.first(where: { $0.contains(".") }) ?? service.host)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                switch live {
                case .some(true): Label("Reachable", systemImage: "checkmark.circle.fill")
                    .labelStyle(StatusLabelStyle(color: .green)).font(.caption)
                case .some(false): Label("Not responding", systemImage: "moon.zzz")
                    .labelStyle(StatusLabelStyle(color: .secondary)).font(.caption)
                case .none: ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
    }

    // MARK: - Step 2

    @ViewBuilder
    private var meshPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Provider", selection: $provider) {
                ForEach(MeshProvider.allCases) { p in Text(p.displayName).tag(p) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if provider == .tailscale {
                if let err = coordinator.tailscaleError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(StatusLabelStyle(color: .orange))
                        .font(.callout)
                }
                HStack {
                    Picker("Device", selection: $meshDevice) {
                        Text("Choose…").tag(MeshDevice?.none)
                        ForEach(peersSorted) { d in
                            Text(d.label).tag(MeshDevice?.some(d))
                        }
                    }
                    .labelsHidden()
                    Button { coordinator.refreshTailscale() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh Tailscale devices")
                }
            } else {
                TextField("iPhone's VPN address, e.g. 100.64.0.5", text: $manualIP)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - Helpers

    private func section<Content: View>(_ n: String, _ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(n). \(title)").font(.headline)
            content()
        }
    }

    private var servicesSorted: [CapturedService] {
        coordinator.capture.services.values.sorted { a, b in
            let la = liveness[a.instanceName] ?? false
            let lb = liveness[b.instanceName] ?? false
            return la == lb ? a.lastSeen > b.lastSeen : la && !lb
        }
    }

    /// iPhones first, then online peers — the one you want is near the top.
    private var peersSorted: [MeshDevice] {
        coordinator.tailscaleDevices.sorted { a, b in
            let ka = (a.os.lowercased() == "ios" ? 0 : 1, a.online ? 0 : 1, a.name)
            let kb = (b.os.lowercased() == "ios" ? 0 : 1, b.online ? 0 : 1, b.name)
            return ka < kb
        }
    }

    /// Re-check each advertised endpoint; records seen in the zone dump can be
    /// stale cache entries pointing at devices that already left the network.
    private func probeLoop() async {
        while !Task.isCancelled {
            for s in coordinator.capture.services.values {
                let targets = s.hostIPs.isEmpty ? [s.host] : s.hostIPs
                var alive = false
                for t in targets where !alive {
                    alive = await ReachabilityProbe.checkTCP(host: t, port: s.port, timeout: 1.2)
                }
                liveness[s.instanceName] = alive
            }
            try? await Task.sleep(for: .seconds(4))
        }
    }

    private var canAdd: Bool {
        guard captured != nil, !name.trimmingCharacters(in: .whitespaces).isEmpty,
              !coordinator.isNameTaken(name) else { return false }
        switch provider {
        case .tailscale: return meshDevice?.ipv4 != nil
        case .manual: return !manualIP.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}
