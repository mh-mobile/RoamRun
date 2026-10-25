import Foundation
import Testing
@testable import RoamRun
import os
import ImageIO

/// A name two saved devices have names neither to the MCP tools, as it doesn't to the commands:
/// a list that was mended gives devices a default name, and the first of them isn't the one meant.
@Test func theMCPToolsDoNotGuessBetweenDevicesOfOneName() throws {
    func device(_ name: String) -> DeviceProfile {
        DeviceProfile(
            displayName: name,
            instanceName: UUID().uuidString,
            serviceType: "_remotepairing._tcp",
            domain: "local.",
            remotePairingPort: 49152,
            bonjourHost: "x.local.",
            txt: [:],
            providerID: "tailscale",
            providerHostName: name,
            providerIP: "100.64.0.1"
        )
    }
    var asked: [DeviceControlWire.Request] = []
    let server = DeviceMCP(profiles: {
        [device("Device"), device("device"), device("iPad")]
    }, looks: FileManager.default.temporaryDirectory) { request in
        asked.append(request)
        return .init(ok: true)
    }
    func call(_ tool: String, _ arguments: String) throws -> [String: Any] {
        let answer = try #require(server
            .handle(
                Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#
                    .utf8)
            ))
        let object = try #require(try JSONSerialization.jsonObject(with: answer) as? [String: Any])
        return try #require(object["result"] as? [String: Any])
    }
    for tool in ["press", "type", "paste", "elements", "look"] {
        #expect(try call(tool, #"{"device":"Device","button":"lock","text":"x"}"#)["isError"] as? Bool == true)
    }
    #expect(asked.isEmpty) // nothing reached a device
    #expect(try call("press", #"{"device":"iPad","button":"home"}"#)["isError"] as? Bool != true)
    #expect(asked.count == 1)
}

