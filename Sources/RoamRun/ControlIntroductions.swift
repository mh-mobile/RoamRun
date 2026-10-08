import DeviceControl
import Foundation

/// Pairings for device control that another Mac introduces. The app listens on the tailnet for
/// that Mac alone and announces nothing; `roamrun pair control --with` carries between the two
/// and asks how it stands. What pairs is kept as a pairing brought in is, and no code or key
/// is shown or written here.
final class ControlIntroductions: @unchecked Sendable {
    enum State: Equatable {
        case waiting
        /// Paired; being tried and kept. Seen through from here, whoever stops asking.
        case checking
        case done(on: Bool)
        case failed(PairWire.Refusal)
    }
    struct Listening {
        var listener: any PairingListener
        var port: UInt16
        var txt: [String: String]
    }
    struct Kept: Sendable {
        var name: String
        var on: Bool
    }
    struct NotKept: Error {
        var how: PairWire.Refusal
        var why: String
        init(_ how: PairWire.Refusal, _ why: String) { self.how = how; self.why = why }
    }
    private struct Attempt {
        var state = State.waiting
        var offer: String
        var code: String?
        var listener: (any PairingListener)?
        var asked = Date()
        let began = Date()
        var cancelled = false
        /// What to tell whoever runs the command here: the device's name, or why not.
        var said: String?
    }

    private let lock = NSLock()
    private var attempts: [UUID: Attempt] = [:]
    private var last: UUID?

    var listen: @Sendable (_ ip: String, _ interface: String, _ only: String) throws -> Listening = { _, _, _ in throw DeviceSession.Failure.message("stopping") }
    var ready: @Sendable () throws -> Void = {}
    var busy: @Sendable () -> Bool = { false }
    /// Whether this Mac holds a pairing for the device already.
    var held: @Sendable (DeviceProfile) -> Bool = { _ in false }
    var keep: @Sendable (DeviceProfile, DevicePairing.Paired, _ wanted: @Sendable () -> Bool) -> Result<Kept, NotKept> = { _, _, _ in .failure(.init(.failed, "stopping")) }
    /// Not asked how it stands for this long, the command that began it is gone.
    var quiet: TimeInterval = 15
    var longest: TimeInterval = 720
    var tick: TimeInterval = 1

    func answer(_ request: DeviceControlWire.Request) -> DeviceControlWire.Response {
        switch request.op {
        case "pair-start": start(request)
        case "pair-status": status(request.text == "last" ? lock.withLock { last } : request.device)
        case "pair-cancel": cancel(request.device)
        default: .failure("unknown request")
        }
    }

    private func refused(_ how: PairWire.Refusal, _ why: String) -> DeviceControlWire.Response {
        .init(ok: false, error: why, state: "failed", reason: how.rawValue)
    }

    private func start(_ request: DeviceControlWire.Request) -> DeviceControlWire.Response {
        let id = request.device
        // Asked again (its answer was lost): the same offer, not a second listener.
        if let begun = lock.withLock({ attempts[id] }) { return .init(ok: true, offer: begun.offer) }
        guard let text = request.text, let device = try? JSONDecoder().decode(DeviceProfile.self, from: Data(text.utf8)),
              let ip = request.address, let interface = request.interface, let only = request.peer,
              device.serviceType == Introduction.deviceService, ["local", "local."].contains(device.domain) else {
            return refused(.failed, "that isn't a device to be introduced to")
        }
        guard !busy(), !lock.withLock({ attempts.values.contains { $0.state == .waiting || $0.state == .checking } }) else {
            return refused(.failed, "another pairing is under way on this Mac")
        }
        if held(device) {
            return refused(.exists, "this Mac already holds a pairing for that device: remove it first (the RoamRun app, on the device's page), then pair again")
        }
        // Before the device is asked anything: a Keychain that then refused would leave it paired with nothing kept here.
        do { try ready() } catch { return refused(.failed, "\(error)") }
        let listening: Listening
        do { listening = try listen(ip, interface, only) } catch { return refused(.failed, "couldn't listen on \(ip) (\(interface)): \(error)") }
        let offer = Introduction.line(Introduction.Offer(port: listening.port, txt: listening.txt))
        guard case .success = Introduction.offer(from: offer) else {
            listening.listener.cancel()
            return refused(.failed, "this Mac's own offer doesn't read as one")
        }
        lock.withLock {
            attempts[id] = Attempt(offer: offer, listener: listening.listener)
            last = id
            // What ended long ago is forgotten: the last few are kept to be asked about.
            for old in attempts.filter({ $0.key != id && $0.value.listener == nil }).sorted(by: { $0.value.began < $1.value.began }).dropLast(8) { attempts[old.key] = nil }
        }
        Thread.detachNewThread { [self] in pair(id, device, listening.listener) }
        Thread.detachNewThread { [self] in watch(id) }
        return .init(ok: true, offer: offer)
    }

