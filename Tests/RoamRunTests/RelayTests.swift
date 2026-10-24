import Foundation
import Testing
@testable import RoamRun
import Network
import os

// With the other relays on the loopback, one at a time: they count the pairs open in the process.
extension TimingSensitive.RelayOnLocalhost {
    /// The stand-in from start to end on the loopback: what it announces, what it says, and that
    /// every way out leaves nothing announced or listening.
    @MainActor @Test func aStandInSaysWhatHappensAndLeavesNothingBehind() async throws {
        final class Said { var events: [Introducer.Event] = [] }
        let txt = [
            "identifier": "6BF40D22-D414-41D0-BE80-7567AE75B2BC",
            "authTag": "BsVby0td",
            "model": "VirtualMac2,1",
            "name": "far-mac",
            "flags": "1",
            "ver": "26",
            "minVer": "17"
        ]
        func plan(_ far: UInt16, deadline: TimeInterval = 300) -> Introducer.Plan {
            .init(
                offer: .init(port: far, txt: txt),
                farIP: "127.0.0.1",
                localIP: "127.0.0.1",
                interface: "lo0",
                accept: .ownAddress,
                deadline: deadline
            )
        }
        func ended(_ said: Said) -> Introducer.Event? {
            said.events.last {
                if case .ended = $0 {
                    return true
                }
                return false
            }
        }

        // A pairing tried: a pair that carried bytes both ways closes, and that ends it.
        let server = try EchoServer()
        let far = await server.start()
        defer { server.stop() }
        var said = Said(), record = FakeRecord()
        var standIn = Introducer(plan(far), record: record, addressNow: {
            "127.0.0.1"
        }) { [said] in
            said.events.append($0)
        }
        try await standIn.start()
        let announced = try #require(record.standIn)
        #expect(announced.type == "_remotepairing-pairable-host._tcp" && announced
            .instance == txt["identifier"] && announced.txt == txt)
        // For a device that waits to be picked: its own kind of record, under the name it announces itself.
        do {
            var waits = plan(far)
            waits.service = Introduction.pairableService
            waits.instance = "Apple Vision Pro"
            let record = FakeRecord(), other = Introducer(waits, record: record, addressNow: {
                "127.0.0.1"
            }) { _ in }
            try await other.start()
            let announced = try #require(record.standIn)
            #expect(announced.type == "_remotepairing-manual-pairing._tcp" && announced
                .instance == "Apple Vision Pro" && announced.txt == txt)
            await other.end(.stopped)
            #expect(record.stopped == 1)
        }
        // Such a stand-in isn't ended by a connection that carried bytes and closed: Device Hub may make more than one.
        do {
            var waits = plan(far)
            waits.service = Introduction.pairableService
            waits.endsWhenCarried = false
            let said = Said(), record = FakeRecord(), other = Introducer(waits, record: record, addressNow: {
                "127.0.0.1"
            }) { [said] in
                said.events.append($0)
            }
            try await other.start()
            let port = try #require(record.standIn).port
            #expect(await roundTrip(port: port, payload: Data("pair".utf8)) == Data("pair".utf8))
            #expect(await eventuallyOnMain {
                said.events.contains(.connected(from: "127.0.0.1"))
            })
            try await Task.sleep(for: .milliseconds(400))
            #expect(ended(said) == nil && !other.ended)
            await other.end(.stopped)
            #expect(ended(said) == .ended(.stopped, clean: true))
        }
        #expect(announced.host.hasSuffix(".roamrun.local") && announced.ip == "127.0.0.1" && announced
            .port != far) // far's port is taken here: the next
        #expect(said.events == [.announced(interface: "lo0", name: "far-mac", port: announced.port)])
        // One that carries nothing says a device connected, and ends nothing.
        let idle = try #require(await openEcho(port: announced.port))
        idle.cancel()
        #expect(await eventuallyOnMain {
            said.events.contains(.connected(from: "127.0.0.1"))
        })
        try await Task.sleep(for: .milliseconds(300))
        #expect(ended(said) == nil && !standIn.ended)
        #expect(await roundTrip(port: announced.port, payload: Data("pair".utf8)) == Data("pair".utf8))
        #expect(await eventuallyOnMain {
            ended(said) == .ended(.carried, clean: true)
        })
        #expect(record.stopped == 1)
        #expect(await eventuallyOnMain {
            !TailscaleClient.listening(on: announced.port)
        })
        await standIn.end(.stopped)
        #expect(said.events
            .filter {
                if case .ended = $0 {
                    return true
                }
                return false
            }
            .count == 1) // an end is said once

        // Nobody at the far port: said, and it waits on (the offer may be stale; the deadline ends it).
        said = Said()
        record = FakeRecord()
        standIn = Introducer(plan(far == 9 ? 10 : 9, deadline: 1.5), record: record, addressNow: {
            "127.0.0.1"
        }) { [said] in
            said.events.append($0)
        }
        try await standIn.start()
        let port = try #require(record.standIn).port
        _ = await roundTrip(port: port, payload: Data("x".utf8), timeout: 1)
        #expect(await eventuallyOnMain {
            said.events.contains {
                if case .farDidNotAnswer = $0 {
                    return true
                }
                return false
            }
        })
        #expect(await eventuallyOnMain {
            ended(said) == .ended(.deadline, clean: true)
        })
        #expect(record.stopped == 1)
        #expect(await eventuallyOnMain {
            !TailscaleClient.listening(on: port)
        })

        // The interface's address gone: it stops rather than be announced elsewhere.
        said = Said()
        record = FakeRecord()
        var address: String? = "127.0.0.1"
        standIn = Introducer(plan(far), record: record, addressNow: {
            address
        }) { [said] in
            said.events.append($0)
        }
        try await standIn.start()
        address = "10.0.0.5"
        #expect(await eventuallyOnMain {
            ended(said) == .ended(.addressLost, clean: true)
        })

        // No interface has the address: nothing is announced, and nothing is left listening.
        said = Said()
        record = FakeRecord()
        record.refuses = true
        standIn = Introducer(plan(far), record: record, addressNow: {
            "127.0.0.1"
        }) { [said] in
            said.events.append($0)
        }
        await #expect(throws: (any Error).self) { try await standIn.start() }
        let asked = try #require(record.standIn).port
        #expect(said.events.isEmpty && Relay.openPairs == 0)
        #expect(await eventuallyOnMain {
            !TailscaleClient.listening(on: asked)
        })
    }
}

