import Foundation
import Testing
@testable import RoamRun
import DeviceControl

// MARK: - Two Macs that name each other (no line carried)

@Test func whatTwoMacsSayIsReadBackAndNothingElseIs() {
    let all: [PairWire.Message] = [
        .wantOffer,
        .offer("rr-xcode-offer-v1:abc"),
        .tried("rr-device-v1:abc"),
        .saved,
        .unsaved,
        .you("iphone.t.ts.net"),
        .pairable("rr-pairable-v1:abc")
    ]
        + PairWire.Reason.allCases.map(PairWire.Message.ended)
    for m in all {
        #expect(PairWire.message(from: PairWire.line(m)) == m)
    }
    // roamrunctl writes these words itself: each one it can end with is one this Mac reads.
    #expect(PairWire.message(from: "rr-pair-v1 ended no-line") == .ended(.noLine))
    let rust = (try? String(
        contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Rust/roamrunctl/src/main.rs"),
        encoding: .utf8
    )) ?? ""
    let ends = rust.matches(of: /"ended ([a-z-]+)"|Err\(\(\s*"([a-z-]+)"|String\| \("([a-z-]+)"/)
        .compactMap {
            $0.1 ?? $0.2 ?? $0.3
        }
        .map(String.init)
    #expect(Set(ends).count >= 7, "\(ends)")
    for word in ends {
        #expect(PairWire.message(from: "rr-pair-v1 ended " + word) != nil, "\(word)")
    }
    // The Introducer app writes its words itself too, and reads what this Mac says to a device by their first word.
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let app = { (file: String) in (try? String(
        contentsOf: root.appendingPathComponent("iOS/Sources/" + file),
        encoding: .utf8
    )) ?? "" }
    let said = app("Session.swift")
        .matches(of: /saying: "([a-z-]+)"|noLine = "([a-z-]+)"/)
        .compactMap {
            $0.1 ?? $0.2
        }
        .map(String.init)
    #expect(Set(said).count >= 5, "\(said)")
    for word in said {
        #expect(PairWire.message(from: "rr-pair-v1 ended " + word) != nil, "\(word)")
    }
    let toADevice: [PairWire.Message] = [
        .offer("x"),
        .ended(.stopped),
        .saved,
        .unsaved,
        .you("x"),
        .wantDevice,
        .attempt("x"),
        .code("123456"),
        .result(.done(on: true))
    ]
    for m in toADevice {
        let first = PairWire.line(m).dropFirst("rr-pair-v1 ".count).split(separator: " ")[0]
        #expect(app("Wire.swift").contains("(\"\(first)\", "), "the app doesn't read \(first)")
    }
    for line in [
        "",
        "offer?",
        "rr-pair-v2 offer?",
        "rr-pair-v1 ",
        "rr-pair-v1 offer",
        "rr-pair-v1 offer ",
        "rr-pair-v1 offer a b",
        "rr-pair-v1 you",
        "rr-pair-v1 you ",
        "rr-pair-v1 ended because",
        "rr-pair-v1 saved it",
        "rr-pair-v1 OFFER?"
    ] {
        #expect(PairWire.message(from: line) == nil, "\(line)")
    }
}

@Test func aMachineIsHeldToItsLastingIDAndNothingStandsInForOne() {
    // whois has a number called ID as well; a peer's ID in status is whois' StableID.
    #expect(TailscaleClient
        .owner(fromWhoisJSON: #"{"Node":{"ID":4477722,"StableID":"nABCDNTRL","Key":"nodekey:1"}}"#) == "nABCDNTRL")
    #expect(TailscaleClient.owner(fromWhoisJSON: #"{"Node":{"ID":4477722}}"#) == nil)
    #expect(TailscaleClient.owner(fromWhoisJSON: #"{"Node":{"StableID":""}}"#) == nil)
    #expect(TailscaleClient.owner(fromWhoisJSON: "no such peer") == nil)
    let status = #"{"Peer":{"k1":{"ID":"nABCDNTRL","TailscaleIPs":["100.64.0.1"],"DNSName":"a.t.ts.net."},"k2":{"TailscaleIPs":["100.64.0.2"],"DNSName":"b.t.ts.net."}}}"#
    let peers = TailscaleClient.devices(fromStatusJSON: status) ?? []
    #expect(peers.first {
        $0.name == "a"
    }?.stableID == "nABCDNTRL")
    #expect(peers.first {
        $0.name == "b"
    }?.stableID == nil) // its `id` falls back to the address; this doesn't
}

private final class Counted<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) {
        lock.lock(); items.append(item); lock.unlock()
    }

    var all: [T] {
        lock.lock(); defer { lock.unlock() }; return items
    }
}

private func farMac(peer: PairByName.Peer = .init(ip: "127.0.0.1", id: "home"),
                    owner: @escaping @Sendable (String) -> String? = { _ in
                        "home"
                    },
                    offers: @escaping @Sendable () async -> PairByName.Offers = {
                        .one("offer-1")
                    },
                    rescan: @escaping @Sendable () async -> Void = {},
                    saved: Counted<String> = .init(), saves: Bool = true,
                    events: Counted<PairByName.Far.Event> = .init(),
                    connectWindow: TimeInterval = 5, resultWindow: TimeInterval = 5) -> PairByName.Far
{
    PairByName.Far(peer: peer, owner: owner, offers: offers, rescan: rescan,
                   save: {
                       saved.add($0); return saves
                   }, say: {
                       events.add($0)
                   },
                   connectWindow: connectWindow, resultWindow: resultWindow, lineWait: 1, pause: .milliseconds(20))
}

private func homeMac(
    _ port: UInt16,
    owner: @escaping @Sendable (String) -> String? = { _ in
        "far"
    },
    window: TimeInterval = 5
) -> PairByName.Home {
    PairByName.Home(peer: .init(ip: "127.0.0.1", id: "far"), owner: owner,
                    connect: {
                        PairLink.connect(to: "127.0.0.1", port: port, interface: nil, within: 1)
                    },
                    window: window, pause: .milliseconds(20))
}

private func started(_ far: PairByName.Far, _ listener: PairLink.Listener) -> Task<PairByName.Far.End, Never> {
    Task.detached {
        await far.run(listener)
    }
}

extension TimingSensitive {
    @Suite struct TwoMacsByName {
        /// The whole of it, in the order a person may do it: the other Mac connects first, the offer comes later.
        @Test func theOfferIsWaitedForThenTheDeviceIsSavedOnce() async throws {
            let listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: "lo0")
            let asked = Counted<Int>(), saved = Counted<String>(), events = Counted<PairByName.Far.Event>()
            let far = farMac(
                offers: {
                    asked.add(1); return asked.all.count < 4 ? .none : .one("offer-1")
                },
                saved: saved,
                events: events
            )
            let end = started(far, listener)
            guard case .offer(let offer, let link) = await homeMac(listener.port).fetch()
            else { Issue.record("no offer"); return }
            #expect(offer == "offer-1")
            #expect(asked.all.count >= 4)
            #expect(PairByName.Home.handOver("device-1", on: link) == .saved)
            #expect(await end.value == .saved)
            #expect(saved.all == ["device-1"])
            #expect(events.all == [.connected, .waitingForOffer, .offerSent])
        }

