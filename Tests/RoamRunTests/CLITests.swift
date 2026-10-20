import Foundation
import Testing
@testable import RoamRun

// MARK: - Suggested commands

@Test func namesAreQuotedForTheShell() {
    #expect(CLI.shellName("MyiPhone") == "MyiPhone")
    #expect(CLI.shellName("iPhone mh") == "'iPhone mh'")
    #expect(CLI.shellName("Hiro's \"iPad\" $1") == #"'Hiro'\''s "iPad" $1'"#)
}

// MARK: - Install: which signing a provisioning profile allows

@Test func provisioningKinds() {
    #expect(CLI.parseProvisioning(["ProvisionedDevices": ["00008102-000B00000000B002"]]) == .devices(["00008102-000B00000000B002"]))
    #expect(CLI.parseProvisioning(["ProvisionsAllDevices": true]) == .allDevices)   // Enterprise
    #expect(CLI.parseProvisioning(["Name": "App Store"]) == .appStore)             // no device list
}

@Test func namesTheCLICanUse() {
    let saved = [profile("iPhone")]
    #expect(saved.nameProblem("  ") != nil)
    #expect(saved.nameProblem(" -x") != nil)       // trimmed first, still an option to the CLI
    #expect(saved.nameProblem("iphone") != nil)
    #expect(saved.nameProblem("iPhone", except: saved[0].id) == nil)
    #expect(saved.nameProblem("iPad") == nil)
}

@Test func emptyAndNonASCIINamesAreQuoted() {
    #expect(CLI.shellName("") == "''")
    #expect(CLI.shellName("Hiro’s iPhone") == "'Hiro’s iPhone'")
    #expect(CLI.shellName("my-iPad_2.0") == "my-iPad_2.0")
}

// MARK: - Argument parsing

private extension Result { var isSuccess: Bool { if case .success = self { true } else { false } } }

private func parsed(_ s: String) -> Result<CLI.Parsed, CLI.ArgumentError> { CLI.parse(s.split(separator: " ").map(String.init)) }

@Test func argumentsPerCommand() throws {
    #expect(try parsed("status --wait 5 iPhone").get().words == ["iPhone"])
    #expect(try parsed("status --wait 5 iPhone").get().wait == 5)
    #expect(try parsed("logs iPhone com.x").get().words == ["iPhone", "com.x"])
    let run = try? parsed("run iPhone --scheme S --logs").get()
    #expect(run?.words == ["iPhone"] && run?.values["--scheme"] == "S" && run?.flags == ["--logs"])
}

@Test func everyValueOptionTakesTheEqualsFormToo() throws {
    #expect(try parsed("status iPhone --wait=60").get().wait == 60)
    let run = try parsed("run iPhone --scheme=S --configuration=Debug --url=myapp://a=b --arg=-v --env=A=b=c").get()
    #expect(run.values["--scheme"] == "S" && run.values["--configuration"] == "Debug")
    #expect(run.launch == CLI.Launch(args: ["-v"], env: ["A=b=c"], url: "myapp://a=b"))   // split at the first "=" only
    // The spaced form still keeps an "=" inside the value.
    #expect(try parsed("run iPhone --env A=B").get().launch.env == ["A=B"])
    // Not for flags, and a name it doesn't take is still refused.
    for bad in ["run iPhone --logs=1", "status iPhone --nope=1", "status iPhone --wait=-1"] {
        #expect((try? parsed(bad).get()) == nil, "\(bad)")
    }
}

@Test func argumentsThatAreRejected() {
    for bad in ["devices -d", "status --wait=", "run x --scheme=", "status --scheme X", "up a b", "status x --wait", "status x --wait inf",
                "status x --wait -1", "run x --scheme", "run x --scheme --logs", "screenshot x a.png b"] {
        #expect((try? parsed(bad).get()) == nil, "\(bad)")
    }
}

