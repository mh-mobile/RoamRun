import Foundation
import Testing
@testable import RoamRun

/// The two lines one Mac hands another: each read back as written, neither taken for the
/// other, and nothing in them that isn't plainly a value of its kind.
@Test func introductionLinesAreReadOnlyAsWhatTheyAre() {
    let txt = ["identifier": "6BF40D22-D414-41D0-BE80-7567AE75B2BC", "authTag": "BsVby0td", "model": "VirtualMac2,1",
               "name": "Managed’s Virtual Machine", "flags": "1", "ver": "26", "minVer": "17"]
    let offer = Introduction.Offer(port: 53050, txt: txt)
    let line = Introduction.line(offer)
    #expect(line.hasPrefix("rr-xcode-offer-v1:") && !line.contains(" ") && !line.contains("=") && !line.dropFirst(3)
        .contains("+"))
    #expect(try! Introduction.offer(from: "  \(line)\n").get() == offer)

    var mine = txt
    mine["model"] = nil; mine["name"] = nil
    let device = Introduction.Device(name: "iPhone", peer: "iphone-15-pro", port: 49152, txt: mine)
    #expect(try! Introduction.device(from: Introduction.line(device)).get() == device)

    // Each says so when handed the other, and neither reads a path or half a line.
    func refused<T>(_ r: Result<T, Introduction.Unreadable>) -> Introduction
        .Unreadable?
    {
        if case .failure(let e) = r {
            return e
        }; return nil
    }
    if case .another = refused(Introduction.offer(from: Introduction.line(device))) {}
    else {
        Issue.record("a device read as an offer")
    }
    if case .another = refused(Introduction.device(from: line)) {} else {
        Issue.record("an offer read as a device")
    }
    #expect(refused(Introduction.offer(from: "/tmp/k.json")) == .notOne &&
        refused(Introduction.offer(from: String(line.dropLast(9)))) == .notOne)
    #expect(refused(Introduction.offer(from: "rr-xcode-offer-v1:" + String(repeating: "A", count: 5000))) == .notOne)

    func offerProblem(_ change: (inout Introduction.Offer) -> Void) -> Bool {
        var o = offer; change(&o)
        if case .refused = refused(Introduction.offer(from: Introduction.line(o))) {
            return true
        }
        return false
    }
    #expect(offerProblem {
        $0.port = 22
    } && offerProblem {
        $0.port = 1023
    } && !offerProblem {
        $0.port = 1024
    })
    #expect(offerProblem {
        $0.txt["model"] = nil
    } && offerProblem {
        $0.txt["extra"] = "1"
    })
    #expect(offerProblem {
        $0.txt["identifier"] = "not-a-uuid"
    } && offerProblem {
        $0.txt["authTag"] = "a b"
    } &&
        offerProblem {
            $0.txt["authTag"] = ""
        })
    #expect(offerProblem {
        $0.txt["ver"] = "26; rm"
    } && offerProblem {
        $0.txt["flags"] = ""
    } &&
        offerProblem {
            $0.txt["model"] = "Mac 1"
        })
    // The name is shown on the device: nothing that hides, reorders or breaks what is read.
    for bad in [
        "a\u{202E}b",
        "a\u{200B}b",
        "a\nb",
        "a\u{1B}[31mb",
        "a=b",
        "a\\b",
        "",
        String(repeating: "x", count: 64)
    ] {
        #expect(offerProblem {
            $0.txt["name"] = bad
        }, "\(bad.unicodeScalars.map { String($0.value, radix: 16) })")
    }
    #expect(!offerProblem {
        $0.txt["name"] = "開発サーバー 2"
    })

    func deviceProblem(_ change: (inout Introduction.Device) -> Void) -> Bool {
        var d = device; change(&d)
        if case .refused = refused(Introduction.device(from: Introduction.line(d))) {
            return true
        }
        return false
    }
    #expect(deviceProblem {
        $0.txt["model"] = "iPhone16,1"
    } && deviceProblem {
        $0.port = 80
    })
    #expect(deviceProblem {
        $0.name = "-rf"
    } && deviceProblem {
        $0.name = "a\u{202E}b"
    } &&
        deviceProblem {
            $0.name = " "
        })
    #expect(deviceProblem {
        $0.peer = "a b"
    } && deviceProblem {
        $0.peer = ""
    } && deviceProblem {
        $0.peer = "-x"
    } &&
        deviceProblem {
            $0.peer = "100.64.0.2/../x"
        })
    #expect(!deviceProblem {
        $0.peer = "iPhone-15-Pro.tail1.ts.net"
    })
}

