import Foundation
import Testing
@testable import RoamRun
import Network

/// Echoes everything back (or, `silent`, accepts and never answers). Keeps its
/// connections, so a test can close them all at a moment of its choosing.
/// One request over a real socket, because `readHead`, the connection count and
/// `stop()` are the parts of OTAServer that only exist at runtime — and they are
/// the parts that were rewritten with nothing exercising them.
/// Sends `request` raw, reads until the server closes, returns what came back.
private func ask(_ port: UInt16, _ request: String, hold: TimeInterval = 0) async -> String? {
    let conn = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    defer { conn.cancel() }
    conn.start(queue: .global())
    // A server that neither answers nor closes: the read below ends with the connection.
    DispatchQueue.global().asyncAfter(deadline: .now() + hold + 30) {
        conn.cancel()
    }
    if hold > 0 {
        try? await Task.sleep(for: .seconds(hold))
    }
    if !request.isEmpty {
        conn.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
    }
    var got = Data()
    while got.count < 1 << 20 {
        let (chunk, done): (Data?, Bool) = await withCheckedContinuation { c in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, isDone, err in
                c.resume(returning: (d, isDone || err != nil))
            }
        }
        if let chunk {
            got.append(chunk)
        }
        if done {
            break
        }
    }
    return got.isEmpty ? nil : String(decoding: got, as: UTF8.self)
}

extension TimingSensitive {
    @Suite(.serialized) struct OTAServerOverASocket {
        private func started() throws -> (OTAServer, UInt16) {
            let server = OTAServer(tailnetPort: 41443)
            server.servedName = "m" // the requests below name it as their Host
            let port = try #require(server.start())
            return (server, port)
        }

        @Test func itAnswersOnlyTheMethodsAndRequestsItServes() async throws {
            let (server, port) = try started()
            defer { server.stop() }
            // A path it doesn't serve: nothing here touches stored builds.
            #expect(await ask(port, "GET /nope HTTP/1.1\r\nHost: m:41443\r\n\r\n")?.hasPrefix("HTTP/1.1 404") == true)
            #expect(await ask(port, "POST / HTTP/1.1\r\nHost: m:41443\r\n\r\n")?.hasPrefix("HTTP/1.1 405") == true)
            // Without a Host every link in the manifest would point the device at itself.
            #expect(await ask(port, "GET /nope HTTP/1.1\r\n\r\n")?.hasPrefix("HTTP/1.1 400") == true)
            #expect(await ask(port, "GET /nope HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n")?
                .hasPrefix("HTTP/1.1 400") == true)
            // A head that never ends.
            let huge = "GET /nope HTTP/1.1\r\nHost: m\r\nX: " + String(repeating: "y", count: 40_000) + "\r\n"
            #expect(await ask(port, huge)?.hasPrefix("HTTP/1.1 431") == true)
            // Still answering afterwards: none of those wedged it.
            #expect(await ask(port, "HEAD /nope HTTP/1.1\r\nHost: m:41443\r\n\r\n")?
                .hasPrefix("HTTP/1.1 404") == true)
        }

        @Test func aHostThatIsntOurTailnetNameIsRefused() async throws {
            let (server, port) = try started()
            defer { server.stop() }
            // A page on this Mac that rebinds its own name to 127.0.0.1 sends its own Host.
            #expect(await ask(port, "GET / HTTP/1.1\r\nHost: attacker.example:41443\r\n\r\n")?
                .hasPrefix("HTTP/1.1 421") == true)
            // Case and a trailing dot are the same name.
            #expect(await ask(port, "GET /nope HTTP/1.1\r\nHost: M.:41443\r\n\r\n")?.hasPrefix("HTTP/1.1 404") == true)
            // Before the name is known, nothing is served.
            server.servedName = nil
            #expect(await ask(port, "GET /nope HTTP/1.1\r\nHost: m:41443\r\n\r\n")?.hasPrefix("HTTP/1.1 421") == true)
        }

        @Test func aPeerThatSaysNothingLetsGoOfItsSlot() async throws {
            let (server, port) = try started()
            defer { server.stop() }
            // The cap is every connection there is, and a peer that connects and stays
            // quiet produces no callback to check a deadline in — which is why the
            // deadline is on the idle timer rather than inside the read loop.
            let silent = (0 ..< OTAServer.maxConnections).map { _ in
                Task {
                    _ = await ask(port, "", hold: 30)
                }
            }
            try await Task.sleep(for: .seconds(1))
            // One more is refused outright rather than queued behind them.
            #expect(await ask(port, "GET /nope HTTP/1.1\r\nHost: m\r\n\r\n") == nil)
            // And they are let go of well inside the idle limit, not held for 120 s.
            try await Task.sleep(for: .seconds(16))
            #expect(await ask(port, "GET /nope HTTP/1.1\r\nHost: m\r\n\r\n")?.hasPrefix("HTTP/1.1 404") == true)
            for t in silent {
                t.cancel()
            }
        }

        @Test func stoppingTakesTheConnectionsWithIt() async throws {
            let (server, port) = try started()
            // Connected and waiting to be told something — and reading, so it can see
            // the close when it comes.
            let quiet = Task {
                await ask(port, "")
            }
            try await Task.sleep(for: .seconds(1))
            // Cancelling the listener only stops new ones; a connection in flight used
            // to sit there until the idle timer, because the pump holds the server
            // weakly and the chain simply stops when the server goes.
            server.stop()
            let closed = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    _ = await quiet.value; return true
                }
                // Well inside the 15 s the head deadline would take, so a pass here is
                // `stop` having done it rather than the timer.
                group.addTask {
                    try? await Task.sleep(for: .seconds(5)); return false
                }
                defer { group.cancelAll() }
                return await group.next() ?? false
            }
            #expect(closed)
            #expect(server.port == 0)
        }
    }
}

// MARK: - Over-the-air builds

@Test func onlyBuildsIOSWillInstallOverTheAirAreAccepted() throws {
    func profile(_ entitlements: [String: Any], _ devices: [String]?) -> [String: Any] {
        var p: [String: Any] = ["Entitlements": entitlements]
        if let devices {
            p["ProvisionedDevices"] = devices
        }
        return p
    }
    let udid = "00008130-000D00000000D004"
    let mine = [OTA.Device(name: "iPhone", udid: udid)]
    // Enterprise: no device list, installs anywhere.
    #expect(try OTA.check(["ProvisionsAllDevices": true, "Entitlements": [:]], against: mine).coverage == .everyDevice)
    // Ad Hoc for this device.
    #expect(try OTA.check(profile(["get-task-allow": false], [udid]), against: mine).coverage
        == .devices(covers: ["iPhone"], unchecked: []))
    // Which problem, not just "a problem": every one of these used to pass if the
    // build were rejected for some entirely different reason.
    #expect(throws: OTA.Problem.development("That build")) {
        try OTA.check(profile(["get-task-allow": true], [udid]), against: mine)
    }
    #expect(throws: OTA.Problem.appStore("That build")) { try OTA.check(["Entitlements": [:]], against: mine) }
    // A device list with no entitlements can't be told from a Development profile.
    #expect(throws: OTA.Problem.unreadable("the entitlements in That build's provisioning profile")) {
        try OTA.check(["ProvisionedDevices": [udid]], against: mine)
    }
    #expect(throws: OTA.Problem.unreadable(
        "the provisioning profile in That build — the archive may be unsigned. " +
            "Export it for Release Testing (Ad Hoc) or Enterprise."
    )) {
        try OTA.check(nil, against: mine)
    }
}

@Test func aBuildIsCheckedAgainstEveryDeviceBecauseThePageOffersItToAll() throws {
    // The page has no idea which device is asking, so "does it cover the one you
    // named" was never the question — this is which of yours can take it.
    let a = "00008130-000D00000000D004", b = "00008120-001A2B3C4D5E6F70"
    let devices = [OTA.Device(name: "iPhone", udid: a),
                   OTA.Device(name: "iPad", udid: b),
                   OTA.Device(name: "Vision Pro", udid: nil)] // never bridged, so unknown
    let adHoc: [String: Any] = ["ProvisionedDevices": [a], "Entitlements": ["get-task-allow": false]]
    #expect(try OTA.check(adHoc, against: devices).coverage
        == .devices(covers: ["iPhone"], unchecked: ["Vision Pro"]))
    let both: [String: Any] = ["ProvisionedDevices": [a, b], "Entitlements": ["get-task-allow": false]]
    #expect(try OTA.check(both, against: devices).coverage
        == .devices(covers: ["iPhone", "iPad"], unchecked: ["Vision Pro"]))
    // None of yours is an answer, not a refusal: the page is open to the whole
    // tailnet, and the profile may name a device this Mac has never seen.
    let other: [String: Any] = ["ProvisionedDevices": ["OTHER"], "Entitlements": ["get-task-allow": false]]
    #expect(try OTA.check(other, against: devices).coverage
        == .noneOfYours(known: ["iPhone", "iPad"], unchecked: ["Vision Pro"]))
    // Same when RoamRun knows no UDID at all, and when nothing is saved: neither
    // is a reason to refuse a build someone else's device can take.
    #expect(try OTA.check(adHoc, against: [devices[2]]).coverage
        == .noneOfYours(known: [], unchecked: ["Vision Pro"]))
    #expect(try OTA.check(adHoc, against: []).coverage == .noneOfYours(known: [], unchecked: []))
    // Enterprise needs no device at all — not even a saved one.
    #expect(try OTA.check(["ProvisionsAllDevices": true], against: []).coverage == .everyDevice)
}