@Test func launchOptionsReachDevicectl() throws {
    let p = try parsed("run iPhone --arg -ShowScreen --arg settings --env DEMO=1 --env EMPTY= --url myapp://settings/a=b").get()
    #expect(p.words == ["iPhone"])
    #expect(p.launch == CLI.Launch(args: ["-ShowScreen", "settings"], env: ["DEMO=1", "EMPTY="], url: "myapp://settings/a=b"))
    #expect(p.launch.argv(udid: "U", bundleID: "com.x", console: false) == [
        "/usr/bin/xcrun", "devicectl", "device", "process", "launch", "--terminate-existing", "--device", "U",
        "--payload-url", "myapp://settings/a=b", "com.x", "--", "-ShowScreen", "settings"])
    // logs takes them too, and without any the command is the plain launch.
    #expect(try parsed("logs iPhone com.x --arg -v").get().launch.args == ["-v"])
    #expect(CLI.Launch().argv(udid: "U", bundleID: "com.x", console: true) == [
        "/usr/bin/xcrun", "devicectl", "device", "process", "launch", "--console", "--terminate-existing", "--device", "U", "com.x"])
    // With the console and a URL: devicectl's own options first, the app's after "--".
    let both = CLI.Launch(args: ["-h"], url: "myapp://x").argv(udid: "U", bundleID: "com.x", console: true)
    #expect(both.suffix(8) == ["--terminate-existing", "--device", "U", "--payload-url", "myapp://x", "com.x", "--", "-h"])
    // Split at the first "=", values may hold more (and newlines).
    let env = CLI.Launch(env: ["A=b=c", "E=", "J=line1\nline2"]).environment
    #expect(env.map(\.name) == ["A", "E", "J"] && env.map(\.value) == ["b=c", "", "line1\nline2"])
    #expect(CLI.parse(["run", "x", "--env", "J={\n\"a\": 1\n}"]).isSuccess)
    // "--arg -h" is for the app, not our help.
    #expect(!CLI.wantsHelp(["run", "x", "--arg", "-h"]) && CLI.wantsHelp(["run", "x", "-h"]) && CLI.wantsHelp(["help"]))
    for bad in ["run x --env DEMO", "run x --env 1A=2", "run x --env", "run x --env -X=1", "run x --url settings",
                "run x --url -x", "run x --arg", "screenshot x --arg a", "install x a.ipa --url myapp://x"] {
        #expect((try? parsed(bad).get()) == nil, "\(bad)")
    }
}

@Test func deviceLookup() {
    let a = profile("iPhone"), b = profile("iPad")
    #expect(CLI.matches("IPHONE", in: [a, b]).map(\.id) == [a.id])
    #expect(CLI.matches(String(a.id.uuidString.prefix(7)), in: [a, b]).isEmpty)      // too short for an id
    #expect(CLI.matches(String(a.id.uuidString.prefix(8)), in: [a, b]).map(\.id) == [a.id])
    let named = profile(b.id.uuidString.prefix(8).lowercased())                          // a name wins over an id prefix
    #expect(CLI.matches(String(b.id.uuidString.prefix(8)), in: [b, named]).map(\.id) == [named.id])
}

@Test func deviceLookupByTailscaleName() {
    let phone = profile("iPhone", host: "iphone-15-pro"), vision = profile("Apple-Vision-Pro", host: "apple-vision-pro")
    #expect(CLI.matches("iphone-15-pro", in: [phone, vision]).map(\.id) == [phone.id])
    #expect(CLI.matches("IPHONE-15-PRO", in: [phone, vision]).map(\.id) == [phone.id])
    #expect(CLI.matches("iphone-15-pro.tail1234.ts.net", in: [phone, vision]).map(\.id) == [phone.id])
    #expect(CLI.matches("iphone-15-pro.tail1234.ts.net.", in: [phone, vision]).map(\.id) == [phone.id])
    #expect(CLI.matches("iPhone", in: [phone, vision]).map(\.id) == [phone.id])
    // Shorter than an id prefix: the Tailscale name is tried before that length guard.
    let other = profile("iphone-15-pro", host: "ipad")
    #expect("ipad".count < 8)
    #expect(CLI.matches("ipad", in: [phone, other]).map(\.id) == [other.id])
    #expect(CLI.matches("IPAD", in: [phone, other]).map(\.id) == [other.id])
    // A display name keeps meaning its device over another's Tailscale name.
    #expect(CLI.matches("iphone-15-pro", in: [phone, other]).map(\.id) == [other.id])
    // Saved in another case, or as the MagicDNS name Tailscale prints.
    var mixed = phone; mixed.providerHostName = "iPhone-15-Pro"
    #expect(CLI.matches("iphone-15-pro", in: [mixed, vision]).map(\.id) == [mixed.id])
    var fqdn = phone; fqdn.providerHostName = "iPhone-15-Pro.Tail1234.TS.NET."
    #expect(CLI.matches("iphone-15-pro", in: [fqdn, vision]).map(\.id) == [fqdn.id])
    #expect(CLI.matches("IPHONE-15-PRO.tail1234.ts.net", in: [fqdn]).map(\.id) == [fqdn.id])
    // A dotted name that is not MagicDNS is not the first label.
    #expect(CLI.matches("iphone-15-pro.local", in: [phone, vision]).isEmpty)
    // Two devices under one Tailscale name: both, for find to refuse.
    let again = profile("iPhone old", host: "iphone-15-pro")
    #expect(Set(CLI.matches("iphone-15-pro", in: [phone, again]).map(\.id)) == [phone.id, again.id])
    // A manual device's host is its IP, not a Tailscale name.
    let manual = profile("Lab", host: "192.168.0.5", provider: "manual")
    #expect(CLI.matches("192.168.0.5", in: [manual]).isEmpty)
    // The id prefix still works when no name matches.
    #expect(CLI.matches(String(phone.id.uuidString.prefix(8)), in: [phone, vision]).map(\.id) == [phone.id])
}

