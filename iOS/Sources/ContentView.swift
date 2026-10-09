import AVFoundation
import SwiftUI
import VisionKit

extension Color {
    /// The icon's blue.
    static let brand = Color(red: 0.145, green: 0.388, blue: 0.922)
}

struct ContentView: View {
    @State private var session = Session()
    @State private var scanning = false
    @State private var editing = false

    var body: some View {
        ZStack {
            Backdrop()
            if let outcome = session.outcome {
                OutcomeView(session: session, outcome: outcome).transition(.opacity)
            } else if session.running {
                RunView(session: session).transition(.opacity)
            } else {
                StartView(session: session, scan: scan, edit: { editing = true }).transition(.opacity)
            }
        }
        .tint(.brand)
        .animation(.smooth(duration: 0.3), value: session.running)
        .animation(.smooth(duration: 0.3), value: session.outcome)
        .animation(.smooth(duration: 0.3), value: session.stage)
        .animation(.smooth(duration: 0.3), value: session.code)
        .onOpenURL { session.open($0) }
        .sheet(isPresented: $scanning) {
            ScanSheet { url in
                scanning = false
                session.open(url)
            }
        }
        .sheet(isPresented: $editing) { OtherWays(session: session) }
        #if DEBUG
        .task { if let what = ProcessInfo.processInfo.environment["INTRODUCER_PREVIEW"] { session.preview(what) } }
        #endif
    }

    private func scan() {
        Task {
            if await AVCaptureDevice.requestAccess(for: .video) { scanning = true }
            else { session.notice = "The camera is off for this app. Allow it in Settings › Apps › RoamRun, or enter the Mac's name." }
        }
    }
}

// MARK: - Pieces

private struct Backdrop: View {
    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemGroupedBackground)
            LinearGradient(colors: [Color.brand.opacity(0.24), Color.cyan.opacity(0.10), .clear], startPoint: .topLeading, endPoint: .bottom)
                .frame(height: 440)
        }
        .ignoresSafeArea()
    }
}