        /// A device that waits to be picked: the other Mac sends what it announces, is asked for the device,
        /// and the device is saved here once this Mac has stood in for that same device — or not at all, with the reason said.
        @Test func aDeviceThatWaitsIsStoodInForHereThenSaved() async throws {
            var listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: "lo0")
            let saved = Counted<String>(), stoodIn = Counted<String>(), read = Counted<Int>()
            var far = farMac(saved: saved)
            far.standIn = {
                stoodIn.add($0 + " for " + $1); return nil
            }
            var end = started(far, listener)
            var home = homeMac(listener.port); home.device = "device-1"
            // What the device announces is read once that Mac has answered, not before.
            #expect(await home.hand(pairable: {
                read.add(1); return "waits-1"
            }, resultWindow: 5) == .saved)
            #expect(await end.value == .saved && stoodIn.all == ["waits-1 for device-1"] && saved
                .all == ["device-1"] && read.all.count == 1)

            // Looking again at what the device announces takes longer than a line is waited for: still heard.
            listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: "lo0")
            far.standIn = { _, _ in
                nil
            }
            end = started(far, listener)
            home = homeMac(listener.port); home.device = "device-1"
            #expect(await home.hand(
                pairable: {
                    try? await Task.sleep(for: .milliseconds(1500)); return "waits-1"
                },
                resultWindow: 5
            ) == .saved)
            #expect(await end.value == .saved)

            // Stood in, and not kept: said as that.
            listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: "lo0")
            var forgetful = farMac(saves: false); forgetful.standIn = { _, _ in
                nil
            }
            end = started(forgetful, listener)
            home = homeMac(listener.port); home.device = "device-1"
            #expect(await home.hand(pairable: {
                "waits-1"
            }, resultWindow: 5) == .unsaved)
            #expect(await end.value == .unsaved)

            // Not stood in: the reason goes back, and nothing is saved.
            listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: "lo0")
            far.standIn = { _, _ in
                .unreachable
            }
            end = started(far, listener)
            home = homeMac(listener.port); home.device = "device-1"
            #expect(await home.hand(pairable: {
                "waits-1"
            }, resultWindow: 5) == .ended(.unreachable))
            #expect(await end.value == .ended(.unreachable) && saved.all == ["device-1", "device-1"])

            // A Mac that doesn't stand in as it runs (a device named with --with) says so, and goes on waiting.
            listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: "lo0")
            far.standIn = nil
            far.connectWindow = 2
            end = started(far, listener)
            home = homeMac(listener.port); home.device = "device-1"
            #expect(await home.hand(pairable: {
                "waits-1"
            }, resultWindow: 5) == .ended(.failed))
            #expect(await end.value == .noOne)

            // One that hangs up without a word, twice, is taken for a RoamRun from before.
            listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: "lo0")
            let old = Task.detached { [listener] in
                for _ in 0 ..<
                    2
                {
                    if let (link, _) = listener.accept(within: 10) {
                        _ = link.read(within: 10); link.close()
                    }
                }
            }
            home = homeMac(listener.port); home.device = "device-1"
            #expect(await home.hand(pairable: {
                "waits-1"
            }, resultWindow: 5) == .tooOld)
            await old.value

            // The device stopped waiting by the time that Mac answered: nothing is sent.
            listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: "lo0")
            far.standIn = {
                stoodIn.add($0 + " for " + $1); return nil
            }
            far.connectWindow = 2
            end = started(far, listener)
            home = homeMac(listener.port); home.device = "device-1"
            #expect(await home.hand(pairable: {
                nil
            }, resultWindow: 5) == .notWaiting)

            // Without a device to hand over, nothing is stood in for.
            #expect(await homeMac(listener.port).hand(pairable: {
                "waits-2"
            }, resultWindow: 5) == .garbled)
            _ = await end.value
            #expect(stoodIn.all == ["waits-1 for device-1"])

            // That Mac took the device and went away: said as that, not as a mix-up of versions.
            listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: "lo0")
            let gone = Task.detached { [listener] in
                guard let (link, _) = listener.accept(within: 10) else { return }
                _ = link.read(within: 10); link.send(.wantDevice); _ = link.read(within: 10); link.close()
            }
            home = homeMac(listener.port); home.device = "device-1"
            #expect(await home.hand(pairable: {
                "waits-1"
            }, resultWindow: 5) == .wentAway)
            await gone.value
        }

        /// A device that introduces this Mac itself is told its Tailscale name before the offer; a Mac isn't.
        @Test func aDeviceIsToldItsNameBeforeTheOffer() async throws {
            let listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: "lo0")
            let saved = Counted<String>()
            var far = farMac(saved: saved)
            far.named = "iphone.t.ts.net"
            let end = started(far, listener)
            let link = try #require(PairLink.connect(to: "127.0.0.1", port: listener.port, interface: nil))
            link.send(.wantOffer)
            #expect(link.read(within: 10).message == .you("iphone.t.ts.net"))
            #expect(link.read(within: 10).message == .offer("offer-1"))
            #expect(PairByName.Home.handOver("device-1", on: link) == .saved)
            #expect(await end.value == .saved && saved.all == ["device-1"])
        }

        @Test func onlyTheMacNamedIsAnsweredAndAStrangerDoesNotShutItOut() async throws {
            // Another address: turned away without a question to Tailscale.
            var listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
            let questions = Counted<String>(), events = Counted<PairByName.Far.Event>()
            var far = farMac(
                peer: .init(ip: "127.0.0.9", id: "home"),
                owner: {
                    questions.add($0); return "home"
                },
                events: events,
                connectWindow: 2
            )
            let none = started(far, listener)
            let stranger = try #require(PairLink.connect(to: "127.0.0.1", port: listener.port, interface: nil))
            stranger.send(.wantOffer)
            #expect(stranger.read(within: 10) == .closed)
            #expect(await none.value == .noOne)
            #expect(questions.all.isEmpty)
            #expect(events.all == [.refused(from: "127.0.0.1")])

            // The right address, held by another machine now, or by one Tailscale can't name: turned
            // away each time; then the Mac itself gets through.
            listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
            let answers = Counted<Int>(), saved = Counted<String>(), turned = Counted<PairByName.Far.Event>()
            far = farMac(
                owner: { _ in
                    answers.add(1); return [1: "another", 2: nil][answers.all.count] ?? "home"
                },
                saved: saved,
                events: turned
            )
            let end = started(far, listener)
            for _ in 1 ... 2 {
                let link = try #require(PairLink.connect(to: "127.0.0.1", port: listener.port, interface: nil))
                link.send(.wantOffer)
                #expect(link.read(within: 10) == .closed)
            }
            guard case .offer(_, let link) = await homeMac(listener.port).fetch()
            else { Issue.record("no offer"); return }
            #expect(PairByName.Home.handOver("device-1", on: link) == .saved)
            #expect(await end.value == .saved)
            #expect(saved.all == ["device-1"])
            // Said as what it was: another machine's, or one Tailscale couldn't name just then.
            #expect(Array(turned.all.prefix(2)) == [.refused(from: "127.0.0.1"), .unsure(from: "127.0.0.1")])
        }

        @Test func whatIsNotALineOfTheseGetsNoOffer() async throws {
            let listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
            let saved = Counted<String>()
            let end = started(farMac(saved: saved), listener)
            // Too long, never ending; then one byte and silence; then another version's word.
            let long = try #require(PairLink.connect(to: "127.0.0.1", port: listener.port, interface: nil))
            long.send(.offer(String(repeating: "x", count: PairWire.maxLine + 100)))
            #expect(long.read(within: 10) == .closed)
            let slow = try #require(PairLink.connect(to: "127.0.0.1", port: listener.port, interface: nil))
            #expect(slow.read(within: 10) == .closed) // three lineWaits for a first line, not for ever
            let other = try #require(PairLink.connect(to: "127.0.0.1", port: listener.port, interface: nil))
            other.send(.saved)
            #expect(other.read(within: 10) == .closed)
            guard case .offer(_, let link) = await homeMac(listener.port).fetch()
            else { Issue.record("no offer"); return }
            #expect(PairByName.Home.handOver("device-1", on: link) == .saved)
            #expect(await end.value == .saved)
        }

        @Test func twoOffersAreLookedAtAgainAndNeverChosenBetween() async throws {
            // Two, and after looking again one: sent.
            var listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
            let looks = Counted<Int>()
            var far = farMac(offers: {
                looks.all.isEmpty ? .several : .one("offer-new")
            }, rescan: {
                looks.add(1)
            })
            let one = started(far, listener)
            guard case .offer(let offer, let link) = await homeMac(listener.port).fetch()
            else { Issue.record("no offer"); return }
            #expect(offer == "offer-new")
            #expect(PairByName.Home.handOver("device-1", on: link) == .saved)
            #expect(await one.value == .saved)

            // Still two: neither is sent, and both Macs are told.
            listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
            far = farMac(offers: {
                .several
            })
            let two = started(far, listener)
            guard case .ended(.ambiguous) = await homeMac(listener.port).fetch()
            else { Issue.record("an offer was chosen"); return }
            #expect(await two.value == .ambiguous)
        }

        @Test func aConnectionLostBeforeTheOfferArrivedIsMadeAgainAndOneLostAfterIsNot() async throws {
            let listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
            let saved = Counted<String>(), events = Counted<PairByName.Far.Event>()
            let end = started(farMac(saved: saved, events: events, connectWindow: 1.5), listener)
            // Dropped with the offer on its way: the other Mac may ask again, and does.
            let first = try #require(PairLink.connect(to: "127.0.0.1", port: listener.port, interface: nil))
            first.send(.wantOffer)
            first.close()
            guard case .offer(_, let link) = await homeMac(listener.port).fetch()
            else { Issue.record("no offer"); return }
            // Dropped with the offer taken: nothing asks again, and the far Mac stops once a connection may no longer begin.
            link.close()
            #expect(await end.value == .noOne)
            #expect(saved.all.isEmpty)
            #expect(events.all
                .filter {
                    $0 == .dropped
                }
                .count >= 1)
        }

        @Test func aFarMacThatMakesNoOfferSaysSoRatherThanGoQuiet() async throws {
            let listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
            let end = started(farMac(offers: {
                .none
            }, connectWindow: 2.5), listener)
            guard case .ended(.noOffer) = await homeMac(listener.port).fetch() else { Issue.record("not told"); return }
            #expect(await end.value == .noOne)
        }

        @Test func theIntroducingMacItselfAsksAgainUntilTheOfferHasArrived() async throws {
            let listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
            let port = listener.port
            async let fetched = homeMac(port).fetch()
            // Dropped once asked, then dropped with the offer half sent; the third time it arrives.
            var (link, _) = try #require(listener.accept(within: 10))
            #expect(link.read(within: 10) == .line(PairWire.line(.wantOffer)))
            link.close()
            (link, _) = try #require(listener.accept(within: 10))
            _ = link.read(within: 10)
            link.write("rr-pair-v1 offer half")
            link.close()
            (link, _) = try #require(listener.accept(within: 10))
            _ = link.read(within: 10)
            link.send(.offer("offer-1"))
            guard case .offer(let offer, let mine) = await fetched else { Issue.record("no offer"); return }
            #expect(offer == "offer-1")
            mine.close()
            #expect(listener.accept(within: 0.5).map { _ in
                true
            } == nil) // and never after
        }

        @Test func theResultIsWaitedForPastTheTimeAConnectionMayBegin() async throws {
            let listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
            let saved = Counted<String>()
            let end = started(farMac(saved: saved, connectWindow: 1.5, resultWindow: 8), listener)
            guard case .offer(_, let link) = await homeMac(listener.port).fetch()
            else { Issue.record("no offer"); return }
            try await Task.sleep(for: .seconds(2)) // standing in, past the first window
            #expect(PairByName.Home.handOver("device-1", on: link) == .saved)
            #expect(await end.value == .saved)
        }

        @Test func nothingIsSavedUnlessAPairingWasTriedAndNoResultIsSaidAsThat() async throws {
            var listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
            let saved = Counted<String>()
            var far = farMac(saved: saved)
            let ended = started(far, listener)
            guard case .offer(_, let link) = await homeMac(listener.port).fetch()
            else { Issue.record("no offer"); return }
            link.send(.ended(.deadline))
            #expect(await ended.value == .ended(.deadline))

            listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
            far = farMac(saved: saved, resultWindow: 0.4)
            let silent = started(far, listener)
            guard case .offer(_, let quiet) = await homeMac(listener.port).fetch()
            else { Issue.record("no offer"); return }
            #expect(await silent.value == .noResult)
            quiet.close()
            #expect(saved.all.isEmpty)

            // Tried, and the far Mac wouldn't save it: said so, not as saved.
            listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
            far = farMac(saved: saved, saves: false)
            let refused = started(far, listener)
            guard case .offer(_, let third) = await homeMac(listener.port).fetch()
            else { Issue.record("no offer"); return }
            #expect(PairByName.Home.handOver("device-1", on: third) == .unsaved)
            #expect(await refused.value == .unsaved)
        }

        @Test func theIntroducingMacAsksOnlyTheMacItNamedAndSaysWhatItCannotKnow() async throws {
            // The address is another machine's now: nothing is asked of it.
            var listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
            var port = listener.port
            async let wrong = homeMac(port, owner: { _ in
                "another"
            }).fetch()
            var (link, _) = try #require(listener.accept(within: 10))
            #expect(link.read(within: 10) == .closed)
            guard case .notThatMac = await wrong else { Issue.record("asked a stranger"); return }
            async let unnamed = homeMac(port, owner: { _ in
                nil
            }).fetch()
            (link, _) = try #require(listener.accept(within: 10))
            #expect(link.read(within: 10) == .closed)
            guard case .notThatMac = await unnamed else { Issue.record("asked a stranger"); return }

            // Another version answering.
            async let garbled = homeMac(port).fetch()
            (link, _) = try #require(listener.accept(within: 10))
            #expect(link.read(within: 10) == .line(PairWire.line(.wantOffer)))
            link.send(.saved)
            guard case .garbled = await garbled else { Issue.record("took it"); return }

            // No one there in time.
            listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
            port = listener.port
            guard case .noOne = await homeMac(port &+ 1, window: 0.3).fetch() else { Issue.record("someone?"); return }

            // The device handed over, and the answer lost: unknown, not "not saved".
            async let fetched = homeMac(port).fetch()
            (link, _) = try #require(listener.accept(within: 10))
            _ = link.read(within: 10)
            link.send(.offer("offer-1"))
            guard case .offer(_, let mine) = await fetched else { Issue.record("no offer"); return }
            async let answer = Task.detached {
                PairByName.Home.handOver("device-1", on: mine, within: 1)
            }
            .value
            #expect(link.read(within: 10) == .line(PairWire.line(.tried("device-1"))))
            link.close()
            #expect(await answer == .unknown)
        }

        @Test func aLineIsReadWholeAndOneWithoutEndIsNotKept() throws {
            let listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
            let from = try #require(PairLink.connect(to: "127.0.0.1", port: listener.port, interface: nil))
            let (to, _) = try #require(listener.accept(within: 10))
            from.send(.saved); from.send(.unsaved)
            #expect(to.read(within: 10) == .line(PairWire.line(.saved)))
            #expect(to.read(within: 10) == .line(PairWire.line(.unsaved)))
            #expect(to.read(within: 0.2) == .timeout)
            #expect(!to.gone)
            // At the limit and just past it, whatever a line ends with in the same read.
            let head = PairWire.line(.offer("")).utf8.count
            to.send(.offer(String(repeating: "x", count: PairWire.maxLine - head)))
            #expect(from.read(within: 10) == .line(PairWire.line(.offer(String(
                repeating: "x",
                count: PairWire.maxLine - head
            )))))
            to.send(.offer(String(repeating: "x", count: PairWire.maxLine - head + 1)))
            #expect(from.read(within: 10) == .tooLong)
            from.close()
            #expect(until {
                to.gone
            })
        }

        @Test func aListenerKeepsToItsInterfaceOrDoesNotListen() throws {
            _ = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: "lo0")
            #expect(throws: (any Error).self) { try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: "nosuch9") }
            let taken = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
            #expect(throws: (any Error).self) {
                try PairLink.Listener(ip: "127.0.0.1", port: taken.port, interface: nil)
            }
        }
    }
}

