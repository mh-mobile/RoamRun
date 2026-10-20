import Foundation
import Testing
@testable import RoamRun

// MARK: - Device names

@Test func nameClashIgnoresCaseAndSurroundingSpaces() {
    let saved = [profile("iPhone")]
    #expect(saved.isNameTaken("iphone"))
    #expect(saved.isNameTaken(" iPhone "))
    #expect(!saved.isNameTaken("iPhone 2"))
}

@Test func renamingToYourOwnNameIsFine() {
    let p = profile("iPhone")
    #expect(![p].isNameTaken("iPhone", except: p.id))
}

@Test func uniqueNameCountsUp() {
    #expect([profile("iPad")].uniqueName("iPhone") == "iPhone")
    #expect([profile("iPhone"), profile("iPhone 2")].uniqueName("iPhone") == "iPhone 3")
}

// MARK: - Device icons

@Test func iconFollowsDeviceType() {
    var p = profile("x")
    #expect(p.symbol == "iphone")
    p.deviceType = "iPad"
    #expect(p.symbol == "ipad")
    p.deviceType = "appleTV"   // unknown kinds fall back
    #expect(p.symbol == "iphone")
}

@Test func namesWithControlCharactersAreRejected() {
    #expect([DeviceProfile]().nameProblem("iPhone\u{1B}[31m") != nil)
    #expect([DeviceProfile]().nameProblem("👩\u{200D}💻 iPhone") == nil)   // ZWJ emoji is fine
}

