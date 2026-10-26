import Foundation
import Testing
@testable import RoamRun
import CryptoKit
import Network
import os
import ImageIO

func profile(_ name: String, host: String = "", provider: String = "tailscale") -> DeviceProfile {
    DeviceProfile(displayName: name, instanceName: "", serviceType: "_remotepairing._tcp", domain: "local",
                  remotePairingPort: 49152, bonjourHost: "", txt: [:], providerID: provider,
                  providerHostName: host, providerIP: "")
}

/// Suites that time things, or block every Swift concurrency thread to test that, run one
/// after another: `.serialized` on each alone only orders its own tests, so one suite
/// filling the pool would still skew another's deadlines.
@Suite(.serialized, .timeLimit(.minutes(2))) struct TimingSensitive {}

final class EchoServer: @unchecked Sendable {
    let listener: NWListener
    private let lock = NSLock()
    private var conns: [NWConnection] = []
    var accepted: Int {
        lock.withLock {
            conns.count
        }
    }

    init(silent: Bool = false, port: UInt16? = nil) throws {
        listener = try port.map {
            try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: $0)!)
        } ?? NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [lock, weak self] c in
            lock.withLock {
                self?.conns.append(c)
            }
            c.start(queue: .global())
            guard !silent else { return }
            @Sendable func loop() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, err in
                    if let data, !data.isEmpty {
                        c.send(content: data, completion: .contentProcessed { _ in
                            loop()
                        })
                    } else if done || err != nil {
                        c.cancel()
                    } else {
                        loop()
                    }
                }
            }
            loop()
        }
    }

    /// The port, or 0 if it couldn't listen (e.g. a fixed port that's taken).
    func start() async -> UInt16 {
        await withCheckedContinuation { cont in
            let once = OnceBox()
            listener.stateUpdateHandler = { [listener] s in
                switch s {
                case .ready: once.run {
                        cont.resume(returning: listener.port!.rawValue)
                    }
                case .failed, .waiting, .cancelled: once.run {
                        listener.cancel()
                        cont.resume(returning: 0)
                    }
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    func closeAll() {
        lock.withLock {
            conns
        }
        .forEach {
            $0.cancel()
        }
    }

    func stop() {
        listener.cancel()
        closeAll()
    }
}

/// Polls `condition` for up to 5 s: connection callbacks land when they land.
/// Up to 15 s: closes reach the process-wide pair count late on a loaded machine, and the
/// relay suite's counts then missed a 5 s wait now and then. It returns as soon as it holds.
func eventually(_ condition: () -> Bool) async throws -> Bool {
    for _ in 0 ..< 150 where !condition() {
        try await Task.sleep(for: .milliseconds(100))
    }
    return condition()
}

final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        if lock.withLock({
            let first = !done
            done = true
            return first
        }) {
            body()
        }
    }
}

/// A run of `count` loopback ports nothing on this Mac holds right now, inside `band`:
/// a port some other app happens to use would make a relay test flaky.
/// Bands stay below 40000: `startedRelay` picks from 40000…49000, and a bridge here relays
/// 127.0.0.1:p to itself, so a stray connection from those tests would loop and skew the pair count.
func freeBase(in band: ClosedRange<UInt16>, count: Int = 20) -> UInt16 {
    func free(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
    for _ in 0 ..< 200 {
        let base = UInt16.random(in: band.lowerBound ... (band.upperBound - UInt16(count)))
        if (0 ..< count).allSatisfy({
            free(base + UInt16($0))
        }) {
            return base
        }
    }
    return band.lowerBound
}

func scratchDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor func eventuallyOnMain(_ condition: () -> Bool) async -> Bool {
    for _ in 0 ..< 300 { // 15 s, as `eventually`: other tests may hold the pool meanwhile
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int {
        lock.withLock {
            n
        }
    }

    func bump() {
        lock.withLock {
            n += 1
        }
    }
}

/// Stands in for `dns-sd -P`.
@MainActor final class FakeRecord: BonjourRecord {
    var onExit: ((Int32) -> Void)?
    var registered = 0, stopped = 0, renewed = 0
    func register(instanceName: String, serviceType: String, domain: String,
                  port: UInt16, host: String, ip: String, txt: [String: String]) throws
    {
        registered += 1
    }

    /// What a stand-in was announced as; `refuses`: no interface has the address.
    var standIn: (instance: String, type: String, port: UInt16, host: String, ip: String, txt: [String: String])?
    var refuses = false
    func registerOnItsInterface(instanceName: String, serviceType: String, domain: String,
                                port: UInt16, host: String, ip: String, txt: [String: String]) throws
    {
        standIn = (instanceName, serviceType, port, host, ip, txt)
        if refuses {
            throw CocoaError(.featureUnsupported)
        }
    }

    func stop() {
        stopped += 1
    }

    func renew() {
        renewed += 1
    }

    func previousExited() async -> Bool {
        true
    }
}

/// Ports no other test has: parallel tests' bridges each bind a control relay, a listener's
/// port frees only some time after it is cancelled, and a scan finds whatever listens in its way.
enum Ports {
    private static let next = OSAllocatedUnfairLock<UInt16>(initialState: 20000)
    /// The first of 25, from 20000 up: under the relays' own (40000…49000) and the ephemeral
    /// range other tests' servers listen in (49152…). Never handed out twice in a run.
    static func band() -> UInt16 {
        next.withLock { port in
            precondition(port < 39000, "more bridges in the tests than port bands: widen Ports")
            defer { port += 25 }
            return port
        }
    }
}

func inertProfile(_ name: String) -> DeviceProfile {
    var p = profile(name)
    p.remotePairingPort = Ports.band()
    p.providerIP = "127.0.0.1"
    p.instanceName = "FAKE-\(name)"
    return p
}

/// The tests' own key: never the Keychain's (a test binary is asked about it, and waits).
let scratchKey = SymmetricKey(size: .bits256)

/// A pairing as the library reads one, for a device that doesn't exist.
func scratchPairing(withDeviceKey: Bool = true) throws -> Data {
    let key = Curve25519.Signing.PrivateKey()
    var plist: [String: Any] = ["public_key": key.publicKey.rawRepresentation, "private_key": key.rawRepresentation,
                                "identifier": UUID().uuidString]
    if withDeviceKey { // as a pairing made now holds it: the device's own key and identifier
        plist["peer_public_key"] = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        plist["peer_identifier"] = UUID().uuidString
    }
    return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
}

/// One saved as the hub saves it.
func scratchPairing(at url: URL) throws {
    try DeviceControlHub.save(DeviceControlHub.seal(scratchPairing(), with: scratchKey), as: url)
}

/// A port on this Mac that takes a connection and never says a word: a device that stopped answering.
func silentPort() throws -> (fd: Int32, port: UInt16) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, length) == 0 && listen(fd, 4) == 0 && getsockname(fd, $0, &length) == 0
        }
    }
    try #require(bound)
    return (fd, UInt16(bigEndian: address.sin_port))
}

