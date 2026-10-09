import Foundation
import Network

// Runs the engine on this Mac under the test type _rrtest._tcp (never the real one):
//   xcrun swiftc -swift-version 6 -parse-as-library -o /tmp/relay-check iOS/Sources/StandIn.swift iOS/Sources/Introduction.swift iOS/Sources/Wire.swift iOS/Checks/relay-check.swift && /tmp/relay-check

final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [StandIn.Event] = []
    func add(_ e: StandIn.Event) { lock.withLock { all.append(e) }; print("  event:", e) }
    var list: [StandIn.Event] { lock.withLock { all } }
    func wait(_ seconds: Double = 5, for test: @escaping ([StandIn.Event]) -> Bool) -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { if test(list) { return true }; Thread.sleep(forTimeInterval: 0.05) }
        return test(list)
    }
}

/// What `dns-sd -B` printed so far.
final class Browse: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var text = ""
    init(type: String) {
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        process.arguments = ["-B", type, "local."]
        process.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [self] h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            lock.withLock { text += s }
        }
        try! process.run()
    }
    func wait(_ seconds: Double = 6, forLine test: @escaping (String) -> Bool) -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if lock.withLock({ text }).split(separator: "\n").contains(where: { test(String($0)) }) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}

/// A client on 127.0.0.1 that keeps what it received and whether the other side closed.
final class Client: @unchecked Sendable {
    let connection: NWConnection
    private let lock = NSLock()
    private var got = Data()
    private var closed = false, failed = false, ready = false
    init(port: UInt16, from local: String? = nil, queue: DispatchQueue) {
        let params = NWParameters.tcp
        if let local { params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(local), port: .any) }
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: params)
        connection.stateUpdateHandler = { [self] st in
            switch st {
            case .ready: lock.withLock { ready = true }; receive()
            case .failed, .waiting: lock.withLock { failed = true }
            case .cancelled: lock.withLock { closed = true }
            default: break
            }
        }
        connection.start(queue: queue)
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, eof, err in
            if let data { lock.withLock { got += data } }
            if eof || err != nil { lock.withLock { closed = true }; return }
            receive()
        }
    }
    func send(_ s: String) { connection.send(content: Data(s.utf8), completion: .contentProcessed { _ in }) }
    func fin() { connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in }) }
    func wait(_ seconds: Double = 5, until test: @escaping (Bool, Bool, Bool, Data) -> Bool) -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if lock.withLock({ test(ready, closed, failed, got) }) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

func check(_ ok: Bool, _ what: String) {
    print(ok ? "ok   " : "FAIL ", what)
    if !ok { exit(1) }
}

/// Echoes until the client's FIN, then closes.
func echo(_ c: NWConnection, on queue: DispatchQueue) {
    @Sendable func loop() {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, eof, err in
            if let data, !data.isEmpty { c.send(content: data, completion: .contentProcessed { _ in }) }
            if eof || err != nil { c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() }); return }
            loop()
        }
    }
    c.start(queue: queue); loop()
}