/// `roamrun mcp`: the handshake, the tool list, and the look a tap, swipe, type or paste gives,
/// passed to the app as the client gave it: the app alone holds an action to a look, as it sees
/// every caller's (one that acts on another's look is refused there, and the other's still goes).
@Test func theMCPServerPassesTheClientsLookToTheApp() throws {
    let device = profile("iPhone")
    var asked: [DeviceControlWire.Request] = []
    var saved = [device]
    var looks = 4, latest = 0
    let server = DeviceMCP(profiles: {
        saved
    }, looks: FileManager.default.temporaryDirectory) { request in
        asked.append(request)
        switch request.op {
        case "rules": return .init(ok: true, rules: DeviceControlHub.rules)
        case "look":
            // The app's look is no larger than a model is shown: 640 x 1280.
            let context = CGContext(data: nil, width: 640, height: 1280, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            let out = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: request.path!) as CFURL,
                "public.png" as CFString,
                1,
                nil
            )!
            CGImageDestinationAddImage(out, context.makeImage()!, nil)
            CGImageDestinationFinalize(out)
            looks += 1
            latest = looks
            return .init(ok: true, width: 640, height: 1280, look: looks)
        case "tap", "swipe", "type", "paste":
            // As the app holds to it: the latest look only.
            return request.look == latest ? .init(ok: true) : .failure(DeviceControlHub.lookedSince(request.look ?? -1))
        default: return .init(ok: true)
        }
    }
    func send(_ json: String) throws -> [String: Any] {
        let answer = try #require(server.handle(Data(json.utf8)))
        return try #require(try JSONSerialization.jsonObject(with: answer) as? [String: Any])
    }
    func result(_ json: String) throws -> [String: Any] {
        try #require(try send(json)["result"] as? [String: Any])
    }
    func call(_ tool: String, _ arguments: String) throws -> [String: Any] {
        try result(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#
        )
    }
    func said(_ answer: [String: Any]) -> String {
        (
            (answer["content"] as? [[String: Any]])?.last?["text"] as? String
        ) ??
            ""
    }

    let hello = try result(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
    #expect(hello["protocolVersion"] as? String == "2025-06-18")
    // A version not spoken here, or none, gets the newest that is: not an echo of what was asked.
    func answered(_ params: String) throws -> String? {
        try result(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":\#(params)}"#)["protocolVersion"] as? String
    }
    #expect(try answered(#"{"protocolVersion":"2024-11-05"}"#) == "2024-11-05")
    #expect(try answered(#"{"protocolVersion":"2026-07-28"}"#) == "2025-11-25")
    #expect(try answered("{}") == "2025-11-25")
    #expect(try answered(#"{"protocolVersion":20251125}"#) == "2025-11-25")
    #expect(server
        .handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) ==
        nil) // a notification gets no answer
    // What can't be read is answered with JSON-RPC's error for it, not left unanswered.
    func failed(_ message: String) throws -> (code: Int?, id: Any?) {
        let answer = try send(message)
        return ((answer["error"] as? [String: Any])?["code"] as? Int, answer["id"])
    }
    #expect(try failed("not json").code == -32700)
    #expect(try failed("[]").code == -32600)
    let noMethod = try failed(#"{"jsonrpc":"2.0","id":9}"#)
    #expect(noMethod.code == -32600 && noMethod.id as? Int == 9)
    #expect(try failed(#"{"jsonrpc":"2.0","id":10,"method":"no/such"}"#).code == -32601)
    let tools =
        try #require(try result(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)["tools"] as? [[String: Any]])
    #expect(Set(tools.compactMap {
        $0["name"] as? String
    }) == [
        "devices",
        "look",
        "tap",
        "swipe",
        "elements",
        "type",
        "paste",
        "press",
        "install",
        "install_status",
        "launch"
    ])
    func hinted(_ hint: String) -> Set<String> {
        Set(tools.filter {
            ($0["annotations"] as? [String: Bool])?[hint] == true
        }
        .compactMap {
            $0["name"] as? String
        })
    }
    #expect(hinted("readOnlyHint") == ["devices", "look", "install_status"])
    #expect(hinted("destructiveHint") == ["tap", "swipe", "type", "paste", "press", "install", "launch"])

    // What holds an action to a look, and says which.
    func required(_ name: String) -> [String] {
        (tools.first {
            $0["name"] as? String == name
        }?["inputSchema"] as? [String: Any])?["required"] as? [String] ?? []
    }
    for name in ["tap", "swipe", "type", "paste"] {
        #expect(required(name).contains("look"), "\(name)")
    }
    #expect(!required("press").contains("look") && !required("look").contains("look"))

    // No look given: refused here, and the app isn't even asked.
    let missing = try call("tap", #"{"device":"iPhone","x":10,"y":10}"#)
    #expect(missing["isError"] as? Bool == true && said(missing).hasPrefix("look is missing"))
    #expect(try call("type", #"{"device":"iPhone","text":"a","look":true}"#)["isError"] as? Bool ==
        true) // JSON's true isn't 1
    #expect(asked.isEmpty)

    let look = try call("look", #"{"device":"iphone"}"#) // names match as the CLI's do
    let content = try #require(look["content"] as? [[String: Any]])
    #expect(content.first?["type"] as? String == "image" && content.first?["mimeType"] as? String == "image/jpeg")
    #expect(said(look).hasPrefix("640 x 1280, look 5."))
    // Another client's look meanwhile: a tap with the first is the app's to refuse; the newer still goes.
    #expect(said(try call("look", #"{"device":"iPhone"}"#)).hasPrefix("640 x 1280, look 6."))
    let older = try call("tap", #"{"device":"iPhone","look":5,"x":320,"y":640}"#)
    #expect(older["isError"] as? Bool == true && said(older) == DeviceControlHub.lookedSince(5))
    #expect(try call("tap", #"{"device":"iPhone","look":"6","x":320,"y":640}"#)["isError"] as? Bool ==
        false) // a number written as text
    // The points as given: the image is the look.
    #expect(asked.last == .init(op: "tap", device: device.id, x: 320, y: 640, look: 6))
    #expect(asked.dropLast().last?.op == "rules")
    #expect(try call("type", #"{"device":"iPhone","look":6,"text":"hi"}"#)["isError"] as? Bool == false)
    #expect(asked.last == .init(op: "type", device: device.id, text: "hi", look: 6))
    #expect(try call("paste", #"{"device":"iPhone","look":6,"text":"hi"}"#)["isError"] as? Bool == false)
    #expect(asked.last == .init(op: "paste", device: device.id, text: "hi", look: 6))
    #expect(try call("swipe",
                     #"{"device":"iPhone","look":6,"x1":1,"y1":2,"x2":3,"y2":4,"milliseconds":2000}"#)[
            "isError"
        ] as? Bool == false)
    #expect(asked.last == .init(op: "swipe", device: device.id, x: 1, y: 2, x2: 3, y2: 4, milliseconds: 2000, look: 6))
    // A whole number only, as JSON writes one: not 6.0, nor a duration as text or out of its range.
    let before = asked.count
    #expect(said(try call("tap", #"{"device":"iPhone","look":6.0,"x":1,"y":1}"#)).hasPrefix("look isn't a look's id"))
    #expect(said(try call("tap", #"{"device":"iPhone","look":6,"x":true,"y":1}"#)) == "x is missing")
    for ms in [#""2000""#, "10", "300.5", "true"] {
        let refused = try call(
            "swipe",
            #"{"device":"iPhone","look":6,"x1":1,"y1":2,"x2":3,"y2":4,"milliseconds":\#(ms)}"#
        )
        #expect(said(refused) == "milliseconds is a whole number, 50...5000", "\(ms)")
    }
    #expect(asked.count == before)
    #expect(try call("press", #"{"device":"iPhone","button":"home"}"#)["isError"] as? Bool == false)
    #expect(asked.last == .init(op: "press", device: device.id, text: "home"))

    #expect(try call("look", #"{"device":"nobody"}"#)["isError"] as? Bool == true)
    #expect(try send(#"{"jsonrpc":"2.0","id":9,"method":"resources/list"}"#)["error"] != nil)

    // A device saved after the server started is there at the next call.
    saved.append(profile("iPad"))
    let listed = try #require((try call("devices", "{}")["content"] as? [[String: Any]])?.first?["text"] as? String)
    #expect(listed == "iPhone\niPad")
    #expect(try call("look", #"{"device":"iPad"}"#)["isError"] as? Bool == false)
}

