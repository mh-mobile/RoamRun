import Foundation
import Testing
@testable import RoamRun
import DeviceControl
import os
import ImageIO

/// `roamrun look` / `tap` reach the app over a socket only this user can open; with no app
/// listening, they are told so.
@Test func theControlSocketAnswersAndIsThisUsersAlone() throws {
    // Not scratchDir(): a socket's path has to fit in 104 bytes, and the temporary folder's is long.
    let dir = URL(fileURLWithPath: "/tmp/rr-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = UUID()
    let request = DeviceControlWire.Request(op: "tap", device: id, x: 10, y: 20)
    #expect(throws: DeviceControlWire.WireError.self) { try DeviceControlWire.ask(
        request,
        in: dir
    ) } // nobody listening

    let listener = try #require(DeviceControlWire.Listener(directory: dir) { r in
        r == request ? .init(ok: true, width: 3, height: 4) : .failure("not what was sent")
    })
    let mode = { (path: String) in
        try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    }
    #expect(try mode(DeviceControlWire.socketFolder(in: dir).path) == 0o700) // nobody else gets as far as the socket
    #expect(try mode(DeviceControlWire.socketPath(in: dir)) == 0o600)
    #expect(try DeviceControlWire.ask(request, in: dir) == .init(ok: true, width: 3, height: 4))
    #expect(try DeviceControlWire.ask(.init(op: "look", device: id), in: dir) == .failure("not what was sent"))
    listener.stop()
    #expect(throws: DeviceControlWire.WireError.self) { try DeviceControlWire.ask(request, in: dir) } // stopped: gone
}

/// A client that goes away before its answer (Ctrl-C during a look) costs the app nothing: the
/// write to it fails instead of ending the process, and the next client is served.
@Test func aClientThatLeavesBeforeItsAnswerDoesNotEndTheApp() throws {
    let dir = URL(fileURLWithPath: "/tmp/rr-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let answered = DispatchSemaphore(value: 0)
    let listener = try #require(DeviceControlWire.Listener(directory: dir) { _ in
        Thread.sleep(forTimeInterval: 0.2) // the client has gone by the time this is written
        defer { answered.signal() }
        return .init(ok: true)
    })
    defer { listener.stop() }
    func connected() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(DeviceControlWire.socketPath(in: dir).utf8)
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.copyBytes(from: path)
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(result == 0)
        return fd
    }
    let request = try JSONEncoder().encode(DeviceControlWire.Request(op: "look", device: UUID())) + Data([0x0A])
    let leaving = try connected()
    request.withUnsafeBytes {
        _ = write(leaving, $0.baseAddress, $0.count)
    }
    close(leaving)
    #expect(soon(answered))
    Thread.sleep(forTimeInterval: 0.1) // the write to the closed socket has happened
    close(try connected()) // one that says nothing at all
    #expect(try DeviceControlWire.ask(.init(op: "state", device: UUID()), in: dir) == .init(ok: true))
}

/// A number JSON can't carry (NaN, from `roamrun tap x nan 1`) is refused at once, not waited on forever.
@Test func aRequestThatCannotBeSentIsRefusedNotWaitedOn() throws {
    let dir = URL(fileURLWithPath: "/tmp/rr-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let listener = try #require(DeviceControlWire.Listener(directory: dir) { _ in
        .init(ok: true)
    })
    defer { listener.stop() }
    let started = Date()
    #expect(throws: DeviceControlWire.WireError.self) {
        try DeviceControlWire.ask(.init(op: "tap", device: UUID(), x: .nan, y: 1), in: dir)
    }
    #expect(Date().timeIntervalSince(started) < 2)
}

/// Asking how a device's connection stands never waits for a call that runs on it: the app's
/// window asks while it draws, and `status` asks while an agent's `elements` is under way.
@Test func askingHowAConnectionStandsDoesNotWaitForACall() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let pairing = try scratchPairing()
    let silent = try silentPort()
    defer { close(silent.fd) }
    let session = DeviceSession(ip: "127.0.0.1", port: silent.port, pairing: {
        pairing
    })
    let entered = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        entered.signal()
        try? session.connect() // waits on the silent port, up to the library's 20 s
    }
    #expect(soon(entered))
    Thread.sleep(forTimeInterval: 0.3) // it holds the session's lock by now
    let asked = Date()
    #expect(!session.isOpen && !session.isRefused)
    #expect(Date().timeIntervalSince(asked) < 1)
}

/// A device renamed keeps the connection it has (away from Wi‑Fi no new one could be made);
/// one found at another port gets a new one.
@Test func aRenamedDeviceKeepsItsConnection() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try scratchPairing(at: DeviceControlWire.pairingFile(udid: "UDID-1", in: dir))
    let hub = DeviceControlHub(directory: dir, key: { _ in
        scratchKey
    })
    defer { hub.stop() }
    let id = UUID()
    func target(_ name: String, port: UInt16) -> DeviceControlHub.Target {
        .init(id: id, name: name, ip: "127.0.0.1", port: port,
              udid: "UDID-1") // nothing listens there: opening fails at once
    }
    hub.update([target("iPhone", port: 1)])
    let first = try #require(hub.session(of: id))
    hub.update([target("My iPhone", port: 1)])
    #expect(hub.session(of: id) === first)
    hub.update([target("My iPhone", port: 2)])
    #expect(hub.session(of: id) != nil && hub.session(of: id) !== first)
    hub.update([])
    #expect(hub.session(of: id) == nil)
}

/// One look serves one action, however many arrive at once: of taps sent together after a
/// look, one reaches the device and the others are told to look first.
@Test func oneLookServesOneActionHoweverManyArriveAtOnce() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (hub, made) = try standInHub(dir)
    defer { hub.stop() }
    let id = UUID()
    hub.update([.init(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-1")])
    let device = try #require(made().first)
    let png = lookFile(in: dir)
    for round in 1 ... 40 {
        #expect(hub.answer(.init(op: "look", device: id, path: png)).ok)
        let answers = OSAllocatedUnfairLock<[DeviceControlWire.Response]>(initialState: [])
        DispatchQueue.concurrentPerform(iterations: 6) { n in
            // Taps, and what else spends a look: none may slip in between another's check and its act.
            let request: DeviceControlWire.Request = n == 5 ? .init(op: "press", device: id, text: "home") : .init(
                op: "tap",
                device: id,
                x: 10,
                y: 10
            )
            let answer = hub.answer(request)
            if request.op == "tap" {
                answers.withLock {
                    $0.append(answer)
                }
            }
        }
        let taps = device.calls
            .filter {
                $0 == "tap"
            }
            .count
        #expect(taps <= round) // never more than one a look
        #expect(answers.withLock {
            $0.filter(\.ok).count
        } <= 1)
        guard taps <= round else { break }
    }
    #expect(device.calls
        .filter {
            $0 == "look"
        }
        .count == 40)
}

/// A connection that stands is asked now and then whether it still does: a device that
/// restarted, or dropped the pairing, doesn't read as connected until the next call.
@Test func aConnectionFoundGoneIsOpenedAnew() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (hub, made) = try standInHub(dir)
    defer { hub.stop() }
    let id = UUID()
    hub.update([.init(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-1")])
    let device = try #require(made().first)
    // Long enough for a runner whose threads are all busy with the tests beside this one.
    func soon(_ what: () -> Bool) -> Bool {
        for _ in 0 ..< 3000 {
            if what() {
                return true
            }
            usleep(10_000)
        }
        return false
    }
    hub.checkOpen() // not due yet: just made
    usleep(50_000)
    #expect(!device.calls.contains("check"))
    hub.checkEvery = 0
    hub.checkOpen()
    #expect(soon {
        device.calls.contains("check")
    })
    #expect(hub.state(of: id, udid: "UDID-1").open) // it stands: nothing is opened
    let connects = device.calls
        .filter {
            $0 == "connect"
        }
        .count
    device.goneWhenChecked = true
    hub.checkOpen()
    #expect(soon {
        device.calls
            .filter {
                $0 == "connect"
            }
            .count == connects + 1
    }) // found gone, opened anew at once
    #expect(soon {
        hub.state(of: id, udid: "UDID-1").open
    })
}