// MARK: - Device control, introduced by another Mac

@Test func whatIsSaidForDeviceControlIsReadBackAndACodeIsSixDigits() {
    let id = UUID().uuidString
    let all: [PairWire.Message] = [
        .wantDevice,
        .device("rr-device-v1:abc"),
        .attempt(id),
        .code("012345"),
        .result(.done(on: true)),
        .result(.done(on: false))
    ]
        + PairWire.Refusal.allCases.map {
            .result(.failed($0))
        }
    for m in all {
        #expect(PairWire.message(from: PairWire.line(m)) == m)
    }
    for line in [
        "rr-pair-v1 code 12345",
        "rr-pair-v1 code 1234567",
        "rr-pair-v1 code 12345a",
        "rr-pair-v1 code １２３４５６",
        "rr-pair-v1 code \u{1B}[2J12",
        "rr-pair-v1 attempt not-an-id",
        "rr-pair-v1 result done",
        "rr-pair-v1 result done maybe",
        "rr-pair-v1 result failed because",
        "rr-pair-v1 device"
    ] {
        #expect(PairWire.message(from: line) == nil, "\(line)")
    }
    #expect(PairWire.isCode("000000") && !PairWire.isCode("") && !PairWire.isCode("12 456") && !PairWire
        .isCode("１２３４５６"))

    // The other command that waits on this Mac is named, by its pid, so it can be stopped; this one isn't.
    let listed = """
    812 /usr/bin/ssh --with-something host
    4021 /Applications/RoamRun.app/Contents/MacOS/RoamRun pair control --with macbook-pro
    4388 /usr/local/bin/roamrun pair xcode --with macbook-pro
    """
    #expect(CLI.otherWaiting(inPgrep: listed, me: 4388)?.pid == 4021)
    #expect(CLI.otherWaiting(inPgrep: listed, me: 4021)?.command == "roamrun pair xcode --with macbook-pro")
    #expect(CLI.otherWaiting(inPgrep: "4388 /usr/local/bin/roamrun pair xcode --with x\n", me: 4388) == nil)
    #expect(CLI.otherWaiting(
        inPgrep: "77 /bin/zsh -c echo pair control --with x\n9 tart exec -t vm /x/RoamRun pair introduce --host a --to b",
        me: 1
    ) == nil)

    // The name this Mac offers under is one an offer may have, whatever the computer is called.
    func offered(_ name: String) -> Bool {
        var txt = [
            "identifier": "6BF40D22-D414-41D0-BE80-7567AE75B2BC",
            "authTag": "BsVby0td",
            "model": "Mac16,1",
            "flags": "1",
            "ver": "26",
            "minVer": "17"
        ]
        txt["name"] = Introduction.hostName(name)
        if case .success = Introduction
            .offer(from: Introduction.line(Introduction.Offer(port: 50000, txt: txt)))
        {
            return true
        }
        return false
    }
    #expect(Introduction.hostName("RoamRun (Studio)") == "RoamRun (Studio)")
    for name in [
        "RoamRun (" + String(repeating: "x", count: 54) + ")",
        "RoamRun (" + String(repeating: "開", count: 18) + ")",
        "RoamRun (a=b\\c)",
        "RoamRun (tab\tand\nline)",
        "",
        "\u{202E}"
    ] {
        #expect(offered(name) && Introduction.hostName(name).utf8.count <= 63, "\(name)")
    }
    #expect(Introduction.hostName("RoamRun (" + String(repeating: "開", count: 30) + ")")
        .unicodeScalars
        .allSatisfy {
            $0 != "\u{FFFD}"
        }) // cut between characters
}

