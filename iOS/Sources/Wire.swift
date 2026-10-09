import Foundation
import Network

/// The introducing side of what `roamrun pair xcode --with` and `pair control --with` speak
/// (Sources/RoamRun/PairByName.swift, `Home`): asks the far Mac for its offer, and later says a
/// pairing was tried, or hears what that Mac's app kept. No line is carried by hand.
// ponytail: @unchecked Sendable because everything runs on the one serial `queue`.
final class Wire: @unchecked Sendable {
    static let port: UInt16 = 41830
    private static let prefix = "rr-pair-v1 "

    enum Answer: Equatable {
        case offer(String)
        /// The far Mac's reason, as its word.
        case ended(String)
        case saved, unsaved
        /// This device's Tailscale name, as the far Mac has it; its offer follows.
        case you(String)
        /// Device control: the far Mac asks which device this is before it offers.
        case wantDevice
        /// Device control: the code to type on this device.
        case code(String)
        /// Device control: what the far Mac's app kept; `on`: switched on there.
        case done(on: Bool)
        /// Device control: nothing kept, and the far Mac's word for why.
        case failed(String)
        /// Said with an offer for device control; nothing to act on here.
        case attempt
        /// The far Mac was reached and nothing listens there: no command of its is waiting.
        case notWaiting
        /// It took the connection and closed it unanswered: it waits for another device than this.
        case turnedAway
        /// It was never reached, and why.
        case unreached(String)
        /// Reached, and nothing usable came of it; why.
        case none(String)

        fileprivate var last: Bool {
            switch self {
            case .notWaiting, .turnedAway, .unreached, .none: true
            default: false
            }
        }
    }

    private let queue = DispatchQueue(label: "io.github.mh-mobile.roamrun.introducer.wire")
    private let connection: NWConnection
    private var buffer = Data()
    private var pending: (@Sendable (Answer) -> Void)?
    /// Device control: every line from here on, until the connection ends.
    private var stream: (@Sendable (Answer) -> Void)?
    private var ready = false, heard = false
    private var timer: DispatchWorkItem?

    init(farHost: String) {
        connection = NWConnection(host: NWEndpoint.Host(farHost), port: NWEndpoint.Port(rawValue: Self.port) ?? .any, using: .tcp)
    }

    static func answer(from line: String) -> Answer {
        guard line.hasPrefix(prefix) else { return .none("it answered with something this app doesn't know") }
        let words = line.dropFirst(prefix.count).split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        switch (words.first, words.count) {
        case ("offer", 2) where !words[1].isEmpty: return .offer(words[1])
        case ("ended", 2): return .ended(words[1])
        case ("saved", 1): return .saved
        case ("unsaved", 1): return .unsaved
        case ("you", 2) where isPeerName(words[1]): return .you(words[1])
        case ("device?", 1): return .wantDevice
        case ("attempt", 2): return .attempt
        case ("code", 2) where words[1].utf8.count == 6 && words[1].utf8.allSatisfy({ (0x30...0x39).contains($0) }): return .code(words[1])
        case ("result", 3) where words[1] == "done" && ["on", "off"].contains(words[2]): return .done(on: words[2] == "on")
        case ("result", 3) where words[1] == "failed": return .failed(words[2])
        default: return .none("it answered with something this app doesn't know")
        }
    }

    /// Only for the words this app knows: what the far Mac sent is never shown as it came.
    static func sentence(ended why: String) -> String {
        switch why {
        case "no-offer": "made no offer to pair in the time it waits. There: Device Hub › + › Pair Nearby Device."
        case "ambiguous": "offers to pair more than once. There: close Device Hub's sheet and press Pair Nearby Device again."
        case "stopped": "was stopped."
        default: "ended it; its terminal says why."
        }
    }

    static func sentence(failed why: String) -> String {
        switch why {
        case "exists": "already holds a pairing for this iPhone. Remove it there first (the RoamRun app, on the device's page)."
        case "not-paired": "saw no pairing made: a wrong code, refused here, or not in time. Introduce again."
        case "another-device": "has another device saved under this one's name; nothing was kept there."
        case "not-kept": "couldn't keep the pairing; it says why there. Remove the one just made here, in Settings › Developer Mode."
        case "no-app": "isn't running the RoamRun app, which makes and keeps the pairing. Open it there."
        case "cancelled": "was stopped; nothing was kept there."
        default: "kept nothing; it says why there."
        }
    }

