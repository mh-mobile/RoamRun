import Foundation
import Testing
@testable import RoamRun
import CryptoKit
import DeviceControl
import os
import ImageIO

/// A pairing that doesn't hold the device's key (made before it was kept) opens nothing, and
/// reads as one only pairing again helps — at once, without a connection being tried.
@Test func aPairingWithoutTheDeviceKeyIsNotUsed() throws {
    let silent = try silentPort()
    defer { close(silent.fd) }
    let pairing = try scratchPairing(withDeviceKey: false)
    let session = DeviceSession(ip: "127.0.0.1", port: silent.port, pairing: {
        pairing
    })
    let asked = Date()
    #expect(throws: (any Error).self) { try session.connect() }
    #expect(Date().timeIntervalSince(asked) < 2) // refused here, not after waiting on the port
    #expect(session.isRefused && !session.isOpen)
}

/// A device knows this Mac by one identity, made once: the same at every pairing, another's elsewhere.
@Test func aMacKeepsOneIdentityForItsPairings() throws {
    func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rr-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    let (here, there) = (try scratch(), try scratch())
    defer { [here, there].forEach {
        try? FileManager.default.removeItem(at: $0)
    } }
    let first = DeviceControlHub.hostID(in: here)
    #expect(UUID(uuidString: first) != nil)
    #expect(DeviceControlHub.hostID(in: here) == first)
    #expect(DeviceControlHub.hostID(in: there) != first)
    try Data("not an id".utf8).write(to: here.appendingPathComponent("device-control-host")) // damaged: made anew
    #expect(UUID(uuidString: DeviceControlHub.hostID(in: here)) != nil)
}

/// A new pairing takes the saved one's place whole, its owner's only, and nothing of the old
/// one is kept — also not what a build before the sealing left as it was: it holds a private key.
@Test func aNewPairingReplacesTheSavedOne() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = DeviceControlWire.pairingFile(udid: "X", in: dir)
    func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }
    try DeviceControlHub.save(Data("first".utf8), as: file)
    try Data("as it was".utf8).write(to: dir.appendingPathComponent("device-pairing-X.plist"))
    try DeviceControlHub.save(Data("second".utf8), as: file)
    #expect(names() == ["device-pairing-X.sealed"])
    #expect(try Data(contentsOf: file) == Data("second".utf8))
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    // Nowhere to write: what is saved stays.
    #expect(throws: (any Error).self) { try DeviceControlHub.save(
        Data("third".utf8),
        as: dir.appendingPathComponent("gone/x.sealed")
    ) }
    #expect(try Data(contentsOf: file) == Data("second".utf8))
}

/// What is saved opens with this Mac's key and no other, and shows nothing of the pairing: a
/// copy of the file is of no use to whoever takes it.
@Test func aSavedPairingOpensOnlyWithItsKey() throws {
    let pairing = try scratchPairing()
    let sealed = try DeviceControlHub.seal(pairing, with: scratchKey)
    #expect(try DeviceControlHub.unseal(sealed, with: scratchKey) == pairing)
    #expect(sealed.range(of: Data("private_key".utf8)) == nil)
    #expect(try DeviceControlHub.seal(pairing, with: scratchKey) != sealed) // sealed anew each time
    #expect(throws: (any Error).self) { try DeviceControlHub.unseal(sealed, with: SymmetricKey(size: .bits256)) }
    #expect(throws: (any Error).self) { try DeviceControlHub.unseal(pairing, with: scratchKey) } // one kept as it was
}

/// A saved pairing that can't be read is of no use however often it is tried: it stands as one
/// to make again, not as a connection being waited for.
@Test func aPairingThatCannotBeReadIsNotTriedAgain() throws {
    let reads = OSAllocatedUnfairLock(initialState: 0)
    let session = DeviceSession(ip: "127.0.0.1", port: 1, pairing: {
        reads.withLock {
            $0 += 1
        }
        throw DeviceSession.Failure.message("unreadable")
    })
    #expect(!session.isRefused)
    #expect(throws: (any Error).self) { try session.connect() }
    #expect(session.isRefused && !session.isOpen)
    // The hub leaves such a session alone.
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("not sealed with this key".utf8).write(to: DeviceControlWire.pairingFile(udid: "UDID-1", in: dir))
    let hub = DeviceControlHub(directory: dir, key: { _ in
        scratchKey
    })
    defer { hub.stop() }
    let id = UUID()
    hub.update([.init(id: id, name: "x", ip: "127.0.0.1", port: 1, udid: "UDID-1")])
    // Tried here, not waited for: when the hub's own try runs is the queue's to say.
    let held = try #require(hub.session(of: id))
    #expect(throws: (any Error).self) { try held.connect() }
    #expect(hub.state(of: id, udid: "UDID-1") == (true, false, true))
}

/// A pairing made on another Mac is kept only if it opens a connection, and then as this Mac
/// keeps its own: sealed with its key, and held from then on.
@Test func aPairingMadeElsewhereIsTakenInOnlyIfItConnects() throws {
    final class Unreachable: ControlledDevice, @unchecked Sendable {
        var isOpen: Bool {
            false
        }

        var isRefused: Bool {
            false
        }

        func connect() throws {
            throw DeviceSession.Failure.message("no route")
        }

        func check() {}
        func letGo() {}
        func close() {}
        func look() throws -> CGImage {
            throw DeviceSession.Failure.message("no")
        }

        func elements(limit: Int) throws -> (captions: [String], complete: Bool) {
            ([], true)
        }

        func tap(x: Double, y: Double) throws {}
        func swipe(from: (x: Double, y: Double), to: (x: Double, y: Double), milliseconds: Int) throws {}
        func type(_ text: String) throws {}
        func paste(_ text: String) throws {}
        func press(_ button: String) throws {}
    }
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let pairing = try scratchPairing()
    let target = DeviceControlHub.Target(id: UUID(), name: "iPhone", ip: "100.64.0.1", port: 49152, udid: "UDID-9")
    let file = DeviceControlWire.pairingFile(udid: "UDID-9", in: dir)

    // What an import does, in its order: tried, sealed, held (the app saves the device in between).
    func takeIn(_ hub: DeviceControlHub, _ pairing: Data, for target: DeviceControlHub.Target) throws {
        let sealing = try hub.tryPairing(pairing, for: target)
        try hub.sealPairing(pairing, with: sealing, udid: target.udid)
        hub.hold(target)
    }
    let away = DeviceControlHub(directory: dir, key: { _ in
        scratchKey
    }) { _, _, _ in
        Unreachable()
    }
    defer { away.stop() }
    #expect(throws: (any Error).self) { try takeIn(away, pairing, for: target) }
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(away.session(of: target.id) == nil)

    // Checked with the pairing that came, not with one read back.
    let given = OSAllocatedUnfairLock<[Data]>(initialState: [])
    let hub = DeviceControlHub(directory: dir, key: { _ in
        scratchKey
    }) { _, read, _ in
        if let data = try? read() {
            given.withLock {
                $0.append(data)
            }
        }
        return StandInDevice()
    }
    defer { hub.stop() }
    try takeIn(hub, pairing, for: target)
    #expect(given.withLock {
        $0.first
    } == pairing)
    #expect(try DeviceControlHub.unseal(Data(contentsOf: file), with: scratchKey) == pairing)
    #expect(hub.state(of: target.id, udid: "UDID-9") == (true, true, false)) // held, and said to be connected at once

    // A key the Keychain won't give: nothing is tried, nothing saved.
    let other = DeviceControlHub.Target(id: UUID(), name: "iPad", ip: "100.64.0.2", port: 49152, udid: "UDID-8")
    let keyless = DeviceControlHub(directory: dir, key: { _ in
        throw DeviceSession.Failure.message("refused")
    }) { _, _, _ in
        StandInDevice()
    }
    defer { keyless.stop() }
    #expect(throws: (any Error).self) { try takeIn(keyless, pairing, for: other) }
    #expect(!FileManager.default.fileExists(atPath: DeviceControlWire.pairingFile(udid: "UDID-8", in: dir).path))
}