/// Whose connections a relay takes: this Mac's alone unless told otherwise, and nobody's on
/// anything it can't read.
@Test func aRelayTakesOnlyWhomItsPolicyNames() {
    func takes(_ from: String, _ policy: Relay.Accept, local: String = "192.168.0.15") -> Bool {
        Relay.accepts(from: IPv4Address(from)!, local: local, policy: policy)
    }
    #expect(takes("192.168.0.15", .ownAddress) && !takes("192.168.0.19", .ownAddress) && !takes(
        "127.0.0.1",
        .ownAddress
    ))
    #expect(takes("192.168.0.19", .only("192.168.0.19")) && !takes("192.168.0.20", .only("192.168.0.19")))
    #expect(!takes("192.168.0.15", .only("192.168.0.19"))) // not this Mac either: one host means one
    let lan = Relay.Accept.subnet(mask: "255.255.255.0")
    #expect(takes("192.168.0.19", lan) && takes("192.168.0.15", lan) && !takes("192.168.1.19", lan) && !takes(
        "100.64.0.2",
        lan
    ))
    #expect(takes("192.168.1.19", .subnet(mask: "255.255.0.0")) && !takes("192.169.0.19", .subnet(mask: "255.255.0.0")))
    // Unreadable: nobody, rather than everybody.
    #expect(!takes("192.168.0.19", .subnet(mask: "0.0.0.0")) && !takes("192.168.0.19", .subnet(mask: "nonsense")))
    #expect(!takes("192.168.0.19", .only("nonsense")) && !takes("192.168.0.15", .ownAddress, local: "nonsense"))
    // Unless given one, a relay is made with the first.
    #expect(Relay(localIP: "127.0.0.1", localPort: 1, remoteIP: "127.0.0.1", remotePort: 2).accept == .ownAddress)
}

// MARK: - Relay, end to end on localhost (fake device = an echo server)

/// Sends `payload` to 127.0.0.1:port and returns what comes back before the peer closes (or times out).
private func roundTrip(port: UInt16, payload: Data, timeout: TimeInterval = 5) async -> Data? {
    let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    return await withCheckedContinuation { cont in
        let box = OnceBox()
        let finish: @Sendable (Data?) -> Void = { d in
            box.run {
                conn.cancel()
                cont.resume(returning: d)
            }
        }
        conn.stateUpdateHandler = { s in
            switch s {
            case .ready:
                conn.send(content: payload, completion: .contentProcessed { _ in })
                conn.receive(minimumIncompleteLength: payload.count, maximumLength: 65536) { data, _, _, _ in
                    finish(data)
                }
            case .failed, .cancelled: finish(nil)
            default: break
            }
        }
        conn.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            finish(nil)
        }
    }
}

/// A connection to 127.0.0.1:port left open, once ready.
private func openEcho(port: UInt16) async -> NWConnection? {
    let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
        let box = OnceBox()
        conn.stateUpdateHandler = { s in
            switch s {
            case .ready: box.run {
                    cont.resume(returning: true)
                }
            case .failed, .cancelled: box.run {
                    cont.resume(returning: false)
                }
            default: break
            }
        }
        conn.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            box.run {
                cont.resume(returning: false)
            }
        }
    }
    if ok {
        return conn
    }
    conn.cancel()
    return nil
}