/// A look is as large as a model is shown it: the file, the size said and the points taken are
/// all of that image, so a viewer that scales large images down doesn't move what is tapped.
@Test func aLookIsNoLargerThanAModelIsShown() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (hub, made) = try standInHub(dir)
    defer { hub.stop() }
    let id = UUID()
    hub.update([.init(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-1")])
    let device = try #require(made().first)
    device.screen = (1179, 2556)
    let png = lookFile(in: dir)
    let look = hub.answer(.init(op: "look", device: id, path: png))
    #expect(look.ok && look.width == 590 && look.height == 1280)
    let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: png) as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 590 && image.height == 1280)
    #expect(hub.answer(.init(op: "tap", device: id, x: 295, y: 640))
        .ok) // the middle of that image is the middle of the screen
    let tapped = try #require(device.tapped)
    #expect(abs(tapped.x - 0.5) < 0.001 && abs(tapped.y - 0.5) < 0.001)
    #expect(hub.answer(.init(op: "look", device: id, path: png)).ok)
    #expect(!hub.answer(.init(op: "tap", device: id, x: 600, y: 640))
        .ok) // outside it, though inside the screen's own pixels
    // A screen that is small enough is as it is.
    device.screen = (100, 200)
    let small = hub.answer(.init(op: "look", device: id, path: png))
    #expect(small.width == 100 && small.height == 200)
    // What a typed text says back: only where another keyboard would have taken it otherwise.
    #expect(DeviceControlWire.typed("hello") == nil)
    #expect(DeviceControlWire.typed("Clair Obscur")?.contains("paste") == true && DeviceControlWire
        .typed("search\n") != nil)
}

/// A look serves for a while only: a point read off one that is old goes to a screen nobody saw.
@Test func anOldLookServesNoAction() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (hub, made) = try standInHub(dir)
    defer { hub.stop() }
    let id = UUID()
    hub.update([.init(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-1")])
    let device = try #require(made().first)
    let png = lookFile(in: dir)
    hub.lookStands = 0.3
    #expect(hub.answer(.init(op: "look", device: id, path: png)).ok)
    Thread.sleep(forTimeInterval: 0.5)
    let tap = hub.answer(.init(op: "tap", device: id, x: 10, y: 10))
    #expect(!tap.ok && tap.error == DeviceControlHub.lookOld)
    // Let go of once found old: nothing more goes by it.
    let swipe = hub.answer(.init(op: "swipe", device: id, x: 10, y: 10, x2: 20, y2: 20))
    #expect(!swipe.ok && swipe.error == DeviceControlHub.lookFirst)
    #expect(!device.calls.contains("tap") && !device.calls.contains("swipe"))
    hub.lookStands = 60
    #expect(hub.answer(.init(op: "look", device: id, path: png)).ok)
    #expect(hub.answer(.init(op: "tap", device: id, x: 10, y: 10)).ok)
}

/// What was seen through a session counts for that session only: a look still under way when
/// the device gets a new session (another port, a new pairing) doesn't let a tap go to the new one.
@Test func aLookThroughAReplacedSessionServesNoAction() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (hub, made) = try standInHub(dir)
    defer { hub.stop() }
    let id = UUID()
    func target(port: UInt16) -> DeviceControlHub.Target {
        .init(
            id: id,
            name: "iPhone",
            ip: "127.0.0.1",
            port: port,
            udid: "UDID-1"
        )
    }
    hub.update([target(port: 1)])
    let old = try #require(made().first)
    old.hold = DispatchSemaphore(value: 0)
    let png = lookFile(in: dir)
    let looked = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        _ = hub.answer(.init(op: "look", device: id, path: png))
        looked.signal()
    }
    #expect(soon(old.lookBegan))
    hub.update([target(port: 2)]) // found at another port while the look runs
    old.hold?.signal()
    #expect(soon(looked))
    let fresh = try #require(made().last)
    #expect(fresh !== old)
    let tap = hub.answer(.init(op: "tap", device: id, x: 10, y: 10))
    #expect(!tap.ok && tap.error?.hasPrefix("look first") == true)
    #expect(!fresh.calls.contains("tap") && !old.calls.contains("tap"))
    // And through the new one, as ever: look, then act.
    #expect(hub.answer(.init(op: "look", device: id, path: png)).ok)
    #expect(hub.answer(.init(op: "tap", device: id, x: 10, y: 10)).ok)
    #expect(fresh.calls == ["look", "tap"])
}

/// One command at a time reaches a device, also when its session is replaced while one runs:
/// a command for the new session waits for the one still running through the old.
@Test func aCommandWaitsForTheOneRunningThroughAReplacedSession() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (hub, made) = try standInHub(dir)
    defer { hub.stop() }
    let id = UUID()
    func target(port: UInt16) -> DeviceControlHub.Target {
        .init(
            id: id,
            name: "iPhone",
            ip: "127.0.0.1",
            port: port,
            udid: "UDID-1"
        )
    }
    hub.update([target(port: 1)])
    let old = try #require(made().first)
    old.hold = DispatchSemaphore(value: 0)
    let png = lookFile(in: dir)
    let first = DispatchSemaphore(value: 0), second = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        _ = hub.answer(.init(op: "look", device: id, path: png))
        first.signal()
    }
    #expect(soon(old.lookBegan))
    hub.update([target(port: 2)]) // a new session while the look runs through the old
    let fresh = try #require(made().last)
    #expect(fresh !== old)
    let answer = OSAllocatedUnfairLock<DeviceControlWire.Response?>(initialState: nil)
    Thread.detachNewThread {
        let r = hub.answer(.init(op: "press", device: id, text: "home"))
        answer.withLock {
            $0 = r
        }
        second.signal()
    }
    #expect(second.wait(timeout: .now() + 0.5) == .timedOut) // it waits
    #expect(fresh.calls.isEmpty && old.calls == ["look", "letGo"])
    #expect(hub.answer(.init(op: "state", device: id)).ok) // how it stands is still said at once
    old.hold?.signal()
    #expect(soon(first))
    #expect(soon(second))
    #expect(answer.withLock {
        $0?.ok
    } == true)
    #expect(fresh.calls == ["press"] && old.calls == ["look", "letGo"]) // through the session held by then
}

/// A device can be set up before its UDID is known (one added at home has never been bridged):
/// the pairing says which device it is. What came in is the device asked for, another saved
/// one, or one that has to prove itself by connecting at the address asked for.
@Test func aPairingSaysWhichDeviceItIs() {
    typealias Hub = DeviceControlHub
    let others = [(udid: "00008130-AAAA", name: "iPhone")]
    #expect(Hub.verdict(expected: "00008027-BBBB", paired: "00008027-BBBB", others: others) == .expected)
    #expect(Hub
        .verdict(expected: "00008027-bbbb", paired: "00008027-BBBB", others: others) ==
        .expected) // one UDID, however spelled
    #expect(Hub.verdict(expected: nil, paired: "00008027-BBBB", others: others) == .toProve)
    // Known by another UDID than the one that paired: not proved by connecting — the pairing
    // would be saved under the known one's name, in its own pairing's place.
    #expect(Hub.verdict(expected: "00008027-CCCC", paired: "00008027-BBBB", others: others) == .another)
    // Already saved under another name: not saved twice, whether or not this one's UDID was known.
    #expect(Hub.verdict(expected: nil, paired: "00008130-aaaa", others: others) == .savedAs("iPhone"))
    #expect(Hub.verdict(expected: "00008027-BBBB", paired: "00008130-AAAA", others: others) == .savedAs("iPhone"))
    #expect(Hub.verdict(expected: nil, paired: "", others: others) == .nameless)
    #expect(Hub.verdict(expected: "00008027-BBBB", paired: "", others: others) == .toProve) // named by the one known

    // What the app does with the UDID the pairing was saved under.
    #expect(AppCoordinator.pairedUDID(saved: nil, paired: "X") == .save)
    #expect(AppCoordinator.pairedUDID(saved: "abc", paired: "ABC") == .known)
    #expect(AppCoordinator.pairedUDID(saved: "ABC", paired: "DEF") == .conflicts) // learned as another meanwhile
}