/// An app older than this `roamrun` doesn't hold text to a look: nothing held to one is sent to it.
@Test func theMCPServerSendsNothingHeldToALookToAnOlderApp() throws {
    let device = profile("iPhone")
    var asked: [String] = []
    let server = DeviceMCP(profiles: {
        [device]
    }, looks: FileManager.default.temporaryDirectory) { request in
        asked.append(request.op)
        return request.op == "rules" ? .failure("unknown request") : .init(ok: true) // what an older app says
    }
    for (tool, arguments) in [("tap", #""look":1,"x":1,"y":1"#), ("swipe", #""look":1,"x1":1,"y1":1,"x2":2,"y2":2"#),
                              ("type", #""look":1,"text":"a""#), ("paste", #""look":1,"text":"a""#)]
    {
        let json = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(tool)","arguments":{"device":"iPhone",\#(arguments)}}}"#
        let answer = try #require(server.handle(Data(json.utf8)))
        let result =
            try #require((try JSONSerialization
                    .jsonObject(with: answer) as? [String: Any])?["result"] as? [String: Any])
        #expect(
            result["isError"] as? Bool == true && (
                (result["content"] as? [[String: Any]])?.first?["text"] as? String
            ) ==
                DeviceMCP.olderApp,
            "\(tool)"
        )
    }
    #expect(asked == ["rules", "rules", "rules", "rules"])
    // What the CLI's --look goes by too.
    #expect(DeviceMCP.older(.failure("unknown request")) && DeviceMCP.older(.init(ok: true)) && DeviceMCP.older(.init(
        ok: true,
        rules: DeviceControlHub.rules - 1
    )))
    #expect(!DeviceMCP.older(.init(ok: true, rules: DeviceControlHub.rules)) && !DeviceMCP
        .older(.failure("device control isn't set up for this device")))
}

/// A blank line is no message: nothing is answered, as `roamrunctl mcp` does. A line that isn't
/// JSON is answered with its error.
@Test func theMCPServerAnswersWhatItCantReadAndNotABlankLine() {
    let server = DeviceMCP(profiles: {
        []
    }, looks: FileManager.default.temporaryDirectory) { _ in
        .init(ok: true)
    }
    let written = OSAllocatedUnfairLock<[String]>(initialState: [])
    var lines = ["", "   ", "not json"].makeIterator()
    server.serve(lines: {
        lines.next()
    }, write: { answer in
        written.withLock {
            $0.append(String(decoding: answer, as: UTF8.self))
        }
    })
    #expect(written.withLock {
        $0.count
    } == 1)
    #expect(written.withLock {
        $0.first?.contains("-32700")
    } == true)
}

