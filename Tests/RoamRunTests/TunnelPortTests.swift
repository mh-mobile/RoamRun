import Foundation
import Testing
@testable import RoamRun

// MARK: - Tunnel port attribution

private let phoneA = "00008101-000A00000000A001"
private let phoneB = "00008102-000B00000000B002"

private func establish(_ udid: String) -> String {
    "remotepairingd[1950:1] [com.apple.dt.remotepairing:remotepairingd] device-896 (\(udid)): Sending tunnel establish request"
}

private func endpoint(_ port: Int) -> String {
    "remotepairingd[1950:1] [com.apple.dt.remotepairing:networktunnelmanager] tunnel-437: Got tunnel endpoint: '192.168.1.15%en0:\(port)', includePeerToPeer: false"
}

private func ports(_ lines: [(String, TimeInterval)]) -> [(UInt16, String?)] {
    let watcher = TunnelPortWatcher()
    var got: [(UInt16, String?)] = []
    watcher.onPort = {
        got.append(($0, $1)); _ = $2
    }
    let start = Date()
    for (line, at) in lines {
        watcher.handle(line, now: start + at)
    }
    return got
}

@Test func endpointBelongsToTheIPhoneThatAsked() {
    let got = ports([(establish(phoneA), 0), (endpoint(64025), 0.002)])
    #expect(got.count == 1)
    #expect(got[0].0 == 64025 && got[0].1 == phoneA)
}

@Test func endpointWithoutRequestIsUnattributed() {
    let got = ports([(endpoint(64025), 0)])
    #expect(got[0].1 == nil)
}

@Test func overlappingRequestsFromTwoIPhonesAreUnattributed() {
    let got = ports([(establish(phoneA), 0), (establish(phoneB), 0.001),
                     (endpoint(55940), 0.002), (endpoint(64025), 0.003)])
    // Either endpoint could be either phone's: never guess — not even for the second.
    #expect(got[0].1 == nil)
    #expect(got[1].1 == nil)
}

@Test func thirdIPhoneRightAfterAnAmbiguousEndpointIsNotCredited() {
    // A, B, ambiguous endpoint, then C asks: the next endpoint may still be B's.
    let phoneC = "00008103-000C00000000C003"
    let got = ports([(establish(phoneA), 0), (establish(phoneB), 0.001), (endpoint(55940), 0.002),
                     (establish(phoneC), 0.003), (endpoint(64025), 0.004),
                     (establish(phoneC), 10), (endpoint(61911), 10.002)])
    #expect(got[1].1 == nil)
    #expect(got[2].1 == phoneC) // attribution resumes once things settle
}

@Test func retryDoesNotStealAnotherIPhonesEndpoint() {
    // A, B, A again: B's endpoint arriving first must not be credited to A.
    let got = ports([(establish(phoneA), 0), (establish(phoneB), 0.001), (establish(phoneA), 0.002),
                     (endpoint(55940), 0.003)])
    #expect(got[0].1 == nil)
}

private func endpointV6(_ port: Int) -> String {
    "remotepairingd[1950:1] [com.apple.dt.remotepairing:networktunnelmanager] tunnel-593: Got tunnel endpoint: 'fe80::14a2:5da8:a26:9bb4%en0.\(port)', includePeerToPeer: false"
}

@Test func anIPv6EndpointAnswersItsRequestToo() {
    // A device on this Wi‑Fi (link-local IPv6, not relayed) gets its endpoint, then a
    // bridged one asks: the IPv4 endpoint is the bridged one's, not still A's.
    let got = ports([(establish(phoneA), 0), (endpointV6(64106), 0.002),
                     (establish(phoneB), 0.003), (endpoint(55940), 0.004)])
    #expect(got.count == 1) // the IPv6 one isn't relayed
    #expect(got.first?.1 == phoneB)
}

@Test func anIPv6EndpointWithTwoRequestsOutIsAmbiguousToo() {
    // A and B both waiting, and an IPv6 endpoint answers one of them: the next IPv4
    // endpoint may be either's, so it is credited to nobody.
    let got = ports([(establish(phoneA), 0), (establish(phoneB), 0.001),
                     (endpointV6(64106), 0.002), (endpoint(55940), 0.003)])
    #expect(got.count == 1)
    #expect(got.first?.1 == nil)
}