    /// A Tailscale name as a device's line may hold one (the far Mac's own rule for it).
    static func isPeerName(_ name: String) -> Bool {
        (1...253).contains(name.utf8.count) && !name.hasPrefix("-") && !name.hasPrefix(".")
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == ".") }
    }

    /// What a line says of this device's Tailscale name where the far Mac says it itself: no name on a tailnet.
    static let unnamedPeer = "this-device.invalid"

    /// The name's first label when it is a name; the address itself otherwise.
    static func label(_ host: String) -> String {
        IPv4Address(host) == nil && IPv6Address(host) == nil ? String(host.split(separator: ".").first ?? "") : host
    }

    /// The offer as it is announced for a far Mac called so: under what the person called it, never
    /// the name that Mac gave itself.
    static func announced(_ offer: Introduction.Offer, for host: String) -> Introduction.Offer {
        Introduction.announced(offer, as: label(host))
    }

    /// After a pairing was carried, an ending that says nothing of it is said as "a pairing was
    /// tried". Not one that succeeded, has a line to carry, says so already, or is the far Mac's own word.
    static func saidAsTried(carried: Bool, success: Bool, line: Bool, title: String?, farsWord: Bool) -> Bool {
        carried && !success && !line && !farsWord && title?.hasPrefix("A pairing was tried") != true
    }

    /// An address Tailscale gives: 100.64.0.0/10 or fd7a:115c:a1e0::/48.
    static func onTailnet(_ raw: Data) -> Bool {
        let b = [UInt8](raw)
        if b.count == 4 { return b[0] == 100 && b[1] & 0xC0 == 64 }
        guard b.count == 16 else { return false }
        if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF { return b[12] == 100 && b[13] & 0xC0 == 64 }
        return Array(b[0..<6]) == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]
    }

    static func onTailnet(_ endpoint: NWEndpoint?) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return onTailnet(address.rawValue)
        case .ipv6(let address): return onTailnet(address.rawValue)
        default: return false
        }
    }

    /// Connects and asks; the far Mac answers once it has an offer (it waits for Pair Nearby Device).
    func fetch(_ completion: @escaping @Sendable (Answer) -> Void) {
        queue.async { [self] in
            pending = completion
            expect(within: 10, .unreached("it didn't answer in 10 seconds"))
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard !self.ready else { return }
                    self.ready = true
                    // Whatever the name led to, nothing is said to an address that isn't Tailscale's.
                    guard Self.onTailnet(self.connection.currentPath?.remoteEndpoint) else { self.answer(.unreached("that name isn't an address on the tailnet")); return }
                    self.write("offer?")
                    self.expect(within: 620, .none("it made no offer in 10 minutes"))
                    self.read()
                case .waiting(.posix(.ECONNREFUSED)), .failed(.posix(.ECONNREFUSED)): self.answer(.notWaiting)
                case .waiting(let error), .failed(let error): self.answer(self.ready ? .none(error.localizedDescription) : .unreached(error.localizedDescription))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Device control: answers which device this is; every line after that goes to `each`, the last
    /// one that ends it.
    func device(_ line: String, each: @escaping @Sendable (Answer) -> Void) {
        queue.async { [self] in
            stream = each
            write("device " + line)
            expect(within: 560, .none("it said nothing more in 9 minutes"))
            read()
        }
    }

    /// Says a pairing was tried with this device; the far Mac saves it and says so.
    func tried(_ device: String, _ completion: @escaping @Sendable (Answer) -> Void) {
        queue.async { [self] in
            pending = completion
            write("tried " + device)
            expect(within: 30, .none("it said nothing in 30 seconds"))
            read()
        }
    }

    /// Closes, saying why first when there is a reason (one of the far Mac's words) and a connection to say it on.
    func end(_ reason: String? = nil) {
        queue.async { [self] in
            pending = nil
            stream = nil
            timer?.cancel()
            guard let reason, ready else { connection.cancel(); return }
            write("ended " + reason) { [connection] in connection.cancel() }
        }
    }

    private func expect(within seconds: TimeInterval, _ otherwise: Answer) {
        timer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.answer(otherwise) }
        timer = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func write(_ text: String, then: (@Sendable () -> Void)? = nil) {
        connection.send(content: Data((Self.prefix + text + "\n").utf8), completion: .contentProcessed { _ in then?() })
    }

    private func read() {
        if let end = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[..<end], as: UTF8.self)
            buffer.removeSubrange(...end)
            heard = true
            answer(Self.answer(from: line))
            return
        }
        guard buffer.count <= 4096 else { answer(.none("it said too much")); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.buffer.append(data); self.read() }
            else if let error { self.answer(.none(error.localizedDescription)) }
            else if complete { self.answer(self.heard ? .none("the connection closed") : .turnedAway) }
            else { self.read() }
        }
    }

    private func answer(_ answer: Answer) {
        if answer.last { timer?.cancel(); connection.cancel() }
        if let each = stream {
            if answer.last { stream = nil }
            each(answer)
            if stream != nil { read() }
            return
        }
        guard let completion = pending else { return }
        // Its name comes before its offer: said, and the offer still waited for.
        if case .you = answer { completion(answer); read(); return }
        pending = nil
        timer?.cancel()
        completion(answer)
    }
}
