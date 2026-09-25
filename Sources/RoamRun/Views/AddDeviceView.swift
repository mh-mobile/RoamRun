import SwiftUI
import Network

struct AddDeviceView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    var onAdded: (UUID) -> Void = { _ in }

    /// Selected device, by host: its newest Bonjour instance can change
    /// while the sheet is open, the device doesn't.
    @State private var selectedHost: String?
    @State private var provider: MeshProvider = .tailscale
    @State private var meshDevice: MeshDevice?
    @State private var manualIP = ""
    @State private var name = ""
    /// host -> whether the advertised host:port actually answers.
    /// mDNS cache keeps dead records for ~75min, so zone-dump hits alone
    /// don't mean the device is still here.
    @State private var liveness: [String: Bool] = [:]
    @State private var showUnresponsive = false
    @State private var added = false
    @State private var advertsKnown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Device").font(.title2.weight(.semibold))
                Text("Do this once, while the device is on this Mac's Wi‑Fi (or plugged in by USB).")
                    .foregroundStyle(.secondary)
            }

            section("1", "Choose the device") { iphonePicker }
            section("2", "Match it to its Tailscale device") { meshPicker }
            section("3", "Name") {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Text(!added && coordinator.isNameTaken(name)
                     ? "Another device already uses this name — pick a different one."
                     : "Used in the menu and the CLI: roamrun up <name>")
                    .font(.caption)
                    .foregroundStyle(!added && coordinator.isNameTaken(name) ? Color.red : .secondary)
            }

            HStack {
                if !added, let saved = alreadySaved {
                    Text("\(chosenIP) is already saved as “\(saved.displayName)”.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Device") {
                    guard let captured = newest(for: selectedHost),
                          let id = coordinator.addDevice(captured: captured, provider: provider,
                                                         meshDevice: meshDevice, manualIP: manualIP,
                                                         name: name) else { return }   // stay: the checks above say why
                    added = true   // the sheet re-renders while closing: don't flag the device we just saved
                    onAdded(id)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            coordinator.refreshTailscale()
            coordinator.capture.restart()   // only this sheet needs the scan
        }
        .onDisappear { coordinator.capture.stop() }
        .task { await probeLoop() }
        .task {
            while !Task.isCancelled {
                await coordinator.learnAdvertTypes()
                advertsKnown = true
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .onChange(of: selectedHost) { _ in
            if name.isEmpty, let s = newest(for: selectedHost) { name = coordinator.uniqueName(s.shortHost) }
        }
    }

    // MARK: - Step 1

    /// Rows that answer. The rest are usually devices that left, kept alive by
    /// the mDNS cache or a Bonjour Sleep Proxy; unprobed rows wait (≤ ~1s) so
    /// those never flash up.
    private var visibleServices: [CapturedService] {
        guard advertsKnown else { return [] }   // until we can tell saved devices apart, show nothing
        return servicesSorted.filter { showUnresponsive || liveness[$0.host] == true }
    }

    @ViewBuilder
    private var iphonePicker: some View {
        devicePicker
        let hidden = advertsKnown ? servicesSorted.filter { liveness[$0.host] == false }.count : 0
        if hidden > 0 && !showUnresponsive {
            Button("\(hidden) not responding — show") { showUnresponsive = true }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var devicePicker: some View {
        if advertsKnown && servicesSorted.isEmpty && !coordinator.capture.services.isEmpty
            && coordinator.capture.services.values.allSatisfy({ isSaved(host: $0.host) }) {
            Text("All devices on this network are already added.")
                .foregroundStyle(.secondary)
        } else if visibleServices.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for devices on this network…").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Not showing up? Check that:").font(.callout.weight(.medium))
                    Text("• The device is unlocked and on the same Wi‑Fi as this Mac (or on USB)")
                    Text("• Developer Mode is on (Settings › Privacy & Security)")
                    Text("• It has been paired with this Mac (USB, or Xcode 27 Device Hub › Pair Nearby Device)")
                }
                .fixedSize(horizontal: false, vertical: true)   // wrap instead of truncating
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 0) {
                ForEach(visibleServices) { s in
                    ServiceRow(service: s, live: liveness[s.host],
                               selected: selectedHost == s.host,
                               symbol: DeviceProfile.symbol(for: deviceType(ofHost: s.host)))
                        .contentShape(Rectangle())
                        .onTapGesture { selectedHost = s.host }
                    if s.id != visibleServices.last?.id { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
        }
    }

    private struct ServiceRow: View {
        let service: CapturedService
        let live: Bool?
        let selected: Bool
        let symbol: String

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Image(systemName: symbol).foregroundStyle(.secondary)
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
                TextField("The device's VPN address, e.g. 100.64.0.5", text: $manualIP)
                    .textFieldStyle(.roundedBorder)
                if !chosenIP.isEmpty && !isIPAddress(chosenIP) {
                    Text("Enter an IP address, e.g. 100.64.0.5").font(.caption).foregroundStyle(.red)
                }
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

    /// One row per device. An iPhone announces a new Bonjour instance each
    /// time it changes network, and the old ones linger in the mDNS cache
    /// (~75 min) — keep only the newest per host.
    /// Stable order: responding devices first, then by name — rows must not
    /// jump around while the user is picking one.
    private var servicesSorted: [CapturedService] {
        Set(coordinator.capture.services.values.map(\.host)).filter { !isSaved(host: $0) }
            .compactMap(newest(for:)).sorted { a, b in
            let la = liveness[a.host] != false, lb = liveness[b.host] != false
            guard la == lb else { return la }
            let c = a.shortHost.localizedStandardCompare(b.shortHost)
            return c == .orderedSame ? a.host < b.host : c == .orderedAscending
        }
    }

    /// Any of the host's (rotating) adverts that remotepairingd matched to a
    /// known device (by UDID; host names aren't trusted).
    private func deviceType(ofHost host: String) -> String? {
        coordinator.capture.services.values.lazy.filter { $0.host == host }
            .compactMap { coordinator.advertTypes[$0.instanceName] }.first
    }

    /// Already added? By UDID only — remotepairingd matches each advert to one.
    /// Host names can't be trusted: they change on rename and repeat across
    /// people ("iPhone").
    private func isSaved(host: String) -> Bool {
        let saved = Set(coordinator.profiles.compactMap { $0.udid?.uppercased() })
        return coordinator.capture.services.values.contains {
            $0.host == host && coordinator.advertUDIDs[$0.instanceName].map(saved.contains) == true
        }
    }

    private func newest(for host: String?) -> CapturedService? {
        coordinator.capture.services.values.filter { $0.host == host }.max { $0.lastSeen < $1.lastSeen }
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
            let results = await withTaskGroup(of: (String, Bool).self) { group in
                for s in servicesSorted {
                    let targets = s.hostIPs.isEmpty ? [s.host] : s.hostIPs
                    group.addTask {
                        for t in targets where await ReachabilityProbe.checkTCP(host: t, port: s.port, timeout: 1.2) {
                            return (s.host, true)
                        }
                        return (s.host, false)
                    }
                }
                return await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
            }
            liveness.merge(results) { _, new in new }
            // Re-check every 4s, but a newly seen device right away.
            for _ in 0..<8 where !servicesSorted.contains(where: { liveness[$0.host] == nil }) {
                try? await Task.sleep(for: .seconds(0.5))
            }
        }
    }

    /// Dotted-quad IPv4 or IPv6, no zone: IPv4Address alone also takes "10.1" or "0x7f.1".
    private func isIPAddress(_ s: String) -> Bool {
        guard !s.contains("%") else { return false }
        if s.contains(":") { return IPv6Address(s) != nil }
        return s.split(separator: ".").count == 4 && s.allSatisfy { $0.isNumber || $0 == "." } && IPv4Address(s) != nil
    }

    private var chosenIP: String {
        provider == .manual ? manualIP.trimmingCharacters(in: .whitespaces) : (meshDevice?.ipv4 ?? "")
    }

    /// Two profiles for one iPhone would both bridge it and collide.
    private var alreadySaved: DeviceProfile? {
        coordinator.profiles.first { $0.providerIP == chosenIP }
    }

    private var canAdd: Bool {
        visibleServices.contains(where: { $0.host == selectedHost }) && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !coordinator.isNameTaken(name) && isIPAddress(chosenIP) && alreadySaved == nil
    }
}
