import AppKit
import Foundation
import os

extension CLI {
    /// A saved device as another Mac can be told of it, or why it can't be.
    private static func handover(of profile: DeviceProfile) -> Introduction.Device {
        guard profile.providerID == MeshProvider.tailscale.rawValue else {
            stop(
                "\(profile.displayName) is saved by its address, not as a Tailscale device, so another Mac can't be told which device it is: remove it and add it again on its Wi‑Fi, choosing its Tailscale device"
            )
        }
        guard let device = Introduction.device(of: profile) else {
            stop(
                "what is saved of \(profile.displayName)'s announcement isn't whole: remove it and add it again on its Wi‑Fi first"
            )
        }
        return device
    }

    /// `devices export`: the line alone on stdout, what to do with it on stderr.
    static func exportDevice(_ profile: DeviceProfile) -> Never {
        let device = handover(of: profile)
        print(Introduction.line(device))
        note(
            "On the other Mac: roamrun devices add <that line>   (no key is in it; it names the device \(device.peer) on your tailnet)"
        )
        exit(0)
    }

    /// `devices add`: where the device is comes from this Mac's own Tailscale, never from the line.
    static func addDevice(line: String, name: String?, replacing: String?, peer: String?,
                          store: ProfileStore) -> Never
    {
        do { try saveDevice(line: line, name: name, replacing: replacing, peer: peer, store: store) } catch {
            error.happened ? stop(error.why) : fail(error.why)
        }
        exit(0)
    }

    private struct Refusal: Error {
        let why: String
        /// Not a mistake in the command, but how things are (exit 1, not 2).
        let happened: Bool
        init(_ why: String, happened: Bool = false) {
            self.why = why
            self.happened = happened
        }
    }

    /// A device's line read, and the device found on this Mac's own tailnet.
    private static func found(line: String, peer: String?) throws(Refusal) -> (Introduction.Device, MeshDevice) {
        let device: Introduction.Device
        switch Introduction.device(from: line) {
        case .success(let d): device = d
        case .failure(.another(let what)): throw Refusal("that is \(what), not a saved device")
        case .failure(.notOne): throw Refusal(
                "that isn't a line from `roamrun devices export` or `roamrun pair introduce`"
            )
        case .failure(.refused(let why)): throw Refusal("not taken: \(why)")
        }
        let mesh: TailscaleClient.Mesh
        do { mesh = try TailscaleClient.fromSettings().mesh() } catch { throw Refusal(
            "Tailscale on this Mac couldn't be asked: \(error.localizedDescription)",
            happened: true
        ) }
        let wanted = peer ?? device.peer
        let found: MeshDevice
        switch TailscaleClient.peer(named: wanted, in: mesh) {
        case .one(let p): found = p
        case .none: throw Refusal(
                "no device named \(shellName(wanted)) on this Mac's tailnet. If it has another name here, say which: --peer <Tailscale name>"
            )
        case .several(let names): throw Refusal(
                "\(shellName(wanted)) names more than one device here (\(names.joined(separator: ", "))): say which with --peer <whole Tailscale name>"
            )
        }
        // What Tailscale's client on it says it is: turns a wrong name away, and is no proof of what it is.
        guard ["ios", "ipados", "visionos"].contains(found.os.lowercased()) else {
            throw Refusal(
                "\(found.dnsName) is a \(found.os.isEmpty ? "device of another kind" : found.os) device, not an iPhone, iPad or Apple Vision Pro: --peer <Tailscale name> names the right one"
            )
        }
        return (device, found)
    }

    private static func saveDevice(
        line: String,
        name: String?,
        replacing: String?,
        peer: String?,
        store: ProfileStore
    ) throws(Refusal) {
        let (device, found) = try Self.found(line: line, peer: peer)
        let saved = store.load()
        var change: (inout [DeviceProfile]) -> Void
        let called: String
        var added = Introduction.Added.added, replaced = Introduction.Replaced.replaced
        if let replacing {
            guard let old = find(replacing, in: saved)
            else { throw Refusal("no device named \(shellName(replacing)). " + names(saved)) }
            if StatusFile.read()[old.id] != nil {
                throw Refusal(
                    "\(old.displayName)'s bridge is running: `roamrun down \(shellName(old.displayName))` first",
                    happened: true
                )
            }
            if !NSRunningApplication.runningApplications(withBundleIdentifier: AppID.bundle)
                .filter({
                    $0.processIdentifier != getpid()
                })
                .isEmpty
            {
                throw Refusal(
                    "the RoamRun app is running on this Mac. Quit it (its menu bar icon › Quit RoamRun), then run this again: while it runs it would put back its older copy of \(old.displayName)",
                    happened: true
                )
            }
            guard let new = Introduction.profile(from: device, peer: found, name: old.displayName) else { throw Refusal(
                "\(found.dnsName) has no IPv4 address on the tailnet",
                happened: true
            ) }
            called = old.displayName
            change = {
                replaced = Introduction.replace(old.id, with: new, in: &$0)
            }
        } else {
            let wantedName = (name ?? device.name).trimmingCharacters(in: .whitespaces)
            guard let new = Introduction.profile(from: device, peer: found, name: wantedName) else { throw Refusal(
                "\(found.dnsName) has no IPv4 address on the tailnet",
                happened: true
            ) }
            called = wantedName
            change = {
                added = Introduction.add(new, from: device, to: &$0, renewing: peer == nil)
            }
        }
        guard store.update(change) else { throw Refusal(
            "couldn't write \(ProfileStore.directory.path)/profiles.json",
            happened: true
        ) }
        switch replaced {
        case .replaced: break
        case .gone: throw Refusal("\(called) was removed while this ran: nothing was changed", happened: true)
        case .already(let name): throw Refusal(
                "that line is for the device saved as \(name), not \(called): nothing was changed. To put it in \(name)'s place: --replace \(shellName(name))"
            )
        }
        switch added {
        case .added: break
        case .unchanged(let name):
            // Paired again with nothing moved: there is nothing to put in its place.
            print("\(name) is saved already, and this changes nothing in it. Next: roamrun up \(shellName(name))")
            return
        case .renewed(let name):
            let inUse = StatusFile.read()[saved.first {
                $0.displayName == name
            }?.id ?? UUID()] != nil
                || !NSRunningApplication.runningApplications(withBundleIdentifier: AppID.bundle)
                .filter({
                    $0.processIdentifier != getpid()
                })
                .isEmpty
            print("\(name) is saved already; it now holds that line's announcement. Next: roamrun up \(shellName(name))"
                +
                (inUse ?
                    " (what runs here now — the app, or its bridge — goes on with the older one until it is started again)" :
                    ""))
            return
        case .already(let name): throw Refusal(
                "\(name) is that device already. To put this in its place: --replace \(shellName(name))"
            )
        case .nameProblem(let problem): throw Refusal("\(problem) Give it one: --as <name>")
        }
        note(
            "\(called): \(found.dnsName) (\(found.ipv4 ?? "")), port \(device.port), announced as \(device.txt["identifier"] ?? "")"
        )
        print(replacing != nil
            ? "\(called) now has that announcement and address; its UDID is as it was (this is for the same device: another one is added under a name of its own). Next: roamrun up \(shellName(called))"
            :
            "\(called) is saved, without a UDID: the bridge learns it from this Mac's own pairing. Next: roamrun up \(shellName(called))")
        note(
            "(no need to open the RoamRun app for this; it lists \(called) when it is next opened, or in a moment if it is open)"
        )
    }

    /// The offers to pair this Mac makes right now: announced by it, and listened for here.
    private static func ownOffers(_ capture: BonjourCapture) -> [CapturedService] {
        Introduction.ownOffers(
            among: Array(capture.services.values),
            ownIPs: Set(InterfaceMonitor.ipv4Addresses().values)
        )
        .filter {
            TailscaleClient.listening(on: $0.port)
        }
    }

    /// A Mac named on the command line, as this Mac's Tailscale has it.
    private static func mac(named name: String) -> (TailscaleClient.Mesh, MeshDevice, String) {
        let mesh: TailscaleClient.Mesh
        do { mesh = try TailscaleClient.fromSettings().mesh() } catch {
            stop("Tailscale on this Mac couldn't be asked: \(error.localizedDescription)")
        }
        switch TailscaleClient.peer(named: name, in: mesh) {
        case .one(let p):
            guard let ip = p.ipv4 else { stop("\(p.dnsName) has no IPv4 address on the tailnet") }
            return (mesh, p, ip)
        case .none: fail(
                "nothing named \(shellName(name)) on this Mac's tailnet (its Tailscale name; one of another tailnet by its whole name)"
            )
        case .several(let names): fail(
                "\(shellName(name)) names more than one (\(names.joined(separator: ", "))): give the whole Tailscale name"
            )
        }
    }

