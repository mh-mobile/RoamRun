import Foundation
import Network

/// Serves the OTA page, the manifests and the .ipa files on loopback, for
/// `tailscale serve` to put behind HTTPS. Tailscale can serve a directory
/// itself, but only as root; proxying to a port needs no privilege.
///
/// Deliberately small: GET and HEAD, no ranges, no keep-alive. The only client
/// is iOS installing a build from the tailnet.
final class OTAServer: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "roamrun.ota")
    private var _listener: NWListener?
    private var listener: NWListener? {
        get { lock.withLock { _listener } }
        set { lock.withLock { _listener = newValue } }
    }
    /// What the device sees in front of us, e.g. `/roamrun`. Requests arrive
    /// without it (tailscale strips the mount), but the manifest has to hand iOS
    /// an absolute URL, so it goes back on.
    private let prefix: String
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
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.port = listener.port?.rawValue ?? 0; ready.signal()
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

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let head = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let (method, path, host) = Self.request(head)
            guard method == "GET" || method == "HEAD" else { return self.send(conn, status: "405 Method Not Allowed") }
            let base = "https://\(host)\(self.prefix)"
            self.route(conn, path: path, base: base, bodyWanted: method == "GET")
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

    private func route(_ conn: NWConnection, path: String, base: String, bodyWanted: Bool) {
        let parts = Self.segments(path)
        switch parts.count {
        case 0:
            let html = OTA.indexHTML(OTA.builds(), base: base)
            send(conn, status: "200 OK", type: "text/html; charset=utf-8", body: bodyWanted ? Data(html.utf8) : nil,
                 length: Int64(Data(html.utf8).count))
        case 3 where parts[2] == "manifest.plist" || parts[2] == "app.ipa":
            guard let build = OTA.builds(of: parts[0]).first(where: { $0.slug == parts[1] }) else {
                return send(conn, status: "404 Not Found")
            }
            if parts[2] == "manifest.plist" {
                let data = OTA.manifest(for: build, base: base)
                send(conn, status: "200 OK", type: "application/xml", body: bodyWanted ? data : nil, length: Int64(data.count))
            } else {
                sendIPA(conn, at: OTA.directory.appendingPathComponent(parts[0]).appendingPathComponent(parts[1])
                    .appendingPathComponent("app.ipa"), bodyWanted: bodyWanted)
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
    private func sendIPA(_ conn: NWConnection, at url: URL, bodyWanted: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return send(conn, status: "404 Not Found") }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
        guard bodyWanted else {
            try? handle.close()
            return send(conn, status: "200 OK", type: "application/octet-stream", length: size)
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n" +
            "Content-Length: \(size)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil else { try? handle.close(); conn.cancel(); return }
            self?.pump(conn, handle)
        })
    }

    private func pump(_ conn: NWConnection, _ handle: FileHandle) {
        let chunk = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        guard !chunk.isEmpty else {
            try? handle.close()
            conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
            return
        }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil else { try? handle.close(); conn.cancel(); return }
            self?.pump(conn, handle)
        })
    }
}