/// A pairing that shows its code, then waits to be told the device paired.
private final class IntroducedPairing: PairingListener, @unchecked Sendable {
    let name = "RoamRun (test)"
    private let turn = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var cancelled = false
    var code: String? = "246810"
    func pairNow() {
        turn.signal()
    }

    var wasCancelled: Bool {
        lock.withLock {
            cancelled
        }
    }

    func accept(code show: @escaping @Sendable (String) -> Void) throws -> DevicePairing.Paired {
        if let code {
            show(code)
        }
        held(turn)
        if lock.withLock({
            cancelled
        }) {
            throw DeviceSession.Failure.message("cancelled")
        }
        if didFail {
            throw DevicePairing.NotCompleted(description: "the code entered on the device wasn't the one shown")
        }
        if didBreak {
            throw DeviceSession.Failure.message("the pairing didn't complete: Socket(ConnectionReset)")
        }
        return .init(
            udid: "00008130-000D00000000D004",
            name: "iPhone",
            model: "iPhone16,1",
            pairing: Data("<plist/>".utf8)
        )
    }

    func cancel() {
        lock.withLock {
            cancelled = true
        }
        turn.signal()
    }

    /// The device came and didn't take the pairing (`fail`), or the connection to it broke (`break`).
    private var failed = false, broken = false
    func fail() {
        lock.withLock {
            failed = true
        }
        turn.signal()
    }

