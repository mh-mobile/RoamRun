import Network
import SwiftUI
import UIKit
import UserNotifications

private enum SavedField {
    static let far = "introducer.farAddress"
    static let peerName = "introducer.peerName"
}

/// One introduction at a time: what was asked for, how far it is, and how it ended.
@MainActor @Observable
final class Session {
    enum Kind { case xcode, control }
    /// The three steps the screen shows.
    enum Stage: Int, Comparable {
        case asking, pairing, finishing
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }
    struct Outcome: Equatable {
        enum Tone { case success, attention, failure }
        var tone: Tone
        var title: String
        var detail: String
        /// A line to take to the far Mac by hand.
        var line: String?
    }

    // What is asked for. `far` is kept between launches once it was introduced.
    var far = UserDefaults.standard.string(forKey: SavedField.far) ?? ""
    /// The lines carried by hand, for a far Mac that can't be asked.
    var byLine = false
    /// Not kept: each press of Pair Nearby Device makes another.
    var offerLine = ""
    var peerName = UserDefaults.standard.string(forKey: SavedField.peerName) ?? "" {
        didSet { UserDefaults.standard.set(peerName, forKey: SavedField.peerName) }
    }

    private(set) var running = false
    private(set) var kind = Kind.xcode
    private(set) var stage = Stage.asking
    /// The name Settings lists the far Mac under.
    private(set) var announcedName = ""
    private(set) var code: String?
    /// A second line under the step in hand.
    private(set) var hint: String?
    /// iOS gives this build about 30 seconds in the background, no more: said for as long as it runs.
    private(set) var limited = false
    private(set) var outcome: Outcome?
    /// Said on the first screen: what a code held, or what is wrong with what was entered.
    var notice: String?
    private(set) var log: [String] = []

    private var wire: Wire?
    private var standIn: StandIn?
    private var finder: DeviceFinder?
    private let keeper = BackgroundKeeper()
    /// Which introduction a late answer belongs to: one from an earlier one is dropped.
    private var run = 0
    /// The far Mac's name as it was at the tap, whatever the field holds later.
    private var host = ""
    /// The far Mac has begun on its side: only then is it told why this ends.
    private var begun = false
    private var carried = false
    private var announced = false
    /// This iPhone's Tailscale name, once the far Mac said it.
    private var ownName: String?

    /// The name's first label when it is a name; the address itself otherwise.
    static func label(_ host: String) -> String { Wire.label(host) }
    var name: String { Self.label(running || outcome != nil ? host : far.trimmingCharacters(in: .whitespaces)) }

    /// A far Mac is named as Tailscale names it: one word, a name under ts.net, or an address of Tailscale's.
    nonisolated static func hostProblem(_ host: String) -> String? {
        if host.isEmpty { return "Enter the far Mac's Tailscale name." }
        let other = "That isn't a Tailscale name: one word, or a name ending in .ts.net."
        if let address = IPv4Address(host) { return Wire.onTailnet(address.rawValue) ? nil : "That address isn't one Tailscale gives (100.64–100.127)." }
        // The far Mac listens on its IPv4 address alone.
        if IPv6Address(host) != nil || host.contains("%") || host.contains(":") { return "Give the far Mac's name, or its 100.x address: it isn't reached by an IPv6 address." }
        let lower = host.lowercased(), labels = lower.split(separator: ".", omittingEmptySubsequences: false)
        guard lower.utf8.count <= 253, labels.allSatisfy({ label in
            (1...63).contains(label.utf8.count) && !label.hasPrefix("-")
                && label.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
        }) else { return other }
        return labels.count == 1 || lower.hasSuffix(".ts.net") ? nil : other
    }

    /// The Tailscale name a line carries for this iPhone, by the far Mac's own rules for one.
    nonisolated static func peerProblem(_ peer: String) -> String? {
        return Wire.isPeerName(peer) ? nil : "Enter this iPhone's Tailscale name (as the Tailscale app shows it): the far Mac finds it by that."
    }

