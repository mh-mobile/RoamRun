import Foundation
import Testing
@testable import RoamRun

// MARK: - tailscale ping

@Test func directPathOnTheLAN() {
    let out = "pong from my-iphone (100.64.0.10) via 192.168.1.42:41641 in 40ms\n"
    #expect(TailscaleClient.directHost(fromPing: out) == "192.168.1.42")
}

@Test func directPathOverIPv6() {
    let out = "pong from my-iphone (100.64.0.10) via [fd00::1]:41641 in 40ms\n"
    #expect(TailscaleClient.directHost(fromPing: out) == "fd00::1")
}

@Test func lastPongWins() {
    let out = """
    pong from my-iphone (100.64.0.10) via DERP(tok) in 120ms
    pong from my-iphone (100.64.0.10) via 203.0.113.50:41805 in 80ms
    """
    #expect(TailscaleClient.directHost(fromPing: out) == "203.0.113.50")
}

@Test func relayedOrSilentIsNotDirect() {
    #expect(TailscaleClient.directHost(fromPing: "pong from my-iphone (100.64.0.10) via DERP(tok) in 120ms\n") == nil)
    #expect(TailscaleClient.directHost(fromPing: "ping \"100.64.0.10\" timed out\n") == nil)
    #expect(TailscaleClient.directHost(fromPing: "") == nil)
}

