import Darwin
import Foundation

/// `roamrun mcp --http`: the tools of `roamrun mcp` over HTTP, for the machines on the tailnet Tailscale says are
/// allowed, served as `roamrunctl mcp --http` serves its own: one JSON-RPC message a `POST /mcp`, answered in JSON;
/// a turn for each device; a call whose caller has gone, or took it back, isn't made.
final class MCPHTTP: @unchecked Sendable {
    static let headMost = 16 * 1024
    static let bodyMost = 1 << 20
    /// From connecting, for the head; then for the body.
    static let headWithin: TimeInterval = 10
    static let bodyWithin: TimeInterval = 30
    static let writeWithin: TimeInterval = 30
    static let atOnce = 32
    static let fromOne = 17
    /// Connections answered "too many" at once, beyond which more are closed unanswered.
    static let turningAwayMost = 64
    /// A call that waited this long for its device isn't begun.
    static let turnWithin: TimeInterval = 20
    /// How long a `notifications/cancelled` is kept for a call still to come, and how many at most.
    static let takenBackFor: TimeInterval = 60
    static let cancelsMost = 256
    /// The longest a read of a request waits for anything to come.
    static let idle: TimeInterval = 60
    /// What may trail a chunked body's last piece, at most.
    static let trailerLines = 64
    static let trailerMost = 8 * 1024
    /// A connection's thread: what it reads is parsed there, and a JSON nested deep enough runs a thread's default
    /// 512 KB out (Foundation stops at depth 512, but only after recursing that far).
    static let stack = 8 << 20

    enum Allow: Equatable {
        case tag(String)
        case login(String)
    }

    /// Who Tailscale says is at an address: the machine's lasting id and tags, its user, and who shared it in.
    struct Whois: Equatable {
        var id = ""
        var tags: [String] = []
        var login = ""
        var sharer = 0
    }

    struct Request {
        var method: String
        var path: String
        var headers: [(String, String)]

        func header(_ name: String) -> String? {
            headers.first {
                $0.0 == name
            }?.1
        }
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    /// The HTTP status a request is refused with.
    struct Refused: Error, Equatable, ExpressibleByIntegerLiteral {
        let status: Int
        init(integerLiteral status: Int) {
            self.status = status
        }
    }

    // MARK: - Who may call

    /// `--allow`, as given.
    static func allow(_ said: String) throws -> Allow {
        // One each: a list in one (tag:a,tag:b) would be one tag nobody has.
        if said.contains(where: {
            $0 == "," || $0 == ";" || $0.isWhitespace
        }) {
            throw Failure(description: "--allow \(said): one tag or login each; --allow again for another")
        }
        if said.count > 4, said.hasPrefix("tag:") {
            return .tag(said)
        }
        if said.contains("@") {
            return .login(said)
        }
        throw Failure(
            description: "--allow \(said): a tag (tag:ci) or a login (someone@example.com), as `tailscale whois` names them. A machine's name isn't taken: it can be taken by another"
        )
    }

    /// Whether the machine calling may, and who it is for the log: by its tags where it has any, else by its user's
    /// login. One shared in from another tailnet is refused; so is this machine itself (any user of it would pass),
    /// unless the token came too.
    static func judged(_ who: Whois, allowed: [Allow], own: Bool, token: Bool) -> Result<String, Failure> {
        let name = who.tags.isEmpty ? who.login : who.tags.joined(separator: ",")
        if who.sharer != 0 {
            return .failure(Failure(description: "\(name), shared in from another tailnet"))
        }
        if own {
            return token ? .success("\(name) (this machine)") :
                .failure(Failure(description: "this machine itself, without the token"))
        }
        let fits = allowed.contains { allow in
            switch allow {
            case let .tag(tag): who.tags.contains(tag)
            // A tagged machine is nobody's, whoever it shows as.
            case let .login(login): who.tags.isEmpty && !who.login.isEmpty &&
                login.caseInsensitiveCompare(who.login) == .orderedSame
            }
        }
        return fits ? .success(name) : .failure(Failure(description: "\(name), not allowed"))
    }

    /// `tailscale whois --json`, read.
    static func whois(fromJSON out: String) -> Whois? {
        guard let data = out.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let node = root["Node"] as? [String: Any] ?? [:]
        return Whois(
            id: node["StableID"] as? String ?? "",
            tags: node["Tags"] as? [String] ?? [],
            login: (root["UserProfile"] as? [String: Any])?["LoginName"] as? String ?? "",
            sharer: (node["Sharer"] as? NSNumber)?.intValue ?? 0
        )
    }