/// Sends `payload` on an open connection and returns the echo (nil on close or timeout).
private func echo(_ conn: NWConnection, _ payload: Data) async -> Data? {
    await withCheckedContinuation { cont in
        let box = OnceBox()
        conn.send(content: payload, completion: .contentProcessed { _ in })
        conn.receive(minimumIncompleteLength: payload.count, maximumLength: 65536) { data, _, _, _ in
            box.run {
                cont.resume(returning: data)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            box.run {
                cont.resume(returning: nil)
            }
        }
    }
}

/// A started relay on a free local port (random, retried if taken).
private func startedRelay(upstream: UInt16, spare: Bool = false, cap: Int = Relay.maxConnections,
                          clock: @escaping @Sendable () -> UInt64 = {
                              Relay.continuousNow()
                          },
                          onPair: (@Sendable (Relay.PairEvent) -> Void)? = nil) async throws -> Relay
{
    var lastError: Error?
    for _ in 0 ..< 10 {
        let r = Relay(localIP: "127.0.0.1", localPort: UInt16.random(in: 40000 ... 49000), remoteIP: "127.0.0.1",
                      remotePort: upstream, spare: spare, cap: cap, clock: clock, onPair: onPair)
        do { try await r.start()
            return r
        } catch { lastError = error }
    }
    throw lastError!
}

extension TimingSensitive {
    @Suite(.serialized) struct RelayOnLocalhost {
        @Test func bytesGoThroughUnchanged() async throws {
            let server = try EchoServer()
            let upstream = await server.start()
            defer { server.stop() }
            let relay = try await startedRelay(upstream: upstream)
            defer { relay.stop() }
            let payload = Data((0 ..< 4000).map {
                UInt8($0 % 251)
            })
            #expect(await roundTrip(port: relay.localPort, payload: payload) == payload)
        }

        @Test func refusedUpstreamClosesTheLocalSide() async throws {
            let server = try EchoServer()
            let dead = await server.start()
            server.stop() // nothing listens there now
            let relay = try await startedRelay(upstream: dead)
            defer { relay.stop() }
            let start = Date()
            let got = await roundTrip(port: relay.localPort, payload: Data("hi".utf8), timeout: 8)
            #expect(got == nil || got?.isEmpty == true)
            #expect(Date().timeIntervalSince(start) < 7) // closed, not left hanging until our timeout
        }

        @Test func aRefusingUpstreamIsDialedOnlyOnceAHold() async throws {
            let server = try EchoServer()
            let dead = await server.start()
            server.stop()
            let now = OSAllocatedUnfairLock<UInt64>(initialState: 1_000_000_000)
            let relay = try await startedRelay(upstream: dead, clock: {
                now.withLock {
                    $0
                }
            })
            defer { relay.stop() }
            for _ in 0 ..< 3 {
                _ = await roundTrip(port: relay.localPort, payload: Data("hi".utf8), timeout: 8)
            }
            #expect(relay.heldOffTotal == 2) // the first was dialed and refused; the next two weren't dialed
            now.withLock {
                $0 += UInt64((Relay.upstreamHold + 1) * 1e9)
            }
            _ = await roundTrip(port: relay.localPort, payload: Data("hi".utf8), timeout: 8)
            #expect(relay.heldOffTotal == 2) // the hold is over: dialed again
            _ = await roundTrip(port: relay.localPort, payload: Data("hi".utf8), timeout: 8)
            #expect(relay.heldOffTotal == 3) // and refused again: held again
        }

        /// "At most every 3 s" also when connections come together: the one that is dialed
        /// after a hold begins the next hold, before its own refusal has come back.
        @Test func connectionsThatComeTogetherAfterAHoldAreDialedOnce() async throws {
            let server = try EchoServer()
            let dead = await server.start()
            server.stop()
            let now = OSAllocatedUnfairLock<UInt64>(initialState: 1_000_000_000)
            let relay = try await startedRelay(upstream: dead, clock: {
                now.withLock {
                    $0
                }
            })
            defer { relay.stop() }
            _ = await roundTrip(port: relay.localPort, payload: Data("hi".utf8), timeout: 8) // dialed, refused
            now.withLock {
                $0 += UInt64((Relay.upstreamHold + 1) * 1e9)
            }
            let port = relay.localPort
            await withTaskGroup(of: Void.self) { group in
                for _ in 0 ..< 4 {
                    group.addTask {
                        _ = await roundTrip(port: port, payload: Data("hi".utf8), timeout: 8)
                    }
                }
            }
            #expect(relay.heldOffTotal == 3) // one of the four was dialed
        }

        @Test func aTunnelRelayDialsEveryTime() async throws {
            let server = try EchoServer()
            let dead = await server.start()
            server.stop()
            let relay = try await startedRelay(upstream: dead, spare: true)
            defer { relay.stop() }
            for _ in 0 ..< 3 {
                _ = await roundTrip(port: relay.localPort, payload: Data("hi".utf8), timeout: 8)
            }
            #expect(relay.heldOffTotal == 0)
        }

        @Test func connectionsBeyondTheCapAreRefused() async throws {
            let server = try EchoServer()
            let upstream = await server.start()
            defer { server.stop() }
            let relay = try await startedRelay(upstream: upstream)
            defer { relay.stop() }
            var held: [NWConnection] = []
            defer { held.forEach {
                $0.cancel()
            } }
            for _ in 0 ..< 64 { // the per-relay cap, each kept open
                let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: relay.localPort)!, using: .tcp)
                c.start(queue: .global())
                held.append(c)
            }
            try await Task.sleep(for: .seconds(2)) // let all 64 be accepted and tracked
            #expect(await roundTrip(port: relay.localPort, payload: Data("x".utf8), timeout: 3) == nil)
        }

        /// Opens `n` connections to the relay and keeps them until cancelled.
        private func hold(_ n: Int, to relay: Relay) -> [NWConnection] {
            (0 ..< n).map { _ in
                let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: relay.localPort)!, using: .tcp)
                c.start(queue: .global())
                return c
            }
        }

        /// The process-wide pair count must come back to zero whichever side ends a
        /// connection first — stop(), the client, or the upstream — or relays
        /// slowly lose capacity until they refuse everything.
        @Test func pairCountSurvivesStopAndCloseRaces() async throws {
            let server = try EchoServer()
            let upstream = await server.start()
            defer { server.stop() }
            #expect(try await eventually {
                Relay.openPairs == 0
            })

            // Stop with every connection tracked, then the clients' late closes arrive.
            let a = try await startedRelay(upstream: upstream)
            var held = hold(64, to: a)
            #expect(try await eventually {
                Relay.openPairs == 64
            })
            a.stop()
            held.forEach {
                $0.cancel()
            }
            #expect(try await eventually {
                Relay.openPairs == 0
            })

            // stop() and the upstream closing every connection, at the same moment.
            let far = try EchoServer()
            let farPort = await far.start()
            defer { far.stop() }
            let b = try await startedRelay(upstream: farPort)
            held = hold(40, to: b)
            #expect(try await eventually {
                far.accepted == 40 && Relay.openPairs == 40
            })
            DispatchQueue.concurrentPerform(iterations: 2) { i in
                if i == 0 {
                    far.closeAll()
                } else {
                    b.stop()
                }
            }
            held.forEach {
                $0.cancel()
            }
            #expect(try await eventually {
                Relay.openPairs == 0
            })

            // Full, all closed by the clients: new connections get through again.
            let c = try await startedRelay(upstream: upstream)
            defer { c.stop() }
            held = hold(64, to: c)
            #expect(try await eventually {
                Relay.openPairs == 64
            })
            #expect(await roundTrip(port: c.localPort, payload: Data("x".utf8), timeout: 2) == nil)
            held.forEach {
                $0.cancel()
            }
            #expect(try await eventually {
                Relay.openPairs == 0
            })
            #expect(await roundTrip(port: c.localPort, payload: Data("x".utf8)) == Data("x".utf8))
        }

        /// 256 pairs across all relays: one more is refused anywhere, until one closes.
        @Test func processWideCapSpansRelays() async throws {
            let server = try EchoServer()
            let upstream = await server.start()
            defer { server.stop() }
            var relays: [Relay] = []
            defer { relays.forEach {
                $0.stop()
            } }
            var held: [[NWConnection]] = []
            defer { held.joined().forEach {
                $0.cancel()
            } }
            for _ in 0 ..< 4 {
                let r = try await startedRelay(upstream: upstream)
                relays.append(r)
                held.append(hold(64, to: r))
            }
            #expect(try await eventually {
                Relay.openPairs == 256
            })
            let fifth = try await startedRelay(upstream: upstream)
            relays.append(fifth)
            #expect(await roundTrip(port: fifth.localPort, payload: Data("x".utf8), timeout: 2) == nil)
            held[0][0].cancel()
            #expect(try await eventually {
                Relay.openPairs == 255
            })
            #expect(await roundTrip(port: fifth.localPort, payload: Data("x".utf8)) == Data("x".utf8))
        }

        /// Tunnel relays fill up with remotepairingd's standby connections; the last
        /// slots stay for control channels, which must come back every ~40 s.
        @Test func tunnelRelaysLeaveTheLastSlotsToControlChannels() async throws {
            let server = try EchoServer()
            let upstream = await server.start()
            defer { server.stop() }
            var relays: [Relay] = []
            defer { relays.forEach {
                $0.stop()
            } }
            var held: [[NWConnection]] = []
            defer { held.joined().forEach {
                $0.cancel()
            } }
            let usable = 256 - Relay.controlReserve // what tunnel relays may take
            for n in [64, 64, 64, usable - 192] { // control relays: tunnel ones stop at spareCap
                let r = try await startedRelay(upstream: upstream)
                relays.append(r)
                held.append(hold(n, to: r))
            }
            #expect(try await eventually {
                Relay.openPairs == usable
            })
            // A tunnel relay: refused, though it holds nothing and the process isn't full.
            let tunnel = try await startedRelay(upstream: upstream, spare: true)
            relays.append(tunnel)
            #expect(await roundTrip(port: tunnel.localPort, payload: Data("x".utf8), timeout: 2) == nil)
            // A control relay still gets through.
            let control = try await startedRelay(upstream: upstream)
            relays.append(control)
            #expect(await roundTrip(port: control.localPort, payload: Data("x".utf8)) == Data("x".utf8))
        }

        /// A pair is told of twice: when it reaches the far side, and once when it ends, with
        /// what it carried each way. One that the far side refuses ends with the reason and nothing carried.
        @Test func aPairsOpeningAndEndAreEachToldOnce() async throws {
            final class Told: @unchecked Sendable {
                private let lock = NSLock()
                private var all: [Relay.PairEvent] = []
                func add(_ e: Relay.PairEvent) {
                    lock.withLock {
                        all.append(e)
                    }
                }

                var events: [Relay.PairEvent] {
                    lock.withLock {
                        all
                    }
                }
            }
            let server = try EchoServer()
            let upstream = await server.start()
            defer { server.stop() }
            let told = Told()
            let relay = try await startedRelay(upstream: upstream, cap: 1, onPair: told.add)
            defer { relay.stop() }
            #expect(await roundTrip(port: relay.localPort, payload: Data("hello".utf8)) == Data("hello".utf8))
            #expect(try await eventually {
                told.events.count == 2
            })
            // How a finished pair's end shows depends on which side's close is seen first: both
            // done, or an error on the other leg. What it carried, and that it is told once, don't.
            guard told.events.count == 2, case .closed(let from, let up, let down, _) = told.events[1] else {
                Issue.record("told: \(told.events)")
                return
            }
            #expect(told.events[0] == .opened(from: "127.0.0.1") && from == "127.0.0.1" && up == 5 && down == 5)
            try await Task.sleep(for: .milliseconds(300))
            #expect(told.events.count == 2)
            relay.stop()

            let nobody = Told()
            let dead = try await startedRelay(upstream: 1, onPair: nobody.add)
            defer { dead.stop() }
            _ = await roundTrip(port: dead.localPort, payload: Data("x".utf8), timeout: 2)
            #expect(try await eventually {
                !nobody.events.isEmpty
            })
            guard case .closed(_, _, let down, let why) = nobody.events.first
            else { Issue.record("no end told: \(nobody.events)")
                return
            }
            #expect(down == 0 && why != nil && nobody.events.count == 1)
        }

        /// A relay may be given fewer pairs than any relay may have, never more.
        @Test func aRelaysOwnCapOnlyLowersIt() {
            #expect(Relay.refusal(relayPairs: 1, total: 1, spare: false, cap: 1) == .relayFull)
            #expect(Relay.refusal(relayPairs: 1, total: 1, spare: false, cap: 2) == nil)
            #expect(Relay.refusal(relayPairs: Relay.maxConnections, total: 70, spare: false, cap: 1000) == .relayFull)
        }

        /// A tunnel relay keeps spareCap pairs: a new one pushes out a standby — never the
        /// live tunnel, even when it is both the oldest and has been quiet the longest.
        @Test func aFullTunnelRelayDropsAStandbyNotTheQuietLiveOne() async throws {
            let server = try EchoServer()
            let upstream = await server.start()
            defer { server.stop() }
            let relay = try await startedRelay(upstream: upstream, spare: true)
            defer { relay.stop() }
            let live = try #require(await openEcho(port: relay.localPort))
            defer { live.cancel() }
            let traffic = Data(count: Relay.standbyBytes) // what a live tunnel has moved by the time standbys pile up
            #expect(await echo(live, traffic)?.count == traffic.count)
            let idle = hold(Relay.spareCap - 1, to: relay)
            defer { idle.forEach {
                $0.cancel()
            } }
            #expect(try await eventually {
                Relay.openPairs == Relay.spareCap
            })
            #expect(await roundTrip(port: relay.localPort, payload: Data("x".utf8)) == Data("x".utf8))
            #expect(Relay.openPairs <= Relay.spareCap)
            #expect(await echo(live, Data("still here".utf8)) == Data("still here".utf8))
            relay.stop()
            #expect(try await eventually {
                Relay.openPairs == 0
            })
        }

        /// Only live-looking pairs: none is evicted, the relay takes one more.
        @Test func aTunnelRelayWithNoStandbyTakesThePairInstead() async throws {
            let server = try EchoServer()
            let upstream = await server.start()
            defer { server.stop() }
            let relay = try await startedRelay(upstream: upstream, spare: true)
            defer { relay.stop() }
            var live: [NWConnection] = []
            defer { live.forEach {
                $0.cancel()
            } }
            for _ in 0 ..< Relay.spareCap {
                let c = try #require(await openEcho(port: relay.localPort))
                live.append(c)
                #expect(await echo(c, Data(count: Relay.standbyBytes))?.count == Relay.standbyBytes)
            }
            let extra = try #require(await openEcho(port: relay.localPort))
            defer { extra.cancel() }
            #expect(try await eventually {
                Relay.openPairs == Relay.spareCap + 1
            })
            for c in live {
                #expect(await echo(c, Data("ok".utf8)) == Data("ok".utf8))
            }
        }

        /// A relay whose pairs stay open but silent reads as quiet — how an old tunnel's
        /// relay, kept open by standbys, gets closed.
        @Test func openButSilentPairsReadAsQuiet() async throws {
            let server = try EchoServer()
            let upstream = await server.start()
            defer { server.stop() }
            let relay = try await startedRelay(upstream: upstream, spare: true)
            defer { relay.stop() }
            let c = try #require(await openEcho(port: relay.localPort))
            defer { c.cancel() }
            #expect(try await eventually {
                relay.openCount == 1
            })
            #expect(!relay.quiet(for: 0.3))
            try await Task.sleep(for: .milliseconds(400))
            #expect(relay.openCount == 1 && relay.quiet(for: 0.3))
            #expect(await echo(c, Data("hi".utf8)) == Data("hi".utf8))
            #expect(!relay.quiet(for: 0.3))
        }

        /// Paused on cellular, a tunnel relay closes its pairs but keeps listening:
        /// back on Wi‑Fi the next tunnel comes to the same port.
        @Test func droppingConnectionsKeepsTheListener() async throws {
            let server = try EchoServer()
            let upstream = await server.start()
            defer { server.stop() }
            let relay = try await startedRelay(upstream: upstream, spare: true)
            defer { relay.stop() }
            let held = hold(3, to: relay)
            defer { held.forEach {
                $0.cancel()
            } }
            #expect(try await eventually {
                Relay.openPairs == 3
            })
            relay.dropConnections()
            #expect(Relay.openPairs == 0)
            #expect(await roundTrip(port: relay.localPort, payload: Data("x".utf8)) == Data("x".utf8))
            #expect(try await eventually {
                Relay.openPairs == 0
            })
        }

        /// A tunnel whose far end is gone still gets remotepairingd's writes: only bytes
        /// from the device say it is alive.
        @Test func onlyBytesFromTheDeviceCountAsHearingIt() async throws {
            let silent = try EchoServer(silent: true)
            let upstream = await silent.start()
            defer { silent.stop() }
            let relay = try await startedRelay(upstream: upstream, spare: true)
            defer { relay.stop() }
            let c = try #require(await openEcho(port: relay.localPort))
            defer { c.cancel() }
            #expect(try await eventually {
                relay.openCount == 1
            })
            #expect(!relay.heardFromDevice(within: 30)) // just opened: nothing from the device yet
            try await Task.sleep(for: .milliseconds(400))
            c.send(content: Data("heartbeat".utf8), completion: .contentProcessed { _ in })
            #expect(try await eventually {
                !relay.quiet(for: 0.3)
            }) // the Mac side wrote…
            #expect(!relay.heardFromDevice(within: 0.3)) // …the device said nothing

            let talker = try EchoServer()
            let answering = await talker.start()
            defer { talker.stop() }
            let live = try await startedRelay(upstream: answering, spare: true)
            defer { live.stop() }
            let l = try #require(await openEcho(port: live.localPort))
            defer { l.cancel() }
            try await Task.sleep(for: .milliseconds(400))
            #expect(await echo(l, Data("heartbeat".utf8)) == Data("heartbeat".utf8))
            #expect(live.heardFromDevice(within: 0.3)) // a device that answers is heard
        }

        /// The 256 ports it scans are under every other test's (`Ports`): a server of theirs
        /// that answered the probe would end the scan early and race the deadline, and the
        /// scan's own connections would be counted by whatever relay they reached.
        @Test func portScanKeepsItsDeadlineEvenOnASilentPort() async throws {
            // A port that accepts and never answers the handshake (4 s timeout on its own).
            var silent: EchoServer?, from: UInt16 = 0
            for port in UInt16(19152) ... 19160 where silent == nil {
                if let s = try? EchoServer(silent: true, port: port), await s.start() != 0 {
                    silent = s
                    from = port
                }
            }
            guard let silent else { return } // all taken: nothing to test here
            defer { silent.stop() }
            let clock = ContinuousClock(), start = clock.now
            let r = await ReachabilityProbe.findRemotePairingPort(host: "127.0.0.1", from: from, limit: .seconds(1))
            #expect(r == .timedOut)
            #expect(clock
                .now - start < .seconds(3.5)) // 1 s alone; slower beside parallel tests, but under the 4 s handshake
        }

        @Test func stopFreesThePort() async throws {
            let server = try EchoServer()
            let upstream = await server.start()
            defer { server.stop() }
            let first = try await startedRelay(upstream: upstream)
            let port = first.localPort
            first.stop()
            try await Task.sleep(for: .milliseconds(200))
            let again = Relay(localIP: "127.0.0.1", localPort: port, remoteIP: "127.0.0.1", remotePort: upstream)
            try await again.start()
            defer { again.stop() }
            #expect(await roundTrip(port: port, payload: Data("x".utf8)) == Data("x".utf8))
        }
    }
}