    func breakOff() {
        lock.withLock {
            broken = true
        }
        turn.signal()
    }

    var didFail: Bool {
        lock.withLock {
            failed
        }
    }

    var didBreak: Bool {
        lock.withLock {
            broken
        }
    }
}

private let offerTXT = ["identifier": "6BF40D22-D414-41D0-BE80-7567AE75B2BC", "authTag": "BsVby0td", "model": "Mac16,1",
                        "name": "RoamRun (test)", "flags": "1", "ver": "26", "minVer": "17"]

/// The one turn at pairing a Mac has, as the hub keeps it.
private final class Turn: @unchecked Sendable {
    private let lock = NSLock()
    private var holder: UUID?
    let taken = Counted<UUID>(), given = Counted<UUID>()
    var held: UUID? {
        lock.withLock {
            holder
        }
    }

    func claim(_ id: UUID) -> Bool {
        lock.withLock {
            guard holder == nil else { return false }
            holder = id
            taken.add(id)
            return true
        }
    }

    func release(_ id: UUID) {
        lock.withLock {
            if holder == id {
                holder = nil; given.add(id)
            }
        }
    }
}

private func introductions(
    _ pairing: IntroducedPairing,
    turn: Turn = Turn(),
    keep: @escaping @Sendable (@Sendable () -> Bool)
        -> Result<ControlIntroductions.Kept, ControlIntroductions.NotKept> = { _ in .success(.init(
            name: "iPhone",
            on: true
        )) }
) -> ControlIntroductions {
    let made = ControlIntroductions()
    made.listen = { _, _, _ in
        .init(listener: pairing, port: 50123, txt: offerTXT)
    }
    made.keep = { _, _, wanted in
        keep(wanted)
    }
    made.claim = {
        turn.claim($0)
    }
    made.release = {
        turn.release($0)
    }
    made.tick = 0.02
    return made
}

private func candidate() -> String {
    let device = DeviceProfile(
        displayName: "iPhone",
        instanceName: "3DACFF68-D8B5-4990-B842-3BC99758E0A1",
        serviceType: "_remotepairing._tcp",
        domain: "local",
        remotePairingPort: 49152,
        bonjourHost: "",
        txt: [:],
        providerID: "tailscale",
        providerHostName: "iphone",
        providerIP: "100.64.0.9"
    )
    return String(decoding: try! JSONEncoder().encode(device), as: UTF8.self)
}

private func begin(_ i: ControlIntroductions, _ id: UUID, text: String? = candidate()) -> DeviceControlWire.Response {
    i.answer(.init(
        op: "pair-start",
        device: id,
        text: text,
        address: "100.64.0.2",
        interface: "utun9",
        peer: "100.64.0.1"
    ))
}

private func how(_ i: ControlIntroductions, _ id: UUID) -> DeviceControlWire.Response {
    i.answer(.init(
        op: "pair-status",
        device: id
    ))
}