/// What isn't a device at all, among the saved ones, costs neither the others nor the process.
@Test func aListWithSomethingElseInItKeepsItsDevices() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let one = String(decoding: try JSONEncoder().encode(profile("iPhone")), as: UTF8.self)
    try Data(#"[null, "x", 3, [], \#(one)]"#.utf8).write(to: dir.appendingPathComponent("profiles.json"))
    #expect(ProfileStore(directory: dir).load().map(\.displayName) == ["iPhone"])

    let entry = String(decoding: try JSONEncoder().encode(StatusFile.Entry(pid: 1, status: "Ready", detail: "", ready: true, tunnelPorts: [], updated: Date(timeIntervalSince1970: 0))), as: UTF8.self)
    let (bad, good) = (UUID(), UUID())
    let status = StatusFile.decode(Data(#"["\#(bad)", null, "\#(UUID())", "x", "\#(good)", \#(entry)]"#.utf8))
    #expect(Array(status.keys) == [good])
}

/// The app lists what the CLI saved while it runs: a device it never saw — not one it has,
/// not one it removed, and not one it added again itself meanwhile.
@Test func aDeviceSavedByAnotherProcessIsTheOnlyOneTakenIn() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let app = ProfileStore(directory: dir), cli = ProfileStore(directory: dir)
    #expect(app.written == nil)
    var kept = profile("iPad"), removed = profile("Old"); kept.providerIP = "100.64.0.1"; removed.providerIP = "100.64.0.2"
    let read = try #require(app.save(base: [], wanted: [kept, removed]))
    let first = try #require(app.written)
    #expect(app.savedElsewhere(base: read, mine: [kept]).isEmpty)   // removed here, still on disk: not taken back
    var new = profile("iPhone"); new.providerIP = "100.64.0.3"
    var moved = kept; moved.remotePairingPort = 50001
    #expect(cli.update { $0 = [moved, removed, new] })
    #expect(try #require(app.written) >= first)
    #expect(app.savedElsewhere(base: read, mine: [kept]) == [new])   // …and what it has keeps what it has
    var again = profile("iPhone"); again.providerIP = "100.64.0.3"
    #expect(app.savedElsewhere(base: read, mine: [kept, again]).isEmpty)   // added here too meanwhile: that one stands
    try Data("{".utf8).write(to: dir.appendingPathComponent("profiles.json"))
    #expect(app.savedElsewhere(base: [], mine: []).isEmpty)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.appendingPathComponent("profiles.json").path)
    #expect(app.savedElsewhere(base: [], mine: []).isEmpty)   // unreadable: nothing is taken for the list
}

/// A name is taken by a device the CLI saved since the app read its list, too.
@Test func aNameSavedByAnotherProcessMeanwhileIsTaken() {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let app = ProfileStore(directory: dir), cli = ProfileStore(directory: dir)
    let mine = profile("iPad")
    #expect(app.save(base: [], wanted: [mine]) != nil)
    #expect(cli.update { $0.append(profile("iPhone")) })
    let known = app.known(with: [mine])   // the app's list, as it read it before
    #expect(known.count == 2 && known.nameProblem("iphone") != nil)
    #expect([mine].nameProblem("iphone") == nil)
    #expect(known.nameProblem("iPad", except: mine.id) == nil && known.uniqueName("iPhone") == "iPhone 2")
}

// MARK: - Saved file compatibility

@Test func profilesFromOlderAndNewerVersionsDecode() throws {
    // As 0.1.x writes it.
    let v01 = #"[{"id":"940F4303-91B8-4C9C-9861-763E5429DDC6","displayName":"iPad","instanceName":"6E44","serviceType":"_remotepairing._tcp","domain":"local","remotePairingPort":49152,"bonjourHost":"my-ipad.local","txt":{"identifier":"AB"},"providerID":"tailscale","providerHostName":"my-ipad","providerIP":"100.64.0.10","udid":"00008101-000A00000000A001"}]"#
    let old = try JSONDecoder().decode([DeviceProfile].self, from: Data(v01.utf8))
    #expect(old.first?.displayName == "iPad" && old.first?.remotePairingPort == 49152 && old.first?.deviceType == nil)
    // Fields missing, or added by a later version: still readable.
    let sparse = #"[{"id":"940F4303-91B8-4C9C-9861-763E5429DDC6","instanceName":"6E44","providerIP":"100.64.0.10","futureField":true}]"#
    let p = try JSONDecoder().decode([DeviceProfile].self, from: Data(sparse.utf8))
    #expect(p.first?.serviceType == "_remotepairing._tcp" && p.first?.providerID == "tailscale")
    // Not a device at all: refused, so the file is kept aside rather than turned into a ghost entry.
    #expect((try? JSONDecoder().decode([DeviceProfile].self, from: Data("[{}]".utf8))) == nil)
    // And what we write reads back the same.
    #expect(try JSONDecoder().decode([DeviceProfile].self, from: JSONEncoder().encode(old)) == old)
}

// MARK: - Profiles saved from two processes

@Test func theAppDoesntUndoAnEndpointRoamrunUpSaved() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let app = ProfileStore(directory: dir), cli = ProfileStore(directory: dir)
    var phone = profile("iPhone"), pad = profile("iPad")
    phone.providerIP = "100.64.0.10"
    pad.providerIP = "100.64.0.11"
    #expect(app.save(base: [], wanted: [phone, pad]) != nil)

    // The app keeps its list in memory from here on; `roamrun up` moves the phone.
    let held = [phone, pad]
    var moved = cli.load()
    moved[0].providerIP = "100.64.0.99"
    moved[0].remotePairingPort = 50000
    #expect(cli.save(base: cli.load(), wanted: moved) != nil)

    // Now the app saves for an unrelated reason: a rename of the *other* device.
    var stale = held
    stale[1].displayName = "iPad Pro"
    let saved = app.save(base: held, wanted: stale)
    #expect(saved?.first(where: { $0.id == phone.id })?.providerIP == "100.64.0.99")
    #expect(saved?.first(where: { $0.id == phone.id })?.remotePairingPort == 50000)
    #expect(saved?.first(where: { $0.id == pad.id })?.displayName == "iPad Pro")
    #expect(app.load() == saved)
}

@Test func thisProcessStillOwnsWhatItChangedAndWhoIsInTheList() {
    var phone = profile("iPhone"), pad = profile("iPad")
    phone.providerIP = "old"
    let base = [phone, pad]
    var onDisk = base
    onDisk[0].providerIP = "theirs"
    // Changed here too: ours wins, it is the newer intent.
    var mine = base
    mine[0].providerIP = "mine"
    #expect(ProfileStore.merge(base: base, wanted: mine, disk: onDisk)[0].providerIP == "mine")
    // Deleted here: the disk's copy doesn't come back.
    let without = ProfileStore.merge(base: base, wanted: [pad], disk: onDisk)
    #expect(without.map(\.id) == [pad.id])
    // Added here: kept, even though the disk has never seen it.
    let vision = profile("Vision")
    let added = ProfileStore.merge(base: base, wanted: base + [vision], disk: onDisk)
    #expect(added.map(\.id) == [phone.id, pad.id, vision.id])
}