/// What the browse prints of a TXT record, read back as it was announced: a name with spaces,
/// a quote, a backslash and bytes above ASCII.
@Test func quotedTXTStringsAreReadAsTheyWereAnnounced() {
    let line = #"rrtest._rrtest._tcp   TXT   "identifier=70876C3E-BC8A-4FE9-BA12-FA8D0D6448A4" "authTag=Rb+z3/eI" "name=Managed’s Virtual \"Mac\" 開発" "flags=1""#
    #expect(BonjourCapture.quoted(in: line) == [
        "identifier=70876C3E-BC8A-4FE9-BA12-FA8D0D6448A4",
        "authTag=Rb+z3/eI",
        "name=Managed’s Virtual \"Mac\" 開発",
        "flags=1"
    ])
    #expect(BonjourCapture.quoted(in: #"x TXT "a=b\\c" "d=\065\032e" "open"#) == ["a=b\\c", "d=A e"])
    #expect(BonjourCapture.quoted(in: "no strings here").isEmpty)
}

/// Which announcements are this Mac's own offer, whose connections a stand-in takes, and a
/// saved device there and back without its UDID or where it is.
@Test func introductionChoicesAreMadeFromWhatThisMacKnows() {
    func service(_ instance: String, type: String = Introduction.hostService, ips: [String]) -> CapturedService {
        CapturedService(
            instanceName: instance,
            serviceType: type,
            domain: "local",
            port: 53050,
            host: "h.local",
            hostIPs: ips,
            txt: [:],
            lastSeen: .now
        )
    }
    // One whose host is elsewhere isn't this Mac's; one whose host has no address in the browse
    // (as Xcode's has none) may be, and is left for the port to decide.
    let seen = [service("B", ips: ["192.168.0.15", "fe80::1"]), service("A", ips: ["192.168.0.77"]),
                service("C", type: "_remotepairing._tcp", ips: ["192.168.0.15"]), service("D", ips: [])]
    #expect(Introduction.ownOffers(among: seen, ownIPs: ["192.168.0.15", "100.64.0.1"]).map(\.instanceName) == [
        "B",
        "D"
    ])
    #expect(Introduction.ownOffers(among: seen, ownIPs: []).map(\.instanceName) == ["D"])

    let lan = Relay.Accept.subnet(mask: "255.255.255.0")
    func accept(_ endpoint: String) -> Relay.Accept {
        Introduction.accept(
            deviceEndpoint: endpoint,
            local: "192.168.0.15",
            mask: "255.255.255.0"
        )
    }
    #expect(accept("192.168.0.19:41641") == .only("192.168.0.19"))
    // Relayed, on another network, this Mac's own address, IPv6 or unreadable: the LAN, not one host.
    for unknown in ["", "203.0.113.5:41641", "192.168.0.15:41641", "[fd7a::1]:41641", "192.168.0.19", "nonsense:1"] {
        #expect(accept(unknown) == lan, "\(unknown)")
    }

    // What the device shows is the name Tailscale has for the Mac, not the one in its offer;
    // a name that couldn't be shown as it is leaves the offer's.
    let offered = Introduction.Offer(port: 53050, txt: ["name": "macbook", "identifier": "x"])
    #expect(Introduction.announced(offered, as: "cloud-mac").txt == ["name": "cloud-mac", "identifier": "x"])
    #expect(Introduction.announced(offered, as: "").txt["name"] == "macbook" && Introduction.announced(
        offered,
        as: "a\u{202E}b"
    )
    .txt["name"] == "macbook")
    #expect(Introduction.announced(offered, as: String(repeating: "n", count: 80)).txt["name"]?.count == 63)

    var saved = inertProfile("iPhone")
    saved.txt = [
        "identifier": "6BF40D22-D414-41D0-BE80-7567AE75B2BC",
        "authTag": "66cI3FaC",
        "flags": "0",
        "ver": "26",
        "minVer": "8"
    ]
    saved.providerHostName = "iphone-15-pro"; saved.udid = "00008130-000D00000000D004"
    guard let device = Introduction.device(of: saved) else { Issue.record("a whole device not handed over"); return }
    #expect(device.name == "iPhone" && device.peer == "iphone-15-pro" && device.port == saved.remotePairingPort)
    #expect(!Introduction.line(device).contains("00008130") && Introduction.line(device).hasPrefix("rr-device-v1:"))
    var half = saved; half.txt["authTag"] = nil
    var unnamed = saved; unnamed.providerHostName = ""
    #expect(Introduction.device(of: half) == nil && Introduction.device(of: unnamed) == nil)
    // Saved by its address: what stands where its Tailscale name would is that address, and no Mac knows a device by it.
    var byAddress = saved; byAddress.providerID = MeshProvider.manual.rawValue; byAddress.providerHostName = saved
        .providerIP
    #expect(Introduction.device(of: byAddress) == nil)

    // A device nothing has talked to has no address in Tailscale's list; a ping's answer stands in for it.
    #expect(Introduction.accept(
        deviceEndpoint: Introduction.endpoint(pinged: "192.168.0.19"),
        local: "192.168.0.15",
        mask: "255.255.255.0"
    ) == .only("192.168.0.19"))
    #expect(Introduction.endpoint(pinged: nil) == "" && Introduction.endpoint(pinged: "") == "")
    let six = Introduction.endpoint(pinged: "2400:1:2::19")
    #expect(six.hasPrefix("[") && Introduction.accept(
        deviceEndpoint: six,
        local: "192.168.0.15",
        mask: "255.255.255.0"
    ) != .only("2400:1:2::19"))
    if case .only = Introduction
        .accept(deviceEndpoint: six, local: "192.168.0.15", mask: "255.255.255.0")
    {
        Issue.record("an IPv6 path was taken for an address on the LAN")
    }

    let peer = MeshDevice(id: "n1", name: "phone-here", os: "iOS", ips: ["fd7a::9", "100.64.0.9"], online: true)
    let made = Introduction.profile(from: device, peer: peer, name: "Test iPhone")
    #expect(made?.providerIP == "100.64.0.9" && made?.providerHostName == "phone-here" && made?.udid == nil)
    #expect(made?.instanceName == saved.txt["identifier"] && made?.serviceType == "_remotepairing._tcp" && made?
        .displayName == "Test iPhone")
    #expect(Introduction.profile(
        from: device,
        peer: MeshDevice(id: "n2", name: "v6", os: "iOS", ips: ["fd7a::9"], online: true),
        name: "x"
    ) == nil)
    // Paired again, nothing moved: what is saved says it all already — under any name, with a UDID or without.
    guard var kept = made else { return }
    kept.displayName = "Another name"; kept.udid = "00008130-000D00000000D004"
    #expect(Introduction.unchanged(kept, by: device, as: kept))
    var elsewhere = kept; elsewhere.providerIP = "100.64.0.10"
    #expect(!Introduction.unchanged(kept, by: device, as: elsewhere))
    var renamed = kept; renamed
        .providerHostName = "phone-renamed" // its Tailscale name changed: export would hand on the old one
    #expect(!Introduction.unchanged(kept, by: device, as: renamed))
    var moved = device; moved.port += 1
    #expect(!Introduction.unchanged(kept, by: moved, as: kept))
    // Announced anew, under another name with its own tag: not unchanged, and nothing else moved.
    var anew = device; anew.txt["identifier"] = "0A0A0A0A-D414-41D0-BE80-7567AE75B2BC"; anew.txt["authTag"] = "other"
    #expect(!Introduction.unchanged(kept, by: anew, as: kept) && Introduction.announcedAnew(kept, by: anew, as: kept))
    #expect(!Introduction.announcedAnew(kept, by: anew, as: elsewhere) && !Introduction.announcedAnew(
        kept,
        by: anew,
        as: renamed
    ))
    moved = anew; moved.txt["ver"] = "99"
    #expect(!Introduction.unchanged(kept, by: moved, as: kept) && !Introduction.announcedAnew(
        kept,
        by: moved,
        as: kept
    ))
    #expect(!Introduction.unchanged(half, by: device, as: half))

    // Added under the store's lock: the same device from two commands at once is there once.
    guard let new = made else { return }
    var list: [DeviceProfile] = []
    #expect(Introduction.add(new, from: device, to: &list) == .added)
    var again = new; again.id = UUID()
    #expect(Introduction.add(again, from: device, to: &list) == .unchanged("Test iPhone"))
    #expect(Introduction.add(again, from: moved, to: &list) == .already("Test iPhone"))
    #expect(list.count == 1 && list[0].instanceName == new.instanceName)
    // Announced anew where it was: the one saved takes the newest announcement, and keeps its id, name and UDID.
    list[0].udid = "00008130-000D00000000D004"
    guard var renewed = Introduction.profile(from: anew, peer: peer, name: "Whatever") else { return }
    renewed.id = UUID()
    #expect(Introduction.add(renewed, from: anew, to: &list) == .renewed("Test iPhone"))
    #expect(list.count == 1 && list[0].id == new.id && list[0].udid != nil)
    #expect(list[0].instanceName == "0A0A0A0A-D414-41D0-BE80-7567AE75B2BC" && list[0].txt["authTag"] == "other")
    #expect(Introduction.add(renewed, from: anew, to: &list) == .unchanged("Test iPhone"))
    // Not for a line turned to another device than it names, nor where two saved ones match it: refused as before.
    var again2 = anew; again2.txt["identifier"] = "0B0B0B0B-D414-41D0-BE80-7567AE75B2BC"
    guard var turned = Introduction.profile(from: again2, peer: peer, name: "Whatever") else { return }
    turned.id = UUID()
    #expect(Introduction.add(turned, from: again2, to: &list, renewing: false) == .already("Test iPhone"))
    var pairOfThem = list
    var twin = list[0]; twin.id = UUID(); twin.displayName = "Twin"; twin.providerIP = "100.64.0.50"; twin
        .instanceName = again2.txt["identifier"]!
    pairOfThem.insert(twin, at: 0)
    #expect(Introduction.add(turned, from: again2, to: &pairOfThem, renewing: true) == .already("Twin"))
    #expect(pairOfThem.map(\.instanceName) == [twin.instanceName, list[0].instanceName] && list[0]
        .instanceName == "0A0A0A0A-D414-41D0-BE80-7567AE75B2BC")
    // The app, running, saves over what the CLI renewed: an announcement it left alone stays the newer one on disk.
    var appHas = list[0]; appHas.instanceName = new.instanceName; appHas.txt = new.txt
    var appWants = appHas; appWants.displayName = "Renamed in the app"
    let kept2 = ProfileStore.merge(base: [appHas], wanted: [appWants], disk: list)
    #expect(kept2.count == 1 && kept2[0].displayName == "Renamed in the app" && kept2[0].instanceName == list[0]
        .instanceName && kept2[0].txt == list[0].txt)
    // …and one it changed itself is its own.
    var appChanged = appHas; appChanged.instanceName = "0C0C0C0C-D414-41D0-BE80-7567AE75B2BC"; appChanged
        .txt["identifier"] = appChanged.instanceName
    #expect(ProfileStore.merge(base: [appHas], wanted: [appChanged], disk: list)[0].instanceName == appChanged
        .instanceName)
    // From the device itself: the line's own names are placeholders, and the one named here is what is saved.
    let placed = Introduction.Device(name: "iPhone", peer: "this-device.invalid", port: device.port, txt: device.txt)
    guard case .success(let named) = Introduction.device(from: Introduction.line(
        Introduction.line(placed),
        ofDevice: "iphone-15-pro.example.ts.net",
        named: "iphone-15-pro"
    )) else { Issue.record("a device's own line didn't read"); return }
    #expect(named.peer == "iphone-15-pro.example.ts.net" && named.name == "iphone-15-pro" && named.txt == device
        .txt && named.port == device.port)
    #expect(Introduction.line("not a line", ofDevice: "x", named: "y") == "not a line")
    // A code's address: the Mac's name alone, or with its offer by parts, whatever a name holds.
    #expect(Introduction.codeURL(mac: "cloud-mac.example.ts.net") == "roamrun-introducer://cloud-mac.example.ts.net")
    let coded = Introduction.Offer(
        port: 53050,
        txt: [
            "identifier": "0A0A0A0A-D414-41D0-BE80-7567AE75B2BC",
            "authTag": "a+b/c",
            "model": "Mac16,1",
            "name": "M&M’s Mac",
            "flags": "1",
            "ver": "26",
            "minVer": "17"
        ]
    )
    let parts = URLComponents(string: Introduction.codeURL(mac: "cloud-mac.example.ts.net", offer: coded) ?? "")
    let read = Dictionary(uniqueKeysWithValues: (parts?.queryItems ?? []).map {
        ($0.name, $0.value ?? "")
    })
    #expect(parts?.host == "cloud-mac.example.ts.net" && read == [
        "p": "53050",
        "i": coded.txt["identifier"]!,
        "a": "a+b/c",
        "m": "Mac16,1",
        "n": "M&M’s Mac",
        "f": "1",
        "v": "26",
        "w": "17"
    ])
    var other = new; other.id = UUID(); other.instanceName = "0F0F0F0F-D414-41D0-BE80-7567AE75B2BC"; other
        .txt["identifier"] = other.instanceName
    other.providerIP = "100.64.0.77"
    if case .nameProblem = Introduction.add(other, from: device, to: &list) {}
    else {
        Issue.record("a second device took a name in use")
    }
    #expect(list.count == 1)

    // Put in a saved device's place: not when the line is for another saved device, nor when the one to replace is gone.
    var two = [new, other]
    two[1].displayName = "Other iPhone"
    var forOther = other; forOther.id = UUID(); forOther.remotePairingPort += 1
    #expect(Introduction.replace(new.id, with: forOther, in: &two) == .already("Other iPhone"))
    #expect(two[0].instanceName == new.instanceName)
    #expect(Introduction.replace(two[1].id, with: forOther, in: &two) == .replaced)
    #expect(two[1].remotePairingPort == forOther.remotePairingPort && two[1].displayName == "Other iPhone")
    #expect(Introduction.replace(UUID(), with: forOther, in: &two) == .gone)
    // One saved by its address becomes the Tailscale device the line names: it can then be exported.
    two[1].providerID = MeshProvider.manual.rawValue; two[1].providerHostName = two[1].providerIP; two[1].udid = "00008130-000D00000000D004"
    #expect(Introduction.device(of: two[1]) == nil)
    #expect(Introduction.replace(two[1].id, with: forOther, in: &two) == .replaced)
    #expect(Introduction.device(of: two[1]) != nil && two[1].providerHostName == forOther.providerHostName)
    #expect(two[1].udid == "00008130-000D00000000D004") // the same device's: what it is stays

    // A device saved long since is tried, for an introduction, where it was found a moment ago — and saved there once that held.
    var old = new; old.remotePairingPort = 50000; old.providerIP = "100.64.0.9"
    var now = new; now.remotePairingPort = 51000; now.providerIP = "100.64.0.9"
    #expect(AppCoordinator.tryAt(saved: old, given: now, fresh: true) == ("100.64.0.9", 51000))
    #expect(AppCoordinator.tryAt(saved: old, given: now, fresh: false) == (
        "100.64.0.9",
        50000
    )) // a file's is where it was when the file was made
    let moved2 = AppCoordinator.keepSaved(
        old.id,
        udid: "00008130-000D00000000D004",
        at: ("100.64.0.10", 51000),
        in: [old],
        save: { _ in
            true
        }
    )
    #expect(moved2?.remotePairingPort == 51000 && moved2?.providerIP == "100.64.0.10" && moved2?
        .udid == "00008130-000D00000000D004")
    #expect(AppCoordinator.keepSaved(old.id, udid: "x", in: [old], save: { _ in
        true
    })?.remotePairingPort == 50000)
    // A bridge running for it is rebuilt only when the device is somewhere else: not for a UDID learned.
    #expect(AppCoordinator.moved(old, to: ("100.64.0.9", 51000)) && AppCoordinator.moved(
        old,
        to: ("100.64.0.10", 50000)
    ))
    #expect(!AppCoordinator.moved(old, to: ("100.64.0.9", 50000)) && !AppCoordinator.moved(
        nil,
        to: ("100.64.0.9", 50000)
    ))

    // What another Mac sent is shown only as a device read and written again.
    #expect(Introduction.shown(Introduction.line(device)) == Introduction.line(device))
    #expect(Introduction.shown("\u{1B}]52;c;aGk=\u{07}") == nil && Introduction.shown("rr-device-v1:\u{1B}[2J") == nil)
    #expect(Introduction.shown(Introduction.line(Introduction.Offer(port: 50000, txt: [:]))) == nil)
}