extension TimingSensitive {
    @Suite struct DeviceControlIntroduced {
        @Test func theAppOffersShowsItsCodeOnlyToWhoAsksAndSaysWhatItKept() {
            let pairing = IntroducedPairing(), i = introductions(pairing), id = UUID()
            let started = begin(i, id)
            #expect(started.ok && started.offer
                .map {
                    if case .success = Introduction.offer(from: $0) {
                        true
                    } else {
                        false
                    }
                } == true)
            #expect(begin(i, id).offer == started.offer) // its answer lost: asked again, the same offer
            #expect(until {
                how(i, id).state == "code"
            } && how(i, id).code == "246810")
            #expect(begin(i, UUID()).reason == PairWire.Refusal.failed.rawValue) // one at a time
            pairing.pairNow()
            #expect(until {
                how(i, id).state == "done"
            })
            let done = how(i, id)
            #expect(done.allowed == true && done.name == "iPhone" && done
                .code == nil) // the code isn't kept once it is over
            #expect(i.answer(.init(op: "pair-status", device: UUID(), text: "last")).state == "done")
            #expect(how(i, UUID()).state == "unknown") // another attempt's is never said for this one
            #expect(begin(i, UUID()).ok) // and the next may begin
        }

        @Test func nothingIsAskedOfTheDeviceWhereItCouldNotBeKept() {
            // A pairing held already, a Keychain that refuses, a pairing on this Mac's own screen: no listener is opened.
            for refuse in 0 ..< 3 {
                let pairing = IntroducedPairing(), i = introductions(pairing)
                let opened = Counted<Int>()
                i.listen = { _, _, _ in
                    opened.add(1); return .init(listener: pairing, port: 50123, txt: offerTXT)
                }
                if refuse == 0 {
                    i.held = { _ in
                        true
                    }
                }
                if refuse == 1 {
                    i.ready = {
                        throw DeviceSession.Failure.message("the Keychain said no")
                    }
                }
                let turn = Turn()
                i.claim = {
                    turn.claim($0)
                }
                i.release = {
                    turn.release($0)
                }
                if refuse == 2 {
                    _ = turn.claim(UUID())
                } // a pairing on this Mac's own screen has the turn
                let r = begin(i, UUID())
                #expect(!r.ok && r.offer == nil && opened.all.isEmpty)
                #expect(r.reason == (refuse == 0 ? PairWire.Refusal.exists : .failed).rawValue)
                // And the turn is back where one was taken for nothing.
                if refuse < 2 {
                    #expect(turn.held == nil && turn.given.all.count == 1)
                }
            }
            let i = introductions(IntroducedPairing())
            #expect(!begin(i, UUID(), text: "{}").ok && !begin(i, UUID(), text: nil).ok)
        }

        @Test func stoppedBeforeTheDevicePairedNothingIsKeptAndOnceItPairedItIsSeenThrough() {
            // Stopped while it waits: the listener goes, nothing is kept.
            var pairing = IntroducedPairing()
            let kept = Counted<Int>()
            var i = introductions(pairing) { _ in
                kept.add(1); return .success(.init(name: "iPhone", on: true))
            }
            var id = UUID()
            #expect(begin(i, id).ok)
            let stopped = i.answer(.init(op: "pair-cancel", device: id))
            #expect(stopped.state == "failed" && stopped.reason == PairWire.Refusal.cancelled.rawValue)
            #expect(pairing.wasCancelled && kept.all.isEmpty)

            // Stopped while what paired is being kept: it is kept, and said to be.
            pairing = IntroducedPairing()
            let keeping = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
            // (What keeps it asks, as the app's does, whether it is still wanted: a stop that came too late doesn't make it say no.)
            i = introductions(pairing) { wanted in
                keeping.signal(); held(go)
                return wanted() ? .success(.init(name: "iPhone", on: false)) : .failure(.init(.cancelled, "stopped"))
            }
            id = UUID()
            #expect(begin(i, id).ok)
            pairing.pairNow()
            #expect(soon(keeping))
            #expect(how(i, id).state == "checking")
            let late = i.answer(.init(op: "pair-cancel", device: id))
            #expect(late.state == "checking")
            go.signal()
            #expect(until {
                how(i, id).state == "done"
            } && how(i, id)
                .allowed == false) // kept, and switched off: said as that
        }

        @Test func aCommandThatStopsAskingIsTakenForGoneButNotWhileTheAppKeepsWhatPaired() {
            var pairing = IntroducedPairing()
            var i = introductions(pairing)
            i.quiet = 0.2
            var id = UUID()
            #expect(begin(i, id).ok)
            #expect(until {
                pairing.wasCancelled
            })
            #expect(until { how(i, id).reason == PairWire.Refusal.cancelled.rawValue
            }) // said once the listener has let go

            // Asked often enough, it stays; and while it keeps, silence stops nothing.
            pairing = IntroducedPairing()
            let keeping = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
            i = introductions(pairing) { wanted in keeping.signal(); held(go); return wanted() ? .success(.init(
                name: "iPhone",
                on: true
            )) : .failure(.init(.cancelled, "stopped")) }
            i.quiet = 1
            id = UUID()
            #expect(begin(i, id).ok)
            for _ in 0 ..< 8 {
                usleep(200_000); _ = how(i, id)
            }
            #expect(!pairing.wasCancelled)
            pairing.pairNow()
            #expect(soon(keeping))
            usleep(1_500_000)
            go.signal()
            #expect(until {
                how(i, id).state == "done"
            })

            // And none waits longer than the longest it may.
            pairing = IntroducedPairing()
            i = introductions(pairing)
            i.longest = 0.2
            id = UUID()
            #expect(begin(i, id).ok)
            for _ in 0 ..< 250 where !pairing.wasCancelled {
                usleep(40_000); _ = how(i, id)
            }
            #expect(pairing.wasCancelled)
        }

        /// One pairing at a time, however begun: the turn is had before anything listens, and given back once.
        @Test func theTurnAtPairingIsTakenFirstAndGivenBackOnceHoweverItEnds() {
            // Two that begin at the same instant: one listens.
            var pairing = IntroducedPairing(), turn = Turn()
            var i = introductions(pairing, turn: turn)
            let opened = Counted<Int>(), first = pairing
            i.listen = { _, _, _ in opened.add(1); usleep(100_000); return .init(
                listener: first,
                port: 50123,
                txt: offerTXT
            ) }
            let answers = Counted<Bool>(), both = DispatchGroup()
            for _ in 0 ..< 2 {
                both.enter()
                let mine = i
                Thread.detachNewThread {
                    answers.add(begin(mine, UUID()).ok); both.leave()
                }
            }
            #expect(both.wait(timeout: .now() + 10) == .success)
            #expect(answers.all.sorted {
                !$0 && $1
            } == [false, true] && opened.all.count == 1)
            let id = turn.held
            #expect(id != nil)
            pairing.pairNow()
            #expect(until {
                turn.held == nil
            } && turn.given.all.count == 1)

            // Stopped, or the device came and didn't pair: given back too, and said as which.
            pairing = IntroducedPairing(); turn = Turn(); i = introductions(pairing, turn: turn)
            var attempt = UUID()
            #expect(begin(i, attempt).ok)
            _ = i.answer(.init(op: "pair-cancel", device: attempt))
            #expect(until {
                turn.held == nil
            })
            pairing = IntroducedPairing(); turn = Turn(); i = introductions(pairing, turn: turn)
            attempt = UUID()
            #expect(begin(i, attempt).ok)
            pairing.fail()
            #expect(until {
                how(i, attempt).reason == PairWire.Refusal.notPaired.rawValue
            } && turn.held == nil)
            // A connection that broke isn't the device's answer: not said as one to simply try again.
            pairing = IntroducedPairing(); turn = Turn(); i = introductions(pairing, turn: turn)
            attempt = UUID()
            #expect(begin(i, attempt).ok)
            pairing.breakOff()
            #expect(until {
                how(i, attempt).reason == PairWire.Refusal.failed.rawValue
            } && turn.held == nil)
            #expect(how(i, attempt).error?.contains("ConnectionReset") == true)

            // Keeping what paired takes longer than anything may: the turn is kept all the same — a
            // pairing begun meanwhile could have the device drop the one being kept — and given back when it ends.
            pairing = IntroducedPairing(); turn = Turn()
            let keeping = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
            i = introductions(pairing, turn: turn) { wanted in
                keeping.signal(); held(go); return wanted() ? .success(.init(
                    name: "iPhone",
                    on: true
                )) : .failure(.init(.cancelled, "stopped"))
            }
            i.longest = 1
            attempt = UUID()
            #expect(begin(i, attempt).ok)
            pairing.pairNow()
            #expect(soon(keeping))
            usleep(1_500_000)
            #expect(turn.held == attempt && how(i, attempt).state == "checking")
            #expect(begin(i, UUID()).reason == PairWire.Refusal.failed.rawValue) // no other begins meanwhile
            go.signal()
            #expect(until {
                how(i, attempt).state == "done"
            } && turn.held == nil && turn.given.all.count == 1)
        }

        /// Nothing listens once the device has paired, however long keeping takes: the listener is let go then.
        @Test func theListenerIsLetGoTheMomentTheDeviceHasPaired() {
            final class Seen: @unchecked Sendable { weak var listener: IntroducedPairing? }
            let seen = Seen(), i = ControlIntroductions()
            let keeping = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
            i.listen = { _, _, _ in
                let made = IntroducedPairing()
                seen.listener = made
                return .init(listener: made, port: 50123, txt: offerTXT)
            }
            i.keep = { _, _, _ in
                keeping.signal(); held(go); return .success(.init(name: "iPhone", on: true))
            }
            i.tick = 0.02
            let id = UUID()
            #expect(begin(i, id).ok && seen.listener != nil)
            seen.listener?.pairNow()
            #expect(soon(keeping))
            #expect(until {
                seen.listener == nil
            }) // while what paired is still being kept
            #expect(how(i, id).state == "checking")
            go.signal()
            #expect(until {
                how(i, id).state == "done"
            })
        }

        /// Asked to begin again under the same id while it is still being made ready (its answer was
        /// lost): told so, with no second listener; any other is turned away.
        @Test func begunAgainWhileItIsMadeReadyItSaysSoAndOpensNothingMore() {
            let pairing = IntroducedPairing(), i = introductions(pairing)
            let opened = Counted<Int>(), readying = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
            i.ready = {
                readying.signal(); held(go)
            }
            i.listen = { _, _, _ in
                opened.add(1); return .init(listener: pairing, port: 50123, txt: offerTXT)
            }
            let id = UUID(), first = Counted<Bool>()
            Thread.detachNewThread {
                first.add(begin(i, id).offer != nil)
            }
            #expect(soon(readying))
            let again = begin(i, id)
            #expect(again.ok && again.state == "preparing" && again.offer == nil)
            #expect(how(i, id).state == "preparing")
            #expect(begin(i, UUID()).reason == PairWire.Refusal.failed.rawValue)
            go.signal()
            #expect(until {
                first.all == [true]
            } && opened.all.count == 1)
            #expect(begin(i, id).offer != nil && opened.all.count == 1)
        }

        @Test func whatCouldNotBeKeptIsSaidWithItsWord() {
            let pairing = IntroducedPairing()
            let i = introductions(pairing) { _ in
                .failure(.init(.exists, "this Mac already holds a pairing"))
            }
            let id = UUID()
            #expect(begin(i, id).ok)
            pairing.pairNow()
            #expect(until {
                how(i, id).state == "failed"
            })
            #expect(how(i, id).reason == "exists" && how(i, id).error == "this Mac already holds a pairing")
        }
    }
}