/// In the serialized relay suite: they open relays, and `processWideCapSpansRelays`
/// counts every pair in the process — run beside it, they made it flaky.
extension TimingSensitive.RelayOnLocalhost {
    /// A restart while a bind is in flight, then a discovery whose window reaches the
    /// old port further down: what is counted as relayed is exactly what listens.
    @MainActor @Test func coveredPortsMatchRelaysAfterARestartMidBind() async {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var p = profile("A")
        p.providerIP = "127.0.0.1"
        let bridge = ProxyBridge(profile: p, statusDir: dir)
        defer { bridge.stop() }
        let base = freeBase(in: 36000 ... 37999, count: 30)
        bridge.onTunnelPortDiscovered(base + 8, localIP: "127.0.0.1")
        for _ in 0 ..< 1000 where bridge.bindsInFlight == 0 {
            await Task.yield()
        }
        #expect(bridge.bindsInFlight > 0) // the old start is mid-bind
        bridge.stop()
        bridge.onTunnelPortDiscovered(base, localIP: "127.0.0.1")
        #expect(await eventuallyOnMain {
            bridge.bindsInFlight == 0 && !bridge.tunnelRelayPorts.isEmpty
        })
        try? await Task.sleep(for: .milliseconds(300)) // the old start's last bind ends too
        #expect(bridge.coveredPortsForTests == bridge.tunnelRelayPorts)
    }

    @MainActor @Test func aTunnelPortInAnotherBridgesLookaheadGoesToItsDevice() async {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var a = profile("A"), b = profile("B")
        a.providerIP = "127.0.0.1"
        b.providerIP = "127.0.0.1"
        let bridgeA = ProxyBridge(profile: a, statusDir: dir), bridgeB = ProxyBridge(profile: b, statusDir: dir)
        defer { bridgeA.stop()
            bridgeB.stop()
        }
        let base = freeBase(in: 30000 ... 31999) // bands differ per test: they run in parallel
        bridgeA.onTunnelPortDiscovered(base, localIP: "127.0.0.1")
        #expect(await eventuallyOnMain {
            bridgeA.tunnelRelayPorts.contains(base + 5)
        })
        // B's device says base+5 is its tunnel; A only held it on speculation.
        bridgeB.onTunnelPortDiscovered(base + 5, localIP: "127.0.0.1")
        #expect(await eventuallyOnMain {
            bridgeB.tunnelRelayPorts.contains(base + 5)
        })
        #expect(!bridgeA.tunnelRelayPorts.contains(base + 5))
        // B's next attempt dials past the port it just found: that one moves over too.
        #expect(await eventuallyOnMain {
            bridgeB.tunnelRelayPorts.contains(base + 6)
        })
        #expect(!bridgeA.tunnelRelayPorts.contains(base + 16))
        #expect(bridgeA.tunnelRelayPorts.contains(base + 4)) // the part of A's window below B's stays
    }

    @Test func aListenerThatDiesAfterItWasUpIsReportedOnce() async throws {
        let failures = Counter()
        let relay = Relay(
            localIP: "127.0.0.1",
            localPort: freeBase(in: 34000 ... 35999, count: 1),
            remoteIP: "127.0.0.1",
            remotePort: 9,
            onFailure: { _ in
                failures.bump()
            }
        )
        try await relay.start()
        defer { relay.stop() }
        // What used to be dropped: the first verdict had already been given.
        // Waiting once up may still recover by itself (a Wi‑Fi roam): not the end.
        relay.listenerStateChanged(.waiting(.posix(.ENETDOWN)), nil)
        #expect(failures.value == 0)
        relay.listenerStateChanged(.failed(.posix(.ENETDOWN)), nil)
        relay.listenerStateChanged(.failed(.posix(.ENETDOWN)), nil)
        #expect(failures.value == 1)
    }

    @MainActor @Test func anotherProcessClaimingPortsTakesOnlyIdleLookahead() async {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var a = profile("A")
        a.providerIP = "127.0.0.1"
        let bridge = ProxyBridge(profile: a, statusDir: dir)
        defer { bridge.stop() }
        let base = freeBase(in: 32000 ... 33999)
        bridge.onTunnelPortDiscovered(base, localIP: "127.0.0.1")
        #expect(await eventuallyOnMain {
            bridge.bindsInFlight == 0 && bridge.tunnelRelayPorts.contains(base + 16)
        })
        // Not from this process, not malformed, not wider than a window.
        #expect(ProxyBridge.handleClaim("\(getpid()) \(base + 3)-\(base + 19)", myPID: getpid()) == 0)
        #expect(ProxyBridge.handleClaim("4242 \(base)-\(base + 40)", myPID: getpid()) == 0)
        #expect(ProxyBridge.handleClaim("4242 nonsense", myPID: getpid()) == 0)
        // Another process's device owns base+3…: this bridge lets go of what it held ahead.
        let heldAhead = bridge.tunnelRelayPorts
            .filter {
                $0 >= base + 3
            }
            .count
        #expect(heldAhead == 14)
        #expect(ProxyBridge.handleClaim("4242 \(base + 3)-\(base + 19)", myPID: getpid()) == heldAhead)
        #expect(!bridge.tunnelRelayPorts.contains(base + 3))
        #expect(bridge.tunnelRelayPorts.contains(base + 2))
    }

    @Test func aListenerThisRelayNoLongerUsesIsIgnored() async throws {
        let failures = Counter()
        let relay = Relay(
            localIP: "127.0.0.1",
            localPort: freeBase(in: 34000 ... 35999, count: 1),
            remoteIP: "127.0.0.1",
            remotePort: 9,
            onFailure: { _ in
                failures.bump()
            }
        )
        try await relay.start()
        defer { relay.stop() }
        // A late failure from some other listener (one a restart replaced) says nothing about this one.
        let stranger = try NWListener(using: .tcp)
        relay.listenerStateChanged(.failed(.posix(.ENETDOWN)), stranger)
        #expect(failures.value == 0)
    }
}