@Test func updateRoundTripsTheListAndIgnoresAnUnknownID() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProfileStore(directory: dir)
    var phone = profile("iPhone")
    phone.providerIP = "100.64.0.10"
    #expect(store.save(base: [], wanted: [phone]) != nil)
    // What `roamrun up` does. Reading the file first and merging afterwards would
    // drop a device the app added in between, since membership follows the caller.
    #expect(store.update { all in
        guard let i = all.firstIndex(where: { $0.id == phone.id }) else { return }
        all[i].providerIP = "100.64.0.99"
    })
    #expect(store.load().first?.providerIP == "100.64.0.99")
    // An id it doesn't know: nothing is changed, and nothing is lost either.
    #expect(store.update { all in
        guard let i = all.firstIndex(where: { $0.id == UUID() }) else { return }
        all[i].displayName = "never"
    })
    #expect(store.load().map(\.displayName) == ["iPhone"])
}

@Test func anUnreadableDeviceListIsNeverWrittenOver() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProfileStore(directory: dir)
    let saved = [profile("iPhone"), profile("iPad")]
    #expect(store.save(base: [], wanted: saved) == saved)
    let file = dir.appendingPathComponent("profiles.json").path
    chmod(file, 0)
    defer { chmod(file, 0o600) }
    // `roamrun up` learning a UDID, and the app saving a list it had to start empty.
    #expect(!store.update { if !$0.isEmpty { $0[0].udid = "U" } })
    #expect(store.save(base: [], wanted: [profile("New")]) == nil)
    #expect(store.unreadable)
    chmod(file, 0o600)
    #expect(store.load() == saved)
    #expect(!store.unreadable)
}

@Test func anUpdateThatChangesNothingWritesNothing() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProfileStore(directory: dir)
    #expect(store.update { _ in })   // no file and nothing to add
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("profiles.json").path))
}

@Test func devicesThisProcessNeverSawStayOnDisk() {
    let a = profile("A"), b = profile("B"), new = profile("New")
    // Started from an unreadable list (nothing seen), then added one: the others stay.
    #expect(Set(ProfileStore.merge(base: [], wanted: [new], disk: [a, b]).map(\.id)) == Set([a.id, b.id, new.id]))
    // Deleted here — it was seen — so it doesn't come back.
    #expect(ProfileStore.merge(base: [a, b], wanted: [b], disk: [a, b]).map(\.id) == [b.id])
}

@Test func aListThatBecomesReadableAgainIsntWrittenOverByTheEmptyOneWeStartedWith() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProfileStore(directory: dir)
    let saved = [profile("iPhone"), profile("iPad")]
    #expect(store.save(base: [], wanted: saved) == saved)
    let file = dir.appendingPathComponent("profiles.json").path
    chmod(file, 0)
    let seen = store.load()   // the app at launch: nothing it can read
    #expect(seen.isEmpty && store.unreadable)
    chmod(file, 0o600)        // the permission comes back while it runs
    let added = profile("New")
    let after = try #require(store.save(base: seen, wanted: [added]))
    #expect(Set(after.map(\.id)) == Set(saved.map(\.id) + [added.id]))
    #expect(Set(store.load().map(\.id)) == Set(after.map(\.id)))
}

@Test func aPortScanStillSelectsItsDeviceAfterSavingRestoresOtherDevices() throws {
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProfileStore(directory: dir)
    let restored = profile("A"), scanned = profile("B")
    #expect(store.save(base: [], wanted: [restored]) == [restored])
    // The app only knows B; this save is the first one after A becomes readable.
    let updated = try #require(AppCoordinator.saveScannedPort(49160, for: scanned.id, in: [scanned]) { changed in
        store.save(base: [], wanted: changed) ?? changed
    })
    #expect(store.load().map(\.id) == [restored.id, scanned.id])
    #expect(store.load().first == restored)
    #expect(updated.id == scanned.id)
    #expect(updated.remotePairingPort == 49160)
}

@Test func onlyTestRunnersTripTheRealFolderGuard() {
    #expect(ProfileStore.isTestRunner("xctest"))
    #expect(ProfileStore.isTestRunner("swiftpm-testing-helper"))
    #expect(ProfileStore.isTestRunner(ProcessInfo.processInfo.processName))   // so it fires in this very run
    for name in ["RoamRun", "roamrun", "xctest-helper", ""] { #expect(!ProfileStore.isTestRunner(name), "\(name)") }
}

@Test func aDeviceAddedAgainWhileTheListWasUnreadableDoesntComeBackTwice() {
    var old = profile("iPhone"), again = profile("iPhone")
    old.udid = "00008130-000D00000000D004"
    again.udid = "00008130-000d00000000d004"
    let other = profile("iPad")
    let merged = ProfileStore.merge(base: [], wanted: [again], disk: [old, other])
    #expect(Set(merged.map(\.id)) == Set([again.id, other.id]))
}