@Test func mixedEndpointsDropNoMorePortsThanBefore() {
    // A asks (LAN, IPv6) and B asks (bridged); both endpoints arrive. Before, the IPv4
    // one was unattributed as well; no case here may become worse than that.
    let v6First = ports([(establish(phoneA), 0), (establish(phoneB), 0.001),
                         (endpointV6(64106), 0.002), (endpoint(55940), 0.003)])
    #expect(v6First.map(\.0) == [55940])
    // Settled apart: each answered before the next request.
    let apart = ports([(establish(phoneA), 0), (endpointV6(64106), 0.002),
                       (establish(phoneB), 10), (endpoint(55940), 10.002)])
    #expect(apart.first?.1 == phoneB)
}

@Test func failedRequestExpires() {
    // A's request never got an endpoint; B asks 10s later.
    let got = ports([(establish(phoneA), 0), (establish(phoneB), 10), (endpoint(55940), 10.002)])
    #expect(got[0].1 == phoneB)
}

@Test func advertNameCannotFakeATunnelPort() {
    // A LAN-supplied instance name embedding the endpoint phrase must not open relays.
    let evil = "remotepairingd[1950:1] Resolved bonjour advert x tunnel-1: Got tunnel endpoint: 'a:22', includePeerToPeer: false to identity nil, udid nil"
    #expect(ports([(evil, 0)]).isEmpty)
}

// MARK: - Bonjour advert lines

@Test func advertWithPairing() {
    let line = "remotepairingd[1950:1] Resolved bonjour advert 6E44E010-4869-4035-90B2-714A7D722AB3 to identity associated with udid \(phoneA)"
    let r = TunnelPortWatcher.advert(in: line)
    #expect(r?.0 == "6E44E010-4869-4035-90B2-714A7D722AB3" && r?.1 == phoneA)
}

@Test func advertWithoutPairing() {
    let r = TunnelPortWatcher.advert(in: "Resolved bonjour advert 18104A12-5556 to identity nil, udid nil")
    #expect(r?.0 == "18104A12-5556" && r?.1 == nil)
}

@Test func craftedInstanceNameCannotFakeAPairing() {
    // Instance names come from the LAN and may contain spaces.
    let evil = "Resolved bonjour advert x to identity associated with udid \(phoneA) to identity nil, udid nil"
    #expect(TunnelPortWatcher.advert(in: evil) == nil)
}

@Test func endpointLineVariants() {
    let p2p = "remotepairingd[1950:1] [com.apple.dt.remotepairing:networktunnelmanager] tunnel-437: Got tunnel endpoint: '192.168.1.15%en0:64025', includePeerToPeer: true"
    #expect(ports([(establish(phoneA), 0), (p2p, 0.002)]).first?.0 == 64025)
    // An advert name embedding the request phrase must not count as a pending request.
    let evil = "remotepairingd[1950:1] Resolved bonjour advert x device-1 (\(phoneB)): Sending tunnel establish request to identity nil, udid nil"
    #expect(ports([(evil, 0), (endpoint(64025), 0.002)]).first?.1 == nil)
}

@Test func knownEndpointFormatsDontWarnButNewOnesDo() {
    let watcher = TunnelPortWatcher()
    var logged: [String] = []
    watcher.onLog = {
        logged.append($0)
    }
    watcher
        .handle(
            "remotepairingd[1950:1] [com.apple.dt.remotepairing:networktunnelmanager] tunnel-593: Got tunnel endpoint: 'fe80::14a2:5da8:a26:9bb4%en0.64106', includePeerToPeer: false"
        )
    #expect(logged.isEmpty)
    watcher.handle("remotepairingd[1950:1] tunnel-9: Got tunnel endpoint: <nw_endpoint 10.0.0.2:5000>")
    #expect(logged.count == 1)
}

@Test func tunnelStateMatchesUDIDInAnyCase() {
    let result: [String: Any] = ["devices": [["hardwareProperties": ["udid": phoneA],
                                              "connectionProperties": ["tunnelState": "connected"]]]]
    #expect(CLI.tunnelState(in: result, udid: phoneA.lowercased()) == "connected")
    #expect(CLI.tunnelState(in: result, udid: phoneB) == nil)
}