    /// From the code `roamrun pair xcode --qr` shows: the far Mac's name — and, without `--with`
    /// there, its offer to carry by hand. Nothing starts, and nothing is kept, until Introduce is tapped.
    @discardableResult
    func open(_ url: URL) -> Bool {
        // Nothing is opened over a line still to be carried: it can't be had again.
        guard !running, outcome?.line == nil else { return false }
        guard url.scheme == "roamrun-introducer", let host = url.host() else { notice = "That code isn't one from roamrun."; return false }
        if let problem = Self.hostProblem(host) { notice = "That code names “\(host)”. \(problem)"; return false }
        var line: String?
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, !items.isEmpty {
            let given = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
            let names = ["i": "identifier", "a": "authTag", "m": "model", "n": "name", "f": "flags", "v": "ver", "w": "minVer"]
            let txt = Dictionary(uniqueKeysWithValues: names.compactMap { short, long in given[short].map { (long, $0) } })
            let made = Introduction.line(Introduction.Offer(port: UInt16(given["p"] ?? "") ?? 0, txt: txt))
            guard case .success = Introduction.offer(from: made) else { notice = "That code's offer isn't one this app takes."; return false }
            line = made
        }
        outcome = nil
        far = host
        byLine = line != nil
        offerLine = line ?? ""
        notice = line == nil ? "Read from the code. Introduce when it is the Mac you mean." : "Read from the code, with its offer. Introduce when it is the Mac you mean."
        return true
    }