/// A pairing brought for a device that already has one is tried without anything being written:
/// if its device then can't be saved, the pairing that worked before is still the one here.
@Test func tryingAPairingLeavesTheOneSavedBefore() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let before = try scratchPairing(), brought = try scratchPairing()
    let target = DeviceControlHub.Target(id: UUID(), name: "iPhone", ip: "100.64.0.1", port: 49152, udid: "UDID-9")
    let file = DeviceControlWire.pairingFile(udid: "UDID-9", in: dir)
    try DeviceControlHub.save(DeviceControlHub.seal(before, with: scratchKey), as: file)
    let sealedBefore = try Data(contentsOf: file)
    let hub = DeviceControlHub(directory: dir, key: { _ in
        scratchKey
    }) { _, _, _ in
        StandInDevice()
    }
    defer { hub.stop() }

    let sealing = try hub.tryPairing(brought, for: target)
    #expect(try Data(contentsOf: file) == sealedBefore) // not a byte of it
    #expect(hub.session(of: target.id) == nil) // nor held yet
    // The device couldn't be saved: nothing more is asked of the hub, and the earlier one opens.
    #expect(try DeviceControlHub.unseal(Data(contentsOf: file), with: scratchKey) == before)

    // Sealing is the file alone — no connection made, nothing held: it can be done in one turn
    // with the saving of the device. Holding comes after.
    try hub.sealPairing(brought, with: sealing, udid: "UDID-9")
    #expect(try DeviceControlHub.unseal(Data(contentsOf: file), with: scratchKey) == brought)
    #expect(hub.session(of: target.id) == nil)
    hub.hold(target)
    #expect(hub.state(of: target.id, udid: "UDID-9") == (true, true, false))
}

/// The file a pairing travels in holds the device with it, and is read only as that.
@Test func aSharedPairingIsReadOnlyAsOne() throws {
    var device = DeviceProfile(
        displayName: "iPhone",
        instanceName: "abc",
        serviceType: "_remotepairing._tcp",
        domain: "local.",
        remotePairingPort: 49152,
        bonjourHost: "x.local.",
        txt: ["a": "b"],
        providerID: "tailscale",
        providerHostName: "iphone",
        providerIP: "100.64.0.1"
    )
    device.udid = "UDID-9"
    let shared = SharedPairing(device: device, pairing: "<plist/>")
    let data = try JSONEncoder().encode(shared)
    #expect(SharedPairing.read(data) == shared)
    #expect(SharedPairing.read(Data("<plist/>".utf8)) == nil) // a bare pairing
    #expect(SharedPairing.read(try JSONEncoder().encode(device)) == nil) // a device alone
    var nameless = shared
    nameless.device.udid = nil
    #expect(SharedPairing.read(try JSONEncoder().encode(nameless)) == nil) // nothing to name the pairing by
    var empty = shared
    empty.pairing = ""
    #expect(SharedPairing.read(try JSONEncoder().encode(empty)) == nil)
    var later = shared
    later.roamrunPairing = 2
    #expect(SharedPairing.read(try JSONEncoder().encode(later)) == nil) // a form this RoamRun doesn't know
}

/// The file a pairing came in is a key for as long as it is there: one that couldn't be removed
/// is said to be, not passed over — and it is the file that was read that is removed, not
/// whatever its name has come to be.
@Test func aPairingFileLeftBehindIsSaidToBe() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("k.json")
    try Data("x".utf8).write(to: file)
    var (fd, data) = try DeviceControlHub.readTaken(file.path)
    #expect(data == Data("x".utf8))
    let left = try #require(DeviceControlHub.removeTaken(file, readThrough: fd) { _ in
        throw CocoaError(.fileWriteVolumeReadOnly)
    })
    #expect(left.contains(file.path) && left.contains("delete it yourself"))
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(DeviceControlHub.removeTaken(file, readThrough: fd) == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    close(fd)

    // Moved aside and another put in its place while it was read: that one is not removed, and
    // the one read is said to be still about.
    try Data("the pairing".utf8).write(to: file)
    (fd, data) = try DeviceControlHub.readTaken(file.path)
    defer { close(fd) }
    try FileManager.default.moveItem(at: file, to: dir.appendingPathComponent("kept.json"))
    try Data("another's".utf8).write(to: file)
    let moved = try #require(DeviceControlHub.removeTaken(file, readThrough: fd))
    #expect(moved.contains("another name"))
    #expect(try String(contentsOf: file, encoding: .utf8) == "another's")
}

/// A pairing is taken in from the one file it is in. Through a link, the link would be removed
/// and the pairing left where it is; with a second name, it would stay under that.
@Test func aPairingIsReadOnlyFromTheFileItself() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let real = dir.appendingPathComponent("real.json")
    try Data("the pairing".utf8).write(to: real)
    func refused(_ path: String, saying part: String) {
        do {
            let (fd, _) = try DeviceControlHub.readTaken(path)
            close(fd)
            Issue.record("\(path) was read")
        } catch { #expect("\(error)".contains(part), "\(error)") }
    }
    let link = dir.appendingPathComponent("link.json").path
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real.path)
    refused(link, saying: "is a link")
    let second = dir.appendingPathComponent("second.json")
    try FileManager.default.linkItem(at: real, to: second)
    refused(real.path, saying: "another name")
    try FileManager.default.removeItem(at: second)
    refused(dir.path, saying: "isn't a file")
    let pipe = dir.appendingPathComponent("pipe").path
    #expect(mkfifo(pipe, 0o600) == 0)
    refused(pipe, saying: "isn't a file") // and without waiting for a writer
    let big = dir.appendingPathComponent("big.json")
    try Data(count: 1 << 20).write(to: big)
    refused(big.path, saying: "isn't a pairing")
    refused(dir.appendingPathComponent("none.json").path, saying: "can't read")
    // With its one name again, it is read.
    let (fd, data) = try DeviceControlHub.readTaken(real.path)
    close(fd)
    #expect(data == Data("the pairing".utf8))
    #expect(try String(contentsOf: real, encoding: .utf8) == "the pairing")
}

