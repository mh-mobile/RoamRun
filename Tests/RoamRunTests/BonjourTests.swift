import Foundation
import Testing
@testable import RoamRun

/// The record is announced on the interface whose address it names, not on a VM's bridge beside it.
@Test func theRecordIsAnnouncedOnTheInterfaceItsAddressIsOn() {
    func args(_ interfaces: [String: String]) -> [String] {
        DNSServiceProxy.arguments(
            instanceName: "6E44",
            serviceType: "_remotepairing._tcp",
            domain: "local",
            port: 49152,
            host: "rr-1.roamrun.local",
            ip: "192.168.1.2",
            txt: ["ver": "26"],
            interfaces: interfaces
        )
    }
    let record = ["-P", "6E44", "_remotepairing._tcp", "local", "49152", "rr-1.roamrun.local", "192.168.1.2", "ver=26"]
    #expect(args(["en1": "192.168.1.2", "bridge100": "198.19.249.3"]) == ["-i", "en1"] + record)
    #expect(args(["bridge100": "198.19.249.3"]) == record) // no interface holds it: as before
}

/// The line for a device that a Mac picks: read back as written, not taken for the other lines
/// (nor they for it), and nothing in it that isn't plainly a value of its kind.
@Test func aPairableDevicesLineIsReadOnlyAsWhatItIs() {
    let txt = [
        "identifier": "6BF40D22-D414-41D0-BE80-7567AE75B2BC",
        "authTag": "BsVby0td",
        "model": "RealityDevice14,1",
        "name": "Apple Vision Pro",
        "ver": "26",
        "minVer": "17"
    ]
    let pairable = Introduction.Pairable(instance: "Apple Vision Pro", port: 60346, txt: txt)
    let line = Introduction.line(pairable)
    #expect(line.hasPrefix("rr-pairable-v1:") && !line.contains(" ") && !line.contains("="))
    #expect(try! Introduction.pairable(from: " \(line)\n").get() == pairable)
    func refused<T>(_ r: Result<T, Introduction.Unreadable>) -> Introduction
        .Unreadable?
    {
        if case .failure(let e) = r {
            return e
        }; return nil
    }
    let offer = Introduction.line(Introduction.Offer(port: 53050, txt: txt.merging(["flags": "1"]) { a, _ in
        a
    }))
    if case .another = refused(Introduction.pairable(from: offer)) {}
    else {
        Issue.record("an offer read as a device that waits")
    }
    #expect(refused(Introduction.offer(from: line)) == .notOne && refused(Introduction.device(from: line)) == .notOne)
    #expect(refused(Introduction.pairable(from: String(line.dropLast(9)))) == .notOne)
    func bad(_ change: (inout Introduction.Pairable) -> Void) -> Bool {
        var p = pairable; change(&p)
        if case .refused = refused(Introduction.pairable(from: Introduction.line(p))) {
            return true
        }
        return false
    }
    #expect(bad {
        $0.port = 80
    } && bad {
        $0.txt["flags"] = "1"
    } && bad {
        $0.txt["name"] = nil
    })
    #expect(bad {
        $0.instance = ""
    } && bad {
        $0.instance = "a=b"
    } && bad { $0.instance = String(
        repeating: "n",
        count: 64
    ) } && bad {
        $0.instance = "a\u{202E}b"
    })
    // Which device it is isn't in the line: nothing in it names a host.
    #expect(!String(
        decoding: Data(base64Encoded: String(line.dropFirst("rr-pairable-v1:".count))
            .replacingOccurrences(
                of: "-",
                with: "+"
            )
            .replacingOccurrences(of: "_", with: "/") + "==") ?? Data(),
        as: UTF8.self
    ).contains("peer"))
    // From what was seen on the network: only the keys of its kind go into the line.
    let seen = CapturedService(
        instanceName: "Apple Vision Pro",
        serviceType: Introduction.pairableService,
        domain: "local",
        port: 60346,
        host: "vision.local",
        hostIPs: [],
        txt: txt.merging(["extra": "x"]) { a, _ in
            a
        },
        lastSeen: Date()
    )
    #expect(Introduction.pairable(seen) == pairable)
    var short = seen; short.txt["authTag"] = nil
    #expect(Introduction.pairable(short) == nil)
}

