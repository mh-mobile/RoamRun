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
    @State private var manualIP = ""
    @State private var name = ""
    @State private var autoName: String?
    /// host -> whether the advertised host:port actually answers.
    /// mDNS cache keeps dead records for ~75min, so zone-dump hits alone
    /// don't mean the device is still here.
    @State private var liveness: [String: Bool] = [:]
    /// host -> its IPv4 addresses, where the browse gave none: what says which Tailscale device it is.
    @State private var addresses: [String: [String]] = [:]
    /// The Tailscale device chosen for the user, by its address: followed until they pick their own.
    @State private var autoMeshID: String?
    @State private var showUnresponsive = false
    @State private var added = false
    @State private var advertsKnown = false
    /// The list stays empty for a few seconds while this Mac's own log and
    /// devicectl are read, so the hints below would blame the device for a wait
    /// the app is causing.
    @State private var showHints = false
    /// Why Add Device was refused (a check the fields above can't see, e.g. the same device by UDID).
    @State private var refusal: String?
    /// The chosen Tailscale device, by its id: a refresh brings new values for the same device.
    @State private var meshDeviceID: String?
    private var meshDevice: MeshDevice? { coordinator.tailscaleDevices.first { $0.id == meshDeviceID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Device").font(.title2.weight(.semibold))
                Text("Do this once, while the device is on this Mac's Wi‑Fi (or plugged in by USB).")
                    .foregroundStyle(.secondary)
            }

            section("1", "Choose the device") { iphonePicker }
            section("2", provider == .tailscale ? "Match it to its Tailscale device" : "Enter its VPN address") { meshPicker }
            section("3", "Name") {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                let problem = added || name.isEmpty ? nil : coordinator.profiles.nameProblem(name)
                Text(problem ?? "Used in the menu and the CLI: roamrun up <name>")
                    .font(.caption)
                    .foregroundStyle(problem != nil ? Color.red : .secondary)
            }

            HStack {
                if !added, let saved = alreadySaved {
                    Text("\(chosenIP) is already saved as “\(saved.displayName)”.")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let refusal {
                    Text(refusal).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Device") {
                    refusal = nil
                    guard let captured = newest(for: selectedHost) else { return }
                    switch coordinator.addDevice(captured: captured, provider: provider, meshDevice: meshDevice,
                                                 manualIP: manualIP, name: name) {
                    case .added(let id):
                        added = true   // the sheet re-renders while closing: don't flag the device we just saved
                        onAdded(id)
                        dismiss()
                    case .refused(let why):
                        refusal = why   // stay, and say why
                    }
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
            try? await Task.sleep(for: .seconds(8))
            showHints = true
        }
        .task {
            while !Task.isCancelled {
                await coordinator.learnAdvertTypes()
                advertsKnown = true
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .onChange(of: selectedHost) { _ in
            refusal = nil
            // Follows the selection until the user types their own: picking another device
            // mustn't save it under the first one's name.
            if name.isEmpty || name == autoName, let s = newest(for: selectedHost) {
                name = coordinator.uniqueName(s.shortHost)
                autoName = name
            }
            followSelection()
        }
        // Its address may only be known a moment after it was picked.
        .onChange(of: addresses) { _ in followSelection() }
        // A refusal is about what was asked then: any change makes it stale.
        .onChange(of: meshDeviceID) { _ in refusal = nil }
        .onChange(of: manualIP) { _ in refusal = nil }
        .onChange(of: name) { _ in refusal = nil }
        .onChange(of: provider) { _ in refusal = nil; followSelection() }
        // The chosen Tailscale device gone from a refreshed list: no choice, not a blank one.
        .onChange(of: coordinator.tailscaleDevices) { devices in
            if let id = meshDeviceID, !devices.contains(where: { $0.id == id }) { meshDeviceID = nil }
            followSelection()
        }
    }

    // MARK: - Step 1

    /// Rows that answer. The rest are usually devices that left, kept alive by
    /// the mDNS cache or a Bonjour Sleep Proxy; unprobed rows wait (≤ ~1s) so
    /// those never flash up.
    private var visibleServices: [CapturedService] {
        if let fake = Snapshot.fakeServices { return fake }
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
                if showHints {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Not showing up? Check that:").font(.callout.weight(.medium))
                        Text("• The device is unlocked and on the same Wi‑Fi as this Mac (or on USB)")
                        Text("• Developer Mode is on (Settings › Privacy & Security)")
                        Text("• It has been paired with this Mac (USB, or Xcode 27 Device Hub › Pair Nearby Device)")
                        if #available(macOS 15, *) {   // the Local Network permission came with macOS 15
                            Text("• RoamRun is allowed in System Settings › Privacy & Security › Local Network — without it this Mac can't see the device at all")
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)   // wrap instead of truncating
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        } else {
            // A busy network (an office Wi‑Fi) can show dozens: scroll rather than grow off screen.
            if visibleServices.count > 5 {
                ScrollView { serviceList }
                    .frame(height: 250)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
            } else {
                serviceList.background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
            }
        }
    }

    private var serviceList: some View {
        VStack(spacing: 0) {
            ForEach(visibleServices) { s in
                // A button, not a tap gesture: reachable with the keyboard (Tab, Space) and VoiceOver.
                Button { selectedHost = s.host } label: {
                    ServiceRow(service: s, live: Snapshot.fakeServices == nil ? liveness[s.host] : true,
                               selected: selectedHost == s.host, tailscaleName: tailscaleDevice(for: s)?.name,
                               symbol: DeviceProfile.symbol(for: deviceType(ofHost: s.host)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedHost == s.host ? .isSelected : [])
                .accessibilityValue(selectedHost == s.host ? "Selected" : "")   // macOS VoiceOver may not voice the trait
                if s.id != visibleServices.last?.id { Divider() }
            }
        }
    }

    private struct ServiceRow: View {
        let service: CapturedService
        let live: Bool?
        let selected: Bool
        /// Which Tailscale device this is, when its address here says so: two phones are both "iPhone".
        var tailscaleName: String?
        let symbol: String

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)   // "selected" is a trait of the row
                Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(service.shortHost).lineLimit(1).truncationMode(.middle)
                    Text((service.hostIPs.first(where: { $0.contains(".") }) ?? service.host)
                         + (tailscaleName.map { " · \($0) on Tailscale" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
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
                    Picker("Device", selection: $meshDeviceID) {
                        Text("Choose…").tag(String?.none)
                        ForEach(peersSorted) { d in
                            Text(d.label).tag(String?.some(d.id))
                        }
                    }
                    .labelsHidden()
                    Button { coordinator.refreshTailscale() } label: {
                        Label("Refresh Tailscale devices", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
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

    /// The Tailscale device a host on this LAN is, by the address Tailscale reaches it at.
    private func tailscaleDevice(for service: CapturedService) -> MeshDevice? {
        coordinator.tailscaleDevices.reached(at: service.hostIPs + (addresses[service.host] ?? []))
    }

    /// Step 2 follows step 1 where the device's address settles it, until the user chooses there.
    private func followSelection() {
        guard provider == .tailscale else { return }
        let match = newest(for: selectedHost).flatMap(tailscaleDevice(for:))
        (meshDeviceID, autoMeshID) = MeshDevice.follow(chosen: meshDeviceID, auto: autoMeshID, match: match?.id)
    }

    /// A host's IPv4 addresses by the system's resolver (mDNS for `.local`); empty when it has none.
    nonisolated private static func ipv4(of host: String) async -> [String] {
        await Task.detached {
            var hints = addrinfo(), list: UnsafeMutablePointer<addrinfo>?
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
            defer { freeaddrinfo(list) }
            var found: [String] = []
            for info in sequence(first: first, next: { $0.pointee.ai_next }) {
                var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let address = name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                    if !found.contains(address) { found.append(address) }
                }
            }
            return found
        }.value
    }

    private func newest(for host: String?) -> CapturedService? {
        if let fake = Snapshot.fakeServices { return fake.first { $0.host == host } }
        return coordinator.capture.services.values.filter { $0.host == host }.max { $0.lastSeen < $1.lastSeen }
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
                var found: [String: Bool] = [:]
                for await (host, live) in group { found[host] = live }
                return found
            }
            liveness.merge(results) { _, new in new }
            // Only for rows that answer and whose address the browse didn't give: the name is asked once.
            for s in servicesSorted where s.hostIPs.isEmpty && addresses[s.host] == nil && results[s.host] == true {
                addresses[s.host] = await Self.ipv4(of: s.host)
            }
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
        visibleServices.contains(where: { $0.host == selectedHost }) && coordinator.profiles.nameProblem(name) == nil
            && isIPAddress(chosenIP) && alreadySaved == nil
    }
}