/// Where a pairing made elsewhere goes is worked out without saving anything: a pairing that
/// then doesn't connect leaves the saved devices as they were, the UDID of one not yet known too.
@Test func placingAPairingSavesNothing() throws {
    func device(_ name: String, ip: String, instance: String, udid: String?) -> DeviceProfile {
        var d = DeviceProfile(
            displayName: name,
            instanceName: instance,
            serviceType: "_remotepairing._tcp",
            domain: "local.",
            remotePairingPort: 49152,
            bonjourHost: "x.local.",
            txt: [:],
            providerID: "tailscale",
            providerHostName: name,
            providerIP: ip
        )
        d.udid = udid
        return d
    }
    let known = device("iPhone", ip: "100.64.0.1", instance: "a", udid: "0000-ABCD")
    let unknown = device("iPad", ip: "100.64.0.2", instance: "b", udid: nil)
    let saved = [known, unknown]
    let came = device("Phone there", ip: "100.64.0.9", instance: "z", udid: nil)

    // One saved under that UDID, however it is spelled: that one, as it is.
    #expect(try saved.placement(of: came, udid: "0000-abcd", as: nil).get() == DevicePlacement(
        profile: known,
        isNew: false
    ))
    // One whose UDID isn't known yet, at that address or by that advert: that one — and still
    // without a UDID: it is saved only once the pairing has connected.
    var at = came
    at.providerIP = "100.64.0.2"
    #expect(try saved.placement(of: at, udid: "U2", as: nil).get() == DevicePlacement(profile: unknown, isNew: false))
    var advert = came
    advert.instanceName = "b"
    #expect(try saved.placement(of: advert, udid: "U2", as: "Other").get().profile.udid == nil)
    // A device known by another UDID isn't taken for it by its address.
    var sameAddress = came
    sameAddress.providerIP = "100.64.0.1"
    #expect(try saved.placement(of: sameAddress, udid: "U3", as: nil).get().isNew)
    // None: one to add, new here, under the name asked for.
    let new = try saved.placement(of: came, udid: "U9", as: " Work phone ").get()
    #expect(new.isNew && new.profile.id != came.id && new.profile.udid == "U9" && new.profile
        .displayName == "Work phone")
    #expect(new.profile.providerIP == came.providerIP && new.profile.instanceName == came.instanceName)
    // A name taken here: refused, with what to do.
    var clash = came
    clash.displayName = "iphone"
    guard case .failure(let why) = saved.placement(of: clash, udid: "U9", as: nil)
    else { Issue.record("placed under a taken name")
        return
    }
    #expect("\(why)".contains("--as"))
    #expect(try saved.placement(of: clash, udid: "U9", as: "Second").get().isNew)
}

/// A pairing that was to be removed and whose file wouldn't go is out of use all the same: the
/// device isn't operated again on what "removed" left behind.
@Test func aPairingThatCouldNotBeRemovedIsNotUsed() throws {
    let dir = scratchDir()
    defer {
        chmod(dir.path, 0o700)
        try? FileManager.default.removeItem(at: dir)
    }
    let (hub, _) = try standInHub(dir)
    defer { hub.stop() }
    let id = UUID()
    let target = DeviceControlHub.Target(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-1")
    hub.update([target])
    #expect(hub.answer(.init(op: "press", device: id, text: "home")).ok)
    let said = OSAllocatedUnfairLock<[String]>(initialState: [])
    hub.onLog = { message, _ in
        said.withLock {
            $0.append(message)
        }
    }
    #expect(chmod(dir.path, 0o500) == 0) // nothing in it can be removed
    hub.unpair(target)
    #expect(FileManager.default.fileExists(atPath: DeviceControlWire.pairingFile(udid: "UDID-1", in: dir).path))
    #expect(!hub.answer(.init(op: "press", device: id, text: "home")).ok)
    #expect(!hub.state(of: id, udid: "UDID-1").open)
    #expect(said.withLock {
        $0
    }
    .contains {
        $0.contains("couldn't be removed")
    })
    #expect(!said.withLock {
        $0
    }
    .contains("device control: pairing removed"))
    hub.update([target]) // the list saved again: still not taken up
    #expect(!hub.answer(.init(op: "press", device: id, text: "home")).ok)
}

/// What a build before the sealing left as it was is removed when the app starts: each holds a
/// private key the device may still take. Nothing else in the folder is touched.
@Test func pairingsLeftUnsealedAreRemoved() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let kept = ["device-pairing-A.sealed", "profiles.json", "device-control-host", "other.plist"]
    let gone = ["device-pairing-A.plist", "device-pairing-B.plist", "device-pairing-B.plist.previous",
                "device-pairing-A.sealed.writing-0F5B6A7C"] // a saving that didn't get to its end
    for name in kept + gone {
        try Data("x".utf8).write(to: dir.appendingPathComponent(name))
    }
    DeviceControlHub.removeUnsealed(in: dir)
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)) == Set(kept))
}

/// The key is made only when the Keychain says there is none, and only to save a pairing:
/// after a refusal a new one would leave every saved pairing unreadable.
@Test func theKeyIsMadeOnlyWhenThereIsNone() throws {
    let saved = Data(repeating: 7, count: 32)
    func key(make: Bool, read: [(OSStatus, Data?)], add: OSStatus = errSecSuccess) -> (key: Data?, added: Int) {
        var reads = read[...], added = 0
        let key = try? DeviceControlKey.key(make: make, read: {
            reads.popFirst() ?? (errSecItemNotFound, nil)
        }, add: { _ in
            added += 1
            return add
        })
        return (key?.withUnsafeBytes {
            Data($0)
        }, added)
    }
    #expect(key(make: true, read: [(errSecSuccess, saved)]) == (saved, 0))
    for refusal in [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed] {
        #expect(key(make: true, read: [(refusal, nil)]) == (nil, 0))
    }
    #expect(key(make: false, read: [(errSecItemNotFound, nil)]) == (nil, 0)) // to read one: none is made
    let made = key(make: true, read: [(errSecItemNotFound, nil)])
    #expect(made.key?.count == 32 && made.added == 1)
    // Made by another in between: that one is the key, not ours.
    #expect(key(make: true, read: [(errSecItemNotFound, nil), (errSecSuccess, saved)], add: errSecDuplicateItem) == (
        saved,
        1
    ))
    #expect(key(make: true, read: [(errSecItemNotFound, nil)], add: errSecAuthFailed) == (nil, 1))
}

