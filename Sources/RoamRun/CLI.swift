import AppKit
import CoreImage
import DeviceControl
import Foundation

/// `roamrun devices | up <name> | status [name]` — the same bridge as the menu
/// bar app, headless, for SSH sessions and scripts.
@MainActor
enum CLI {
    /// This process was started as the CLI (vs. the menu bar app).
    nonisolated static var isRunning: Bool { commands.contains(CommandLine.arguments.dropFirst().first ?? "") }
    nonisolated static let commands: Set<String> = deviceCommands.union(["devices", "pair", "up", "down", "status", "doctor", "run", "install", "ota", "logs", "screenshot", "init", "version", "--version", "help", "--help", "-h"])
    /// The words as numbers a point or a duration can be: nil when one isn't a number, or is NaN or infinite.
    nonisolated static func finite(_ words: some Sequence<String>) -> [Double]? {
        let numbers = words.compactMap { Double($0) }.filter(\.isFinite)
        return numbers.count == Array(words).count ? numbers : nil
    }

    /// What only a build with device control has (to the others they are unknown commands).
    nonisolated static let deviceCommands: Set<String> = ["look", "tap", "swipe", "type", "paste", "press", "elements", "mcp", "key"]
    /// Posted by `roamrun down`; the app stops the bridge whose id is `object`.
    static let stopNotification = Notification.Name(AppID.bundle + ".stopBridge")
    /// What a RoamRun before 0.1.12 listens for, should it still run next to this CLI.
    // ponytail: bundle-id migration only; drop after a few releases.
    static let legacyStopNotification = Notification.Name(AppID.legacy + ".stopBridge")

    private static let usage = baseUsage + "\n\n" + deviceUsage

    private static let deviceUsage = """
    Operating a device (iOS 27 or later; the RoamRun app holds the connection, and the device needs
    a pairing of RoamRun's own):
      look <name> [file.png]         Save the device's screen now as PNG, its longer side 1280 at most;
                                     prints the path, then its size
      tap <name> <x> <y>             Tap a point given in the pixels of the last look
      swipe <name> <x1> <y1> <x2> <y2> [ms]
                                     Drag from one point of the last look to another
      elements <name> [limit]        What accessibility says is on the screen, one caption a line
                                     (no positions; the screen may scroll)
      type <name> <text>             Type on the device's keyboard (US keys; right only while that
                                     keyboard is an English one: under a Japanese one even a space converts)
      paste <name> <text>            Any text, by the device's pasteboard (it asks the user each time)
      press <name> <button>          home, lock, volume-up or volume-down
      mcp                            The same as MCP tools, over stdin/stdout (for an agent's MCP config)
    Each look serves one action: look, act, look again.
    For a Mac that can't pair itself (not on the device's network):
      key create <name> <file> [--as <label>]
                                     Here, with the device on this Wi‑Fi: pairs once more, as
                                     <label> in the device's list, and writes that pairing and the
                                     device to <file>. The file is the key: keep it as one.
      key import <file> [--as <name>]
                                     There: saves the device and its pairing (switched on), then removes <file>
    """

    private static let baseUsage = """
    Usage: roamrun <command>

    AI agents: `roamrun init` installs the RoamRun skill for Claude Code, Codex,
    Cursor, Gemini CLI and Copilot (`roamrun init --print` to read it now).

      devices [--json]               List saved devices (with UDID) and their bridge status
      devices export <name>          A saved device as a line for another Mac: no key, no UDID
      devices add <line> [--as <name>] [--replace <name>] [--peer <Tailscale name>]
                                     Save the device of such a line (found by its Tailscale name on this
                                     Mac's tailnet; --replace: put it in a saved one's place, with the
                                     app and that device's bridge stopped)
      pair xcode                     On a Mac the device was never near, after Device Hub › Pair Nearby
                                     Device: print this Mac's offer to pair, for `pair introduce`
      pair introduce <offer> --mac <Tailscale name> --to <device>
                                     On a Mac on the device's Wi‑Fi: stand in for that Mac until the
                                     device has paired with it (5 minutes at most), then print the line
                                     for `devices add` there. That Mac will use the device as a developer.
      up <name> [-v] [-d]            Bridge a device until Ctrl-C (-v: activity log; -d: run in the background —
                                     waits up to 60s for Ready or On this Wi-Fi (exit 0); otherwise exits 1
                                     and keeps trying, unless the bridge itself quit: then exit 1 at once
                                     with the reason)
      down <name>                    Stop a bridge, whether the app or another `roamrun up` runs it
      status [name] [--wait N] [--json]
                                     Bridge status, UDID and lock state; exits 0 only if Xcode can use
                                     the device (bridged and ready, or a bridge standing aside on this Wi-Fi);
                                     without a name it lists every saved device and exits 0 if any one of
                                     them is ready (--wait: wait up to N seconds for ready; each round runs
                                     one devicectl list, plus a lock check per ready device, before the
                                     deadline is looked at again, so it can return several seconds after N)
      doctor [name] [--json]         Check each step from this Mac to the device and say what to fix
                                     (without a name: devices with a running bridge, or all if none runs)
      run <name> [--scheme S] [--workspace W | --project P] [--configuration C] [--logs] [launch options]
                                     Build the project in this folder for the device, install and launch it
                                     (--logs: then stream its output like `logs`)
      install <name> <App.ipa|App.app>
                                     Install an .ipa or .app signed for the device (Debugging, Release
                                     Testing / Ad Hoc or Enterprise); checks the signing first
      logs <name> <bundle-id> [launch options]
                                     Relaunch the app with its console attached (print and os_log)
                                     until Ctrl-C — it restarts the app; it can't join one already running
      launch options (run, logs), e.g. to open one screen before a screenshot:
        --arg A                      pass A to the app (repeat for more; may start with “-”)
        --env NAME=value             set an environment variable for the app (repeatable)
        --url URL                    open URL in the app (its URL scheme or a universal link)
      screenshot <name> [file.png]   Save the device's screen as PNG (default: ./<name>-<time>.png) and
                                     print its path — to check what an app shows (Xcode 26.3+)
      ota [<name>] <App.ipa> [--replace]
                                     Publish a build for installing from the device itself, without the
                                     bridge — over Wi-Fi or cellular, and on devices that were never paired.
                                     Install only: no debugger, no logs, no screenshots. Needs an Ad Hoc or
                                     Enterprise .ipa, `tailscale serve` for HTTPS, and RoamRun.app running —
                                     it serves the page. Says which of your devices the build covers, and
                                     prints the page's address. Anyone on your tailnet can install from it
                                     (<name>: check one device rather than all; --replace: drop builds
                                     already listed under the same version and build)
      version                        Print the version (also --version)
      init [--client <name>] [--print] [--uninstall]
                                     Install the agent skill (clients: claude, codex, cursor, gemini, copilot, devin)

    Exit codes: 0 ok/ready, 1 not ready or a check failed, 2 usage error.
    Name a device when a script needs the answer to be about that one.

    Add devices (iPhone, iPad, Vision Pro) in the RoamRun app first (one-time, with the device on this
    Wi-Fi or USB).
    """

    // Kept alive for the lifetime of `up`.
    private static var bridge: ProxyBridge?
    private static var keepAlive: [AnyObject] = []

    private static func note(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    /// `devices export`: the line alone on stdout, what to do with it on stderr.
    private static func exportDevice(_ profile: DeviceProfile) -> Never {
        guard let device = Introduction.device(of: profile) else {
            fail("what is saved of \(profile.displayName)'s announcement isn't whole (or its Tailscale name is missing): remove it and add it again on its Wi‑Fi, then export")
        }
        print(Introduction.line(device))
        note("On the other Mac: roamrun devices add <that line>   (no key is in it; it names the device \(device.peer) on your tailnet)")
        exit(0)
    }

    /// `devices add`: where the device is comes from this Mac's own Tailscale, never from the line.
    private static func addDevice(line: String, name: String?, replacing: String?, peer: String?, store: ProfileStore) -> Never {
        let device: Introduction.Device
        switch Introduction.device(from: line) {
        case .success(let d): device = d
        case .failure(.another(let what)): fail("that is \(what), not a saved device")
        case .failure(.notOne): fail("that isn't a line from `roamrun devices export` or `roamrun pair introduce`")
        case .failure(.refused(let why)): fail("not taken: \(why)")
        }
        let mesh: TailscaleClient.Mesh
        do { mesh = try TailscaleClient.fromSettings().mesh() } catch { fail("Tailscale on this Mac couldn't be asked: \(error.localizedDescription)") }
        let wanted = peer ?? device.peer
        let found: MeshDevice
        switch TailscaleClient.peer(named: wanted, in: mesh) {
        case .one(let p): found = p
        case .none: fail("no device named \(shellName(wanted)) on this Mac's tailnet. If it has another name here, say which: --peer <Tailscale name>")
        case .several(let names): fail("\(shellName(wanted)) names more than one device here (\(names.joined(separator: ", "))): say which with --peer <whole Tailscale name>")
        }
        guard ["ios", "ipados"].contains(found.os.lowercased()) else {
            fail("\(found.dnsName) is a \(found.os.isEmpty ? "device of another kind" : found.os) device, not an iPhone or iPad: --peer <Tailscale name> names the right one")
        }
        let saved = store.load()
        var change: (inout [DeviceProfile]) -> Void
        let called: String
        if let replacing {
            guard let old = find(replacing, in: saved) else { fail("no device named \(shellName(replacing)). " + names(saved)) }
            if StatusFile.read()[old.id] != nil { fail("\(old.displayName)'s bridge is running: `roamrun down \(shellName(old.displayName))` first") }
            if !NSRunningApplication.runningApplications(withBundleIdentifier: AppID.bundle).filter({ $0.processIdentifier != getpid() }).isEmpty {
                fail("quit the RoamRun app first: it would write back what it has of \(old.displayName)")
            }
            guard let new = Introduction.profile(from: device, peer: found, name: old.displayName) else { fail("\(found.dnsName) has no IPv4 address on the tailnet") }
            called = old.displayName
            change = { all in
                guard let i = all.firstIndex(where: { $0.id == old.id }) else { return }
                all[i].instanceName = new.instanceName; all[i].txt = new.txt
                all[i].remotePairingPort = new.remotePairingPort
                all[i].providerIP = new.providerIP; all[i].providerHostName = new.providerHostName
            }
        } else {
            let wantedName = (name ?? device.name).trimmingCharacters(in: .whitespaces)
            guard let new = Introduction.profile(from: device, peer: found, name: wantedName) else { fail("\(found.dnsName) has no IPv4 address on the tailnet") }
            // Before the name: a device saved already is the likelier reason its name is taken.
            if let same = saved.first(where: { ProfileStore.sameDevice($0, new) }) {
                fail("\(same.displayName) is that device already. To put this in its place: --replace \(shellName(same.displayName))")
            }
            if let problem = saved.nameProblem(wantedName) { fail("\(problem) Give it one: --as <name>") }
            called = wantedName
            change = { $0.append(new) }
        }
        note("\(called): \(found.dnsName) (\(found.ipv4 ?? "")), port \(device.port), announced as \(device.txt["identifier"] ?? "")")
        guard store.update(change) else { fail("couldn't write \(ProfileStore.directory.path)/profiles.json") }
        print(replacing != nil
              ? "\(called) now has that announcement and address; its UDID is as it was. Next: roamrun up \(shellName(called))"
              : "\(called) is saved, without a UDID: the bridge learns it from this Mac's own pairing. Next: roamrun up \(shellName(called))")
        note("(the RoamRun app lists it once it is opened again)")
        exit(0)
    }

    /// `pair xcode`: this Mac's own offer, as Xcode announces it while Pair Nearby Device waits.
    private static func offerXcodePairing() async -> Never {
        let capture = BonjourCapture()
        capture.start(serviceType: Introduction.hostService)
        try? await Task.sleep(for: .seconds(3))
        let own = Introduction.ownOffers(among: Array(capture.services.values), ownIPs: Set(InterfaceMonitor.ipv4Addresses().values))
            .filter { TailscaleClient.listening(on: $0.port) }
        capture.stop()
        guard let service = own.first else {
            fail("this Mac isn't offering to pair. In Xcode's Device Hub: + › Pair Nearby Device, leave “Waiting to pair.” open, then run this again")
        }
        if own.count > 1 { fail("this Mac offers to pair \(own.count) times over (is RoamRun's own Set Up open too?): leave only Device Hub's open") }
        let offer = Introduction.Offer(port: service.port, txt: service.txt)
        switch Introduction.offer(from: Introduction.line(offer)) {
        case .success: break
        case .failure(.refused(let why)): fail("Xcode on this Mac announces its offer in a way this RoamRun doesn't know: \(why). Please report it, with Xcode's version")
        case .failure: fail("this Mac's offer couldn't be read")
        }
        print(Introduction.line(offer))
        let me = (try? TailscaleClient.fromSettings().selfDNSName()).flatMap { $0 }?.split(separator: ".").first.map(String.init) ?? "<this Mac's Tailscale name>"
        note("""
        On a Mac on the device's Wi‑Fi, with the device saved in RoamRun there:
          roamrun pair introduce <that line> --mac \(me) --to <device>
        Keep “Waiting to pair.” open: pressing the button again makes a new offer, and this line is then no good.
        The code to type on the device is the one Device Hub shows here.
        """)
        exit(0)
    }

    /// `pair introduce`: stands in for the Mac named, until the device has tried to pair with it.
    private static func introduce(offer line: String, mac: String, to profile: DeviceProfile) async -> Never {
        var offer: Introduction.Offer
        switch Introduction.offer(from: line) {
        case .success(let o): offer = o
        case .failure(.another(let what)): fail("that is \(what), not a Mac's offer to pair")
        case .failure(.notOne): fail("that isn't a line from `roamrun pair xcode`")
        case .failure(.refused(let why)): fail("not taken: \(why)")
        }
        // Before anything is announced: without this the pairing could be made and the device not handed over.
        guard let handover = Introduction.device(of: profile) else {
            fail("what is saved of \(profile.displayName)'s announcement isn't whole: remove it and add it again on its Wi‑Fi first")
        }
        let mesh: TailscaleClient.Mesh
        do { mesh = try TailscaleClient.fromSettings().mesh() } catch { fail("Tailscale on this Mac couldn't be asked: \(error.localizedDescription)") }
        let far: MeshDevice
        switch TailscaleClient.peer(named: mac, in: mesh) {
        case .one(let p): far = p
        case .none: fail("no Mac named \(shellName(mac)) on this Mac's tailnet (its Tailscale name; a Mac of another tailnet by its whole name)")
        case .several(let names): fail("\(shellName(mac)) names more than one (\(names.joined(separator: ", "))): give the whole Tailscale name")
        }
        guard let farIP = far.ipv4 else { fail("\(far.dnsName) has no IPv4 address on the tailnet") }
        // The device lists a paired Mac under the name that Mac gives itself, whatever was announced.
        let listedAs = offer.txt["name"] ?? far.name
        offer = Introduction.announced(offer, as: far.name)
        let interface = InterfaceMonitor.lanInterface
        guard let local = InterfaceMonitor.currentIPv4(on: interface), let mask = InterfaceMonitor.netmask(of: local) else {
            fail("this Mac has no address on \(interface): the device has to be on a Wi‑Fi this Mac is on (Settings › Network picks the interface)")
        }
        let endpoint = mesh.peers.first { $0.ips.contains(profile.providerIP) }?.curAddr ?? ""
        let accept = Introduction.accept(deviceEndpoint: endpoint, local: local, mask: mask)
        guard await ReachabilityProbe.checkTCP(host: farIP, port: offer.port) else {
            fail("\(far.dnsName) isn't waiting to pair on port \(offer.port) any more (or can't be reached): there, press Pair Nearby Device again and run `roamrun pair xcode` for a new line")
        }
        let who: String
        switch TailscaleClient.holder(of: far, in: mesh) {
        case .yours: who = "your Mac"
        case .user(let login): who = "\(login)'s Mac"
        case .shared(let tags): who = "a shared machine (\(tags.joined(separator: ", "))): whoever can use Xcode on it"
        case .unknown: who = "whose it is Tailscale doesn't say"
        }
        note("Introducing \(far.dnsName) (\(who)) to \(profile.displayName). It will be able to use \(profile.displayName) as a developer; to withdraw that, remove “\(listedAs)” on the device (Settings › Privacy & Security › Developer Mode: once paired it is listed under the name that Mac gives itself).")

        var done: CheckedContinuation<(Introducer.End, Bool), Never>?
        var early: (Introducer.End, Bool)?
        let introducer = Introducer(.init(offer: offer, farIP: farIP, localIP: local, interface: interface, accept: accept),
                                    record: DNSServiceProxy(), addressNow: { InterfaceMonitor.currentIPv4(on: interface) }) { event in
            switch event {
            case .announced(let interface, let name, _):
                let from: String
                switch accept {
                case .only(let ip): from = "from \(ip) only (the device's address here)"
                default: from = "from this LAN (\(profile.displayName)'s address here isn't known)"
                }
                note("Announced on \(interface) as “\(name)”; taking connections \(from). On \(profile.displayName): Settings › Privacy & Security › Developer Mode › Pair with “\(name)”, and type the code \(far.name) shows. 5 minutes at most.")
            case .connected(let from): note("A device connected from \(from). (A wrong code keeps this open: type it again on the device.)")
            case .farDidNotAnswer(let why): note("\(far.dnsName) didn't take it (\(why)): there, press Pair Nearby Device again and make a new line.")
            case .ended(let why, let clean):
                if let done { done.resume(returning: (why, clean)) } else { early = (why, clean) }
            }
        }
        keepAlive.append(introducer)
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { Task { @MainActor in await introducer.end(.stopped) } }
            src.resume()
            keepAlive.append(src as AnyObject)
        }
        do { try await introducer.start() } catch { fail("couldn't stand in: \(error.localizedDescription)") }
        let (why, clean) = await withCheckedContinuation { c in
            if let early { c.resume(returning: early) } else { done = c }
        }
        note(clean ? "Stopped: nothing is announced or listening here any more." : "Stopped, but the announcement's helper may still be running: `roamrun doctor` says.")
        switch why {
        case .carried: note("A pairing was tried; whether it was made shows on \(far.name), not here.")
        case .deadline: note("Nothing was paired in 5 minutes. Run it again when the device is at hand (the same line works while “Waiting to pair.” stays open).")
        case .stopped: note("Stopped before a pairing was tried.")
        case .addressLost: note("This Mac's address on \(interface) changed, so it stopped rather than announce elsewhere.")
        case .announcementLost: note("The announcement or its listener failed.")
        }
        print(Introduction.line(handover))
        note("On \(far.name): roamrun devices add <that line>   then: roamrun up \(shellName(profile.displayName))   (it shows there whether the pairing was made)")
        exit(why == .carried ? 0 : 1)
    }