// MARK: - Relay admission

@Test func admissionKeepsAReserveForControlChannels() {
    let top = 256, reserve = Relay.controlReserve
    #expect(Relay.refusal(relayPairs: 64, total: 10, spare: false) == .relayFull)
    #expect(Relay.refusal(relayPairs: 3, total: top, spare: false) == .processFull)
    #expect(Relay.refusal(relayPairs: 3, total: top - reserve, spare: true) == .reservedForControl)
    #expect(Relay.refusal(relayPairs: 3, total: top - reserve - 1, spare: true) == nil)
    #expect(Relay.refusal(relayPairs: 3, total: top - 1, spare: false) == nil) // control may use the reserve
}

@Test func aRefusedUpstreamIsLeftAloneForTheHoldOnly() {
    let s: UInt64 = 1_000_000_000
    #expect(!Relay.holdsOff(refusedAt: nil, now: 100 * s))
    #expect(Relay.holdsOff(refusedAt: 100 * s, now: 100 * s))
    let hold = UInt64(Relay.upstreamHold)
    #expect(Relay.holdsOff(refusedAt: 100 * s, now: (100 + hold) * s - 1))
    #expect(!Relay.holdsOff(refusedAt: 100 * s, now: (100 + hold) * s))
    #expect(Relay.upstreamHold + 1 < Link.waitAfter) // a held redial lands before the link reads as waiting
}