/// A UDID spelled another way is the same device: its connection is kept, not made anew.
@Test func aUDIDSpelledAnotherWayKeepsTheConnection() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (hub, made) = try standInHub(dir, udid: "00008027-00ab")
    defer { hub.stop() }
    let id = UUID()
    hub.update([.init(id: id, name: "iPad", ip: "127.0.0.1", port: 1, udid: "00008027-00ab")])
    let first = try #require(hub.session(of: id))
    hub.update([.init(id: id, name: "iPad", ip: "127.0.0.1", port: 1, udid: "00008027-00AB")])
    #expect(hub.session(of: id) === first && made().count == 1)
}

/// A failed input is never sent again, but its connection is no longer taken for sound — unless
/// it was refused for what it asked, before anything was sent.
@Test func aFailedInputLeavesItsConnectionInDoubt() {
    #expect(DeviceSession.leavesConnectionInDoubt(DeviceSession.Failure.message("touch: not connected")))
    #expect(DeviceSession.leavesConnectionInDoubt(DeviceSession.Failure.message("timed out")))
    #expect(!DeviceSession.leavesConnectionInDoubt(DeviceSession.Failure.invalid("can't type 'あ'")))
}

/// Whatever number a caller sends for a walk's length or a swipe's duration, the app survives it:
/// the one is brought into what a walk can do, the other refused outside what the library takes.
@Test func anyNumberACallerSendsIsBoundedOrRefused() {
    #expect(DeviceControlHub.elementLimit(nil) == 40)
    #expect(DeviceControlHub.elementLimit(0) == 1 && DeviceControlHub.elementLimit(-7) == 1)
    #expect(DeviceControlHub.elementLimit(4_294_967_296) == 1000 && DeviceControlHub.elementLimit(.max) == 1000)
    #expect(DeviceControlHub.swipeDuration(nil) == 300 && DeviceControlHub.swipeDuration(50) == 50)
    #expect(DeviceControlHub.swipeDuration(5_000_000_000) == nil && DeviceControlHub.swipeDuration(49) == nil)
    #expect(DeviceControlHub.swipeDuration(-1) == nil && DeviceControlHub.swipeDuration(.max) == nil)
    // The CLI's own: a point or a duration is a finite number, or the command is refused.
    #expect(CLI.finite(["1", "2.5", "1e3"]) == [1, 2.5, 1000])
    #expect(CLI.finite(["1", "inf"]) == nil && CLI.finite(["nan", "1"]) == nil && CLI.finite(["1", "x"]) == nil)
    #expect(CLI.finite(["1e999", "1"]) == nil)
}

/// A point comes in the pixels of a look and goes to the device as a fraction of its screen;
/// one outside the look is no point at all.
@Test func aLooksPixelsBecomeFractionsOfTheScreen() {
    let size = (width: 1000, height: 2000)
    let p = DeviceControlHub.fraction(x: 250, y: 500, of: size)
    #expect(p?.x == 0.25 && p?.y == 0.25)
    #expect(DeviceControlHub.fraction(x: 0, y: 0, of: size) != nil)
    #expect(DeviceControlHub.fraction(x: 999.5, y: 1999.5, of: size) != nil)
    #expect(DeviceControlHub.fraction(x: 1000, y: 10, of: size) == nil) // the width itself is past the last pixel
    #expect(DeviceControlHub.fraction(x: 10, y: 2000, of: size) == nil)
    #expect(DeviceControlHub.fraction(x: -1, y: 10, of: size) == nil)
    #expect(DeviceControlHub.fraction(x: nil, y: 10, of: size) == nil)
}

/// Where the app writes a look: only in the folder it keeps them in.
private func lookFile(in dir: URL) -> String {
    let folder = DeviceControlWire.socketFolder(in: dir)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent("look-\(UUID().uuidString).png").path
}

extension TimingSensitive {
    /// Watched while looks keep taking its place (a new file each time, as a look's name is):
    /// it is never there readable by others. A chmod after the write showed 644 within 50.
    @Test func aLookIsNeverThereReadableByOthers() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("now.png")
        let before = umask(0o022)
        defer { umask(before) }
        let modes = OSAllocatedUnfairLock<(seen: Set<mode_t>, done: Bool)>(initialState: ([], false))
        let watcher = Thread {
            while !modes.withLock({
                $0.done
            }) {
                var st = stat()
                guard stat(file.path, &st) == 0 else { continue }
                let mode = st.st_mode & 0o777
                modes.withLock {
                    _ = $0.seen.insert(mode)
                }
            }
        }
        watcher.start()
        for _ in 0 ..< 200 {
            try? FileManager.default.removeItem(at: file)
            let made = dir.appendingPathComponent("made-\(UUID().uuidString).png")
            try Data(count: 1000).write(to: made)
            try CLI.put(look: made, at: file)
        }
        modes.withLock {
            $0.done = true
        }
        while watcher.isExecuting {
            usleep(1000)
        }
        #expect(modes.withLock {
            $0.seen
        } == [0o600])
    }
}

/// A point is read off the look it came from: when another has looked since, the screen it was
/// read off is not the one that would be pressed.
@Test func aPointIsOfTheLookItNames() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (hub, made) = try standInHub(dir)
    defer { hub.stop() }
    let id = UUID()
    hub.update([.init(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-1")])
    let device = try #require(made().first)
    let png = lookFile(in: dir)
    func taps() -> Int {
        device.calls
            .filter {
                $0 == "tap" || $0 == "swipe"
            }
            .count
    }

    let mine = try #require(hub.answer(.init(op: "look", device: id, path: png)).look)
    let theirs = try #require(hub.answer(.init(op: "look", device: id, path: png)).look) // another, meanwhile
    #expect(mine != theirs)
    let refused = hub.answer(.init(op: "tap", device: id, x: 10, y: 10, look: mine))
    #expect(!refused.ok && refused.error == DeviceControlHub.lookedSince(mine))
    #expect(!hub.answer(.init(op: "swipe", device: id, x: 10, y: 10, x2: 20, y2: 20, look: mine)).ok)
    #expect(taps() == 0)
    // The other's look is still theirs to use: a refusal for what was asked doesn't spend it.
    #expect(hub.answer(.init(op: "tap", device: id, x: 10, y: 10, look: theirs)).ok)
    #expect(taps() == 1)
    // A command run by hand names none: it is of the last look, as before.
    #expect(hub.answer(.init(op: "look", device: id, path: png)).ok)
    #expect(hub.answer(.init(op: "tap", device: id, x: 10, y: 10)).ok)
    #expect(taps() == 2)
}

/// Text goes by the look given while it is the device's latest, a tap by it before or not: look,
/// tap a field, type. A tap or swipe doesn't go by a look a tap, swipe or text went by already.
@Test func textGoesByTheLatestLookATapWentBy() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (hub, made) = try standInHub(dir)
    defer { hub.stop() }
    hub.settling = 0
    let id = UUID()
    hub.update([.init(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-1")])
    let device = try #require(made().first)
    let png = lookFile(in: dir)
    func sent(_ op: String) -> Int {
        device.calls
            .filter {
                $0 == op
            }
            .count
    }

    let look = try #require(hub.answer(.init(op: "look", device: id, path: png)).look)
    #expect(hub.answer(.init(op: "tap", device: id, x: 10, y: 10, look: look)).ok)
    #expect(hub.answer(.init(op: "type", device: id, text: "a", look: look)).ok)
    #expect(hub.answer(.init(op: "paste", device: id, text: "b", look: look)).ok)
    #expect(hub.answer(.init(op: "type", device: id, text: "c", look: look)).ok)
    #expect(hub.answer(.init(op: "tap", device: id, x: 10, y: 10, look: look)).error == DeviceControlHub.lookFirst)
    #expect(hub.answer(.init(op: "swipe", device: id, x: 10, y: 10, x2: 20, y2: 20, look: look))
        .error == DeviceControlHub.lookFirst)
    #expect(sent("tap") == 1 && sent("type") == 2 && sent("paste") == 1 && sent("swipe") == 0)
    // Another look since, by whoever: text by the older one isn't sent, and the newer stands.
    let newer = try #require(hub.answer(.init(op: "look", device: id, path: png)).look)
    #expect(hub.answer(.init(op: "type", device: id, text: "d", look: look)).error == DeviceControlHub.notLatest(
        look,
        "type"
    ))
    #expect(hub.answer(.init(op: "paste", device: id, text: "d", look: look)).error == DeviceControlHub.notLatest(
        look,
        "paste"
    ))
    #expect(sent("type") == 2 && sent("paste") == 1)
    #expect(hub.answer(.init(op: "tap", device: id, x: 10, y: 10, look: newer)).ok)
    // Typed by hand (no look named): sent, and no tap goes by that look after it.
    #expect(hub.answer(.init(op: "look", device: id, path: png)).ok)
    #expect(hub.answer(.init(op: "type", device: id, text: "e")).ok)
    #expect(hub.answer(.init(op: "tap", device: id, x: 10, y: 10)).error == DeviceControlHub.lookFirst)
    // A tap by hand is of no one's look: text held to the latest isn't sent after it.
    let latest = try #require(hub.answer(.init(op: "look", device: id, path: png)).look)
    #expect(hub.answer(.init(op: "tap", device: id, x: 10, y: 10)).ok)
    #expect(hub.answer(.init(op: "type", device: id, text: "g", look: latest)).error == DeviceControlHub.notLatest(
        latest,
        "type"
    ))
    // A look over a minute old: not sent, and let go of.
    hub.lookStands = 0.2
    let old = try #require(hub.answer(.init(op: "look", device: id, path: png)).look)
    Thread.sleep(forTimeInterval: 0.3)
    #expect(hub.answer(.init(op: "type", device: id, text: "f", look: old)).error == DeviceControlHub.lookOld)
    #expect(hub.answer(.init(op: "type", device: id, text: "f", look: old)).error == DeviceControlHub.notLatest(
        old,
        "type"
    ))
    #expect(sent("type") == 3)
}