@Test func theManifestPointsAtTheBuildItDescribes() throws {
    let build = OTA.Build(bundleID: "com.example.App", title: "App & Co", version: "1.2.0", build: "45",
                          added: .now, size: 3_200_000, slug: "1.2.0-45-20260928-0730")
    let data = try #require(OTA.manifest(for: build, base: "https://mac.tail1234.ts.net/roamrun"))
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    let item = (plist?["items"] as? [[String: Any]])?.first
    let url = ((item?["assets"] as? [[String: String]])?.first)?["url"]
    #expect(url == "https://mac.tail1234.ts.net/roamrun/com.example.App/\(build.slug)/app.ipa")
    let metadata = item?["metadata"] as? [String: String]
    #expect(metadata?["bundle-identifier"] == "com.example.App")
    #expect(metadata?["kind"] == "software") // iOS refuses the manifest without it
    #expect(metadata?["bundle-version"] == "45") // CFBundleVersion, not the marketing one
    #expect(metadata?["title"] == "App & Co")
    #expect(OTA.installLink(for: build, base: "https://x/p")
        .hasPrefix("itms-services://?action=download-manifest&url=https://x/p/"))
}

@Test func aTitleXmlCantHoldNeverReachesTheManifest() throws {
    // `title` is CFBundleDisplayName, straight out of someone's .ipa. XML 1.0
    // has no way to carry most control characters, so this is the one input
    // that can make the manifest unserialisable — and a 200 with an empty body
    // is exactly the silent failure the whole feature exists to avoid.
    let odd = OTA.Build(bundleID: "com.example.App", title: "App\u{0}Name", version: "1.0", build: "1",
                        added: .now, size: 1, slug: "1.0-1-x")
    // Whether Foundation refuses such a title or emits it anyway depends on the
    // machine — this assertion, pinned to one of them, went red on CI. So the
    // characters don't reach it: the manifest is always produced and always
    // parses back, everywhere.
    let made = try #require(OTA.manifest(for: odd, base: "https://m.ts.net:41443"))
    let back = try PropertyListSerialization.propertyList(from: made, format: nil) as? [String: Any]
    let title = ((back?["items"] as? [[String: Any]])?.first?["metadata"] as? [String: String])?["title"]
    #expect(title == "AppName")
    #expect(OTA.printable("a\u{0}b\u{7}c") == "abc")
    #expect(OTA.printable("tab\tnewline\nfine") == "tab\tnewline\nfine")
    // And the page doesn't carry them either.
    #expect(!OTA.escape("App\u{0}Name").contains("\u{0}"))
    // An ordinary title is unaffected.
    let fine = OTA.Build(bundleID: "com.example.App", title: "App", version: "1.0", build: "1",
                         added: .now, size: 1, slug: "1.0-1-x")
    #expect(OTA.manifest(for: fine, base: "https://m.ts.net:41443") != nil)
}

@Test func thePageEscapesWhatCameFromTheArchive() {
    let build = OTA.Build(bundleID: "com.example.App", title: "<script>alert(1)</script>", version: "1.0", build: "1",
                          added: .now, size: 1)
    let html = OTA.indexHTML([(bundleID: "com.example.App", builds: [build])], base: "https://x/p", in: absentOTA)
    #expect(!html.contains("<script>alert"))
    #expect(html.contains("&lt;script&gt;"))
    #expect(html.contains("NEWEST"))
    #expect(OTA.indexHTML([], base: "https://x/p", in: absentOTA).contains("No builds yet"))
}

@Test func theServerWontServeAnythingOutsideItsOwnDirectory() {
    #expect(OTAServer.segments("/") == [])
    #expect(OTAServer.segments("/com.example.App/1.0-1-x/app.ipa") == ["com.example.App", "1.0-1-x", "app.ipa"])
    // A climb out has its dots dropped, so the path can no longer name a parent.
    #expect(OTAServer.segments("/../../etc/passwd") == ["etc", "passwd"])
    #expect(OTAServer.segments("/a/./b") == ["a", "b"])
    let (method, path, host) = OTAServer.request("GET /x/y?z=1 HTTP/1.1\r\nHost: mac.ts.net\r\n\r\n")
    #expect(method == "GET")
    #expect(path == "/x/y")
    #expect(host == "mac.ts.net")
    // Percent-encoding doesn't get a second chance to climb: appendingPathComponent
    // encodes rather than decodes, so these are ordinary names and miss everything.
    #expect(OTAServer.segments("/%2e%2e/%2e%2e/etc") == ["%2e%2e", "%2e%2e", "etc"])
    // The head is found from where the last receive stopped, less the three bytes
    // the terminator can straddle: a peer sending one byte at a time would
    // otherwise have the whole buffer rescanned on every one of them.
    let whole = Data("GET / HTTP/1.1\r\nHost: m\r\n\r\nbody".utf8)
    #expect(OTAServer.endOfHead(whole) == 23)
    #expect(OTAServer.endOfHead(whole, from: 20) == 23) // straddling the boundary
    #expect(OTAServer.endOfHead(whole, from: 24) == nil) // already past it
    #expect(OTAServer.endOfHead(Data("GET / HTTP/1.1\r\nHost: m\r\n".utf8)) == nil)
    #expect(OTAServer.endOfHead(Data()) == nil)
    // No Host, or two of them, and the manifest would send the device to itself.
    #expect(OTAServer.request("GET / HTTP/1.0\r\n").2 == nil)
    #expect(OTAServer.request("GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n").2 == nil)
}

@Test func theBiggestIconIsPickedAndTheIpadOneOnlyIfItIsAllThereIs() {
    // The page is read on a phone, so an iPad icon is the last resort.
    #expect(OTA.biggestIcon(["AppIcon60x60@2x.png", "AppIcon76x76@2x~ipad.png"]) == "AppIcon60x60@2x.png")
    #expect(OTA.biggestIcon(["AppIcon76x76@2x~ipad.png"]) == "AppIcon76x76@2x~ipad.png")
    // Higher scale wins at the same size, and a bigger source scales down well.
    #expect(OTA.biggestIcon(["AppIcon60x60@2x.png", "AppIcon60x60@3x.png"]) == "AppIcon60x60@3x.png")
    #expect(OTA.biggestIcon(["AppIcon40x40@2x.png", "AppIcon60x60@2x.png"]) == "AppIcon60x60@2x.png")
    #expect(OTA.biggestIcon([]) == nil)
}

@Test func twoFilesAreTheSameArchiveOnlyIfEveryByteMatches() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b"), c = dir.appendingPathComponent("c")
    // Bigger than the 1 MB read, so the whole file is really hashed.
    let payload = Data(repeating: 0x41, count: 3_000_000)
    try payload.write(to: a)
    try payload.write(to: b)
    try (payload + Data([0x42])).write(to: c)
    #expect(OTA.digest(of: a) == OTA.digest(of: b))
    #expect(OTA.digest(of: a) != OTA.digest(of: c))
    #expect(OTA.digest(of: dir.appendingPathComponent("missing")) == nil)
}

@Test func theLabelReplaceMatchesOnIsVersionAndBuildNumber() {
    // The label is what a reader sees, so it is what --replace collapses.
    func build(_ v: String, _ b: String) -> OTA.Build {
        .init(bundleID: "com.example.App", title: "App", version: v, build: b, added: .now, size: 1)
    }
    #expect(build("1.2.0", "45").label == "1.2.0 (45)")
    #expect(build("1.2.0", "").label == "1.2.0") // no build number to show
    #expect(build("1.2.0", "1.2.0").label == "1.2.0") // Xcode's default, not worth repeating
    #expect(build("1.2.0", "45").label != build("1.2.0", "46").label)
}

@Test func aSlugSurvivesBeingPutInAURLAndAFileName() {
    let when = Date(timeIntervalSince1970: 1_790_000_000)
    // Whatever a version string contains, the slug has to go into a URL and come
    // back unchanged. Asserted against ASCII directly, not against the same
    // predicate the implementation uses.
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    for version in ["1.0 beta", "1.0-テスト", "١٢", "a/b", "v#1", "100%"] {
        #expect(OTA.Build.slug(version: version, build: "45", at: when).allSatisfy(allowed.contains))
    }
    #expect(OTA.Build.slug(version: "1.2.0", build: "45", at: when).hasPrefix("1.2.0-45-"))
    #expect(!OTA.Build.slug(version: "a/b", build: "#", at: when).contains("/"))
    // UTC, so the name doesn't move when the Mac changes time zone.
    #expect(OTA.Build.slug(version: "1", build: "1", at: when) == "1-1-20260921-141320")
}

