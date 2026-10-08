import Foundation

/// What two Macs say to each other so no line has to be carried by hand: `pair xcode --with`
/// listens on the Mac that offers, `pair introduce` without a line connects to it.
enum PairWire {
    static let port: UInt16 = 41830
    static let maxLine = 4096
    private static let prefix = "rr-pair-v1 "

    /// Why nothing came of it, as a word: the Mac that reads it writes the sentence.
    enum Reason: String, CaseIterable {
        case offerRefused = "offer-refused"
        case unreachable
        case ambiguous
        /// The Mac that offers made no offer in the time it waits.
        case noOffer = "no-offer"
        case deadline
        case stopped
        case addressLost = "address-lost"
        case announcementLost = "announcement-lost"
        case failed
    }

    /// Why a pairing for device control wasn't kept, as a word.
    enum Refusal: String, CaseIterable {
        /// This Mac holds a pairing for the device already: it isn't put in its place.
        case exists
        case cancelled
        /// The device that paired isn't the one that was to.
        case anotherDevice = "another-device"
        /// Paired, and nothing of it could be kept here: the device's own record of it stays.
        case notKept = "not-kept"
        /// The device came and the pairing wasn't made: a wrong code, refused, or not in time.
        case notPaired = "not-paired"
        case noApp = "no-app"
        case failed
    }

    /// What came of a pairing for device control. `on`: whether it may be used right away.
    enum Outcome: Equatable {
        case done(on: Bool)
        case failed(Refusal)
    }

    enum Message: Equatable {
        case wantOffer
        case offer(String)
        /// A pairing was tried; the device, as `devices add` takes it.
        case tried(String)
        case ended(Reason)
        case saved
        case unsaved
        // For device control: the Mac that offers asks for the device first, says which attempt
        // this is, passes the code on, and says what came of it itself.
        case wantDevice
        case device(String)
        case attempt(String)
        case code(String)
        case result(Outcome)
    }

    static func line(_ message: Message) -> String {
        switch message {
        case .wantOffer: prefix + "offer?"
        case .offer(let line): prefix + "offer " + line
        case .tried(let line): prefix + "tried " + line
        case .ended(let why): prefix + "ended " + why.rawValue
        case .saved: prefix + "saved"
        case .unsaved: prefix + "unsaved"
        case .wantDevice: prefix + "device?"
        case .device(let line): prefix + "device " + line
        case .attempt(let id): prefix + "attempt " + id
        case .code(let digits): prefix + "code " + digits
        case .result(.done(let on)): prefix + "result done " + (on ? "on" : "off")
        case .result(.failed(let why)): prefix + "result failed " + why.rawValue
        }
    }

    /// Six ASCII digits and nothing else: what is shown as a code is never anything but one.
    static func isCode(_ text: String) -> Bool {
        text.utf8.count == 6 && text.utf8.allSatisfy { (0x30...0x39).contains($0) }
    }

    /// nil for another version's line, or anything not one of these.
    static func message(from line: String) -> Message? {
        guard line.hasPrefix(prefix) else { return nil }
        let words = line.dropFirst(prefix.count).split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        switch (words.first, words.count) {
        case ("offer?", 1): return .wantOffer
        case ("saved", 1): return .saved
        case ("unsaved", 1): return .unsaved
        case ("offer", 2) where !words[1].isEmpty: return .offer(words[1])
        case ("tried", 2) where !words[1].isEmpty: return .tried(words[1])
        case ("ended", 2): return Reason(rawValue: words[1]).map(Message.ended)
        case ("device?", 1): return .wantDevice
        case ("device", 2) where !words[1].isEmpty: return .device(words[1])
        case ("attempt", 2): return UUID(uuidString: words[1]).map { .attempt($0.uuidString) }
        case ("code", 2): return isCode(words[1]) ? .code(words[1]) : nil
        case ("result", 3) where words[1] == "done" && ["on", "off"].contains(words[2]): return .result(.done(on: words[2] == "on"))
        case ("result", 3) where words[1] == "failed": return Refusal(rawValue: words[2]).map { .result(.failed($0)) }
        default: return nil
        }
    }
}