/// An offer is this Mac's to give only when it reads whole: its port arrives before its values.
@Test func anOfferHalfArrivedIsWaitedForAndTwoAreNotChosenBetween() {
    let txt = ["identifier": "6BF40D22-D414-41D0-BE80-7567AE75B2BC", "authTag": "BsVby0td", "model": "VirtualMac2,1",
               "name": "far-mac", "flags": "1", "ver": "26", "minVer": "17"]
    func service(_ txt: [String: String], _ name: String = "a") -> CapturedService {
        CapturedService(
            instanceName: name,
            serviceType: Introduction.hostService,
            domain: "local",
            port: 50000,
            host: "h.local",
            hostIPs: [],
            txt: txt,
            lastSeen: .now
        )
    }
    #expect(Introduction.current(among: []) == .none)
    #expect(Introduction.current(among: [service([:])]) == .none)
    var partial = txt; partial["authTag"] = nil
    #expect(Introduction.current(among: [service(partial)]) == .none)
    #expect(Introduction.current(among: [service(txt)]) == .one(Introduction.line(Introduction.Offer(
        port: 50000,
        txt: txt
    ))))
    // One that reads and one that doesn't (half arrived, or another host's): the one that reads.
    #expect(Introduction.current(among: [service(txt), service([:], "b")]) == .one(Introduction.line(Introduction.Offer(
        port: 50000,
        txt: txt
    ))))
    var second = txt; second["identifier"] = "0F0F0F0F-D414-41D0-BE80-7567AE75B2BC"
    #expect(Introduction.current(among: [service(txt), service(second, "b")]) == .several)
}