    private func pair(_ id: UUID, _ device: DeviceProfile, _ listener: any PairingListener) {
        func end(_ state: State, _ said: String?) {
            lock.withLock {
                attempts[id]?.state = state
                attempts[id]?.said = said
                attempts[id]?.code = nil
                attempts[id]?.listener = nil
            }
        }
        let cancelled: @Sendable () -> Bool = { [self] in lock.withLock { attempts[id]?.cancelled != false } }
        do {
            let paired = try listener.accept { [self] code in lock.withLock { attempts[id]?.code = code } }
            // Stopped or kept: whichever came first, under the one lock.
            let goes = lock.withLock { () -> Bool in
                guard attempts[id]?.cancelled == false else { return false }
                attempts[id]?.state = .checking
                attempts[id]?.code = nil
                return true
            }
            guard goes else {
                return end(.failed(.cancelled), "It was stopped as the device paired: nothing was kept here. The pairing just made can be removed on the device, in Settings › Privacy & Security › Developer Mode.")
            }
            switch keep(device, paired, { !cancelled() }) {
            case .success(let kept): end(.done(on: kept.on), kept.name)
            case .failure(let not): end(.failed(not.how), not.why)
            }
        } catch {
            end(.failed(cancelled() ? .cancelled : .failed), cancelled() ? nil : "\(error)")
        }
    }

    /// The command that began it is the only one that can stop it by asking: gone without a
    /// word, it is stopped here. Not once the device has paired: that is seen through.
    private func watch(_ id: UUID) {
        while true {
            Thread.sleep(forTimeInterval: tick)
            let over = lock.withLock { () -> Bool? in
                guard let a = attempts[id], a.state == .waiting else { return nil }
                return Date().timeIntervalSince(a.asked) > quiet || Date().timeIntervalSince(a.began) > longest
            }
            guard let over else { return }
            if over { _ = cancel(id); return }
        }
    }

    private func status(_ id: UUID?) -> DeviceControlWire.Response {
        lock.withLock {
            guard let id, let a = attempts[id] else {
                return .init(ok: false, error: "this RoamRun doesn't know that attempt (it was opened anew since, or it is another Mac's)", state: "unknown")
            }
            attempts[id]?.asked = Date()
            switch a.state {
            case .waiting: return .init(ok: true, state: a.code == nil ? "waiting" : "code", code: a.code)
            case .checking: return .init(ok: true, state: "checking")
            case .done(let on): return .init(ok: true, name: a.said, allowed: on, state: "done")
            case .failed(let how): return .init(ok: true, error: a.said, state: "failed", reason: how.rawValue)
            }
        }
    }

    private func cancel(_ id: UUID) -> DeviceControlWire.Response {
        let listener = lock.withLock { () -> (any PairingListener)? in
            guard attempts[id]?.state == .waiting else { return nil }
            attempts[id]?.cancelled = true
            return attempts[id]?.listener
        }
        listener?.cancel()
        // Answered once it has stopped, or says it is being kept: a moment at most.
        for _ in 0..<20 where lock.withLock({ attempts[id]?.state == .waiting && attempts[id]?.listener != nil }) { Thread.sleep(forTimeInterval: 0.1) }
        return status(id)
    }
}