/// One connection, read a line at a time. Blocking: call it off the main actor.
final class PairLink: @unchecked Sendable {
    enum Read: Equatable {
        case line(String), closed, timeout, tooLong
        /// The line as one of the two Macs' messages; nil for anything else.
        var message: PairWire.Message? {
            if case .line(let text) = self { PairWire.message(from: text) } else { nil }
        }
    }

    private let fd: Int32
    private var buffer = Data()
    private let lock = NSLock()
    private var open = true

    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }
    deinit { close() }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if open { open = false; Darwin.close(fd) }
    }

    /// The whole line within `seconds`, however slowly it comes; `stop` ends the wait early (as a timeout).
    func read(within seconds: TimeInterval, stop: () -> Bool = { false }) -> Read {
        let end = Date().addingTimeInterval(seconds)
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                guard nl - buffer.startIndex <= PairWire.maxLine else { return .tooLong }
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                return .line(line)
            }
            if buffer.count > PairWire.maxLine { return .tooLong }
            let left = end.timeIntervalSinceNow
            if left <= 0 || stop() { return .timeout }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, Int32(min(left, 0.25) * 1000)) > 0 else { continue }
            var chunk = [UInt8](repeating: 0, count: 1024)
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return .closed }
            buffer.append(contentsOf: chunk[..<n])
        }
    }

    @discardableResult
    func send(_ message: PairWire.Message) -> Bool { write(PairWire.line(message) + "\n") }

    @discardableResult
    func write(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    /// The other end has closed (nothing is taken off the line to find out).
    var gone: Bool {
        var byte: UInt8 = 0
        let n = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK)
    }

    private static func address(_ ip: String, _ port: UInt16) -> sockaddr_in? {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        return inet_pton(AF_INET, ip, &a.sin_addr) == 1 ? a : nil
    }

    /// An address alone doesn't say which interface a packet came in on: a host on the LAN with a
    /// route to it reaches a socket bound only to the address.
    fileprivate static func tie(_ fd: Int32, to interface: String?) -> Bool {
        guard let interface else { return true }
        var index = if_nametoindex(interface)
        return index != 0 && setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0
    }

    /// nil when nothing answers within `seconds`.
    static func connect(to ip: String, port: UInt16, interface: String?, within seconds: TimeInterval = 5) -> PairLink? {
        guard var a = address(ip, port) else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard tie(fd, to: interface) else { Darwin.close(fd); return nil }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let r = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if r != 0 {
            guard errno == EINPROGRESS else { Darwin.close(fd); return nil }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var err: Int32 = 0, len = socklen_t(MemoryLayout<Int32>.size)
            guard poll(&p, 1, Int32(seconds * 1000)) > 0,
                  getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else { Darwin.close(fd); return nil }
        }
        _ = fcntl(fd, F_SETFL, flags)
        return PairLink(fd: fd)
    }

    /// A listening socket on one address of this Mac, tied to `interface` when one is given, and its port.
    static func listening(ip: String, port: UInt16, interface: String?) throws -> (fd: Int32, port: UInt16) {
        guard var a = address(ip, port) else { throw RelayError.bindFailed("\(ip) isn't an address") }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RelayError.bindFailed("no socket") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        guard tie(fd, to: interface) else {
            Darwin.close(fd)
            throw RelayError.bindFailed("couldn't keep to \(interface ?? "")")
        }
        let bound = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            let why = String(cString: strerror(errno))
            Darwin.close(fd)
            throw RelayError.bindFailed("\(ip):\(port): \(why)")
        }
        var got = sockaddr_in(), len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return (fd, UInt16(bigEndian: got.sin_port))
    }

    /// Listens on one address of this Mac, and (given `interface`) for what comes in there alone.
    final class Listener: @unchecked Sendable {
        private let fd: Int32
        let port: UInt16

        init(ip: String, port: UInt16, interface: String?) throws {
            (fd, self.port) = try PairLink.listening(ip: ip, port: port, interface: interface)
        }
        deinit { Darwin.close(fd) }

        /// The next connection and the address it came from; nil when none comes within `seconds`.
        func accept(within seconds: TimeInterval) -> (PairLink, String)? {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, Int32(seconds * 1000)) > 0 else { return nil }
            var from = sockaddr_in(), len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let c = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(fd, $0, &len) }
            }
            guard c >= 0 else { return nil }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &text, socklen_t(text.count))
            return (PairLink(fd: c), text.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
        }
    }
}