    /// The token in `path`: its owner's alone to read, 32 characters at least, one line.
    static func token(at path: String) throws -> String {
        var info = stat()
        guard stat(path, &info) == 0 else { throw Failure(description: "\(path): \(String(cString: strerror(errno)))") }
        guard info.st_mode & 0o077 == 0 else {
            throw Failure(description: "\(path) can be read by others than its owner: chmod 600 it")
        }
        guard let read = FileManager.default.contents(atPath: path), let text = String(data: read, encoding: .utf8)
        else { throw Failure(description: "\(path): couldn't be read") }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 32, !token.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }) else {
            throw Failure(
                description: "\(path): a token is 32 characters or more on one line (`openssl rand -hex 32`, say)"
            )
        }
        return token
    }

    /// What a caller sent, as the log shows it: no control characters, 200 at most.
    static func printable(_ said: String) -> String {
        String(String.UnicodeScalarView(said.unicodeScalars.prefix(200).map {
            CharacterSet.controlCharacters.contains($0) ? "?" : $0
        }))
    }

    /// Equal, in a time that doesn't tell how much of it was.
    static func same(_ a: String, _ b: String) -> Bool {
        let (a, b) = (Array(a.utf8), Array(b.utf8))
        return a.count == b.count && zip(a, b).reduce(0) {
            $0 | ($1.0 ^ $1.1)
        } == 0
    }

    /// What a request's Host may name: this machine's address or one of its Tailscale names, with the port, or
    /// without it where the port is HTTP's own.
    static func hosts(ip: String, names: [String], port: UInt16) -> [String] {
        ([ip] + names).flatMap {
            port == 80 ? ["\($0):\(port)", $0] : ["\($0):\(port)"]
        }
    }

    // MARK: - Reading a request

    /// A socket read with one deadline for all that is read, not for each read.
    final class Reader {
        let fd: Int32
        var until: Date
        /// The longest a read waits for anything to come.
        var idle: TimeInterval = MCPHTTP.idle
        private var buffer: [UInt8] = []
        private var at = 0

        enum Filled { case data, end, late }

        init(fd: Int32, until: Date) {
            self.fd = fd
            self.until = until
        }

        private func fill() -> Filled {
            if at == buffer.count {
                buffer.removeAll(keepingCapacity: true)
                at = 0
            }
            while true {
                let left = until.timeIntervalSinceNow
                guard left > 0 else { return .late }
                var wanted = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&wanted, 1, Int32(min(left, idle) * 1000) + 1)
                if ready < 0, errno == EINTR {
                    continue
                }
                guard ready > 0 else {
                    // Nothing for `idle`: a body that stopped coming, whatever time is left for it.
                    return ready == 0 ? .late : .end
                }
                var chunk = [UInt8](repeating: 0, count: 8192)
                let n = recv(fd, &chunk, chunk.count, 0)
                if n < 0, errno == EINTR {
                    continue
                }
                guard n > 0 else { return .end }
                buffer.append(contentsOf: chunk[..<n])
                return .data
            }
        }

        /// A line, ending in LF; `most` bytes at most.
        func line(most: Int) -> Result<String, Refused> {
            var line: [UInt8] = []
            while true {
                if at == buffer.count {
                    switch fill() {
                    case .data: continue
                    case .end: return .failure(line.count > most ? 431 : 400)
                    case .late: return .failure(408)
                    }
                }
                let byte = buffer[at]
                at += 1
                line.append(byte)
                if byte == 0x0A {
                    break
                }
                if line.count > most {
                    return .failure(431)
                }
            }
            // By bytes: "\r\n" is one Character to a String.
            while line.last == 0x0A || line.last == 0x0D {
                line.removeLast()
            }
            guard let text = String(bytes: line, encoding: .utf8) else { return .failure(400) }
            return .success(text)
        }

        /// `count` bytes: 408 where the time ran out, 400 where they were cut short.
        func bytes(_ count: Int) -> Result<[UInt8], Refused> {
            var out: [UInt8] = []
            return pass(count) {
                out += $0
                return true
            }.map {
                out
            }
        }

        /// `count` bytes, handed on as they come: 507 where `into` couldn't keep them.
        func pass(_ count: Int, into: (ArraySlice<UInt8>) -> Bool) -> Result<Void, Refused> {
            var left = count
            while left > 0 {
                if at == buffer.count {
                    switch fill() {
                    case .data: continue
                    case .end: return .failure(400)
                    case .late: return .failure(408)
                    }
                }
                let n = min(buffer.count - at, left)
                guard into(buffer[at ..< at + n]) else { return .failure(507) }
                at += n
                left -= n
            }
            return .success(())
        }
    }

    /// The request line and the headers, to the empty line. A target in absolute form is taken by its path.
    static func head(_ reader: Reader) -> Result<Request, Refused> {
        var left = headMost
        var first = ""
        while first.isEmpty {
            switch reader.line(most: left) {
            case let .success(line): first = line
            case let .failure(status): return .failure(status)
            }
            left -= first.utf8.count + 2
            guard left >= 0 else { return .failure(431) }
        }
        let words = first.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard words.count == 3 else { return .failure(400) }
        guard words[2].hasPrefix("HTTP/1.") else { return .failure(505) }
        var target = words[1]
        if target.hasPrefix("http://") {
            let rest = target.dropFirst(7)
            target = rest.firstIndex(of: "/").map {
                String(rest[$0...])
            } ?? "/"
        }
        let path = target.split(separator: "?", omittingEmptySubsequences: false).first.map(String.init) ?? "/"
        var headers: [(String, String)] = []
        while true {
            let line: String
            switch reader.line(most: left) {
            case let .success(read): line = read
            case let .failure(status): return .failure(status)
            }
            left -= line.utf8.count + 2
            guard left >= 0 else { return .failure(431) }
            if line.isEmpty {
                break
            }
            guard let colon = line.firstIndex(of: ":") else { return .failure(400) }
            let name = line[..<colon]
            guard !name.isEmpty, !name.contains(where: \.isWhitespace) else { return .failure(400) }
            headers.append((
                name.lowercased(),
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            ))
        }
        return .success(Request(method: words[0], path: path, headers: headers))
    }

    /// The length the head gives, if it gives one and isn't chunked; 400 where it gives it wrong.
    static func length(_ request: Request) -> Result<Int?, Refused> {
        if request.header("transfer-encoding") != nil {
            return .success(nil)
        }
        let lengths = request.headers
            .filter {
                $0.0 == "content-length"
            }
            .map(\.1)
        switch lengths.count {
        case 0: return .success(nil)
        case 1 where !lengths[0].isEmpty && lengths[0].allSatisfy(\.isASCII) && lengths[0].allSatisfy(\.isNumber):
            return Int(lengths[0]).map {
                .success($0)
            } ?? .failure(413)
        default: return .failure(400)
        }
    }

    /// The body as the head frames it: chunked where it says so (also when a length comes with it), else by its one
    /// length, else none; `most` bytes at most.
    static func body(_ reader: Reader, _ request: Request, most: Int) -> Result<[UInt8], Refused> {
        var body: [UInt8] = []
        return framed(reader, request, most: most) {
            body += $0
            return true
        }.map { _ in
            body
        }
    }

    /// The body as the head frames it, handed on as it comes (`into`: false where it couldn't be kept); its size.
    static func framed(_ reader: Reader, _ request: Request, most: Int,
                       into: (ArraySlice<UInt8>) -> Bool) -> Result<Int, Refused>
    {
        if let coding = request.header("transfer-encoding") {
            guard coding.caseInsensitiveCompare("chunked") == .orderedSame else { return .failure(501) }
            var size = 0
            while true {
                let piece: Int
                switch reader.line(most: 1024) {
                case let .success(line):
                    guard let size = Int(
                        line.split(separator: ";", omittingEmptySubsequences: false)
                            .first?
                            .trimmingCharacters(in: .whitespaces) ?? "",
                        radix: 16
                    ), size >= 0 else { return .failure(400) }
                    piece = size
                case let .failure(status): return .failure(status)
                }
                if piece == 0 {
                    break
                }
                guard piece <= most - size else { return .failure(413) }
                if case let .failure(status) = reader.pass(piece, into: into) {
                    return .failure(status)
                }
                size += piece
                switch reader.line(most: 2) {
                case let .success(line) where line.isEmpty: break
                case .success: return .failure(400)
                case let .failure(status): return .failure(status)
                }
            }
            // What may trail the last piece: read to the empty line, not used — a little of it, not a stream of lines.
            var trailing = 0
            for _ in 0 ..< trailerLines {
                switch reader.line(most: 1024) {
                case let .success(line) where line.isEmpty: return .success(size)
                case let .success(line):
                    trailing += line.utf8.count + 2
                    guard trailing <= trailerMost else { return .failure(431) }
                case let .failure(status): return .failure(status)
                }
            }
            return .failure(431)
        }
        switch length(request) {
        case let .success(length):
            let length = length ?? 0
            guard length <= most else { return .failure(413) }
            return reader.pass(length, into: into).map {
                length
            }
        case let .failure(status): return .failure(status)
        }
    }

    // MARK: - Answering

    static func reason(_ status: Int) -> String {
        [
            200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
            405: "Method Not Allowed", 408: "Request Timeout", 409: "Conflict", 411: "Length Required",
            413: "Content Too Large", 507: "Insufficient Storage",
            431: "Request Header Fields Too Large", 501: "Not Implemented", 503: "Service Unavailable",
            505: "HTTP Version Not Supported",
        ][status] ?? ""
    }

    static func respond(_ fd: Int32, _ status: Int, _ extra: String = "", _ body: String = "") {
        let kind = body.hasPrefix("{") ? "application/json" : "text/plain; charset=utf-8"
        let head =
            "HTTP/1.1 \(status) \(reason(status))\r\nContent-Type: \(kind)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\(extra)\r\n"
        let bytes = Array((head + body).utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes {
                send(fd, $0.baseAddress, $0.count, 0)
            }
            if n < 0, errno == EINTR {
                continue
            }
            guard n > 0 else { return }
            sent += n
        }
    }

    /// A JSON-RPC error (with no id where the request can't be read: what the MCP SDKs do).
    static func rpcError(_ id: Any, _ code: Int, _ message: String) -> String {
        json(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    static func json(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
    }

    /// The time of day in UTC, as a cloud's logs give it.
    static func clock() -> String {
        let s = Int(Date().timeIntervalSince1970) % 86400
        return String(format: "%02d:%02d:%02d UTC", s / 3600, s / 60 % 60, s % 60)
    }

    /// Whether the caller's connection is closed or broken. Nothing more is due from a caller once its request is
    /// in, so a read that ends, or fails, says so (one that only shut its own side is taken as gone too).
    static func closed(_ fd: Int32) -> Bool {
        var byte: UInt8 = 0
        let n = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
    }

    /// What the caller still sends after its answer is read and dropped for a moment before the connection closes:
    /// closed with it unread, the system resets the connection, and the caller can lose its answer.
    static func linger(_ fd: Int32) {
        shutdown(fd, SHUT_WR)
        let until = Date().addingTimeInterval(1)
        var left = bodyMost
        var rest = [UInt8](repeating: 0, count: 8192)
        while left > 0, until.timeIntervalSinceNow > 0 {
            var wanted = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&wanted, 1, 250) > 0 else { break }
            let n = recv(fd, &rest, rest.count, 0)
            guard n > 0 else { break }
            left -= n
        }
    }

    // MARK: - The server

    let allowed: [Allow]
    let token: String?
    let ownIP: String
    let ownID: String
    let hosts: [String]
    let whois: @Sendable (String) -> Result<Whois, Failure>
    /// One JSON-RPC message in, its answer out (nil for a notification), asked of the app with the `Asking` given,
    /// which is given up when the caller goes or takes the call back.
    let handle: @Sendable (Data, DeviceControlWire.Asking) -> Data?
    /// The device a tool call's arguments name, as its turn is kept; nil: answered at once (no such device).
    let turnOf: @Sendable ([String: Any]) -> String?
    let headWithin: TimeInterval
    /// With `--allow-install`: what `PUT /upload` keeps, for `install`.
    let uploads: Uploads?

    private let lock = NSLock()
    private var turns: [String: DispatchQueue] = [:]
    private var cancelled: [(session: String, id: String, at: Date)] = []
    private var open: [String: Int] = [:]
    private var turningAway = 0

    init(
        allowed: [Allow],
        token: String?,
        ownIP: String,
        ownID: String,
        hosts: [String],
        headWithin: TimeInterval = headWithin,
        uploads: Uploads? = nil,
        whois: @escaping @Sendable (String) -> Result<Whois, Failure>,
        handle: @escaping @Sendable (Data, DeviceControlWire.Asking) -> Data?,
        turnOf: @escaping @Sendable ([String: Any]) -> String?
    ) {
        self.allowed = allowed
        self.token = token
        self.ownIP = ownIP
        self.ownID = ownID
        self.hosts = hosts
        self.headWithin = headWithin
        self.uploads = uploads
        self.whois = whois
        self.handle = handle
        self.turnOf = turnOf
    }

    /// A listening socket on `ip` (IPv4) and `port`, and the port it got.
    static func listen(ip: String, port: UInt16) throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "no socket") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else {
            close(fd)
            throw Failure(description: "\(ip) isn't an IPv4 address")
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 128) == 0 else {
            let why = errno
            close(fd)
            switch why {
            case EADDRINUSE: throw Failure(description: "port \(port) is taken on \(ip)")
            case EADDRNOTAVAIL: throw Failure(
                    description: "can't listen on \(ip): this Mac's Tailscale gives it no address of its own to listen on"
                )
            default: throw Failure(description: "can't listen on \(ip):\(port): \(String(cString: strerror(why)))")
            }
        }
        var got = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &size)
            }
        }
        return (fd, UInt16(bigEndian: got.sin_port))
    }

    /// Takes connections until the socket is closed, each on a thread of its own.
    func serve(_ listener: Int32) {
        while true {
            var from = sockaddr_in()
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let fd = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listener, $0, &size)
                }
            }
            guard fd >= 0 else {
                if errno == EBADF || errno == EINVAL {
                    return
                }
                if errno != EINTR, errno != ECONNABORTED {
                    usleep(100_000) // too many files open, say: not tried again at once, over and over
                }
                continue
            }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var wait = timeval(tv_sec: Int(Self.writeWithin), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var address = from.sin_addr
            let ip = inet_ntop(AF_INET, &address, &text, socklen_t(text.count)).map {
                String(cString: $0)
            } ?? "?"
            let taken = lock.withLock { () -> Bool in
                let full = open.values.reduce(0, +) >= Self.atOnce || open[ip, default: 0] >= Self.fromOne
                if !full {
                    open[ip, default: 0] += 1
                }
                return !full
            }
            guard taken else {
                // Answered aside, so that waiting for what it sends doesn't hold up the next.
                let answering = lock.withLock { () -> Bool in
                    turningAway += 1
                    return turningAway <= Self.turningAwayMost
                }
                guard answering else {
                    lock.withLock {
                        turningAway -= 1
                    }
                    close(fd)
                    continue
                }
                Self.thread {
                    Self.respond(fd, 503, "", "too many connections at once\n")
                    Self.linger(fd)
                    close(fd)
                    self.lock.withLock {
                        self.turningAway -= 1
                    }
                }
                continue
            }
            Self.thread {
                self.connection(fd, from: ip)
                close(fd)
                self.lock.withLock {
                    self.open[ip, default: 1] -= 1
                    if self.open[ip] == 0 {
                        self.open[ip] = nil
                    }
                }
            }
        }
    }

    static func thread(_ work: @escaping @Sendable () -> Void) {
        let thread = Thread(block: work)
        thread.stackSize = stack
        thread.start()
    }

    /// A line on standard error; one that can't be written (its reader gone) is dropped.
    static func note(_ line: String) {
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
    }

    /// One request, from its head to its answer, and its line in the log. Never logged: the token, a body, what is
    /// typed or pasted, what is shown.
    func connection(_ fd: Int32, from ip: String) {
        let began = Date()
        var who = "-", what = "-"
        let outcome = served(fd, from: ip, began: began, who: &who, what: &what)
        let line =
            "\(Self.clock()) \(ip) \(Self.printable(who)) \(Self.printable(what)) \(outcome) \(String(format: "%.1f", Date().timeIntervalSince(began)))s\n"
        Self.note(line)
        Self.linger(fd)
    }

    private func served(_ fd: Int32, from ip: String, began: Date, who: inout String, what: inout String) -> String {
        let reader = Reader(fd: fd, until: began.addingTimeInterval(headWithin))
        func refuse(_ refused: Refused, _ extra: String = "", _ body: String = "") -> String {
            Self.respond(fd, refused.status, extra, body)
            return "\(refused.status)"
        }
        let request: Request
        switch Self.head(reader) {
        case let .success(read): request = read
        case let .failure(status): return refuse(status)
        }
        what = "\(request.method) \(request.path)"
        // Where a client looks for OAuth: nothing, before anything is asked of it, so that it doesn't start that.
        if request.path.hasPrefix("/.well-known/") || request.path == "/register" {
            return refuse(404)
        }
        // A browser's: a page on some site isn't let in by its viewer's place on the tailnet.
        if request.header("origin") != nil {
            return refuse(403)
        }
        guard let host = request.header("host"), hosts.contains(where: {
            $0.caseInsensitiveCompare(host) == .orderedSame
        }) else { return refuse(400, "", "the Host isn't this server's address or name\n") }
        let presented = request.header("authorization").flatMap { value -> String? in
            let parts = value.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].caseInsensitiveCompare("bearer") == .orderedSame else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        let tokenCame = token.map { token in
            presented.map {
                Self.same(token, $0)
            } ?? false
        } ?? false
        if token != nil, !tokenCame {
            return refuse(401, "WWW-Authenticate: Bearer\r\n")
        }
        let caller: Whois
        switch whois(ip) {
        case let .success(said): caller = said
        // Not known to be refused: a 403 would tell the caller not to try again.
        case let .failure(why):
            who = "(whois: \(why))"
            return refuse(503, "", "the caller couldn't be looked up (tailscale whois): try again\n")
        }
        let own = ip == ownIP || (!ownID.isEmpty && caller.id == ownID)
        switch Self.judged(caller, allowed: allowed, own: own, token: tokenCame) {
        case let .success(name): who = name
        case let .failure(why):
            who = why.description
            return refuse(403)
        }
        if request.path == "/upload" {
            guard let uploads else { return refuse(404) }
            guard request.method == "PUT" else { return refuse(405, "Allow: PUT\r\n") }
            // Tied to the caller by its lasting id: none, no upload.
            guard !caller.id.isEmpty else { return refuse(403) }
            let length: Int?
            switch Self.length(request) {
            case let .success(said): length = said
            case let .failure(refused): return refuse(refused)
            }
            // Refused before the slot is taken, which lets go of the one kept.
            if let coding = request.header("transfer-encoding") {
                guard coding.caseInsensitiveCompare("chunked") == .orderedSame else { return refuse(501) }
            } else if length == nil {
                return refuse(411)
            }
            let tooBig = "\(uploads.most >> 20) MiB at most: the server's --max-upload sets it\n"
            if let length, length > uploads.most {
                return refuse(413, "", tooBig)
            }
            guard uploads.begin()
            else { return refuse(409, "", "another upload is coming in: try again once it is in\n") }
            defer { uploads.done() }
            if request.header("expect")?.caseInsensitiveCompare("100-continue") == .orderedSame {
                let go = Array("HTTP/1.1 100 Continue\r\n\r\n".utf8)
                _ = send(fd, go, go.count, 0)
            }
            switch uploads.receive(reader, request, owner: caller.id) {
            case let .success(answer):
                Self.respond(fd, 200, "", answer)
                return "ok"
            case let .failure(refused):
                Self.respond(fd, refused.status, "", refused.status == 413 ? tooBig : "")
                return "\(refused.status)"
            }
        }
        guard request.path == "/mcp" else { return refuse(404) }
        guard request.method == "POST" else { return refuse(405, "Allow: POST\r\n") }
        if let version = request.header("mcp-protocol-version"), !DeviceMCP.versions.contains(version) {
            return refuse(400, "", Self.rpcError(
                NSNull(),
                -32000,
                "Bad Request: Unsupported protocol version: \(version) (supported: \(DeviceMCP.versions.joined(separator: ", ")))"
            ))
        }
        reader.until = Date().addingTimeInterval(Self.bodyWithin)
        if request.header("expect")?.caseInsensitiveCompare("100-continue") == .orderedSame {
            let go = Array("HTTP/1.1 100 Continue\r\n\r\n".utf8)
            _ = send(fd, go, go.count, 0)
        }
        let body: [UInt8]
        switch Self.body(reader, request, most: Self.bodyMost) {
        case let .success(read): body = read
        case let .failure(status): return refuse(status)
        }
        guard let read = try? JSONSerialization.jsonObject(with: Data(body), options: .fragmentsAllowed) else {
            return refuse(400, "", Self.rpcError(NSNull(), -32700, "not JSON"))
        }
        guard let message = read as? [String: Any] else {
            return refuse(400, "", Self.rpcError(NSNull(), -32600, "one message a request, as an object"))
        }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        switch method {
        case "tools/call": what = "tools/call \(params["name"] as? String ?? "?")"
        case "": what = "a response"
        default: what = method
        }
        // Given at initialize (a client that initialized sends it on): what a call is taken back within.
        let session = request.header("mcp-session-id").flatMap {
            (1 ... 128).contains($0.utf8.count) && $0.utf8.allSatisfy {
                (0x21 ... 0x7E).contains($0)
            } ? $0 : nil
        }
        let response = method.isEmpty && (message["result"] != nil || message["error"] != nil)
        guard let id = message["id"], !response else {
            // A notification or a response: nothing to answer. `notifications/cancelled` takes back the call of that
            // id in its session; without one it does nothing (another client's call could carry the same id).
            if method == "notifications/cancelled", let session, let taken = params["requestId"],
               Self.requestID(taken)
            {
                takeBack(session: session, id: DeviceMCP.name(taken))
            }
            return refuse(202)
        }
        if method.isEmpty {
            return refuse(400, "", Self.rpcError(id, -32600, "no method"))
        }
        // An install from another's upload, or one not as it was sent, is refused before it waits its turn.
        if let uploads, method == "tools/call", params["name"] as? String == "install",
           let upload = arguments["upload"] as? String,
           let why = uploads.refusal(id: upload, owner: caller.id, sha256: arguments["sha256"] as? String ?? "")
        {
            Self.respond(fd, 200, "", Self.json([
                "jsonrpc": "2.0",
                "id": id,
                "result": ["content": [["type": "text", "text": why]], "isError": true],
            ]))
            return "error"
        }
        let line = Data(body)
        guard method == "tools/call", let device = turnOf(arguments) else {
            // Asks nothing of a device (`devices`, `initialize`, a device not saved): answered at once. An initialize
            // is given a session id, sent back with what follows.
            let answer = handle(line, DeviceControlWire.Asking()).flatMap {
                String(data: $0, encoding: .utf8)
            } ?? ""
            var given = ""
            if method == "initialize" {
                var bytes = [UInt8](repeating: 0, count: 16)
                arc4random_buf(&bytes, bytes.count)
                given = "Mcp-Session-Id: \(bytes.map { String(format: "%02x", $0) }.joined())\r\n"
            }
            return refuse(200, given, answer)
        }
        var givenUp = false
        guard let answer = take(
            turnOn: device,
            session: session,
            id: DeviceMCP.name(id),
            rpcID: id,
            line: line,
            fd: fd,
            givenUp: &givenUp
        )
        else { return "not begun" }
        let failed =
            ((try? JSONSerialization.jsonObject(with: answer) as? [String: Any])?["result"] as? [String: Any])?[
                "isError"
            ] as? Bool == true
        Self.respond(fd, 200, "", String(data: answer, encoding: .utf8) ?? "")
        // Its caller went, or took it back, while it was at the app: what it answers is no failure of the call's own.
        return givenUp ? "given up" : failed ? "error" : "ok"
    }

    /// A request id as MCP has one: a number, or text, and not a long one.
    static func requestID(_ id: Any) -> Bool {
        if let n = id as? NSNumber {
            return CFGetTypeID(n) != CFBooleanGetTypeID()
        }
        return (id as? String).map {
            $0.utf8.count <= 128
        } ?? false
    }

    /// Kept a while (an id isn't used twice in a session): `cancelsMost` at most, so that a flood doesn't push out another's.
    private func takeBack(session: String, id: String) {
        lock.withLock {
            cancelled.removeAll {
                Date().timeIntervalSince($0.at) >= Self.takenBackFor
            }
            if cancelled.count < Self.cancelsMost {
                cancelled.append((session, id, Date()))
            }
        }
    }

    /// The call, in its turn on the device: nil where it isn't begun (taken back in its session, or its caller's
    /// connection closed, before its turn). One that waited too long is answered so, and not begun.
    private func take(
        turnOn device: String,
        session: String?,
        id: String,
        rpcID: Any,
        line: Data,
        fd: Int32,
        givenUp: inout Bool
    ) -> Data? {
        let queue = lock.withLock { () -> DispatchQueue in
            if let queue = turns[device] {
                return queue
            }
            let queue = DispatchQueue(label: "roamrun.mcp.http.\(device)")
            turns[device] = queue
            return queue
        }
        let came = Date()
        let rpcID = rpcID as? NSNumber ?? (rpcID as? String).map {
            $0 as NSString
        } ?? NSNull()
        return queue.sync { () -> Data? in
            let takenBack = session.map { session in
                lock.withLock {
                    cancelled.removeAll {
                        Date().timeIntervalSince($0.at) >= Self.takenBackFor
                    }
                    return cancelled.contains {
                        $0.session == session && $0.id == id
                    }
                }
            } ?? false
            if takenBack || Self.closed(fd) {
                return nil
            }
            if Date().timeIntervalSince(came) > Self.turnWithin {
                let busy = "not begun: another call held the device for more than \(Int(Self.turnWithin)) s. Look before trying again"
                return Self.json([
                    "jsonrpc": "2.0",
                    "id": rpcID,
                    "result": ["content": [["type": "text", "text": busy]], "isError": true],
                ])
                .data(using: .utf8)
            }
            // Given up when the caller goes or takes it back: one still waiting at the app (behind another client
            // of the device) isn't begun there, and one under way stops where it can, as with stdio.
            let asking = DeviceControlWire.Asking()
            let done = DispatchSemaphore(value: 0)
            Self.thread { [weak self] in
                while done.wait(timeout: .now() + 0.3) == .timedOut {
                    let takenBack = session.map { session in
                        self?.lock.withLock {
                            self?.cancelled.contains {
                                $0.session == session && $0.id == id
                            } ?? false
                        } ?? false
                    } ?? false
                    if takenBack || Self.closed(fd) {
                        asking.giveUp()
                        return
                    }
                }
            }
            defer { done.signal() }
            let answer = handle(line, asking)
            givenUp = asking.givenUp
            return answer
        }
    }
}