/// What ends a look — a button, the elements walked, another look though it failed, a failure
/// once something was sent — and what leaves it: a refusal for what was asked, before anything went.
@Test func whatEndsALookAndWhatLeavesIt() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (hub, made) = try standInHub(dir)
    defer { hub.stop() }
    hub.settling = 0
    let id = UUID()
    hub.update([.init(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-1")])
    let device = try #require(made().first)
    let png = lookFile(in: dir)
    func look() throws -> Int {
        try #require(hub.answer(.init(op: "look", device: id, path: png)).look)
    }
    func typed(_ look: Int) -> DeviceControlWire.Response {
        hub.answer(.init(
            op: "type",
            device: id,
            text: "a",
            look: look
        ))
    }

    for (op, request) in [
        ("press", DeviceControlWire.Request(op: "press", device: id, text: "home")),
        ("elements", .init(op: "elements", device: id))
    ] {
        let seen = try look()
        #expect(hub.answer(request).ok, "\(op)")
        #expect(typed(seen).error == DeviceControlHub.notLatest(seen, "type"), "\(op)")
    }
    // A look that failed: what the one before saw may have moved meanwhile.
    var seen = try look()
    device.lookFailing = DeviceSession.Failure.message("no picture")
    #expect(!hub.answer(.init(op: "look", device: id, path: png)).ok)
    device.lookFailing = nil
    #expect(typed(seen).error == DeviceControlHub.notLatest(seen, "type"))
    // Refused for what it says, before anything was sent: the look stands.
    seen = try look()
    #expect(hub.answer(.init(op: "tap", device: id, x: 1000, y: 10, look: seen))
        .error?
        .hasPrefix("the point must be inside the image") == true)
    #expect(hub.answer(.init(op: "type", device: id, look: seen)).error == "nothing to send")
    device.failing = DeviceSession.Failure.invalid("can't type that")
    #expect(typed(seen).error == "can't type that")
    #expect(hub.answer(.init(op: "press", device: id, text: "home")).error == "can't type that")
    device.failing = DeviceSession.Failure.notBegun("no connection") // nor did one that never began
    #expect(hub.answer(.init(op: "tap", device: id, x: 10, y: 10, look: seen)).error == "no connection")
    device.failing = nil
    #expect(hub.answer(.init(op: "tap", device: id, x: 10, y: 10, look: seen)).ok) // not spent by them
    #expect(typed(seen).ok)
    // Failed once sent: it may have reached the device, and nothing more goes by that look.
    device.failing = DeviceSession.Failure.message("timed out")
    #expect(typed(seen).error == "timed out. It may or may not have reached the device: look before doing it again")
    device.failing = nil
    #expect(typed(seen).error == DeviceControlHub.notLatest(seen, "type"))
    seen = try look()
    device.failing = DeviceSession.Failure.message("timed out")
    #expect(!hub.answer(.init(op: "tap", device: id, x: 10, y: 10, look: seen)).ok)
    device.failing = nil
    #expect(typed(seen).error == DeviceControlHub.notLatest(seen, "type"))
}

/// Text waits out the screen's moment after an input, as a look does: keys sent at once after a
/// tap on a field were seen lost. A request refused before anything was sent isn't an input.
@Test func textWaitsOutAMomentAfterAnInput() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (hub, made) = try standInHub(dir)
    defer { hub.stop() }
    hub.settling = 0.4
    let id = UUID()
    hub.update([.init(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-1")])
    let png = lookFile(in: dir)
    func timed(_ request: DeviceControlWire.Request) -> (ok: Bool, took: TimeInterval) {
        let began = Date()
        let answer = hub.answer(request)
        return (answer.ok, Date().timeIntervalSince(began))
    }
    let device = try #require(made().first)
    let look = try #require(hub.answer(.init(op: "look", device: id, path: png)).look)
    #expect(hub.answer(.init(op: "tap", device: id, x: 10, y: 10, look: look)).ok)
    let typed = timed(.init(op: "type", device: id, text: "a", look: look))
    #expect(typed.ok && typed.took >= 0.35, "\(typed.took)")
    let byHand = timed(.init(op: "paste", device: id, text: "b"))
    #expect(byHand.ok && byHand.took >= 0.35, "\(byHand.took)")
    // Whoever asked left while it waited: not begun, by hand or by a look that stands; nor a look taken.
    func leaving() -> @Sendable () -> Bool {
        let asked = OSAllocatedUnfairLock(initialState: 0)
        return {
            asked.withLock {
                $0 += 1
                return $0 == 1
            }
        } // there at its turn, gone after
    }
    let (pasted, looked) = (device.calls
        .filter {
            $0 == "paste"
        }
        .count, device.calls
        .filter {
            $0 == "look"
        }
        .count)
    #expect(hub.answer(.init(op: "look", device: id, path: png), wanted: leaving()).error == DeviceControlHub.notGiven)
    #expect(device.calls
        .filter {
            $0 == "look"
        }
        .count == looked)
    let standing = try #require(hub.answer(.init(op: "look", device: id, path: png)).look)
    for given in [nil, standing] {
        let left = hub.answer(.init(op: "paste", device: id, text: "x", look: given), wanted: leaving())
        #expect(left.error?.hasPrefix(DeviceSession.stopped) == true, "\(String(describing: given))")
    }
    #expect(device.calls
        .filter {
            $0 == "paste"
        }
        .count == pasted)
    // Long after the last input, and after a refusal only: nothing to wait out.
    Thread.sleep(forTimeInterval: 0.5)
    let fresh = try #require(hub.answer(.init(op: "look", device: id, path: png)).look)
    #expect(!hub.answer(.init(op: "tap", device: id, x: 1000, y: 10, look: fresh)).ok)
    device.failing = DeviceSession.Failure.invalid("can't type that") // the device's own refusal, nothing sent
    #expect(!hub.answer(.init(op: "type", device: id, text: "é", look: fresh)).ok)
    device.failing = DeviceSession.Failure.notBegun("no connection")
    #expect(!hub.answer(.init(op: "tap", device: id, x: 10, y: 10, look: fresh)).ok)
    device.failing = nil
    let soon = timed(.init(op: "type", device: id, text: "c", look: fresh))
    #expect(soon.ok && soon.took < 0.2, "\(soon.took)")
}

/// What fails before a call begins says so: no connection had, a pairing not read, a session closed.
@Test func whatFailsBeforeACallBeginsSaysSo() throws {
    func notBegun(_ call: () throws -> Void) -> Bool {
        do { try call()
            return false
        } catch DeviceSession.Failure.notBegun(_) { return true } catch { return false }
    }
    let unread = DeviceSession(ip: "127.0.0.1", port: 1, pairing: {
        throw DeviceSession.Failure.message("unreadable")
    })
    #expect(notBegun {
        try unread.tap(x: 0, y: 0)
    })
    let nobody = DeviceSession(ip: "127.0.0.1", port: 1, pairing: {
        Data("x".utf8)
    })
    #expect(notBegun {
        try nobody.press("home")
    })
    nobody.close()
    #expect(notBegun {
        try nobody.type("a")
    })
}