private let anAttempt = "6BF40D22-D414-41D0-BE80-7567AE75B2BC"

private func farControl(
    start: @escaping @Sendable (String) async -> PairByName.FarControl.Started = { _ in .offer(
        "offer-1",
        attempt: anAttempt
    ) },
    status: @escaping @Sendable () async -> PairByName.FarControl.Status,
    cancelled: Counted<Int> = .init(),
    events: Counted<PairByName.FarControl.Event> = .init(),
    owner: @escaping @Sendable (String) -> String? = { _ in
        "home"
    },
    resultWindow: TimeInterval = 5,
    tries: Int = 5
) -> PairByName.FarControl {
    PairByName.FarControl(peer: .init(ip: "127.0.0.1", id: "home"), owner: owner,
                          start: start, status: { _ in
                              await status()
                          }, cancel: { _ in
                              cancelled.add(1)
                          },
                          tries: tries,
                          say: {
                              events.add($0)
                          },
                          connectWindow: 5, resultWindow: resultWindow, lineWait: 1, pause: 0.05)
}

private func startedControl(_ far: PairByName.FarControl,
                            _ listener: PairLink.Listener) -> Task<PairByName.FarControl.End, Never>
{
    Task.detached {
        await far.run(listener)
    }
}

private func homeForControl(_ port: UInt16, device: String? = "device-1") -> PairByName.Home {
    PairByName.Home(peer: .init(ip: "127.0.0.1", id: "far"), owner: { _ in
        "far"
    },
    connect: {
        PairLink.connect(to: "127.0.0.1", port: port, interface: nil, within: 1)
    },
    device: device, window: 5, lineWait: 1, pause: .milliseconds(20))
}

