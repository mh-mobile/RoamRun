import Darwin
import Foundation
import Testing
@testable import RoamRun

@Test func whoMayCallOverHTTPIsATagOrALoginAndNotAMachineName() throws {
    #expect(try MCPHTTP.allow("tag:ci") == .tag("tag:ci"))
    #expect(try MCPHTTP.allow("me@example.com") == .login("me@example.com"))
    for refused in ["tag:", "my-mac", "tag:a,tag:b", "a@b c"] {
        #expect(throws: MCPHTTP.Failure.self) {
            try MCPHTTP.allow(refused)
        }
    }
    let allowed: [MCPHTTP.Allow] = [.tag("tag:ci"), .login("me@example.com")]
    func judged(_ who: MCPHTTP.Whois, own: Bool = false, token: Bool = false) -> String? {
        try? MCPHTTP.judged(who, allowed: allowed, own: own, token: token).get()
    }
    #expect(judged(.init(id: "n1", tags: ["tag:ci"])) == "tag:ci")
    #expect(judged(.init(id: "n2", login: "ME@example.com")) == "ME@example.com")
    // A tagged machine is nobody's, whoever it shows as; one shared in isn't this tailnet's.
    #expect(judged(.init(id: "n3", tags: ["tag:other"], login: "me@example.com")) == nil)
    #expect(judged(.init(id: "n4", login: "me@example.com", sharer: 9)) == nil)
    #expect(judged(.init(id: "n5", login: "you@example.com")) == nil)
    // This machine: any user of it would pass, so only with the token.
    #expect(judged(.init(id: "own", login: "you@example.com"), own: true) == nil)
    #expect(judged(.init(id: "own", login: "you@example.com"), own: true, token: true) ==
        "you@example.com (this machine)")
    let said = #"{"Node":{"StableID":"nX","Tags":["tag:ci"],"Sharer":0},"UserProfile":{"LoginName":"tagged-devices"}}"#
    #expect(MCPHTTP.whois(fromJSON: said) == .init(id: "nX", tags: ["tag:ci"], login: "tagged-devices"))
}

@Test func theTokenFileIsItsOwnersAloneAndLongEnough() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("token").path
    let token = String(repeating: "a1", count: 16)
    try (token + "\n").write(toFile: file, atomically: true, encoding: .utf8)
    chmod(file, 0o644)
    #expect(throws: MCPHTTP.Failure.self) {
        try MCPHTTP.token(at: file)
    }
    chmod(file, 0o600)
    #expect(try MCPHTTP.token(at: file) == token)
    try "short".write(toFile: file, atomically: true, encoding: .utf8)
    chmod(file, 0o600)
    #expect(throws: MCPHTTP.Failure.self) {
        try MCPHTTP.token(at: file)
    }
}

/// A server on 127.0.0.1, with Tailscale's answers and the tools given here.
private final class Served: @unchecked Sendable {
    let server: MCPHTTP
    let listener: Int32
    let port: UInt16
    let lock = NSLock()
    var handled: [String] = []
    /// Held while a call on "slow" runs.
    let slow = DispatchSemaphore(value: 0)
    /// Whether a call on "waits" saw its request to the app given up.
    var givenUp: Bool?