@Test func savedListShowsATailscaleNameOnlyWhenItDiffers() {
    let phone = profile("iPhone", host: "iphone-15-pro")
    let same = profile("iPad", host: "ipad")
    let blank = profile("Vision", host: "")
    let manual = profile("Lab", host: "192.168.0.5", provider: "manual")
    #expect(CLI.names([phone, same, blank, manual]) == "Saved: iPhone (iphone-15-pro), iPad, Vision, Lab")
}

@Test func aSavedNameHidesAnotherDevicesTailscaleNameOutLoud() {
    let phone = profile("iPhone", host: "iPhone-15-Pro.tail1234.ts.net.")
    let other = profile("iphone-15-pro", host: "ipad")
    #expect(CLI.shadowNote("iphone-15-pro", in: [phone, other])
             == "roamrun: using iphone-15-pro, its name in RoamRun; iPhone has that Tailscale name")
    #expect(CLI.shadowNote("iPhone", in: [phone, other]) == nil)
    #expect(CLI.shadowNote("ipad", in: [phone, other]) == nil)
    #expect(CLI.shadowNote("iphone-15-pro", in: [other]) == nil)
}

@Test func findRefusesTwoDevicesUnderOneTailscaleName() {
    let phone = profile("iPhone", host: "iphone-15-pro")
    let stale = profile("iPhone old", host: "iPhone-15-Pro.Tail1234.ts.net.")
    let why = CLI.ambiguous("iphone-15-pro", in: [phone, stale])
    #expect(why == "“iphone-15-pro” matches more than one device — use the name it has in RoamRun, or its id: "
            + "iPhone (\(phone.id.uuidString.prefix(8))), 'iPhone old' (\(stale.id.uuidString.prefix(8)))")
    #expect(CLI.ambiguous("iPhone", in: [phone, stale]) == nil)
    #expect(CLI.ambiguous("missing", in: [phone, stale]) == nil)
}

@Test func namingADeviceDoesNotConsultTailscaleNames() {
    let saved = [profile("iPhone", host: "iphone-15-pro")]
    #expect(saved.nameProblem("iphone-15-pro") == nil)   // another's Tailscale name may be this one's name
    #expect(!saved.isNameTaken("iphone-15-pro"))
    #expect(saved.nameProblem("iphone") != nil)
}

/// `pair` and `devices` take a word that says what to do, not a device's name first.
@Test func pairAndDevicesCommandsParse() throws {
    let line = "rr-xcode-offer-v1:eyJ4IjoxfQ"
    let introduce = try CLI.parse(["pair", "introduce", line, "--host", "cloud-mac", "--to=iPhone"]).get()
    #expect(introduce.words == ["introduce", line] && introduce.values["--host"] == "cloud-mac" && introduce.values["--to"] == "iPhone")
    #expect(try CLI.parse(["pair", "xcode"]).get().words == ["xcode"])
    let add = try CLI.parse(["devices", "add", "rr-device-v1:eyJ4IjoxfQ", "--replace", "iPhone", "--peer=iphone-15-pro"]).get()
    #expect(add.words.count == 2 && add.values["--replace"] == "iPhone" && add.values["--peer"] == "iphone-15-pro")
    #expect(try CLI.parse(["devices", "--json"]).get().flags.contains("--json"))
    #expect(throws: (any Error).self) { try CLI.parse(["pair", "introduce", "a", "b", "c"]).get() }
}