extension TimingSensitive.DeviceControlIntroduced {
    /// The whole exchange between the two Macs: the device first, then the offer, the code once, the result.
    @Test func theDeviceIsAskedForFirstAndTheCodeAndTheResultArePassedOn() async throws {
        let listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
        let given = Counted<String>(), asks = Counted<Int>(), cancelled = Counted<Int>(),
            events = Counted<PairByName.FarControl.Event>()
        let far = farControl(start: {
                                 given.add($0); return .offer("offer-1", attempt: anAttempt)
                             },
                             status: { asks.add(1); return [
                                 1: .waiting,
                                 2: .code("246810"),
                                 3: .code("246810"),
                                 4: .checking
                             ][asks.all.count] ?? .done(on: true) },
                             cancelled: cancelled, events: events)
        let end = startedControl(far, listener)
        guard case .control(let offer, let attempt, let link) = await homeForControl(listener.port).fetch()
        else { Issue.record("no offer"); return }
        #expect(offer == "offer-1" && attempt == "6BF40D22-D414-41D0-BE80-7567AE75B2BC" && given.all == ["device-1"])
        #expect(link.read(within: 10).message == .code("246810"))
        #expect(link.read(within: 10)
            .message == .result(.done(on: true))) // the code went once, not each time it was said
        #expect(await end.value == .done(on: true))
        #expect(cancelled.all.isEmpty && events.all == [.connected, .offerSent(attempt: anAttempt), .codeSent])
    }

    @Test func aMacThatOffersForXcodeIsAskedAsBeforeAndOneWithoutADeviceToGiveAsksNothingMore() async throws {
        // #96's far Mac answers the same first line with its offer: nothing changes for it.
        var listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
        let saved = Counted<String>()
        let xcode = started(farMac(saved: saved), listener)
        guard case .offer(_, let link) = await homeForControl(listener.port).fetch()
        else { Issue.record("not the Xcode turn"); return }
        #expect(PairByName.Home.handOver("device-1", on: link) == .saved)
        #expect(await xcode.value == .saved)

        // Asked for a device it has none to give: it ends there.
        listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
        let far = farControl(status: {
            .waiting
        })
        let end = startedControl(far, listener)
        guard case .garbled = await homeForControl(listener.port, device: nil).fetch()
        else { Issue.record("went on without a device"); return }
        end.cancel()
    }

    @Test func whereItCannotBeginOrTheOtherMacStopsTheAppIsToldAndNothingIsWaitedFor() async throws {
        // The app refuses: the other Mac is told before it announces anything.
        var listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
        var end = startedControl(farControl(start: { _ in
            .refused(.exists)
        }, status: {
            .unknown
        }), listener)
        guard case .refused(.exists) = await homeForControl(listener.port).fetch()
        else { Issue.record("not told why"); return }
        #expect(await end.value == .failed(.exists))

        // The other Mac says it stopped (its five minutes): the app is told to stop.
        listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
        let cancelled1 = Counted<Int>()
        end = startedControl(
            farControl(status: {
                cancelled1.all.isEmpty ? .waiting : .failed(.cancelled)
            }, cancelled: cancelled1),
            listener
        )
        guard case .control(_, _, let link) = await homeForControl(listener.port).fetch()
        else { Issue.record("no offer"); return }
        link.send(.ended(.deadline))
        #expect(await end.value == .ended(.deadline))
        #expect(cancelled1.all.count == 1)

        // It goes away without a word while the device's pairing is being kept: stopped too late, and said as that.
        listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
        let cancelled2 = Counted<Int>()
        end = startedControl(farControl(status: {
            .checking
        }, cancelled: cancelled2), listener)
        guard case .control(_, _, let second) = await homeForControl(listener.port).fetch()
        else { Issue.record("no offer"); return }
        second.close()
        #expect(await end.value == .lost(.checking))
        #expect(cancelled2.all.count == 1)

        // …and when it had been kept by then, that is what is said.
        listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
        let cancelled3 = Counted<Int>()
        end = startedControl(
            farControl(status: {
                cancelled3.all.isEmpty ? .checking : .done(on: true)
            }, cancelled: cancelled3),
            listener
        )
        guard case .control(_, _, let third) = await homeForControl(listener.port).fetch()
        else { Issue.record("no offer"); return }
        third.close()
        #expect(await end.value == .done(on: true))
    }

    /// A wrong code ends the introducing Mac's command, not this one: it waits for that Mac again,
    /// with an attempt of its own each time, and gives up after so many.
    @Test func aPairingThatWasNotMadeIsWaitedForAgainOnTheFarMac() async throws {
        let listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
        let begun = Counted<String>(), events = Counted<PairByName.FarControl.Event>()
        let far = PairByName.FarControl(
            peer: .init(ip: "127.0.0.1", id: "home"), owner: { _ in
                "home"
            },
            start: { _ in
                let id = UUID().uuidString
                begun.add(id)
                return .offer("offer-\(begun.all.count)", attempt: id)
            },
            status: { id in
                id == begun.all.first ? .failed(.notPaired) : .done(on: true)
            },
            cancel: { _ in }, say: {
                events.add($0)
            }, connectWindow: 5, resultWindow: 5, lineWait: 1, pause: 0.05
        )
        let end = startedControl(far, listener)
        guard case .control(let first, let one, let link) = await homeForControl(listener.port).fetch()
        else { Issue.record("no offer"); return }
        #expect(link.read(within: 10).message == .result(.failed(.notPaired)))
        link.close()
        guard case .control(let second, let two, let again) = await homeForControl(listener.port).fetch()
        else { Issue.record("not waited for again"); return }
        #expect(first == "offer-1" && second == "offer-2" && one != two && begun.all == [one, two])
        #expect(again.read(within: 10).message == .result(.done(on: true)))
        #expect(await end.value == .done(on: true))
        #expect(events.all.contains(.again))

        // Not for ever, and not for what isn't the device's doing.
        var other = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
        var ended = startedControl(farControl(status: {
            .failed(.notPaired)
        }, tries: 2), other)
        for _ in 1 ... 2 {
            guard case .control(_, _, let link) = await homeForControl(other.port).fetch()
            else { Issue.record("no offer"); return }
            #expect(link.read(within: 10).message == .result(.failed(.notPaired)))
            link.close()
        }
        #expect(await ended.value == .failed(.notPaired))
        other = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
        ended = startedControl(farControl(status: {
            .failed(.notKept)
        }), other)
        guard case .control(_, _, let last) = await homeForControl(other.port).fetch()
        else { Issue.record("no offer"); return }
        #expect(last.read(within: 10).message == .result(.failed(.notKept)))
        #expect(await ended.value == .failed(.notKept))
    }

    @Test func aCodeThatIsNotOneOrCannotBeSentEndsTheAttempt() async throws {
        let listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
        let cancelled = Counted<Int>()
        let end = startedControl(
            farControl(status: {
                           cancelled.all.isEmpty ? .code("12\u{1B}[2J") : .failed(.cancelled)
                       },
                       cancelled: cancelled),
            listener
        )
        guard case .control(_, _, let link) = await homeForControl(listener.port).fetch()
        else { Issue.record("no offer"); return }
        #expect(link.read(within: 10) == .closed) // nothing that isn't a code is passed on
        #expect(await end.value == .lost(.failed(.cancelled)))
        #expect(cancelled.all.count == 1)
    }

    /// Stopped, or out of time, while the app keeps what paired: that goes on, and isn't said as nothing kept.
    @Test func anEndWhileTheAppKeepsWhatPairedIsNotSaidAsNothingKept() async throws {
        var listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
        let end = startedControl(farControl(status: {
            .checking
        }, resultWindow: 0.4), listener)
        guard case .control(_, _, let link) = await homeForControl(listener.port).fetch()
        else { Issue.record("no offer"); return }
        #expect(await end.value == .lost(.checking))
        link.close()

        // The app gone: not waited out, and not said as nothing kept either.
        listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
        let gone = startedControl(farControl(status: {
            .unknown
        }, resultWindow: 30), listener)
        guard case .control(_, _, let second) = await homeForControl(listener.port).fetch()
        else { Issue.record("no offer"); return }
        let asked = Date()
        #expect(await gone.value == .lost(.unknown))
        #expect(Date().timeIntervalSince(asked) < 10) // after a few questions, not at the end of all the time there is
        second.close()
    }

    @Test func noResultInTimeIsSaidAndTheAppStopped() async throws {
        let listener = try PairLink.Listener(ip: "127.0.0.1", port: 0, interface: nil)
        let cancelled = Counted<Int>()
        let end = startedControl(
            farControl(status: {
                cancelled.all.isEmpty ? .waiting : .failed(.cancelled)
            }, cancelled: cancelled,
            resultWindow: 0.4),
            listener
        )
        guard case .control(_, _, let link) = await homeForControl(listener.port).fetch()
        else { Issue.record("no offer"); return }
        #expect(await end.value == .noResult)
        #expect(cancelled.all.count == 1)
        link.close()
    }
}