    init(
        token: String? = nil,
        own: String = "100.64.0.9",
        uploads: MCPHTTP.Uploads? = nil,
        whois: @escaping @Sendable (String) -> Result<MCPHTTP.Whois, MCPHTTP.Failure> = { _ in
            .success(.init(id: "caller", tags: ["tag:ci"]))
        }
    ) throws {
        (listener, port) = try MCPHTTP.listen(ip: "127.0.0.1", port: 0)
        final class Later: @unchecked Sendable {
            var handle: ((Data, DeviceControlWire.Asking) -> Data?)?
        }
        let later = Later()
        server = MCPHTTP(
            allowed: [.tag("tag:ci")],
            token: token,
            ownIP: own,
            ownID: "own-node",
            hosts: MCPHTTP.hosts(ip: "127.0.0.1", names: ["mac.tail.ts.net"], port: port),
            headWithin: 2,
            uploads: uploads,
            whois: whois,
            handle: { message, asking in
                later.handle?(message, asking)
            },
            turnOf: { arguments in
                arguments["device"] as? String
            }
        )
        later.handle = { [unowned self] message, asking in
            let object = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any] ?? [:]
            let id = object["id"].map {
                "\($0)"
            } ?? ""
            let device = ((object["params"] as? [String: Any])?["arguments"] as? [String: Any])?["device"] as? String
            lock.withLock {
                handled.append(id)
            }
            if device == "slow" {
                slow.wait()
            }
            if device == "waits" {
                // As a call waiting at the app behind another client: until it is given up, or 3 s.
                for _ in 0 ..< 150 where !asking.givenUp {
                    usleep(20000)
                }
                lock.withLock {
                    givenUp = asking.givenUp
                }
            }
            return Data(#"{"jsonrpc":"2.0","id":\#(id),"result":{"content":[],"isError":false}}"#.utf8)
        }
        Thread.detachNewThread { [server, listener] in
            server.serve(listener)
        }
    }

    deinit {
        close(listener)
    }

    /// A connection, with `request` sent on it.
    func open(_ request: String) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let bytes = Array(request.utf8)
        _ = send(fd, bytes, bytes.count, 0)
        return fd
    }

    /// The whole answer to `request`, to the server's close.
    func ask(_ request: String) -> String {
        let fd = open(request)
        defer { close(fd) }
        var answer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { break }
            answer += chunk[..<n]
        }
        return String(decoding: answer, as: UTF8.self)
    }

    func post(_ body: String, headers: String = "") -> String {
        ask(
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\n\(headers)Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        )
    }
}

private func status(_ answer: String) -> Int {
    Int(answer.split(separator: " ").dropFirst().first ?? "") ?? 0
}

@Test func anMCPRequestOverHTTPIsRefusedBeforeAnythingIsAskedOfADevice() throws {
    let served = try Served(token: String(repeating: "t", count: 32))
    let port = served.port
    let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"look","arguments":{"device":"phone"}}}"#
    let bearer = "Authorization: Bearer \(String(repeating: "t", count: 32))\r\n"
    #expect(status(served
            .ask("GET /.well-known/oauth-authorization-server HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")) == 404)
    #expect(status(served.post(call, headers: bearer + "Origin: https://example.com\r\n")) == 403)
    #expect(status(served
            .ask("POST /mcp HTTP/1.1\r\nHost: elsewhere.example:\(port)\r\n\(bearer)Content-Length: 2\r\n\r\n{}")) ==
        400)
    let unauthorized = served.post(call)
    #expect(status(unauthorized) == 401 && unauthorized.contains("WWW-Authenticate: Bearer"))
    #expect(status(served.post(call, headers: "Authorization: Bearer wrong\r\n")) == 401)
    #expect(status(served.ask("GET /mcp HTTP/1.1\r\nHost: mac.tail.ts.net:\(port)\r\n\(bearer)\r\n")) == 405)
    #expect(status(served.post(call, headers: bearer + "MCP-Protocol-Version: 2026-07-28\r\n")) == 400)
    #expect(status(served.post("[1]", headers: bearer)) == 400)
    #expect(status(served.post("{", headers: bearer)) == 400)
    #expect(served.lock
        .withLock {
            served.handled
        }
        .isEmpty)
    let answered = served.post(call, headers: bearer)
    #expect(status(answered) == 200 && answered.contains(#""isError":false"#))
    #expect(served.lock.withLock {
        served.handled
    } == ["1"])
}

@Test func whoCallsOverHTTPIsWhatTailscaleSays() throws {
    let call = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"look","arguments":{"device":"phone"}}}"#
    #expect(status(try Served(whois: { _ in
        .failure(.init(description: "no answer"))
    }).post(call)) == 503)
    #expect(status(try Served(whois: { _ in
        .success(.init(id: "n", login: "someone@example.com"))
    }).post(call)) == 403)
    #expect(status(try Served(whois: { _ in
        .success(.init(id: "n", tags: ["tag:ci"], sharer: 3))
    }).post(call)) == 403)
    // This Mac itself: only with the token.
    let token = String(repeating: "t", count: 32)
    let own = try Served(token: token, own: "127.0.0.1")
    #expect(status(own.post(call)) == 401)
    #expect(status(own.post(call, headers: "Authorization: Bearer \(token)\r\n")) == 200)
    let noToken = try Served(own: "127.0.0.1")
    #expect(status(noToken.post(call)) == 403)
}