@Test func aBundleIdThatCouldNameSomewhereElseIsRefused() {
    #expect(OTA.isPlainName("com.example.App"))
    #expect(!OTA.isPlainName("../../../../tmp/x"))
    #expect(!OTA.isPlainName(".hidden")) // invisible to everything that walks the directory
    #expect(!OTA.isPlainName("a/b"))
    #expect(!OTA.isPlainName(""))
    // A URL component too: `&` would end the itms-services query early, and
    // anything non-ASCII comes back percent-encoded and matches nothing.
    #expect(!OTA.isPlainName("com.foo&bar"))
    #expect(!OTA.isPlainName("com.foo?bar"))
    #expect(!OTA.isPlainName("com.フー"))
    #expect(OTA.isPlainName("com.example.my_app"))
}

@Test func onlyTheRootOfRoamRunsOwnPortCounts() {
    // One port, one handler. Everything else the user serves is untouched.
    let json = #"""
    {"Web":{"mac.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8788"},
                                          "/roamrun":{"Proxy":"http://127.0.0.1:1"}}},
            "mac.ts.net:41443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:61816"}}}}}
    """#
    let me = "mac.ts.net"
    #expect(TailscaleClient.serving(port: 41443, inJSON: json).root(on: me) == "http://127.0.0.1:61816")
    // The user's own port comes back with its other mounts named, so RoamRun can
    // tell "free" from "carrying something I must not remove".
    #expect(TailscaleClient.serving(port: 443, inJSON: json).root(on: me) == "http://127.0.0.1:8788")
    #expect(TailscaleClient.serving(port: 443, inJSON: json).alongside(me) == ["/roamrun"])
    #expect(TailscaleClient.serving(port: 9999, inJSON: json) == .nothing)
    // Not "nothing": a status we couldn't read is the moment RoamRun would
    // otherwise decide the port is free and overwrite an entry of the user's.
    #expect(TailscaleClient.serving(port: 41443, inJSON: "not json") == .unknown)
    #expect(TailscaleClient.serving(port: 41443, inJSON: "") == .unknown)
    #expect(TailscaleClient.serving(port: 41443, inJSON: "null") == .nothing) // no serve config at all
    // A port with only a sub-path of the user's on it is not an empty port.
    #expect(TailscaleClient.serving(port: 41443, inJSON: #"{"Web":{"m:41443":{"Handlers":{"/mine":{}}}}}"#)
        == .mounted(roots: [], others: [.init(host: "m", path: "/mine")]))
    // Nor is one carrying a TCP forward, which has no Web entry at all: reading a
    // section we don't look at as "nothing here" is the same mistake one layer down.
    let forwarded = TailscaleClient.serving(port: 41443, inJSON: #"{"TCP":{"41443":{"TCPForward":"localhost:22"}}}"#)
    #expect(forwarded == .mounted(roots: [], others: [.init(host: nil, path: "TCP forwarding")]))
    // It belongs to the port, not to a name, so it is in the way whatever the
    // node is called — `tailscale` refuses to serve web on such a port at all.
    #expect(forwarded.alongside("any") == ["TCP forwarding"])
    // `{"HTTPS": true}` is what a plain https serve puts beside its Web entry.
    #expect(TailscaleClient.serving(port: 41443, inJSON: #"{"TCP":{"41443":{"HTTPS":true}}}"#) == .nothing)
    // An entry for the port whose inside we can't read is not an empty port —
    // reading it that way is how RoamRun would take one that is in use.
    #expect(TailscaleClient.serving(port: 41443, inJSON: #"{"Web":{"m:41443":{"Handlers":"?"}}}"#)
        .alongside("m") == ["m (unreadable)"])
    // Funnel is never something RoamRun turns on, and the port it picks can't be
    // published today — but that list is Tailscale's policy, and being wrong
    // about it means unreleased builds on the open internet.
    let funnelled = TailscaleClient.serving(port: 41443, inJSON:
        #"{"AllowFunnel":{"m:41443":true},"Web":{"m:41443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:1"}}}}}"#)
    #expect(funnelled.funnelled(on: "m"))
    #expect(!funnelled.funnelled(on: "other"))
    #expect(!TailscaleClient.serving(port: 41443, inJSON: #"{"AllowFunnel":{"m:41443":false}}"#).funnelled(on: "m"))
}

@Test func onlyTheMountUnderTheNameThisNodeAnswersToNowIsOurs() {
    // `tailscale serve` adds and removes under st.Self.DNSName and nothing else,
    // so after a rename our old entry is neither ours to replace nor ours to
    // remove — and the root sitting under the *current* name is someone else's.
    let renamed = #"""
    {"Web":{"old:41443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:61816"}}},
            "new:41443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9999"}}}}}
    """#
    let state = TailscaleClient.serving(port: 41443, inJSON: renamed)
    #expect(state == .mounted(roots: [.init(host: "new", target: "http://127.0.0.1:9999"),
                                      .init(host: "old", target: "http://127.0.0.1:61816")], others: []))
    // Ours is visible, but `off` would take the other one: that is not "ours is
    // still there", and answering yes is how the user's service gets deleted.
    #expect(state.root(on: "new") == "http://127.0.0.1:9999")
    #expect(state.root(on: "old") == "http://127.0.0.1:61816")
    // What sits under the old name blocks nothing: `serve` can't reach it and the
    // name no longer resolves, so it is inert config rather than a port in use.
    // Refusing to publish because of it would end the feature at a rename.
    #expect(state.alongside("new").isEmpty)
    #expect(state.alongside("old").isEmpty)
    #expect(state.root(on: "third") == nil) // a name with nothing of its own
}

@Test func whetherOurRegistrationLandedIsNotAQuestionAboutOneName() {
    // `serve` writes under the name the node has when it runs, which need not be
    // the one we read a moment earlier. Asking only about the old name reads a
    // rename as "it didn't take" and throws away the proof of ownership.
    let state = TailscaleClient.serving(port: 41443, inJSON:
        #"{"Web":{"new:41443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:61816"}}}}}"#)
    #expect(state.root(on: "old") == nil) // the question we must not ask here
    #expect(state.isRegistered("http://127.0.0.1:61816")) // the one we must
    #expect(!state.isRegistered("http://127.0.0.1:1"))
    #expect(!TailscaleClient.Serving.nothing.isRegistered("http://127.0.0.1:61816"))
}

@Test func everyServeChangeThisTickOwesComesBeforeLookingForLeftovers() {
    typealias D = AppCoordinator.Due
    func due(port: Bool = false, published: Bool, listening: Bool = true,
             builds: Bool, failed: Bool = false) -> D
    {
        AppCoordinator.due(portChanged: port, published: published, listening: listening,
                           hasBuilds: builds, publishJustFailed: failed)
    }
    // The sweep shares one lock with all of these, so each has to come first.
    #expect(due(port: true, published: true, builds: true) == .releaseOldPort)
    #expect(due(published: true, builds: false) == .stopServing) // `ota/` deleted
    #expect(due(published: true, listening: false, builds: true) == .restartListener)
    #expect(due(published: false, builds: true) == .publish)
    // Both settled states, where nothing else wants it.
    #expect(due(published: true, builds: true) == .nothing)
    #expect(due(published: false, builds: false) == .nothing)
    // `published == hasBuilds` was not this question: a registration with a dead
    // listener behind it satisfies it and still needs work.
    #expect(due(published: true, listening: false, builds: true) != .nothing)
    // A publish that just failed yields the next turn, so a release it may be
    // waiting on — the port taken by our own leftover, say — can happen.
    #expect(due(published: false, builds: true, failed: true) == .nothing)
    // Order: a port change outranks everything, a deletion outranks recovery.
    #expect(due(port: true, published: true, listening: false, builds: false) == .releaseOldPort)
    #expect(due(published: true, listening: false, builds: false) == .stopServing)
}

@Test func anAttemptThatReturnsEarlyStillGivesTheSweepATurn() {
    var work = AppCoordinator.PublishWork()
    func next(_ work: AppCoordinator.PublishWork) -> AppCoordinator.Due {
        AppCoordinator.due(portChanged: false, published: false, listening: true,
                           hasBuilds: true, publishJustFailed: work.yieldToSweep)
    }
    #expect(next(work) == .publish)

    // Begun before opening the listener: any early return needs no extra failure callback.
    work.began()
    #expect(next(work) == .nothing)
    // A tick while the attempt holds the lock must not consume the sweep's turn.
    let whileRunning = work.offerSweep(due: next(work), changeInProgress: true,
                                       wanted: true, hasRemembered: true)
    #expect(!whileRunning)
    #expect(work.yieldToSweep)

    // The completed attempt yields once; even a failed sweep lets publishing retry.
    let afterFinishing = work.offerSweep(due: next(work), changeInProgress: false,
                                         wanted: true, hasRemembered: true)
    #expect(afterFinishing)
    #expect(next(work) == .publish)
    work.began()
    #expect(next(work) == .nothing)

    // Both confirmed and unconfirmed registrations are tracked instead of retried.
    work.registered()
    #expect(!work.yieldToSweep)
    #expect(AppCoordinator.due(portChanged: false, published: true, listening: true,
                               hasBuilds: true, publishJustFailed: work.yieldToSweep) == .nothing)
}

@Test func offeringCleanupConsumesTheTurnEvenWhenNoSweepIsNeeded() {
    for wanted in [false, true] {
        for remembered in [false, true] {
            var work = AppCoordinator.PublishWork()
            work.began()
            let due = AppCoordinator.due(portChanged: false, published: false, listening: true,
                                         hasBuilds: true, publishJustFailed: work.yieldToSweep)
            #expect(due == .nothing)
            // The production decision consumes before checking these prerequisites.
            let sweep = work.offerSweep(due: due, changeInProgress: false,
                                        wanted: wanted, hasRemembered: remembered)
            #expect(sweep == (wanted && remembered))
            #expect(!work.yieldToSweep)
            #expect(AppCoordinator.due(portChanged: false, published: false, listening: true,
                                       hasBuilds: true, publishJustFailed: work.yieldToSweep) == .publish)
        }
    }
}

@Test func offeringCleanupDoesNotTakeTheTurnOfAnUrgentServeChange() {
    for due: AppCoordinator.Due in [.releaseOldPort, .stopServing, .restartListener, .publish] {
        var work = AppCoordinator.PublishWork()
        work.began()
        let sweep = work.offerSweep(due: due, changeInProgress: false,
                                    wanted: true, hasRemembered: true)
        #expect(!sweep)
        #expect(work.yieldToSweep)
    }
}

@Test func aSweepThatStartedEarlierCantCancelARequestMadeWhileItRan() {
    var work = AppCoordinator.StrayWork()
    #expect(work.wanted) // something may always be left from a previous run

    // The ordinary case: it starts, finds nothing of ours, and stops asking.
    let first = work.generation
    work.finished(true, startedAt: first)
    #expect(!work.wanted)

    // A listener dying mid-sweep is the case this exists for: the request made
    // while it ran points at the registration that sweep never saw.
    work.askAgain()
    let second = work.generation
    work.askAgain() // e.g. recovery, after the sweep began
    work.finished(true, startedAt: second)
    #expect(work.wanted)

    // The next sweep, started after it, may clear it.
    let third = work.generation
    work.finished(true, startedAt: third)
    #expect(!work.wanted)

    // A sweep that failed or couldn't ask leaves the request standing.
    work.askAgain()
    work.finished(false, startedAt: work.generation)
    #expect(work.wanted)
}

@Test func anOwnershipTokenNamesThePortAsWellAsTheTarget() {
    // A loopback address on its own is recycled, and a registration made on a
    // port the app is no longer configured for can't be found to give back.
    #expect(AppCoordinator.token(41443, "http://127.0.0.1:61949") == "41443 http://127.0.0.1:61949")
    #expect(AppCoordinator.pair("41443 http://127.0.0.1:61949").port == 41443)
    #expect(AppCoordinator.pair("41443 http://127.0.0.1:61949").target == "http://127.0.0.1:61949")
    // Written before the port was part of it: still recognised, on any port.
    #expect(AppCoordinator.pair("http://127.0.0.1:61949").port == nil)
    #expect(AppCoordinator.pair("http://127.0.0.1:61949").target == "http://127.0.0.1:61949")
    // Not a token at all.
    #expect(AppCoordinator.pair("").target == "")
    #expect(AppCoordinator.pair("notaport http://x").port == nil)
}

@Test func aHostThatIsNotAHostNameNeverReachesAURL() {
    // It goes into the manifest's asset URL and the install link, where `%`,
    // `\` and `@` all mean something.
    #expect(OTAServer.hostLike("mac.ts.net") == "mac.ts.net")
    #expect(OTAServer.hostLike("mac.ts.net:41443") == "mac.ts.net:41443")
    #expect(OTAServer.hostLike("MAC-1.ts.net:80") == "MAC-1.ts.net:80")
    #expect(OTAServer.hostLike("evil.example/../x") == nil)
    #expect(OTAServer.hostLike("user@evil.example") == nil)
    #expect(OTAServer.hostLike("mac.ts.net:notaport") == nil)
    #expect(OTAServer.hostLike("mac.ts.net:99999") == nil) // not a port
    #expect(OTAServer.hostLike("a%2f.ts.net") == nil)
    #expect(OTAServer.hostLike(":41443") == nil)
    #expect(OTAServer.hostLike(String(repeating: "a", count: 300)) == nil)
    // And the request parser is what applies it.
    #expect(OTAServer.request("GET / HTTP/1.1\r\nHost: user@evil.example\r\n").2 == nil)
}

@Test func aBuildWhoseMetadataCantBeReadIsNotABuildThatIsGone() throws {
    // The folder lists fine and only the metadata is unreadable: dropping it
    // silently serves "No builds yet" while the .ipa sits right there, and the
    // manifest URL a device already has answers 404.
    let root = otaScratch()
    let dir = root.appendingPathComponent("com.example.App/1.0-1-x")
    let meta = dir.appendingPathComponent("meta.json")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: meta.path)
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONEncoder().encode(build("1.0", "1", "1.0-1-x")).write(to: meta)
    #expect(OTA.builds(of: "com.example.App", in: root)?.count == 1)

    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: meta.path)
    try #require(!FileManager.default.isReadableFile(atPath: meta.path))
    #expect(OTA.builds(of: "com.example.App", in: root) == nil)
    #expect(OTA.builds(in: root) == nil)
    // Absent is still a build that was never finished, and still skipped.
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: meta.path)
    try FileManager.default.removeItem(at: meta)
    #expect(OTA.builds(of: "com.example.App", in: root)?.isEmpty == true)
}

@Test func aBuildFolderThatCantBeEnteredIsNotABuildThatIsGone() throws {
    // One level further in, where `fileExists` was being asked to tell absent
    // from unreadable — and it is false for both, which is why it was taken out
    // of `appDirectories` in the first place.
    let root = otaScratch()
    let dir = root.appendingPathComponent("com.example.App/1.0-1-x")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONEncoder()
        .encode(build("1.0", "1", "1.0-1-x"))
        .write(to: dir.appendingPathComponent("meta.json"))
    #expect(OTA.builds(of: "com.example.App", in: root)?.count == 1)

    // The app folder still lists; only this one can't be entered.
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
    try #require(!FileManager.default.isReadableFile(atPath: dir.appendingPathComponent("meta.json").path))
    #expect(OTA.appDirectories(in: root) == ["com.example.App"])
    #expect(OTA.builds(of: "com.example.App", in: root) == nil) // not `[]`, which serves "No builds yet"
    #expect(OTA.builds(in: root) == nil)
}

@Test func aPublishIsJudgedByTheConfigNotByTheExitCode() {
    // `tailscale serve --https` writes nothing and exits 0 when the tailnet has
    // no HTTPS certificates: it prints the admin link and calls os.Exit(0) before
    // touching any config. Reading that as success logged "serving builds over
    // the air" once a minute while nothing was served.
    let mine = "http://127.0.0.1:61816"
    let landed = TailscaleClient.serving(port: 41443, inJSON:
        #"{"Web":{"m:41443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:61816"}}}}}"#)
    #expect(landed.isRegistered(mine))
    // What that path actually leaves behind: no serve config at all.
    #expect(!TailscaleClient.serving(port: 41443, inJSON: "null").isRegistered(mine))
    #expect(TailscaleClient.serving(port: 41443, inJSON: "null") != .unknown) // so it is a failure, not a maybe
    // And a status we couldn't read is neither.
    #expect(!TailscaleClient.serving(port: 41443, inJSON: "not json").isRegistered(mine))
    #expect(TailscaleClient.serving(port: 41443, inJSON: "not json") == .unknown)
}

@Test func aPortThatCantWorkIsIgnoredRatherThanRetriedForEver() {
    #expect(AppCoordinator.otaPort(0) == 41443) // unset
    #expect(AppCoordinator.otaPort(41444) == 41443 + 1)
    #expect(AppCoordinator.otaPort(8443) == 41443) // Funnel could publish it
    #expect(AppCoordinator.otaPort(80) == 41443) // tailscaled is root and would take it
    #expect(AppCoordinator.otaPort(70000) == 41443) // `tailscale serve` refuses it
}

@Test func aFolderThatCantBeReadIsNotAnEmptyOne() throws {
    // Deleting ota/ is the off switch; failing to read it is not, and treating
    // the two alike takes the page down under a download.
    let root = scratchDir()
    let app = root.appendingPathComponent("com.example.App")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: app.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.path)
        try? FileManager.default.removeItem(at: root)
    }
    try #require(!FileManager.default.isReadableFile(atPath: app.path)) // not running as root
    #expect(OTA.appDirectories(in: root) == nil) // unreadable: ask again
    #expect(OTA.appDirectories(in: root.appendingPathComponent("absent")) == []) // gone: off
}

@Test func anExpiredProfileOrAnUnknownUdidIsRefusedBeforeTheDeviceSeesIt() throws {
    let udid = "00008130-000D00000000D004"
    let live: [String: Any] = ["ProvisionedDevices": [udid], "Entitlements": ["get-task-allow": false]]
    let mine = [OTA.Device(name: "iPhone", udid: udid)]
    #expect(throws: Never.self) { try OTA.check(live, against: mine) }
    // The expiry comes back so the page can mark a build that ran out since.
    var dated = live
    let when = Date(timeIntervalSinceNow: 86_400)
    dated["ExpirationDate"] = when
    #expect(try OTA.check(dated, against: mine).expires == when)
    // Expired: iOS would refuse it on the device with nothing to go on.
    var stale = live
    stale["ExpirationDate"] = Date(timeIntervalSinceNow: -86_400)
    #expect(throws: OTA.Problem.self) { try OTA.check(stale, against: mine) }
    // No UDID learned yet: the question can't be answered, so it comes back as
    // unanswered rather than as a refusal — the build may still be someone else's.
    #expect(try OTA.check(live, against: [OTA.Device(name: "iPhone", udid: nil)]).coverage
        == .noneOfYours(known: [], unchecked: ["iPhone"]))
    // Enterprise covers every device, so a missing UDID doesn't matter there.
    #expect(try OTA.check(["ProvisionsAllDevices": true], against: []).expires == nil)
}

@Test func aUdidTheCommandLineLearnedSurvivesTheAppSavingOverIt() {
    // The app can hold a profile it loaded before `roamrun up` learned the UDID.
    // Writing its own nil back leaves `roamrun ota` unable to say what a build
    // covers, on a device that has been bridged.
    let loaded = profile("iPhone") // what the app read: no UDID yet
    var onDisk = loaded
    onDisk.udid = "00008130-000D00000000D004" // what `roamrun up` wrote after that
    var renamed = loaded
    renamed.displayName = "iPhone mh" // the app changed something else
    #expect(ProfileStore.merge(base: [loaded], wanted: [renamed], disk: [onDisk]).first?.udid == onDisk.udid)
    // A UDID this process did change is this process's answer.
    var cleared = renamed
    cleared.udid = "OTHER"
    #expect(ProfileStore.merge(base: [loaded], wanted: [cleared], disk: [onDisk]).first?.udid == "OTHER")
    // A UDID that is known isn't given up for none on disk: its pairing is named by it, and
    // without it the device's control would go — and its switch with it.
    var forgotten = onDisk
    forgotten.udid = nil
    #expect(ProfileStore.merge(base: [onDisk], wanted: [onDisk], disk: [forgotten]).first?.udid == onDisk.udid)
}

@Test func aStoredBuildSurvivesThisStructGainingAField() throws {
    // What an older RoamRun wrote: no `slug`, no `devices`. Losing someone's
    // build because the schema moved is not an acceptable upgrade.
    let older = #"{"bundleID":"com.example.App","title":"App","version":"1.0","build":"7","added":760000000,"size":123}"#
    let build = try JSONDecoder().decode(OTA.Build.self, from: Data(older.utf8))
    #expect(build.bundleID == "com.example.App")
    #expect(build.label == "1.0 (7)")
    #expect(build.slug.isEmpty) // the directory it was found in replaces this
    // And the other way: nothing but the bundle id is actually required.
    #expect(throws: Never.self) {
        try JSONDecoder().decode(OTA.Build.self, from: Data(#"{"bundleID":"com.example.App"}"#.utf8))
    }
}

@Test func metadataThatCantBeReadIsNotTheSameAsMetadataThatIsntThere() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let app = dir.appendingPathComponent("com.example.App")
    let kept = app.appendingPathComponent("1.0-1-20260101-0000")
    try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
    // Present but not decodable: a later version may understand it, so it stays.
    try Data("{".utf8).write(to: kept.appendingPathComponent("meta.json"))
    // Absent: an add that died before writing it, and nothing else would ever
    // remove the .ipa beside it.
    let gone = app.appendingPathComponent("1.0-2-20260101-0000")
    try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
    try Data("ipa".utf8).write(to: gone.appendingPathComponent("app.ipa"))

    // Through the production path, not a helper written for the test.
    #expect(OTA.builds(of: "com.example.App", in: dir)?.isEmpty == true) // neither decodes
    // A read never deletes: it is answering a request from the tailnet, and a
    // build being written is exactly what it would take away.
    #expect(FileManager.default.fileExists(atPath: kept.path))
    #expect(FileManager.default.fileExists(atPath: gone.path))
    // A folder that isn't there at all is empty, not unreadable: deleting it is
    // the documented off switch.
    #expect(OTA.builds(of: "com.example.App", in: dir.appendingPathComponent("nope"))?.isEmpty == true)
    #expect(OTA.appDirectories(in: dir.appendingPathComponent("nope")) == [])
}

/// The write path had no tests at all, which is why every round of fixes here
/// arrived with a new fault. `in:` exists so these can run somewhere harmless.
private func otaScratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-ota-test-\(UUID().uuidString)")
}

private func fakeIPA(_ root: URL, _ bytes: String) throws -> String {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let at = root.appendingPathComponent("\(UUID().uuidString).ipa")
    try Data(bytes.utf8).write(to: at)
    return at.path
}

private func build(_ version: String, _ number: String, _ slug: String,
                   added: Date = .now, size: Int64 = 1) -> OTA.Build
{
    OTA.Build(bundleID: "com.example.App", title: "App", version: version, build: number,
              added: added, size: size, expires: nil, slug: slug)
}

/// `sameArchive` filters on size before it hashes, so a Build whose size doesn't
/// describe the file it names can never match one — which is what `OTA.read`
/// guarantees in production and a test has to do for itself.
private func sized(_ path: String, _ b: OTA.Build) -> OTA.Build {
    var b = b
    b.size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64) ?? 0
    return b
}

@Test func storingTheSameArchiveTwiceMovesItBackUpInsteadOfStacking() throws {
    let root = otaScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let ipa = try fakeIPA(root.appendingPathComponent("src"), "one")
    let first = try OTA.add(ipa: ipa, sized(ipa, build("1.0", "1", "1.0-1-a", added: .distantPast)), in: root)
    #expect(OTA.builds(of: "com.example.App", in: root)?.count == 1)
    // Byte for byte the same: the row it already has, re-dated, not a second one.
    let again = try OTA.add(ipa: ipa, sized(ipa, build("1.0", "1", "1.0-1-b")), in: root)
    #expect(again.dir == first.dir)
    #expect(OTA.builds(of: "com.example.App", in: root)?.count == 1)
    #expect((OTA.builds(of: "com.example.App", in: root)?.first?.added ?? .distantPast) > .distantPast)
    // The same size, different bytes: the digest is what decides, so it stacks.
    let other = try fakeIPA(root.appendingPathComponent("src"), "two")
    _ = try OTA.add(ipa: other, sized(other, build("1.0", "1", "1.0-1-c")), in: root)
    #expect(OTA.builds(of: "com.example.App", in: root)?.count == 2)
}

@Test func nothingIsKeptBeyondTheLimitEvenWhenTheNewBuildSortsLast() throws {
    let root = otaScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    // `added` is taken before the lock, so a build that waited its turn can sort
    // behind every other one. Dropping it from the tail used to leave six.
    for i in 0 ..< OTA.keepPerApp {
        _ = try OTA.add(ipa: try fakeIPA(root.appendingPathComponent("src"), "n\(i)"),
                        build("1.\(i)", "1", "1.\(i)-1-x", added: .now), in: root)
    }
    #expect(OTA.builds(of: "com.example.App", in: root)?.count == OTA.keepPerApp)
    let late = try OTA.add(ipa: try fakeIPA(root.appendingPathComponent("src"), "late"),
                           build("0.9", "1", "0.9-1-x", added: .distantPast), in: root)
    let after = OTA.builds(of: "com.example.App", in: root) ?? []
    #expect(after.count == OTA.keepPerApp)
    #expect(after.contains {
        $0.slug == late.dir.lastPathComponent
    }) // the one just asked for stays
}

@Test func aBuildThatWasNeverFinishedIsReapedByTheNextWriteNotByAReader() throws {
    let root = otaScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("com.example.App")
    let orphan = app.appendingPathComponent("1.0-1-dead")
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    try Data("ipa".utf8).write(to: orphan.appendingPathComponent("app.ipa"))
    let stale = app.appendingPathComponent(".adding-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -7200)],
                                          ofItemAtPath: stale.path)
    // A reader leaves both alone: it is answering a request from the tailnet.
    _ = OTA.builds(of: "com.example.App", in: root)
    #expect(FileManager.default.fileExists(atPath: orphan.path))
    // The next add holds the lock, so it is the one that can safely clear them.
    _ = try OTA.add(ipa: try fakeIPA(root.appendingPathComponent("src"), "x"),
                    build("1.0", "2", "1.0-2-x"), in: root)
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
    #expect(!FileManager.default.fileExists(atPath: stale.path))
}

@Test func theOneDeleteInHereIsNotDecidedByFileExists() throws {
    // `reapOrphans` removes a build folder with no `meta.json`. Asking
    // `fileExists` for that answers the same for a folder that can't be entered,
    // and this is the only place in the feature that deletes someone's build.
    let root = otaScratch()
    let app = root.appendingPathComponent("com.example.App")
    let shut = app.appendingPathComponent("1.0-9-locked")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shut.path)
        try? FileManager.default.removeItem(at: root)
    }
    // One that really has no metadata, and one that can't be looked into.
    let orphan = app.appendingPathComponent("1.0-8-orphan")
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    try Data("ipa".utf8).write(to: orphan.appendingPathComponent("app.ipa"))
    try FileManager.default.createDirectory(at: shut, withIntermediateDirectories: true)
    try JSONEncoder()
        .encode(build("1.0", "9", "1.0-9-locked"))
        .write(to: shut.appendingPathComponent("meta.json"))
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: shut.path)
    try #require(!FileManager.default.isReadableFile(atPath: shut.appendingPathComponent("meta.json").path))

    // `add` is what runs the reap, under the lock.
    _ = try? OTA.add(ipa: try fakeIPA(root.appendingPathComponent("src"), "x"),
                     build("2.0", "1", "2.0-1-x"), in: root)
    #expect(!FileManager.default.fileExists(atPath: orphan.path)) // never finished: reaped
    #expect(FileManager.default.fileExists(atPath: shut.path)) // unreadable: left alone
}

@Test func aFolderWithNoBuildsInItIsNotSomethingToPublish() throws {
    let root = otaScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("com.example.App")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    // What a failed first add leaves: the folder and the lock it took, nothing else.
    try Data().write(to: app.appendingPathComponent(".lock"))
    #expect(OTA.appDirectories(in: root) == []) // so the page isn't published for it
    try FileManager.default.createDirectory(at: app.appendingPathComponent("1.0-1-x"),
                                            withIntermediateDirectories: true)
    #expect(OTA.appDirectories(in: root) == ["com.example.App"])
}

@Test func aFolderThatCantBeOpenedIsNotAnEmptyOne() throws {
    let root = otaScratch()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }
    let app = root.appendingPathComponent("com.example.App")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("1.0-1-x"),
                                            withIntermediateDirectories: true)
    try JSONEncoder()
        .encode(build("1.0", "1", "1.0-1-x"))
        .write(to: app.appendingPathComponent("1.0-1-x/meta.json"))
    #expect(OTA.builds(in: root)?.count == 1)
    // `fileExists` is false both for a path that isn't there and for one whose
    // parent you can't get into, so it can't be what tells these apart.
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
    try #require(!FileManager.default.isReadableFile(atPath: root.path)) // not running as root
    #expect(OTA.appDirectories(in: root) == nil)
    #expect(OTA.builds(in: root) == nil) // the page answers 503, not "no builds yet"
}

@Test func anAppFolderThatCantBeOpenedIsNotAnAppThatIsGone() throws {
    // One level down, where `try?` used to turn "couldn't read it" back into
    // "there is no such app" — and an app vanishing from the list is how the
    // coordinator decides the off switch was pressed and takes the page down
    // under a download.
    let root = otaScratch()
    let app = root.appendingPathComponent("com.example.App")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: app.path)
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: app.appendingPathComponent("1.0-1-x"),
                                            withIntermediateDirectories: true)
    try JSONEncoder()
        .encode(build("1.0", "1", "1.0-1-x"))
        .write(to: app.appendingPathComponent("1.0-1-x/meta.json"))
    #expect(OTA.appDirectories(in: root) == ["com.example.App"])

    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: app.path)
    try #require(!FileManager.default.isReadableFile(atPath: app.path))
    #expect(OTA.appDirectories(in: root) == nil) // not `[]`, which reads as the off switch
    #expect(OTA.builds(in: root) == nil)
    #expect(OTA.builds(of: "com.example.App", in: root) == nil)
    // And `drop` says it couldn't look, rather than "there was nothing to remove".
    #expect(OTA.drop("com.example.App", labelled: "1.0 (1)", in: root) == nil)
}

@Test func replaceSaysSoWhenItCouldntReplace() throws {
    let root = otaScratch()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: root.appendingPathComponent("com.example.App").path)
        try? FileManager.default.removeItem(at: root)
    }
    let app = root.appendingPathComponent("com.example.App")
    let old = app.appendingPathComponent("1.0-1-old")
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    try JSONEncoder().encode(build("1.0", "1", "1.0-1-old")).write(to: old.appendingPathComponent("meta.json"))
    // A folder the old build can't be removed from: --replace didn't replace, and
    // reporting success would leave it on the page under the same version.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: app.path)
    try #require(!FileManager.default.isWritableFile(atPath: app.path))
    #expect(OTA.drop("com.example.App", labelled: "1.0 (1)", keeping: nil, in: root) == 1)
}

@Test func replaceDropsTheOtherBuildsOfThatVersionAndNothingElse() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let app = dir.appendingPathComponent("com.example.App")
    func store(_ version: String, _ number: String, _ slug: String, added: Date) throws {
        let at = app.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
        let build = OTA.Build(bundleID: "com.example.App", title: "App", version: version, build: number,
                              added: added, size: 1, expires: nil, slug: slug)
        try JSONEncoder().encode(build).write(to: at.appendingPathComponent("meta.json"))
    }
    try store("1.0", "1", "1.0-1-a", added: .now.addingTimeInterval(-60))
    try store("1.0", "1", "1.0-1-b", added: .now.addingTimeInterval(-30))
    try store("1.1", "1", "1.1-1-a", added: .now)
    #expect(OTA.builds(of: "com.example.App", in: dir)?.count == 3)
    // What --replace does: everything under that one label except the new build.
    #expect(OTA.drop("com.example.App", labelled: "1.0 (1)", keeping: "1.0-1-b", in: dir) == 0)
    #expect(OTA.builds(of: "com.example.App", in: dir)?.map(\.slug).sorted() == ["1.0-1-b", "1.1-1-a"])
}

@Test func aServeEntryOnlyCountsWhenSomethingIsBehindIt() async throws {
    // A crash leaves the serve entry pointing at a port nothing holds any more,
    // and `serve status` alone can't tell that from a working page.
    let server = try EchoServer()
    let port = await server.start()
    #expect(port > 0)
    #expect(TailscaleClient.listening(on: port))
    server.stop()
    #expect(try await eventually {
        !TailscaleClient.listening(on: port)
    })
}

@Test func aBuildWhoseProfileRanOutWhileItSatThereSaysSo() {
    // The check happens when it's stored; a profile lasts a year and builds are
    // kept for months, so the page is the only place left to say it.
    func page(_ expires: Date?) -> String {
        let build = OTA.Build(bundleID: "com.example.App", title: "App", version: "1.0", build: "1",
                              added: .now, size: 1, expires: expires, slug: "1.0-1-x")
        return OTA.indexHTML([(bundleID: "com.example.App", builds: [build])], base: "https://x/p", in: absentOTA)
    }
    #expect(page(.now.addingTimeInterval(-86_400)).contains("EXPIRED"))
    #expect(!page(.now.addingTimeInterval(86_400)).contains("EXPIRED"))
    #expect(!page(nil).contains("EXPIRED")) // Enterprise profiles carry no date we act on
}

@Test func aPortOutsideFunnelsThreeCanNeverReachTheInternet() {
    // Funnel only publishes 443, 8443 and 10000, so a port outside them can't be
    // put on the internet by anyone — which is why RoamRun uses one.
    #expect(!AppCoordinator.funnelCapable.contains(AppCoordinator.otaPort))
    #expect(AppCoordinator.funnelCapable == [443, 8443, 10000])
}

@Test func aSlugNeverStartsWithADotOrTheBuildDisappears() {
    let when = Date(timeIntervalSince1970: 1_790_000_000)
    // `builds(of:)` skips dot-directories to keep a running add safe, so a
    // version like `.5` would store a build nothing could ever see again.
    for version in [".5", "..", ".", "-1"] {
        #expect(!OTA.Build.slug(version: version, build: "1", at: when).hasPrefix("."))
    }
    #expect(OTA.Build.slug(version: "1.0", build: "1", at: when).hasPrefix("1.0-"))
}

@Test func everyAddressRoamRunRegisteredStaysRecognisable() {
    // A registration that failed must leave the one before it still ours —
    // otherwise one bad command turns into a page that never comes back.
    var seen = AppCoordinator.remembering([], "port1")
    seen = AppCoordinator.remembering(seen, "port2")
    #expect(seen == ["port1", "port2"])
    // Asking again for one already there moves it to the end, it doesn't repeat.
    #expect(AppCoordinator.remembering(seen, "port1") == ["port2", "port1"])
    // Bounded, newest kept.
    var many: [String] = []
    for port in 1 ... 9 {
        many = AppCoordinator.remembering(many, "port\(port)", keep: 5)
    }
    #expect(many == ["port5", "port6", "port7", "port8", "port9"])
}

/// For page tests: icons are looked up here, so they never touch the real ota/ folder.
private let absentOTA = FileManager.default
    .temporaryDirectory
    .appendingPathComponent("roamrun-absent-\(UUID().uuidString)")

@Test func theInstallPageKnowsOnlyItsTailnetName() {
    #expect(OTAServer.isServedName("mac.tail1.ts.net:41443", servedName: "mac.tail1.ts.net"))
    #expect(OTAServer.isServedName("Mac.Tail1.ts.net.", servedName: "mac.tail1.ts.net"))
    #expect(!OTAServer.isServedName("attacker.example:41443", servedName: "mac.tail1.ts.net"))
    #expect(!OTAServer.isServedName("mac.tail1.ts.net.attacker.example", servedName: "mac.tail1.ts.net"))
    #expect(!OTAServer.isServedName("mac.tail1.ts.net", servedName: nil))
}

@Test func leftoverUnpackedArchivesAreSweptButFreshOnesStay() throws {
    let tmp = scratchDir()
    defer { try? FileManager.default.removeItem(at: tmp) }
    let fm = FileManager.default
    for name in ["roamrun-ipa-old", "roamrun-install-old", "roamrun-ipa-fresh", "someone-elses",
                 "roamrun-ipa-4242-X", "roamrun-ipa-4343-X", "roamrun-ipa-4444-X"]
    {
        try fm.createDirectory(at: tmp.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let longAgo = Date.now.addingTimeInterval(-7200)
    try fm.setAttributes([.creationDate: longAgo], ofItemAtPath: tmp.appendingPathComponent("roamrun-ipa-old").path)
    try fm.setAttributes([.creationDate: longAgo], ofItemAtPath: tmp.appendingPathComponent("someone-elses").path)
    try fm.setAttributes([.creationDate: longAgo], ofItemAtPath: tmp.appendingPathComponent("roamrun-install-old").path)
    for n in ["roamrun-ipa-4242-X", "roamrun-ipa-4343-X", "roamrun-ipa-4444-X"] {
        try fm.setAttributes([.creationDate: longAgo], ofItemAtPath: tmp.appendingPathComponent(n).path)
    }
    let before = longAgo.timeIntervalSince1970 - 5, after = Date.now.timeIntervalSince1970 - 60
    CLI.sweepStaleUnpacks(in: tmp, started: {
        [4242: before, 4444: after][$0]
    })
    #expect(fm.fileExists(atPath: tmp.appendingPathComponent("roamrun-ipa-4242-X").path)) // an install still running
    #expect(!fm.fileExists(atPath: tmp.appendingPathComponent("roamrun-ipa-4343-X").path)) // its process is gone
    #expect(!fm
        .fileExists(atPath: tmp.appendingPathComponent("roamrun-ipa-4444-X").path)) // its pid is another process's now
    #expect(!fm.fileExists(atPath: tmp.appendingPathComponent("roamrun-ipa-old").path))
    #expect(!fm
        .fileExists(atPath: tmp.appendingPathComponent("roamrun-install-old").path)) // the signing check's unpacking
    #expect(fm.fileExists(atPath: tmp.appendingPathComponent("roamrun-ipa-fresh").path)) // maybe an install running now
    #expect(fm.fileExists(atPath: tmp.appendingPathComponent("someone-elses").path))
}

@Test func aTLSTerminatingForwardIsAPortInUse() {
    // ipn.TCPPortHandler's key is TerminateTLS.
    let json = #"{"TCP":{"41443":{"TerminateTLS":"mac.tail1.ts.net"}}}"#
    #expect(TailscaleClient.serving(port: 41443, inJSON: json).alongside("mac.tail1.ts.net") == ["TCP forwarding"])
}

@Test func aControlCharacterInTheBuildNumberStillMakesAManifest() throws {
    let build = OTA.Build(bundleID: "com.example.App", title: "App", version: "1.0", build: "7\u{1}", added: .now,
                          size: 1, slug: "1.0-7-20260101-000000")
    let data = try #require(OTA.manifest(for: build, base: "https://mac.tail1.ts.net:41443"))
    let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let item = try #require((plist["items"] as? [[String: Any]])?.first)
    #expect((item["metadata"] as? [String: Any])?["bundle-version"] as? String == "7")
}

@Test func aStrayFileInTheBuildsFolderDoesntTakeThePageDown() throws {
    let root = scratchDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let slug = "1.0-1-20260101-000000"
    let build = OTA.Build(
        bundleID: "com.example.App",
        title: "App",
        version: "1.0",
        build: "1",
        added: .now,
        size: 1,
        slug: slug
    )
    let dir = root.appendingPathComponent("com.example.App").appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONEncoder().encode(build).write(to: dir.appendingPathComponent("meta.json"))
    // Notes dropped next to the app folders and next to the builds.
    try Data("hi".utf8).write(to: root.appendingPathComponent("notes.txt"))
    try Data("hi".utf8).write(to: root.appendingPathComponent("com.example.App").appendingPathComponent("old.ipa"))
    #expect(OTA.appDirectories(in: root) == ["com.example.App"])
    #expect(OTA.builds(in: root)?.first?.builds.map(\.slug) == [slug])
}

/// `tailscale serve` and the record of what this Mac registered, faked. Calls are counted
/// so a test sees what would have been run.
private final class FakeServe: @unchecked Sendable {
    var states: [Int: TailscaleClient.Serving] = [:] // missing: .nothing
    var host: String? = "mac.ts.net"
    var offWorks = true
    /// What the port carries after an `off` that exited 0 (nil: nothing).
    var afterOff: TailscaleClient.Serving?
    var record: [String]
    var offs: [Int] = []
    var serves: [Int] = []
    var otaPort = 41443
    init(record: [String] = []) {
        self.record = record
    }

    var tools: AppCoordinator.ServeTools {
        var t = AppCoordinator.ServeTools()
        t.serving = { port, _ in
            self.states[port] ?? .nothing
        }
        t.host = { _ in
            self.host
        }
        t.off = { port, _ in
            self.offs.append(port)
            if self.offWorks {
                self.states[port] = self.afterOff
            }
            return self.offWorks
        }
        t.serve = { port, target in
            self.serves.append(port); self.states[port] = mounted(port, target); return ""
        }
        t.remember = { target, port in
            self.record.append("\(port) \(target)")
        }
        t.remembered = {
            self.record
        }
        t.forget = { target, port in
            self.record
                .removeAll {
                    let p = AppCoordinator.pair($0); return p.target == target && (p.port == nil || p.port == port)
                }
        }
        t.otaPort = {
            self.otaPort
        }
        return t
    }
}

/// A mount at `/` on `port` under mac.ts.net, proxying to `target`.
private func mounted(_ port: Int, _ target: String) -> TailscaleClient.Serving {
    TailscaleClient.serving(
        port: port,
        inJSON: #"{"Web":{"mac.ts.net:\#(port)":{"Handlers":{"/":{"Proxy":"\#(target)"}}}}}"#
    )
}

enum ReleaseCase: String, CaseIterable {
    case unreadable, alreadyGone, oursOffWorks, oursOffFails, someoneElses, oursUnderAnOldName, noHostName
    case offSaysYesButStays, offThenUnreadable, offThenSomeoneElses
}

/// Giving one registration back: only what is provably ours is removed, and it is
/// forgotten only once it is gone.
@Test(arguments: ReleaseCase.allCases)
func releaseServeOutcomes(_ c: ReleaseCase) {
    let mine = "http://127.0.0.1:61816"
    let fake = FakeServe(record: ["41443 \(mine)"])
    switch c {
    case .unreadable: fake.states[41443] = .unknown
    case .alreadyGone: break
    case .oursOffWorks: fake.states[41443] = mounted(41443, mine)
    case .oursOffFails: fake.states[41443] = mounted(41443, mine); fake.offWorks = false
    case .someoneElses: fake.states[41443] = mounted(41443, "http://127.0.0.1:8788")
    case .oursUnderAnOldName: // the node was renamed: `off` would hit whatever took its place
        fake.states[41443] = TailscaleClient.serving(port: 41443,
                                                     inJSON: #"{"Web":{"old.ts.net:41443":{"Handlers":{"/":{"Proxy":"\#(mine)"}}}}}"#)
    case .noHostName: fake.states[41443] = mounted(41443, mine); fake.host = nil
    case .offSaysYesButStays: fake.states[41443] = mounted(41443, mine); fake.afterOff = mounted(41443, mine)
    case .offThenUnreadable: fake.states[41443] = mounted(41443, mine); fake.afterOff = .unknown
    case .offThenSomeoneElses: // ours went, and something else took `/` straight after
        fake.states[41443] = mounted(41443, mine); fake.afterOff = mounted(41443, "http://127.0.0.1:8788")
    }
    let gone = AppCoordinator.releaseServe((port: 41443, target: mine), tools: fake.tools)
    let (expectGone, expectOff, expectForgotten): (Bool, Bool, Bool) = switch c {
    case .unreadable: (false, false, false) // couldn't look: claiming it's gone is how one survives
    case .alreadyGone: (true, false, true)
    case .oursOffWorks: (true, true, true)
    case .oursOffFails: (false, true, false) // still there: remembered, so the next run knows it
    case .someoneElses, .oursUnderAnOldName: (true, false, true) // not ours to remove; ours is gone
    case .noHostName: (false, false, false)
    case .offSaysYesButStays, .offThenUnreadable: (false, true, false) // not seen gone: kept for the next sweep
    case .offThenSomeoneElses: (true, true, true)
    }
    #expect(gone == expectGone, "\(c)")
    #expect(fake.offs == (expectOff ? [41443] : []), "\(c)")
    #expect(fake.record.isEmpty == expectForgotten, "\(c)")
}

/// Leftovers are looked for on every port the record names and the one configured now;
/// only our own mount is removed, never the one this run serves from or the user's.
@Test func reclaimStraysRemovesOnlyOurLeftovers() {
    let old = "http://127.0.0.1:50001", live = "http://127.0.0.1:50002", older = "http://127.0.0.1:50003"
    let fake = FakeServe(record: ["41444 \(old)", "41446 \(older)", "41443 \(live)"])
    fake.states[41444] = mounted(41444, old) // a killed run's, after otaPort changed
    fake.states[41443] = mounted(41443, live) // this run's
    fake.states[41446] = mounted(41446, "http://127.0.0.1:8788") // ours was replaced by the user's
    fake.otaPort = 41443
    #expect(AppCoordinator.reclaimStrays(keeping: (port: 41443, target: live), tools: fake.tools) == true)
    #expect(fake.offs == [41444]) // never the live one, never the user's
    #expect(fake.record == ["41446 \(older)", "41443 \(live)"])

    // One port it couldn't read: not "done", so the sweep runs again later.
    let unsure = FakeServe(record: ["41444 \(old)"])
    unsure.states[41444] = .unknown
    #expect(AppCoordinator.reclaimStrays(keeping: nil, tools: unsure.tools) == nil)
    // No name for this node: nothing can be judged.
    let nameless = FakeServe(record: ["41444 \(old)"])
    nameless.host = nil
    #expect(AppCoordinator.reclaimStrays(keeping: nil, tools: nameless.tools) == nil)
    #expect(nameless.offs.isEmpty)
}

extension TimingSensitive.OTAServerOverASocket {
    /// The page, its manifest and the .ipa, end to end from a folder of builds.
    @Test func aStoredBuildIsServedPageManifestAndIPA() async throws {
        let root = otaScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("com.example.App/1.0-1-x")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ipa = Data("IPA-BYTES-\(UUID().uuidString)".utf8)
        try ipa.write(to: dir.appendingPathComponent("app.ipa"))
        try JSONEncoder()
            .encode(build("1.0", "1", "1.0-1-x", size: Int64(ipa.count)))
            .write(to: dir.appendingPathComponent("meta.json"))

        let server = OTAServer(tailnetPort: 41443, root: root)
        server.servedName = "m"
        let port = try #require(server.start())
        defer { server.stop() }
        let page = await ask(port, "GET / HTTP/1.1\r\nHost: m:41443\r\n\r\n")
        #expect(page?.hasPrefix("HTTP/1.1 200") == true)
        #expect(page?.contains("com.example.App/1.0-1-x/manifest.plist") == true)
        let manifest = await ask(port, "GET /com.example.App/1.0-1-x/manifest.plist HTTP/1.1\r\nHost: m:41443\r\n\r\n")
        #expect(manifest?.hasPrefix("HTTP/1.1 200") == true)
        #expect(manifest?.contains("https://m:41443/com.example.App/1.0-1-x/app.ipa") == true)
        let body = await ask(port, "GET /com.example.App/1.0-1-x/app.ipa HTTP/1.1\r\nHost: m:41443\r\n\r\n")
        #expect(body?.hasPrefix("HTTP/1.1 200") == true)
        #expect(body?.hasSuffix(String(decoding: ipa, as: UTF8.self)) == true)
        #expect(await ask(port, "GET /com.example.App/9.9-9-x/app.ipa HTTP/1.1\r\nHost: m:41443\r\n\r\n")?
            .hasPrefix("HTTP/1.1 404") == true)
    }
}

/// Any `ota` clears another app's leftover staging an hour old, unless that app's add is
/// running (its lock is held); a fresh one stays (F44).
@Test func anOtaClearsOtherAppsLeftoversButNotARunningAdd() throws {
    let store = otaScratch()
    defer { try? FileManager.default.removeItem(at: store) }
    let fm = FileManager.default, old = Date(timeIntervalSinceNow: -7200)
    func app(_ name: String, staging: [(String, Date)]) throws -> URL {
        let a = store.appendingPathComponent(name)
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        fm.createFile(atPath: a.appendingPathComponent(".lock").path, contents: nil)
        for (n, made) in staging {
            let d = a.appendingPathComponent(n)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try fm.setAttributes([.creationDate: made], ofItemAtPath: d.path)
        }
        return a
    }
    let mine = try app("com.example.Mine", staging: [])
    let idle = try app("com.example.Idle", staging: [(".adding-old", old), (".adding-new", .now)])
    let busy = try app("com.example.Busy", staging: [(".adding-old", old)])
    let held = open(busy.appendingPathComponent(".lock").path, O_RDWR)
    defer { close(held) }
    #expect(flock(held, LOCK_EX) == 0) // an add running there
    OTA.sweepOthersStaging(in: store, besides: mine)
    #expect(!fm.fileExists(atPath: idle.appendingPathComponent(".adding-old").path))
    #expect(fm.fileExists(atPath: idle.appendingPathComponent(".adding-new").path))
    #expect(fm.fileExists(atPath: busy.appendingPathComponent(".adding-old").path))
}

/// The download floor: a peer far below it goes after five minutes, a slow but real
/// download doesn't, and nothing goes before five minutes whatever the rate.
@Test func otaDownloadFloor() {
    #expect(!OTAServer.tooSlow(sent: 0, after: 299))
    #expect(OTAServer.tooSlow(sent: 100_000, after: 300)) // ~330 B/s
    #expect(!OTAServer.tooSlow(sent: 300 * 8 * 1024, after: 300)) // right at 8 KB/s
    #expect(!OTAServer.tooSlow(sent: 50_000_000, after: 3600)) // ~14 KB/s for an hour
}

/// The write between two looks at whether OTA is still on: turned off before it, nothing
/// is written; turned off while `serve` ran, what it wrote is given back and forgotten.
enum PublishCase: String, CaseIterable { case portChanged, offBefore, offDuring, stillOn }

@Test(arguments: PublishCase.allCases)
func publishStepsAsideWhenTurnedOff(_ c: PublishCase) async {
    final class Answers: @unchecked Sendable { var left: [Bool]; init(_ a: [Bool]) {
        left = a
    } }
    let mine = "http://127.0.0.1:61816"
    let fake = FakeServe()
    let answers = Answers(c == .offBefore ? [false] : c == .offDuring ? [true, false] : [true, true])
    let checked: TailscaleClient.Serving = c == .portChanged ? mounted(41443, "http://127.0.0.1:8788") : .nothing
    let step = await AppCoordinator.publish(mine, on: 41443, expecting: checked, tools: fake.tools) {
        answers.left.removeFirst()
    }
    switch c {
    case .portChanged, .offBefore:
        #expect(step == (c == .portChanged ? .changed : .notWanted))
        #expect(fake.serves.isEmpty && fake.record.isEmpty)
    case .offDuring:
        #expect(step == .withdrawn)
        #expect(fake.serves == [41443] && fake.offs == [41443] && fake.record.isEmpty)
        #expect(fake.states[41443] == nil)
    case .stillOn:
        #expect(step == .ran(after: mounted(41443, mine), said: ""))
        #expect(fake.offs.isEmpty && fake.record == ["41443 \(mine)"])
    }
}