enum PairByName {
    /// The other Mac, as it was when the command began: a name may come to mean another machine,
    /// and an address may be given to another.
    struct Peer: Equatable, Sendable {
        var ip: String
        var id: String
    }

    enum Offers: Equatable, Sendable { case none, one(String), several }

    /// The Mac that offers to pair: hands its offer to the one Mac named, and saves the device
    /// that Mac says a pairing was tried with.
    struct Far: Sendable {
        enum Event: Equatable, Sendable {
            case refused(from: String)
            /// From the right address, and Tailscale couldn't say whose it is just then.
            case unsure(from: String)
            case connected
            case waitingForOffer
            case offerSent
            /// The connection went after the offer did: the other Mac may come back.
            case dropped
        }
        enum End: Equatable, Sendable {
            case saved, unsaved
            case ended(PairWire.Reason)
            case ambiguous
            /// The offer went, and no result came in time.
            case noResult
            case noOne
            case stopped
        }

        var peer: Peer
        /// Whose an address is at this moment, as Tailscale has it; nil when it can't say.
        var owner: @Sendable (String) -> String?
        var offers: @Sendable () async -> Offers
        /// Forget what was seen of offers and look again.
        var rescan: @Sendable () async -> Void
        var save: @Sendable (String) async -> Bool
        var stopped: @Sendable () -> Bool = { false }
        var say: @Sendable (Event) -> Void = { _ in }
        /// How long a connection may still begin.
        var connectWindow: TimeInterval = 600
        /// How long a connection that was sent the offer is waited on: the other Mac's check, its
        /// five minutes of standing in, and the answer.
        var resultWindow: TimeInterval = 420
        var lineWait: TimeInterval = 10
        var pause: Duration = .seconds(1)

        func run(_ listener: PairLink.Listener) async -> End {
            let until = Date().addingTimeInterval(connectWindow)
            var told = false
            while true {
                if stopped() { return .stopped }
                if Date() >= until { return .noOne }
                guard let (link, from) = listener.accept(within: 0.25) else { continue }
                defer { link.close() }
                // The address first: a stranger costs no question to Tailscale.
                guard from == peer.ip else { say(.refused(from: from)); continue }
                guard let holder = owner(from) else { say(.unsure(from: from)); continue }
                guard holder == peer.id else { say(.refused(from: from)); continue }
                say(.connected)
                guard link.read(within: lineWait, stop: stopped) == .line(PairWire.line(.wantOffer)) else { continue }
                var offer: String?
                var rescanned = false
                while offer == nil, Date() < until, !stopped(), !link.gone {
                    switch await offers() {
                    case .one(let line): offer = line
                    case .several:
                        if rescanned { link.send(.ended(.ambiguous)); return .ambiguous }
                        rescanned = true
                        await rescan()
                    case .none:
                        if !told { told = true; say(.waitingForOffer) }
                        try? await Task.sleep(for: pause)
                    }
                }
                guard let offer else {
                    // Said, so the other Mac doesn't go on asking a Mac that has stopped.
                    if stopped() { link.send(.ended(.stopped)) } else if Date() >= until { link.send(.ended(.noOffer)) }
                    continue
                }
                guard link.send(.offer(offer)) else { continue }
                say(.offerSent)
                switch link.read(within: resultWindow, stop: stopped) {
                case .line(let line):
                    switch PairWire.message(from: line) {
                    case .tried(let device):
                        let ok = await save(device)
                        link.send(ok ? .saved : .unsaved)
                        return ok ? .saved : .unsaved
                    case .ended(let why): return .ended(why)
                    default: continue
                    }
                case .closed: say(.dropped)
                case .timeout: return stopped() ? .stopped : .noResult
                case .tooLong: continue
                }
            }
        }
    }