@Test func aPairingMadeIsReadFromDeviceHubsLine() {
    #expect(CLI.pairingLog.contains(#"senderImagePath BEGINSWITH "/Library/Developer/PrivateFrameworks/CoreDevice.framework/""#))
    #expect(CLI.pairingEnded("Pairing attempt completed with error nil") == true)
    #expect(CLI.pairingEnded("Pairing attempt completed with error Optional(Error Domain=com.apple.dt.CoreDeviceError Code=2)") == false)
    // Not that line, or more than it: not taken for a pairing.
    #expect(CLI.pairingEnded("Pairing attempt completed with error nil, or so") == false)
    #expect(CLI.pairingEnded("Pairing attempt started") == nil && CLI.pairingEnded("") == nil)
}

@Test func runInstallsTheApplicationNotAnAppClip() {
    let t = { (name: String, type: String) -> [String: Any] in
        ["buildSettings": ["WRAPPER_EXTENSION": "app", "PLATFORM_NAME": "iphoneos", "TARGET_NAME": name,
                           "PRODUCT_TYPE": type, "WRAPPER_NAME": "\(name).app", "TARGET_BUILD_DIR": "/b"]]
    }
    let clip = t("Clip", "com.apple.product-type.application.on-demand-install-capable")
    let app = t("App", "com.apple.product-type.application")
    #expect(CLI.appTarget(in: [clip, app], scheme: "App (Staging)")?["TARGET_NAME"] == "App")
    #expect(CLI.appTarget(in: [app, clip], scheme: "Clip")?["TARGET_NAME"] == "App")   // never the clip
    #expect(CLI.appTarget(in: [], scheme: "App") == nil)
}

@Test func aStatusProbeGetsOnlyTheTimeTheWaitHasLeft() {
    let now = Date.now
    #expect(CLI.probeSeconds(by: nil, now: now) == 10)                                  // no --wait: unchanged
    #expect(CLI.probeSeconds(by: now.addingTimeInterval(60), now: now) == 10)            // plenty: capped
    #expect(CLI.probeSeconds(by: now.addingTimeInterval(7), now: now) == 7)
    // devicectl refuses a --timeout below 5 with a usage error, so that's the floor.
    #expect(CLI.probeSeconds(by: now.addingTimeInterval(1), now: now) == 5)
    #expect(CLI.probeSeconds(by: now.addingTimeInterval(-5), now: now) == 5)             // past: still one try
    // --wait is only checked for being finite and non-negative, and Int(1e19) traps.
    #expect(CLI.probeSeconds(by: now.addingTimeInterval(1e19), now: now) == 10)
}

@Test func onlyAPagePublishedToTheInternetFailsDoctor() {
    // `doctor <name>` exits 1 on a fail, which scripts read as "the device isn't usable".
    #expect(!CLI.failsDoctor(.notPublished))
    #expect(!CLI.failsDoctor(.noHTTPSCertificates))
    #expect(CLI.failsDoctor(.funnel))
}

@Test func onThisWiFiButUnreachableSaysWhy() {
    func entry(_ s: BridgeStatus) -> StatusFile.Entry {
        .init(pid: 4242, cli: false, udid: "U", status: s.title, detail: "", ready: s == .ready, tunnelPorts: [],
              updated: .now, state: s.rawValue)
    }
    let asleep = CLI.readiness(entry(.local), udid: "U", core: "unavailable", deep: true)
    #expect(!asleep.ready && asleep.kind == .local)
    #expect(asleep.detail?.contains("On this Wi") == true)
    let usable = CLI.readiness(entry(.local), udid: "U", core: "connected", deep: true)
    #expect(usable.ready && usable.detail == nil)
    // A bridge that looks ready but CoreDevice can't reach reads as waiting, as before.
    let stale = CLI.readiness(entry(.ready), udid: "U", core: "unavailable", deep: true)
    #expect(!stale.ready && stale.kind == .waiting && stale.detail != nil)
}