/// A refusal is asked for once: every try to connect asking again would have the Keychain ask
/// the user again. Setting a device up asks anew, and what it then gets is kept.
@Test func aRefusedKeyIsNotAskedForAgainUntilADeviceIsSetUp() throws {
    let saved = Data(repeating: 7, count: 32)
    let asked = OSAllocatedUnfairLock(initialState: 0)
    let allowed = OSAllocatedUnfairLock(initialState: false)
    let key = DeviceControlKey(read: {
        asked.withLock {
            $0 += 1
        }
        return allowed.withLock {
            $0
        } ? (errSecSuccess, saved) : (errSecUserCanceled, nil)
    }, add: { _ in
        errSecAuthFailed
    })
    #expect(throws: (any Error).self) { try key.key(make: false) }
    #expect(throws: (any Error).self) { try key.key(make: false) }
    #expect(asked.withLock {
        $0
    } == 1)
    #expect(throws: (any Error).self) { try key.key(make: true) } // set up: asked again, refused again
    #expect(asked.withLock {
        $0
    } == 2)
    allowed.withLock {
        $0 = true
    }
    #expect(throws: (any Error).self) { try key.key(make: false) } // still not asked
    #expect(asked.withLock {
        $0
    } == 2)
    #expect(try key.key(make: true).withUnsafeBytes {
        Data($0)
    } == saved)
    #expect(try key.key(make: false).withUnsafeBytes {
        Data($0)
    } == saved) // kept: the Keychain is read once
    #expect(asked.withLock {
        $0
    } == 3)
}

/// A Keychain that couldn't ask just now (locked) isn't a refusal: the next try reads again.
@Test func aLockedKeychainIsReadAgain() throws {
    let saved = Data(repeating: 7, count: 32)
    let locked = OSAllocatedUnfairLock(initialState: true)
    let asked = OSAllocatedUnfairLock(initialState: 0)
    let key = DeviceControlKey(read: {
        asked.withLock {
            $0 += 1
        }
        return locked.withLock {
            $0
        } ? (errSecInteractionNotAllowed, nil) : (errSecSuccess, saved)
    }, add: { _ in
        errSecAuthFailed
    })
    #expect(throws: (any Error).self) { try key.key(make: false) }
    locked.withLock {
        $0 = false
    }
    #expect(try key.key(make: false).withUnsafeBytes {
        Data($0)
    } == saved)
    #expect(asked.withLock {
        $0
    } == 2)
}

/// The key removed from the Keychain while the app runs is put back when a device is set up —
/// the same one: a new one would lose what is saved, and none would lose it at the next start.
@Test func aKeyRemovedFromTheKeychainIsPutBackWhenADeviceIsSetUp() throws {
    let kept = OSAllocatedUnfairLock<Data?>(initialState: Data(repeating: 7, count: 32))
    let key = DeviceControlKey(read: {
                                   kept.withLock {
                                       $0.map {
                                           (errSecSuccess, $0)
                                       } ?? (errSecItemNotFound, nil)
                                   }
                               },
                               add: { fresh in
                                   kept.withLock {
                                       $0 = fresh
                                   }
                                   return errSecSuccess
                               })
    let first = try key.key(make: false).withUnsafeBytes {
        Data($0)
    }
    kept.withLock {
        $0 = nil
    } // removed by hand
    #expect(try key.key(make: false).withUnsafeBytes {
        Data($0)
    } == first) // still at hand
    #expect(kept.withLock {
        $0
    } == nil)
    #expect(try key.key(make: true).withUnsafeBytes {
        Data($0)
    } == first)
    #expect(kept.withLock {
        $0
    } == first) // back, and the same
}

/// A key replaced in the Keychain while the app runs is not taken up: pairings saved from then
/// on would be sealed apart from the ones already saved. And what isn't a key of ours never is.
@Test func aKeyReplacedInTheKeychainIsNotTakenUp() throws {
    let ours = Data(repeating: 7, count: 32), other = Data(repeating: 9, count: 32)
    let kept = OSAllocatedUnfairLock<Data?>(initialState: ours)
    let added = OSAllocatedUnfairLock(initialState: 0)
    let key = DeviceControlKey(read: {
                                   kept.withLock {
                                       $0.map {
                                           (errSecSuccess, $0)
                                       } ?? (errSecItemNotFound, nil)
                                   }
                               },
                               add: { _ in
                                   added.withLock {
                                       $0 += 1
                                   }
                                   return errSecSuccess
                               })
    #expect(try key.key(make: true).withUnsafeBytes {
        Data($0)
    } == ours)
    kept.withLock {
        $0 = other
    }
    #expect(throws: (any Error).self) { try key.key(make: true) } // to set a device up: refused
    #expect(try key.key(make: false).withUnsafeBytes {
        Data($0)
    } == ours) // what is saved still opens
    #expect(kept.withLock {
        $0
    } == other && added.withLock {
        $0
    } == 0) // and nothing was written over
    // Not a key at all: of the wrong length, before a pairing or after.
    for bad in [Data(), Data(repeating: 1, count: 16), Data(repeating: 1, count: 33)] {
        #expect(throws: (any Error).self) {
            try DeviceControlKey.key(make: true, read: {
                (errSecSuccess, bad)
            }, add: { _ in
                errSecSuccess
            })
        }
    }
    // Made by another in between: taken only if it is one.
    var reads = [(errSecItemNotFound, Data?.none), (errSecSuccess, Data(repeating: 1, count: 5))][...]
    #expect(throws: (any Error).self) {
        try DeviceControlKey.key(make: true, read: {
            reads.popFirst() ?? (errSecItemNotFound, nil)
        }, add: { _ in
            errSecDuplicateItem
        })
    }
}

/// A pairing made again is kept though the list couldn't be saved, when the file names its
/// device already: the one before it is gone. A first pairing nothing on disk names isn't.
@Test func aPairingMadeAgainIsKeptThoughTheListWasNotSaved() {
    #expect(AppCoordinator.keepsPairing(savedNow: true, onDisk: nil, paired: "UDID-1"))
    #expect(AppCoordinator.keepsPairing(savedNow: false, onDisk: "udid-1", paired: "UDID-1"))
    #expect(!AppCoordinator.keepsPairing(savedNow: false, onDisk: nil, paired: "UDID-1"))
    #expect(!AppCoordinator.keepsPairing(savedNow: false, onDisk: "UDID-2", paired: "UDID-1"))
}

/// What is advertised for a pairing is "key=value" behind its length, 255 bytes at most, and a
/// name too long for that is cut between characters.
@Test func aPairingsAdvertIsCutBetweenCharacters() throws {
    let short = DevicePairing.txtRecord(["ver": "26", "name": "Mac"])
    #expect(Array(short) == [8] + Array("name=Mac".utf8) + [6] + Array("ver=26".utf8))
    let long = DevicePairing.txtRecord(["name": String(repeating: "あ", count: 100)]) // 5 + 300 bytes
    #expect(long.count == 1 + Int(long[0]) && long[0] <= 255)
    let text = try #require(String(data: long.dropFirst(), encoding: .utf8)) // still whole characters
    #expect(text == "name=" + String(repeating: "あ", count: 83))
}

