import Foundation

/// `roamrun devices | up <name> | status [name]` — the same bridge as the menu
/// bar app, headless, for SSH sessions and scripts.
@MainActor
enum CLI {
    /// This process was started as the CLI (vs. the menu bar app).
    nonisolated static var isRunning: Bool {
        commands.contains(CommandLine.arguments.dropFirst().first ?? "")
    }

    nonisolated static let commands: Set<String> = deviceCommands.union([
        "devices",
        "pair",
        "up",
        "down",
        "status",
        "doctor",
        "run",
        "install",
        "ota",
        "logs",
        "screenshot",
        "init",
        "version",
        "--version",
        "help",
        "--help",
        "-h"
    ])
    /// The words as numbers a point or a duration can be: nil when one isn't a number, or is NaN or infinite.
    nonisolated static func finite(_ words: some Sequence<String>) -> [Double]? {
        let numbers = words.compactMap {
            Double($0)
        }
        .filter(\.isFinite)
        return numbers.count == Array(words).count ? numbers : nil
    }

    /// What only a build with device control has (to the others they are unknown commands).
    nonisolated static let deviceCommands: Set<String> = [
        "look",
        "tap",
        "swipe",
        "type",
        "paste",
        "press",
        "elements",
        "mcp",
        "key"
    ]
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
                                     prints the path, its size, then "look <n>"
      tap <name> <x> <y> [--look <n>]
                                     Tap a point given in the pixels of the last look (of look n only)
      swipe <name> <x1> <y1> <x2> <y2> [ms] [--look <n>]
                                     Drag from one point of the last look to another
      elements <name> [limit]        What accessibility says is on the screen, one caption a line
                                     (no positions; the screen may scroll)
      type <name> <text> [--look <n>]
                                     Type on the device's keyboard (US keys; right only while that
                                     keyboard is an English one: under a Japanese one even a space converts)
      paste <name> <text> [--look <n>]
                                     Any text, by the device's pasteboard (it asks the user each time)
      press <name> <button>          home, lock, volume-up or volume-down
      mcp                            The same as MCP tools, over stdin/stdout (for an agent's MCP config)
    Each look serves one action (type and paste may still go by it): look, act, look again.
    With --look, refused once another look (anyone's), a button, elements or an action without
    --look came since, or after a minute: what an agent sharing the device gives.
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
                                     Mac's tailnet; one saved already where it was takes the line's
                                     announcement; --replace: put it in the place of what is
                                     saved of that same device — its UDID is kept — with the app and
                                     that device's bridge stopped)
      pair xcode [--with <Tailscale name>] [--qr]
                                     On a Mac the device was never near, with Device Hub › Pair Nearby
                                     Device: print this Mac's offer to pair, for `pair introduce`.
                                     --with: wait instead for that Mac's `pair introduce` (10 minutes at
                                     most), give it the offer over Tailscale, and save the device it
                                     hands back — no line is carried. --with may name the device
                                     itself, where the RoamRun Introducer app on it introduces, or
                                     a Windows or Linux machine that runs roamrunctl.
                                     --qr: draw this Mac's name as a code for that app (without
                                     --with: its offer too, to carry by hand)
      pair control --with <Tailscale name> [--peer <Tailscale name>] [--qr]
                                     On a Mac the device was never near, with the RoamRun app open: wait
                                     for that Mac's `pair introduce`, and have the app here pair with
                                     the device for device control (look, tap, type). The code shows on
                                     that Mac. --peer: the device's Tailscale name here, when it differs.
                                     --with may name the device itself (and --qr draw the code) or a
                                     Windows or Linux machine, as for `pair xcode`: the code to type
                                     then shows on the device, or on that machine.
                                     `pair control --attempt <id>` (or --last): what came of one
      pair introduce [<offer>] --host <Tailscale name> --to <device>
                                     On a Mac on the device's Wi‑Fi: stand in for the Mac --host names
                                     until the device has paired with it (5 minutes at most), then print
                                     the line for `devices add` there. It will use the device as a developer.
                                     Without <offer>: ask it for the offer (it runs `pair xcode --with`
                                     naming this Mac) and hand it the device afterwards. --host may also
                                     name a machine that waits with `pair control --with` (RoamRun's, or
                                     roamrunctl's on Linux or Windows): it then pairs for device control.
                                     An Apple Vision Pro waits to be picked instead (Settings › General ›
                                     Remote Devices, open): without <offer>, what it announces goes to
                                     that Mac, which announces it there for its own Device Hub to pick
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

    // Kept alive until the process exits.
    static var keepAlive: [AnyObject] = []

    nonisolated static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
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
                if let note = moved(args[0]) {
                    fail(note)
                }
                FileHandle.standardError.write(Data("roamrun: unknown command “\(args[0])”\n\n\(usage)\n".utf8))
                exit(2)
            }
            if wantsHelp(args) {
                print(usage); exit(0)
            }
            if args[0] == "version" || args[0] == "--version" {
                // Through the /usr/local/bin link, Bundle.main isn't the app: resolve it.
                let app = Bundle.main
                    .executableURL?
                    .resolvingSymlinksInPath()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                let info = app.flatMap(Bundle.init(url:))?.infoDictionary ?? Bundle.main.infoDictionary
                print("roamrun \(info?["CFBundleShortVersionString"] as? String ?? "dev")")
                exit(0)
            }
            if args[0] == "init" {
                initSkill(args)
            } // takes no iPhone name
            let store = ProfileStore()
            let profiles = store.load()
            if let copy = store.keptUnreadable {
                FileHandle.standardError
                    .write(Data("roamrun: couldn't read saved devices; kept the file as \(copy.path)\n".utf8))
            } else if store.unreadable {
                FileHandle.standardError
                    .write(
                        Data("roamrun: couldn't read \(ProfileStore.directory.path)/profiles.json — check its permissions\n"
                            .utf8)
                    )
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
            let name = (args[0] == "ota" && words.count < 2) || ["key", "pair", "devices"]
                .contains(args[0]) ? nil : words.first
            var targets = profiles
            if let name {
                guard let p = find(name, in: profiles)
                else { fail("no device named \(shellName(name)). " + names(profiles)) }
                targets = [p]
            }
            switch args[0] {
            case "devices":
                // An option that belongs to another form isn't dropped in silence.
                @MainActor func only(_ allowed: Set<String>, _ form: String) {
                    if let extra = Set(parsed.values.keys).union(parsed.flags).subtracting(allowed).sorted().first {
                        fail("`roamrun \(form)` doesn't take \(extra) — see roamrun --help")
                    }
                }
                switch (words.first, words.count) {
                case (nil, _):
                    only(["--json"], "devices")
                    devices(profiles, json: json)
                case ("export", 2):
                    only([], "devices export")
                    guard let p = find(words[1], in: profiles)
                    else { fail("no device named \(shellName(words[1])). " + names(profiles)) }
                    exportDevice(p)
                case ("add", 2):
                    only(["--as", "--replace", "--peer"], "devices add")
                    if parsed.values["--as"] != nil,
                       parsed
                           .values["--replace"] != nil
                    {
                        fail("--replace keeps the saved device's name: leave --as out")
                    }
                    addDevice(line: words[1], name: parsed.values["--as"], replacing: parsed.values["--replace"],
                              peer: parsed.values["--peer"], store: store)
                default:
                    fail(
                        "usage: roamrun devices [--json] | roamrun devices export <name> | roamrun devices add <line> [--as <name>] [--replace <name>] [--peer <Tailscale name>]"
                    )
                }
            case "pair":
                switch (words.first, words.count) {
                case ("control", 1):
                    // One form at a time: an option of another isn't dropped in silence.
                    let given = Set(parsed.values.keys).union(parsed.flags)
                    let form: Set<String> = given.contains("--with") ? ["--with", "--peer", "--qr"] : given
                        .contains("--attempt") ? ["--attempt"] : ["--last"]
                    if let extra = given.subtracting(form).sorted().first {
                        fail(
                            "`roamrun pair control` doesn't take \(extra) here: --with <Mac or device> [--peer <device>] [--qr], or --attempt <id>, or --last"
                        )
                    }
                    if let home = parsed.values["--with"] {
                        Task { await offerControlPairing(
                            with: home,
                            peer: parsed.values["--peer"],
                            qr: parsed.flags.contains("--qr")
                        ) }
                    } else if let id = parsed.values["--attempt"] {
                        controlAttempt(id)
                    } else if parsed.flags.contains("--last") {
                        controlAttempt(nil)
                    } else {
                        fail(
                            "usage: roamrun pair control --with <Tailscale name> [--peer <Tailscale name>] [--qr] | roamrun pair control --attempt <id> | roamrun pair control --last"
                        )
                    }
                case ("xcode", 1):
                    if let extra = Set(parsed.values.keys)
                        .union(parsed.flags)
                        .subtracting(["--with", "--qr"])
                        .sorted()
                        .first
                    {
                        fail(
                            "`roamrun pair xcode` doesn't take \(extra): the Mac or device to wait for is --with <its Tailscale name>, and --qr draws a code"
                        )
                    }
                    let qr = parsed.flags.contains("--qr")
                    if let home = parsed.values["--with"] {
                        Task {
                            await offerXcodePairing(with: home, qr: qr)
                        }
                    } else {
                        Task {
                            await offerXcodePairing(qr: qr)
                        }
                    }
                case ("introduce", 1), ("introduce", 2):
                    if parsed
                        .values["--with"] !=
                        nil
                    {
                        fail(
                            "`roamrun pair introduce` doesn't take --with: the machine to introduce is --host <its Tailscale name>"
                        )
                    }
                    if let extra = Set(parsed.values.keys)
                        .union(parsed.flags)
                        .subtracting(["--host", "--to"])
                        .sorted()
                        .first
                    {
                        fail("`roamrun pair introduce` doesn't take \(extra) — see roamrun --help")
                    }
                    guard let mac = parsed.values["--host"], let to = parsed.values["--to"] else {
                        fail(
                            "usage: roamrun pair introduce [<offer>] --host <the other machine's Tailscale name> --to <device>"
                        )
                    }
                    guard let p = find(to, in: profiles)
                    else { fail("no device named \(shellName(to)). " + names(profiles)) }
                    if words.count == 2 {
                        Task {
                            await introduce(offer: words[1], mac: mac, to: p)
                        }
                    } else {
                        Task { await introduceByName(
                            mac: mac,
                            to: p
                        ) }
                    }
                default:
                    fail(
                        "usage: roamrun pair xcode [--with <Tailscale name>] [--qr] | roamrun pair control --with <Tailscale name> | roamrun pair introduce [<offer>] --host <the other machine's Tailscale name> --to <device> — see roamrun --help"
                    )
                }
            case "status":
                noteStaleSkills()
                status(targets, json: json, wait: wait)
            case "doctor":
                noteStaleSkills()
                // No name and nothing running: check every device rather than report "All good." unchecked.
                let running = StatusFile.read()
                let checkAll = name != nil || !targets.contains {
                    running[$0.id] != nil
                }
                Task {
                    exit(await doctor(targets, json: json, checkAll: checkAll) ? 0 : 1)
                }
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
                guard name != nil,
                      let p = targets.first else { fail("usage: roamrun run <name> [--scheme S]. " + names(profiles)) }
                Proc.Passing.shared.begin() // nothing it waits on may outlive it
                let v = parsed.values
                runApp(p, scheme: v["--scheme"], workspace: v["--workspace"], project: v["--project"],
                       configuration: v["--configuration"] ?? "Debug", logs: parsed.flags.contains("--logs"),
                       launch: parsed.launch)
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
                    guard let p = find(words[1], in: profiles)
                    else { fail("no device named \(shellName(words[1])). " + names(profiles)) }
                    createPairing(p, others: profiles.filter {
                        $0.id != p.id
                    }, file: words[2], label: label)
                case ("import", 2):
                    importPairing(file: words[1], name: label)
                default:
                    fail(
                        "usage: roamrun key create <name> <file> [--as <label>] | roamrun key import <file> [--as <name>]"
                    )
                }
            case "mcp":
                // Off the main thread: it reads stdin until the client closes it.
                let asking = DeviceControlWire.Asking()
                let server = DeviceMCP(
                    profiles: {
                        store.load()
                    },
                    looks: DeviceControlWire.socketFolder(in: ProfileStore.directory),
                    asking: asking
                ) {
                    try DeviceControlWire.ask($0, in: ProfileStore.directory, asking: asking)
                }
                Thread.detachNewThread {
                    server.serve(); exit(0)
                }
            case "look":
                guard name != nil,
                      let p = targets.first else { fail("usage: roamrun look <name> [file.png]. " + names(profiles)) }
                look(p, path: words.count >= 2 ? words[words.startIndex + 1] : nil)
            case "tap":
                guard name != nil, let p = targets.first, words.count == 3, let point = finite(words.dropFirst()) else {
                    fail("usage: roamrun tap <name> <x> <y> [--look <n>] — pixels of the last `roamrun look`. " +
                        names(profiles))
                }
                operate(.init(op: "tap", device: p.id, x: point[0], y: point[1], look: lookGiven(parsed)))
            case "swipe":
                guard name != nil, let p = targets.first, let numbers = finite(words.dropFirst()),
                      (4 ... 5).contains(numbers.count),
                      let ms = numbers.count == 5 ? Int(exactly: numbers[4].rounded()) : 300
                else {
                    fail("usage: roamrun swipe <name> <x1> <y1> <x2> <y2> [milliseconds] [--look <n>] — pixels of the last `roamrun look`. " +
                        names(profiles))
                }
                operate(.init(
                    op: "swipe",
                    device: p.id,
                    x: numbers[0],
                    y: numbers[1],
                    x2: numbers[2],
                    y2: numbers[3],
                    milliseconds: ms,
                    look: lookGiven(parsed)
                ))
            case "type", "paste", "press":
                guard name != nil, let p = targets.first, words.count == 2 else {
                    fail("usage: roamrun \(args[0]) <name> \(args[0] == "press" ? "<home|lock|volume-up|volume-down>" : "<text> [--look <n>]"). " +
                        names(profiles))
                }
                operate(.init(
                    op: args[0],
                    device: p.id,
                    text: words[words.startIndex + 1],
                    look: args[0] == "press" ? nil : lookGiven(parsed)
                ))
            case "elements":
                guard name != nil,
                      let p = targets.first else { fail("usage: roamrun elements <name> [limit]. " + names(profiles)) }
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
        all["look"] = ([], 0 ... 2)
        all["tap"] = (["--look="], 0 ... 3)
        all["swipe"] = (["--look="], 0 ... 6)
        all["type"] = (["--look="], 0 ... 2)
        all["paste"] = (["--look="], 0 ... 2)
        all["press"] = ([], 0 ... 2)
        all["elements"] = ([], 0 ... 2)
        all["mcp"] = ([], 0 ... 0)
        all["key"] = (["--as="], 0 ... 3)
        return all
    }()

    nonisolated private static let baseSpecs: [String: (options: Set<String>, words: ClosedRange<Int>)] = [
        "devices": (["--json", "--as=", "--replace=", "--peer="], 0 ... 2),
        "pair": (["--host=", "--to=", "--with=", "--attempt=", "--last", "--peer=", "--qr"], 0 ... 2),
        "status": (["--json", "--wait="], 0 ... 1),
        "doctor": (["--json"], 0 ... 1),
        "down": ([], 0 ... 1),
        "up": (["-v", "-d", detachedFlag], 0 ... 1),
        "logs": (["--arg=", "--env=", "--url="], 0 ... 2),
        "run": (
            ["--scheme=", "--workspace=", "--project=", "--configuration=", "--logs", "--arg=", "--env=", "--url="],
            0 ... 1
        ),
        "screenshot": ([], 0 ... 2),
        "install": ([], 0 ... 2),
        "ota": (["--replace"], 0 ... 2),
    ]

    struct Parsed: Equatable {
        var words: [String] = []
        var flags: Set<String> = []
        var values: [String: String] = [:]
        /// Every value of an option given more than once (--arg, --env), in order.
        var lists: [String: [String]] = [:]
        var wait: Double?
        var launch: Launch {
            Launch(args: lists["--arg"] ?? [], env: lists["--env"] ?? [], url: values["--url"])
        }
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
                + ["--terminate-existing", "--device", udid] + (url.map {
                    ["--payload-url", $0]
                } ?? [])
                + [bundleID] + (args.isEmpty ? [] : ["--"] + args) // "--": devicectl would read "-Flag" as its own
        }

        /// NAME=value pairs split at the first "=": a value may contain more.
        var environment: [(name: String, value: String)] {
            env.compactMap { pair in
                pair.firstIndex(of: "=").map {
                    (String(pair[..<$0]), String(pair[pair.index(after: $0)...]))
                }
            }
        }

        func exportEnvironment() {
            for (name, value) in environment {
                setenv("DEVICECTL_CHILD_" + name, value, 1)
            }
        }
    }

    struct ArgumentError: Error, Equatable { let message: String }

    /// `--help` anywhere, except as the value of `--arg` (`--arg -h` is for the app) and as the
    /// text to type or paste.
    nonisolated static func wantsHelp(_ args: [String]) -> Bool {
        ["help", "--help", "-h"].contains(args[0])
            || args.indices.dropFirst().contains {
                ["--help", "-h"]
                    .contains(args[$0]) && args[$0 - 1] != "--arg" && !(textCommands.contains(args[0]) && $0 == 2)
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
                    return .failure(.init(message: name == "--wait" ? "--wait needs a number of seconds" :
                            "\(name) needs a value"))
                }
                p.values[name] = value
                p.lists[name, default: []].append(value)
                i += 1
                continue
            }
            if spec.options.contains(a + "=") {
                // --arg values are often flags themselves (-ShowScreen), --wait may be negative (refused below).
                guard i + 1 < args.count, !args[i + 1].hasPrefix("-") || a == "--wait" || a == "--arg" else {
                    return .failure(.init(message: a == "--wait" ? "--wait needs a number of seconds" :
                            "\(a) needs a value"))
                }
                p.values[a] = args[i + 1]
                p.lists[a, default: []].append(args[i + 1])
                i += 2
                continue
            }
            if a.hasPrefix("-") {
                // The old name isn't taken; whoever was shown it by an earlier RoamRun is told the new one.
                if a == "--mac" || a
                    .hasPrefix("--mac=")
                {
                    return .failure(
                        .init(
                            message: "--mac is --host since 0.7.0: roamrun pair introduce --host <the machine that will hold the pairing> --to <device>"
                        )
                    )
                }
                guard !a.hasSuffix("="), spec.options.contains(a) else {
                    let hint = spec.words
                        .upperBound > 0 ? " (a device name starting with “-”? use its id, see roamrun devices)" : ""
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
            guard let n = Double(w), n.isFinite,
                  n >= 0 else { return .failure(.init(message: "--wait needs a number of seconds")) }
            p.wait = n
        }
        return .success(p)
    }

    /// A runtime failure (exit 1). `fail` is for usage errors (exit 2).
    static func stop(_ why: String) -> Never {
        FileHandle.standardError.write(Data("roamrun: \(why)\n".utf8))
        exit(1)
    }

    /// The UDID of a device Xcode can reach right now (bridged, or on this
    /// Wi-Fi without a bridge) and that is unlocked; otherwise says what to do.
    static func reachableUDID(_ profile: DeviceProfile) -> String {
        guard let udid = StatusFile.read()[profile.id]?.udid ?? profile.udid else {
            stop(
                "\(profile.displayName)'s UDID isn't known yet — start its bridge once: roamrun up \(commandName(profile)) -d"
            )
        }
        let core = coreDeviceState(udid)
        guard let core, core != "unavailable" else {
            stop(
                "Xcode can't reach \(profile.displayName) (\(core ?? "unknown")). If it's away, start the bridge: roamrun up \(commandName(profile)) -d; otherwise run roamrun doctor \(commandName(profile))."
            )
        }
        if isLocked(udid) ==
            true
        {
            stop("\(profile.displayName) is locked — ask the user to unlock it and keep the screen on.")
        }
        return udid
    }

    /// Hands over to devicectl so Ctrl-C and kill reach it directly.
    static func exec(_ argv: [String]) -> Never {
        Proc.Passing.shared.endForExec()
        var cargs = argv.map {
            strdup($0)
        } + [nil]
        execv(argv[0], &cargs)
        stop("could not run \(argv[0]): \(String(cString: strerror(errno)))")
    }

    /// Through the tunnel like everything else: works over the bridge.
    /// What keeps this Mac off Tailscale, as its own word; nil when it is on it.
    nonisolated static func meshProblem(_ list: () throws -> [MeshDevice]) -> String? {
        do { _ = try list(); return nil } catch { return error.localizedDescription }
    }

    // Device control: the app holds the connection; these ask it.

    /// How to name a device in a command we suggest: a name starting with "-" would be taken
    /// for an option, so its id stands in (every command takes one).
    nonisolated static func commandName(_ p: DeviceProfile) -> String {
        p.displayName.hasPrefix("-") ? p.id.uuidString : shellName(p.displayName)
    }

    /// A name as it must be typed in a shell: 'iPhone mh', 'it'\''s'.
    nonisolated static func shellName(_ name: String) -> String {
        guard name.isEmpty || !name.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0))
        })
        else { return name }
        return "'" + name.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Global skill directories of agents that follow the Agent Skills layout.
    nonisolated private static let skillClients: [(name: String, home: String)] = [
        ("claude", ".claude"), ("codex", ".codex"), ("cursor", ".cursor"),
        ("gemini", ".gemini"), ("copilot", ".copilot"), ("devin", ".devin"),
    ]

    /// The skill shipped in this app, which matches this CLI.
    nonisolated static func bundledSkill() -> Data? {
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath()
        return exe.flatMap { try? Data(contentsOf: $0.deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/roamrun-skill.md")) }
    }

    nonisolated static var homeDir: URL {
        // $HOME first, like other CLIs (homeDirectoryForCurrentUser ignores it).
        ProcessInfo.processInfo.environment["HOME"].map {
            URL(fileURLWithPath: $0)
        }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Skills `roamrun init` put there that differ from this version's (links belong to other tools).
    nonisolated static func staleSkills(home: URL, bundled: Data) -> [String] {
        let fm = FileManager.default
        return skillClients.compactMap { c in
            let dir = home.appendingPathComponent("\(c.home)/skills/roamrun")
            let file = dir.appendingPathComponent("SKILL.md")
            guard ![dir, file].contains(where: {
                      (try? fm.destinationOfSymbolicLink(atPath: $0.path)) != nil
                  }),
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
        let shown = stale.map {
            $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0
        }
        .joined(separator: ", ")
        FileHandle.standardError
            .write(
                Data("roamrun: the agent skill in \(shown) is from another RoamRun version — run `roamrun init` to update it\n"
                    .utf8)
            )
    }

    /// Installs the bundled SKILL.md for every detected (or named) agent.
    private static func initSkill(_ args: [String]) -> Never {
        // A typo (e.g. --uninstal) must not fall through to installing everywhere.
        for (i, a) in args.enumerated().dropFirst() where args[i - 1] != "--client" {
            // Also bare words: `init claude` must not install into every client.
            guard ["--client", "--print", "--uninstall"].contains(a) else {
                fail(a
                    .hasPrefix("-") ? "unknown option \(a) — see roamrun --help" :
                    "unexpected \(shellName(a)) — to pick a client: roamrun init --client \(shellName(a))")
            }
        }
        if let i = args.lastIndex(of: "--client"), !args.indices.contains(i + 1) || args[i + 1].hasPrefix("-") {
            fail("--client needs a value (\(skillClients.map(\.name).joined(separator: ", ")))")
        }
        guard let skill = bundledSkill() else {
            stop("skill not found in the app bundle — build with `make app`")
        }
        if args.contains("--print") {
            FileHandle.standardOutput.write(skill); exit(0)
        }

        let home = homeDir
        let named = args.indices
            .filter {
                args[$0] == "--client" && args.indices.contains($0 + 1)
            }
            .map {
                args[$0 + 1]
            }
        if let unknown = named.first(where: { n in
            !skillClients.contains {
                $0.name == n
            }
        }) {
            fail("unknown client “\(unknown)”. Known: \(skillClients.map(\.name).joined(separator: ", "))")
        }
        let targets = skillClients.filter { c in
            named.isEmpty ? FileManager.default.fileExists(atPath: home.appendingPathComponent(c.home).path) : named
                .contains(c.name)
        }
        guard !targets.isEmpty else {
            stop(
                "no supported agent found in ~ (\(skillClients.map(\.home).joined(separator: ", "))). Use --client, or --print and paste it yourself."
            )
        }
        let fm = FileManager.default
        for c in targets {
            let dir = home.appendingPathComponent("\(c.home)/skills/roamrun")
            let file = dir.appendingPathComponent("SKILL.md")
            // Only ever touch our own plain file: a linked dir/file is managed
            // elsewhere (npx skills, a checkout), and a foreign SKILL.md is the user's.
            if [dir, file].contains(where: {
                (try? fm.destinationOfSymbolicLink(atPath: $0.path)) != nil
            }) {
                print("Skipped \(dir.path): it is a link managed elsewhere")
                continue
            }
            let existing = try? String(contentsOf: file, encoding: .utf8)
            let ours = existing?.hasPrefix("---\nname: roamrun\n") ?? false
            if args.contains("--uninstall") {
                guard ours else { print("Skipped \(dir.path): no RoamRun skill there"); continue }
                do { try fm.removeItem(at: file) } catch {
                    print("Couldn't remove \(file.path): \(error.localizedDescription)"); continue
                }
                rmdir(dir.path) // only if now empty
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

    nonisolated static let noDevices = "No devices saved yet — add one in the RoamRun app."

    /// By name (any case), else by Tailscale name as saved, else by an id prefix of 8+ characters
    /// (shorter is more likely a typo). The name is taken as typed: a whole MagicDNS name says a
    /// tailnet, which the first label saved doesn't, so it is no device's.
    nonisolated static func matches(_ name: String, in profiles: [DeviceProfile]) -> [DeviceProfile] {
        guard !name.isEmpty else { return [] }
        let byName = profiles.filter {
            $0.displayName.caseInsensitiveCompare(name) == .orderedSame
        }
        if !byName.isEmpty {
            return byName
        }
        let lower = name.lowercased()
        let byHost = profiles.filter {
            savedTailscaleName($0) == lower
        }
        guard byHost.isEmpty, name.count >= 8 else { return byHost }
        return profiles.filter {
            $0.id.uuidString.lowercased().hasPrefix(lower)
        }
    }

    /// The Tailscale name a device was saved with, lowercased; nil for one not on Tailscale.
    nonisolated private static func savedTailscaleName(_ p: DeviceProfile) -> String? {
        p.providerID == MeshProvider.tailscale.rawValue && !p.providerHostName
            .isEmpty ? tailscaleHost(p.providerHostName).lowercased() : nil
    }

    /// A saved Tailscale name as it is typed: a MagicDNS name's first label (`host.tailnet.ts.net`,
    /// trailing dot or not), any other with a trailing dot dropped.
    nonisolated private static func tailscaleHost(_ saved: String) -> String {
        var name = saved
        while name.hasSuffix(".") {
            name.removeLast()
        }
        guard name.lowercased().hasSuffix(".ts.net") else { return name }
        return String(name.prefix {
            $0 != "."
        })
    }

    /// Why `name` matches more than one saved device. `find` refuses with this; nil for one or none.
    nonisolated static func ambiguous(_ name: String, in profiles: [DeviceProfile]) -> String? {
        let found = matches(name, in: profiles)
        guard found.count > 1 else { return nil }
        func listed(_ id: (DeviceProfile) -> String) -> String {
            found.map {
                "\(commandName($0)) (\(id($0)))"
            }
            .joined(separator: ", ")
        }
        if found[0].displayName.caseInsensitiveCompare(name) == .orderedSame {
            return "more than one device is named “\(name)” in RoamRun — rename one in the app, or use its id: " +
                listed {
                    String($0.id.uuidString.prefix(8))
                }
        }
        if savedTailscaleName(found[0]) == name.lowercased() {
            return "“\(name)” matches more than one device — use the name it has in RoamRun, or its id: " +
                listed {
                    String($0.id.uuidString.prefix(8))
                }
        }
        // Their first eight characters are the same: the whole ids.
        return "“\(name)” begins more than one device's id — give more of it: " + listed(\.id.uuidString)
    }

    /// Said when the name saved in RoamRun hides a different device's Tailscale name. Nil otherwise.
    nonisolated static func shadowNote(_ name: String, in profiles: [DeviceProfile]) -> String? {
        let byName = profiles.filter {
            $0.displayName.caseInsensitiveCompare(name) == .orderedSame
        }
        guard byName.count == 1, let used = byName.first else { return nil }
        let hidden = profiles.filter {
            $0.id != used.id && savedTailscaleName($0) == name.lowercased()
        }
        guard !hidden.isEmpty else { return nil }
        let who = hidden.map {
            commandName($0)
        }
        .joined(separator: ", ")
        return "roamrun: using \(commandName(used)), its name in RoamRun; \(who) \(hidden.count == 1 ? "has" : "have") that Tailscale name"
    }

    static func find(_ name: String, in profiles: [DeviceProfile]) -> DeviceProfile? {
        if let why = ambiguous(name, in: profiles) {
            fail(why)
        }
        if let said = shadowNote(name, in: profiles) {
            note(said)
        }
        return matches(name, in: profiles).first
    }

    /// Each saved name, with the Tailscale name that names the same device alone where that differs.
    nonisolated static func names(_ profiles: [DeviceProfile]) -> String {
        profiles.isEmpty ? noDevices
            : "Saved: " + profiles.map { p in
                let host = savedTailscaleName(p) == nil ? "" : tailscaleHost(p.providerHostName)
                let shown = !host.isEmpty && host.caseInsensitiveCompare(p.displayName) != .orderedSame
                    && matches(host, in: profiles).map(\.id) == [p.id]
                return commandName(p) + (shown ? " (\(shellName(host)))" : "")
            }
            .joined(separator: ", ")
    }

    static func owner(_ e: StatusFile.Entry) -> String {
        e.pid == getpid() ? "this process" : e.cli == true ? "roamrun CLI, pid \(e.pid)" : "RoamRun app"
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("roamrun: \(message)\n".utf8))
        exit(2)
    }
}