/// The rules a look is held to are said at once, of no device: what `roamrun mcp` asks before an action.
@Test func theRulesAreSaidOfNoDevice() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (hub, _) = try standInHub(dir)
    defer { hub.stop() }
    let said = hub.answer(.init(op: "rules", device: UUID()))
    #expect(said.ok && said.rules == DeviceControlHub.rules)
}

/// A listener for a folder whose last one has just stopped. Asked again for a moment: a process
/// another test starts at that instant holds a copy of the stopped one's lock until it runs its
/// own program (the app asks again too, every half minute).
private func listenerSoon(
    in dir: URL,
    _ handler: @escaping @Sendable (DeviceControlWire.Request) -> DeviceControlWire.Response
) -> DeviceControlWire.Listener? {
    for _ in 0 ..< 300 {
        if let listener = DeviceControlWire.Listener(directory: dir, handler: handler) {
            return listener
        }
        usleep(10_000)
    }
    return nil
}

/// A second copy started beside the app (a screenshot run) doesn't take the socket the app
/// answers on: commands went to nobody once it had quit.
@Test func aSocketSomethingAnswersOnIsNotTaken() throws {
    // Not scratchDir(): a socket's path has to fit in 104 bytes.
    let dir = URL(fileURLWithPath: "/tmp/rr-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = try #require(DeviceControlWire.Listener(directory: dir) { _ in
        .init(ok: true, name: "first")
    })
    defer { first.stop() }
    #expect(DeviceControlWire.Listener(directory: dir) { _ in
        .init(ok: true, name: "second")
    } == nil)
    #expect(try DeviceControlWire.ask(.init(op: "state", device: UUID()), in: dir).name == "first")
    // Once it has ended, the next takes over — and the one that ended, asked to stop again,
    // doesn't remove the socket that is the next one's by then.
    first.stop()
    let next = try #require(listenerSoon(in: dir) { _ in
        .init(ok: true, name: "next")
    })
    defer { next.stop() }
    first.stop()
    #expect(try DeviceControlWire.ask(.init(op: "state", device: UUID()), in: dir).name == "next")
    // A socket left by a run that ended without removing it (its lock went with it) is replaced.
    next.stop()
    let sock = DeviceControlWire.socketPath(in: dir)
    FileManager.default.createFile(atPath: sock, contents: nil)
    let after = try #require(listenerSoon(in: dir) { _ in
        .init(ok: true, name: "after")
    })
    defer { after.stop() }
    #expect(try DeviceControlWire.ask(.init(op: "state", device: UUID()), in: dir).name == "after")
}

/// Many started at once for one folder: one listens, and its socket is there to be asked —
/// none of the others removed it on its way out.
@Test func ofManyStartedAtOnceOneListens() throws {
    let dir = URL(fileURLWithPath: "/tmp/rr-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for _ in 0 ..< 20 {
        var listening: [DeviceControlWire.Listener] = []
        // Asked again when none of the eight got it: a process another test starts at that moment
        // holds a copy of the last round's lock until it execs. Never more than one, either way.
        for _ in 0 ..< 100 where listening.isEmpty {
            let made = OSAllocatedUnfairLock<[DeviceControlWire.Listener]>(initialState: [])
            DispatchQueue.concurrentPerform(iterations: 8) { n in
                if let l = DeviceControlWire.Listener(directory: dir, handler: { _ in
                    .init(ok: true, name: "\(n)")
                }) {
                    made.withLock {
                        $0.append(l)
                    }
                }
            }
            listening = made.withLock {
                $0
            }
            if listening.isEmpty {
                usleep(10_000)
            }
        }
        #expect(listening.count == 1)
        #expect((try? DeviceControlWire.ask(.init(op: "state", device: UUID()), in: dir))?.ok == true)
        listening.forEach {
            $0.stop()
        }
    }
}

/// A request that waited its turn behind another isn't begun once its asker has left: a lock
/// button asked for and given up on would otherwise be pressed minutes later, for nobody.
@Test func aRequestWhoseAskerLeftIsNotBegun() throws {
    let dir = URL(fileURLWithPath: "/tmp/rr-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try scratchPairing(at: DeviceControlWire.pairingFile(udid: "UDID-1", in: dir))
    let made = OSAllocatedUnfairLock<[StandInDevice]>(initialState: [])
    let hub = DeviceControlHub(directory: dir, key: { _ in
        scratchKey
    }) { _, _, _ in
        let device = StandInDevice()
        made.withLock {
            $0.append(device)
        }
        return device
    }
    defer { hub.stop() }
    let id = UUID()
    hub.update([.init(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-1")])
    let device = try #require(made.withLock {
        $0.first
    })
    hub.start()

    // A look that is held up has the device; a press asked for meanwhile waits behind it.
    device.hold = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        _ = hub.answer(.init(op: "look", device: id, path: lookFile(in: dir)))
    }
    #expect(soon(device.lookBegan))
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = DeviceControlWire.socketPath(in: dir)
    withUnsafeMutableBytes(of: &address.sun_path) {
        $0.copyBytes(from: path.utf8.prefix($0.count - 1))
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    #expect(connected == 0)
    let line = try JSONEncoder()
        .encode(DeviceControlWire.Request(op: "press", device: id, text: "lock")) + Data("\n".utf8)
    #expect(line.withUnsafeBytes {
        write(fd, $0.baseAddress, $0.count)
    } == line.count)
    Thread.sleep(forTimeInterval: 0.3) // read by the app, and waiting its turn
    close(fd) // the asker leaves
    Thread.sleep(forTimeInterval: 0.2)
    device.hold?.signal() // the look ends: the press's turn
    Thread.sleep(forTimeInterval: 0.5)
    #expect(!device.calls.contains("press"))
    // One whose asker is still there is begun as ever.
    #expect(hub.answer(.init(op: "press", device: id, text: "home")).ok)
    #expect(device.calls
        .filter {
            $0 == "press"
        }
        .count == 1)
}

/// A saved device a pairing was brought for counts as kept only once the list is written, also
/// when nothing about it changes: it can be here and not in the file, and the pairing's file is
/// removed on this answer.
@Test func aSavedDeviceIsKeptOnlyOnceTheListIsWritten() {
    func device(_ name: String, udid: String?) -> DeviceProfile {
        var d = DeviceProfile(
            displayName: name,
            instanceName: name,
            serviceType: "_remotepairing._tcp",
            domain: "local.",
            remotePairingPort: 49152,
            bonjourHost: "x.local.",
            txt: [:],
            providerID: "tailscale",
            providerHostName: name,
            providerIP: "100.64.0.1"
        )
        d.udid = udid
        return d
    }
    let known = device("iPhone", udid: "0000-ABCD"), unknown = device("iPad", udid: nil)
    let list = [known, unknown]
    var asked: [[DeviceProfile]] = []
    // Its UDID known already: nothing to change, and still asked to be written.
    #expect(AppCoordinator.keepSaved(known.id, udid: "0000-abcd", in: list, save: {
        asked.append($0)
        return true
    }) == known)
    #expect(asked == [list])
    #expect(AppCoordinator.keepSaved(known.id, udid: "0000-abcd", in: list, save: { _ in
        false
    }) == nil)
    // Not known yet: written with it, or not kept.
    asked = []
    #expect(AppCoordinator.keepSaved(unknown.id, udid: "U2", in: list, save: {
        asked.append($0)
        return true
    })?.udid == "U2")
    #expect(asked.first?
        .first {
            $0.id == unknown.id
        }?.udid == "U2" && asked.first?.first {
            $0.id == known.id
        } == known)
    #expect(AppCoordinator.keepSaved(unknown.id, udid: "U2", in: list, save: { _ in
        false
    }) == nil)
    // Removed meanwhile: nothing to keep, and nothing asked.
    asked = []
    #expect(AppCoordinator.keepSaved(UUID(), udid: "U2", in: list, save: {
        asked.append($0)
        return true
    }) == nil)
    #expect(asked.isEmpty)
}

