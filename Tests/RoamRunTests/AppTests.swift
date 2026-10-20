import Foundation
import Testing
@testable import RoamRun

@Test func settingsCarryOverFromTheOldBundleID() {
    let old: [String: Any] = ["networkInterface": "en1", "wasActiveIDs": ["A"]]
    #expect(AppID.carriedOver(old: nil, new: nil) == nil)                         // nothing saved yet
    #expect(AppID.carriedOver(old: [:], new: nil) == nil)
    #expect(AppID.carriedOver(old: old, new: nil)?["networkInterface"] as? String == "en1")
    #expect(AppID.carriedOver(old: old, new: [:])?["networkInterface"] as? String == "en1")   // an empty domain file
    #expect(AppID.carriedOver(old: old, new: ["networkInterface": "en0"]) == nil)             // never overwrites
    var marked = old; marked[AppID.movedKey] = AppID.bundle                                     // already carried over once:
    #expect(AppID.carriedOver(old: marked, new: nil) == nil)                                   // deleted settings stay deleted
}

@Test func openAtLoginSurvivesALostRegistration() {
    // Never chosen here: whatever the system says.
    #expect(AppCoordinator.loginItem(saved: nil, status: .notRegistered) == (on: false, register: false))
    #expect(AppCoordinator.loginItem(saved: nil, status: .enabled) == (on: true, register: false))
    // Chosen and still registered. .requiresApproval is the user switching it off in System
    // Settings: still "on" here, and we don't register over their choice.
    #expect(AppCoordinator.loginItem(saved: true, status: .enabled) == (on: true, register: false))
    #expect(AppCoordinator.loginItem(saved: true, status: .requiresApproval) == (on: true, register: false))
    // The registration went with the old bundle id (0.1.12) or a replaced app: put it back.
    #expect(AppCoordinator.loginItem(saved: true, status: .notRegistered) == (on: true, register: true))
    #expect(AppCoordinator.loginItem(saved: true, status: .notFound) == (on: true, register: true))
    // Switched off stays off.
    #expect(AppCoordinator.loginItem(saved: false, status: .notRegistered) == (on: false, register: false))
}

@Test func aLostLoginItemThisCopyCantRestoreShowsOff() {
    // Outside /Applications nothing registers it again: showing it on would be a promise nobody keeps.
    #expect(AppCoordinator.loginItem(saved: true, status: .notRegistered, canRegister: false) == (on: false, register: false))
    #expect(AppCoordinator.loginItem(saved: true, status: .notFound, canRegister: false) == (on: false, register: false))
    #expect(AppCoordinator.loginItem(saved: true, status: .enabled, canRegister: false) == (on: true, register: false))
    #expect(AppCoordinator.loginItem(saved: true, status: .notRegistered, canRegister: true) == (on: true, register: true))
    // Only an installed copy is invited to take the login item back; a build run
    // from a folder would take it from the one in /Applications.
    #expect(AppCoordinator.lostLoginItemAdvice(bundlePath: "/Users/me/Applications/RoamRun.app").contains("Switch it on"))
    #expect(!AppCoordinator.lostLoginItemAdvice(bundlePath: "/Users/me/src/RoamRun/RoamRun.app").contains("Switch it on"))
}

@Test func quittingGivesTheLiveEntryBackWhileOnlyTheSweepRuns() {
    // Nothing running: quit takes the flag and ends it.
    let free = AppCoordinator.beginReleaseAtQuit()
    #expect(free.allowed && free.owns)
    AppCoordinator.endServeChange()
    // The sweep leaves the live entry alone: quit may give it back, without the flag.
    #expect(AppCoordinator.beginServeChange(sweep: true))
    let duringSweep = AppCoordinator.beginReleaseAtQuit()
    #expect(duringSweep.allowed && !duringSweep.owns)
    AppCoordinator.endServeChange()
    // A publish or a release in flight: racing it is what the flag prevents.
    #expect(AppCoordinator.beginServeChange())
    #expect(!AppCoordinator.beginReleaseAtQuit().allowed)
    AppCoordinator.endServeChange()
}