    /// The Mac that introduces: asks the one Mac named for its offer.
    struct Home: Sendable {
        enum Event: Equatable, Sendable { case waiting, connected }
        enum Fetched: Sendable {
            case offer(String, PairLink)
            /// For device control: the offer, and which attempt of that Mac's it belongs to.
            case control(String, attempt: String, PairLink)
            /// For device control: that Mac wouldn't begin, and why.
            case refused(PairWire.Refusal)
            case ended(PairWire.Reason)
            /// The address is no longer that Mac's, or Tailscale couldn't say whose it is.
            case notThatMac
            /// It answered with something this RoamRun doesn't know.
            case garbled
            case noOne
            case stopped
        }

        var peer: Peer
        var owner: @Sendable (String) -> String?
        var connect: @Sendable () -> PairLink?
        /// The device to be introduced, as a line: given to a Mac that asks for it first.
        var device: String?
        var stopped: @Sendable () -> Bool = { false }
        var say: @Sendable (Event) -> Void = { _ in }
        var window: TimeInterval = 600
        var lineWait: TimeInterval = 10
        var pause: Duration = .seconds(2)

        /// Tries again until the whole offer has arrived, and never after.
        func fetch() async -> Fetched {
            let until = Date().addingTimeInterval(window)
            var told = false
            while true {
                if stopped() { return .stopped }
                if Date() >= until { return .noOne }
                guard let link = connect() else {
                    if !told { told = true; say(.waiting) }
                    try? await Task.sleep(for: pause)
                    continue
                }
                guard owner(peer.ip) == peer.id else { link.close(); return .notThatMac }
                say(.connected)
                guard link.send(.wantOffer) else { link.close(); continue }
                switch link.read(within: until.timeIntervalSinceNow, stop: stopped) {
                case .line(let line):
                    switch PairWire.message(from: line) {
                    case .offer(let offer): return .offer(offer, link)
                    case .ended(let why): link.close(); return .ended(why)
                    case .wantDevice:
                        // From here on nothing is asked again: that Mac has begun.
                        guard let device, link.send(.device(device)) else { link.close(); return .garbled }
                        switch link.read(within: until.timeIntervalSinceNow, stop: stopped).message {
                        case .offer(let offer):
                            guard case .attempt(let id) = link.read(within: lineWait, stop: stopped).message else { link.close(); return .garbled }
                            return .control(offer, attempt: id, link)
                        case .ended(let why): link.close(); return .ended(why)
                        case .result(.failed(let why)): link.close(); return .refused(why)
                        default: link.close(); return .garbled
                        }
                    default: link.close(); return .garbled
                    }
                case .closed: link.close(); try? await Task.sleep(for: pause)
                case .timeout: link.close()
                case .tooLong: link.close(); return .garbled
                }
            }
        }

        enum Saved: Equatable, Sendable { case saved, unsaved, unknown }

        /// Says a pairing was tried and hands the device over; what the other Mac did with it, if it said.
        static func handOver(_ device: String, on link: PairLink, within seconds: TimeInterval = 30) -> Saved {
            defer { link.close() }
            guard link.send(.tried(device)), case .line(let line) = link.read(within: seconds) else { return .unknown }
            switch PairWire.message(from: line) {
            case .saved: return .saved
            case .unsaved: return .unsaved
            default: return .unknown
            }
        }
    }

    /// The Mac that offers a pairing of its own, for device control. Its app makes the pairing
    /// and keeps it; this only carries, between that app and the one Mac named.
    struct FarControl: Sendable {
        /// `attempt`: which of the app's attempts this offer belongs to; each try is one of its own.
        enum Started: Equatable, Sendable { case offer(String, attempt: String), refused(PairWire.Refusal) }
        enum Status: Equatable, Sendable {
            case waiting
            /// The code to pass on; it goes on being said until the pairing is made or given up.
            case code(String)
            case checking
            case done(on: Bool)
            case failed(PairWire.Refusal)
            /// The app doesn't answer, or doesn't know the attempt.
            case unknown
        }
        enum Event: Equatable, Sendable {
            case refused(from: String), unsure(from: String), connected, offerSent(attempt: String), codeSent
            /// The device came and didn't pair: the other Mac is waited for again.
            case again
        }
        enum End: Equatable, Sendable {
            case done(on: Bool)
            case failed(PairWire.Refusal)
            /// The other Mac said why it stopped.
            case ended(PairWire.Reason)
            /// The other Mac went away; what the app made of the attempt after it was told to stop.
            case lost(Status)
            case noResult
            case noOne
            case stopped
        }