/// The port a pairing's file carries is the device's when it was made. Refused there, the device
/// is looked for on its other ports; any other failure (no route, a pairing it doesn't take)
/// isn't one a search would mend.
@Test func aRefusedPortIsWhatASearchMends() {
    #expect(AppCoordinator
        .portMoved(
            "this pairing opens no connection to “iPhone” at 100.64.0.1 (RemotePairing port: Connection refused (os error 61)). Nothing was saved."
        ))
    #expect(!AppCoordinator
        .portMoved("this pairing opens no connection to “iPhone” at 100.64.0.1 (timed out). Nothing was saved."))
    #expect(!AppCoordinator.portMoved("the device doesn't accept this pairing: it proved itself and refused it"))
}

/// A screen's size is asked until it is answered, a minute apart, and then kept: a look that
/// came while the device didn't say it no longer leaves every later one uncut.
@Test func aScreensSizeIsAskedAgainUntilItIsKnown() {
    var answers: [(width: Int, height: Int)?] = [nil, nil, (1179, 2556)]
    var asked = 0
    let sizes = ScreenSizes(ask: { _ in
        asked += 1
        return answers.removeFirst()
    }, retry: 60)
    let t0 = Date()
    #expect(sizes.size(of: "A", now: t0) == nil && asked == 1)
    #expect(sizes.size(of: "A", now: t0.addingTimeInterval(59)) == nil && asked == 1) // not yet again
    #expect(sizes.size(of: "A", now: t0.addingTimeInterval(60)) == nil && asked == 2)
    #expect(sizes.size(of: "A", now: t0.addingTimeInterval(120))?.width == 1179 && asked == 3)
    #expect(sizes.size(of: "A", now: t0.addingTimeInterval(121))?.height == 2556 && asked == 3) // kept
}

/// Device control looks for a device's port itself only when no bridge does, only when the
/// device answered and refused the port, and not more than every ten minutes.
@Test func deviceControlLooksForAMovedPortWhenNoBridgeDoes() {
    let refused = "RemotePairing port: Connection refused (os error 61)"
    let now = Date()
    #expect(AppCoordinator.controlWantsPortScan(why: refused, bridgeAtWork: false, lastScan: nil, now: now))
    #expect(!AppCoordinator.controlWantsPortScan(
        why: refused,
        bridgeAtWork: true,
        lastScan: nil,
        now: now
    )) // it finds the port itself
    // A device that doesn't answer (away, asleep) isn't searched: thousands of probes for nothing.
    #expect(!AppCoordinator.controlWantsPortScan(
        why: "RemotePairing port: Operation timed out (os error 60)",
        bridgeAtWork: false,
        lastScan: nil,
        now: now
    ))
    #expect(!AppCoordinator.controlWantsPortScan(
        why: "the device doesn't accept this pairing: it proved itself and refused it",
        bridgeAtWork: false,
        lastScan: nil,
        now: now
    ))
    #expect(!AppCoordinator.controlWantsPortScan(
        why: refused,
        bridgeAtWork: false,
        lastScan: now.addingTimeInterval(-599),
        now: now
    ))
    #expect(AppCoordinator.controlWantsPortScan(
        why: refused,
        bridgeAtWork: false,
        lastScan: now.addingTimeInterval(-600),
        now: now
    ))
    // A search that found nothing (the device on cellular refuses every port): the next waits four times as long, up to a day.
    #expect(!AppCoordinator.controlWantsPortScan(
        why: refused,
        bridgeAtWork: false,
        lastScan: now.addingTimeInterval(-2399),
        misses: 1,
        now: now
    ))
    #expect(AppCoordinator.controlWantsPortScan(
        why: refused,
        bridgeAtWork: false,
        lastScan: now.addingTimeInterval(-2400),
        misses: 1,
        now: now
    ))
    #expect(!AppCoordinator.controlWantsPortScan(
        why: refused,
        bridgeAtWork: false,
        lastScan: now.addingTimeInterval(-86399),
        misses: 9,
        now: now
    ))
    #expect(AppCoordinator.controlWantsPortScan(
        why: refused,
        bridgeAtWork: false,
        lastScan: now.addingTimeInterval(-86400),
        misses: 9,
        now: now
    ))
}

/// What the app answers from what it has at hand is waited for a moment, not as long as a text takes.
@Test func aQuestionWaitsOnlyAsLongAsItIsGiven() throws {
    // Not scratchDir(): a socket's path has to fit in 104 bytes.
    let dir = URL(fileURLWithPath: "/tmp/rr-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let listener = try #require(listenerSoon(in: dir) { _ in
        Thread.sleep(forTimeInterval: 3)
        return .init(ok: true)
    })
    defer { listener.stop() }
    let began = Date()
    #expect(throws: (any Error).self) { try DeviceControlWire.ask(.init(op: "state", device: UUID()), in: dir, wait: 1)
    }
    #expect(Date().timeIntervalSince(began) < 2.5)
}

/// A device that can't be reached is tried less and less often, up to every five minutes.
@Test func aDeviceOutOfReachIsTriedLessOften() {
    #expect((1 ... 6).map {
        DeviceControlHub.retryDelay(afterFailures: $0)
    } == [30, 60, 120, 240, 300, 300])
    #expect(DeviceControlHub.retryDelay(afterFailures: 0) == 30 && DeviceControlHub
        .retryDelay(afterFailures: 1000) == 300)
}

/// A look right after an input waits out the rest of the settling time; a later one doesn't wait.
@Test func aLookWaitsForTheScreenToSettleAfterAnInput() {
    let now = Date()
    #expect(DeviceControlHub.settleWait(acted: nil, now: now) == 0)
    #expect(DeviceControlHub.settleWait(acted: now, now: now) == DeviceControlHub.settle)
    #expect(abs(DeviceControlHub
            .settleWait(acted: now.addingTimeInterval(-0.4), now: now) - (DeviceControlHub.settle - 0.4)) < 0.001)
    #expect(DeviceControlHub.settleWait(acted: now.addingTimeInterval(-5), now: now) == 0)
    #expect(DeviceControlHub.settleWait(acted: now.addingTimeInterval(60), now: now) == DeviceControlHub
        .settle) // a clock set back
}

/// What the CLI sends for each command reaches the app as it was written.
@Test func everyRequestSurvivesTheWire() throws {
    let id = UUID()
    let requests: [DeviceControlWire.Request] = [
        .init(op: "look", device: id, path: "/tmp/a.png"),
        .init(op: "swipe", device: id, x: 1, y: 2, x2: 3, y2: 4, milliseconds: 400),
        .init(op: "paste", device: id, text: "東京 \"quoted\"\nsecond line"),
        .init(op: "elements", device: id, limit: 15),
    ]
    for r in requests {
        #expect(try JSONDecoder().decode(DeviceControlWire.Request.self, from: JSONEncoder().encode(r)) == r)
    }
    let answer = DeviceControlWire.Response(ok: true, captions: ["ホーム, ヘッダ", "a\nb"], complete: false)
    #expect(try JSONDecoder().decode(DeviceControlWire.Response.self, from: JSONEncoder().encode(answer)) == answer)
}