/// The MCP server reads on while a tool runs: a call taken back before its turn isn't begun, and
/// neither is one still waiting when the client goes.
@Test func theMCPServerDoesNotBeginWhatIsTakenBackOrLeftBehind() throws {
    let device = profile("iPhone")
    func call(_ id: Int, _ button: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"press","arguments":{"device":"iPhone","button":"\#(button)"}}}"#
    }
    /// What reached the app. The first call holds the queue until `freedAfter` lines were read
    /// (all of them: until the client has gone).
    func asked(_ lines: [String], freedAfter: Int, reaching: Int = 1) -> [String] {
        let sent = OSAllocatedUnfairLock<[String]>(initialState: [])
        let first = DispatchSemaphore(value: 0), free = DispatchSemaphore(value: 0)
        let server = DeviceMCP(profiles: {
            [device]
        }, looks: FileManager.default.temporaryDirectory) { request in
            let n = sent.withLock {
                $0.append(request.text ?? "")
                return $0.count
            }
            if n == 1 {
                first.signal()
                held(free)
            }
            return .init(ok: true)
        }
        var read = 0
        server.serve(lines: {
            if read == 1 {
                held(first)
            } // the first is under way before more is said
            if read == freedAfter, read < lines.count {
                free.signal()
            }
            if read == lines.count {
                if freedAfter < lines.count {
                    // The rest has its turn before the end: until all that should reach the app did.
                    for _ in 0 ..< 500 where sent.withLock({
                        $0.count
                    }) < reaching {
                        usleep(20_000)
                    }
                } else {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        free.signal()
                    }
                }
            }
            defer { read += 1 }
            return read < lines.count ? lines[read] : nil
        }, write: { _ in })
        return sent.withLock {
            $0
        }
    }
    let cancel = #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}"#
    #expect(asked([call(1, "home"), call(2, "lock")], freedAfter: 2) == ["home"]) // the client went
    #expect(asked([call(1, "home"), call(2, "lock"), cancel, call(3, "home")], freedAfter: 3, reaching: 2) == [
        "home",
        "home"
    ]) // taken back
    #expect(asked([call(1, "home"), call(2, "lock"), call(3, "home")], freedAfter: 2, reaching: 3) == [
        "home",
        "lock",
        "home"
    ]) // neither
    // "2" is another request than 2: taking it back takes nothing of 2's.
    let other = #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"2"}}"#
    #expect(asked([call(1, "home"), call(2, "lock"), other, call(3, "home")], freedAfter: 3, reaching: 3) == [
        "home",
        "lock",
        "home"
    ])
}

/// The MCP tool types no more than a client would wait for: the rest is for paste.
@Test func theMCPToolTypesOnlySoMuch() throws {
    let device = profile("iPhone")
    var asked = 0
    let server = DeviceMCP(profiles: {
        [device]
    }, looks: FileManager.default.temporaryDirectory) { request in
        if request.op == "rules" {
            return .init(ok: true, rules: DeviceControlHub.rules)
        }
        asked += 1
        return .init(ok: true)
    }
    func call(_ text: String) throws -> Bool {
        let json = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"type","arguments":{"device":"iPhone","look":1,"text":"\#(text)"}}}"#
        let answer = try #require(server.handle(Data(json.utf8)))
        let result =
            try #require((try JSONSerialization
                    .jsonObject(with: answer) as? [String: Any])?["result"] as? [String: Any])
        return result["isError"] as? Bool ?? true
    }
    #expect(try call(String(repeating: "a", count: DeviceMCP.longestTyped)) == false && asked == 1)
    #expect(try call(String(repeating: "a", count: DeviceMCP.longestTyped + 1)) == true && asked == 1)
}

/// `install` takes a path on this Mac, over stdio only: it is copied into RoamRun's own folder, where the app
/// takes it from. A server that doesn't offer it (over HTTP) neither lists nor does it.
@Test func anInstallFromAPathIsCopiedWhereTheAppTakesIt() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let ipa = folder.appendingPathComponent("App.ipa")
    try Data("not really".utf8).write(to: ipa)
    var seen: (path: String, there: Bool)?
    func server(installs: Bool) -> DeviceMCP {
        DeviceMCP(profiles: {
            [profile("iPhone")]
        }, looks: folder, installsFromPaths: installs) { request in
            if request.op == "install" {
                seen = (request.path ?? "", FileManager.default.fileExists(atPath: request.path ?? ""))
                return .init(ok: true, install: "ab12", said: "installing began (install ab12)")
            }
            return .init(ok: true, pid: 7)
        }
    }
    func call(_ server: DeviceMCP, _ tool: String, _ arguments: String) throws -> (text: String, failed: Bool) {
        let answer = try #require(server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#
                .utf8
        )))
        let result =
            try #require((try JSONSerialization
                    .jsonObject(with: answer) as? [String: Any])?["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result["isError"] as? Bool == true)
    }
    let local = server(installs: true)
    let begun = try call(local, "install", #"{"device":"iPhone","path":"\#(ipa.path)"}"#)
    #expect(!begun.failed && begun.text.contains("install ab12"))
    let path = try #require(seen?.path)
    #expect(seen?.there == true && path != ipa.path)
    #expect(URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
    #expect(URL(fileURLWithPath: path).lastPathComponent.hasPrefix("install-") && path.hasSuffix(".ipa"))
    #expect(try call(local, "install", #"{"device":"iPhone","path":"/nowhere/App.ipa"}"#).failed)
    #expect(try call(local, "launch", #"{"device":"iPhone","bundle":"com.example.App"}"#).text.contains("pid 7"))
    let remote = server(installs: false)
    seen = nil
    #expect(try call(remote, "install", #"{"device":"iPhone","path":"\#(ipa.path)"}"#).failed)
    #expect(seen == nil)
}