    /// What a command's earlier name is answered with; nil for any other word.
    nonisolated static func moved(_ command: String) -> String? {
        command == "pairing" ? "`roamrun pairing …` is now `roamrun key …` (key create, key import)" : nil
    }

    nonisolated static func run(_ args: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        MainActor.assumeIsolated {
            if !commands.contains(args[0]) {
                // Renamed after 0.3.0: say where it went rather than print the whole usage.
                if let note = moved(args[0]) { fail(note) }
                FileHandle.standardError.write(Data("roamrun: unknown command “\(args[0])”\n\n\(usage)\n".utf8))
                exit(2)
            }
            if wantsHelp(args) { print(usage); exit(0) }
            if args[0] == "version" || args[0] == "--version" {
                // Through the /usr/local/bin link, Bundle.main isn't the app: resolve it.
                let app = Bundle.main.executableURL?.resolvingSymlinksInPath()
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let info = app.flatMap(Bundle.init(url:))?.infoDictionary ?? Bundle.main.infoDictionary
                print("roamrun \(info?["CFBundleShortVersionString"] as? String ?? "dev")")
                exit(0)
            }
            if args[0] == "init" { initSkill(args) }   // takes no iPhone name
            let store = ProfileStore()
            let profiles = store.load()
            if let copy = store.keptUnreadable {
                FileHandle.standardError.write(Data("roamrun: couldn't read saved devices; kept the file as \(copy.path)\n".utf8))
            } else if store.unreadable {
                FileHandle.standardError.write(Data("roamrun: couldn't read \(ProfileStore.directory.path)/profiles.json — check its permissions\n".utf8))
            }
            let parsed: Parsed
            switch parse(args) {
            case .success(let p): parsed = p
            case .failure(let e): fail(e.message)
            }
            let (json, wait, words) = (parsed.flags.contains("--json"), parsed.wait, parsed.words)
            // `ota` is the one command whose first word may be the path: it does
            // nothing to a device, so naming one is optional there. By the count,
            // not the extension — a device may well be called "iPhone.ipa".
            let name = (args[0] == "ota" && words.count < 2) || ["key", "pair", "devices"].contains(args[0]) ? nil : words.first
            var targets = profiles
            if let name {
                guard let p = find(name, in: profiles) else { fail("no device named \(shellName(name)). " + names(profiles)) }
                targets = [p]
            }
            switch args[0] {
            case "devices":
                switch (words.first, words.count) {
                case (nil, _): devices(profiles, json: json)
                case ("export", 2):
                    guard let p = find(words[1], in: profiles) else { fail("no device named \(shellName(words[1])). " + names(profiles)) }
                    exportDevice(p)
                case ("add", 2):
                    addDevice(line: words[1], name: parsed.values["--as"], replacing: parsed.values["--replace"],
                              peer: parsed.values["--peer"], store: store)
                default:
                    fail("usage: roamrun devices [--json] | roamrun devices export <name> | roamrun devices add <line> [--as <name>] [--replace <name>] [--peer <Tailscale name>]")
                }
            case "pair":
                switch (words.first, words.count) {
                case ("xcode", 1): Task { await offerXcodePairing() }
                case ("introduce", 2):
                    guard let mac = parsed.values["--mac"], let to = parsed.values["--to"] else {
                        fail("usage: roamrun pair introduce <offer> --mac <the other Mac's Tailscale name> --to <device>")
                    }
                    guard let p = find(to, in: profiles) else { fail("no device named \(shellName(to)). " + names(profiles)) }
                    Task { await introduce(offer: words[1], mac: mac, to: p) }
                default:
                    fail("usage: roamrun pair xcode | roamrun pair introduce <offer> --mac <the other Mac's Tailscale name> --to <device>")
                }
            case "status":
                noteStaleSkills()
                status(targets, json: json, wait: wait)
            case "doctor":
                noteStaleSkills()
                // No name and nothing running: check every device rather than report "All good." unchecked.
                let running = StatusFile.read()
                let checkAll = name != nil || !targets.contains { running[$0.id] != nil }
                Task { exit(await doctor(targets, json: json, checkAll: checkAll) ? 0 : 1) }
            case "down":
                guard name != nil, let p = targets.first else { fail("which device? " + names(profiles)) }
                down(p)
            case "up":
                guard name != nil, let p = targets.first else { fail("which device? " + names(profiles)) }
                if parsed.flags.contains("-d") {
                    detach(p, verbose: parsed.flags.contains("-v"))
                } else {
                    up(p, verbose: parsed.flags.contains("-v"), detachedChild: parsed.flags.contains(detachedFlag))
                }
            case "logs":
                guard name != nil, let p = targets.first, words.count >= 2 else {
                    fail("usage: roamrun logs <name> <bundle-id>. " + names(profiles))
                }
                logs(p, bundleID: words[words.startIndex + 1], launch: parsed.launch)
            case "run":
                guard name != nil, let p = targets.first else { fail("usage: roamrun run <name> [--scheme S]. " + names(profiles)) }
                Proc.Passing.shared.begin()   // nothing it waits on may outlive it
                let v = parsed.values
                runApp(p, scheme: v["--scheme"], workspace: v["--workspace"], project: v["--project"],
                       configuration: v["--configuration"] ?? "Debug", logs: parsed.flags.contains("--logs"), launch: parsed.launch)
            case "screenshot":
                guard name != nil, let p = targets.first else {
                    fail("usage: roamrun screenshot <name> [file.png]. " + names(profiles))
                }
                screenshot(p, path: words.count >= 2 ? words[words.startIndex + 1] : nil)
            case "install":
                guard name != nil, let p = targets.first, words.count >= 2 else {
                    fail("usage: roamrun install <name> <path to .ipa or .app>. " + names(profiles))
                }
                Proc.Passing.shared.begin()
                install(p, path: words[words.startIndex + 1])
            case "ota":
                // The name is optional here, unlike every command above: nothing is
                // done *to* a device, so the .ipa is the only required argument and
                // the check runs against every device RoamRun knows.
                guard let path = words.last, path.lowercased().hasSuffix(".ipa") else {
                    fail("usage: roamrun ota [<name>] <path to .ipa>")
                }
                ota(targets, path: path, replacing: parsed.flags.contains("--replace"))
            case "key":
                let label = parsed.values["--as"]
                switch (words.first, words.count) {
                case ("create", 3):
                    guard let p = find(words[1], in: profiles) else { fail("no device named \(shellName(words[1])). " + names(profiles)) }
                    createPairing(p, others: profiles.filter { $0.id != p.id }, file: words[2], label: label)
                case ("import", 2):
                    importPairing(file: words[1], name: label)
                default:
                    fail("usage: roamrun key create <name> <file> [--as <label>] | roamrun key import <file> [--as <name>]")
                }
            case "mcp":
                // Off the main thread: it reads stdin until the client closes it.
                let asking = DeviceControlWire.Asking()
                let server = DeviceMCP(profiles: { store.load() }, looks: DeviceControlWire.socketFolder(in: ProfileStore.directory), asking: asking) {
                    try DeviceControlWire.ask($0, in: ProfileStore.directory, asking: asking)
                }
                Thread.detachNewThread { server.serve(); exit(0) }
            case "look":
                guard name != nil, let p = targets.first else { fail("usage: roamrun look <name> [file.png]. " + names(profiles)) }
                look(p, path: words.count >= 2 ? words[words.startIndex + 1] : nil)
            case "tap":
                guard name != nil, let p = targets.first, words.count == 3, let point = finite(words.dropFirst()) else {
                    fail("usage: roamrun tap <name> <x> <y> — pixels of the last `roamrun look`. " + names(profiles))
                }
                tap(p, x: point[0], y: point[1])
            case "swipe":
                guard name != nil, let p = targets.first, let numbers = finite(words.dropFirst()), (4...5).contains(numbers.count),
                      let ms = numbers.count == 5 ? Int(exactly: numbers[4].rounded()) : 300 else {
                    fail("usage: roamrun swipe <name> <x1> <y1> <x2> <y2> [milliseconds] — pixels of the last `roamrun look`. " + names(profiles))
                }
                operate(p, .init(op: "swipe", device: p.id, x: numbers[0], y: numbers[1], x2: numbers[2], y2: numbers[3], milliseconds: ms))
            case "type", "paste", "press":
                guard name != nil, let p = targets.first, words.count == 2 else {
                    fail("usage: roamrun \(args[0]) <name> \(args[0] == "press" ? "<home|lock|volume-up|volume-down>" : "<text>"). " + names(profiles))
                }
                operate(p, .init(op: args[0], device: p.id, text: words[words.startIndex + 1]))
            case "elements":
                guard name != nil, let p = targets.first else { fail("usage: roamrun elements <name> [limit]. " + names(profiles)) }
                elements(p, limit: words.count >= 2 ? Int(words[words.startIndex + 1]) : nil)
            default: print(usage); exit(0)
            }
        }
        // RunLoop, not dispatchMain(): the status Timers need a running run loop.
        RunLoop.main.run()
        exit(0)
    }

    // MARK: - Arguments

    /// What each command accepts: options (value-taking ones marked) and how many words.
    nonisolated private static let specs: [String: (options: Set<String>, words: ClosedRange<Int>)] = {
        var all = baseSpecs
        all["look"] = ([], 0...2)
        all["tap"] = ([], 0...3)
        all["swipe"] = ([], 0...6)
        all["type"] = ([], 0...2)
        all["paste"] = ([], 0...2)
        all["press"] = ([], 0...2)
        all["elements"] = ([], 0...2)
        all["mcp"] = ([], 0...0)
        all["key"] = (["--as="], 0...3)
        return all
    }()

    nonisolated private static let baseSpecs: [String: (options: Set<String>, words: ClosedRange<Int>)] = [
        "devices": (["--json", "--as=", "--replace=", "--peer="], 0...2),
        "pair": (["--mac=", "--to="], 0...2),
        "status": (["--json", "--wait="], 0...1),
        "doctor": (["--json"], 0...1),
        "down": ([], 0...1),
        "up": (["-v", "-d", detachedFlag], 0...1),
        "logs": (["--arg=", "--env=", "--url="], 0...2),
        "run": (["--scheme=", "--workspace=", "--project=", "--configuration=", "--logs", "--arg=", "--env=", "--url="], 0...1),
        "screenshot": ([], 0...2),
        "install": ([], 0...2),
        "ota": (["--replace"], 0...2),
    ]

    struct Parsed: Equatable {
        var words: [String] = []
        var flags: Set<String> = []
        var values: [String: String] = [:]
        /// Every value of an option given more than once (--arg, --env), in order.
        var lists: [String: [String]] = [:]
        var wait: Double?
        var launch: Launch { Launch(args: lists["--arg"] ?? [], env: lists["--env"] ?? [], url: values["--url"]) }
    }