/// A refusal is one however it shows — the connection's state, a read or a send that fails first.
@Test func aRefusalIsARefusalHoweverItShows() {
    #expect(Relay.isRefusal(.posix(.ECONNREFUSED)))
    #expect(!Relay.isRefusal(.posix(.ETIMEDOUT)) && !Relay.isRefusal(.posix(.ENETDOWN)) && !Relay
        .isRefusal(.posix(.ECONNRESET)))
}

@Test func aRefusalIsLoggedOnlyEveryTenMinutesPerRelay() {
    let now = Date()
    #expect(Relay.shouldLogRefusal(last: nil, now: now))
    #expect(!Relay.shouldLogRefusal(last: now.addingTimeInterval(-300), now: now))
    #expect(Relay.shouldLogRefusal(last: now.addingTimeInterval(-600), now: now))
}

@MainActor private final class LateRecord: BonjourRecord {
    var onExit: ((Int32) -> Void)?
    var announced = false
    func register(instanceName: String, serviceType: String, domain: String,
                  port: UInt16, host: String, ip: String, txt: [String: String]) throws
    {
        announced = true
    }

    func registerOnItsInterface(instanceName: String, serviceType: String, domain: String,
                                port: UInt16, host: String, ip: String, txt: [String: String]) throws
    {
        announced = true
    }