/// A look's number isn't counted from the same place by every run of the app: one kept from
/// before a restart isn't taken for one made since.
@Test func looksAreNotNumberedAlikeByEveryStart() throws {
    func first() throws -> Int {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (hub, _) = try standInHub(dir)
        defer { hub.stop() }
        let id = UUID()
        hub.update([.init(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-1")])
        return try #require(hub.answer(.init(op: "look", device: id, path: lookFile(in: dir))).look)
    }
    #expect(try first() != first())
}

/// The app writes a look only where it keeps looks, whatever file it is asked for.
@Test func aLookIsWrittenOnlyWhereLooksAreKept() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (hub, _) = try standInHub(dir)
    defer { hub.stop() }
    let id = UUID()
    hub.update([.init(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-1")])
    let outside = dir.appendingPathComponent("look-1.png")
    #expect(!hub.answer(.init(op: "look", device: id, path: outside.path)).ok)
    #expect(!FileManager.default.fileExists(atPath: outside.path))
    let around = DeviceControlWire.socketFolder(in: dir).appendingPathComponent("../look-2.png").path
    #expect(!hub.answer(.init(op: "look", device: id, path: around)).ok)
    #expect(!hub.answer(.init(
        op: "look",
        device: id,
        path: DeviceControlWire.socketFolder(in: dir).appendingPathComponent("sock").path
    ))
    .ok)
    #expect(hub.answer(.init(op: "look", device: id, path: lookFile(in: dir))).ok)
}

/// A look whose asker left while it was taken isn't left lying where looks are kept.
@Test func aLookNobodyWaitsForIsNotKept() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (hub, _) = try standInHub(dir)
    defer { hub.stop() }
    let id = UUID()
    hub.update([.init(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-1")])
    let png = lookFile(in: dir)
    let asked = OSAllocatedUnfairLock(initialState: 0)
    // There when its turn came, gone once the look was taken.
    let answer = hub.answer(.init(op: "look", device: id, path: png), wanted: {
        asked.withLock {
            $0 += 1
            return $0 == 1
        }
    })
    #expect(answer.error == DeviceControlHub.notGiven)
    #expect(!FileManager.default.fileExists(atPath: png))
    #expect(hub.answer(.init(op: "look", device: id, path: png)).ok)
    #expect(FileManager.default.fileExists(atPath: png))
}

/// A pairing brought in is told whether whoever brought it still waits.
@Test func anImportIsToldWhetherItsAskerWaits() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (hub, _) = try standInHub(dir)
    defer { hub.stop() }
    hub.onImport = { _, _, wanted in
        wanted() ? .init(ok: true) : .failure(DeviceControlHub.nobodyWaits)
    }
    #expect(hub.answer(.init(op: "import", device: UUID(), path: "/x"), wanted: {
        true
    })
    .ok)
    #expect(hub.answer(.init(op: "import", device: UUID(), path: "/x"), wanted: {
        false
    })
    .error == DeviceControlHub.nobodyWaits)
}

/// A request given up while it waits its turn: the app finds its asker gone. Given up before
/// it was sent, it isn't sent.
@Test func aRequestGivenUpIsSeenAsLeft() throws {
    let dir = URL(fileURLWithPath: "/tmp/rr-\(UUID().uuidString.prefix(8))") // a socket's path is short
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let reached = DispatchSemaphore(value: 0), given = DispatchSemaphore(value: 0)
    let still = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    let made = DeviceControlWire.Listener(directory: dir, answering: { _, wanted in
        reached.signal()
        held(given)
        for _ in 0 ..< 50 where wanted() {
            usleep(20_000)
        }
        let waits = wanted()
        still.withLock {
            $0 = waits
        }
        return .init(ok: true)
    })
    let listener = try #require(made)
    defer { listener.stop() }
    let asking = DeviceControlWire.Asking()
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        _ = try? DeviceControlWire.ask(.init(op: "press", device: UUID(), text: "lock"), in: dir, asking: asking)
        done.signal()
    }
    #expect(soon(reached))
    asking.giveUp()
    given.signal()
    #expect(soon(done))
    #expect(until {
        still.withLock {
            $0
        } != nil
    })
    #expect(still.withLock {
        $0
    } == false)
    #expect(throws: (any Error).self) { try DeviceControlWire.ask(
        .init(op: "press", device: UUID(), text: "lock"),
        in: dir,
        asking: asking
    ) }
    asking.again()
    #expect(reached.wait(timeout: .now()) == .timedOut) // nothing was sent meanwhile
    given.signal()
    #expect(try DeviceControlWire.ask(.init(op: "press", device: UUID(), text: "lock"), in: dir, asking: asking).ok)
}