@Test func anMCPSessionIsGivenAtInitializeAndNotificationsAreAccepted() throws {
    let served = try Served()
    let hello = served.post(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
    #expect(status(hello) == 200 && hello.contains("Mcp-Session-Id: "))
    #expect(status(served.post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)) == 202)
    // Chunked, as a cloud's proxy may send it.
    let body = #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"look","arguments":{"device":"phone"}}}"#
    let chunked = served.ask(
        "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(served.port)\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\n\r\n\(String(body.utf8.count, radix: 16))\r\n\(body)\r\n0\r\n\r\n"
    )
    #expect(status(chunked) == 200 && chunked.contains(#""id":5"#))
}

/// A call waits its device's turn; one whose caller has gone meanwhile, or took it back in its session, isn't made.
@Test func aCallWhoseCallerWentBeforeItsTurnIsNotMade() throws {
    let served = try Served()
    func call(_ id: Int) -> String {
        let body = #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"tap","arguments":{"device":"slow"}}}"#
        return "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(served.port)\r\nMcp-Session-Id: s1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }
    let first = served.open(call(1))
    // In its turn before the others come.
    for _ in 0 ..< 100 where served.lock.withLock({
        served.handled.isEmpty
    }) {
        usleep(20000)
    }
    let gone = served.open(call(2))
    let takenBack = served.open(call(3))
    usleep(200_000)
    close(gone)
    #expect(status(served.post(
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#,
        headers: "Mcp-Session-Id: s1\r\n"
    )) == 202)
    let kept = served.open(call(4))
    usleep(200_000)
    for _ in 0 ..< 4 {
        served.slow.signal()
    }
    var answer = [UInt8](repeating: 0, count: 4096)
    let n = recv(kept, &answer, answer.count, 0)
    #expect(n > 0 && String(decoding: answer[..<n], as: UTF8.self).contains(#""id":4"#))
    #expect(served.lock.withLock {
        served.handled
    } == ["1", "4"])
    // The one taken back is closed unanswered.
    #expect(recv(takenBack, &answer, answer.count, 0) == 0)
    [first, takenBack, kept].forEach {
        close($0)
    }
}

/// A JSON nested deep is refused or read, and the server goes on: on a thread's default stack it ran out.
@Test func aDeeplyNestedBodyDoesntEndTheServer() throws {
    let served = try Served()
    let deep = String(repeating: #"{"a":"#, count: 5000) + "1" + String(repeating: "}", count: 5000)
    #expect([200, 202, 400].contains(status(served.post(deep))))
    #expect(status(served.post(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)) == 200)
}

/// A call whose caller goes while it waits at the app (behind another client of the device) has its
/// request to the app given up.
@Test func aCallsRequestToTheAppIsGivenUpWhenItsCallerGoes() throws {
    let served = try Served()
    let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"tap","arguments":{"device":"waits"}}}"#
    let fd = served
        .open(
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(served.port)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        )
    for _ in 0 ..< 100 where served.lock.withLock({
        served.handled.isEmpty
    }) {
        usleep(20000)
    }
    close(fd)
    for _ in 0 ..< 200 where served.lock.withLock({
        served.givenUp == nil
    }) {
        usleep(20000)
    }
    #expect(served.lock.withLock {
        served.givenUp
    } == true)
}

/// …and so does one taken back in its session after its turn, its caller still there.
@Test func aCallsRequestToTheAppIsGivenUpWhenItIsTakenBack() throws {
    let served = try Served()
    let body = #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"tap","arguments":{"device":"waits"}}}"#
    let fd = served
        .open(
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(served.port)\r\nMcp-Session-Id: s9\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        )
    defer { close(fd) }
    for _ in 0 ..< 100 where served.lock.withLock({
        served.handled.isEmpty
    }) {
        usleep(20000)
    }
    #expect(status(served.post(
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":8}}"#,
        headers: "Mcp-Session-Id: s9\r\n"
    )) == 202)
    for _ in 0 ..< 200 where served.lock.withLock({
        served.givenUp == nil
    }) {
        usleep(20000)
    }
    #expect(served.lock.withLock {
        served.givenUp
    } == true)
}