@Test func unknownValuesInJSONAreNullNotMissing() throws {
    let row = CLI.Row(name: "iPhone", state: "off", id: "x", vpnAddress: "100.64.0.1", udid: nil, status: "Off",
                      ready: false, owner: nil, pid: nil, tunnelPorts: [], network: nil, coreDevice: nil, detail: nil, locked: nil)
    let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
    for key in ["udid", "owner", "pid", "network", "coreDevice", "detail", "locked"] {
        #expect(json[key] is NSNull, "\(key) should be null")
    }
    let check = CLI.Check(scope: "mac", result: "ok", message: "fine", fix: nil)
    let c = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(check)) as? [String: Any])
    #expect(c["fix"] is NSNull)
}

/// `up -d`'s log, past its limit, becomes `.log.1` and the writing moves to a new file; a
/// rename that fails changes nothing (F42).
@Test func theBackgroundLogRollsOverAtItsLimit() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = dir.appendingPathComponent("iPhone.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let fd = open(log.path, O_WRONLY | O_APPEND)
    defer { close(fd) }
    _ = "old enough to roll\n".withCString { write(fd, $0, strlen($0)) }
    CLI.rotateLog(at: log, limit: 10, fds: [fd])
    _ = "new\n".withCString { write(fd, $0, strlen($0)) }
    #expect(try String(contentsOf: log.appendingPathExtension("1"), encoding: .utf8) == "old enough to roll\n")
    #expect(try String(contentsOf: log, encoding: .utf8) == "new\n")
    // Small: left alone.
    CLI.rotateLog(at: log, limit: 10, fds: [fd])
    #expect(try String(contentsOf: log, encoding: .utf8) == "new\n")
    // The file renamed away under it (can't be moved): the descriptor keeps writing where it was.
    try FileManager.default.removeItem(at: log)
    _ = "more than ten bytes here\n".withCString { write(fd, $0, strlen($0)) }
    CLI.rotateLog(at: log, limit: 10, fds: [fd])
    #expect(!FileManager.default.fileExists(atPath: log.path))
    #expect(try String(contentsOf: log.appendingPathExtension("1"), encoding: .utf8) == "old enough to roll\n")   // the last run's kept
}

/// A step after the first failing (here: the last `.1` can't be moved aside) undoes the rest:
/// the live log and the last run's keep their names and contents (F42 review).
@Test func aRolloverThatFailsMidwayKeepsBothLogs() throws {
    let dir = scratchDir()
    let log = dir.appendingPathComponent("iPhone.log"), previous = log.appendingPathExtension("1")
    defer {
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: previous.path)
        try? FileManager.default.removeItem(at: dir)
    }
    try Data("last run\n".utf8).write(to: previous)
    try Data("this run, long enough\n".utf8).write(to: log)
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: previous.path)
    let fd = open(log.path, O_WRONLY | O_APPEND)
    defer { close(fd) }
    CLI.rotateLog(at: log, limit: 10, fds: [fd])
    #expect(try String(contentsOf: previous, encoding: .utf8) == "last run\n")
    #expect(try String(contentsOf: log, encoding: .utf8) == "this run, long enough\n")
    _ = "still here\n".withCString { write(fd, $0, strlen($0)) }
    #expect(try String(contentsOf: log, encoding: .utf8).hasSuffix("still here\n"))   // the descriptor's file kept its name
}

/// A command we suggest for a device whose name starts with "-" names it by id: the name
/// would be read as an option (F13).
@Test func aSuggestedCommandNamesADashDeviceByID() {
    var p = profile("-iPad")
    #expect(CLI.commandName(p) == p.id.uuidString)
    p.displayName = "Kid's iPad"
    #expect(CLI.commandName(p) == "'Kid'\\''s iPad'")
}