/// A device that isn't one: what the hub asks of it is counted, and a look can be held up.
final class StandInDevice: ControlledDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var counted: [String] = []
    var calls: [String] {
        lock.withLock {
            counted
        }
    }

    /// A look waits here when set, and says it has begun.
    var hold: DispatchSemaphore?
    let lookBegan = DispatchSemaphore(value: 0)
    var isOpen: Bool {
        lock.withLock {
            open
        }
    }

    private var open = true
    /// What a check finds: the connection gone, when set.
    var goneWhenChecked = false
    func check() {
        count("check")
        lock.withLock {
            if goneWhenChecked {
                open = false
            }
        }
    }

    var isRefused: Bool {
        false
    }

    /// What answers isn't the device the pairing was made with.
    var isAnother = false
    /// A connection waits here when set, and says it has begun.
    var connectHold: DispatchSemaphore?
    let connectBegan = DispatchSemaphore(value: 0)
    /// What a connection fails with, when set.
    var connectFailing: Error?
    func connect() throws {
        count("connect")
        connectBegan.signal()
        held(connectHold)
        if let connectFailing {
            throw connectFailing
        }
        lock.withLock {
            open = true
            goneWhenChecked = false
        }
    }

    func reach() throws {
        count("reach")
        try connect()
    }

    func letGo() {
        count("letGo")
    }

    /// What the hub gave it: the pairing it would connect with, and what is asked before a call begins.
    var pairing: (@Sendable () throws -> Data)?
    private(set) var gated: (@Sendable () -> Bool)?
    func gate(_ mayBegin: @escaping @Sendable () -> Bool) {
        gated = mayBegin
    }

    /// An input waits here when set, until it is interrupted.
    var typeHold: DispatchSemaphore?
    let typeBegan = DispatchSemaphore(value: 0)
    func interrupt() {
        count("interrupt")
        typeHold?.signal()
    }

    func close() {}
    private func count(_ call: String) {
        lock.withLock {
            counted.append(call)
        }
    }

    /// What an input, or a look, throws when set (after it was sent, as the device's own do).
    var failing: (any Error)?
    var lookFailing: (any Error)?
    func look() throws -> CGImage {
        count("look")
        lookBegan.signal()
        held(hold)
        if let lookFailing {
            throw lookFailing
        }
        return CGContext(
            data: nil,
            width: screen.width,
            height: screen.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!.makeImage()!
    }

    /// The size of the screen a look shows.
    var screen = (width: 100, height: 200)
    /// Where the last tap went, as fractions of the screen.
    var tapped: (x: Double, y: Double)?
    func elements(limit: Int) throws -> (captions: [String], complete: Bool) {
        count("elements")
        return ([], true)
    }

    func tap(x: Double, y: Double) throws {
        try input("tap")
        lock.withLock {
            tapped = (x, y)
        }
        Thread.sleep(forTimeInterval: 0.01)
    }

    func swipe(from: (x: Double, y: Double), to: (x: Double, y: Double), milliseconds: Int) throws {
        try input("swipe")
    }

    func type(_ text: String) throws {
        try input("type")
    }

    func paste(_ text: String) throws {
        try input("paste")
    }

    func press(_ button: String) throws {
        try input("press")
    }

    /// An install waits here when set, and says it has begun; it throws `failing` when that is set.
    var installHold: DispatchSemaphore?
    let installBegan = DispatchSemaphore(value: 0)
    func install(_ path: String) throws {
        count("install")
        installBegan.signal()
        held(installHold)
        if let failing {
            throw failing
        }
    }

    func launch(_ bundle: String) throws -> Int {
        try input("launch")
        return 42
    }

    private func input(_ call: String) throws {
        count(call)
        typeBegan.signal()
        held(typeHold)
        if let failing {
            throw failing
        }
    }
}