/// `PUT /upload` with `--allow-install`: an .ipa kept for one install by the caller that sent it, and its sha256.
@Test func anUploadIsKeptForItsCallersInstall() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let plain = try Served()
    #expect(status(plain.ask("PUT /upload HTTP/1.1\r\nHost: 127.0.0.1:\(plain.port)\r\nContent-Length: 1\r\n\r\nx")) ==
        404)

    let uploads = MCPHTTP.Uploads(folder: folder, most: 1 << 20)
    let served = try Served(uploads: uploads)
    let host = "Host: 127.0.0.1:\(served.port)\r\n"
    #expect(status(served.ask("GET /upload HTTP/1.1\r\n\(host)\r\n")) == 405)
    #expect(status(served.ask("PUT /upload HTTP/1.1\r\n\(host)\r\n")) == 411)
    let tooBig = served.ask("PUT /upload HTTP/1.1\r\n\(host)Content-Length: \((1 << 20) + 1)\r\n\r\n")
    #expect(status(tooBig) == 413 && tooBig.contains("1 MiB at most"))
    // One coming in holds the slot: another meanwhile is told to wait.
    let coming = served.open("PUT /upload HTTP/1.1\r\n\(host)Content-Length: 100\r\n\r\nhalf")
    usleep(200_000)
    #expect(status(served.ask("PUT /upload HTTP/1.1\r\n\(host)Content-Length: 1\r\n\r\nx")) == 409)
    close(coming)
    usleep(200_000)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty) // what came of it is gone

    let sent = served.ask("PUT /upload HTTP/1.1\r\n\(host)Content-Length: 5\r\n\r\nhello")
    #expect(status(sent) == 200)
    let answer = try #require(sent.components(separatedBy: "\r\n\r\n").last.flatMap {
        try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    })
    let id = try #require(answer["upload"] as? String)
    let sha256 = try #require(answer["sha256"] as? String)
    #expect(answer["size"] as? Int == 5)
    #expect(sha256 == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("upload-\(id).ipa").path))
    // An install naming it by another sha256 is refused before its turn; nothing is asked of a device.
    let wrong = served.post(
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"install","arguments":{"device":"phone","upload":"\#(id)","sha256":"00"}}}"#
    )
    #expect(wrong.contains(#""isError":true"#) && wrong.contains("isn't upload"))
    #expect(served.lock
        .withLock {
            served.handled
        }
        .isEmpty)
    #expect(uploads.refusal(id: id, owner: "someone-else", sha256: sha256) != nil)
    #expect(uploads.refusal(id: id, owner: "caller", sha256: sha256) == nil)
    // Handed to an install: linked where the app takes it from, the upload's own file kept meanwhile. Not taken by the
    // app, it is kept again; taken, it is used up.
    let upload = folder.appendingPathComponent("upload-\(id).ipa").path
    let lent = try uploads.claim(id: id, sha256: sha256, into: folder)
    let own = URL(fileURLWithPath: lent.path).deletingLastPathComponent()
    #expect(own.lastPathComponent.hasPrefix("install-") && FileManager.default.fileExists(atPath: lent.path))
    #expect(FileManager.default.fileExists(atPath: upload))
    #expect(uploads.refusal(id: id, owner: "caller", sha256: sha256) != nil) // not kept for another meanwhile
    lent.settle(false)
    #expect(uploads.refusal(id: id, owner: "caller", sha256: sha256) == nil)
    try FileManager.default.removeItem(at: own) // as the app or `roamrun mcp` does
    let taken = try uploads.claim(id: id, sha256: sha256, into: folder)
    taken.settle(true)
    #expect(FileManager.default.fileExists(atPath: taken.path)) // the app's, to remove when its install ends
    #expect(!FileManager.default.fileExists(atPath: upload))
    #expect(throws: MCPHTTP.Failure.self) {
        try uploads.claim(id: id, sha256: sha256, into: folder)
    }

    // Stopped while one is lent: its own file goes, the install's link stays.
    let again = served.ask("PUT /upload HTTP/1.1\r\n\(host)Content-Length: 1\r\n\r\ny")
    let second = try #require(again.components(separatedBy: #""upload":""#).last?.prefix(32)).description
    let secondSha = try #require(again.components(separatedBy: #""sha256":""#).last?.prefix(64)).description
    let held = try uploads.claim(id: second, sha256: secondSha, into: folder)
    uploads.end()
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("upload-\(second).ipa").path))
    #expect(FileManager.default.fileExists(atPath: held.path))
}