/// Add Device's second step follows the row picked while the choice there was made for the user.
@Test func aChoiceMadeForTheUserFollowsTheRowAndTheirOwnStays() {
    func follow(_ chosen: String?, _ auto: String?, _ match: String?) -> [String?] {
        let r = MeshDevice.follow(chosen: chosen, auto: auto, match: match); return [r.chosen, r.auto]
    }
    #expect(follow(nil, nil, "a") == ["a", "a"])
    #expect(follow("a", "a", "b") == ["b", "b"])
    #expect(follow("a", "a", nil) == [nil, nil]) // another row, no device known for it: not the last row's
    #expect(follow("x", "a", "b") == ["x", "a"]) // chosen by hand
    #expect(follow("x", nil, nil) == ["x", nil])
}

@Test func theDeviceWaitingIsFoundByItsAddressEvenWhenOnlyAnIPv6OneWasHeard() {
    func service(_ name: String, _ host: String, _ ips: [String]) -> CapturedService {
        CapturedService(
            instanceName: name,
            serviceType: Introduction.pairableService,
            domain: "local",
            port: 1,
            host: host,
            hostIPs: ips,
            txt: [:],
            lastSeen: .now
        )
    }
    let other = service("other", "other.local", ["192.168.0.9"]), mine = service("mine", "mine.local", ["fe80::1"])
    let names = ["mine.local": ["192.168.0.20"]]
    #expect(CLI.waiting([other, mine], at: "192.168.0.20") {
        names[$0] ?? []
    }?.instanceName == "mine")
    // Heard with the address: nothing is looked up.
    #expect(CLI.waiting([other, mine], at: "192.168.0.9") { _ in
        Issue.record("looked up"); return []
    }?.instanceName == "other")
    #expect(CLI.waiting([other, mine], at: "192.168.0.30") {
        names[$0] ?? []
    } == nil)
}