/// A hub over stand-ins, one made for each session the hub opens.
func standInHub(_ dir: URL, udid: String = "UDID-1", paired: Bool = true,
                prepare: @escaping @Sendable (StandInDevice) -> Void = { _ in }) throws
    -> (hub: DeviceControlHub, made: () -> [StandInDevice])
{
    if paired {
        try scratchPairing(at: DeviceControlWire.pairingFile(udid: udid, in: dir))
    }
    let made = OSAllocatedUnfairLock<[StandInDevice]>(initialState: [])
    let hub = DeviceControlHub(directory: dir, key: { _ in
        scratchKey
    }) { _, pairing, _ in
        let device = StandInDevice()
        device.pairing = pairing
        prepare(device)
        made.withLock {
            $0.append(device)
        }
        return device
    }
    return (hub, {
        made.withLock {
            $0
        }
    })
}

/// A wait that a missed moment ends as a failure, not as a test that never returns.
func soon(_ signal: DispatchSemaphore) -> Bool {
    signal.wait(timeout: .now() + 10) == .success
}

/// A fake's hold, let go by its test: one whose test has gone on without it lets go by itself,
/// rather than keep a thread for good.
func held(_ signal: DispatchSemaphore?) {
    _ = signal?.wait(timeout: .now() + 30)
}

func until(_ what: () -> Bool) -> Bool {
    for _ in 0 ..< 1000 where !what() {
        usleep(10_000)
    } // 10 s: other tests may hold the threads meanwhile
    return what()
}