        var peer: Peer
        var owner: @Sendable (String) -> String?
        var start: @Sendable (_ device: String) async -> Started
        var status: @Sendable (_ attempt: String) async -> Status
        var cancel: @Sendable (_ attempt: String) async -> Void
        /// A code typed wrong, or the pairing refused by the device, isn't the end here: the
        /// other Mac's command is run again and this one has waited. So many times at most.
        var tries = 5
        var stopped: @Sendable () -> Bool = { false }
        var say: @Sendable (Event) -> Void = { _ in }
        var connectWindow: TimeInterval = 600
        /// From the offer to the result: the other Mac's check, its five minutes, and the keeping here.
        var resultWindow: TimeInterval = 540
        var lineWait: TimeInterval = 10
        var pause: TimeInterval = 2

        func run(_ listener: PairLink.Listener) async -> End {
            var until = Date().addingTimeInterval(connectWindow)
            var tried = 0
            retries: while true {
                if stopped() { return .stopped }
                if Date() >= until { return .noOne }
                guard let (link, from) = listener.accept(within: 0.25) else { continue }
                defer { link.close() }
                guard from == peer.ip else { say(.refused(from: from)); continue }
                guard let holder = owner(from) else { say(.unsure(from: from)); continue }
                guard holder == peer.id else { say(.refused(from: from)); continue }
                say(.connected)
                guard link.read(within: lineWait, stop: stopped).message == .wantOffer, link.send(.wantDevice),
                      case .device(let device) = link.read(within: lineWait, stop: stopped).message else { continue }
                // Begun: whatever happens to this connection from here, it isn't taken up again.
                let attempt: String
                switch await start(device) {
                case .refused(let why):
                    link.send(.result(.failed(why)))
                    return .failed(why)
                case .offer(let offer, let id):
                    attempt = id
                    guard link.send(.offer(offer)), link.send(.attempt(attempt)) else { return await given(up: attempt) }
                    say(.offerSent(attempt: attempt))
                }
                let end = Date().addingTimeInterval(resultWindow)
                var passed = false, silent = 0
                while Date() < end {
                    if stopped() {
                        link.send(.ended(.stopped))
                        return await given(up: attempt, as: .stopped)
                    }
                    switch await status(attempt) {
                    case .done(let on):
                        link.send(.result(.done(on: on)))
                        return .done(on: on)
                    case .failed(let why):
                        link.send(.result(.failed(why)))
                        tried += 1
                        // The device came and didn't pair, and nothing was kept: the other Mac's
                        // command ends on that and is run again; this one goes on waiting for it.
                        guard why == .notPaired, tried < tries else { return .failed(why) }
                        say(.again)
                        until = Date().addingTimeInterval(connectWindow)
                        continue retries
                    // The app gone: not waited out. What it kept, if it had begun to, isn't known here.
                    case .unknown:
                        silent += 1
                        if silent >= 3 { return .lost(.unknown) }
                    case .code(let digits) where !passed:
                        // A code that didn't get to where it is shown isn't one to wait on.
                        guard PairWire.isCode(digits), link.send(.code(digits)) else { return await given(up: attempt) }
                        passed = true
                        say(.codeSent)
                    default: silent = 0
                    }
                    switch link.read(within: pause, stop: stopped) {
                    case .timeout: continue
                    case .line(let text):
                        if case .ended(let why) = PairWire.message(from: text) { return await given(up: attempt, as: .ended(why)) }
                        return await given(up: attempt)
                    case .closed, .tooLong: return await given(up: attempt)
                    }
                }
                return await given(up: attempt, as: .noResult)
            }
        }

        /// The app is told to stop, and asked once more. What it had kept by then stays kept, and
        /// what it is keeping it goes on keeping: neither is said as nothing.
        private func given(up attempt: String, as end: End? = nil) async -> End {
            await cancel(attempt)
            switch await status(attempt) {
            case .done(let on): return .done(on: on)
            case .checking: return .lost(.checking)
            case .unknown: return .lost(.unknown)
            case let after: return end ?? .lost(after)
            }
        }
    }
}