    func stop() {
        announced = false
    }

    func renew() {}
    func previousExited() async -> Bool {
        true
    }
}

extension TimingSensitive.RelayOnLocalhost {
    /// Stopped while its listener was still starting: it said nothing is announced, so nothing may be afterwards.
    @MainActor @Test func aStandInStoppedWhileItStartsAnnouncesNothingAfterward() async throws {
        let record = LateRecord()
        let txt = [
            "identifier": "6BF40D22-D414-41D0-BE80-7567AE75B2BC",
            "authTag": "BsVby0td",
            "model": "VirtualMac2,1",
            "name": "far-mac",
            "flags": "1",
            "ver": "26",
            "minVer": "17"
        ]
        var said: [Introducer.Event] = []
        var (listening, stopped) = (false, false)
        let standIn = Introducer(.init(offer: .init(port: 58701, txt: txt), farIP: "127.0.0.1", localIP: "127.0.0.1",
                                       interface: "lo0", accept: .ownAddress, deadline: 0.1),
                                 record: record, addressNow: {
                                     "127.0.0.1"
                                 }, listening: {
                                     listening = true
                                     while !stopped {
                                         await Task.yield()
                                     }
                                 }) {
            said.append($0)
        }
        let starting = Task { @MainActor in
            try await standIn.start()
        }
        while !listening {
            await Task.yield()
        }
        await standIn.end(.stopped)
        stopped = true
        _ = try? await starting.value
        try await Task.sleep(for: .milliseconds(150))
        #expect(!record.announced)
        #expect(said == [.ended(.stopped, clean: true)])
        #expect(await eventuallyOnMain {
            !TailscaleClient.listening(on: 58701)
        })
    }
}