/// The signal sources of a server with uploads, kept for as long as the process runs.
nonisolated(unsafe) private var stopping: [DispatchSourceSignal] = []

extension MCPHTTP {
    /// `roamrun mcp --http <port> --allow <who>… [--token-file <file>]`, ready to serve: on this Mac's Tailscale
    /// IPv4 address only; not without Tailscale, without `--allow`, or as root. The server, its socket, and what to
    /// tell the person who started it.
    static func start(
        port given: String,
        allow: [String],
        tokenFile: String?,
        allowInstall: Bool = false,
        maxUpload: String? = nil
    ) throws -> (MCPHTTP, Int32, String) {
        // A log read through a pipe whose reader went: the write fails, the server goes on.
        signal(SIGPIPE, SIG_IGN)
        guard geteuid() != 0
        else { throw Failure(description: "not as root: start it as the user whose devices it offers") }
        guard let port = UInt16(given), port > 0 else { throw Failure(description: "--http takes a port, 1...65535") }
        guard !allow.isEmpty else {
            throw Failure(
                description: "who may call: --allow tag:<name> (a tagged machine, such as a cloud's) or --allow <login> (a person's own machines)"
            )
        }
        let allowed = try allow.map(Self.allow)
        let token = try tokenFile.map(Self.token(at:))
        guard maxUpload == nil || allowInstall
        else { throw Failure(description: "--max-upload goes with --allow-install") }
        let mib = try maxUpload.map {
            guard let mib = Int($0), (1 ... 4096).contains(mib)
            else { throw Failure(description: "--max-upload takes MiB, 1...4096") }
            return mib
        } ?? 1024
        let mesh: TailscaleClient.Mesh
        do { mesh = try TailscaleClient.fromSettings().mesh() } catch {
            throw Failure(description: error.localizedDescription)
        }
        guard let own = mesh.ownIPs.first(where: {
            !$0.contains(":")
        }) else { throw Failure(description: "this Mac has no IPv4 address on the tailnet") }
        let (fd, bound) = try listen(ip: own, port: port)
        let dns = mesh.ownDNSName.hasSuffix(".") ? String(mesh.ownDNSName.dropLast()) : mesh.ownDNSName
        let names = [dns, dns.split(separator: ".").first.map(String.init) ?? ""].filter {
            !$0.isEmpty
        }
        let folder = DeviceControlWire.socketFolder(in: ProfileStore.directory)
        let uploads = allowInstall ? Uploads(folder: folder, most: mib << 20) : nil
        if let uploads {
            // At stop, what was uploaded goes: Ctrl-C, and what a closed terminal sends.
            for stop in [SIGINT, SIGTERM, SIGHUP] {
                // One ignored already (nohup's SIGHUP) still doesn't end it.
                guard unsafeBitCast(signal(stop, SIG_IGN), to: Int.self) != unsafeBitCast(SIG_IGN, to: Int.self)
                else { continue }
                let source = DispatchSource.makeSignalSource(signal: stop, queue: .global())
                source.setEventHandler {
                    uploads.end()
                    exit(128 + stop)
                }
                source.resume()
                stopping.append(source)
            }
            Thread.detachNewThread {
                while true {
                    Thread.sleep(forTimeInterval: 60)
                    uploads.sweep()
                }
            }
        }
        let server = MCPHTTP(
            allowed: allowed,
            token: token,
            ownIP: own,
            ownID: mesh.ownID,
            hosts: hosts(ip: own, names: names, port: bound),
            uploads: uploads,
            whois: { ip in
                do {
                    guard let said = whois(fromJSON: try TailscaleClient.fromSettings().whoisJSON(of: ip)) else {
                        return .failure(Failure(description: "tailscale whois wasn't readable"))
                    }
                    return .success(said)
                } catch {
                    return .failure(Failure(description: error.localizedDescription))
                }
            },
            handle: { message, asking in
                // Each call its own asking: one taken back gives up its own request to the app alone.
                DeviceMCP(profiles: {
                    ProfileStore().load()
                }, looks: folder, installsFromPaths: false, claimUpload: uploads.map { uploads in
                    { id, sha256 in
                        try uploads.claim(id: id, sha256: sha256, into: folder)
                    }
                }, asking: asking) {
                    try DeviceControlWire.ask($0, in: ProfileStore.directory, asking: asking)
                }.handle(message)
            },
            turnOf: { arguments in
                guard let name = arguments["device"] as? String else { return nil }
                let named = ProfileStore().load().filter {
                    $0.displayName.caseInsensitiveCompare(name) == .orderedSame
                }
                return named.count == 1 ? named[0].id.uuidString : nil
            }
        )
        let who = allow.joined(separator: ", ")
        let install = uploads == nil ? "" : "; install of an .ipa sent to http://\(own):\(bound)/upload, \(mib) MiB at most"
        let note =
            "roamrun: the MCP tools for the devices saved in RoamRun at http://\(own):\(bound)/mcp, for \(who) on the tailnet\(token == nil ? "" : ", with the token")\(install). Ctrl-C ends it. What is sent and shown passes through whatever lies between (a cloud's proxy sees images and text)."
        return (server, fd, note)
    }
}