/// A device switched off is refused to every command, and says so when asked how it stands.
@Test func aDeviceSwitchedOffIsNotOperated() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (hub, made) = try standInHub(dir)
    defer { hub.stop() }
    let id = UUID()
    hub.update([.init(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-1")])
    let on = OSAllocatedUnfairLock(initialState: false)
    hub.allowed = { _ in
        on.withLock {
            $0
        }
    }
    hub.allowedKnown = { _ in
        on.withLock {
            $0
        }
    }
    for op in ["look", "elements", "press", "type", "paste", "tap", "swipe"] {
        #expect(
            hub.answer(.init(op: op, device: id, path: lookFile(in: dir), text: "home")).error == DeviceControlHub
                .switchedOff,
            "\(op)"
        )
    }
    #expect(made().last?.calls.isEmpty == true)
    #expect(hub.answer(.init(op: "state", device: id)).allowed == false)
    #expect(hub.answer(.init(op: "state", device: id)).listUnreadable == nil)
    hub.allowedUnreadable = {
        true
    } // not the same as a switch that is off: said apart
    #expect(hub.answer(.init(op: "state", device: id)).listUnreadable == true)
    hub.allowedUnreadable = {
        false
    }
    on.withLock {
        $0 = true
    }
    #expect(hub.answer(.init(op: "press", device: id, text: "home")).ok)
    #expect(hub.answer(.init(op: "state", device: id)).allowed == true)
}

/// What answers for a device isn't that device: said when asked how it stands, apart from a
/// pairing the device refuses (pairing again isn't the answer to an address taken by another).
@Test func anotherAnsweringForADeviceIsSaid() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (hub, made) = try standInHub(dir)
    defer { hub.stop() }
    let id = UUID()
    hub.update([.init(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-1")])
    #expect(hub.answer(.init(op: "state", device: id)).another == nil && !hub.isAnother(id))
    try #require(made().last).isAnother = true
    #expect(hub.answer(.init(op: "state", device: id)).another == true && hub.isAnother(id))
    #expect(hub.answer(.init(op: "state", device: id)).refused == false)
}

/// An input stops where it is when whoever asked for it leaves, and when its device is switched
/// off: neither waits for it — a text to be typed out, or any of them for its connection.
@Test(arguments: ["type", "paste", "press", "tap", "swipe"])
func anInputIsInterruptedWhenItsAskerLeavesOrItsDeviceIsSwitchedOff(_ op: String) throws {
    for leaving in [true, false] {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hold = DispatchSemaphore(value: 0)
        let (hub, made) = try standInHub(dir) {
            $0.typeHold = hold
        }
        defer { hub.stop() }
        let id = UUID()
        hub.update([.init(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-1")])
        let device = try #require(made().last)
        let there = OSAllocatedUnfairLock(initialState: true), on = OSAllocatedUnfairLock(initialState: true)
        hub.allowedKnown = { _ in
            on.withLock {
                $0
            }
        }
        #expect(hub.answer(.init(op: "look", device: id, path: lookFile(in: dir))).ok) // a point is read off one
        let answered = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = hub.answer(.init(op: op, device: id, x: 10, y: 10, x2: 20, y2: 20, text: "home"), wanted: {
                there.withLock {
                    $0
                }
            })
            answered.signal()
        }
        #expect(soon(device.typeBegan))
        #expect(!device.calls.contains("interrupt"))
        // Its asker gone — or its pairing switched off under it, as the hub comes to know it.
        if leaving {
            there.withLock {
                $0 = false
            }
        } else {
            on.withLock {
                $0 = false
            }
        }
        #expect(soon(answered))
        #expect(device.calls.contains("interrupt"))
    }
}

/// The words the app knows the library's failures by are the library's own: reworded there,
/// a refusal or another device answering would read as a plain failure here.
@Test func theLibrarySaysItsFailuresInTheWordsTheAppKnows() throws {
    let source = try String(
        contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Rust/RoamRunDevice/src/lib.rs"),
        encoding: .utf8
    )
    // As the first words of a message it makes (a string that begins with them), which is how the app knows them.
    for words in [DeviceSession.refusal, DeviceSession.unchecked, DeviceSession.notTheDevice, DeviceSession.stopped] {
        #expect(source.contains("\"\(words)") || source.contains("format!(\"\(words)"), "\(words)")
    }
    #expect(!DeviceSession.leavesConnectionInDoubt(DeviceSession.Failure.message("stopped: told to stop where it was")))
    #expect(!DeviceSession
        .leavesConnectionInDoubt(DeviceSession.Failure
            .notBegun("stopped: its device was switched off before it began")))
    #expect(DeviceSession.leavesConnectionInDoubt(DeviceSession.Failure.notBegun("can't open")))
    #expect(DeviceSession.leavesConnectionInDoubt(DeviceSession.Failure.message("keys: BrokenPipe")))
}

/// A read that failed for being told to stop isn't tried again, nor on a new connection.
@Test func whatWasToldToStopIsNotTriedAgain() {
    var attempts = 0, reopened = 0
    #expect(throws: (any Error).self) {
        try Recovery.run(repeatable: true, attempt: { () -> Int in
            attempts += 1
            throw DeviceSession.Failure.message("stopped: told to stop where it was")
        }, pause: {}, reopen: {
            reopened += 1
            return true
        })
    }
    #expect(attempts == 1 && reopened == 0)
    attempts = 0
    #expect(throws: (any Error).self) {
        try Recovery.run(repeatable: true, attempt: { () -> Int in
            attempts += 1
            throw DeviceSession.Failure.message("frames: timed out")
        }, pause: {}, reopen: {
            reopened += 1
            return true
        })
    }
    #expect(attempts == 3 && reopened == 1)
    // An input may have arrived: it is sent once, whatever its failure.
    attempts = 0
    reopened = 0
    #expect(throws: (any Error).self) {
        try Recovery.run(repeatable: false, attempt: { () -> Int in
            attempts += 1
            throw DeviceSession.Failure.message("frames: timed out")
        }, pause: {}, reopen: {
            reopened += 1
            return true
        })
    }
    #expect(attempts == 1 && reopened == 0)
}

/// An install holds the device until it ends: other calls on it are answered that it is installing,
/// install_status says how it goes, and the app's copy is removed once it ends. Only an app RoamRun's
/// own folder holds is installed.
@Test func anInstallHoldsTheDeviceUntilItEndsAndSaysHowItWent() throws {
    let dir = URL(fileURLWithPath: "/tmp/rr-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try scratchPairing(at: DeviceControlWire.pairingFile(udid: "UDID-1", in: dir))
    let made = OSAllocatedUnfairLock<[StandInDevice]>(initialState: [])
    let hub = DeviceControlHub(directory: dir, key: { _ in
        scratchKey
    }) { _, _, _ in
        let device = StandInDevice()
        made.withLock {
            $0.append(device)
        }
        return device
    }
    defer { hub.stop() }
    let id = UUID()
    hub.update([.init(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-1")])
    let device = try #require(made.withLock {
        $0.first
    })
    hub.start()
    func app(_ name: String) throws -> String {
        let folder = DeviceControlWire.socketFolder(in: dir)
            .appendingPathComponent(name)
            .appendingPathComponent("App.app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.App"],
            format: .xml,
            options: 0
        )
        .write(to: folder.appendingPathComponent("Info.plist"))
        return folder.path
    }
    func status(_ install: String?) -> DeviceControlWire.Response {
        hub.answer(.init(op: "install_status", device: id, install: install))
    }

    #expect(status(nil).said?.hasPrefix("no install was begun") == true)
    #expect(!hub.answer(.init(op: "install", device: id, path: "/tmp/App.ipa")).ok)
    let elsewhere = dir.appendingPathComponent("install-1").appendingPathComponent("App.app").path
    try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
    #expect(!hub.answer(.init(op: "install", device: id, path: elsewhere)).ok)
    // Not in a folder of its own there: refused too.
    let loose = DeviceControlWire.socketFolder(in: dir).appendingPathComponent("install-2.app").path
    try FileManager.default.createDirectory(atPath: loose, withIntermediateDirectories: true)
    #expect(!hub.answer(.init(op: "install", device: id, path: loose)).ok)
    #expect(!device.calls.contains("install"))

    device.installHold = DispatchSemaphore(value: 0)
    let path = try app("install-a")
    let begun = hub.answer(.init(op: "install", device: id, path: path))
    let install = try #require(begun.install)
    #expect(begun.ok && begun.said?.contains("install \(install)") == true)
    #expect(soon(device.installBegan))
    let busy = hub.answer(.init(op: "press", device: id, text: "home"))
    #expect(!busy.ok && busy.error?.hasPrefix("installing com.example.App on iPhone") == true)
    // The device found at another port meanwhile, its session made anew: the install still holds the device.
    hub.update([.init(id: id, name: "iPhone", ip: "127.0.0.1", port: 2, udid: "UDID-1")])
    #expect(made.withLock {
        $0.count
    } == 2)
    let stillBusy = hub.answer(.init(op: "press", device: id, text: "home"))
    #expect(!stillBusy.ok && stillBusy.error?.hasPrefix("installing com.example.App on iPhone") == true)
    #expect(status(install).said?.hasPrefix("installing com.example.App") == true)
    #expect(!status("another").ok)
    // The same path asked for again meanwhile: refused, and the folder the install takes it from stays.
    #expect(!hub.answer(.init(op: "install", device: id, path: path)).ok)
    #expect(FileManager.default.fileExists(atPath: path))
    device.installHold?.signal()
    var said = status(install)
    for _ in 0 ..< 100 where said.said?.hasPrefix("installing") == true {
        Thread.sleep(forTimeInterval: 0.02)
        said = status(install)
    }
    #expect(said.ok && said.said?.contains("is installed on iPhone") == true && said.said?
        .contains("launch takes it") == true)
    #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path))
    let launched = hub.answer(.init(op: "launch", device: id, text: "com.example.App"))
    #expect(launched.ok && launched.pid == 42)

    // One that fails says why, and it is gone too. (On the session made anew.)
    let anew = try #require(made.withLock {
        $0.last
    })
    anew.failing = DeviceSession.Failure.message("install: the device said no")
    let again = try app("install-b")
    let second = try #require(hub.answer(.init(op: "install", device: id, path: again)).install)
    var failed = status(second)
    for _ in 0 ..< 100 where failed.said?.hasPrefix("installing") == true {
        Thread.sleep(forTimeInterval: 0.02)
        failed = status(second)
    }
    #expect(!failed.ok && failed.error?.contains("the device said no") == true)
    // The earlier one is still said, by its id.
    #expect(status(install).said?.contains("is installed on iPhone") == true)
    #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: again).deletingLastPathComponent().path))

    // Refused by the app's own check: its folder goes too. Given through a link and `..`, it is the folder that was
    // checked that goes, not where the link leads (which has no App.ipa: the path is then taken as install-c's own).
    anew.failing = nil
    let control = DeviceControlWire.socketFolder(in: dir)
    let own = control.appendingPathComponent("install-c")
    let outside = dir.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: outside.appendingPathComponent("sub"),
        withIntermediateDirectories: true
    )
    try Data("not an ipa".utf8).write(to: own.appendingPathComponent("App.ipa"))
    try Data("keep".utf8).write(to: outside.appendingPathComponent("canary"))
    try FileManager.default.createSymbolicLink(at: own.appendingPathComponent("link"),
                                               withDestinationURL: outside.appendingPathComponent("sub"))
    let refused = hub.answer(.init(op: "install", device: id, path: own.appendingPathComponent("link/../App.ipa").path))
    #expect(!refused.ok)
    #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("canary").path))
    #expect(!FileManager.default.fileExists(atPath: own.path))
}

/// What the app's start sweeps away of apps left to install: one left two minutes ago or more, not one a CLI is copying.
@Test func onlyAnInstallCopyLeftAWhileIsSweptAtStart() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let left = folder.appendingPathComponent("install-old"), fresh = folder.appendingPathComponent("install-new")
    try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-300)], ofItemAtPath: left.path)
    #expect(DeviceControlWire.leftToInstall(left))
    #expect(!DeviceControlWire.leftToInstall(fresh))
    #expect(!DeviceControlWire.leftToInstall(folder.appendingPathComponent("look-1.png")))
    // An upload a killed server left: only once a day old.
    let upload = folder.appendingPathComponent("upload-x.ipa")
    try Data("x".utf8).write(to: upload)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-3600)],
        ofItemAtPath: upload.path
    )
    #expect(!DeviceControlWire.leftToInstall(upload))
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-25 * 3600)],
        ofItemAtPath: upload.path
    )
    #expect(DeviceControlWire.leftToInstall(upload))
}