/// The text to type or paste is text, whatever it starts with: `-1`, `--json`, `-h`.
@Test func textForTheDeviceMayStartWithADash() throws {
    for command in ["type", "paste"] {
        for text in ["-1", "--json", "-h", "--help", "- milk", ""] {
            #expect(try CLI.parse([command, "iPhone", text]).get().words == ["iPhone", text], "\(command) \(text)")
            #expect(!CLI.wantsHelp([command, "iPhone", text]))
        }
        #expect(CLI.wantsHelp([command, "--help"]) && CLI.wantsHelp([command, "iPhone", "x", "-h"]))
        #expect(throws: CLI.ArgumentError.self) { try CLI.parse([command, "iPhone", "a", "b"]).get() }   // one text
    }
    // Elsewhere a dash still starts an option, and one a command doesn't take is refused.
    #expect(throws: CLI.ArgumentError.self) { try CLI.parse(["tap", "iPhone", "-5", "10"]).get() }
    #expect(throws: CLI.ArgumentError.self) { try CLI.parse(["press", "iPhone", "-h2"]).get() }
}

/// `--look <n>` holds a command to look n, as the MCP tools are: what an agent sharing the device gives.
/// After the text for type and paste (the word after the name is the text, whatever it is).
@Test func aCommandMayNameItsLook() throws {
    #expect(try CLI.parse(["tap", "iPhone", "1", "2", "--look", "5"]).get().values["--look"] == "5")
    #expect(try CLI.parse(["swipe", "iPhone", "1", "2", "3", "4", "--look=6"]).get().values["--look"] == "6")
    for command in ["type", "paste"] {
        let parsed = try CLI.parse([command, "iPhone", "hello", "--look", "7"]).get()
        #expect(parsed.words == ["iPhone", "hello"] && parsed.values["--look"] == "7", "\(command)")
        // Right after the name it is the text, and the number one word too many.
        #expect(throws: CLI.ArgumentError.self, "\(command)") { try CLI.parse([command, "iPhone", "--look", "7"]).get() }
    }
    #expect(throws: CLI.ArgumentError.self) { try CLI.parse(["press", "iPhone", "home", "--look", "5"]).get() }   // a button isn't held to one
    #expect(throws: CLI.ArgumentError.self) { try CLI.parse(["look", "iPhone", "--look", "5"]).get() }
}

/// Not connected because this Mac itself is off Tailscale is said as that, not as the device being away.
@Test func notConnectedSaysWhenThisMacIsOffTailscale() {
    #expect(CLI.ControlState.notConnectedLine(mesh: nil) == CLI.ControlState.notConnected.line)
    let down = CLI.meshProblem { throw TailscaleClientError.commandFailed(TailscaleClient.stateProblem("NeedsLogin")!) }
    #expect(down?.contains("isn't signed in") == true)
    let line = CLI.ControlState.notConnectedLine(mesh: down)
    #expect(line.contains("isn't signed in") && !line.contains("on a Wi‑Fi"))
    #expect(CLI.meshProblem { [] } == nil)
    #expect(CLI.meshProblem { throw TailscaleClientError.cliNotFound }?.contains("not found") == true)
}

/// Where a pairing is written is had before the pairing is made, new and the owner's alone: a
/// file that is there — put there while the code was being entered, say — is never written over,
/// nor one a link leads to.
@Test func aPairingIsWrittenOnlyToAFileMadeForIt() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fresh = dir.appendingPathComponent("k.json").path
    let fd = try CLI.reserve(fresh)
    #expect(try FileManager.default.attributesOfItem(atPath: fresh)[.posixPermissions] as? Int == 0o600)
    #expect(CLI.write(Data("the pairing".utf8), to: fd))
    close(fd)
    #expect(try String(contentsOfFile: fresh, encoding: .utf8) == "the pairing")

    #expect(throws: (any Error).self) { try CLI.reserve(fresh) }                      // there already
    #expect(try String(contentsOfFile: fresh, encoding: .utf8) == "the pairing")

    let other = dir.appendingPathComponent("someone's.txt").path
    try "theirs".write(toFile: other, atomically: true, encoding: .utf8)
    let link = dir.appendingPathComponent("link.json").path
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: other)
    #expect(throws: (any Error).self) { try CLI.reserve(link) }                       // a link to a file
    #expect(try String(contentsOfFile: other, encoding: .utf8) == "theirs")
    let dangling = dir.appendingPathComponent("dangling.json").path
    try FileManager.default.createSymbolicLink(atPath: dangling, withDestinationPath: dir.appendingPathComponent("not yet").path)
    #expect(throws: (any Error).self) { try CLI.reserve(dangling) }                   // a link to nothing: nothing made behind it
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("not yet").path))
    #expect(throws: (any Error).self) { try CLI.reserve(dir.appendingPathComponent("no such folder/k.json").path) }
}