/// A name as dns-sd prints it is read back as it is: a device that waits announces under a name with spaces.
@MainActor @Test func aNameWithSpacesIsReadFromWhatDnsSdPrints() {
    #expect(BonjourCapture.unescaped("Apple\\032Vision\\032Pro") == "Apple Vision Pro")
    #expect(BonjourCapture.unescaped("a\\.b\\\\c") == "a.b\\c" && BonjourCapture
        .unescaped("6BF40D22-D414") == "6BF40D22-D414" && BonjourCapture.unescaped("x\\") == "x\\")
    // Three digits and nothing else are a byte; bytes above 127 come so, and make their character again.
    #expect(BonjourCapture.unescaped("a\\+12b") == "a+12b" && BonjourCapture.unescaped("caf\\195\\169") == "café")
    let c = BonjourCapture()
    c.reads(Introduction.pairableService)
    for line in [
        "_remotepairing-manual-pairing._tcp PTR Apple\\032Vision\\032Pro._remotepairing-manual-pairing._tcp",
        "Apple\\032Vision\\032Pro._remotepairing-manual-pairing._tcp SRV 0 0 60346 vision.local. ; Replace with unicast FQDN of target host",
        "Apple\\032Vision\\032Pro._remotepairing-manual-pairing._tcp TXT \"identifier=6BF40D22-D414-41D0-BE80-7567AE75B2BC\" \"authTag=BsVby0td\" \"model=RealityDevice14,1\" \"name=Apple Vision Pro\" \"ver=26\" \"minVer=17\"",
    ] {
        c.parse(line: line)
    }
    let seen = Array(c.services.values)
    #expect(seen.map(\.instanceName) == ["Apple Vision Pro"])
    let read = seen.first.flatMap {
        Introduction.pairable($0)
    }
    #expect(read?.instance == "Apple Vision Pro" && read?.port == 60346 && read?.txt["name"] == "Apple Vision Pro")
}

/// A record that stands in for another Mac goes out on the one interface that has the address, or not at all.
@Test func aStandInRecordIsNeverAnnouncedEverywhere() {
    func args(_ interfaces: [String: String]) -> [String]? {
        DNSServiceProxy.argumentsOnItsInterface(
            instanceName: "6E44",
            serviceType: "_remotepairing-pairable-host._tcp",
            domain: "local",
            port: 53050,
            host: "rr-1.roamrun.local",
            ip: "192.168.1.2",
            txt: ["ver": "26"],
            interfaces: interfaces
        )
    }
    #expect(args(["en1": "192.168.1.2", "bridge100": "198.19.249.3"])?.prefix(2) == ["-i", "en1"])
    #expect(args(["bridge100": "198.19.249.3"]) == nil && args([:]) == nil)
}

// MARK: - dns-sd -Z zone dump

@MainActor @Test func zoneDumpBecomesServices() {
    let c = BonjourCapture()
    c.ownedHosts = ["rr-1.roamrun.local"]
    for line in [
        "_remotepairing._tcp PTR 6E44._remotepairing._tcp",
        "6E44._remotepairing._tcp SRV 0 0 49152 my-iphone.local. ; Replace with unicast FQDN of target host",
        #"6E44._remotepairing._tcp TXT "identifier=AB" "authTag=k=v=w" "flag""#,
        "my-iphone.local. A 192.168.1.42",
        "_remotepairing._tcp PTR FAKE._remotepairing._tcp",
        "FAKE._remotepairing._tcp SRV 0 0 49152 rr-1.roamrun.local.", // our own record
    ] {
        c.parse(line: line)
    }
    let s = c.services["6E44._remotepairing._tcp"]
    #expect(s?.instanceName == "6E44" && s?.port == 49152 && s?.host == "my-iphone.local")
    #expect(s?.txt["authTag"] == "k=v=w" && s?.txt["flag"] == "" && s?.hostIPs == ["192.168.1.42"])
    #expect(c.services["FAKE._remotepairing._tcp"] == nil)
}

/// A host's address heard again makes none of its records newer: Add Device takes the newest.
@MainActor @Test func anAddressHeardAgainDoesntMakeARecordNewer() {
    let c = BonjourCapture()
    c.parse(line: "OLD._remotepairing._tcp SRV 0 0 49152 my-iphone.local.")
    let heard = c.services["OLD._remotepairing._tcp"]?.lastSeen
    Thread.sleep(forTimeInterval: 0.01)
    c.parse(line: "my-iphone.local. A 192.168.1.9")
    #expect(heard != nil && c.services["OLD._remotepairing._tcp"]?.lastSeen == heard)
    #expect(c.services["OLD._remotepairing._tcp"]?.hostIPs == ["192.168.1.9"])
}

@MainActor @Test func aFloodingPeerCantGrowTheTablesOrLockOutARealDevice() {
    let c = BonjourCapture()
    for i in 0 ..< 600 {
        c.parse(line: "I\(i)._remotepairing._tcp SRV 0 0 49152 h\(i).local.")
    }
    #expect(c.services.count == 500)
    c.parse(line: "REAL._remotepairing._tcp SRV 0 0 49152 my-iphone.local.") // arrives after the flood
    #expect(c.services["REAL._remotepairing._tcp"] != nil && c.services.count == 500)
}