    /// What the app is launched with: arguments after the bundle id, environment
    /// (NAME=value) and a URL it opens — e.g. to go straight to one screen.
    struct Launch: Equatable {
        var args: [String] = []
        var env: [String] = []
        var url: String?

        /// devicectl's launch command; the environment goes through DEVICECTL_CHILD_*.
        func argv(udid: String, bundleID: String, console: Bool) -> [String] {
            ["/usr/bin/xcrun", "devicectl", "device", "process", "launch"] + (console ? ["--console"] : [])
                + ["--terminate-existing", "--device", udid] + (url.map { ["--payload-url", $0] } ?? [])
                + [bundleID] + (args.isEmpty ? [] : ["--"] + args)   // "--": devicectl would read "-Flag" as its own
        }

        /// NAME=value pairs split at the first "=": a value may contain more.
        var environment: [(name: String, value: String)] {
            env.compactMap { pair in
                pair.firstIndex(of: "=").map { (String(pair[..<$0]), String(pair[pair.index(after: $0)...])) }
            }
        }

        func exportEnvironment() {
            for (name, value) in environment { setenv("DEVICECTL_CHILD_" + name, value, 1) }
        }
    }

    struct ArgumentError: Error, Equatable { let message: String }

    /// `--help` anywhere, except as the value of `--arg` (`--arg -h` is for the app) and as the
    /// text to type or paste.
    nonisolated static func wantsHelp(_ args: [String]) -> Bool {
        ["help", "--help", "-h"].contains(args[0])
            || args.indices.dropFirst().contains {
                ["--help", "-h"].contains(args[$0]) && args[$0 - 1] != "--arg" && !(textCommands.contains(args[0]) && $0 == 2)
            }
    }

    /// Commands whose word after the device's name is text for the device, whatever it starts
    /// with: `roamrun type iPhone -1`, `roamrun paste iPhone --help`.
    nonisolated static let textCommands: Set<String> = ["type", "paste"]

    /// Too few words is left to each command (its message lists the saved devices).
    nonisolated static func parse(_ args: [String]) -> Result<Parsed, ArgumentError> {
        guard let spec = specs[args[0]] else { return .success(Parsed()) }
        var p = Parsed()
        var i = 1
        while i < args.count {
            let a = args[i]
            if textCommands.contains(args[0]), i == 2, p.words.count == 1 {
                p.words.append(a)
                i += 1
                continue
            }
            // `--name=value`, split at the first "=": `--env=A=b` is --env with A=b.
            if a.hasPrefix("--"), let eq = a.firstIndex(of: "="), spec.options.contains(a[...eq] + "") {
                let name = String(a[..<eq]), value = String(a[a.index(after: eq)...])
                guard !value.isEmpty else {
                    return .failure(.init(message: name == "--wait" ? "--wait needs a number of seconds" : "\(name) needs a value"))
                }
                p.values[name] = value
                p.lists[name, default: []].append(value)
                i += 1
                continue
            }
            if spec.options.contains(a + "=") {
                // --arg values are often flags themselves (-ShowScreen), --wait may be negative (refused below).
                guard i + 1 < args.count, !args[i + 1].hasPrefix("-") || a == "--wait" || a == "--arg" else {
                    return .failure(.init(message: a == "--wait" ? "--wait needs a number of seconds" : "\(a) needs a value"))
                }
                p.values[a] = args[i + 1]
                p.lists[a, default: []].append(args[i + 1])
                i += 2
                continue
            }
            if a.hasPrefix("-") {
                guard !a.hasSuffix("="), spec.options.contains(a) else {
                    let hint = spec.words.upperBound > 0 ? " (a device name starting with “-”? use its id, see roamrun devices)" : ""
                    return .failure(.init(message: "\(args[0]) doesn't take \(a) — see roamrun --help\(hint)"))
                }
                p.flags.insert(a)
            } else {
                guard p.words.count < spec.words.upperBound else {
                    return .failure(.init(message: "unexpected \(shellName(a)) — see roamrun --help"))
                }
                p.words.append(a)
            }
            i += 1
        }
        // Only the name is checked: a value may be anything, even several lines.
        for pair in p.lists["--env"] ?? [] where pair.prefixMatch(of: #/[A-Za-z_][A-Za-z0-9_]*=/#) == nil {
            return .failure(.init(message: "--env takes NAME=value, not \(shellName(pair))"))
        }
        if let u = p.values["--url"], URL(string: u)?.scheme == nil {
            return .failure(.init(message: "--url needs a URL with a scheme, e.g. myapp://settings"))
        }
        if let w = p.values["--wait"] {
            guard let n = Double(w), n.isFinite, n >= 0 else { return .failure(.init(message: "--wait needs a number of seconds")) }
            p.wait = n
        }
        return .success(p)
    }

    // MARK: - Commands

    /// One device as `status --json` / `devices --json` report it. Every key is always
    /// there — an unknown value is `null`, as SKILL.md says, not a missing key.
    struct Row: Encodable {
        let name: String
        /// Stable key for scripts: off, starting, waiting, preparing, ready, error, local (on this Wi-Fi).
        let state: String
        let id: String
        let vpnAddress: String
        let udid: String?
        let status: String
        let ready: Bool
        let owner: String?
        let pid: Int32?
        let tunnelPorts: [UInt16]
        /// "wifi" or "cellular" while ready over the bridge; "cellular" also while waiting
        /// because it closed the tunnel on cellular (see `detail`); nil otherwise.
        let network: String?
        /// CoreDevice's view: "connected", "disconnected" (reachable, no tunnel yet) or "unavailable".
        let coreDevice: String?
        let detail: String?
        /// nil when unknown (not queried, or the iPhone is unreachable).
        let locked: Bool?
        /// Device control, in `status` and `devices`: connected, notConnected, refused (pair again), switchedOff,
        /// another (not the paired device answers), noApp, keptOut; null where it isn't set up.
        var deviceControl: String?

        private enum CodingKeys: String, CodingKey {
            case name, state, id, vpnAddress, udid, status, ready, owner, pid, tunnelPorts, network, coreDevice, detail, locked, deviceControl
        }