/// A pairing whose file wouldn't go was emptied: it isn't back when RoamRun is opened again, and
/// one set up anew in its place is used.
@Test func aPairingThatCouldNotBeRemovedIsNotBackAfterAStart() throws {
    let dir = scratchDir()
    defer {
        chmod(dir.path, 0o700)
        try? FileManager.default.removeItem(at: dir)
    }
    let (hub, _) = try standInHub(dir)
    let id = UUID()
    let target = DeviceControlHub.Target(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-1")
    hub.update([target])
    #expect(chmod(dir.path, 0o500) == 0)
    #expect(hub.unpair(target) == .emptied)
    #expect(!hub.state(of: id, udid: "UDID-1").paired)
    #expect(!DeviceControlWire.hasPairing(udid: "UDID-1", in: dir)) // what `roamrun status` reads
    hub.stop()
    let (again, _) = { () -> (DeviceControlHub, () -> [StandInDevice]) in
        let made = OSAllocatedUnfairLock<[StandInDevice]>(initialState: [])
        return (DeviceControlHub(directory: dir, key: { _ in
            scratchKey
        }) { _, _, _ in
            let device = StandInDevice()
            made.withLock {
                $0.append(device)
            }
            return device
        }, {
            made.withLock {
                $0
            }
        })
    }()
    defer { again.stop() }
    again.update([target])
    #expect(!again.answer(.init(op: "press", device: id, text: "home")).ok)
    chmod(dir.path, 0o700)
    try again.sealPairing(Data("<plist/>".utf8), with: scratchKey, udid: "UDID-1")
    again.update([target])
    #expect(again.answer(.init(op: "press", device: id, text: "home")).ok)
}

/// One that could be neither removed nor emptied is said to be left, and is out of use meanwhile.
@Test func aPairingThatCouldNotEvenBeEmptiedIsSaidToBeLeft() throws {
    let dir = scratchDir()
    let file = DeviceControlWire.pairingFile(udid: "UDID-1", in: dir)
    defer {
        chflags(file.path, 0)
        try? FileManager.default.removeItem(at: dir)
    }
    let (hub, _) = try standInHub(dir)
    defer { hub.stop() }
    let id = UUID()
    let target = DeviceControlHub.Target(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-1")
    hub.update([target])
    #expect(chflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
    #expect(hub.unpair(target) == .left)
    #expect(!hub.state(of: id, udid: "UDID-1").paired)
    #expect(!hub.answer(.init(op: "press", device: id, text: "home")).ok)
}

/// A file brought in names its device only in what RoamRun itself would have written.
@Test func aSharedPairingNamesItsDeviceOnlyAsRoamRunWould() throws {
    func read(_ change: (inout DeviceProfile) -> Void) throws -> SharedPairing? {
        var device = DeviceProfile(
            displayName: "iPhone",
            instanceName: "abc",
            serviceType: "_remotepairing._tcp",
            domain: "local.",
            remotePairingPort: 49152,
            bonjourHost: "x.local.",
            txt: [:],
            providerID: "tailscale",
            providerHostName: "iphone",
            providerIP: "100.64.0.1"
        )
        device.udid = "00008130-000D00000000D004"
        change(&device)
        return SharedPairing.read(try JSONEncoder().encode(SharedPairing(device: device, pairing: "<plist/>")))
    }
    #expect(try read { _ in } != nil)
    #expect(try read {
        $0.udid = "x,name=Any iOS Device"
    } == nil)
    #expect(try read {
        $0.udid = "../../x"
    } == nil)
    #expect(try read {
        $0.providerIP = "example.com"
    } == nil)
    #expect(try read {
        $0.providerIP = "fd7a:115c:a1e0::1"
    } != nil)
    #expect(try read {
        $0.serviceType = "_ssh._tcp"
    } == nil)
    #expect(try read {
        $0.domain = "example.com"
    } == nil)
}

/// A device pairs with this in tests: it pairs when told to, or is cancelled.
private final class StandInPairing: PairingListener, @unchecked Sendable {
    let name = "RoamRun (test)"
    private let turn = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var cancelled = false
    /// Run when the device has paired, before that is handed back.
    var paired: (@Sendable () -> Void)?
    let waiting = DispatchSemaphore(value: 0)
    func pairNow() {
        turn.signal()
    }

    func accept(code: @escaping @Sendable (String) -> Void) throws -> DevicePairing.Paired {
        waiting.signal()
        held(turn)
        if lock.withLock({
            cancelled
        }) {
            throw DeviceSession.Failure.message("cancelled")
        }
        paired?()
        return .init(udid: "UDID-1", name: "iPhone", model: "iPhone16,1", pairing: Data("<plist/>".utf8))
    }

    func cancel() {
        lock.withLock {
            cancelled = true
        }
        turn.signal()
    }
}

/// A pairing cancelled once the device has paired, while it is still checked, isn't saved; one
/// cancelled after it was saved and before it is said to be done is removed at once.
@Test func aPairingCancelledWhileItIsCheckedIsNotKept() throws {
    let request = DeviceControlHub.PairingRequest(
        id: UUID(),
        name: "iPhone",
        ip: "127.0.0.1",
        port: 1,
        udid: "UDID-1",
        others: []
    )
    func steps()
        -> (said: @Sendable (DeviceControlHub.PairingStep) -> Void, all: () -> [DeviceControlHub.PairingStep],
            ended: DispatchSemaphore)
    {
        let all = OSAllocatedUnfairLock<[DeviceControlHub.PairingStep]>(initialState: [])
        let ended = DispatchSemaphore(value: 0)
        return ({ step in
            all.withLock {
                $0.append(step)
            }
            switch step { case .done, .failed: ended.signal()
            default: break }
        }, {
            all.withLock {
                $0
            }
        }, ended)
    }
    // Cancelled between the device's pairing and the saving.
    do {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (hub, _) = try standInHub(dir, paired: false)
        defer { hub.stop() }
        let listener = StandInPairing(), attempt = UUID()
        listener.paired = {
            hub.cancelPairing(attempt)
        }
        hub.listening = { _, _ in
            listener
        }
        let (said, all, ended) = steps()
        hub.pair(request, as: "x", attempt: attempt, step: said)
        #expect(soon(listener.waiting))
        listener.pairNow()
        #expect(soon(ended))
        #expect(all().last == .failed(DeviceControlHub.pairingCancelled))
        #expect(!DeviceControlWire.hasPairing(udid: "UDID-1", in: dir))
    }
    // Cancelled while the connection is tried, after the saving.
    do {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hold = DispatchSemaphore(value: 0), began = DispatchSemaphore(value: 0)
        let (hub, _) = try standInHub(dir, paired: false) { device in
            device.connectHold = hold
            Thread.detachNewThread {
                held(device.connectBegan)
                began.signal()
            }
        }
        defer { hub.stop() }
        let listener = StandInPairing(), attempt = UUID()
        hub.listening = { _, _ in
            listener
        }
        let (said, all, ended) = steps()
        hub.pair(request, as: "x", attempt: attempt, step: said)
        #expect(soon(listener.waiting))
        listener.pairNow()
        #expect(soon(began))
        #expect(DeviceControlWire.hasPairing(udid: "UDID-1", in: dir))
        hub.cancelPairing(attempt)
        #expect(!DeviceControlWire.hasPairing(udid: "UDID-1", in: dir)) // at once, not when the try returns
        for _ in 0 ..< 8 {
            hold.signal()
        }
        #expect(soon(ended))
        #expect(all().last == .failed(DeviceControlHub.pairingCancelled))
        #expect(!DeviceControlWire.hasPairing(udid: "UDID-1", in: dir))
    }
    // Not cancelled: kept and said to be done.
    do {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (hub, _) = try standInHub(dir, paired: false)
        defer { hub.stop() }
        let listener = StandInPairing()
        hub.listening = { _, _ in
            listener
        }
        let (said, all, ended) = steps()
        hub.pair(request, as: "x", step: said)
        #expect(soon(listener.waiting))
        listener.pairNow()
        #expect(soon(ended))
        #expect(all().last == .done(udid: "UDID-1", unreached: nil))
        #expect(DeviceControlWire.hasPairing(udid: "UDID-1", in: dir))
    }
}