/// An upload not used for half an hour is let go of, and its file with it.
@Test func anUploadUnusedForHalfAnHourIsDropped() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let uploads = MCPHTTP.Uploads(folder: folder, most: 1 << 20)
    let served = try Served(uploads: uploads)
    let sent = served.ask(
        "PUT /upload HTTP/1.1\r\nHost: 127.0.0.1:\(served.port)\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"
    )
    #expect(status(sent) == 200 && sent.contains(#""size":3"#))
    uploads.sweep(now: Date().addingTimeInterval(MCPHTTP.Uploads.keptFor - 60))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
    uploads.sweep(now: Date().addingTimeInterval(MCPHTTP.Uploads.keptFor + 60))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
}

/// A server starting removes upload files a killed one left a day or more ago, not one younger; a use refreshes its time.
@Test func uploadsLeftADayAgoGoWhenAServerStarts() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let old = folder.appendingPathComponent("upload-old.ipa"), young = folder.appendingPathComponent("upload-young.ipa")
    try Data("x".utf8).write(to: old)
    try Data("x".utf8).write(to: young)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-25 * 3600)],
        ofItemAtPath: old.path
    )
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-3600)],
        ofItemAtPath: young.path
    )
    let uploads = MCPHTTP.Uploads(folder: folder, most: 1 << 20)
    #expect(!FileManager.default.fileExists(atPath: old.path) && FileManager.default.fileExists(atPath: young.path))
    // A use of the kept one takes its file's time along.
    let served = try Served(uploads: uploads)
    let sent = served.ask("PUT /upload HTTP/1.1\r\nHost: 127.0.0.1:\(served.port)\r\nContent-Length: 1\r\n\r\nx")
    let id = try #require(sent.components(separatedBy: #""upload":""#).last?.prefix(32)).description
    let file = folder.appendingPathComponent("upload-\(id).ipa").path
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: file)
    _ = uploads.refusal(id: id, owner: "caller", sha256: "")
    let touched = try #require(try FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date)
    #expect(Date().timeIntervalSince(touched) < 60)
}

/// Over HTTP, an install by another machine than the one that sent the upload is refused before its turn.
@Test func anUploadIsInstalledOnlyByTheMachineThatSentIt() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    final class Caller: @unchecked Sendable {
        var id = "sender"
    }
    let caller = Caller()
    let served = try Served(uploads: MCPHTTP.Uploads(folder: folder, most: 1 << 20)) { _ in
        .success(.init(id: caller.id, tags: ["tag:ci"]))
    }
    let sent = served.ask("PUT /upload HTTP/1.1\r\nHost: 127.0.0.1:\(served.port)\r\nContent-Length: 1\r\n\r\nx")
    let answer = try #require(sent.components(separatedBy: "\r\n\r\n").last.flatMap {
        try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    })
    let (id, sha256) = (answer["upload"] as? String ?? "", answer["sha256"] as? String ?? "")
    caller.id = "another"
    let refused = served.post(
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"install","arguments":{"device":"phone","upload":"\#(id)","sha256":"\#(sha256)"}}}"#
    )
    #expect(refused.contains(#""isError":true"#) && refused.contains("no upload \(id) is kept here for you"))
    #expect(served.lock
        .withLock {
            served.handled
        }
        .isEmpty)
}