    func introduce() {
        guard !running else { return }
        let host = far.trimmingCharacters(in: .whitespaces)
        if let problem = Self.hostProblem(host) { notice = problem; return }
        var pasted: Introduction.Offer?
        if byLine {
            switch Introduction.offer(from: offerLine) {
            case .success(let read): pasted = read
            case .failure(.another(let what)): notice = "That line is \(what), not a Mac's offer to pair."; return
            case .failure(.notOne): notice = "That isn't a line from `roamrun pair xcode`."; return
            case .failure(.refused(let why)): notice = "That offer isn't taken: \(why)."; return
            }
            if let problem = Self.peerProblem(peerName.trimmingCharacters(in: .whitespaces)) { notice = problem; return }
        }
        UserDefaults.standard.set(host, forKey: SavedField.far)
        run += 1
        let run = run
        self.host = host
        running = true
        kind = .xcode
        stage = .asking
        code = nil; hint = nil; limited = false; outcome = nil; notice = nil; log = []
        begun = false; carried = false; announced = false; ownName = nil
        keeper.onExpire = { [weak self] in self?.expired(run) }
        keeper.onLimited = { [weak self] in
            guard let self, self.live(run) else { return }
            self.limited = true
        }
        keeper.begin(title: "Introducing \(name)", subtitle: "Asking \(name) for its offer", total: 620)
        if keeper.limited { keeper.onLimited?() }
        // Looking already: device control is asked which device this is before anything is offered.
        let finder = DeviceFinder()
        finder.start()
        self.finder = finder
        // Nothing is asked of the far Mac before this app may announce: the first run's prompt may take
        // the person a while, and the far Mac's patience begins with the question.
        let offer = pasted
        // Unanswered after a moment, it is iOS's question that is waited on: said, so the wait isn't a mystery.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.live(run), self.stage == .asking, self.wire == nil, self.standIn == nil else { return }
            self.hint = "Waiting for Local Network access: allow it when iOS asks, or in Settings › Apps › RoamRun."
        }
        finder.allowed { [weak self] allowed in
            Task { @MainActor in
                guard let self, self.live(run) else { return }
                self.hint = nil
                guard allowed else { self.finish(Self.noLocalNetwork); return }
                if let offer { self.start(offer, run); return }
                self.note("Asking \(host) for its offer.")
                let wire = Wire(farHost: host)
                self.wire = wire
                wire.fetch { [weak self] answer in Task { @MainActor in self?.fetched(answer, run) } }
            }
        }
    }

    func stop() {
        guard running else { return }
        if let standIn { standIn.end(.stopped) } else { finish(nil, saying: "stopped") }
    }

    /// Back to the first screen.
    func dismiss() { outcome = nil }

    private func live(_ run: Int) -> Bool { running && run == self.run }
    private func note(_ text: String) { log.append(text) }

    private func expired(_ run: Int) {
        guard live(run) else { return }
        if let standIn { standIn.end(.expired) } else {
            finish(.init(tone: .failure, title: "iOS stopped it in the background", detail: "Nothing is announced any more. Introduce again, and keep to Settings and this app meanwhile."), saying: "stopped")
        }
    }

    private func fetched(_ answer: Wire.Answer, _ run: Int) {
        // Its name is taken whenever it arrives: nothing waits on it, and the offer may be handled first.
        if case .you(let name) = answer {
            guard live(run) else { return }
            ownName = name
            // Kept for the lines carried by hand too: there it would have to be typed.
            if peerName.trimmingCharacters(in: .whitespaces).isEmpty { peerName = name }
            return
        }
        guard live(run), standIn == nil else { return }
        switch answer {
        case .offer(let line):
            guard case .success(let offer) = Introduction.offer(from: line) else {
                begun = true
                finish(.init(tone: .failure, title: "\(name) sent an offer this app doesn't take", detail: "Is RoamRun there a newer version than this app knows?"), saying: "offer-refused")
                return
            }
            begun = true
            start(offer, run)
        case .wantDevice:
            kind = .control
            hint = "Looking for this iPhone's own announcement…"
            note("\(name) asks which device this is: it pairs for device control.")
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) }
            finder?.line(name: UIDevice.current.name, peer: Wire.unnamedPeer) { [weak self] found in Task { @MainActor in self?.answerDevice(found, run) } }
        case .ended(let why): finish(.init(tone: .failure, title: "\(name) isn't offering to pair", detail: "\(name) \(Wire.sentence(ended: why))"))
        case .notWaiting:
            finish(.init(tone: .failure, title: "\(name) isn't waiting for this iPhone",
                         detail: "Run this there first, then Introduce again:\nroamrun pair xcode --with <this iPhone> --qr\n(or pair control, for device control)"))
        case .turnedAway:
            finish(.init(tone: .failure, title: "\(name) turned this iPhone away",
                         detail: "It answers only the device named after --with. Is that this iPhone's Tailscale name, as the Tailscale app shows it?"))
        case .unreached(let why):
            finish(.init(tone: .failure, title: "Couldn't reach \(name)", detail: "\(why.prefix(200)). Is Tailscale connected on this iPhone, and is “\(host)” the far Mac's Tailscale name?"))
        case .none(let why):
            finish(.init(tone: .failure, title: "\(name) gave no offer", detail: "\(why.prefix(200)). Is Pair Nearby Device waiting there, and is RoamRun there the version this app goes with?"))
        default: finish(.init(tone: .failure, title: "\(name) answered out of turn", detail: "Is RoamRun there the version this app goes with?"))
        }
    }

    private func answerDevice(_ found: DeviceFinder.Found, _ run: Int) {
        guard live(run), kind == .control, standIn == nil, !begun else { return }
        hint = nil
        switch found {
        case .line(let line):
            begun = true
            wire?.device(line) { [weak self] answer in Task { @MainActor in self?.controlSaid(answer, run) } }
        case .notSeen:
            finish(.init(tone: .failure, title: "This iPhone isn't announcing itself", detail: "It does once it is paired with a Mac. Pair Xcode first (roamrun pair xcode --with <this iPhone> on \(name)), then this."))
        case .denied: finish(Self.noLocalNetwork)
        case .refused(let why): finish(.init(tone: .failure, title: "This iPhone's announcement can't be carried", detail: "\(why)."))
        }
    }

    private static let noLocalNetwork = Outcome(tone: .failure, title: "Local Network access is off",
                                                detail: "This app announces the far Mac on this iPhone's own network. Allow it in Settings › Apps › RoamRun, then Introduce again.")

    private func controlSaid(_ answer: Wire.Answer, _ run: Int) {
        guard live(run), kind == .control else { return }
        switch answer {
        // What it kept is the end of it, whatever was carried or not.
        case .done, .failed: carried = false
        default: break
        }
        switch answer {
        case .offer(let line):
            guard standIn == nil, !carried, case .success(let offer) = Introduction.offer(from: line) else {
                finish(.init(tone: .failure, title: "\(name) sent an offer this app doesn't take", detail: "Is RoamRun there a newer version than this app knows?"), saying: "offer-refused")
                return
            }
            start(offer, run)
        case .attempt: break
        case .code(let digits):
            code = digits
            hint = nil
            note("The code arrived.")
            keeper.show("Code: \(digits)")
            let content = UNMutableNotificationContent()
            content.title = "Code: \(digits)"
            content.body = "Type it in Settings to pair with \(name)."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "introducer.code", content: content, trigger: nil))
        case .done(let on):
            finish(.init(tone: .success, title: "\(name) can operate this iPhone",
                         detail: on ? "Device control is paired and switched on there. Try, on \(name): roamrun look"
                                    : "Device control is paired, and switched off there: switch it on in the RoamRun app on \(name)."))
        case .failed(let why): finish(.init(tone: .failure, title: "Not paired for device control", detail: "\(name) \(Wire.sentence(failed: why))"))
        case .ended(let why): finish(.init(tone: .failure, title: "\(name) stopped", detail: "\(name) \(Wire.sentence(ended: why))"))
        case .none(let why) where stage == .asking, .unreached(let why) where stage == .asking:
            // Before its offer: nothing had begun there.
            finish(.init(tone: .failure, title: "\(name) didn't go on", detail: "\(why.prefix(200)). Nothing was begun there: Introduce again."))
        case .turnedAway:
            finish(.init(tone: .failure, title: "\(name) didn't go on", detail: "It closed the connection. Nothing was begun there: Introduce again."))
        case .none(let why), .unreached(let why):
            finish(.init(tone: .attention, title: "Lost \(name) before it said what it kept", detail: "\(why.prefix(200)). On \(name):\nroamrun pair control --last"))
        default: finish(.init(tone: .failure, title: "\(name) answered out of turn", detail: "Is RoamRun there the version this app goes with?"))
        }
    }

    private func start(_ offer: Introduction.Offer, _ run: Int) {
        let shown = Wire.announced(offer, for: host)
        announcedName = shown.txt["name"] ?? name
        stage = .pairing
        hint = nil
        keeper.phase(title: "Pair with \(announcedName)", subtitle: "Settings › Privacy & Security › Developer Mode", total: 300)
        let standIn = StandIn(offer: shown, farHost: host) { [weak self] event in
            Task { @MainActor in self?.handle(event, run) }
        }
        self.standIn = standIn
        do { try standIn.start() } catch {
            finish(.init(tone: .failure, title: "Couldn't listen on this iPhone", detail: "\(error.localizedDescription.prefix(200))"), saying: "failed")
            return
        }
        // A record that doesn't get announced says nothing by itself.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.live(run), !self.announced, self.standIn === standIn else { return }
            standIn.end(.announcementLost("nothing was announced in 20 seconds"))
        }
    }

    private func handle(_ event: StandIn.Event, _ run: Int) {
        guard live(run) else { return }
        switch event {
        case .announced:
            announced = true
            note("Announced as “\(announcedName)”.")
        case .connected(let from):
            note("A device connected from \(from).")
            hint = kind == .control ? "Connected. The code is on its way." : "Connected. Type the code Device Hub shows on \(name)."
        case .refused(let from): note("Refused a connection from \(from): not this device.")
        case .farDidNotAnswer(let why):
            note("\(name) didn't take it (\(why)).")
            hint = "\(name) didn't take the connection. Still announced: try Pair with “\(announcedName)” again."
        case .ended(let end):
            guard standIn != nil else { return }
            standIn = nil
            switch end {
            case .carried:
                carried = true
                stage = .finishing
                hint = nil
                code = nil
                note("A pairing was tried.")
                keeper.phase(title: "Finishing with \(name)", subtitle: kind == .control ? "\(name) says what it kept" : "Telling \(name) about this iPhone", total: 120)
                if kind == .control { return }
                // The keeper stays until the far Mac has it: iOS would suspend the app mid-way otherwise.
                // Asked by wire, the far Mac names the device and knows its Tailscale name itself.
                finder?.line(name: wire == nil ? UIDevice.current.name : ownName.map(Wire.label) ?? UIDevice.current.name,
                             peer: wire == nil ? peerName.trimmingCharacters(in: .whitespaces) : ownName ?? Wire.unnamedPeer) { [weak self] found in
                    Task { @MainActor in self?.found(found, run) }
                }
            case .deadline: finish(.init(tone: .failure, title: "Nothing was paired in 5 minutes", detail: "Introduce again when the far Mac is ready, and pick “\(announcedName)” in Settings › Privacy & Security › Developer Mode."), saying: "deadline")
            case .stopped: finish(nil, saying: "stopped")
            case .expired: finish(.init(tone: .failure, title: "iOS stopped it in the background", detail: "Nothing is announced any more. Introduce again, and keep to Settings and this app meanwhile."), saying: "stopped")
            case .announcementLost(let why):
                finish(why.contains("Local Network") ? Self.noLocalNetwork : .init(tone: .failure, title: "Couldn't announce on this network", detail: "\(why.prefix(200))."), saying: "announcement-lost")
            }
        }
    }

    private func found(_ found: DeviceFinder.Found, _ run: Int) {
        guard live(run), carried else { return }
        switch found {
        case .line(let line):
            guard let wire else {
                finish(.init(tone: .attention, title: "A pairing was tried", detail: "Whether it was made shows on \(name). Take this line there:\nroamrun devices add <line>\nthen roamrun up", line: line))
                return
            }
            wire.tried(line) { [weak self] answer in Task { @MainActor in self?.told(answer, line, run) } }
        case .notSeen:
            finish(.init(tone: .attention, title: "A pairing was tried", detail: "This iPhone's own announcement wasn't seen here, so \(name) wasn't told which device it is. On \(name): roamrun devices — if this iPhone is saved there, roamrun up <its name>."))
        case .denied: finish(Self.noLocalNetwork)
        case .refused(let why): finish(.init(tone: .attention, title: "A pairing was tried", detail: "This iPhone's announcement can't be carried (\(why)), so \(name) wasn't told which device it is."))
        }
    }

    private func told(_ answer: Wire.Answer, _ line: String, _ run: Int) {
        guard live(run), carried else { return }
        switch answer {
        case .saved: finish(.init(tone: .success, title: "\(name) knows this iPhone", detail: "Whether Xcode paired shows there. Next, on \(name): roamrun up, with the name it just printed."))
        case .unsaved: finish(.init(tone: .attention, title: "\(name) didn't save this iPhone", detail: "Its terminal says why, and how to save it by hand."), farsWord: true)
        default:
            finish(.init(tone: .attention, title: "\(name) didn't say whether it saved this iPhone", detail: "If it didn't, take this line there:\nroamrun devices add <line>" + (ownName == nil ? " --peer <this iPhone's Tailscale name>" : ""), line: line))
        }
    }

    /// Everything of this introduction is over. The far Mac is told why only while that means
    /// something to it: once it has begun, and before a pairing was carried to it.
    private func finish(_ given: Outcome?, saying reason: String? = nil, farsWord: Bool = false) {
        guard running else { return }
        running = false
        var outcome = given
        // After a pairing was carried, whatever ends this isn't "nothing happened": it may have been made.
        if Wire.saidAsTried(carried: carried, success: outcome?.tone == .success, line: outcome?.line != nil, title: outcome?.title, farsWord: farsWord) {
            let why = outcome.map { "\($0.title). " } ?? "Stopped. "
            outcome = .init(tone: .attention, title: "A pairing was tried",
                            detail: why + "Whether it was made shows on \(name):\n" + (kind == .control ? "roamrun pair control --last" : "roamrun devices"))
        }
        self.outcome = outcome
        if outcome == nil { notice = "Stopped. Nothing is announced any more." }
        wire?.end(begun && !carried ? reason : nil)
        wire = nil
        let ending = standIn
        standIn = nil
        ending?.end(.stopped)
        keeper.finish()
        finder?.stop()
        finder = nil
        code = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["introducer.code"])
    }

    #if DEBUG
    /// For looking at a screen without a far Mac: INTRODUCER_PREVIEW=pairing|code|finishing|done|byhand|failed.
    func preview(_ what: String) {
        far = "rr-cloud.tailnet-966e.ts.net"; host = far; announcedName = "rr-cloud"
        log = ["Asking rr-cloud.tailnet-966e.ts.net for its offer.", "Announced as “rr-cloud”.", "A device connected from 192.168.0.19:65442."]
        switch what {
        case "asking": running = true; stage = .asking
        case "pairing": running = true; stage = .pairing; hint = "Connected. Type the code Device Hub shows on rr-cloud."
        case "code": running = true; kind = .control; stage = .pairing; code = "456640"
        case "finishing": running = true; stage = .finishing
        case "done": outcome = .init(tone: .success, title: "rr-cloud knows this iPhone", detail: "Whether Xcode paired shows there. Next, on rr-cloud: roamrun up, with the name it just printed.")
        case "byhand": outcome = .init(tone: .attention, title: "A pairing was tried", detail: "Whether it was made shows on rr-cloud. Take this line there:\nroamrun devices add <line>\nthen roamrun up", line: "rr-device-v1:eyJuYW1lIjoiaVBob25lIiwicGVlciI6ImlwaG9uZS0xNS1wcm8iLCJwb3J0Ijo0OTE1MiwidHh0Ijp7ImF1dGhUYWciOiJZOXdYV21kaCJ9fQ")
        case "failed": outcome = .init(tone: .failure, title: "rr-cloud isn't waiting for this iPhone", detail: "Run this there first, then Introduce again:\nroamrun pair xcode --with <this iPhone> --qr\n(or pair control, for device control)")
        case "empty": far = ""
        default: break
        }
    }
    #endif
}