/// A cancel is its attempt's own: another pairing begun right after doesn't undo it.
@Test func aCancelledPairingStaysCancelledWhenAnotherBegins() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (hub, _) = try standInHub(dir, paired: false)
    defer { hub.stop() }
    let request = DeviceControlHub.PairingRequest(
        id: UUID(),
        name: "iPhone",
        ip: "127.0.0.1",
        port: 1,
        udid: "UDID-1",
        others: []
    )
    let made = OSAllocatedUnfairLock<[StandInPairing]>(initialState: [])
    hub.listening = { _, _ in
        let listener = StandInPairing()
        made.withLock {
            $0.append(listener)
        }
        return listener
    }
    let first = UUID(), second = UUID()
    let firstEnd = OSAllocatedUnfairLock<DeviceControlHub.PairingStep?>(initialState: nil)
    let ended = DispatchSemaphore(value: 0)
    hub.pair(request, as: "x", attempt: first) { step in
        switch step { case .done, .failed: firstEnd.withLock {
                $0 = step
            }
            ended.signal()
        default: break }
    }
    hub.cancelPairing(first)
    hub.pair(request, as: "x", attempt: second) { _ in }
    // Whichever the device pairs with, the first is not the one that keeps it.
    for _ in 0 ..< 50 {
        made.withLock {
            $0
        }
        .forEach {
            $0.pairNow()
        }
        usleep(10_000)
    }
    #expect(soon(ended))
    if case .done = firstEnd.withLock({
        $0
    }) {
        Issue.record("the cancelled pairing was kept")
    }
    hub.cancelPairing(second)
}

/// A device let go of is told at once, on the caller's thread: a call waiting on its session
/// doesn't begin after the removal. And a folder that can't be looked into isn't a file gone.
@Test func removingLetsGoAtOnceAndAFileUnseenIsNotGone() throws {
    let dir = scratchDir()
    defer {
        chmod(dir.path, 0o700)
        try? FileManager.default.removeItem(at: dir)
    }
    let (hub, made) = try standInHub(dir)
    defer { hub.stop() }
    let id = UUID()
    let target = DeviceControlHub.Target(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-1")
    hub.update([target])
    let device = try #require(made().last)
    #expect(chmod(dir.path, 0o000) == 0)
    #expect(hub.unpair(target) == .left)
    #expect(device.calls.contains("letGo"))
}

/// The pairings switched on are whatever the Keychain gives. What it doesn't give is nobody —
/// and not an empty list to write over: another program's item (macOS asks, and is refused)
/// switches none on, and loses none of what was on.
@Test func onlyWhatTheKeychainGivesIsSwitchedOn() throws {
    let a = "mark-a", b = "mark-b"
    let stored = OSAllocatedUnfairLock<Data?>(initialState: try JSONEncoder().encode([a]))
    let reads = OSAllocatedUnfairLock<OSStatus>(initialState: errSecSuccess)
    let writes = OSAllocatedUnfairLock<OSStatus>(initialState: errSecSuccess)
    func list() -> DeviceControlAllowed {
        DeviceControlAllowed(read: {
            let status = reads.withLock {
                $0
            }
            return (status, status == errSecSuccess ? stored.withLock {
                $0
            } : nil)
        }, write: { data in
            let status = writes.withLock {
                $0
            }
            if status == errSecSuccess {
                stored.withLock {
                    $0 = data
                }
            }
            return status
        })
    }
    let first = list()
    #expect(first.known(a) == nil) // not read yet: nothing said
    #expect(first.contains(a) && !first.contains(b))
    #expect(first.set(b, true) && first.contains(b))
    #expect(list().contains(b)) // kept
    // What names no pairing in use is dropped; what does stays.
    first.prune(keeping: [a])
    #expect(first.contains(a) && !first.contains(b))
    #expect(try JSONDecoder().decode(Set<String>.self, from: try #require(stored.withLock {
        $0
    })) == [a])
    #expect(first.set(b, true))
    // A write that failed is made again when the app quits, at the latest.
    writes.withLock {
        $0 = errSecAuthFailed
    }
    #expect(!first.set(b, false))
    writes.withLock {
        $0 = errSecSuccess
    }
    first.flush()
    #expect(try JSONDecoder().decode(Set<String>.self, from: try #require(stored.withLock {
        $0
    })) == [a])
    #expect(first.set(b, true))
    // Off at once, before the Keychain is told; on again only by being switched on.
    first.offNow(b)
    #expect(!first.contains(b) && first.known(b) == false && first.contains(a))
    #expect(first.set(b, false) && !first.contains(b))
    #expect(first.set(b, true) && first.contains(b) && first.known(b) == true)
    // Off, then on, both asked before either was written: the later one stands.
    first.offNow(b)
    let offAsked = first.now(), onAsked = first.now()
    #expect(first.set(b, false, asked: offAsked) && first.set(b, true, asked: onAsked) && first.contains(b))
    // A switch-on that waited its turn doesn't undo an off asked after it was.
    let waiting = first.now()
    first.offNow("mark-late")
    #expect(first.set("mark-late", true, asked: waiting) && !first.contains("mark-late"))
    #expect(try JSONDecoder().decode(Set<String>.self, from: try #require(stored.withLock {
        $0
    })) == [a, b]) // nor written as on
    #expect(first.set("mark-late", true) && first.contains("mark-late") && first.set("mark-late", false))
    // Refused: nobody is on, it is said, and switching writes nothing over what is there.
    reads.withLock {
        $0 = errSecAuthFailed
    }
    let refused = list()
    #expect(!refused.contains(a) && refused.isUnreadable && refused.known(a) == nil)
    #expect(!refused.set(b, false) && !refused.set("mark-c", true))
    #expect(try JSONDecoder().decode(Set<String>.self, from: try #require(stored.withLock {
        $0
    })) == [a, b])
    // Given again (the user was asked, and allowed it): read when something is next switched on —
    // switching off doesn't ask.
    reads.withLock {
        $0 = errSecSuccess
    }
    #expect(!refused.set(b, false) && refused.isUnreadable)
    #expect(refused.set("mark-d", true) && refused.contains(a) && !refused.contains(b) && !refused.isUnreadable)
    // What was switched off while it couldn't be read went out with that write: not on again after a restart.
    #expect(try JSONDecoder().decode(Set<String>.self, from: try #require(stored.withLock {
        $0
    })) == [a, "mark-d"])
    #expect(refused.set("mark-d", false) && refused.set(b, true))
    // A locked Keychain will answer later: nobody is on meanwhile, and it is read again by itself.
    reads.withLock {
        $0 = errSecInteractionNotAllowed
    }
    let locked = list()
    #expect(!locked.contains(a) && !locked.isUnreadable && locked.isLocked && locked.known(a) == nil)
    reads.withLock {
        $0 = errSecSuccess
    }
    #expect(locked.contains(a) && !locked.isLocked)
    // Nothing there yet is an empty list, not an unreadable one.
    reads.withLock {
        $0 = errSecItemNotFound
    }
    let fresh = list()
    #expect(!fresh.contains(a) && !fresh.isUnreadable)
    reads.withLock {
        $0 = errSecSuccess
    }
    stored.withLock {
        $0 = Data("not a list".utf8)
    }
    #expect(!list().contains(a))
    // What can't be kept isn't switched on; switched off, it is off here all the same — and said not to be kept.
    stored.withLock {
        $0 = try? JSONEncoder().encode([a])
    }
    writes.withLock {
        $0 = errSecAuthFailed
    }
    let unkept = list()
    #expect(!unkept.set(b, true) && !unkept.contains(b))
    #expect(!unkept.set(a, false) && !unkept.contains(a))
    // Asked again, it is written again (the Keychain still has it): not answered as done.
    #expect(!unkept.set(a, false))
    writes.withLock {
        $0 = errSecSuccess
    }
    #expect(unkept.set(a, false))
    #expect(try JSONDecoder().decode(Set<String>.self, from: try #require(stored.withLock {
        $0
    })) == [])
}