    /// What `--with` and `pair introduce` without a line hold the other Mac to, and this Mac's way to it.
    /// `also`: what else than a Mac may be the one named, by the OS Tailscale gives for it — the device
    /// itself (the app on it introduces this Mac), a Windows or Linux machine (roamrunctl does). That only
    /// turns a wrong name away sooner: whose the connection is, is held to the id and address below.
    /// `holds`: the one named is to hold the pairing (this Mac introduces), which a Linux or Windows machine with roamrunctl can too.
    private static func byName(
        _ mesh: TailscaleClient.Mesh,
        _ other: MeshDevice,
        _ ip: String,
        also: Set<String> = [],
        holds: Bool = false
    ) -> (PairByName.Peer, own: String, interface: String) {
        guard other.os.lowercased() == "macos" || also.contains(other.os.lowercased()) else {
            fail("\(other.dnsName) is a \(other.os.isEmpty ? "device of another kind" : other.os) device, "
                + (holds ? "not one that can hold a pairing (a Mac, or a Linux or Windows machine with roamrunctl)"
                    : also
                    .isEmpty ? "not a Mac" :
                    "not one that introduces here (a Mac, the device itself\(also.contains("linux") ? ", or a Windows or Linux machine with roamrunctl" : ""))"))
        }
        guard let id = other.stableID
        else {
            stop(
                "Tailscale gives no lasting id for \(other.dnsName), so it can't be held to being that one: carry the lines instead (`roamrun pair xcode` alone prints the first)"
            )
        }
        guard let own = mesh.ownIPs.first(where: {
                  $0.contains(".")
              }),
              let interface = InterfaceMonitor.ipv4Addresses()
                  .first(where: {
                      $0.value == own
                  })?.key
        else {
            stop("this Mac's Tailscale address isn't on any of its interfaces: is Tailscale connected?")
        }
        return (PairByName.Peer(ip: ip, id: id), own, interface)
    }

    /// `itself`: the one named is the device, whose app introduces — it has no terminal and no command.
    private static func sentence(_ why: PairWire.Reason, other: String, itself: Bool = false) -> String {
        switch why {
        case .offerRefused: "\(other) didn't take this Mac's offer: press Pair Nearby Device again, and \(itself ? "run this again and Introduce in its app" : "run both commands again")"
        case .unreachable: "\(other) couldn't reach this Mac's pairing port: press Pair Nearby Device again, or see whether Tailscale's rules let it in"
        case .ambiguous: "\(other) offers to pair more than once, and which offer is the current one can't be told: there, close Device Hub's sheet, press Pair Nearby Device again, and run both commands again"
        case .noOffer: "\(other) made no offer to pair in the time it waits: there, Device Hub: + › Pair Nearby Device, and run both commands again"
        case .deadline: "nothing was paired in 5 minutes on \(other)"
        case .stopped: "it was stopped on \(other) before a pairing was tried"
        case .addressLost: "\(other)'s address on the device's Wi‑Fi changed, so it stopped"
        case .announcementLost: "\(other)'s announcement or its listener failed"
        case .noLine: "a pairing was tried, but \(other) didn't see the device's own announcement, so it has no line to save the device from. Whether the pairing was made shows in Device Hub here; if the device isn't saved here yet (`roamrun devices`), add it with `roamrun devices add` and a line from a Mac that has it"
        case .failed: "\(other) couldn't start standing in: \(itself ? "its app" : "its own terminal") says why"
        }
    }

    private static func sentence(_ why: PairWire.Refusal, other: String, device: String) -> String {
        switch why {
        case .exists: "\(other) already holds a pairing for \(device): there, remove it first (the RoamRun app, on the device's page), then run both commands again"
        case .cancelled: "it was stopped on \(other); nothing was kept there"
        case .anotherDevice: "the device that paired isn't \(device) as \(other) has it saved; nothing was kept there. Remove the pairing just made on the device (Settings › Privacy & Security › Developer Mode)"
        case .notPaired: "the pairing wasn't completed on \(device) (a wrong code, refused there, or not in time); nothing was kept on \(other). Run this again: \(other) goes on waiting for it (if its command has ended, run that again first)"
        case .notKept: "\(device) paired, but \(other) couldn't keep the pairing (it says why). Remove the pairing just made on the device (Settings › Privacy & Security › Developer Mode)"
        case .noApp: "the RoamRun app isn't running on \(other): it makes and keeps the pairing. Open it there and run both commands again"
        case .failed: "it failed on \(other) (it says why there); nothing was kept there. Run both commands again"
        }
    }

    /// One question to the app, answered or not: a command that waits on another Mac doesn't end on it.
    nonisolated private static func asked(
        _ op: String,
        _ attempt: UUID,
        text: String? = nil,
        address: String? = nil,
        interface: String? = nil,
        peer: String? = nil
    ) -> DeviceControlWire.Response? {
        try? DeviceControlWire.ask(
            .init(op: op, device: attempt, text: text, address: address, interface: interface, peer: peer),
            in: ProfileStore.directory
        )
    }

    nonisolated private static func status(of r: DeviceControlWire.Response?) -> PairByName.FarControl.Status {
        switch r?.state {
        case "waiting": .waiting
        case "code": r?.code.map(PairByName.FarControl.Status.code) ?? .waiting
        case "checking": .checking
        case "done": .done(on: r?.allowed == true)
        case "failed": .failed(r?.reason.flatMap(PairWire.Refusal.init(rawValue:)) ?? .failed)
        default: .unknown
        }
    }

    /// Another `roamrun pair … --with` among the processes `pgrep -fl -- --with` lists: its pid and
    /// what it was run as. nil when there is none but this one.
    nonisolated static func otherWaiting(inPgrep out: String, me: Int32) -> (pid: Int32, command: String)? {
        for line in out.split(separator: "\n") {
            let words = line.split(separator: " ")
            guard let pid = words.first.flatMap({
                Int32($0)
            }), pid != me,
                  let pair = words.firstIndex(of: "pair"), words.count > pair + 1,
                  ["xcode", "control"].contains(words[pair + 1]),
                  words[pair - 1].lowercased().hasSuffix("roamrun") else { continue }
            return (pid, "roamrun " + words[pair...].joined(separator: " "))
        }
        return nil
    }

    /// The port both `--with` commands wait on is taken: by which, and what to do about it.
    private static func taken(waitingFor other: String, _ error: Error) -> String {
        let listed = Proc.run("/usr/bin/pgrep", ["-fl", "--", "--with"], timeout: 5).out
        guard let found = otherWaiting(inPgrep: listed, me: getpid()) else {
            return "couldn't listen for \(other) (\(error.localizedDescription)): another program on this Mac has port \(PairWire.port) on its Tailscale address."
        }
        return "another `\(found.command)` is waiting on this Mac (process \(found.pid)), and only one can at a time. It ends by itself once it has waited its time out (ten minutes for the one it names); to stop it now: kill -INT \(found.pid)"
    }

    /// `pair control --attempt` / `--last`: what the app made of an attempt, while it remembers.
    static func controlAttempt(_ id: String?) -> Never {
        let attempt: UUID
        if let id {
            guard let read = UUID(uuidString: id) else { fail("that isn't an attempt's id") }
            attempt = read
        } else {
            attempt = UUID()
        }
        let r = askApp(.init(op: "pair-status", device: attempt, text: id == nil ? "last" : nil))
        switch status(of: r) {
        case .done(let on):
            print("\(r.name ?? "The device") is paired for device control here" +
                (on ? ", and switched on. Try: roamrun look \(r.name.map(shellName) ?? "<name>")" :
                    "; it is switched off: switch it on in the RoamRun app, on the device's page."))
            exit(0)
        case .failed: stop("that attempt kept nothing: \(r.error ?? r.reason ?? "it failed")")
        case .waiting, .code: stop("that attempt is still waiting for the device")
        case .checking: stop("that attempt is being kept right now: ask again in a moment")
        case .unknown: stop(r
                .state == nil ? "the RoamRun app here is a build that can't be introduced to a device" :
                (r.error ?? "this RoamRun doesn't know that attempt") +
                ". Whether the device can be operated now: roamrun look <name>")
        }
    }