@main struct RelayCheck {
    static func main() {
        let queue = DispatchQueue(label: "check")
        let type = "_rrtest._tcp"

        // A fake far Mac: echo on 127.0.0.1.
        let farParams = NWParameters.tcp
        farParams.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let far = try! NWListener(using: farParams)
        let farReady = DispatchSemaphore(value: 0)
        far.stateUpdateHandler = { if case .ready = $0 { farReady.signal() } }
        let farHits = Counter()
        far.newConnectionHandler = { farHits.bump(); echo($0, on: queue) }
        far.start(queue: queue)
        check(farReady.wait(timeout: .now() + 5) == .success, "fake far Mac listens on 127.0.0.1:\(far.port!.rawValue)")

        func offer(_ id: String) -> Introduction.Offer {
            let o = Introduction.Offer(port: far.port!.rawValue, txt: ["identifier": id, "authTag": "dGVzdA", "model": "Mac16,1",
                                                                       "name": "Fake Offer Name", "flags": "1", "ver": "2", "minVer": "1"])
            check(Introduction.offer(from: Introduction.line(o)) == .success(o), "offer line round-trips")
            return Introduction.announced(o, as: "cloud-mac")
        }
        let browse = Browse(type: type)
        defer { browse.process.terminate() }

        // 1. A connection from an address not allowed is refused (allowlist empty: 127.0.0.1 is a stranger).
        print("-- wire")
        check(Wire.answer(from: "rr-pair-v1 offer rr-xcode-offer-v1:abc") == .offer("rr-xcode-offer-v1:abc"), "an offer is read")
        check(Wire.answer(from: "rr-pair-v1 ended no-offer") == .ended("no-offer"), "an ending is read")
        check(Wire.answer(from: "rr-pair-v1 saved") == .saved, "saved is read")
        check(Wire.answer(from: "rr-pair-v2 saved") != .saved && Wire.answer(from: "rr-pair-v1 offer ") != .offer(""), "another version's line and an empty offer aren't")
        check(Wire.answer(from: "rr-pair-v1 you iphone-15-pro.example.ts.net") == .you("iphone-15-pro.example.ts.net")
              && Wire.answer(from: "rr-pair-v1 you -x") != .you("-x") && Wire.answer(from: "rr-pair-v1 you a b") != .you("a"), "this device's name is read, and only one that is a name")
        check(Wire.answer(from: "rr-pair-v1 device?") == .wantDevice && Wire.answer(from: "rr-pair-v1 code 123456") == .code("123456"), "device control's question and code are read")
        check(Wire.answer(from: "rr-pair-v1 code 12345a") != .code("12345a") && Wire.answer(from: "rr-pair-v1 result done on") == .done(on: true)
              && Wire.answer(from: "rr-pair-v1 result failed not-paired") == .failed("not-paired"), "a code that isn't one isn't shown; results are read")
        check(Wire.onTailnet(Data([100, 109, 91, 134])) && !Wire.onTailnet(Data([100, 128, 0, 1])) && !Wire.onTailnet(Data([203, 0, 113, 5])), "only 100.64/10 is Tailscale's IPv4")
        check(Wire.onTailnet(Data([0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0] + [UInt8](repeating: 1, count: 10))) && !Wire.onTailnet(Data([UInt8](repeating: 0xFD, count: 16))), "only fd7a:115c:a1e0::/48 is Tailscale's IPv6")
        check(!Wire.sentence(ended: "<b>anything it sent</b>").contains("anything"), "a word this app doesn't know isn't shown as it came")
        let own = Introduction.Offer(port: 53050, txt: ["identifier": UUID().uuidString, "authTag": "dGVzdA", "model": "Mac16,1", "name": "Its Own Name", "flags": "1", "ver": "2", "minVer": "1"])
        check(Wire.announced(own, for: "rr-cloud.example.ts.net").txt["name"] == "rr-cloud" && Wire.announced(own, for: "100.101.102.103").txt["name"] == "100.101.102.103", "announced under what the person called it, an address too")
        check(Wire.saidAsTried(carried: true, success: false, line: false, title: "iOS stopped it in the background", farsWord: false)
              && !Wire.saidAsTried(carried: true, success: false, line: false, title: "it didn't save this iPhone", farsWord: true)
              && !Wire.saidAsTried(carried: false, success: false, line: false, title: nil, farsWord: false)
              && !Wire.saidAsTried(carried: true, success: false, line: false, title: "A pairing was tried", farsWord: false), "after a pairing was carried, only an ending that says nothing of it is said as tried")
        let unnamed = Introduction.Device(name: "iPhone", peer: Wire.unnamedPeer, port: 49152, txt: ["identifier": UUID().uuidString, "authTag": "dGVzdA", "flags": "1", "ver": "2", "minVer": "1"])
        check(Introduction.device(from: Introduction.line(unnamed)) == .success(unnamed) && Wire.unnamedPeer.hasSuffix(".invalid"), "the name a line holds for a device the far Mac names is a line's, and no tailnet's")
        print("-- refusal")
        let idA = UUID().uuidString
        let evA = Events()
        let a = StandIn(offer: offer(idA), farHost: "127.0.0.1", serviceType: type, allowed: [], deadline: 60, anywhere: true) { evA.add($0) }
        try! a.start()
        check(evA.wait { $0.contains { if case .announced(let n, let p) = $0 { return n == idA && p >= 1024 }; return false } }, "announced under the identifier")
        check(browse.wait { $0.contains("Add") && $0.contains(idA) }, "dns-sd -B sees Add")
        let portA = evA.list.compactMap { if case .announced(_, let p) = $0 { return p }; return nil }.first!
        let stranger = Client(port: portA, queue: queue)
        check(evA.wait { $0.contains { if case .refused = $0 { return true }; return false } }, "refused event")
        check(stranger.wait { _, closed, failed, _ in closed || failed }, "stranger's connection was closed")
        check(farHits.value == 0, "the fake far Mac saw no connection")
        a.end(.stopped); a.end(.stopped)
        check(evA.wait { $0.filter { $0 == .ended(.stopped) }.count == 1 }, "ended(.stopped) once (end is idempotent)")
        check(browse.wait { $0.contains("Rmv") && $0.contains(idA) }, "dns-sd -B sees Rmv after end")

        // 2. A connection from an allowed address (127.0.0.1 only) is carried to the far Mac and echoed; .carried ends it.
        print("-- relay")
        let idB = UUID().uuidString
        let evB = Events()
        let b = StandIn(offer: offer(idB), farHost: "127.0.0.1", serviceType: type, allowed: [IPv4Address.loopback.rawValue], deadline: 60, anywhere: true) { evB.add($0) }
        try! b.start()
        check(evB.wait { $0.contains { if case .announced(let n, _) = $0 { return n == idB }; return false } }, "announced")
        check(browse.wait { $0.contains("Add") && $0.contains(idB) }, "dns-sd -B sees Add")
        let portB = evB.list.compactMap { if case .announced(_, let p) = $0 { return p }; return nil }.first!
        let device = Client(port: portB, queue: queue)
        check(device.wait { ready, _, _, _ in ready }, "device connected")
        check(evB.wait { $0.contains { if case .connected = $0 { return true }; return false } }, "connected event")
        if OwnAddresses.all().contains(IPv4Address("127.0.0.2")!.rawValue) {
            let other = Client(port: portB, from: "127.0.0.2", queue: queue)
            check(other.wait { ready, _, _, _ in ready }, "stranger on 127.0.0.2 connected")
            check(evB.wait { $0.contains { if case .refused(let f) = $0 { return f.hasPrefix("127.0.0.2") }; return false } }, "connection from 127.0.0.2 refused")
        } else {
            print("skip  127.0.0.2 isn't an address of this Mac (sudo ifconfig lo0 alias 127.0.0.2 would make it one); refusal was checked above")
        }
        device.send("ping")
        check(device.wait { _, _, _, got in got == Data("ping".utf8) }, "echo came back through the relay")
        device.fin()
        check(device.wait { _, closed, _, _ in closed }, "FIN forwarded back: device saw the close")
        check(evB.wait { $0.contains(.ended(.carried(up: 4, down: 4))) }, "ended(.carried(up: 4, down: 4))")
        check(browse.wait { $0.contains("Rmv") && $0.contains(idB) }, "dns-sd -B sees Rmv within a few seconds of the end")

        // 3. Deadline.
        print("-- deadline")
        let evC = Events()
        let c = StandIn(offer: offer(UUID().uuidString), farHost: "127.0.0.1", serviceType: type, deadline: 1, anywhere: true) { evC.add($0) }
        try! c.start()
        check(evC.wait(4) { $0.contains(.ended(.deadline)) }, "ended(.deadline)")

        far.cancel()
        print("all checks passed")
    }
}