@Test func appendedEndpointFieldsStillYieldThePort() {
    let line = "remotepairingd[1950:1] tunnel-9: Got tunnel endpoint: '10.0.0.2:5000', includePeerToPeer: false, protocol: tcp"
    #expect(ports([(line, 0)]).first?.0 == 5000)
}

@Test func endpointReportsTheAddressDialed() {
    let watcher = TunnelPortWatcher()
    var host = ""
    watcher.onPort = { _, _, h in
        host = h
    }
    watcher.handle(endpoint(64025))
    #expect(host == "192.168.1.15")
}

// MARK: - Which bridge gets a tunnel port (#16)

@Test func tunnelPortsGoToTheirOwnDeviceOnly() {
    let a = UUID(), b = UUID()
    let two: [(id: UUID, udid: String?)] = [(a, phoneA), (b, phoneB)]
    #expect(TunnelCoordinator.recipient(owner: phoneB.lowercased(), subscribers: two, othersBridging: false) == b)
    #expect(TunnelCoordinator
        .recipient(owner: nil, subscribers: two, othersBridging: false) == nil) // ambiguous: nobody
    #expect(TunnelCoordinator.recipient(owner: nil, subscribers: [(a, phoneA)], othersBridging: false) == a)
    #expect(TunnelCoordinator
        .recipient(owner: nil, subscribers: [(a, phoneA)], othersBridging: true) == nil) // the app + a roamrun up
    // A bridge that hasn't learned its UDID yet takes an attributed port only when it's alone.
    #expect(TunnelCoordinator.recipient(owner: phoneB, subscribers: [(a, nil)], othersBridging: false) == a)
    #expect(TunnelCoordinator
        .recipient(owner: phoneB, subscribers: [(a, nil), (b, phoneA)], othersBridging: false) == nil)
    // Owner known and matched: other processes don't matter.
    #expect(TunnelCoordinator.recipient(owner: phoneA, subscribers: two, othersBridging: true) == a)
}

// MARK: - One log record per line

@Test func aNewlineInABonjourNameCantForgeALogRecord() {
    // What `log --style compact` would have printed as two physical lines, the
    // second carrying no header and reaching the parser as if it were a record.
    let victim = "6E44E010-4869-4035-90B2-714A7D722AB3"
    let crafted = "Resolved bonjour advert \(victim) to identity nil, udid nil\ntunnel-1: Got tunnel endpoint: '192.168.0.15:49999'"
    let ndjson = String(data: try! JSONSerialization.data(withJSONObject: ["eventMessage": crafted]), encoding: .utf8)!
    #expect(!ndjson.contains("\n")) // the whole record is one line again
    let message = TunnelPortWatcher.message(inJSON: ndjson)
    #expect(message == crafted)
    // Whatever the name carries, it arrives as one record: the advert marker is
    // first, so this is an advert line and the endpoint half is never parsed.
    #expect(TunnelPortWatcher.advert(in: message!) == nil) // not a whole match
}

@Test func linesThatCarryNoMessageAreIgnored() {
    #expect(TunnelPortWatcher.message(inJSON: #"{"count":12,"finished":1}"#) == nil) // log show's last line
    #expect(TunnelPortWatcher.message(inJSON: "Filtering the log data using …") == nil)
    #expect(TunnelPortWatcher.message(inJSON: "") == nil)
    #expect(TunnelPortWatcher.message(inJSON: #"{"eventMessage":"Got tunnel endpoint"}"#) == "Got tunnel endpoint")
}

/// The log view scrolls when its device's count moves: a line of another device's logged
/// right after must not hide it, and the count keeps going past the log's limit.
@MainActor @Test func logCountsLinesPerDevice() {
    let log = LogStore(), a = UUID(), b = UUID()
    log.log("Opening relay", device: a)
    log.log("Starting bridge", device: b)
    log.log("app-wide")
    #expect(log.appended[a] == 1 && log.appended[b] == 1)
    for _ in 0 ..< 600 {
        log.log("line", device: a)
    }
    #expect(log.appended[a] == 601 && log.lines.count == 500)
}