private extension View {
    func card() -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct Primary: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(.white)
            .background(LinearGradient(colors: [.brand, Color(red: 0.07, green: 0.56, blue: 0.90)], startPoint: .leading, endPoint: .trailing), in: Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

private struct Secondary: ButtonStyle {
    var color = Color.brand

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(color)
            .background(color.opacity(configuration.isPressed ? 0.26 : 0.16), in: Capsule())
    }
}

private struct Command: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(.footnote, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - First screen

private struct StartView: View {
    var session: Session
    var scan: () -> Void
    var edit: () -> Void

    private var host: String { session.far.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 14) {
                    Image("Mark")
                        .resizable()
                        .frame(width: 92, height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                        .shadow(color: .brand.opacity(0.35), radius: 18, y: 8)
                        .accessibilityHidden(true)
                    Text("Introduce a Mac").font(.largeTitle.bold())
                    Text("Pair this iPhone with a Mac that isn't nearby, over Tailscale.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 28)

                if host.isEmpty {
                    VStack(spacing: 12) {
                        Button(action: scan) { Label("Scan the Mac's Code", systemImage: "qrcode.viewfinder") }.buttonStyle(Primary())
                        Button("Enter Its Name", action: edit).buttonStyle(Secondary())
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 14) {
                            Image(systemName: "desktopcomputer")
                                .font(.title2)
                                .foregroundStyle(Color.brand)
                                .frame(width: 46, height: 46)
                                .background(Color.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.name).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                                if host != session.name { Text(host).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                                if session.byLine { Label("With its offer, carried by hand", systemImage: "doc.on.clipboard").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 0)
                        }
                        Button("Introduce") { session.introduce() }.buttonStyle(Primary())
                    }
                    .card()
                    HStack(spacing: 12) {
                        Button(action: scan) { Label("Scan a Code", systemImage: "qrcode.viewfinder") }.buttonStyle(Secondary())
                        Button(action: edit) { Label("Edit", systemImage: "slider.horizontal.3") }.buttonStyle(Secondary())
                    }
                }

                if let notice = session.notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("How it goes").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    HowRow(number: 1, title: "On the far Mac", detail: "Device Hub › + › Pair Nearby Device, then in a terminal:", command: "roamrun pair xcode --with <this iPhone> --qr")
                    HowRow(number: 2, title: "Scan the code it draws", detail: "Or enter the Mac's Tailscale name.")
                    HowRow(number: 3, title: "Pair in Settings", detail: "Privacy & Security › Developer Mode › Pair with the Mac, and type its code.")
                }
                .card()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
    }
}

private struct HowRow: View {
    let number: Int
    let title: String
    let detail: String
    var command: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.brand)
                .frame(width: 28, height: 28)
                .background(Color.brand.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                if let command { Command(command) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - While it runs

private struct RunView: View {
    var session: Session

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Text(session.kind == .control ? "Introducing, for device control" : "Introducing").font(.subheadline).foregroundStyle(.secondary)
                    Text(session.name).font(.largeTitle.bold()).lineLimit(1).minimumScaleFactor(0.6)
                }
                .padding(.top, 40)

                if let code = session.code {
                    VStack(spacing: 8) {
                        Text(code.prefix(3) + " " + code.suffix(3))
                            .font(.system(size: 54, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.5).lineLimit(1)
                            .textSelection(.enabled)
                            .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
                        Text("Type this code in Settings").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .background(Color.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }

                VStack(alignment: .leading, spacing: 20) {
                    StepRow(number: 1, title: session.byLine ? "Offer read from the line" : "Ask \(session.name) for its offer",
                            detail: "It answers once Pair Nearby Device is waiting there.", at: .asking, now: session.stage)
                    StepRow(number: 2, title: "Pair in Settings", detail: pairing, at: .pairing, now: session.stage)
                    StepRow(number: 3, title: session.kind == .control ? "\(session.name) keeps the pairing" : "Tell \(session.name) about this iPhone",
                            detail: session.kind == .control ? "It says here what it kept." : "So it can find this iPhone over Tailscale.", at: .finishing, now: session.stage)
                }
                .card()

                if let hint = session.hint {
                    Label(hint, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                if session.limited, session.stage != .finishing {
                    Label("iOS gives this about 30 seconds in the background: go to Settings and type the code straight away.", systemImage: "timer")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }

                Button("Stop", role: .destructive) { session.stop() }.buttonStyle(Secondary(color: .red))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
    }

    private var pairing: String {
        let path = "Settings › Privacy & Security › Developer Mode › Pair with “\(session.announcedName)”."
        if session.kind == .xcode { return path + " Then type the code Device Hub shows on \(session.name)." }
        return session.code == nil ? path + " The code then arrives here, in a notification and at the top of the screen." : "Type the code above in Settings."
    }
}

private struct StepRow: View {
    let number: Int
    let title: String
    let detail: String
    let at: Session.Stage
    let now: Session.Stage

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                if now > at {
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                } else if now == at {
                    Circle().fill(Color.brand.opacity(0.12))
                    ProgressView().controlSize(.small)
                } else {
                    Circle().fill(Color(.tertiarySystemFill))
                    Text("\(number)").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(now == at ? .semibold : .regular)).foregroundStyle(now < at ? .secondary : .primary)
                if now == at { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(now > at ? "Done" : now == at ? "In progress" : "Not started")
    }
}

// MARK: - How it ended

private struct OutcomeView: View {
    var session: Session
    let outcome: Session.Outcome
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: symbol)
                    .font(.system(size: 76))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(color)
                    .padding(.top, 56)
                    .accessibilityHidden(true)
                Text(outcome.title).font(.title2.bold()).multilineTextAlignment(.center)
                // A line that is a command is set as one.
                VStack(spacing: 10) {
                    ForEach(Array(outcome.detail.split(separator: "\n").enumerated()), id: \.offset) { part in
                        if part.element.hasPrefix("roamrun ") { Command(String(part.element)) }
                        else { Text(part.element).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true) }
                    }
                }

                if let line = outcome.line {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(line).font(.system(.footnote, design: .monospaced)).lineLimit(5).truncationMode(.middle).textSelection(.enabled)
                        HStack(spacing: 12) {
                            Button {
                                UIPasteboard.general.string = line
                                copied = true
                            } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                                .buttonStyle(Secondary())
                            ShareLink(item: line) { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(Secondary())
                        }
                    }
                    .card()
                }

                VStack(spacing: 12) {
                    if outcome.tone == .failure {
                        Button("Try Again") { session.introduce() }.buttonStyle(Primary())
                        Button("Back") { session.dismiss() }.buttonStyle(Secondary())
                    } else {
                        Button("Done") { session.dismiss() }.buttonStyle(Primary())
                    }
                }
                .padding(.top, 4)

                if !session.log.isEmpty {
                    DisclosureGroup("Details") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(session.log.enumerated()), id: \.offset) {
                                Text($0.element).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, 8)
                    }
                    .font(.subheadline)
                    .card()
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
    }

    private var symbol: String {
        switch outcome.tone {
        case .success: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .failure: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch outcome.tone {
        case .success: .green
        case .attention: .orange
        case .failure: .red
        }
    }
}

// MARK: - Sheets

private struct OtherWays: View {
    @Bindable var session: Session
    @Environment(\.dismiss) private var dismiss

    private var problem: String? {
        let host = session.far.trimmingCharacters(in: .whitespaces)
        return host.isEmpty ? nil : Session.hostProblem(host)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("rr-cloud", text: $session.far)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                } header: {
                    Text("Far Mac's Tailscale name")
                } footer: {
                    Text(problem ?? "As the Tailscale app lists it, or its whole name ending in .ts.net.")
                        .foregroundStyle(problem == nil ? Color.secondary : Color.red)
                }
                Section {
                    Toggle("Carry the lines by hand", isOn: $session.byLine)
                    if session.byLine {
                        TextEditor(text: $session.offerLine)
                            .font(.system(.footnote, design: .monospaced)).frame(minHeight: 96)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .overlay(alignment: .topLeading) {
                                if session.offerLine.isEmpty { Text("Paste the line from roamrun pair xcode").foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 4).allowsHitTesting(false) }
                            }
                        TextField("This iPhone's Tailscale name", text: $session.peerName)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    }
                } footer: {
                    Text(session.byLine
                         ? "On the far Mac: roamrun pair xcode prints the line (with --qr, a code that holds it). Afterwards this app shows a line to take back there."
                         : "For a far Mac this iPhone can't ask over Tailscale. Xcode's pairing only.")
                }
            }
            .navigationTitle("Far Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct ScanSheet: View {
    var found: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                    Scanner(found: found).ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView("The camera can't be used", systemImage: "camera.fill", description: Text("Enter the far Mac's Tailscale name instead."))
                }
            }
            .navigationTitle("Scan the Mac's Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
