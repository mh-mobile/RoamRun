import Foundation
import Network

/// Cancels after a stretch with nothing sent, rearmed by every chunk that gets
/// through, so a slow download isn't mistaken for a stalled one.
private final class IdleTimer: @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let fire: () -> Void
    private var pending: DispatchWorkItem?

    init(queue: DispatchQueue, fire: @escaping () -> Void) {
        self.queue = queue
        self.fire = fire
    }

    func arm(_ seconds: TimeInterval) {
        let work = DispatchWorkItem { [fire] in fire() }
        lock.withLock {
            pending?.cancel()
            pending = work
        }
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// Serves the OTA page, the manifests and the .ipa files on loopback, for
/// `tailscale serve` to put behind HTTPS. Tailscale can serve a directory
/// itself, but only as root; proxying to a port needs no privilege.
///
/// Deliberately small: GET and HEAD, no ranges, no keep-alive. The only client
/// is iOS installing a build from the tailnet.
final class OTAServer: @unchecked Sendable {
    private let lock = NSLock()
    private var live: [ObjectIdentifier: NWConnection] = [:]

    private func closed(_ conn: NWConnection) { lock.withLock { live[ObjectIdentifier(conn)] = nil } }
    private let queue = DispatchQueue(label: "roamrun.ota")
    private var _listener: NWListener?
    private var listener: NWListener? {
        get { lock.withLock { _listener } }
        set { lock.withLock { _listener = newValue } }
    }
    /// The tailnet port `tailscale serve` publishes us on. Kept only so the
    /// coordinator can tell whether a running server is on the port configured
    /// now; URLs come from each request's Host header, which carries the port.
    let tailnetPort: Int
    private var _port: UInt16 = 0
    private(set) var port: UInt16 {
        get { lock.withLock { _port } }
        set { lock.withLock { _port = newValue } }
    }

    init(tailnetPort: Int) { self.tailnetPort = tailnetPort }

    /// The MagicDNS name `tailscale serve` publishes us under; nil until it is known.
    /// Anything else in Host is not a request from the tailnet: a page on this
    /// Mac rebinding its own name to 127.0.0.1, say, would otherwise read the builds.
    private var _servedName: String?
    var servedName: String? {
        get { lock.withLock { _servedName } }
        set { lock.withLock { _servedName = newValue.map(Self.canonical) } }
    }

    /// The port it ended up on; nil if it couldn't listen at all.
    @discardableResult
    func start() -> UInt16? {
        guard listener == nil else { return port }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: params) else { return nil }
        listener.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready: self?.port = listener?.port?.rawValue ?? 0; ready.signal()
            case .failed, .cancelled:
                // Also after it was ready: leaving the port set would make start()
                // hand back a dead one for ever, with `tailscale serve` still
                // pointing at it. Cleared, the next check builds a new listener.
                self?.forget(listener)
                ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        _ = ready.wait(timeout: .now() + 5)
        guard port > 0 else { stop(); return nil }
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
        // Cancelling the listener only stops new ones. A download in flight would
        // otherwise sit there until the idle timer, because `pump` holds `self`
        // weakly and the chain simply stops when the server goes.
        for conn in lock.withLock({ Array(live.values) }) { conn.cancel() }
    }

    /// Whether there is still a listener behind the port `tailscale serve` was
    /// told about. False after one failed post-ready, which nothing else notices.
    var listening: Bool { lock.withLock { _listener != nil && _port > 0 } }

    /// Only if it is still the one we are using: a cancelled listener's late
    /// callback must not wipe the replacement.
    private func forget(_ gone: NWListener?) {
        lock.withLock {
            guard _listener === gone else { return }
            _listener = nil
            _port = 0
        }
    }

    // MARK: - One request

    /// Enough for a phone and a laptop at once; past that something is wrong and
    /// the menu bar app's descriptors matter more than the extra download.
    private static let maxConnections = 8
    private static let idleLimit: TimeInterval = 120
    /// The whole head, not time between bytes: one byte every 119 s would keep an
    /// idle timer happy for ever, and eight of those are every connection there is.
    private static let headLimit: TimeInterval = 15

    private func serve(_ conn: NWConnection) {
        let accepted = lock.withLock { () -> Bool in
            guard live.count < Self.maxConnections else { return false }
            live[ObjectIdentifier(conn)] = conn
            return true
        }
        guard accepted else { conn.cancel(); return }
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            switch state {
            case .failed: conn?.cancel()        // always ends at .cancelled, so `closed` runs once
            case .cancelled: if let conn { self?.closed(conn) }
            default: break
            }
        }
        // A peer that stops reading would otherwise hold a file handle and a
        // chunk of an .ipa until the app quits. Time without progress, not time
        // altogether: this exists for slow cellular, where a big .ipa legitimately
        // takes a long while.
        let idle = IdleTimer(queue: queue) { conn.cancel() }
        // Armed to the head's deadline, not the idle limit: a peer that connects
        // and never sends produces no callback to check a deadline in, and eight
        // of those are every connection there is. `pump` re-arms it to the idle
        // limit once a body is going out, where slow really is only slow.
        idle.arm(Self.headLimit)
        conn.start(queue: queue)
        readHead(conn, soFar: Data(), scanned: 0, idle: idle, by: DispatchTime.now() + Self.headLimit)
    }

    /// Until the blank line that ends the head. One `receive` can stop in the
    /// middle of it, and a request line without its `Host` would make every link
    /// in the manifest point the device at itself.
    private func readHead(_ conn: NWConnection, soFar: Data, scanned: Int,
                          idle: IdleTimer, by deadline: DispatchTime) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, _ in
            guard let self, let data, !data.isEmpty else { conn.cancel(); return }
            let head = soFar + data
            guard head.count <= 32 * 1024 else { return self.send(conn, status: "431 Request Header Fields Too Large") }
            // Only the bytes that are new, less the three the terminator could
            // straddle. A peer sending one byte at a time would otherwise have the
            // whole buffer rescanned each time, which is quadratic in what it sends.
            let from = max(0, scanned - 3)
            guard let cut = Self.endOfHead(head, from: from) else {
                guard !done else { conn.cancel(); return }
                let now = DispatchTime.now()
                guard now < deadline else { return self.send(conn, status: "408 Request Timeout") }
                idle.arm(Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1e9)
                return self.readHead(conn, soFar: head, scanned: head.count, idle: idle, by: deadline)
            }
            // Lossy on purpose: one byte that isn't UTF-8 used to mean the request
            // was never answered and the slot was held until the idle timer.
            let (method, path, host) = Self.request(String(decoding: head[head.startIndex..<cut], as: UTF8.self))
            guard method == "GET" || method == "HEAD" else { return self.send(conn, status: "405 Method Not Allowed") }
            // Without it every link in the manifest would point the device at
            // itself, and the install would fail with nothing to go on.
            guard let host else { return self.send(conn, status: "400 Bad Request") }
            guard Self.isServedName(host, servedName: self.servedName) else {
                return self.send(conn, status: "421 Misdirected Request")
            }
            let base = "https://\(host)"   // Host carries the port serve published us on
            self.route(conn, path: path, base: base, bodyWanted: method == "GET", idle: idle)
        }
    }

    /// Where the blank line that ends the head begins, searching only from `from`.
    static func endOfHead(_ head: Data, from: Int = 0) -> Data.Index? {
        let marker = Data("\r\n\r\n".utf8)
        guard head.count >= marker.count, from <= head.count - marker.count else { return nil }
        let start = head.index(head.startIndex, offsetBy: from)
        return head[start...].firstRange(of: marker)?.lowerBound
    }

    /// (method, path, host). The path is whatever came in; `resolve` decides
    /// whether it names anything we serve.
    static func request(_ head: String) -> (String, String, String?) {
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        let parts = (lines.first ?? "").split(separator: " ")
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        // Two of them is a request two proxies would read differently; neither is
        // iOS, so refuse rather than pick.
        let host = hosts.count == 1
            ? hosts[0].dropFirst("host:".count).trimmingCharacters(in: .whitespaces) : nil
        let path = parts.count > 1 ? String(parts[1]).split(separator: "?").first.map(String.init) ?? "/" : "/"
        return (parts.first.map(String.init) ?? "", path, host.flatMap(hostLike))
    }

    /// A name and maybe a port, and nothing else. It goes into the URLs the
    /// device is told to fetch, where `%`, `\` and `@` all mean something.
    static func hostLike(_ s: String) -> String? {
        // Not omitting empties: ":41443" would otherwise split to just the port
        // and pass as a name.
        let name = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard !s.isEmpty, s.count < 256, let first = name.first, !first.isEmpty,
              first.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              name.count == 1 || UInt16(name[1]) != nil else { return nil }
        return s
    }

    /// Host's name part is the name we are served under (case and a trailing dot
    /// aside); its port is whatever `serve` published.
    static func isServedName(_ host: String, servedName: String?) -> Bool {
        guard let servedName else { return false }
        let name = host.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return canonical(name) == servedName
    }

    private static func canonical(_ name: String) -> String {
        (name.hasSuffix(".") ? String(name.dropLast()) : name).lowercased()
    }

    private func route(_ conn: NWConnection, path: String, base: String, bodyWanted: Bool, idle: IdleTimer) {
        // The head is read; what is left of its deadline isn't the budget for
        // sending a reply. `pump` re-arms it per chunk for the long ones.
        idle.arm(Self.idleLimit)
        let parts = Self.segments(path)
        switch parts.count {
        case 0:
            // At any level, not just the top one: an empty page is a lie about a
            // folder the Mac simply couldn't open.
            guard let groups = OTA.builds() else {
                let why = Data("Can't read the builds folder on the Mac.\n".utf8)
                return send(conn, status: "503 Service Unavailable",
                            body: bodyWanted ? why : nil, length: Int64(why.count))
            }
            let html = Data(OTA.indexHTML(groups, base: base).utf8)
            send(conn, status: "200 OK", type: "text/html; charset=utf-8",
                 body: bodyWanted ? html : nil, length: Int64(html.count))
        case 3 where parts[2] == "icon.png":
            let url = OTA.directory.appendingPathComponent(parts[0]).appendingPathComponent(parts[1])
                .appendingPathComponent("icon.png")
            guard let png = try? Data(contentsOf: url) else { return send(conn, status: "404 Not Found") }
            send(conn, status: "200 OK", type: "image/png", body: bodyWanted ? png : nil, length: Int64(png.count))
        case 3 where parts[2] == "manifest.plist" || parts[2] == "app.ipa":
            guard let known = OTA.builds(of: parts[0]) else {
                return send(conn, status: "503 Service Unavailable")
            }
            guard let build = known.first(where: { $0.slug == parts[1] }) else {
                return send(conn, status: "404 Not Found")
            }
            if parts[2] == "manifest.plist" {
                guard let data = OTA.manifest(for: build, base: base) else {
                    return send(conn, status: "500 Internal Server Error")
                }
                send(conn, status: "200 OK", type: "application/xml", body: bodyWanted ? data : nil, length: Int64(data.count))
            } else {
                sendIPA(conn, at: OTA.directory.appendingPathComponent(parts[0]).appendingPathComponent(parts[1])
                    .appendingPathComponent("app.ipa"), bodyWanted: bodyWanted, idle: idle)
            }
        default:
            send(conn, status: "404 Not Found")
        }
    }

    /// Path components, with anything that could climb out of the directory gone.
    static func segments(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
            .filter { !$0.hasPrefix(".") && !$0.contains("\0") }
    }

    // MARK: - Writing

    private func send(_ conn: NWConnection, status: String, type: String = "text/plain; charset=utf-8",
                      body: Data? = nil, length: Int64 = 0) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        if let body { out.append(body) }
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Sent in pieces: an .ipa can be hundreds of megabytes and this runs inside
    /// the menu bar app.
    private func sendIPA(_ conn: NWConnection, at url: URL, bodyWanted: Bool, idle: IdleTimer) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return send(conn, status: "404 Not Found") }
        // From the handle, so it describes the bytes this connection will send
        // even if the file is replaced a moment later. `try?` here would promise
        // a length of 0 and then send the whole file, or promise the length and
        // send from the end — a body that doesn't match its header either way.
        guard let end = try? handle.seekToEnd(), (try? handle.seek(toOffset: 0)) != nil else {
            try? handle.close()
            return send(conn, status: "500 Internal Server Error")
        }
        let size = Int64(end)
        guard bodyWanted else {
            try? handle.close()
            return send(conn, status: "200 OK", type: "application/octet-stream", length: size)
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n" +
            "Content-Length: \(size)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil else { try? handle.close(); conn.cancel(); return }
            self?.pump(conn, handle, idle)
        })
    }

    private func pump(_ conn: NWConnection, _ handle: FileHandle, _ idle: IdleTimer) {
        idle.arm(Self.idleLimit)   // it is moving, so it isn't idle
        let chunk: Data
        do {
            chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
        } catch {
            // Not the end of the file: finishing cleanly here would hand iOS a
            // body shorter than the length we promised, and it would fail with
            // nothing to go on. Drop the connection instead.
            try? handle.close()
            conn.cancel()
            return
        }
        guard !chunk.isEmpty else {
            try? handle.close()
            conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
            return
        }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil else { try? handle.close(); conn.cancel(); return }
            self?.pump(conn, handle, idle)
        })
    }
}