/// The switch is the pairing's, not the place its device has in the list: a device given
/// another's address or UDID there is operated only if the pairing it would use is on.
@Test func theSwitchFollowsThePairingNotTheDevicesEntry() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (hub, _) = try standInHub(dir, udid: "UDID-A")
    defer { hub.stop() }
    try scratchPairing(at: DeviceControlWire.pairingFile(udid: "UDID-B", in: dir))
    let a = try #require(DeviceControlHub.pairingMark(udid: "UDID-A", in: dir))
    let b = try #require(DeviceControlHub.pairingMark(udid: "UDID-B", in: dir))
    #expect(a != b && DeviceControlHub.pairingMark(udid: "UDID-C", in: dir) == nil)
    hub.allowed = {
        $0 == a
    } // A is on, B is off
    let id = UUID() // one entry of the list, whatever it is made to name
    hub.update([.init(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-A")])
    #expect(hub.answer(.init(op: "press", device: id, text: "home")).ok)
    // The same entry rewritten to name B's pairing: off, though "its" device was on.
    hub.update([.init(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-B")])
    #expect(hub.answer(.init(op: "press", device: id, text: "home")).error == DeviceControlHub.switchedOff)
}

/// A pairing written over is dropped from the switch: the one it replaced may still be one the
/// device knows, and isn't left on for whoever kept a copy of its file.
@Test func aPairingWrittenOverIsSaidSoItsSwitchGoes() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (hub, _) = try standInHub(dir)
    defer { hub.stop() }
    let replaced = OSAllocatedUnfairLock<[String]>(initialState: [])
    hub.onReplaced = { mark in
        replaced.withLock {
            $0.append(mark)
        }
    }
    let old = try #require(DeviceControlHub.pairingMark(udid: "UDID-1", in: dir))
    let written = try hub.sealPairing(try scratchPairing(), with: scratchKey, udid: "UDID-1")
    #expect(replaced.withLock {
        $0
    } == [old])
    // What it gives is the mark of what it wrote, and stays that whatever the file becomes.
    #expect(written != old && DeviceControlHub.pairingMark(udid: "UDID-1", in: dir) == written)
    try Data("another's".utf8).write(to: DeviceControlWire.pairingFile(udid: "UDID-1", in: dir))
    #expect(hub.sealedMark(udid: "udid-1") == written && DeviceControlHub
        .pairingMark(udid: "UDID-1", in: dir) != written)
    try hub.sealPairing(try scratchPairing(), with: scratchKey, udid: "UDID-1")
    try hub
        .sealPairing(try scratchPairing(), with: scratchKey, udid: "UDID-2") // nothing there before: nothing replaced
    #expect(replaced.withLock {
        $0
    }
    .count == 2) // the first, and what was put in the file by hand
}

/// The switch is asked about the pairing a session connects with: a file put in its place — the
/// sealed pairing of a device that is on — doesn't make the session that stands usable under it.
@Test func aSessionIsOnlyAsAllowedAsThePairingItWasMadeFor() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (hub, made) = try standInHub(dir, udid: "UDID-A")
    defer { hub.stop() }
    try scratchPairing(at: DeviceControlWire.pairingFile(udid: "UDID-B", in: dir))
    let a = try #require(DeviceControlHub.pairingMark(udid: "UDID-A", in: dir))
    let b = try #require(DeviceControlHub.pairingMark(udid: "UDID-B", in: dir))
    hub.allowed = {
        $0 == b
    } // A is off, B is on
    let id = UUID()
    let target = DeviceControlHub.Target(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-A")
    hub.update([target])
    let standing = try #require(made().last)
    #expect(hub.answer(.init(op: "press", device: id, text: "home")).error == DeviceControlHub.switchedOff)
    // B's sealed file under A's name: the session that stands is still A's, and still off.
    try FileManager.default.removeItem(at: DeviceControlWire.pairingFile(udid: "UDID-A", in: dir))
    try FileManager.default.copyItem(
        at: DeviceControlWire.pairingFile(udid: "UDID-B", in: dir),
        to: DeviceControlWire.pairingFile(udid: "UDID-A", in: dir)
    )
    // (Under A's name those bytes are neither A's pairing nor B's to the switch.)
    let moved = try #require(DeviceControlHub.pairingMark(udid: "UDID-A", in: dir))
    #expect(moved != a && moved != b)
    #expect(hub.answer(.init(op: "press", device: id, text: "home")).error == DeviceControlHub.switchedOff)
    #expect(standing.calls
        .filter {
            $0 == "press"
        }
        .isEmpty)
    // Nor does it connect with what is there now — said as a call stopped, not as a pairing to make again.
    #expect { try standing.pairing?() } throws: {
        "\($0)".hasPrefix(DeviceSession.stopped)
    }
    // And a call that got its turn on it is asked about its own pairing: still off.
    #expect(standing.gated?() == false)
    hub.allowed = {
        $0 == a
    }
    #expect(standing.gated?() == true)
    hub.allowed = {
        $0 == b
    }
    // Found out by itself (every half minute), as when the list is saved again: A's session is
    // let go of, and a new one stands for the pairing that is there now.
    hub.renewChanged()
    #expect(standing.calls.contains("letGo"))
    #expect(made().count == 2 && made().last !== standing)
    hub.renewChanged()
    hub.update([target])
    #expect(made().count == 2) // and that one is left alone
}

