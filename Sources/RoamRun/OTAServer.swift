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
    private var open = 0

    private func closed() { lock.withLock { open = max(0, open - 1) } }
    private let queue = DispatchQueue(label: "roamrun.ota")
    private var _listener: NWListener?
    private var listener: NWListener? {
        get { lock.withLock { _listener } }
        set { lock.withLock { _listener = newValue } }
    }
    /// What the device sees in front of us, e.g. `/roamrun`. Requests arrive
    /// without it (tailscale strips the mount), but the manifest has to hand iOS
    /// an absolute URL, so it goes back on.
    let prefix: String
    private var _port: UInt16 = 0
    private(set) var port: UInt16 {
        get { lock.withLock { _port } }
        set { lock.withLock { _port = newValue } }
    }

    init(prefix: String) { self.prefix = prefix }

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
            case .failed, .cancelled: ready.signal()
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
    }

    // MARK: - One request

    /// Enough for a phone and a laptop at once; past that something is wrong and
    /// the menu bar app's descriptors matter more than the extra download.
    private static let maxConnections = 8
    private static let idleLimit: TimeInterval = 120

    private func serve(_ conn: NWConnection) {
        let accepted = lock.withLock { () -> Bool in
            guard open < Self.maxConnections else { return false }
            open += 1
            return true
        }
        guard accepted else { conn.cancel(); return }
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            switch state {
            case .failed: conn?.cancel()        // always ends at .cancelled, so `closed` runs once
            case .cancelled: self?.closed()
            default: break
            }
        }
        // A peer that stops reading would otherwise hold a file handle and a
        // chunk of an .ipa until the app quits. Time without progress, not time
        // altogether: this exists for slow cellular, where a big .ipa legitimately
        // takes a long while.
        let idle = IdleTimer(queue: queue) { conn.cancel() }
        idle.arm(Self.idleLimit)
        conn.start(queue: queue)
        readHead(conn, soFar: Data(), idle: idle)
    }

    /// Until the blank line that ends the head. One `receive` can stop in the
    /// middle of it, and a request line without its `Host` would make every link
    /// in the manifest point the device at itself.
    private func readHead(_ conn: NWConnection, soFar: Data, idle: IdleTimer) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, _ in
            guard let self, let data, !data.isEmpty else { conn.cancel(); return }
            let head = soFar + data
            guard head.count <= 32 * 1024 else { return self.send(conn, status: "431 Request Header Fields Too Large") }
            guard let text = String(data: head, encoding: .utf8), text.contains("\r\n\r\n") else {
                guard !done else { conn.cancel(); return }
                idle.arm(Self.idleLimit)
                return self.readHead(conn, soFar: head, idle: idle)
            }
            let (method, path, host) = Self.request(text)
            guard method == "GET" || method == "HEAD" else { return self.send(conn, status: "405 Method Not Allowed") }
            let base = "https://\(host)\(self.prefix)"
            self.route(conn, path: path, base: base, bodyWanted: method == "GET", idle: idle)
        }
    }

    /// (method, path, host). The path is whatever came in; `resolve` decides
    /// whether it names anything we serve.
    static func request(_ head: String) -> (String, String, String) {
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        let parts = (lines.first ?? "").split(separator: " ")
        let host = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("host:") }?
            .dropFirst("host:".count).trimmingCharacters(in: .whitespaces) ?? "localhost"
        let path = parts.count > 1 ? String(parts[1]).split(separator: "?").first.map(String.init) ?? "/" : "/"
        return (parts.first.map(String.init) ?? "", path, host)
    }

    private func route(_ conn: NWConnection, path: String, base: String, bodyWanted: Bool, idle: IdleTimer) {
        let parts = Self.segments(path)
        switch parts.count {
        case 0:
            let html = OTA.indexHTML(OTA.builds(), base: base)
            send(conn, status: "200 OK", type: "text/html; charset=utf-8", body: bodyWanted ? Data(html.utf8) : nil,
                 length: Int64(Data(html.utf8).count))
        case 3 where parts[2] == "icon.png":
            let url = OTA.directory.appendingPathComponent(parts[0]).appendingPathComponent(parts[1])
                .appendingPathComponent("icon.png")
            guard let png = try? Data(contentsOf: url) else { return send(conn, status: "404 Not Found") }
            send(conn, status: "200 OK", type: "image/png", body: bodyWanted ? png : nil, length: Int64(png.count))
        case 3 where parts[2] == "manifest.plist" || parts[2] == "app.ipa":
            guard let build = OTA.builds(of: parts[0]).first(where: { $0.slug == parts[1] }) else {
                return send(conn, status: "404 Not Found")
            }
            if parts[2] == "manifest.plist" {
                let data = OTA.manifest(for: build, base: base)
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
            .filter { $0 != "." && $0 != ".." && !$0.contains("\0") && !$0.contains("/") }
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
        // even if the file is replaced a moment later.
        let size = Int64((try? handle.seekToEnd()) ?? 0)
        try? handle.seek(toOffset: 0)
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