/// What was made for a pairing is what is removed when it fails or is interrupted: not a file
/// another put under that name meanwhile.
@Test func onlyTheFileMadeForAPairingIsRemoved() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("k.json").path
    var fd = try CLI.reserve(path)
    #expect(DeviceControlWire.names(path, theFileOf: fd))
    try FileManager.default.removeItem(atPath: path)
    try "another's".write(toFile: path, atomically: true, encoding: .utf8)
    #expect(!DeviceControlWire.names(path, theFileOf: fd))
    CLI.removeReserved(path, fd)
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "another's")
    close(fd)
    try FileManager.default.removeItem(atPath: path)

    fd = try CLI.reserve(path)
    defer { close(fd) }
    CLI.removeReserved(path, fd)
    #expect(!FileManager.default.fileExists(atPath: path))
    // A link put where it was is not followed either.
    let other = dir.appendingPathComponent("theirs.txt").path
    try "theirs".write(toFile: other, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: other)
    CLI.removeReserved(path, fd)
    #expect(FileManager.default.fileExists(atPath: other) && (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil)
}

/// A pairing travels under the UDID of the device it was made with, not one saved earlier for
/// whatever answered at that address then.
@Test func aSharedPairingNamesTheDeviceItWasMadeWith() {
    #expect(CLI.sharedUDID(saved: nil, paired: "U2") == "U2")
    #expect(CLI.sharedUDID(saved: "U1", paired: "U2") == "U2")              // proved by connecting: it is U2
    #expect(CLI.sharedUDID(saved: "0000-ABCD", paired: "0000-abcd") == "0000-ABCD")   // the same one, as it is spelled here
    #expect(CLI.sharedUDID(saved: "U1", paired: "") == "U1")                // it named none
    #expect(CLI.sharedUDID(saved: nil, paired: "") == nil)
}

/// A look takes the place of a file, never of a folder: one of that name was removed with all
/// it held. And where it can't be written, what was there stays.
@Test func aLookTakesAFilesPlaceNotAFolders() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    func made(_ text: String) throws -> URL {
        let url = dir.appendingPathComponent("made-\(UUID().uuidString).png")
        try Data(text.utf8).write(to: url)
        return url
    }
    let folder = dir.appendingPathComponent("screens.png")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("kept".utf8).write(to: folder.appendingPathComponent("earlier.png"))
    var look = try made("new")
    #expect(throws: (any Error).self) { try CLI.put(look: look, at: folder) }
    #expect(try String(contentsOf: folder.appendingPathComponent("earlier.png"), encoding: .utf8) == "kept")
    #expect(!FileManager.default.fileExists(atPath: look.path))            // not left lying either way

    let file = dir.appendingPathComponent("now.png")
    try Data("old".utf8).write(to: file)
    look = try made("new")
    try CLI.put(look: look, at: file)
    #expect(try String(contentsOf: file, encoding: .utf8) == "new")
    #expect(!FileManager.default.fileExists(atPath: look.path))

    look = try made("newer")
    #expect(throws: (any Error).self) { try CLI.put(look: look, at: dir.appendingPathComponent("no such folder/now.png")) }
    #expect(try String(contentsOf: file, encoding: .utf8) == "new")
    try CLI.put(look: try made("first"), at: dir.appendingPathComponent("fresh.png"))
    #expect(try String(contentsOf: dir.appendingPathComponent("fresh.png"), encoding: .utf8) == "first")
    // A name as long as a file's may be: what is made beside it first is no longer.
    let long = dir.appendingPathComponent(String(repeating: "a", count: 251) + ".png")
    try CLI.put(look: try made("long"), at: long)
    #expect(try String(contentsOf: long, encoding: .utf8) == "long")
}

/// `key` takes a word that says what to do, not a device's name first.
@Test func keyCommandsParse() throws {
    #expect(try CLI.parse(["key", "create", "iPhone", "/tmp/k.json", "--as", "RoamRun (cloud)"]).get().values["--as"] == "RoamRun (cloud)")
    #expect(try CLI.parse(["key", "import", "/tmp/k.json", "--as=Phone"]).get().words == ["import", "/tmp/k.json"])
    #expect(throws: (any Error).self) { try CLI.parse(["key", "create", "a", "b", "c", "d"]).get() }
}