/// Naming a peer and saying whose it is, from what `tailscale status --json` carries.
@Test func aPeerIsNamedByTailscalesNameAndItsHolderIsTold() {
    let json = #"""
    {"Self":{"UserID":7,"TailscaleIPs":["100.64.0.1","fd7a::1"],"DNSName":"home.tail1.ts.net."},
     "CurrentTailnet":{"MagicDNSSuffix":"tail1.ts.net"},
     "User":{"7":{"LoginName":"me@example.com"},"9":{"LoginName":"alice@example.com"}},
     "Peer":{
      "a":{"ID":"n1","DNSName":"cloud-mac.tail1.ts.net.","HostName":"anything","OS":"macOS","UserID":7,"TailscaleIPs":["100.64.0.2"]},
      "b":{"ID":"n2","DNSName":"alice-mbp.tail1.ts.net.","OS":"macOS","UserID":9,"TailscaleIPs":["100.64.0.3"]},
      "c":{"ID":"n3","DNSName":"devserver.tail1.ts.net.","OS":"macOS","UserID":7,"Tags":["tag:dev"],"TailscaleIPs":["100.64.0.4"]},
      "d":{"ID":"n4","DNSName":"cloud-mac.tail2.ts.net.","OS":"macOS","UserID":11,"TailscaleIPs":["100.64.0.5"]},
      "e":{"ID":"n5","HostName":"cloud-mac","OS":"macOS","UserID":7,"TailscaleIPs":["100.64.0.6"]}}}
    """#
    guard let mesh = TailscaleClient.mesh(fromStatusJSON: json) else { Issue.record("no mesh"); return }
    #expect(mesh.ownIPs == ["100.64.0.1", "fd7a::1"] && mesh.userID == 7 && mesh.suffix == "tail1.ts.net")
    func named(_ name: String) -> TailscaleClient.NamedPeer {
        TailscaleClient.peer(named: name, in: mesh)
    }
    func id(_ name: String) -> String? {
        if case .one(let p) = named(name) {
            return p.id
        }; return nil
    }
    // The short name means this tailnet's; another tailnet's needs its whole name. A name a
    // device only gives itself (no DNSName) names nothing.
    #expect(id("cloud-mac") == "n1" && id("Cloud-Mac.tail1.ts.net.") == "n1" && id("cloud-mac.tail2.ts.net") == "n4")
    #expect(named("anything") == .none && named("") == .none && named("nobody") == .none)
    var twice = mesh
    twice.peers.append(MeshDevice(
        id: "n6",
        name: "cloud-mac",
        os: "macOS",
        ips: [],
        online: true,
        dnsName: "cloud-mac.tail1.ts.net"
    ))
    #expect(TailscaleClient.peer(named: "cloud-mac", in: twice) == .several([
        "cloud-mac.tail1.ts.net",
        "cloud-mac.tail1.ts.net"
    ]))
    // What the Introducer app puts for a device the far Mac names itself is no device's name, whatever is on the tailnet.
    var phones = mesh
    phones.peers.append(MeshDevice(
        id: "n7",
        name: "iphone",
        os: "iOS",
        ips: [],
        online: true,
        dnsName: "iphone.tail1.ts.net"
    ))
    #expect(TailscaleClient.peer(named: "this-device.invalid", in: phones) == .none && TailscaleClient.peer(
        named: "iphone",
        in: phones
    ) != .none)

    func holder(_ name: String) -> TailscaleClient.Holder? {
        if case .one(let p) = named(name) {
            return TailscaleClient.holder(of: p, in: mesh)
        }
        return nil
    }
    #expect(holder("cloud-mac") == .yours && holder("alice-mbp") == .user("alice@example.com"))
    #expect(holder("devserver") == .shared(["tag:dev"])) // tagged: no one user's, even with a UserID
    #expect(holder("cloud-mac.tail2.ts.net") == .unknown) // a user this status doesn't name
    #expect(TailscaleClient.mesh(fromStatusJSON: "not json") == nil)
}

/// Which Tailscale device a host on this LAN is: the one reached directly at its address, and
/// no guess where that is none or two.
@Test func aHostOnTheLANIsMatchedToItsTailscaleDeviceByAddress() {
    func device(_ name: String, _ curAddr: String) -> MeshDevice {
        MeshDevice(id: name, name: name, os: "iOS", ips: ["100.64.0.1"], online: true, curAddr: curAddr)
    }
    let devices = [
        device("iphone-15-pro", "192.168.0.19:41641"),
        device("iphone-xs", ""),
        device("ipad", "203.0.113.9:41641")
    ]
    #expect(devices.reached(at: ["192.168.0.19"])?.name == "iphone-15-pro")
    #expect(devices.reached(at: ["fe80::1", "192.168.0.19"])?.name == "iphone-15-pro")
    // Relayed (no direct address), another address, or nothing known: no match.
    #expect(devices.reached(at: ["192.168.0.38"]) == nil && devices.reached(at: []) == nil && devices
        .reached(at: [""]) == nil)
    // Two behind one address (a hotspot's): not told apart, so not chosen.
    #expect((devices + [device("other", "192.168.0.19:5555")]).reached(at: ["192.168.0.19"]) == nil)
}

@Test func tailscalePeersFromStatusJSON() {
    let json = #"{"Peer":{"k1":{"DNSName":"mac.tail.ts.net.","OS":"macOS","TailscaleIPs":["100.64.0.2"],"Online":true},"k2":{"DNSName":"my-iphone.tail.ts.net.","OS":"iOS","TailscaleIPs":["100.64.0.10"],"Online":false,"CurAddr":"203.0.113.50:41641"}}}"#
    let d = TailscaleClient.devices(fromStatusJSON: json)
    #expect(d?.map(\.name) == ["my-iphone", "mac"]) // iOS first
    #expect(d?.first?.curAddr == "203.0.113.50:41641" && d?.last?.curAddr == "")
    #expect(TailscaleClient.devices(fromStatusJSON: "not json") == nil)
}

@Test func aPeerWithoutAMagicDNSNameIsNamedByItsHost() {
    let json = #"{"Peer":{"k1":{"DNSName":"","HostName":"Ken's iPhone","OS":"iOS","TailscaleIPs":["100.64.0.10"]}}}"#
    #expect(TailscaleClient.devices(fromStatusJSON: json)?.map(\.name) == ["Ken's iPhone"])
}

@Test func tailscaleBeingSignedOutIsThisMacsProblemNotTheDevices() {
    #expect(TailscaleClient.stateProblem("Running") == nil)
    #expect(TailscaleClient.stateProblem("NeedsLogin")?.contains("sign in") == true)
    #expect(TailscaleClient.stateProblem("Stopped")?.contains("connect") == true)
    #expect(TailscaleClient.stateProblem("Starting") != nil)
    // Signed out still prints valid JSON with no peers, which used to read as
    // "running, 0 peers" and sent every later check after the device instead.
    #expect(TailscaleClient.stateProblem(inStatusJSON: #"{"BackendState":"NeedsLogin","Peer":null}"#) != nil)
    #expect(TailscaleClient.stateProblem(inStatusJSON: #"{"BackendState":"Running"}"#) == nil)
    #expect(TailscaleClient.stateProblem(inStatusJSON: "{}") == nil) // older tailscale: leave it be
    #expect(TailscaleClient.stateProblem(inStatusJSON: "not json") == nil)
}

@Test func aPongThroughDERPStillMeansTheDeviceIsUp() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    // What tailscale 1.84 does for a relayed peer: the pong, then exit 1 unless
    // it was told not to wait for a direct path.
    let fake = dir.appendingPathComponent("tailscale")
    try """
    #!/bin/sh
    echo "pong from iphone (100.64.0.10) via DERP(tok) in 20ms"
    for a in "$@"; do [ "$a" = "--until-direct=false" ] && exit 0; done
    echo "direct connection not established"
    exit 1
    """.write(to: fake, atomically: true, encoding: .utf8)
    chmod(fake.path, 0o755)
    #expect(TailscaleClient(binaryPath: fake.path).ping("100.64.0.10"))
}

/// Three outcomes, so 2b can tell this Mac's problem from the device's.
@Test func pingTellsNoAnswerFromCouldntAsk() {
    func r(_ status: Int32, _ out: String, _ err: String, timedOut: Bool = false) -> Proc.Result {
        Proc.Result(status: status, out: out, err: err, timedOut: timedOut)
    }
    #expect(TailscaleClient.ping(r(0, "pong from iphone (100.64.0.10) via DERP(tok) in 40ms", "")) == .pong)
    // What `tailscale ping -c 1` prints when nothing answers.
    #expect(TailscaleClient.ping(r(1, "ping \"100.64.0.10\" timed out\n", "no reply\n")) == .noPong)
    #expect(TailscaleClient.ping(r(-1, "", "The file doesn’t exist.")) == .couldNotRun("The file doesn’t exist."))
    #expect(TailscaleClient
        .ping(r(15, "", "tailscale timed out after 8s", timedOut: true)) ==
        .couldNotRun("tailscale timed out after 8s"))
    // This Mac's own Tailscale: not an answer about the device.
    for err in ["failed to connect to local Tailscale daemon for /localapi/v0/ping; not running?",
                "Tailscale is stopped.", "Logged out.", "Access denied: ping access denied",
                "failed to connect to local Tailscale service; is Tailscale running?", // the app quit
                "Machine is not yet approved by tailnet admin.", "unexpected state: NoState"]
    {
        #expect(TailscaleClient.ping(r(1, "", err)) == .couldNotRun(err), "\(err)")
    }
}