/// A pairing cancelled after it was saved takes only what it saved with it: one brought in over
/// it meanwhile stays.
@Test func aCancelledPairingRemovesOnlyWhatItSaved() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let hold = DispatchSemaphore(value: 0), began = DispatchSemaphore(value: 0)
    let (hub, _) = try standInHub(dir, paired: false) { device in
        device.connectHold = hold
        Thread.detachNewThread {
            held(device.connectBegan)
            began.signal()
        }
    }
    defer { hub.stop() }
    let request = DeviceControlHub.PairingRequest(
        id: UUID(),
        name: "iPhone",
        ip: "127.0.0.1",
        port: 1,
        udid: "UDID-1",
        others: []
    )
    let listener = StandInPairing(), attempt = UUID()
    hub.listening = { _, _ in
        listener
    }
    let ended = DispatchSemaphore(value: 0)
    hub.pair(request, as: "x", attempt: attempt) { step in
        switch step { case .done, .failed: ended.signal()
        default: break }
    }
    #expect(soon(listener.waiting))
    listener.pairNow()
    #expect(soon(began))
    let saved = try #require(DeviceControlHub.pairingMark(udid: "UDID-1", in: dir))
    try hub.sealPairing(try scratchPairing(), with: scratchKey, udid: "UDID-1") // another, brought in meanwhile
    let brought = try #require(DeviceControlHub.pairingMark(udid: "UDID-1", in: dir))
    #expect(brought != saved)
    hub.cancelPairing(attempt)
    #expect(DeviceControlHub.pairingMark(udid: "UDID-1", in: dir) == brought)
    for _ in 0 ..< 8 {
        hold.signal()
    }
    #expect(soon(ended))
    #expect(DeviceControlHub.pairingMark(udid: "UDID-1", in: dir) == brought)
}

/// What the switch may keep is what the sessions that stand connect with (the app cuts its list
/// down to `heldMarks`). A pairing parked under another name, or whose device is gone from the
/// list, is held by none; one that can't be read for the moment still is; stopped, nothing is said.
@Test func theSwitchMayKeepOnlyWhatASessionHolds() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (hub, _) = try standInHub(dir, udid: "UDID-A")
    defer { hub.stop() }
    let changes = OSAllocatedUnfairLock(initialState: 0)
    hub.onHeldChanged = {
        changes.withLock {
            $0 += 1
        }
    }
    let a = try #require(DeviceControlHub.pairingMark(udid: "UDID-A", in: dir))
    let id = UUID()
    hub.update([.init(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-A")])
    #expect(hub.heldMarks() == [a] && changes.withLock {
        $0
    } == 1)
    // Not readable for the moment (no leave to open it) isn't gone: the session and its mark stay.
    #expect(chmod(DeviceControlWire.pairingFile(udid: "UDID-A", in: dir).path, 0o000) == 0)
    hub.renewChanged()
    hub.update([.init(id: id, name: "iPhone", ip: "127.0.0.1", port: 1, udid: "UDID-A")])
    #expect(hub.heldMarks() == [a])
    #expect(chmod(DeviceControlWire.pairingFile(udid: "UDID-A", in: dir).path, 0o600) == 0)
    // Parked under a name no device has: still a sealed pairing in the folder, held by nobody.
    let file = DeviceControlWire.pairingFile(udid: "UDID-A", in: dir),
        parked = dir.appendingPathComponent("device-pairing-parked.sealed")
    try FileManager.default.moveItem(at: file, to: parked)
    hub.renewChanged()
    #expect(hub.heldMarks() == [] && changes.withLock {
        $0
    } >= 2)
    // Put back: a session again, for the switch to be about (it was dropped meanwhile).
    try FileManager.default.moveItem(at: parked, to: file)
    hub.renewChanged()
    #expect(hub.heldMarks() == [a])
    // The same bytes under another device's name are another pairing to the switch.
    try FileManager.default.copyItem(at: file, to: DeviceControlWire.pairingFile(udid: "UDID-B", in: dir))
    #expect(DeviceControlHub.pairingMark(udid: "UDID-B", in: dir) != a)
    // Gone from the list: held by none.
    hub.update([])
    #expect(hub.heldMarks() == [])
    // Stopped: nothing is held any more, and that is not what the switch is cut down to.
    hub.stop()
    #expect(hub.heldMarks() == nil)
}

/// A sealed pairing is read only as the small file of its own it is: a link, a pipe or something
/// too large to be one is no pairing (and isn't waited on, with the hub's lock held).
@Test func aSealedPairingIsReadOnlyAsAFileOfItsOwn() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = DeviceControlWire.pairingFile(udid: "UDID-1", in: dir)
    try scratchPairing(at: file)
    #expect(DeviceControlWire.hasPairing(udid: "UDID-1", in: dir))
    let elsewhere = dir.appendingPathComponent("elsewhere")
    try FileManager.default.moveItem(at: file, to: elsewhere)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
    #expect(!DeviceControlWire.hasPairing(udid: "UDID-1", in: dir) && DeviceControlHub.pairingMark(
        udid: "UDID-1",
        in: dir
    ) == nil)
    // Known to be no pairing — not "couldn't be read just now", which would keep a session standing.
    #expect(DeviceControlWire.sealedRead(file) == (nil, true))
    try FileManager.default.removeItem(at: file)
    #expect(mkfifo(file.path, 0o600) == 0)
    let asked = Date()
    #expect(DeviceControlWire.sealedRead(file) == (nil, true))
    #expect(Date().timeIntervalSince(asked) < 1)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    #expect(DeviceControlWire.sealedRead(file) == (nil, true))
    try FileManager.default.removeItem(at: file)
    try Data(count: 1 << 20).write(to: file)
    #expect(!DeviceControlWire.hasPairing(udid: "UDID-1", in: dir))
}

/// A bundle identifier or a button's name with a NUL in it would be sent cut short at it, and reported done: refused
/// before anything is asked of the device (nor its pairing read).
@Test func aNulIsRefusedBeforeTheDeviceIsAsked() throws {
    let reads = OSAllocatedUnfairLock(initialState: 0)
    let session = DeviceSession(ip: "127.0.0.1", port: 1, pairing: {
        reads.withLock {
            $0 += 1
        }
        throw DeviceSession.Failure.message("unreadable")
    })
    func refused(_ call: () throws -> Void) -> Bool {
        do { try call() } catch let DeviceSession.Failure.invalid(why) { return why.contains("NUL") } catch {}
        return false
    }
    #expect(refused {
        _ = try session.launch("com.apple.Preferences\u{0}x")
    })
    #expect(refused {
        try session.press("home\u{0}")
    })
    #expect(reads.withLock {
        $0
    } == 0)
}