/// The name these had in 0.3.0 says where they went; nothing else is taken for a renamed command.
@Test func theOldNameSaysWhereItWent() {
    #expect(CLI.moved("pairing")?.contains("roamrun key") == true)
    #expect(CLI.moved("key") == nil && CLI.moved("up") == nil && CLI.moved("pair") == nil)
}

/// Two `roamrun up -d` for one device take turns from the check to the child's claim: the second
/// waits, and then finds the first (it used to rotate the first's log away from under it).
@Test func detachedUpsForOneDeviceTakeTurns() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = UUID()
    let first = try #require(CLI.upTurn(for: id, in: dir))
    #expect(CLI.upTurn(for: id, in: dir, wait: false) == nil)        // taken
    let other = try #require(CLI.upTurn(for: UUID(), in: dir, wait: false))   // another device's is its own
    close(other)
    close(first)
    // Free once the first is closed — but a process another test starts at that moment holds a
    // copy of it until it execs, so it is asked for a little while, not once.
    func soon() -> Int32? {
        for _ in 0..<1000 {
            if let turn = CLI.upTurn(for: id, in: dir, wait: false) { return turn }
            usleep(10_000)
        }
        return nil
    }
    var second = soon()
    #expect(second != nil)
    // Ended once, however often it is asked (each round of the wait asks): nothing is left to
    // close a second time — by then the number may be another file's.
    CLI.endTurn(&second)
    #expect(second == nil)
    CLI.endTurn(&second)
    let third = try #require(soon())   // and the turn is free (asked as above: the same copy may be held)
    close(third)
}

/// A second `roamrun up` for a device another one handles is refused in every state, an
/// errored one too: both would retry, take the entry from each other, and `down` stops one.
@Test func aSecondUpIsRefusedWhateverTheFirstIsDoing() {
    func e(_ pid: Int32, cli: Bool?, _ s: BridgeStatus) -> StatusFile.Entry {
        .init(pid: pid, cli: cli, udid: nil, status: s.title, detail: "", ready: s == .ready, tunnelPorts: [], updated: .now)
    }
    for s in [BridgeStatus.error, .starting, .waiting, .ready, .local] {
        #expect(CLI.otherUp(e(200, cli: true, s), me: 300) != nil, "\(s)")
    }
    #expect(CLI.otherUp(e(300, cli: true, .error), me: 300) == nil)    // its own entry
    #expect(CLI.otherUp(e(200, cli: false, .error), me: 300) == nil)   // the app's: claim rules decide
    #expect(CLI.otherUp(e(200, cli: nil, .error), me: 300) == nil)     // an old entry with no `cli`
    #expect(CLI.otherUp(nil, me: 300) == nil)
}

@Test func aTerminalQRIsTheRightWayUp() {
    let m = TerminalQR.modules("roamrun-introducer://cloud-mac.example.ts.net")
    #expect(m.count >= 23 && m.allSatisfy { $0.count == m.count })
    // A finder's top edge is seven dark modules over five light ones; the bottom right has none.
    func finder(_ y: Int, _ x: Int) -> Bool { m[y][x..<x + 7].allSatisfy { $0 } && !m[y + 1][x + 1..<x + 6].contains(true) }
    let far = m.count - 8
    #expect(finder(1, 1) && finder(1, far) && finder(far, 1) && !finder(far, far))
    #expect(TerminalQR.lines("x").allSatisfy { $0.hasPrefix("\u{1B}[30;107m") })
    // The window it asks for is the code's own width (margins in, colour codes out) and two rows more.
    let drawn = TerminalQR.lines("roamrun-introducer://cloud-mac.example.ts.net", level: "L")
    let room = TerminalQR.room(for: drawn)
    #expect(room.across == TerminalQR.modules("roamrun-introducer://cloud-mac.example.ts.net", level: "L").count + 6 && room.down == drawn.count + 2)
    #expect(TerminalQR.room(for: []) == (0, 2))
    let address = "roamrun-introducer://cloud-mac.example.ts.net?p=53050&i=0A0A0A0A-D414-41D0-BE80-7567AE75B2BC&a=AAECAwQF&m=Mac16,1&n=cloud-mac&f=1&v=26&w=17"
    #expect(TerminalQR.modules(address, level: "L").count < TerminalQR.modules(address, level: "M").count)
}