        /// `encode`, not the synthesized `encodeIfPresent`: nil becomes `null`.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(state, forKey: .state)
            try c.encode(id, forKey: .id)
            try c.encode(vpnAddress, forKey: .vpnAddress)
            try c.encode(udid, forKey: .udid)
            try c.encode(status, forKey: .status)
            try c.encode(ready, forKey: .ready)
            try c.encode(owner, forKey: .owner)
            try c.encode(pid, forKey: .pid)
            try c.encode(tunnelPorts, forKey: .tunnelPorts)
            try c.encode(network, forKey: .network)
            try c.encode(coreDevice, forKey: .coreDevice)
            try c.encode(detail, forKey: .detail)
            try c.encode(locked, forKey: .locked)
            try c.encode(deviceControl, forKey: .deviceControl)
        }
    }

    /// With `deep`, `ready` means Xcode can use the device right now: the bridge is up
    /// *and* CoreDevice sees the iPhone. The bridge alone can look ready for a while
    /// after the iPhone falls asleep (its relayed connections linger). Without it
    /// (`devices --json`), `ready` is only the bridge's word, or "on this Wi‑Fi".
    private static func row(_ p: DeviceProfile, _ e: StatusFile.Entry?, deep: Bool, by deadline: Date? = nil,
                            coreState: ((String) -> String?)? = nil) -> Row {
        let udid = e?.udid ?? p.udid
        let usable = e?.ready == true || e?.kind == .local   // on this Wi-Fi: Xcode sees it directly
        let core = deep && usable ? udid.flatMap { u in coreState.map { $0(u) } ?? coreDeviceState(u, by: deadline) } : nil
        let r = readiness(e, udid: udid, core: core, deep: deep)
        return Row(name: p.displayName, state: r.kind.rawValue, id: p.id.uuidString, vpnAddress: p.providerIP, udid: udid,
                   status: r.status, ready: r.ready,
                   owner: e.map(owner), pid: e?.pid, tunnelPorts: e?.tunnelPorts ?? [],
                   network: r.ready || e?.kind == .waiting ? e?.network : nil,
                   coreDevice: core, detail: r.detail,
                   locked: deep && r.ready ? udid.flatMap { isLocked($0, by: deadline) } : nil)
    }

    /// Whether Xcode can use the device now, and what `status` shows for it.
    /// `core` is CoreDevice's tunnelState (nil: not asked, or devicectl failed).
    nonisolated static func readiness(_ e: StatusFile.Entry?, udid: String?, core: String?, deep: Bool)
        -> (ready: Bool, kind: BridgeStatus, status: String, detail: String?) {
        let usable = e?.ready == true || e?.kind == .local   // on this Wi-Fi: Xcode sees it directly
        // No UDID yet (standing aside before it ever connected): nothing to ask CoreDevice, trust the bridge.
        let ready = usable && (!deep || udid == nil || core.map { $0 != "unavailable" } ?? false)
        var status = e?.status ?? BridgeStatus.off.title
        var kind = e?.kind ?? .off
        var detail = e.flatMap { $0.detail.isEmpty ? nil : $0.detail }
        if e?.ready == true && !ready {
            status = BridgeStatus.waiting.title
            kind = .waiting
            detail = "The bridge is up but Xcode can't reach the device (asleep, locked, off Wi-Fi, or Tailscale stuck on the device). Run `roamrun doctor` for the cause."
            // Exactly the state a blocked local network produces, so don't lose the reason.
            if e?.detail.contains(LocalNetwork.advice) == true { detail! += " — " + LocalNetwork.advice }
        } else if e?.kind == .local && !ready {
            // Still on this Wi‑Fi (so `state` stays local), but not usable right now.
            detail = "On this Wi‑Fi, but Xcode can't reach the device right now (asleep or locked, or CoreDevice didn't answer). Ask the user to unlock it and keep the screen on, then check again."
        }
        return (ready, kind, status, detail)
    }

    /// devicectl's tunnelState for this UDID; nil if devicectl failed.
    nonisolated static func coreDeviceState(_ udid: String, by deadline: Date? = nil) -> String? {
        devicectl(["list", "devices"], by: deadline).flatMap { tunnelState(in: $0, udid: udid) }
    }

    /// devicectl with only as much time as a `--wait` has left; without one, the
    /// timeouts it has always had.
    nonisolated private static func devicectl(_ args: [String], by deadline: Date?) -> [String: Any]? {
        let secs = probeSeconds(by: deadline)
        let timed = ["--timeout", "\(secs)"] + args
        guard deadline != nil else { return Proc.devicectl(timed) }
        return Proc.devicectl(timed, timeout: Double(secs) + 5)
    }

    /// How long a `status` probe may take. Each round of `--wait N` runs one
    /// `devicectl list devices` plus a lock check per ready device before the
    /// deadline is looked at again, so without this a `--wait 1` could sit for
    /// ~20s per call. devicectl
    /// refuses a --timeout below 5, which is the floor here too.
    nonisolated static func probeSeconds(by deadline: Date?, now: Date = .now) -> Int {
        guard let deadline else { return 10 }
        // Clamped as a Double first: --wait only has to be finite, and Int(1e19) traps.
        return Int(max(5, min(10, deadline.timeIntervalSince(now))).rounded(.up))
    }

    /// From `devicectl list devices` JSON's result; UDIDs compared in any case.
    nonisolated static func tunnelState(in result: [String: Any], udid: String) -> String? {
        let device = (result["devices"] as? [[String: Any]])?.first {
            (($0["hardwareProperties"] as? [String: Any])?["udid"] as? String)?.caseInsensitiveCompare(udid) == .orderedSame
        }
        return (device?["connectionProperties"] as? [String: Any])?["tunnelState"] as? String
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: (try? enc.encode(value)) ?? Data(), as: UTF8.self))
    }

    private static func devices(_ profiles: [DeviceProfile], json: Bool) -> Never {
        let live = StatusFile.read()
        if json {
            // Device control too, asked of the app as `status` does: the key is in every row, and null only where it isn't set up.
            printJSON(profiles.map { p -> Row in
                var r = row(p, live[p.id], deep: false)
                r.deviceControl = controlState(p.id, udid: r.udid).key
                return r
            })
            exit(0)
        }
        guard !profiles.isEmpty else { print(noDevices); exit(0) }
        let w = max(4, profiles.map(\.displayName.count).max() ?? 4)
        print("NAME".padding(toLength: w + 2, withPad: " ", startingAt: 0)
              + "VPN ADDRESS      UDID                       ID                                    STATUS")
        for p in profiles {
            let e = live[p.id]
            let status = e.map { "\($0.status) (\(owner($0)))" } ?? BridgeStatus.off.title
            print(p.displayName.padding(toLength: w + 2, withPad: " ", startingAt: 0)
                  + p.providerIP.padding(toLength: 17, withPad: " ", startingAt: 0)
                  + (e?.udid ?? p.udid ?? "-").padding(toLength: 27, withPad: " ", startingAt: 0)
                  + p.id.uuidString.padding(toLength: 38, withPad: " ", startingAt: 0) + status)
        }
        exit(0)
    }

    private static func status(_ targets: [DeviceProfile], json: Bool, wait: Double?) -> Never {
        if targets.isEmpty && !json { stop(noDevices) }
        var rows: [Row]
        let deadline = Date.now.addingTimeInterval(wait ?? 0)
        let budget = wait == nil ? nil : deadline   // no --wait: the probes keep their own timeouts
        repeat {
            let live = StatusFile.read()
            // One `devicectl list devices` a round, not one per device, and none if no row needs it.
            var listed: [String: Any]??
            let coreState = { (udid: String) -> String? in
                if listed == nil { listed = .some(devicectl(["list", "devices"], by: budget)) }
                return listed!.flatMap { tunnelState(in: $0, udid: udid) }
            }
            rows = targets.map { row($0, live[$0.id], deep: true, by: budget, coreState: coreState) }
            if rows.contains(where: \.ready) || Date.now >= deadline { break }
            usleep(useconds_t(min(3, max(0.1, deadline.timeIntervalSinceNow)) * 1_000_000))   // each round spawns devicectl
        } while true
        // Asked of the app once a device, for both ways of saying it.
        let controls = rows.map { r in UUID(uuidString: r.id).map { controlState($0, udid: r.udid) } }
        rows = zip(rows, controls).map { r, c in var r = r; r.deviceControl = c?.key; return r }
        // Not connected for this Mac's own Tailscale being down reads, from the app's side, like
        // the device being away: asked once, and said, where a device not connected goes over it.
        var mesh: String??
        let lines = Dictionary(zip(rows.map(\.id), controls.map { c -> String? in
            guard c == .notConnected else { return c?.line }
            if mesh == nil {
                let overTailscale = targets.contains { $0.providerID == MeshProvider.tailscale.rawValue }
                mesh = .some(overTailscale ? Self.meshProblem { try TailscaleClient.fromSettings().listDevices() } : nil)
            }
            return ControlState.notConnectedLine(mesh: mesh ?? nil)
        }), uniquingKeysWith: { a, _ in a })
        if json {
            printJSON(rows)
        } else {
            for r in rows {
                var line = "\(r.name): \(r.status)"
                if let n = r.network.flatMap(DeviceNetwork.init(rawValue:)) { line += " · \(n.title)" }
                if let owner = r.owner { line += " — \(owner)" }
                if let lo = r.tunnelPorts.min(), let hi = r.tunnelPorts.max() { line += ", tunnel ports \(lo)–\(hi)" }
                print(line)
                if let udid = r.udid { print("  UDID: \(udid)") }
                if let detail = r.detail { print("  \(detail)") }
                if r.locked == true { print("  ⚠ The device is locked — ask the user to unlock it and keep the screen on before installing or launching.") }
                if let line = lines[r.id] ?? nil { print("  Device control: \(line)") }
            }
        }
        exit(rows.contains { $0.ready } ? 0 : 1)
    }

    /// Needs the tunnel; nil when devicectl can't reach the device.
    private static func isLocked(_ udid: String, by deadline: Date? = nil) -> Bool? {
        devicectl(["device", "info", "lockState", "--device", udid], by: deadline)?["passcodeRequired"] as? Bool
    }

    /// Keeps a build where the device can fetch it over HTTPS, bridge or no
    /// bridge. Nothing is built here: exporting an .ipa needs the project's own
    /// signing settings.
    private static func ota(_ profiles: [DeviceProfile], path given: String, replacing: Bool) -> Never {
        guard FileManager.default.fileExists(atPath: given) else { stop("\(given) doesn't exist") }
        sweepStaleUnpacks(in: FileManager.default.temporaryDirectory)   // an interrupted earlier run's unpacking
        // A build script's `latest.ipa -> MyApp-1.2.ipa` would otherwise be stored
        // as the link itself: a few bytes, and nothing to serve.
        let path = URL(fileURLWithPath: given).resolvingSymlinksInPath().path
        // A trailing slash is how a shell completes a directory; .ipa is a file either way.
        guard path.lowercased().trimmingCharacters(in: ["/"]).hasSuffix(".ipa") else {
            stop("\(given) isn't an .ipa — over-the-air installs need an archive, not an .app bundle")
        }
        let running = StatusFile.read()
        let devices = profiles.map { OTA.Device(name: $0.displayName, udid: running[$0.id]?.udid ?? $0.udid) }
        do {
            var build = try OTA.read(ipa: path)
            let checked = try OTA.check(CLI.profilePlist(of: path), against: devices, path: given)
            build.expires = checked.expires
            // Not while nothing of yours can take it: `--replace` would remove the
            // build people are running to make room for one they can't install,
            // and there would be no way back to it.
            var noneOfYours = false
            if case .noneOfYours = checked.coverage { noneOfYours = true }
            let added = try OTA.add(ipa: path, build, replacing: replacing && !noneOfYours)

            print("Stored \(build.title) \(build.label) (\(OTA.size(build.size))).")
            // Which devices, not whether: an Ad Hoc profile covers the ones it
            // names, and the page offers the build to all of them at once.
            switch checked.coverage {
            case .everyDevice:
                print("  Enterprise signing — it installs on any device.")
            case .devices(let covers, let unchecked):
                print("  Installs on: \(covers.joined(separator: ", ")).")
                // Said out loud, or the line above reads as "and on no others".
                if !unchecked.isEmpty {
                    print("  Can't tell for \(unchecked.joined(separator: ", ")) — " +
                          "bridge one once and RoamRun learns its UDID.")
                }
            case .noneOfYours(let known, let unchecked):
                // Stored, not refused: the page is open to the whole tailnet and
                // the profile may name a device this Mac has never seen. But
                // nobody here can install it, and that has to be said plainly —
                // without claiming anything about the ones it couldn't check.
                print("  WARNING: its provisioning profile doesn't name " +
                      (known.isEmpty ? "any device RoamRun has a UDID for" : known.joined(separator: ", ")) + ".")
                if !unchecked.isEmpty {
                    print("  Can't tell for \(unchecked.joined(separator: ", ")) — " +
                          "bridge one once and RoamRun learns its UDID.")
                }
                print("  Whoever installs it needs a device that is in the profile; iOS refuses the rest.")
                if replacing {
                    print("  --replace was ignored: it would have removed a build that does install.")
                }
            }
            switch added.notReplaced {
            case nil:
                print("  Couldn't read the folder, so --replace may not have removed the older builds.")
            case .some(let n) where n > 0:
                print("  Couldn't remove \(n) older build\(n == 1 ? "" : "s") under that version — " +
                      "--replace left \(n == 1 ? "it" : "them") on the page.")
            default: break
            }
            let tailnetPort = AppCoordinator.otaPort
            let host: String?
            do { host = try TailscaleClient.fromSettings().selfDNSName() } catch {
                stop("\(error.localizedDescription). The build is stored; run this again once Tailscale can answer.")
            }
            guard let host else {
                stop("Tailscale didn't give this Mac a name — turn MagicDNS on for your tailnet. The build is stored.")
            }
            let url = "https://\(host):\(tailnetPort)/"
            let state = TailscaleClient.serving(port: tailnetPort)
            let here = state.root(on: host)
            let beside = state.alongside(host)
            if state.funnelled(on: host) {
                print("  WARNING: Tailscale Funnel is on for port \(tailnetPort), so that page is on the")
                print("  public internet. Turn it off: tailscale funnel --https=\(tailnetPort) off")
            }
            // `here == nil` is a free port under this name, the same reading the app
            // uses: a root left under a name the tailnet no longer knows is inert.
            if case .mounted = state,
               !(beside.isEmpty && (here == nil || AppCoordinator.isOurs(here!, on: tailnetPort))) {
                // Same three situations the app distinguishes, same three answers.
                let why: String
                if !beside.isEmpty {
                    why = "port \(tailnetPort) also carries \(beside.joined(separator: ", ")), and RoamRun keeps\n" +
                          "  a port to itself. Give it another one:\n" +
                          "    defaults write \(AppID.bundle) otaPort -int 41444"
                } else if AppCoordinator.abandoned(here) {
                    why = "port \(tailnetPort) is serving \(state.described) with nothing behind it, so a run\n" +
                          "  was killed before it gave the port back:\n" +
                          "    tailscale serve --https=\(tailnetPort) --set-path=/ off"
                } else {
                    why = "port \(tailnetPort) is serving \(state.described), which isn't RoamRun's, so that\n" +
                          "  address won't reach it. Give RoamRun another port:\n" +
                          "    defaults write \(AppID.bundle) otaPort -int 41444"
                }
                stop("the build is stored, but \(why)")
            }
            if !TailscaleClient.servingLive(port: tailnetPort, host: host) {
                // Named first when it is the cause: without certificates
                // `tailscale serve` writes nothing and still exits 0, so waiting
                // for the page is waiting for something that will never appear.
                if TailscaleClient.httpsEnabled() == false {
                    print("  Your tailnet doesn't issue HTTPS certificates, so the page can't be served.")
                    print("  Turn them on for the tailnet (Tailscale admin console › DNS › HTTPS Certificates).")
                } else {
                    print("  RoamRun publishes the page while it runs, so it has to be open; it can take")
                    print("  half a minute to appear. If it doesn't, look in Open RoamRun › ⚙ Settings ›")
                    print("  Troubleshooting › Recent messages.")
                }
            }
            print("  Open on the device: \(url)")
            print("  Anyone on your tailnet can open that page and install these builds.")
            if isatty(STDOUT_FILENO) != 0 { print(qr(url)) }
            exit(0)
        } catch {
            stop(error.localizedDescription)
        }
    }

    /// The address, for pointing the device's camera at instead of typing it.
    /// Two rows of pixels per line, so it fits a terminal.
    static func qr(_ text: String) -> String {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return "" }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return "" }
        let context = CIContext()
        guard let cg = context.createCGImage(image, from: image.extent) else { return "" }
        let w = cg.width, h = cg.height
        guard let gray = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return "" }
        gray.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let pixels = gray.data?.assumingMemoryBound(to: UInt8.self) else { return "" }
        func dark(_ x: Int, _ y: Int) -> Bool { y < 0 || y >= h ? false : pixels[y * w + x] < 128 }
        let quiet = 2
        // Black on white, said explicitly: a block character takes the terminal's
        // own foreground colour, so on a dark theme the code would come out
        // inverted — which a camera won't read.
        let paper = "\u{1b}[30;47m", plain = "\u{1b}[0m"
        var out = ""
        for row in stride(from: -quiet * 2, to: h + quiet * 2, by: 2) {
            out += paper + String(repeating: " ", count: quiet)
            for x in -quiet..<(w + quiet) {
                let top = x < 0 || x >= w ? false : dark(x, row)
                let bottom = x < 0 || x >= w ? false : dark(x, row + 1)
                out += top && bottom ? "\u{2588}" : top ? "\u{2580}" : bottom ? "\u{2584}" : " "
            }
            out += String(repeating: " ", count: quiet) + plain + "\n"
        }
        return out
    }

    /// A runtime failure (exit 1). `fail` is for usage errors (exit 2).
    private static func stop(_ why: String) -> Never {
        FileHandle.standardError.write(Data("roamrun: \(why)\n".utf8))
        exit(1)
    }

    /// The UDID of a device Xcode can reach right now (bridged, or on this
    /// Wi-Fi without a bridge) and that is unlocked; otherwise says what to do.
    private static func reachableUDID(_ profile: DeviceProfile) -> String {
        guard let udid = StatusFile.read()[profile.id]?.udid ?? profile.udid else {
            stop("\(profile.displayName)'s UDID isn't known yet — start its bridge once: roamrun up \(commandName(profile)) -d")
        }
        let core = coreDeviceState(udid)
        guard let core, core != "unavailable" else {
            stop("Xcode can't reach \(profile.displayName) (\(core ?? "unknown")). If it's away, start the bridge: roamrun up \(commandName(profile)) -d; otherwise run roamrun doctor \(commandName(profile)).")
        }
        if isLocked(udid) == true { stop("\(profile.displayName) is locked — ask the user to unlock it and keep the screen on.") }
        return udid
    }

    /// Hands over to devicectl so Ctrl-C and kill reach it directly.
    private static func exec(_ argv: [String]) -> Never {
        Proc.Passing.shared.endForExec()
        var cargs = argv.map { strdup($0) } + [nil]
        execv(argv[0], &cargs)
        stop("could not run \(argv[0]): \(String(cString: strerror(errno)))")
    }

    /// Through the tunnel like everything else: works over the bridge.
    /// What keeps this Mac off Tailscale, as its own word; nil when it is on it.
    nonisolated static func meshProblem(_ list: () throws -> [MeshDevice]) -> String? {
        do { _ = try list(); return nil } catch { return error.localizedDescription }
    }

    // Device control: the app holds the connection; these ask it.

    /// Where a device stands with being operated. `line` is nil when there is nothing to say
    /// (no pairing of our own: it was never set up).
    enum ControlState: Equatable {
        case notSetUp, connected, notConnected, refused, noApp
        /// Paired, and its switch in the app is off: commands and agents are refused.
        case switchedOff
        /// What answers at its address isn't the device the pairing was made with.
        case another
        /// The Keychain didn't give the app its list of devices switched on: none is.
        case listUnreadable
        /// The app can't be asked from here (a sandbox around this process).
        case keptOut

        /// For `status --json`: nil where device control isn't set up.
        var key: String? {
            switch self {
            case .notSetUp: nil
            case .connected: "connected"
            case .notConnected: "notConnected"
            case .refused: "refused"
            case .switchedOff: "switchedOff"
            case .listUnreadable: "listUnreadable"
            case .another: "another"
            case .noApp: "noApp"
            case .keptOut: "keptOut"
            }
        }

        /// `mesh`: what keeps this Mac itself off Tailscale, when something does.
        static func notConnectedLine(mesh: String?) -> String {
            guard let mesh else { return ControlState.notConnected.line! }
            return "paired, not connected — \(mesh): until then nothing on this Mac reaches the device"
        }

        var line: String? {
            switch self {
            case .notSetUp: nil
            case .connected: "connected"
            case .notConnected: "paired, not connected — the app keeps trying; it can connect only while the device is on a Wi‑Fi"
            case .refused: "the pairing can no longer be used (removed on the device, made by a build that didn't keep the device's key with it, or this Mac can't read what it saved) — the user pairs again in the RoamRun app, on the device's page"
            case .another: "paired, but what answers at its address isn't the device the pairing was made with — it is told nothing of this Mac's and sent no input. Erased or replaced: the user pairs again in the RoamRun app; otherwise something else has its address"
            case .listUnreadable: "paired, off — the Keychain didn't give the RoamRun app its list of devices switched on (the Keychain is locked, it was refused, or the item there isn't RoamRun's); the device's page in the app says what to do"
            case .switchedOff: "paired, switched off — the user switches it on in the RoamRun app, on the device's page"
            case .noApp: "paired; the RoamRun app, which holds the connection, isn't running (or is a build without device control)"
            case .keptOut: "paired; this process isn't allowed to reach the RoamRun app (a sandbox around it?) — run it outside, or use the MCP tools"
            }
        }
    }

    private static func controlState(_ id: UUID, udid: String?) -> ControlState {
        guard let udid, DeviceControlWire.hasPairing(udid: udid, in: ProfileStore.directory) else {
            return .notSetUp
        }
        let r: DeviceControlWire.Response
        do { r = try DeviceControlWire.ask(.init(op: "state", device: id), in: ProfileStore.directory, wait: DeviceControlWire.stateWait) } catch {
            if case DeviceControlWire.WireError.keptOut = error { return .keptOut }
            return .noApp
        }
        // In the order the app's page says them: what must be mended first comes first.
        if r.ok, r.refused == true { return .refused }
        if r.ok, r.another == true { return .another }
        if r.ok, r.listUnreadable == true { return .listUnreadable }
        if r.ok, r.allowed == false { return .switchedOff }
        // A pairing the app hasn't picked up yet answers as not set up there.
        guard r.ok, r.open != true else { return r.ok ? .connected : .notConnected }
        return r.refused == true ? .refused : .notConnected
    }

    /// A pairing for another Mac: made in this process, written to `file` and kept nowhere here.
    /// Under an identity of its own, so the device lists it on its own and it can be removed
    /// there alone; this Mac's own pairing stays as it is.
    private static func createPairing(_ profile: DeviceProfile, others: [DeviceProfile], file: String, label: String?) -> Never {
        let out = URL(fileURLWithPath: file).standardizedFileURL
        // The file is had before the pairing, and written through what was had: checked now and
        // written after the code was entered, another could be put there in between.
        let fd: Int32
        do { fd = try reserve(out.path) } catch { fail((error as? ArgumentError)?.message ?? "\(error)") }
        // Interrupted, hung up on (an SSH session that ends) or told to end: nothing is left.
        reserved = (strdup(out.path), fd)
        for sign in [SIGINT, SIGHUP, SIGTERM] {
            signal(sign) { sign in
                if let made = CLI.reserved { CLI.removeReserved(made.path, made.fd) }
                _exit(128 + sign)
            }
        }
        /// Nothing is left where the pairing was to go.
        func stop(_ why: String) -> Never {
            out.path.withCString { CLI.removeReserved($0, fd) }
            CLI.reserved = nil   // after: a signal in between still finds what to remove
            close(fd)
            CLI.stop(why)
        }
        let label = label ?? "RoamRun (\(out.deletingPathExtension().lastPathComponent))"
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            let listening = try DevicePairing(name: label, host: UUID().uuidString)
            print("On \(profile.displayName) (iOS 27 or later, on this Mac's Wi‑Fi): Settings › Privacy & Security › Developer Mode › “\(listening.name)”.")
            let paired = try listening.accept { print("Enter this code there: \($0)") }
            let known = others.compactMap { o in o.udid.map { (udid: $0, name: o.displayName) } }
            let verdict = DeviceControlHub.verdict(expected: profile.udid, paired: paired.udid, others: known)
            let withdraw = "Remove “\(listening.name)” on it, in that list."
            switch verdict {
            case .savedAs(let other): stop("\(paired.name) paired, which is saved here as “\(other)”, not “\(profile.displayName)”. Nothing was written. \(withdraw)")
            case .nameless: stop("\(paired.name) paired without saying which device it is. Nothing was written. \(withdraw)")
            case .another: stop("\(paired.name) paired, and it isn't “\(profile.displayName)” as that is saved here (another UDID). Nothing was written. \(withdraw)")
            case .expected, .toProve: break
            }
            // Tried once from here: a pairing that connects nowhere isn't worth taking anywhere.
            let check = DeviceSession(ip: profile.providerIP, port: profile.remotePairingPort, pairing: { paired.pairing })
            defer { check.close() }
            var unreached: String?
            do { try check.connect() } catch { unreached = "\(error)" }
            if verdict == .toProve, let unreached {
                stop("\(paired.name) paired, but that pairing opens no connection to “\(profile.displayName)” at \(profile.providerIP) (\(unreached)). Nothing was written. \(withdraw)")
            }
            var device = profile
            device.udid = Self.sharedUDID(saved: profile.udid, paired: paired.udid)
            let shared = SharedPairing(device: device, pairing: String(decoding: paired.pairing, as: UTF8.self))
            guard let data = try? JSONEncoder().encode(shared), Self.write(data, to: fd) else {
                stop("can't write \(out.path). \(withdraw)")
            }
            // Written to what was made at the start: if that name is another file's by now, the
            // pairing isn't where it is said to be.
            guard DeviceControlWire.names(out.path, theFileOf: fd) else {
                stop("\(out.path) was replaced while the pairing was made: the pairing isn't in it. \(withdraw)")
            }
            reserved = nil   // done: an interrupt from here on leaves the file
            close(fd)
            print("Wrote \(out.path)" + (unreached.map { " (it couldn't be tried from here: \($0))" } ?? ", and it connects."))
            print("It is a key to \(profile.displayName): whoever has it and reaches \(profile.providerIP) can see and operate the device. On the other Mac: roamrun key import <that file>")
            print("To withdraw it: remove “\(listening.name)” on the device, in that list.")
            exit(0)
        } catch {
            stop("\(error)")
        }
    }

    /// The file a pairing is being written to, for the handler that removes it when interrupted.
    nonisolated(unsafe) private static var reserved: (path: UnsafeMutablePointer<CChar>, fd: Int32)?

    /// Removes what was made for a pairing — that file, not whatever its name has come to be.
    /// Only what a signal handler may call.
    nonisolated static func removeReserved(_ path: UnsafePointer<CChar>, _ fd: Int32) {
        var held = stat(), named = stat()
        if fstat(fd, &held) == 0, lstat(path, &named) == 0, held.st_dev == named.st_dev, held.st_ino == named.st_ino { unlink(path) }
    }

    /// A new file of the owner's alone, or nothing: never one that is there, never through a link.
    nonisolated static func reserve(_ path: String) throws -> Int32 {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw ArgumentError(message: errno == EEXIST ? "\(path) exists: name a file that doesn't" : "can't make \(path): \(String(cString: strerror(errno)))")
        }
        return fd
    }

    nonisolated static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            var done = 0
            while done < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress! + done, bytes.count - done)
                if n <= 0 { return false }
                done += n
            }
            return true
        }
    }

    /// The UDID a pairing travels under: the paired device's own, which is what it was proved
    /// with — in the saved one's spelling when that is the same device, and the saved one only
    /// when the device named none.
    nonisolated static func sharedUDID(saved: String?, paired: String) -> String? {
        guard !paired.isEmpty else { return saved }
        if let saved, saved.caseInsensitiveCompare(paired) == .orderedSame { return saved }
        return paired
    }

    private static func importPairing(file: String, name: String?) -> Never {
        let path = URL(fileURLWithPath: file).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else { fail("\(path) doesn't exist") }
        let r = askApp(.init(op: "import", device: UUID(), path: path, text: name))
        // Not taken in, the file is where it was — and what it was.
        guard r.ok else { stop("import failed: \(r.error ?? "no answer")\n\(path) was left as it is: a pairing in it is still a key to the device.") }
        print("\(r.name ?? "The device") is saved with its pairing." + (r.error == nil ? " Try: roamrun look \(r.name.map(shellName) ?? "<name>")" : ""))
        // An app from before it said so says it by saying nothing else.
        if r.removed == true || (r.removed == nil && r.error == nil) { print("\(path) is removed.") }
        // Said as it is: a key left where it was is not one that is gone, and a device not switched on isn't usable yet.
        if let more = r.error {
            FileHandle.standardError.write(Data("roamrun: \(more)\n".utf8))
            exit(1)
        }
        exit(0)
    }

    /// A look takes a file's place whole, or none: a folder of that name is left as it is (it was
    /// removed with what it held), and so is the file there when the write fails.
    nonisolated static func put(look made: URL, at file: URL) throws {
        defer { try? FileManager.default.removeItem(at: made) }
        var folder: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &folder), folder.boolValue {
            throw ArgumentError(message: "it is a folder")
        }
        try Data(contentsOf: made).write(to: file, options: .atomic)
        chmod(file.path, 0o600)   // a screen, with whatever was on it
    }

    private static func askApp(_ request: DeviceControlWire.Request) -> DeviceControlWire.Response {
        do {
            return try DeviceControlWire.ask(request, in: ProfileStore.directory)
        } catch DeviceControlWire.WireError.noApp {
            stop("the RoamRun app isn't running (or is a build without device control): it holds the connection to the device")
        } catch {
            stop("couldn't ask the RoamRun app: \(error)")
        }
    }

    /// The device's screen now, as PNG. Prints the path, then the size a tap's point is in.
    private static func look(_ profile: DeviceProfile, path: String?) -> Never {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let file = URL(fileURLWithPath: path ?? "\(fileSafe(profile.displayName))-look-\(f.string(from: .now)).png").standardizedFileURL
        guard file.pathExtension.lowercased() == "png" else { fail("the file must end in .png") }
        // The app writes it where only RoamRun keeps things; it is this command, run by the user in
        // their own folder, that puts it there (the app would be asked for access to it instead).
        let made = DeviceControlWire.socketFolder(in: ProfileStore.directory).appendingPathComponent("look-\(UUID().uuidString).png")
        let r = askApp(.init(op: "look", device: profile.id, path: made.path))
        guard r.ok, let w = r.width, let h = r.height else { stop("look failed: \(r.error ?? "no answer")") }
        do { try put(look: made, at: file) } catch {
            stop("look failed: can't write \(file.path) (\((error as? ArgumentError)?.message ?? error.localizedDescription))")
        }
        print(file.path)
        print("\(w) x \(h)")
        exit(0)
    }

    /// One tap, at a point in the pixels of the last look. Operates the device.
    private static func tap(_ profile: DeviceProfile, x: Double, y: Double) -> Never {
        operate(profile, .init(op: "tap", device: profile.id, x: x, y: y))
    }

    /// Something done to the device: silent when it went (but see `typed`), the reason when it didn't.
    private static func operate(_ profile: DeviceProfile, _ request: DeviceControlWire.Request) -> Never {
        let r = askApp(request)
        guard r.ok else { stop("\(request.op) failed: \(r.error ?? "no answer")") }
        if request.op == "type", let note = request.text.flatMap(DeviceControlWire.typed) { print(note) }
        exit(0)
    }

    /// Accessibility's captions, one a line. Can scroll the screen.
    private static func elements(_ profile: DeviceProfile, limit: Int?) -> Never {
        let r = askApp(.init(op: "elements", device: profile.id, limit: limit))
        guard r.ok, let captions = r.captions else { stop("elements failed: \(r.error ?? "no answer")") }
        captions.forEach { print($0) }
        if r.complete != true {
            FileHandle.standardError.write(Data("roamrun: \(captions.count) elements; the walk was cut short, there may be more\n".utf8))
        }
        exit(0)
    }

    private static func screenshot(_ profile: DeviceProfile, path: String?) -> Never {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: .now)
        let file = URL(fileURLWithPath: path ?? "\(fileSafe(profile.displayName))-\(stamp).png").standardizedFileURL
        guard file.pathExtension.lowercased() == "png" else { fail("the file must end in .png") }
        let udid = reachableUDID(profile)
        let capture = ["devicectl", "--quiet", "device", "capture", "screenshot", "--device", udid, "--destination", file.path]
        var r = Proc.run("/usr/bin/xcrun", capture, timeout: 60)
        if r.status != 0, r.err.contains("CoreDeviceError") {   // e.g. the ~42s control-channel rebuild: once more
            sleep(2)
            r = Proc.run("/usr/bin/xcrun", capture, timeout: 60)
        }
        guard r.status == 0, FileManager.default.fileExists(atPath: file.path) else {
            stop("screenshot failed: " + (r.err.split(separator: "\n").first.map(String.init) ?? "devicectl exited \(r.status)"))
        }
        print(file.path)
        exit(0)
    }

    /// devicectl installs any .app or .ipa signed for this device. Check the
    /// signing first: the usual failure, and devicectl's error for it is cryptic.
    private static func install(_ profile: DeviceProfile, path: String) -> Never {
        guard FileManager.default.fileExists(atPath: path) else { stop("no such file: \(path)") }
        guard [".ipa", ".app"].contains(where: path.lowercased().trimmingCharacters(in: ["/"]).hasSuffix) else {
            stop("\(path) is not an .ipa or .app")
        }
        let tmp = FileManager.default.temporaryDirectory
        sweepStaleUnpacks(in: tmp)   // a Ctrl-C during an earlier install (or ota) skipped its cleanUp
        let udid = reachableUDID(profile)
        guard path.lowercased().hasSuffix(".ipa") else {
            checkSigning(profile, udid: udid, path: path)
            exec(["/usr/bin/xcrun", "devicectl", "device", "install", "app", "--device", udid, path])
        }
        // devicectl documents .app bundles only: unpack the .ipa and hand it the .app inside.
        // Our pid in the name: the install can outlast the sweep's hour (a big app over a slow link).
        let dir = tmp.appendingPathComponent("roamrun-ipa-\(getpid())-\(UUID().uuidString)")
        let cleanUp = { try? FileManager.default.removeItem(at: dir) }   // exit() skips defer
        let unzip = Proc.run("/usr/bin/ditto", ["-x", "-k", path, dir.path], timeout: 300)
        guard unzip.status == 0 else { cleanUp(); stop("couldn't unpack \(path): \(firstLine(unzip.err) ?? "ditto exited \(unzip.status)")") }
        let payload = dir.appendingPathComponent("Payload")
        guard let app = OTA.appBundle(in: payload)
        else { cleanUp(); stop("\(path) has no Payload/*.app inside — not an iOS app archive?") }
        // A crafted archive could make Payload or Payload/X.app a link to somewhere else on this Mac.
        let appURL = payload.appendingPathComponent(app)
        guard appURL.resolvingSymlinksInPath().path.hasPrefix(dir.resolvingSymlinksInPath().path + "/Payload/") else {
            cleanUp(); stop("\(path)'s Payload/\(app) links outside the archive — not installing it")
        }
        // Checked on this very .app: a separate partial unpack could land on another
        // bundle of a multi-app archive and vouch for one that isn't installed.
        checkSigning(profile, udid: udid, path: appURL.path, shown: path, cleanUp: { _ = cleanUp() })
        let status = visible(["/usr/bin/xcrun", "devicectl", "device", "install", "app", "--device", udid,
                              payload.appendingPathComponent(app).path])
        cleanUp()
        exit(status)
    }

    /// Unpacked archives an interrupted `install` or `ota` (or their signing and icon
    /// checks) left behind. An hour is longer than the checks; an install can take longer,
    /// so its folder carries its pid and stays while that process lives — that process: one
    /// that started after the folder was made only has its pid.
    nonisolated static func sweepStaleUnpacks(in tmp: URL, now: Date = .now,
                                              started: (Int32) -> Double? = StatusFile.startTime(of:)) {
        let fm = FileManager.default
        let ours = ["roamrun-ipa-", "roamrun-install-", "roamrun-ota-", "roamrun-icon-"]
        for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where ours.contains(where: name.hasPrefix) {
            let url = tmp.appendingPathComponent(name)
            let made = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? now
            if name.hasPrefix("roamrun-ipa-"), let pid = Int32(name.dropFirst(12).prefix { $0 != "-" }),
               let since = started(pid), since <= made.timeIntervalSince1970 + 1 { continue }
            if made < now.addingTimeInterval(-3600) { try? fm.removeItem(at: url) }
        }
    }

    /// App Store builds and builds not provisioned for this device fail with a
    /// cryptic devicectl error — say what's wrong before trying.
    /// `shown`: how to name it (the .ipa it came from); `cleanUp` runs before a refusal exits.
    private static func checkSigning(_ profile: DeviceProfile, udid: String, path: String, shown: String? = nil,
                                     cleanUp: () -> Void = {}) {
        let name = shown ?? path
        switch provisioning(of: path) {
        case .appStore:
            cleanUp(); stop("\(name) is signed for App Store / TestFlight and can't be installed directly. Export it for Debugging, Release Testing (Ad Hoc) or Enterprise.")
        case .devices(let list) where !list.contains(where: { $0.caseInsensitiveCompare(udid) == .orderedSame }):
            cleanUp(); stop("\(name) isn't signed for \(profile.displayName) (UDID \(udid) is not in its provisioning profile). Add the device to the profile and export again.")
        case .unknown:
            let info = NSDictionary(contentsOfFile: (path as NSString).appendingPathComponent("Info.plist"))
            if (info?["DTPlatformName"] as? String)?.hasSuffix("simulator") == true {
                cleanUp(); stop("\(name) is a Simulator build — build for a device (Any iOS Device / the device itself).")
            }
            FileHandle.standardError.write(Data("roamrun: couldn't read \(name)'s provisioning profile — if the install fails, check it's a device build signed for \(profile.displayName)\n".utf8))
        default:
            break
        }
    }

    /// Runs a tool with its output going straight to this terminal.
    private static func visible(_ argv: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: argv[0])
        task.arguments = Array(argv.dropFirst())
        Proc.Passing.shared.launching()
        do { try task.run() } catch {
            Proc.Passing.shared.launched(nil)
            stop("could not run \(argv[0]): \(error.localizedDescription)")
        }
        Proc.Passing.shared.launched(task)
        task.waitUntilExit()
        Proc.Passing.shared.childEnded()
        return task.terminationStatus
    }

    /// Build → install → launch, for the project in the current folder.
    private static func runApp(_ profile: DeviceProfile, scheme: String?, workspace: String?, project: String?,
                               configuration: String, logs: Bool, launch: Launch) -> Never {
        let udid = reachableUDID(profile)
        let container: [String]
        if let workspace { container = ["-workspace", workspace] }
        else if let project { container = ["-project", project] }
        else {
            let here = (try? FileManager.default.contentsOfDirectory(atPath: ".")) ?? []
            let workspaces = here.filter { $0.hasSuffix(".xcworkspace") }, projects = here.filter { $0.hasSuffix(".xcodeproj") }
            if workspaces.count == 1 { container = ["-workspace", workspaces[0]] }
            else if workspaces.isEmpty, projects.count == 1 { container = ["-project", projects[0]] }
            else if workspaces.isEmpty && projects.isEmpty { stop("no .xcworkspace or .xcodeproj here — cd into the project, or pass --workspace / --project") }
            else { stop("more than one project here: \((workspaces + projects).joined(separator: ", ")) — pass --workspace or --project") }
        }
        let chosen: String
        if let scheme { chosen = scheme }
        else {
            // Generous: the first -list of a project can resolve its packages.
            let list = Proc.run("/usr/bin/xcrun", ["xcodebuild", "-list", "-json"] + container, timeout: 300)
            let root = (try? JSONSerialization.jsonObject(with: Data(list.out.utf8))) as? [String: Any]
            let schemes = ((root?["workspace"] ?? root?["project"]) as? [String: Any])?["schemes"] as? [String] ?? []
            guard schemes.count == 1 else {
                stop(schemes.isEmpty ? "couldn't list the schemes (\(firstLine(list.err) ?? "xcodebuild exited \(list.status)")) — pass --scheme"
                                     : "which scheme? \(schemes.joined(separator: ", ")) — pass --scheme")
            }
            chosen = schemes[0]
        }
        let build = ["/usr/bin/xcrun", "xcodebuild"] + container
            + ["-scheme", chosen, "-configuration", configuration, "-destination", "id=\(udid)", "-allowProvisioningUpdates"]
        print("Building \(chosen) for \(profile.displayName)…")
        guard visible(build + ["-quiet", "build"]) == 0 else { stop("the build failed (see above)") }

        // The built .app: the build settings of the target that produces one.
        let settings = Proc.run(build[0], Array(build.dropFirst()) + ["-showBuildSettings", "-json"], timeout: 300)
        let targets = (try? JSONSerialization.jsonObject(with: Data(settings.out.utf8))) as? [[String: Any]] ?? []
        guard let s = appTarget(in: targets, scheme: chosen), let dir = s["TARGET_BUILD_DIR"], let wrapper = s["WRAPPER_NAME"] else {
            stop("built, but couldn't find the .app in the build settings (\(firstLine(settings.err) ?? "no app target"))")
        }
        let app = (dir as NSString).appendingPathComponent(wrapper)
        guard let bundleID = NSDictionary(contentsOfFile: (app as NSString).appendingPathComponent("Info.plist"))?["CFBundleIdentifier"] as? String
        else { stop("built, but \(app) has no bundle identifier") }

        _ = reachableUDID(profile)   // a long build: it may have locked or dropped off meanwhile
        checkSigning(profile, udid: udid, path: app)
        print("Installing \(wrapper)…")
        guard visible(["/usr/bin/xcrun", "devicectl", "device", "install", "app", "--device", udid, app]) == 0 else {
            stop("the install failed (see above)")
        }
        print("Launching \(bundleID)…")
        if logs { launchWithConsole(udid: udid, bundleID: bundleID, launch: launch) }
        launch.exportEnvironment()
        exec(launch.argv(udid: udid, bundleID: bundleID, console: false))
    }

    /// The target `run` installs: an application (not an App Clip, extension or
    /// watch app), the scheme's own target first.
    nonisolated static func appTarget(in targets: [[String: Any]], scheme: String) -> [String: String]? {
        let apps = targets.compactMap { $0["buildSettings"] as? [String: String] }
            .filter { $0["WRAPPER_EXTENSION"] == "app" && $0["PLATFORM_NAME"] != "watchos" }
        let real = apps.filter { $0["PRODUCT_TYPE"] == "com.apple.product-type.application" }
        let pool = real.isEmpty ? apps : real
        return pool.first { $0["TARGET_NAME"] == scheme } ?? pool.first
    }

    private static func firstLine(_ s: String) -> String? {
        s.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init)
    }

    enum Provisioning: Equatable { case devices([String]), allDevices, appStore, unknown }

    /// Reads embedded.mobileprovision from an .app or (unzipping) an .ipa.
    static func provisioning(of path: String) -> Provisioning {
        profilePlist(of: path).map(parseProvisioning) ?? .unknown
    }

    /// The whole profile: OTA also needs the entitlements, which tell a
    /// Development build (installs only through the bridge) from an Ad Hoc one.
    static func profilePlist(of path: String) -> [String: Any]? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var profile = URL(fileURLWithPath: path).appendingPathComponent("embedded.mobileprovision")
        if path.lowercased().hasSuffix(".ipa") {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = Proc.run("/usr/bin/unzip", ["-qo", path, "Payload/*.app/embedded.mobileprovision", "-d", dir.path], timeout: 30)
            let payload = dir.appendingPathComponent("Payload")
            guard let app = OTA.appBundle(in: payload) else { return nil }
            guard let real = OTA.inside(payload.appendingPathComponent(app)
                .appendingPathComponent("embedded.mobileprovision"), dir) else { return nil }
            profile = real
        }
        let decoded = Proc.run("/usr/bin/security", ["cms", "-D", "-i", profile.path], timeout: 10).out
        guard let data = decoded.data(using: .utf8) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    nonisolated static func parseProvisioning(_ plist: [String: Any]) -> Provisioning {
        if let devices = plist["ProvisionedDevices"] as? [String] { return .devices(devices) }
        if plist["ProvisionsAllDevices"] as? Bool == true { return .allDevices }
        return .appStore   // neither a device list nor Enterprise: App Store / TestFlight
    }

    /// Another process bridges the device. Ready → nothing to do; still coming up → say so.
    /// Another `roamrun up` already runs for it, in any state. Its errors are retried, not
    /// given up: a second would take the entry back and forth with it, and `down` stops only
    /// whichever holds the entry then — the other bridges again once the device answers.
    private static func refuseSecondUp(_ profile: DeviceProfile) {
        guard let e = otherUp(StatusFile.read()[profile.id], me: getpid()) else { return }
        if e.kind == .local {
            print("\(profile.displayName) is on this Wi\u{2011}Fi and already watched by roamrun up (pid \(e.pid)) — it takes over when the device leaves.")
            exit(0)
        }
        stop("\(profile.displayName) is already handled by roamrun up (pid \(e.pid)): \(e.status). It keeps retrying; " +
             "roamrun down \(commandName(profile)) stops it.")
    }

    /// The entry when it is another live `roamrun up`'s (`read` drops dead ones), in any state.
    nonisolated static func otherUp(_ e: StatusFile.Entry?, me: Int32) -> StatusFile.Entry? {
        guard let e, e.cli == true, e.pid != me else { return nil }
        return e
    }

    private static func alreadyBridged(_ profile: DeviceProfile, _ e: StatusFile.Entry) -> Never {
        if e.ready {
            print("\(profile.displayName) is already bridged by \(owner(e)) — ready for Xcode.")
            exit(0)
        }
        stop("\(profile.displayName) is being bridged by \(owner(e)) (\(e.status)). Use it once it's ready, or run roamrun down \(commandName(profile)) first.")
    }

    /// devicectl can't attach to a running process, so this relaunches the app
    /// with `--console`. OS_ACTIVITY_DT_MODE mirrors os_log to stderr, as Xcode does.
    private static func logs(_ profile: DeviceProfile, bundleID: String, launch: Launch) -> Never {
        launchWithConsole(udid: reachableUDID(profile), bundleID: bundleID, launch: launch)
    }

    /// Relaunch with print / os_log streamed here until Ctrl-C.
    private static func launchWithConsole(udid: String, bundleID: String, launch: Launch) -> Never {
        setenv("DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE", "enable", 1)
        launch.exportEnvironment()   // after: the caller's --env OS_ACTIVITY_DT_MODE=… wins
        exec(launch.argv(udid: udid, bundleID: bundleID, console: true))
    }

    private static func down(_ profile: DeviceProfile) -> Never {
        guard let e = StatusFile.read()[profile.id] else {
            print("\(profile.displayName) is not bridged."); exit(0)
        }
        let who = owner(e)   // before it exits and the pid stops resolving
        // Always tell the app too: even when the CLI owns the device, the app
        // may still have it on its restore list and would take it back.
        for name in [stopNotification, legacyStopNotification] {
            DistributedNotificationCenter.default().postNotificationName(
                name, object: profile.id.uuidString, userInfo: nil, deliverImmediately: true)
        }
        if e.cli == true, e.pid != getpid() { kill(e.pid, SIGTERM) }   // its handler tears down dns-sd / log children
        // Wait for the owner to clear its status entry.
        var tries = 0
        while StatusFile.read()[profile.id] != nil && tries < 50 { usleep(100_000); tries += 1 }
        guard StatusFile.read()[profile.id] == nil else { stop("\(who) did not stop the bridge") }
        print("Stopped \(profile.displayName) (\(who)).")
        exit(0)
    }

    /// The display name is user/network supplied: keep it to one safe path component.
    private static func fileSafe(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || "-_ ".contains($0) ? $0 : "_" })
    }

    /// Internal: marks the background copy spawned by `up -d`.
    nonisolated private static let detachedFlag = "--detached-child"

    /// `up -d`: re-launch ourselves in a new session with output going to a
    /// log file, wait until the bridge settles, then hand the prompt back.
    private static func detach(_ profile: DeviceProfile, verbose: Bool) -> Never {
        if StatusFile.otherOwner(of: profile.id) != nil, let e = StatusFile.read()[profile.id] {
            alreadyBridged(profile, e)
        }
        // Two started together both found nobody, and the second rotated the first's log away
        // from under it: from the check to the child's own claim, one at a time per device.
        var turn = upTurn(for: profile.id, in: ProfileStore.directory)
        refuseSecondUp(profile)   // before the log below is rotated away from the one running
        let logURL = detachedLog(profile)
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep the previous run's log (an earlier failure may point at it).
        let previous = logURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: logURL, to: previous)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let log = try? FileHandle(forWritingTo: logURL) else { stop("can't write \(logURL.path)") }

        let child = Process()
        child.executableURL = Bundle.main.executableURL?.resolvingSymlinksInPath()
        child.arguments = ["up", profile.id.uuidString, detachedFlag] + (verbose ? ["-v"] : [])
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = log
        child.standardError = log
        do { try child.run() } catch { stop("could not start the background bridge: \(error.localizedDescription)") }

        // Wait (≤60s) for Ready; a slower start keeps going in the background.
        var last = "", lastKind = BridgeStatus.off
        for _ in 0..<120 {
            usleep(500_000)
            guard child.isRunning else {
                // It exits on an error retrying can't fix (see up); its last line says which.
                let tail = (try? String(contentsOf: logURL, encoding: .utf8)).flatMap { $0.split(separator: "\n").last.map(String.init) }
                stop("the background bridge exited\(tail.map { ": \($0)" } ?? "") — see \(logURL.path)")
            }
            guard let e = StatusFile.read()[profile.id], e.pid == child.processIdentifier else { continue }
            endTurn(&turn)   // the child holds the device now: the next `up` sees it
            if e.status != last { last = e.status; print("  \(e.status)") }
            lastKind = e.kind
            if e.ready || e.kind == .local { break }
        }
        let pid = child.processIdentifier
        switch lastKind {
        case .ready:
            print("\(profile.displayName) is bridged in the background (pid \(pid)).")
        case .local:
            print("\(profile.displayName) is on this Wi‑Fi, so Xcode reaches it directly. The bridge waits in the background (pid \(pid)) and takes over when it leaves.")
        default:
            print("\(profile.displayName) isn't ready yet (\(last.isEmpty ? "no status" : last)). The bridge keeps trying in the background (pid \(pid)).")
        }
        print("""
          Log:  \(logURL.path)
          Stop: roamrun down \(commandName(profile))
        """)
        exit(lastKind == .ready || lastKind == .local ? 0 : 1)
    }

    /// This `up -d`'s turn at the device: waits for another's to end (it ends when its child has
    /// claimed the device, or with its process). The descriptor to close, or nil when no lock
    /// could be made — then as before, unserialized.
    nonisolated static func upTurn(for id: UUID, in directory: URL, wait: Bool = true) -> Int32? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("up-\(id.uuidString).lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, wait ? LOCK_EX : LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        return fd
    }

    /// Ends a turn, once: asked again (each round of the wait asks) it closes nothing — the
    /// number may be another file's by then.
    nonisolated static func endTurn(_ turn: inout Int32?) {
        if let fd = turn { close(fd) }
        turn = nil
    }

    /// Where `up -d`'s bridge writes; the previous run's is kept beside it as `.log.1`.
    private static func detachedLog(_ profile: DeviceProfile) -> URL {
        let safeName = fileSafe(profile.displayName)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/RoamRun", isDirectory: true)
            .appendingPathComponent("\(safeName.isEmpty ? profile.id.uuidString : safeName).log")
    }

    /// The background bridge's stdout and stderr are its log file; one left running for weeks
    /// would fill the disk. Past `limit`, the file becomes `.log.1` (replacing that) and a new
    /// one is opened under the same descriptors. A rename that fails changes nothing: the
    /// writing goes on where it was, and nothing is deleted.
    nonisolated static func rotateLog(at url: URL, limit: Int64 = 10 << 20, fds: [Int32] = [STDOUT_FILENO, STDERR_FILENO]) {
        var st = stat()
        guard let first = fds.first, fstat(first, &st) == 0, st.st_size > limit else { return }
        let fm = FileManager.default
        let previous = url.appendingPathExtension("1")
        let rolling = url.appendingPathExtension("rolling"), backup = url.appendingPathExtension("1.backup")
        // Each step can be undone until the new file is open; only then does the old `.1` go.
        try? fm.removeItem(at: rolling)
        try? fm.removeItem(at: backup)
        guard (try? fm.moveItem(at: url, to: rolling)) != nil else { return }
        let hadPrevious = fm.fileExists(atPath: previous.path)
        func undo() {
            if fm.fileExists(atPath: previous.path), !fm.fileExists(atPath: rolling.path) {
                try? fm.moveItem(at: previous, to: rolling)   // step 3 had happened
            }
            if hadPrevious { try? fm.moveItem(at: backup, to: previous) }
            try? fm.moveItem(at: rolling, to: url)
        }
        guard !hadPrevious || (try? fm.moveItem(at: previous, to: backup)) != nil else { return undo() }
        guard (try? fm.moveItem(at: rolling, to: previous)) != nil else { return undo() }
        let fresh = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fresh >= 0 else { return undo() }   // still writing to the renamed file: it gets its name back
        try? fm.removeItem(at: backup)
        for fd in fds { dup2(fresh, fd) }
        close(fresh)
    }

    private static func up(_ profile: DeviceProfile, verbose: Bool, detachedChild: Bool = false) {
        if StatusFile.otherOwner(of: profile.id) != nil, let e = StatusFile.read()[profile.id] {
            alreadyBridged(profile, e)
        }
        refuseSecondUp(profile)
        var logRotation: Timer?
        if detachedChild {
            // Own session: closing the terminal / ending SSH doesn't reach us.
            setsid()
            signal(SIGHUP, SIG_IGN)
            let log = detachedLog(profile)
            logRotation = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in rotateLog(at: log) }
        }
        let bridge = ProxyBridge(profile: profile)
        self.bridge = bridge
        bridge.onLog = { m in if verbose { print("    \(m)") } }
        bridge.onYield = { other in
            print("\(profile.displayName): another roamrun up (pid \(other.pid)) is already handling it — exiting.")
            exit(0)
        }
        bridge.onUDID = { udid in   // the app saves it too; without this, CLI-only use never learns it
            _ = ProfileStore().update { all in
                guard let i = all.firstIndex(where: { $0.id == profile.id }), all[i].udid == nil else { return }
                all[i].udid = udid
            }
        }
        bridge.onProfileChange = { moved in   // save where the device answers now, as the app does
            var found = false
            let saved = ProfileStore().update { all in
                guard let i = all.firstIndex(where: { $0.id == moved.id }) else { return }
                found = true
                all[i].providerIP = moved.providerIP
                all[i].remotePairingPort = moved.remotePairingPort
                all[i].providerHostName = moved.providerHostName
            }
            guard found || !saved else { return }   // a lock we couldn't take never ran the closure
            print("  \(moved.displayName) now answers at \(moved.providerIP):\(moved.remotePairingPort)\(saved ? " (saved)" : " (couldn't save it)")")
        }

        // Print status transitions, not a stream of identical lines.
        var last = ""
        let ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                var line = bridge.status.title
                switch bridge.state {
                case .error(let m): line += " — \(m)"
                case .starting(let step): line += " — \(step)"
                default: break
                }
                if bridge.status == .ready, let n = bridge.network { line += " · \(n.title)" }
                if bridge.status == .ready { line += " — pick “\(profile.displayName)” in Xcode. Ctrl-C to stop." }
                if bridge.status == .local { line += " — Xcode sees it directly; bridging resumes when it leaves." }
                if bridge.status == .waiting, bridge.pausedOnCellular {
                    line += " — on cellular, so the tunnel was closed to save data; it reconnects on Wi‑Fi."
                }
                guard line != last else { return }
                last = line
                print("[\(Date.now.formatted(date: .omitted, time: .standard))] \(line)")
            }
        }
        // Same recovery as the app: retry errors, rebind when the Mac's IP changes, re-announce on wake.
        let supervisor = BridgeSupervisor(all: { [bridge] }, wanted: { _ in true }, start: { list, reason in
            for b in list {
                if StartPolicy.of(reason).restarts { b.stop() }
                b.requestStart(reason)
            }
        }, gaveUp: { b in
            // Retrying can't fix it (lost pairing, no admin rights): say why and stop.
            let reason = { if case .error(let m) = b.state { m } else { "the bridge failed" } }()
            b.stop()   // before printing: its "bridge stopped" line mustn't be the log's last
            FileHandle.standardError.write(Data("roamrun: \(reason)\n".utf8))
            exit(1)
        })
        supervisor.run()
        let wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                     object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { supervisor.woke() }
        }
        let monitor = InterfaceMonitor()
        monitor.onLost = { Task { @MainActor in supervisor.lanAddressLost() } }
        monitor.onChange = { _ in Task { @MainActor in supervisor.lanAddressChanged() } }
        monitor.start()

        // Ctrl-C must tear down dns-sd / log children, or the fake Bonjour
        // record outlives us.
        var sources: [AnyObject] = []
        for sig in detachedChild ? [SIGINT, SIGTERM] : [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                MainActor.assumeIsolated {
                    bridge.stop()
                    print("\nBridge stopped.")
                    exit(0)
                }
            }
            src.resume()
            sources.append(src as AnyObject)
        }
        keepAlive = [ticker, supervisor, monitor, wake] + sources + (logRotation.map { [$0] } ?? [])

        print("Bridging \(profile.displayName) over \(profile.providerIP)…")
        bridge.requestStart(.manual)
    }

    /// Walks the path Xcode → this Mac → Tailscale → iPhone and reports the
    /// first thing to fix at each hop.
    struct Check: Encodable {
        let scope: String          // "mac" or the device's name
        let result: String         // "ok", "warning", "fail" or "skipped"
        let message: String
        let fix: String?

        private enum CodingKeys: String, CodingKey { case scope, result, message, fix }

        /// `fix` is `null` when there is nothing to do, like Row's unknowns.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(scope, forKey: .scope)
            try c.encode(result, forKey: .result)
            try c.encode(message, forKey: .message)
            try c.encode(fix, forKey: .fix)
        }
    }

    /// Unless checkAll, devices whose bridge is off are skipped: an unused device
    /// isn't a problem to report.
    private static func doctor(_ profiles: [DeviceProfile], json: Bool, checkAll: Bool) async -> Bool {
        var checks: [Check] = []
        var scope = "mac"
        func section(_ title: String, _ name: String) {
            scope = name
            if !json { print(title) }
        }
        func check(_ ok: Bool, _ line: String, fix: String = "", warnOnly: Bool = false) {
            let result = ok ? "ok" : warnOnly ? "warning" : "fail"
            checks.append(Check(scope: scope, result: result, message: line, fix: ok || fix.isEmpty ? nil : fix))
            guard !json else { return }
            print(" \(paint(ok ? "✓" : warnOnly ? "!" : "✗", ok ? 32 : warnOnly ? 33 : 31)) \(line)")
            if !ok, !fix.isEmpty { print("     → \(fix)") }
        }
        /// Not a result: why a check didn't run.
        func note(_ line: String) {
            checks.append(Check(scope: scope, result: "skipped", message: line, fix: nil))
            if !json { print(" – \(line)") }
        }
        /// ANSI color on a terminal only (not when piped, or with NO_COLOR set).
        func paint(_ s: String, _ code: Int) -> String {
            isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil ? "\u{1B}[\(code);1m\(s)\u{1B}[0m" : s
        }
        func finish() -> Bool {
            let healthy = !checks.contains { $0.result == "fail" }
            if json {
                struct Report: Encodable { let healthy: Bool; let checks: [Check] }
                printJSON(Report(healthy: healthy, checks: checks))
            } else {
                print(healthy ? "\n" + paint("All good.", 32) : "\nFix the first failed check (\(paint("✗", 31))) first — the ones below it are often caused by it.")
            }
            return healthy
        }

        section("This Mac", "mac")
        check(FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") && shell("/usr/bin/xcrun", ["--find", "devicectl"]) != nil,
              "Xcode's devicectl is available", fix: "Install Xcode and run it once (sudo xcode-select -s /Applications/Xcode.app).")
        let ip = InterfaceMonitor.currentIPv4()
        let lan = InterfaceMonitor.lanInterface
        check(ip != nil, "LAN address (\(lan)): \(ip ?? "none")",
              fix: "Connect \(lan) to the network — the bridge listens where Xcode looks for devices. To use another interface, pick it in RoamRun (Open RoamRun › ⚙ Settings › Network).")
        let orphans = DNSServiceProxy.orphanedHelperCount()
        check(orphans == 0, orphans == 0 ? "No leftover helper processes" : "\(orphans) leftover helper process(es) from a crash",
              fix: "Open RoamRun (it cleans them up at launch) or ⚙ Settings › Troubleshooting › Clean Up Leftover Helpers.", warnOnly: true)

        let live = StatusFile.read()
        let cli = TailscaleClient.fromSettings()
        let viaTailscale = { (p: DeviceProfile) in p.providerID == MeshProvider.tailscale.rawValue }
        var peers: [MeshDevice] = []
        do {
            peers = try cli.listDevices()
            check(true, "Tailscale is running (\(peers.count) peers)")
        } catch {
            // Devices entered by IP (another mesh VPN) don't need Tailscale.
            if profiles.contains(where: { viaTailscale($0) && (checkAll || live[$0.id] != nil) }) {
                check(false, "Tailscale: \(error.localizedDescription)", fix: "Install Tailscale and sign in, or set its CLI path in RoamRun (Open RoamRun › ⚙ Settings).")
                return finish()
            }
            note("Tailscale not checked (no device uses it)")
        }

        if profiles.isEmpty { check(false, "No devices saved", fix: "Add one in the RoamRun app.") }
        for p in profiles {
            section("\n\(p.displayName) (\(p.providerIP))", p.displayName)
            switch controlState(p.id, udid: p.udid ?? live[p.id]?.udid) {
            case .notSetUp: break
            case .connected: check(true, "Device control: connected")
            case .notConnected:
                check(false, "Device control: paired, but not connected",
                      fix: "It connects while the device is on a Wi‑Fi, awake and reachable over the VPN — and then stays connected on cellular. Ask the user to unlock it on Wi‑Fi.", warnOnly: true)
            case .refused:
                check(false, "Device control: RoamRun's pairing can no longer be used",
                      fix: "It was removed on the device, was made by a build that didn't keep the device's key with it, or this Mac can't read what it saved (its key is gone from the Keychain, or was refused). Ask the user to pair again: the RoamRun app, the device's page, Device control › Pair Again… (same Wi‑Fi, iOS 27 or later).", warnOnly: true)
            case .another:
                check(false, "Device control: what answers at the device's address isn't the device RoamRun paired with",
                      fix: "It is told nothing of this Mac's and sent no input. If the device was erased or replaced, ask the user to pair again (the RoamRun app, the device's page); if not, something else on the network has the device's address — check the address saved for it.")
            case .listUnreadable:
                check(false, "Device control: the Keychain didn't give RoamRun its list of devices switched on",
                      fix: "Nothing is switched on until it does. Ask the user to open the device's page in the RoamRun app: it says what to do (a question from macOS about that item is not to be allowed).", warnOnly: true)
            case .switchedOff:
                check(false, "Device control: switched off for this device",
                      fix: "Commands and agents are refused while its switch is off. Ask the user to switch it on: the RoamRun app, the device's page, Device control.", warnOnly: true)
            case .noApp:
                check(false, "Device control: the RoamRun app isn't running (or is a build without it)",
                      fix: "Open RoamRun: it holds the connection that look, tap and the rest use.", warnOnly: true)
            case .keptOut:
                check(false, "Device control: this process isn't allowed to reach the RoamRun app",
                      fix: "A sandbox around it keeps it from the app's socket (the app may well be running). Run roamrun outside the sandbox, or use the MCP tools (`roamrun mcp`).", warnOnly: true)
            }
            if !checkAll, live[p.id] == nil {
                note("Bridge is off — not checked (roamrun doctor \(commandName(p)) checks it anyway)")
                continue
            }
            // On this Wi‑Fi Xcode reaches the device directly: the VPN path doesn't matter.
            if live[p.id]?.kind == .local {
                note("On this Wi\u{2011}Fi — VPN checks skipped (Xcode reaches the device directly)")
            } else {
                if viaTailscale(p) {
                    guard let peer = peers.first(where: { $0.ips.contains(p.providerIP) }) else {
                        check(false, "Not found on this tailnet", fix: "Sign the device into the same tailnet, or remove and re-add it in RoamRun.")
                        continue
                    }
                    check(peer.online, "Tailscale peer “\(peer.name)” is \(peer.online ? "online" : "offline")",
                          fix: "Unlock the device and keep its screen on — while it sleeps, iOS pauses the Tailscale VPN too.")
                    // On this Wi-Fi Xcode reaches the device directly; the Tailscale path doesn't matter.
                    if peer.online, live[p.id]?.kind != .local {
                        check(!peer.curAddr.isEmpty, "Path: \(peer.pathDescription)",
                              fix: "Direct paths are much faster. Some networks (hotel, carrier NAT) force DERP.", warnOnly: true)
                    }
                } else {
                    note("VPN address entered by hand — Tailscale checks skipped")
                }
                let open = await ReachabilityProbe.checkTCP(host: p.providerIP, port: p.remotePairingPort, timeout: 4)
                if open {
                    check(true, "RemotePairing port \(p.remotePairingPort) is reachable")
                } else if viaTailscale(p), cli.ping(p.providerIP) {
                    // Tailscale answers but the iPhone's service doesn't: the iOS
                    // Tailscale data plane is stuck, or the iPhone left Wi-Fi.
                    check(false, "Tailscale reaches the device, but RemotePairing port \(p.remotePairingPort) does not answer",
                          fix: "Ask the user to (1) toggle the VPN off and on in the device's Tailscale app — iOS Tailscale can show \"MagicSock function ReceiveIPv4 is not running\" and stop passing data while still looking connected; (2) check the device is on Wi-Fi (cellular alone is not enough). If it restarted, run Find RemotePairing Port in the app.")
                } else {
                    check(false, "The device does not answer over \(viaTailscale(p) ? "Tailscale" : "the VPN")",
                          fix: "Ask the user to unlock the device, keep the screen on and make sure Tailscale is on. If the Tailscale app shows a \"MagicSock … not running\" warning, toggle its VPN off and on.")
                }
                if open {
                    let speaks = await ReachabilityProbe.speaksRemotePairing(host: p.providerIP, port: p.remotePairingPort)
                    check(speaks, "Device \(speaks ? "answers" : "does not answer") the RemotePairing handshake",
                          fix: "Another service holds this port. Run Find RemotePairing Port in the app.")
                }
            }
            // How remotepairingd last resolved our record (nil = pairing lost), or any
            // advert matched to this UDID. Only plain hex/UUIDs go into the predicates.
            let plain = { (s: String) in !s.isEmpty && s.allSatisfy { $0.isHexDigit || $0 == "-" } }
            let udid = live[p.id]?.udid ?? p.udid
            // Through the hardened parser: instance names in these lines come from the LAN.
            let adverts = { (phrase: String) in TunnelPortWatcher.recentAdverts(last: "15m", containing: phrase) }
            let ours = plain(p.instanceName) ? adverts("Resolved bonjour advert \(p.instanceName) to identity").last { $0.0 == p.instanceName } : nil
            if let ours, ours.1 == nil {
                check(false, "This Mac does not recognize the device's pairing (identity nil)",
                      fix: "Put the device on this Mac's Wi-Fi, remove it in RoamRun and add it again; a Mac never on its Wi-Fi takes it again from one that is (`roamrun devices export` there, `roamrun devices add <line> --replace` here). If Xcode lost it too, pair it in Xcode first (from afar: `roamrun pair xcode`, and have this Mac introduced again).")
            } else if ours != nil || (udid.map(plain) == true && adverts("associated with udid \(udid ?? "")")
                .contains { $0.1?.caseInsensitiveCompare(udid ?? "") == .orderedSame }) {
                check(true, "This Mac recognizes the device's pairing")
            } else {
                note("Pairing not checked — no advert of this device was matched in the last 15 minutes")
            }
            if let e = live[p.id] {
                let own = LocalNetwork.withoutAdvice(e.detail)   // it gets its own line below
                let over = e.deviceNetwork.map { " over \($0 == .wifi ? "Wi‑Fi" : "cellular")" } ?? ""
                check(e.ready || e.kind == .local, "Mac-side bridge: \(e.status)\(over) (\(owner(e)))", fix: own.isEmpty ? "Wait a few seconds and run doctor again." : own)
                if e.deviceNetwork == .cellular, e.kind == .ready {
                    note("The device is on cellular: Xcode keeps the tunnel set up on Wi‑Fi, but a new one needs Wi‑Fi again")
                }
                if e.detail.contains(LocalNetwork.advice) {
                    check(false, "macOS is blocking RoamRun's local network access, so it can't tell whether the device is on this Wi-Fi",
                          fix: LocalNetwork.advice, warnOnly: true)
                }
                if udid == nil { note("UDID not known yet — learned the first time the bridge connects") }
                if let udid {
                    check(true, "UDID: \(udid)")
                    let core = coreDeviceState(udid)
                    check(core != nil && core != "unavailable", "Xcode (CoreDevice) sees the device as \(core ?? "unknown")",
                          fix: "Ask the user to unlock the device and keep the screen on; then run doctor again.")
                    if e.ready, let locked = isLocked(udid) {
                        check(!locked, locked ? "Device is locked" : "Device is unlocked",
                              fix: "Ask the user to unlock the device and keep the screen on — installs and launches fail while it is locked.")
                    }
                }
            } else {
                check(false, "Bridge is off", fix: "roamrun up \(commandName(p)) -d  (or Start Bridge in the app)")
            }
        }
        otaSection(section: section, check: check, note: note)
        return finish()
    }

    enum OTAIssue { case notPublished, noHTTPSCertificates, funnel }

    /// Which over-the-air findings fail `doctor` (exit 1). Scripts read that as "the
    /// device isn't usable", so only a page exposed to the internet does; the page
    /// not being up — or the reason it can't be — is a warning, whatever device was named.
    nonisolated static func failsDoctor(_ issue: OTAIssue) -> Bool { issue == .funnel }

    /// Only when there is something stored: the address to reopen, what is kept,
    /// and whether the page is actually being served. Nothing to say otherwise.
    private static func otaSection(section: (String, String) -> Void,
                                   check: (Bool, String, String, Bool) -> Void,
                                   note: (String) -> Void) {
        guard let apps = OTA.builds() else {
            section("\nOver the air", "ota")
            check(false, "Can't read \(OTA.directory.path)",
                  "The install page answers 503 while this is true. Check the folder's permissions.", true)
            return
        }
        // Counted over the folders, not over `apps`: an app whose every build has
        // metadata this version can't decode has no entry in `apps` at all, and
        // that is precisely the app this count exists for.
        let undecodable = (OTA.appDirectories() ?? []).reduce(0) { $0 + OTA.unreadableBuilds(of: $1) }
        guard !apps.isEmpty || undecodable > 0 else { return }
        let mine: Bool
        var stray = false
        section("\nOver the air", "ota")
        let builds = apps.flatMap(\.builds)
        let bytes = builds.reduce(Int64(0)) { $0 + $1.size }
        note("\(builds.count) build\(builds.count == 1 ? "" : "s") of \(apps.count) app\(apps.count == 1 ? "" : "s"), " +
             "\(OTA.size(bytes)) in \(OTA.directory.path)")
        // Shown nowhere, pruned never, in no total: at least say it is there.
        if undecodable > 0 {
            note("\(undecodable) more with metadata this version can't read — a later one may; " +
                 "delete the folder to be rid of it")
        }
        let tailnetPort = AppCoordinator.otaPort
        let served = TailscaleClient.serving(port: tailnetPort)
        let host = AppCoordinator.currentHost()   // asked once; `serve` acts on this name alone
        let live = host.map { TailscaleClient.servingLive(port: tailnetPort, host: $0) } ?? false
        var unreadable = false
        switch served {
        case .unknown: mine = true; unreadable = true
        case .nothing: mine = true             // nothing of the user's to get in the way
        case .mounted:
            let here = host.flatMap { served.root(on: $0) }
            let beside = host.map { served.alongside($0) } ?? []
            // The same reading the app and `roamrun ota` use: no root under this
            // name is a free port, but anything else sharing it is not.
            mine = host != nil && beside.isEmpty && (here == nil || AppCoordinator.isOurs(here!, on: tailnetPort))
            stray = !mine && beside.isEmpty && AppCoordinator.abandoned(here)
        }
        check(live, live ? "The install page is published on port \(tailnetPort)"
                         : "The install page isn't published on port \(tailnetPort)",
              unreadable
                  ? "`tailscale serve status` didn't answer, so this can't be checked — is Tailscale running?"
                  : host == nil
                  ? "Tailscale didn't give this Mac a name — turn MagicDNS on for your tailnet."
                  : mine
                  ? "RoamRun publishes it while it runs — open RoamRun, then look in ⚙ Settings › Troubleshooting › Recent messages if it doesn't appear."
                  : stray
                  ? "port \(tailnetPort) carries an entry with nothing behind it, left by a run that was killed: tailscale serve --https=\(tailnetPort) --set-path=/ off"
                  : "port \(tailnetPort) is serving \(served.described), which isn't RoamRun's. Give RoamRun another port: defaults write \(AppID.bundle) otaPort -int 41444",
              !failsDoctor(.notPublished))
        if !live, TailscaleClient.httpsEnabled() == false {
            check(false, "This tailnet doesn't issue HTTPS certificates",
                  "`tailscale serve --https` writes nothing without them and still exits 0. Turn them on in the Tailscale admin console › DNS › HTTPS Certificates.",
                  !failsDoctor(.noHTTPSCertificates))
        }
        if let host, served.funnelled(on: host) {
            check(false, "Tailscale Funnel is on for port \(tailnetPort)",
                  "The install page is on the public internet. tailscale funnel --https=\(tailnetPort) off", !failsDoctor(.funnel))
        }
        // Not only while it is live: forgetting the address and asking `doctor`
        // for it is most likely exactly when RoamRun isn't open.
        if let host {
            note("Open on the device: https://\(host):\(tailnetPort)/")
        }
    }

    /// How to name a device in a command we suggest: a name starting with "-" would be taken
    /// for an option, so its id stands in (every command takes one).
    nonisolated static func commandName(_ p: DeviceProfile) -> String {
        p.displayName.hasPrefix("-") ? p.id.uuidString : shellName(p.displayName)
    }

    /// A name as it must be typed in a shell: 'iPhone mh', 'it'\''s'.
    nonisolated static func shellName(_ name: String) -> String {
        guard name.isEmpty || !name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else { return name }
        return "'" + name.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private static func shell(_ path: String, _ args: [String]) -> String? {
        let r = Proc.run(path, args)
        return r.status == 0 ? r.out : nil
    }

    /// Global skill directories of agents that follow the Agent Skills layout.
    nonisolated private static let skillClients: [(name: String, home: String)] = [
        ("claude", ".claude"), ("codex", ".codex"), ("cursor", ".cursor"),
        ("gemini", ".gemini"), ("copilot", ".copilot"), ("devin", ".devin"),
    ]

    /// The skill shipped in this app, which matches this CLI.
    nonisolated static func bundledSkill() -> Data? {
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath()
        return exe.flatMap { try? Data(contentsOf: $0.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/roamrun-skill.md")) }
    }

    nonisolated static var homeDir: URL {
        // $HOME first, like other CLIs (homeDirectoryForCurrentUser ignores it).
        ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Skills `roamrun init` put there that differ from this version's (links belong to other tools).
    nonisolated static func staleSkills(home: URL, bundled: Data) -> [String] {
        let fm = FileManager.default
        return skillClients.compactMap { c in
            let dir = home.appendingPathComponent("\(c.home)/skills/roamrun")
            let file = dir.appendingPathComponent("SKILL.md")
            guard ![dir, file].contains(where: { (try? fm.destinationOfSymbolicLink(atPath: $0.path)) != nil }),
                  let data = try? Data(contentsOf: file), data.starts(with: Data("---\nname: roamrun\n".utf8)),
                  data != bundled else { return nil }
            return dir.path
        }
    }

    /// One line on stderr (JSON output stays clean) when an installed skill is from another version.
    private static func noteStaleSkills() {
        guard let bundled = bundledSkill() else { return }
        let stale = staleSkills(home: homeDir, bundled: bundled)
        guard !stale.isEmpty else { return }
        let home = homeDir.path
        let shown = stale.map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 }.joined(separator: ", ")
        FileHandle.standardError.write(Data("roamrun: the agent skill in \(shown) is from another RoamRun version — run `roamrun init` to update it\n".utf8))
    }

    /// Installs the bundled SKILL.md for every detected (or named) agent.
    private static func initSkill(_ args: [String]) -> Never {
        // A typo (e.g. --uninstal) must not fall through to installing everywhere.
        for (i, a) in args.enumerated().dropFirst() where args[i - 1] != "--client" {
            // Also bare words: `init claude` must not install into every client.
            guard ["--client", "--print", "--uninstall"].contains(a) else {
                fail(a.hasPrefix("-") ? "unknown option \(a) — see roamrun --help" : "unexpected \(shellName(a)) — to pick a client: roamrun init --client \(shellName(a))")
            }
        }
        if let i = args.lastIndex(of: "--client"), !args.indices.contains(i + 1) || args[i + 1].hasPrefix("-") {
            fail("--client needs a value (\(skillClients.map(\.name).joined(separator: ", ")))")
        }
        guard let skill = bundledSkill() else {
            stop("skill not found in the app bundle — build with `make app`")
        }
        if args.contains("--print") { FileHandle.standardOutput.write(skill); exit(0) }

        let home = homeDir
        let named = args.indices.filter { args[$0] == "--client" && args.indices.contains($0 + 1) }.map { args[$0 + 1] }
        if let unknown = named.first(where: { n in !skillClients.contains { $0.name == n } }) {
            fail("unknown client “\(unknown)”. Known: \(skillClients.map(\.name).joined(separator: ", "))")
        }
        let targets = skillClients.filter { c in
            named.isEmpty ? FileManager.default.fileExists(atPath: home.appendingPathComponent(c.home).path) : named.contains(c.name)
        }
        guard !targets.isEmpty else {
            stop("no supported agent found in ~ (\(skillClients.map(\.home).joined(separator: ", "))). Use --client, or --print and paste it yourself.")
        }
        let fm = FileManager.default
        for c in targets {
            let dir = home.appendingPathComponent("\(c.home)/skills/roamrun")
            let file = dir.appendingPathComponent("SKILL.md")
            // Only ever touch our own plain file: a linked dir/file is managed
            // elsewhere (npx skills, a checkout), and a foreign SKILL.md is the user's.
            if [dir, file].contains(where: { (try? fm.destinationOfSymbolicLink(atPath: $0.path)) != nil }) {
                print("Skipped \(dir.path): it is a link managed elsewhere")
                continue
            }
            let existing = try? String(contentsOf: file, encoding: .utf8)
            let ours = existing?.hasPrefix("---\nname: roamrun\n") ?? false
            if args.contains("--uninstall") {
                guard ours else { print("Skipped \(dir.path): no RoamRun skill there"); continue }
                do { try fm.removeItem(at: file) } catch { print("Couldn't remove \(file.path): \(error.localizedDescription)"); continue }
                rmdir(dir.path)   // only if now empty
                print("Removed \(file.path)")
                continue
            }
            if existing != nil && !ours {
                print("Skipped \(dir.path): its SKILL.md isn't RoamRun's")
                continue
            }
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try skill.write(to: file, options: .atomic)
                print("Installed \(file.path)")
            } catch {
                stop("could not write \(dir.path): \(error.localizedDescription)")
            }
        }
        exit(0)
    }

    // MARK: - Helpers

    private static let noDevices = "No devices saved yet — add one in the RoamRun app."

    /// By name (any case), else by an id prefix of 8+ characters (shorter is more likely a typo).
    nonisolated static func matches(_ name: String, in profiles: [DeviceProfile]) -> [DeviceProfile] {
        let byName = profiles.filter { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }
        guard byName.isEmpty, name.count >= 8 else { return byName }
        return profiles.filter { $0.id.uuidString.lowercased().hasPrefix(name.lowercased()) }
    }

    private static func find(_ name: String, in profiles: [DeviceProfile]) -> DeviceProfile? {
        let matches = matches(name, in: profiles)
        if matches.count > 1 {
            fail("“\(name)” matches more than one device — rename one in the app, or use its id: "
                 + matches.map { "\($0.id.uuidString.prefix(8))" }.joined(separator: ", "))
        }
        return matches.first
    }

    private static func names(_ profiles: [DeviceProfile]) -> String {
        profiles.isEmpty ? noDevices
            : "Saved: " + profiles.map { commandName($0) }.joined(separator: ", ")
    }

    private static func owner(_ e: StatusFile.Entry) -> String {
        e.pid == getpid() ? "this process" : e.cli == true ? "roamrun CLI, pid \(e.pid)" : "RoamRun app"
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("roamrun: \(message)\n".utf8))
        exit(2)
    }
}