    /// `--qr`: this Mac's Tailscale name as a code, for the app on the device named — and with an
    /// offer, that too. The last thing said before waiting; a window it doesn't fit is said, not drawn in.
    nonisolated private static func drawCode(_ url: String?, for whom: String) {
        guard let url
        else { note("No code: Tailscale gives this Mac no name to put in one. Type the name in the app instead.")
            return
        }
        guard isatty(STDERR_FILENO) != 0
        else { note("No code is drawn where this isn't a terminal. For the app: \(url)")
            return
        }
        let lines = TerminalQR.lines(url, level: "L"), (across, down) = TerminalQR.room(for: lines)
        var window = winsize()
        if ioctl(STDERR_FILENO, TIOCGWINSZ, &window) == 0, window.ws_row > 0,
           Int(window.ws_row) < down || Int(window.ws_col) < across
        {
            note(
                "This window is too small for the code (\(across) across, \(down) down; it is \(window.ws_col) by \(window.ws_row)): make it larger or its text smaller, and run this again."
            )
            return
        }
        note("With \(whom)'s camera, or the app's own Scan — it takes this Mac's name from it:\n" + lines
            .joined(separator: "\n"))
    }

    /// `pair control --with`: the app here makes a pairing of its own for device control with a
    /// device the one Mac named introduces; this carries between the two. No code is shown here.
    static func offerControlPairing(with home: String, peer peerName: String?, qr: Bool = false) async -> Never {
        let (mesh, other, ip) = mac(named: home)
        let (peer, own, interface) = byName(mesh, other, ip, also: ["ios", "ipados", "linux", "windows"])
        // Named itself, the device is the one that connects: its Tailscale name is known, and names it here.
        let itself = ["ios", "ipados"].contains(other.os.lowercased())
        let label = other.dnsName.split(separator: ".").first.map(String.init)
        if qr,
           !itself
        {
            fail(
                "--qr is for a device named with --with, whose app reads the code: \(other.dnsName) is given this Mac's name as an argument"
            )
        }
        if itself,
           peerName != nil
        {
            fail("--peer says which device a Mac introduces; \(other.dnsName) is the device itself")
        }
        // Its name here is its Tailscale name: found taken before anything waits, not after the code was typed.
        if itself, let label, ProfileStore().load().contains(where: {
            $0.displayName.caseInsensitiveCompare(label) == .orderedSame && $0.providerIP != ip
        }) {
            stop(
                "another device is saved here as \(label), which is the name \(other.dnsName) would get: rename that one first (the RoamRun app, on its page)"
            )
        }
        // The app makes and keeps the pairing: found out before anything waits.
        if askApp(.init(op: "pair-status", device: UUID())).state == nil {
            stop("the RoamRun app here is a build that can't be introduced to a device: update it, then run this again")
        }
        let listener: PairLink.Listener
        do { listener = try PairLink.Listener(ip: own, port: PairWire.port, interface: interface) } catch {
            stop(taken(waitingFor: other.dnsName, error))
        }
        let halted = OSAllocatedUnfairLock(initialState: false)
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                halted.withLock {
                    $0 = true
                }
            }
            src.resume()
            keepAlive.append(src as AnyObject)
        }
        let whole = (try? TailscaleClient.fromSettings().selfDNSName()).flatMap {
            $0
        }
        let me = whole?.split(separator: ".").first.map(String.init) ?? "<this Mac's Tailscale name>"
        // What the one named runs: a Mac has RoamRun, another machine roamrunctl, which knows the device by its Tailscale name.
        let introduce = other.os.lowercased() == "macos" ? "roamrun pair introduce --host \(me) --to <device>"
            : "roamrunctl pair introduce --host \(me) --to <the device's Tailscale name>"
        // A Mac may have roamrunctl alone: Tailscale doesn't tell.
        let without = other.os
            .lowercased() == "macos" && !itself ?
            "\n    (a Mac without RoamRun:  roamrunctl pair introduce --host \(me) --to <the device's Tailscale name>)" :
            ""
        // Each try is an attempt of the app's own; the one under way, or last made, is what is asked about.
        let current = OSAllocatedUnfairLock(initialState: UUID())
        note("""
        Waiting for \(other.dnsName), 10 minutes at most; only \(itself ? "it" : other.os.lowercased() == "macos" ? "that Mac" : "that machine") is answered.
          There\(itself ? ":  the RoamRun Introducer app, far Mac “\(me)”, Introduce" : " (on the device's Wi‑Fi), run by a person:  \(introduce)\(without)")
          The code to type on the device shows there, not here.
        """)
        if Proc.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"], timeout: 5)
            .out
            .contains("enabled")
        {
            note(
                "This Mac's firewall is on. If \(other.dnsName) connects and nothing shows here, let RoamRun in: System Settings › Network › Firewall › Options."
            )
        }
        if qr {
            drawCode(whole.flatMap {
                Introduction.codeURL(mac: $0)
            }, for: other.dnsName)
        }
        let client = TailscaleClient.fromSettings()
        let said = OSAllocatedUnfairLock<String?>(initialState: nil), met = OSAllocatedUnfairLock(initialState: false)
        let waitedAgain = OSAllocatedUnfairLock(initialState: false)
        let far = PairByName.FarControl(
            peer: peer,
            owner: {
                client.owner(of: $0)
            },
            start: { line in
                // Found on this Mac's own tailnet, as `devices add` finds it: where it is isn't in the line.
                let made = await MainActor.run { () -> Result<DeviceProfile, Refusal> in
                    do throws(Refusal) {
                        let (device, found) = try Self.found(line: line, peer: itself ? other.dnsName : peerName)
                        guard let made = Introduction.profile(
                            from: device,
                            peer: found,
                            name: itself ? label ?? device.name : device.name
                        ) else { throw Refusal("\(found.dnsName) has no IPv4 address on the tailnet") }
                        return .success(made)
                    } catch { return .failure(error) }
                }
                let candidate: DeviceProfile
                switch made {
                case .success(let c): candidate = c
                case .failure(let why):
                    said.withLock {
                        $0 = why.why
                    }
                    return .refused(.failed)
                }
                let text = (try? JSONEncoder().encode(candidate)).map {
                    String(decoding: $0, as: UTF8.self)
                }
                let attempt = UUID()
                current.withLock {
                    $0 = attempt
                }
                said.withLock {
                    $0 = nil
                }
                guard let r = asked("pair-start", attempt, text: text, address: own, interface: interface,
                                    peer: peer.ip)
                else {
                    said.withLock {
                        $0 = "the RoamRun app here stopped answering"
                    }
                    return .refused(.noApp)
                }
                guard r.ok, let offer = r.offer else {
                    said.withLock {
                        $0 = r.error
                    }
                    return .refused(r.reason.flatMap(PairWire.Refusal.init(rawValue:)) ?? .failed)
                }
                return .offer(offer, attempt: attempt.uuidString)
            },
            status: { id in
                status(of: UUID(uuidString: id).flatMap {
                    asked("pair-status", $0)
                })
            },
            cancel: { id in
                _ = UUID(uuidString: id).map {
                    asked("pair-cancel", $0)
                }
            },
            stopped: {
                halted.withLock {
                    $0
                }
            },
            say: { event in
                switch event {
                case .refused(let from): note("Turned away a connection from \(from): it isn't \(other.dnsName).")
                case .unsure(let from): note(
                        "Turned away a connection from \(from): Tailscale couldn't say just then whether that is \(other.dnsName)."
                    )
                case .connected:
                    met.withLock {
                        $0 = true
                    }
                    note("\(other.dnsName) connected.")
                case .offerSent(let id): note(
                        "\(other.dnsName) has this Mac's offer and announces it to the device. Waiting for the device (9 minutes at most). Attempt \(id)."
                    )
                case .again:
                    waitedAgain.withLock {
                        $0 = true
                    }
                    note(
                        "The device came and the pairing wasn't made (a wrong code, or refused there); nothing was kept. Still waiting for \(other.dnsName), 10 minutes more: \(itself ? "in its app, Introduce again" : "there, run `\(introduce.split(separator: " ").first ?? "roamrun") pair introduce` again")."
                    )
                case .codeSent: note(
                        "The device asked to pair; its code is shown on \(other.dnsName)\(itself ? " itself" : "")."
                    )
                }
            }
        )
        let end = await Task.detached {
            await far.run(listener)
        }
        .value
        let again = itself ? "Run this again, and Introduce in its app" : "Run both commands again"
        let attempt = current.withLock {
            $0
        }
        let last = asked("pair-status", attempt)
        let more = said.withLock {
            $0
        } ?? last?.error
        switch end {
        case .done(let on):
            let name = last?.name ?? "The device"
            print("\(name) is paired for device control here" +
                (on ? ", and switched on. Try: roamrun look \(shellName(name))" : "."))
            if !on {
                note(
                    "It is switched off: the Keychain didn't keep the switch. Switch it on in the RoamRun app, on the device's page; the pairing is kept and needn't be made again."
                )
            }
            exit(0)
        case .failed(let why): stop(more ?? sentence(why, other: "this Mac", device: "the device"))
        case .ended(let why): stop(sentence(why, other: other.dnsName, itself: itself))
        case .lost(.checking):
            stop(
                "it ended here while the device's pairing was being kept: that goes on. `roamrun pair control --attempt \(attempt.uuidString)` says what came of it"
            )
        case .lost(.unknown):
            stop(
                "the RoamRun app here stopped answering, so what it kept, if anything, isn't known. Once it is open: `roamrun pair control --attempt \(attempt.uuidString)` (it remembers while it runs), or `roamrun look <name>`"
            )
        case .lost:
            stop("\(other.dnsName) went away. Nothing was kept here" + (more.map {
                " (\($0))"
            } ?? "") + ". \(again)")
        case .noResult: stop("the device didn't pair in time; nothing was kept here. \(again)")
        case .noOne where waitedAgain.withLock({
            $0
        }):
            stop(
                "the pairing wasn't made, and \(other.dnsName) didn't \(itself ? "Introduce" : "run its `pair introduce`") again in 10 minutes; nothing was kept here. \(again)"
            )
        case .noOne where met.withLock({
            $0
        }) && itself:
            stop(
                "\(other.dnsName) connected and didn't go on: its app didn't find the device's own announcement in time, or was stopped. \(again)"
            )
        case .noOne where met.withLock({
            $0
        }) && other.os.lowercased() != "macos":
            stop(
                "\(other.dnsName) connected and didn't go on: its roamrunctl says why (it has to see the device's own announcement on its LAN, which a device no Mac has paired with doesn't make). Then run both commands again"
            )
        case .noOne where met.withLock({
            $0
        }):
            stop(
                "\(other.dnsName) connected and didn't go on: is RoamRun there a version that knows `pair control`? Update it, then run both commands again (with roamrunctl there: it says why)"
            )
        case .noOne where itself:
            stop(
                "\(other.dnsName) didn't connect in 10 minutes. Was Introduce tapped in its app with this Mac's name (\(me)), and do Tailscale's rules and this Mac's firewall let it reach port \(PairWire.port) here?"
            )
        case .noOne: stop(
                "\(other.dnsName) didn't connect in 10 minutes. Is `\(introduce)` running there, and do Tailscale's rules and this Mac's firewall let it reach port \(PairWire.port) here?"
            )
        case .stopped: stop("stopped; nothing was kept here")
        }
    }

    /// `pair xcode --with`: waits for the one Mac named, gives it this Mac's offer, and saves the
    /// device it says a pairing was tried with.
    static func offerXcodePairing(with home: String, qr: Bool = false) async -> Never {
        let (mesh, other, ip) = mac(named: home)
        let (peer, own, interface) = byName(mesh, other, ip, also: ["ios", "ipados", "linux", "windows"])
        // Named itself, the device is saved under its Tailscale name: what its app calls it isn't asked.
        let itself = ["ios", "ipados"].contains(other.os.lowercased())
        let label = other.dnsName.split(separator: ".").first.map(String.init)
        if qr,
           !itself
        {
            fail(
                "--qr is for a device named with --with, whose app reads the code: \(other.dnsName) is given this Mac's name as an argument"
            )
        }
        // Its name here is its Tailscale name: found taken before anything waits.
        if itself, let label, ProfileStore().load().contains(where: {
            $0.displayName.caseInsensitiveCompare(label) == .orderedSame && $0.providerIP != ip
        }) {
            stop(
                "another device is saved here as \(label), which is the name \(other.dnsName) would get: rename that one first (the RoamRun app, on its page)"
            )
        }
        let listener: PairLink.Listener
        do { listener = try PairLink.Listener(ip: own, port: PairWire.port, interface: interface) } catch {
            stop(taken(waitingFor: other.dnsName, error) +
                " Carrying the lines still works: `roamrun pair xcode` alone")
        }
        let capture = BonjourCapture()
        capture.start(serviceType: Introduction.hostService)
        let halted = OSAllocatedUnfairLock(initialState: false)
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                halted.withLock {
                    $0 = true
                }
            }
            src.resume()
            keepAlive.append(src as AnyObject)
        }
        let whole = (try? TailscaleClient.fromSettings().selfDNSName()).flatMap {
            $0
        }
        let me = whole?.split(separator: ".").first.map(String.init) ?? "<this Mac's Tailscale name>"
        // What the one named runs: a Mac has RoamRun, another machine roamrunctl, which knows the device by its Tailscale name.
        let introduce = other.os.lowercased() == "macos" ? "roamrun pair introduce --host \(me) --to <device>"
            : "roamrunctl pair introduce --host \(me) --to <the device's Tailscale name>"
        // A Mac may have roamrunctl alone: Tailscale doesn't tell.
        let without = other.os
            .lowercased() == "macos" && !itself ?
            "\n    (a Mac without RoamRun:  roamrunctl pair introduce --host \(me) --to <the device's Tailscale name>)" :
            ""
        note("""
        Waiting for \(other.dnsName), 10 minutes at most; only \(itself ? "it" : other.os.lowercased() == "macos" ? "that Mac" : "that machine") is answered.
          There\(itself ? ":  the RoamRun Introducer app, far Mac “\(me)”, Introduce" : " (on the device's Wi‑Fi):  \(introduce)\(without)")
          Here:  Xcode's Device Hub: + › Pair Nearby Device, and leave “Waiting to pair.” open (before or after)
                 (for an Apple Vision Pro, with Remote Devices open on it, nothing is pressed yet: this says when)
        """)
        // Held by the firewall, a connection looks made to the other Mac and never arrives here.
        if Proc.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"], timeout: 5)
            .out
            .contains("enabled")
        {
            note(
                "This Mac's firewall is on. If \(other.dnsName) connects and nothing shows here, let RoamRun in: System Settings › Network › Firewall › Options (or `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add` and `--unblockapp` with this roamrun's path)."
            )
        }
        if qr {
            drawCode(whole.flatMap {
                Introduction.codeURL(mac: $0)
            }, for: other.dnsName)
        }
        let client = TailscaleClient.fromSettings()
        let sawOffer = OSAllocatedUnfairLock(initialState: false), met = OSAllocatedUnfairLock(initialState: false)
        // Once this Mac stands in for a device, Ctrl-C ends that (and what was tried is kept), not the command.
        let stoodIn = OSAllocatedUnfairLock(initialState: false)
        let from = other.dnsName
        let standsIn: @Sendable (String, String) async -> PairWire.Reason? = { line, device in
            stoodIn.withLock {
                $0 = true
            }
            return await standIn(forPairable: line, device: device, from: from, halted: {
                halted.withLock {
                    $0
                }
            })
        }
        let far = PairByName.Far(
            peer: peer,
            owner: {
                client.owner(of: $0)
            },
            offers: {
                await MainActor.run {
                    Introduction.current(among: ownOffers(capture))
                }
            },
            rescan: {
                await MainActor.run {
                    capture.restart()
                }
                try? await Task.sleep(for: .seconds(3))
            },
            save: { sent in
                // From the device itself, the line's own name and Tailscale name are placeholders: it is the one named here.
                let line = itself ? Introduction.line(sent, ofDevice: other.dnsName, named: label) : sent
                return await MainActor.run {
                    do throws(Refusal) { try saveDevice(
                        line: line,
                        name: nil,
                        replacing: nil,
                        peer: nil,
                        store: ProfileStore()
                    )
                    return true
                    } catch {
                        note("roamrun: not saved: \(error.why)")
                        // Only a line that reads as a device is shown: what came is the other Mac's to write.
                        if let shown = Introduction.shown(line) {
                            print(shown)
                            note(
                                "By hand: roamrun devices add <that line>   (with --as, --peer or --replace as the reason above asks)"
                            )
                        }
                        return false
                    }
                }
            },
            standIn: itself ? nil : standsIn,
            stopped: {
                halted.withLock {
                    $0
                } && !stoodIn.withLock {
                    $0
                }
            },
            say: { event in
                switch event {
                case .refused(let from): note("Turned away a connection from \(from): it isn't \(other.dnsName).")
                case .unsure(let from): note(
                        "Turned away a connection from \(from): Tailscale couldn't say just then whether that is \(other.dnsName)."
                    )
                case .connected:
                    met.withLock {
                        $0 = true
                    }
                    note("\(other.dnsName) connected.")
                case .waitingForOffer: note("This Mac isn't offering to pair yet: Device Hub: + › Pair Nearby Device.")
                case .offerSent:
                    sawOffer.withLock {
                        $0 = true
                    }
                    note(
                        "\(other.dnsName) has this Mac's offer. On the device: Settings › Privacy & Security › Developer Mode › Pair with “\(me)”\(itself ? " (its app says the name, if another)" : ""), and type the code Device Hub shows here. Waiting for what came of it (7 minutes at most)."
                    )
                case .dropped: note("The connection to \(other.dnsName) dropped; it is waited for again.")
                }
            },
            named: itself ? other.dnsName : nil
        )
        let end = await Task.detached {
            await far.run(listener)
        }
        .value
        capture.stop()
        switch end {
        case .saved:
            note("Whether the pairing was made isn't known yet: `roamrun up` shows.")
            exit(0)
        case .unsaved: exit(1)
        // This Mac's own stand-in, said above as it happened: not the other Mac's doing.
        case .ended(.stopped) where stoodIn.withLock({
            $0
        }): stop("stopped before this Mac connected to the device; nothing was saved")
        case .ended(.deadline) where stoodIn.withLock({
            $0
        }): stop("this Mac didn't connect to the device in 5 minutes; nothing was saved. Run both commands again")
        case .ended where stoodIn.withLock({
            $0
        }): stop("nothing was saved")
        case .ended(let why): stop(sentence(why, other: other.dnsName, itself: itself))
        case .ambiguous: stop(sentence(.ambiguous, other: "this Mac").replacingOccurrences(of: "there, ", with: ""))
        case .noResult: stop(
                "\(other.dnsName) took the offer and said nothing more in 7 minutes. See what its `\(introduce.prefix { $0 != " " }) pair introduce` printed: a line there works with `roamrun devices add` here"
            )
        case .noOne where itself:
            stop(sawOffer.withLock {
                $0
            }
                ? "\(other.dnsName) didn't come back in time. If a pairing was tried and its app shows a line, that works here with `roamrun devices add <line>`; otherwise run this again and Introduce in the app"
                : met.withLock {
                    $0
                }
                ? "\(other.dnsName) connected, but this Mac made no offer to pair in 10 minutes: Device Hub: + › Pair Nearby Device, leave “Waiting to pair.” open, and run this again"
                :
                "\(other.dnsName) didn't connect in 10 minutes. Was Introduce tapped in its app with this Mac's name (\(me)), and do Tailscale's rules let it reach port \(PairWire.port) here?")
        case .noOne:
            stop(sawOffer.withLock {
                $0
            }
                ? "\(other.dnsName) didn't come back in time. If a pairing was tried, the line its `\(introduce.prefix { $0 != " " }) pair introduce` printed works with `roamrun devices add` here; otherwise run both again"
                : met.withLock {
                    $0
                }
                ? "\(other.dnsName) connected, but this Mac made no offer to pair in 10 minutes: Device Hub: + › Pair Nearby Device, leave “Waiting to pair.” open, and run both commands again"
                :
                "\(other.dnsName) got no offer in 10 minutes. Is `\(introduce)` running there, was Pair Nearby Device pressed here, and do Tailscale's rules let it reach port \(PairWire.port) here?")
        case .stopped: stop("stopped; nothing was saved")
        }
    }

    /// A host's IPv4 addresses, as the system resolves its name (a `.local` name by mDNS). Blocking.
    nonisolated private static func addresses(of host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var found: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &found) == 0 else { return [] }
        defer { freeaddrinfo(found) }
        var out: [String] = []
        var next = found
        while let info = next {
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                info.pointee.ai_addr,
                info.pointee.ai_addrlen,
                &text,
                socklen_t(text.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 {
                out.append(String(decoding: text.prefix {
                    $0 != 0
                }
                .map {
                    UInt8(bitPattern: $0)
                }, as: UTF8.self))
            }
            next = info.pointee.ai_next
        }
        return out
    }

    /// Which of the devices waiting is at `at`. Its host is looked up where what was heard doesn't hold that
    /// address: an IPv6 one may have come alone.
    nonisolated static func waiting(_ seen: [CapturedService], at: String,
                                    resolve: (String) -> [String]) -> CapturedService?
    {
        seen.first {
            $0.hostIPs.contains(at)
        } ?? seen.first {
            resolve($0.host).contains(at)
        }
    }

    /// What `profile` announces while it waits to be picked by a Mac, as a line; nil for a device that
    /// picks the Mac itself (an iPhone, an iPad). Which of the devices waiting on this Wi‑Fi it is, is told
    /// by its address here, as Tailscale has it. Stops where it is known to be an Apple Vision Pro and isn't found waiting.
    private static func pairable(_ profile: DeviceProfile) async -> String? {
        let known = profile.deviceType
        guard known == nil || known == "realityDevice" else { return nil }
        let capture = BonjourCapture()
        capture.start(serviceType: Introduction.pairableService)
        try? await Task.sleep(for: .seconds(3))
        // A name that can't be shown isn't shown: whatever is on this Wi‑Fi chose it.
        let seen = capture.services
            .values
            .filter {
                ($0.txt["model"] ?? "").hasPrefix("RealityDevice") && Introduction.shows($0.instanceName)
            }
            .sorted {
                $0.instanceName < $1.instanceName
            }
        capture.stop()
        guard !seen.isEmpty else {
            if known == nil {
                return nil
            }
            stop(
                "\(profile.displayName) isn't waiting to be paired. On it: Settings › General › Remote Devices, left open; then run this again"
            )
        }
        let ip = profile.providerIP
        var endpoint = (try? TailscaleClient.fromSettings().mesh())?.peers
            .first {
                $0.ips.contains(ip)
            }?.curAddr ?? ""
        if endpoint.isEmpty {
            endpoint = Introduction.endpoint(pinged: await Blocking.run {
                (try? TailscaleClient.fromSettings().directHost(ip)) ?? nil
            })
        }
        let parts = endpoint.split(separator: ":")
        guard parts.count == 2, parts[0].contains(".") else {
            if known == nil {
                return nil
            }
            stop(
                "Tailscale doesn't reach \(profile.displayName) directly over IPv4 on this Wi‑Fi (through a relay, over IPv6, or not at all), so which of the devices waiting here it is couldn't be told. See that it is on this Mac's Wi‑Fi and connected in Tailscale; then run this again"
            )
        }
        let at = String(parts[0])
        let its = await Blocking.run {
            waiting(seen, at: at, resolve: addresses(of:))
        }
        guard let its else {
            if known == nil {
                return nil
            }
            stop(
                "\(profile.displayName) isn't waiting to be paired (\(seen.count == 1 ? "another device is" : "\(seen.count) other devices are"): \(seen.map(\.instanceName).joined(separator: ", "))). On it: Settings › General › Remote Devices, left open; then run this again"
            )
        }
        guard let read = Introduction.pairable(its) else {
            stop(
                "what “\(its.instanceName)” announces couldn't be read: it announces in a way this RoamRun doesn't know — please report it, with the device's OS version"
            )
        }
        return Introduction.line(read)
    }

    /// On the Mac that offers: announces a device that waits to be picked, here in its place, and carries this
    /// Mac's connection to it. `sent`: the device as it is saved afterwards — the one it is carried to is that one,
    /// found as saving finds it. nil once a connection was made (a pairing was tried); else why not.
    private static func standIn(
        forPairable line: String,
        device sent: String,
        from other: String,
        halted: @escaping @Sendable () -> Bool
    ) async -> PairWire.Reason? {
        guard case .success(let read) = Introduction.pairable(from: line) else {
            note("\(other) sent something that isn't what a device announces: nothing was announced.")
            return .offerRefused
        }
        let device: MeshDevice
        do throws(Refusal) { device = try found(line: sent, peer: nil).1 } catch {
            note("The device \(other) names wasn't taken (\(error.why)): nothing was announced.")
            return .offerRefused
        }
        guard let ip = device.ipv4 else {
            note("\(device.dnsName) has no IPv4 address on the tailnet: nothing was announced.")
            return .offerRefused
        }
        let who: String
        switch (try? TailscaleClient.fromSettings().mesh()).map({
            TailscaleClient.holder(of: device, in: $0)
        }) ?? .unknown {
        case .yours: who = "your device"
        case .user(let login): who = "\(login)'s device"
        case .shared(let tags): who = "a shared device (\(tags.joined(separator: ", ")))"
        case .unknown: who = "whose it is Tailscale doesn't say"
        }
        let shown = read.txt["name"] ?? read.instance
        // Said before anything is asked of the device or announced.
        note("\(other) says \(device.dnsName) (\(who)) waits to be picked by a Mac, as “\(shown)”.")
        let interface = InterfaceMonitor.lanInterface
        guard let local = InterfaceMonitor.currentIPv4(on: interface) else {
            note(
                "This Mac has no address on \(interface), where Xcode would look for the device (Settings › Network picks the interface): nothing was announced."
            )
            return .failed
        }
        guard await ReachabilityProbe.checkTCP(host: ip, port: read.port) else {
            note("\(device.dnsName) doesn't answer on port \(read.port) from here: nothing was announced.")
            return .unreachable
        }
        var done: CheckedContinuation<Introducer.End, Never>?
        var early: Introducer.End?
        var connected = false
        // Not ended by a connection closing: Device Hub may make more than one, and the one that paired stays open.
        let plan = Introducer.Plan(
            offer: .init(port: read.port, txt: read.txt),
            farIP: ip,
            localIP: local,
            interface: interface,
            accept: .ownAddress,
            service: Introduction.pairableService,
            instance: read.instance,
            endsWhenCarried: false
        )
        let introducer = Introducer(plan, record: DNSServiceProxy(), addressNow: {
            InterfaceMonitor.currentIPv4(on: interface)
        }) { event in
            switch event {
            case .announced(let interface, _, _):
                note("""
                Announced on \(interface) (seen by that network); only this Mac's connections are carried to \(device.dnsName).
                  Here, in Device Hub: + › Pair Nearby Device › Apple Vision Pro, pick “\(shown)”, Next, and type the code the device shows.
                  This ends once Device Hub has paired (if it doesn't: Ctrl-C when Device Hub says it is paired), or after 5 minutes;
                  the device is saved if this Mac connected to it.
                """)
            case .connected:
                if !connected {
                    note("This Mac connected to \(device.dnsName).")
                }
                connected = true
            case .farDidNotAnswer(let why): note("\(device.dnsName) didn't take a connection (\(why)).")
            case .ended(let why, let clean):
                note(clean ? "Nothing is announced or listening here any more." :
                    "The announcement's helper may still be running: `roamrun doctor` says.")
                if let done {
                    done.resume(returning: why)
                } else {
                    early = why
                }
            }
        }
        let watch = Task { @MainActor in
            while !Task.isCancelled, !halted() {
                try? await Task.sleep(for: .milliseconds(300))
            }
            if !Task.isCancelled {
                await introducer.end(.stopped)
            }
        }
        // An iPhone's pairing ends this by closing its connection; this one's stays open, so Device Hub's own log line ends it
        // (`devicectl list devices` can't: a device just paired isn't listed until it was reached). Without the line — its words
        // changed, or no admin to read the log — Ctrl-C or the deadline does. Saved either way, and said as for an iPhone.
        // Counted only once this Mac has connected: a pairing made before isn't this one.
        // ponytail: the line names no device: another one paired in Device Hub meanwhile reads as this one.
        let log = Proc.tied("/usr/bin/log", ["stream", "--style", "ndjson", "--predicate", pairingLog])
        let lines = Pipe()
        log.standardOutput = lines
        log.standardError = FileHandle.nullDevice
        let reader = LineReader(lines) { line in
            guard TunnelPortWatcher.message(inJSON: line).flatMap(pairingEnded) == true else { return }
            Task { @MainActor in
                if connected, !introducer.ended {
                    await introducer.end(.carried)
                }
            }
        }
        try? log.run()
        defer { watch.cancel()
            if log.isRunning {
                log.terminate()
            }
            _ = reader
        }
        do { try await introducer.start() } catch where !introducer.ended {
            note("Couldn't announce it: \(error.localizedDescription)")
            return .failed
        } catch {}
        let why = await withCheckedContinuation { c in
            if let early {
                c.resume(returning: early)
            } else {
                done = c
            }
        }
        switch why {
        case .carried: return nil
        case .stopped, .deadline: return connected ? nil : (why == .deadline ? .deadline : .stopped)
        case .addressLost: return .addressLost
        case .announcementLost: return .announcementLost
        }
    }

    /// `pair introduce` without a line: asks the Mac named for its offer, then stands in as with one.
    static func introduceByName(mac name: String, to profile: DeviceProfile) async -> Never {
        let device = Introduction.line(handover(of: profile))
        let (mesh, far, ip) = mac(named: name)
        let (peer, _, interface) = byName(mesh, far, ip, also: ["linux", "windows"], holds: true)
        let me = (try? TailscaleClient.fromSettings().selfDNSName())
            .flatMap {
                $0
            }?.split(separator: ".")
            .first
            .map(String.init) ?? "<this Mac's Tailscale name>"
        let client = TailscaleClient.fromSettings()
        let waits = await pairable(profile)
        if waits != nil, far.os.lowercased() != "macos" {
            stop(
                "\(profile.displayName) waits to be picked by a Mac (Device Hub pairs it), and \(far.dnsName) isn't one: --host <a Mac>"
            )
        }
        let home = PairByName.Home(
            peer: peer,
            owner: {
                client.owner(of: $0)
            },
            connect: {
                PairLink.connect(to: peer.ip, port: PairWire.port, interface: interface)
            },
            device: device,
            say: { event in
                switch event {
                case .waiting: note("Waiting for \(far.dnsName), 10 minutes at most. There: roamrun pair xcode --with \(me)" +
                        (waits == nil ?
                            "   (or, for device control: roamrun pair control --with \(me) — roamrunctl pair control --with \(me) where it has no RoamRun)" :
                            "")
                        // Saved without its kind, and nothing waited: taken for a device that picks the Mac itself.
                        +
                        (waits == nil && profile.deviceType == nil && far.os
                            .lowercased() == "macos" ?
                            "\nIf \(profile.displayName) is an Apple Vision Pro: open Settings › General › Remote Devices on it, and run this again." :
                            ""))
                case .connected: note(waits == nil ? "\(far.dnsName) answered; waiting for its offer." :
                        "\(far.dnsName) answered.")
                }
            }
        )
        if waits != nil {
            note(
                "\(profile.displayName) waits to be picked by a Mac: what it announces goes to \(far.dnsName), which announces it there. Keep Remote Devices open on it; the code it shows is typed in Device Hub on \(far.dnsName)."
            )
            // Read again once that Mac answers: the device changes its port now and then.
            switch await Task.detached(operation: {
                await home.hand(pairable: {
                    await pairable(profile)
                })
            })
            .value {
            case .saved:
                note(
                    "\(far.dnsName) says it connected to \(profile.displayName), and saved it. Whether the pairing was made shows there: roamrun up \(profile.displayName)"
                )
                exit(0)
            case .unsaved: stop(
                    "\(far.dnsName) says it connected to \(profile.displayName), but didn't save it: what it printed says why. By hand: `roamrun devices export \(profile.displayName)` here, `roamrun devices add <line>` there"
                )
            case .notWaiting: stop(
                    "\(profile.displayName) stopped waiting before \(far.dnsName) answered: Settings › General › Remote Devices on it, left open; then run this again"
                )
            case .ended(.unreachable): stop(
                    "\(far.dnsName) couldn't reach \(profile.displayName) on the port it waits on (Tailscale may not reach the device from there): what it printed says more"
                )
            case .ended(.offerRefused): stop(
                    "\(far.dnsName) didn't take what \(profile.displayName) announces, or the device: what it printed says why"
                )
            case .ended(.deadline): stop(
                    "\(far.dnsName) didn't connect to \(profile.displayName) in 5 minutes: there, Device Hub: + › Pair Nearby Device › Apple Vision Pro; run both commands again"
                )
            case .ended(.failed): stop(
                    "\(far.dnsName) doesn't stand in for a device as it runs now: there, `roamrun pair xcode --with \(me)` (not `pair control`), and what it printed says more"
                )
            case .ended(.stopped): stop(
                    "it was stopped on \(far.dnsName) before that Mac connected to \(profile.displayName)"
                )
            case .ended: stop(
                    "\(far.dnsName) stopped standing in before it connected to \(profile.displayName): what it printed says why"
                )
            case .wentAway: stop(
                    "\(far.dnsName) went away (its command stopped, or the connection dropped) while it stood in: what it printed says whether \(profile.displayName) was saved"
                )
            case .notThatMac: stop(
                    "the address this Mac had for \(far.dnsName) isn't that Mac's any more (or Tailscale couldn't say whose it is): nothing was sent to it. Run this again"
                )
            case .tooOld: stop(
                    "\(far.dnsName) hung up on it without a word: its RoamRun is likely from before an Apple Vision Pro could be introduced (0.7.0). Update RoamRun there"
                )
            case .garbled: stop(
                    "\(far.dnsName) answered with something this RoamRun doesn't know: is RoamRun the same version on both?"
                )
            case .noOne: stop(
                    "\(far.dnsName) wasn't waiting in 10 minutes. Is `roamrun pair xcode --with \(me)` running there, and do Tailscale's rules let this Mac reach port \(PairWire.port) there?"
                )
            case .stopped: stop("stopped")
            }
        }
        switch await Task.detached(operation: {
            await home.fetch()
        })
        .value {
        case .offer(let line, let link):
            await introduce(offer: line, mac: name, to: profile, known: (mesh, far, ip), by: link,
                            stillThatMac: {
                                client.owner(of: peer.ip) == peer.id
                            })
        case .control(let line, let attempt, let link):
            await introduce(offer: line, mac: name, to: profile, known: (mesh, far, ip), by: link,
                            stillThatMac: {
                                client.owner(of: peer.ip) == peer.id
                            }, control: attempt)
        case .refused(let why): stop(sentence(why, other: far.dnsName, device: profile.displayName))
        case .ended(let why): stop(sentence(why, other: far.dnsName))
        case .notThatMac: stop(
                "the address this Mac had for \(far.dnsName) isn't that Mac's any more (or Tailscale couldn't say whose it is): nothing was asked of it. Run this again"
            )
        // A machine that isn't a Mac has roamrunctl, which waits for device control alone.
        case .garbled
            where far.os
            .lowercased() !=
            "macos": stop(
                "\(far.dnsName) answered with something this RoamRun doesn't know: is roamrunctl there the same version as RoamRun here?"
            )
        case .noOne
            where far.os
            .lowercased() !=
            "macos": stop(
                "\(far.dnsName) gave no offer in 10 minutes. Is `roamrunctl pair control --with \(me)` running there, and do Tailscale's rules and that machine's firewall let this Mac reach port \(PairWire.port) there?"
            )
        case .garbled: stop(
                "\(far.dnsName) answered with something this RoamRun doesn't know: is RoamRun the same version on both? Carrying the lines still works: `roamrun pair xcode` there, alone"
            )
        case .noOne: stop(
                "\(far.dnsName) gave no offer in 10 minutes. Is `roamrun pair xcode --with \(me)` (or `pair control --with \(me)`) running there, was Pair Nearby Device pressed for Xcode, and do Tailscale's rules and that Mac's firewall let this Mac reach port \(PairWire.port) there? (If only that port is shut, carrying the lines works: `roamrun pair xcode` there, alone)"
            )
        case .stopped: stop("stopped")
        }
    }

    /// `pair xcode`: this Mac's own offer, as Xcode announces it while Pair Nearby Device waits.
    static func offerXcodePairing(qr: Bool = false) async -> Never {
        let capture = BonjourCapture()
        capture.start(serviceType: Introduction.hostService)
        try? await Task.sleep(for: .seconds(3))
        let own = ownOffers(capture)
        capture.stop()
        switch Introduction.current(among: own) {
        case .one(let line):
            print(line)
            if qr {
                let whole = (try? TailscaleClient.fromSettings().selfDNSName()).flatMap {
                    $0
                }
                note(
                    "Afterwards, here: roamrun devices add <the line the app shows>, then roamrun up <device>. Keep “Waiting to pair.” open meanwhile."
                )
                var offer: Introduction.Offer?
                if case .success(let read) = Introduction.offer(from: line) {
                    offer = read
                }
                drawCode(whole.flatMap { name in
                    offer.flatMap {
                        Introduction.codeURL(mac: name, offer: $0)
                    }
                }, for: "the device")
                exit(0)
            }
        case .several: stop(
                "this Mac offers to pair more than once (is RoamRun's own Set Up open too?): leave only Device Hub's open"
            )
        case .none where own.isEmpty:
            stop(
                "this Mac isn't offering to pair. In Xcode's Device Hub: + › Pair Nearby Device, leave “Waiting to pair.” open, then run this again"
            )
        case .none:
            stop(
                "this Mac's offer couldn't be read yet: run this again. If it stays so, Xcode announces it in a way this RoamRun doesn't know — please report it, with Xcode's version"
            )
        }
        let me = (try? TailscaleClient.fromSettings().selfDNSName())
            .flatMap {
                $0
            }?.split(separator: ".")
            .first
            .map(String.init) ?? "<this Mac's Tailscale name>"
        note("""
        On a Mac on the device's Wi‑Fi, with the device saved in RoamRun there:
          roamrun pair introduce <that line> --host \(me) --to <device>
        Keep “Waiting to pair.” open: pressing the button again makes a new offer, and this line is then no good.
        The code to type on the device is the one Device Hub shows here.
        Afterwards, here: roamrun devices add <the line that prints>, then roamrun up <device>. The RoamRun app needn't be open on this Mac for any of it.
        """)
        exit(0)
    }

    /// `pair introduce`: stands in for the Mac named, until the device has tried to pair with it.
    /// `link`: the Mac named, when its offer came from it directly; it is told what came of this.
    static func introduce(offer line: String, mac: String, to profile: DeviceProfile,
                          known: (TailscaleClient.Mesh, MeshDevice, String)? = nil, by link: PairLink? = nil,
                          stillThatMac: (() -> Bool)? = nil, control: String? = nil) async -> Never
    {
        /// `happened`: not a mistake in the command, but how things are (exit 1, not 2).
        func fail(_ why: String, _ code: PairWire.Reason = .failed, happened: Bool = false) -> Never {
            link?.send(.ended(code))
            if happened {
                stop(why)
            }
            CLI.fail(why)
        }
        var offer: Introduction.Offer
        switch Introduction.offer(from: line) {
        case .success(let o): offer = o
        case .failure(.another(let what)): fail("that is \(what), not a Mac's offer to pair", .offerRefused)
        case .failure(.notOne): fail("that isn't a line from `roamrun pair xcode`", .offerRefused)
        case .failure(.refused(let why)): fail("not taken: \(why)", .offerRefused)
        }
        // Before anything is announced: without this the pairing could be made and the device not handed over.
        let handover = Self.handover(of: profile)
        let (mesh, far, farIP) = known ?? Self.mac(named: mac)
        // The device lists a paired Mac under the name that Mac gives itself, whatever was announced.
        let listedAs = offer.txt["name"] ?? far.name
        offer = Introduction.announced(offer, as: far.name)
        let interface = InterfaceMonitor.lanInterface
        guard let local = InterfaceMonitor.currentIPv4(on: interface),
              let mask = InterfaceMonitor.netmask(of: local)
        else {
            fail(
                "this Mac has no address on \(interface): the device has to be on a Wi‑Fi this Mac is on (Settings › Network picks the interface)",
                happened: true
            )
        }
        // Asked again when the offer took a while to come: where the device is may have changed.
        let now = link == nil ? mesh : ((try? TailscaleClient.fromSettings().mesh()) ?? mesh)
        var endpoint = now.peers
            .first {
                $0.ips.contains(profile.providerIP)
            }?.curAddr ?? ""
        // A device nothing has talked to has no address in Tailscale's list: a ping gives it one.
        if endpoint.isEmpty {
            let ip = profile.providerIP
            endpoint = Introduction.endpoint(pinged: await Blocking.run {
                (try? TailscaleClient.fromSettings().directHost(ip)) ?? nil
            })
        }
        let accept = Introduction.accept(deviceEndpoint: endpoint, local: local, mask: mask)
        // Not from the whole LAN: any host there could then reach the port the offer names on that Mac.
        guard case .only(let deviceIP) = accept else {
            fail(endpoint.hasPrefix("[")
                ? "Tailscale reaches \(profile.displayName) over IPv6 here, and the device's connection to this Mac would come over IPv4: which host it is couldn't be told, so nothing was announced. It can be done on a network where Tailscale reaches it over IPv4"
                :
                "Tailscale doesn't reach \(profile.displayName) directly on this Wi‑Fi (through a relay, or not at all), so its connection couldn't be told from another host's and nothing was announced. See that the device is unlocked, on this Mac's Wi‑Fi, and connected in Tailscale; then run this again",
                happened: true)
        }
        guard await ReachabilityProbe.checkTCP(host: farIP, port: offer.port) else {
            fail(link == nil
                ? "\(far.dnsName) isn't waiting to pair on port \(offer.port) any more (or can't be reached): there, press Pair Nearby Device again and run `roamrun pair xcode` for a new line"
                :
                "\(far.dnsName) answers, but its pairing port \(offer.port) can't be reached from here: there, press Pair Nearby Device again; if it stays so, Tailscale's rules don't let this Mac in on that port (carrying the lines wouldn't change that)",
                .unreachable, happened: true)
        }
        let who: String
        switch TailscaleClient.holder(of: far, in: mesh) {
        case .yours: who = "your Mac"
        case .user(let login): who = "\(login)'s Mac"
        case .shared(let tags): who = "a shared machine (\(tags.joined(separator: ", "))): whoever can use Xcode on it"
        case .unknown: who = "whose it is Tailscale doesn't say"
        }
        note(control == nil
            ? "Introducing \(far.dnsName) (\(who)) to \(profile.displayName). It will be able to use \(profile.displayName) as a developer; to withdraw that, remove “\(listedAs)” on the device (Settings › Privacy & Security › Developer Mode: once paired it is listed under the name that Mac gives itself)."
            :
            "Introducing \(far.dnsName) (\(who)) to \(profile.displayName), for device control: programs on that machine will be able to see \(profile.displayName)'s screen and operate it. To withdraw that, remove “\(listedAs)” on the device (Settings › Privacy & Security › Developer Mode), or there: \(far.os.lowercased() == "macos" ? "switch it off in RoamRun (or `roamrunctl devices remove`)" : "`roamrunctl devices remove`").")

        var done: CheckedContinuation<(Introducer.End, Bool), Never>?
        var early: (Introducer.End, Bool)?
        let introducer = Introducer(
            .init(offer: offer, farIP: farIP, localIP: local, interface: interface, accept: accept),
            record: DNSServiceProxy(),
            addressNow: {
                InterfaceMonitor.currentIPv4(on: interface)
            }
        ) { event in
            switch event {
            case .announced(let interface, let name, _):
                note(
                    "Announced on \(interface) as “\(name)”; taking connections from \(deviceIP) only (the device's address here). On \(profile.displayName): Settings › Privacy & Security › Developer Mode › Pair with “\(name)”, and type the code \(control == nil ? "\(far.name) shows" : "that shows here once it is picked"). 5 minutes at most."
                )
            case .connected(let from): note("A device connected from \(from)." +
                    (control == nil ? " (A wrong code keeps this open: type it again on the device.)" : ""))
            case .farDidNotAnswer(let why): note(
                    "\(far.dnsName) didn't take it (\(why)): there, press Pair Nearby Device again and \(link == nil ? "make a new line" : "run both commands again")."
                )
            case .ended(let why, let clean):
                if let done {
                    done.resume(returning: (why, clean))
                } else {
                    early = (why, clean)
                }
            }
        }
        keepAlive.append(introducer)
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                Task { @MainActor in
                    await introducer.end(.stopped)
                }
            }
            src.resume()
            keepAlive.append(src as AnyObject)
        }
        if let stillThatMac, !stillThatMac() {
            fail(
                "the address this Mac had for \(far.dnsName) isn't that Mac's any more (or Tailscale couldn't say whose it is): nothing was announced. Run both commands again",
                happened: true
            )
        }
        // Stopped while it started: said below, as any other stop.
        do { try await introducer.start() } catch where !introducer.ended { fail(
            "couldn't stand in: \(error.localizedDescription)",
            happened: true
        ) } catch {}
        // The other Mac going away ends this too: nothing stays announced for a Mac that isn't waiting.
        let over = OSAllocatedUnfairLock(initialState: false)
        // For device control that Mac passes the code on, and says itself what came of it.
        let outcome = OSAllocatedUnfairLock<PairWire.Outcome?>(initialState: nil)
        let device = profile.displayName
        let watch = link.map { link in
            Task.detached { () -> Bool in
                while !over.withLock({
                    $0
                }) {
                    let read = link.read(within: 0.5, stop: {
                        over.withLock {
                            $0
                        }
                    })
                    if read == .timeout {
                        continue
                    }
                    switch control == nil ? nil : read.message {
                    case .code(let digits): note("Code to type on \(device): \(digits)")
                    case .result(let came):
                        outcome.withLock {
                            $0 = came
                        }
                        await introducer.end(.stopped)
                        return false
                    default:
                        await introducer.end(.stopped)
                        return true
                    }
                }
                return false
            }
        }
        let (why, clean) = await withCheckedContinuation { c in
            if let early {
                c.resume(returning: early)
            } else {
                done = c
            }
        }
        over.withLock {
            $0 = true
        }
        let lost = await watch?.value ?? false
        note(clean ? "Stopped: nothing is announced or listening here any more." :
            "Stopped, but the announcement's helper may still be running: `roamrun doctor` says.")
        switch why {
        case .carried: note(control == nil ?
                "A pairing was tried; whether it was made shows on \(far.name), not here." :
                "The device is done here; \(far.name) says what it kept (90 seconds at most).")
        case .deadline: note("Nothing was paired in 5 minutes. " +
                (link == nil ?
                    "Run it again when the device is at hand (the same line works while “Waiting to pair.” stays open)." :
                    "Run both commands again when the device is at hand."))
        case .stopped where outcome.withLock({
            $0
        }) != nil: break
        case .stopped: note(lost ?
                "\(far.dnsName) went away (its command stopped, or the connection dropped) before a pairing was tried. Start both again." :
                "Stopped before a pairing was tried.")
        case .addressLost: note(
                "This Mac's address on \(interface) changed, so it stopped rather than announce elsewhere."
            )
        case .announcementLost: note("The announcement or its listener failed.")
        }
        if let link, let control {
            var came = outcome.withLock {
                $0
            }
            if came == nil, why == .carried {
                came = await Task.detached { () -> PairWire.Outcome? in
                    if case .result(let came) = link.read(within: 90).message {
                        came
                    } else {
                        nil
                    }
                }
                .value
            } else if came == nil, !lost {
                // Its own end: that Mac is told, and keeps nothing.
                let code: PairWire.Reason = switch why {
                case .deadline: .deadline
                case .addressLost: .addressLost
                case .announcementLost: .announcementLost
                default: .stopped
                }
                link.send(.ended(code))
                exit(1)
            } else if came == nil {
                exit(1)
            }
            switch came {
            case .done(let on):
                note("\(far.name) is paired with \(profile.displayName) for device control" +
                    (on ? ", and it is switched on there." :
                        ". It is switched off there (its Keychain didn't keep the switch): switch it on in RoamRun on that Mac; the pairing needn't be made again."))
                exit(0)
            case .failed(let why):
                note("roamrun: " + sentence(why, other: far.name, device: profile.displayName))
                exit(1)
            case nil:
                note(
                    "What \(far.name) kept couldn't be learned. Its own terminal says; with RoamRun there: roamrun pair control --attempt \(control)"
                )
                exit(1)
            }
        }
        if let link {
            let code: PairWire.Reason
            switch why {
            case .carried:
                let line = Introduction.line(handover)
                switch await Task.detached(operation: {
                    PairByName.Home.handOver(line, on: link)
                })
                .value {
                case .saved:
                    note(
                        "\(far.name) saved \(profile.displayName). There: roamrun up, as it says   (that shows whether the pairing was made)"
                    )
                    exit(0)
                case .unsaved: note(
                        "\(far.name) didn't save \(profile.displayName); it says why. The line, to do it by hand there:"
                    )
                case .unknown: note(
                        "Whether \(far.name) saved \(profile.displayName) couldn't be learned. There: `roamrun devices` shows. If it isn't listed:"
                    )
                }
                print(line)
                note("On \(far.name): roamrun devices add <that line>   then roamrun up, as it says there")
                exit(1)
            case .deadline: code = .deadline
            case .stopped: code = .stopped
            case .addressLost: code = .addressLost
            case .announcementLost: code = .announcementLost
            }
            link.send(.ended(code))
            exit(1)
        }
        // No line where nothing was tried: a script that goes on would save a device that isn't paired.
        guard why == .carried else { exit(1) }
        print(Introduction.line(handover))
        note(
            "On \(far.name): roamrun devices add <that line>   then roamrun up, as it says there   (that shows whether the pairing was made)"
        )
        exit(0)
    }
}
