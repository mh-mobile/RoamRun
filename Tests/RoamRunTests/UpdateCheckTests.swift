import Foundation
import Testing
@testable import RoamRun

private func release(_ tag: String) -> Data {
    Data(#"{"tag_name": "\#(tag)", "html_url": "https://example.com/elsewhere"}"#.utf8)
}

private func answering(_ status: Int, _ body: Data, calls: Counter = Counter()) -> UpdateCheck.Fetch {
    { request in
        calls.bump()
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Test func versionsCompareByNumber() {
    #expect(UpdateCheck.answer(current: "0.9.0", latest: "0.13.0") == .success(.newer("0.13.0")))
    #expect(UpdateCheck.answer(current: "0.13.0", latest: "0.13.1") == .success(.newer("0.13.1")))
    #expect(UpdateCheck.answer(current: "0.99.99", latest: "1.0.0") == .success(.newer("1.0.0")))
    #expect(UpdateCheck.answer(current: "0.13.0", latest: "0.13.0") == .success(.upToDate))
    #expect(UpdateCheck.answer(current: "0.14.0", latest: "0.13.0") == .success(.upToDate)) // a build ahead
    guard case .failure = UpdateCheck.answer(current: "dev", latest: "0.13.0") else {
        Issue.record("a build without a version compared")
        return
    }
}

@Test func theReleaseIsReadFromItsTag() {
    #expect(UpdateCheck.latestVersion(release("v0.14.0")) == .success("0.14.0"))
    for tag in ["0.14.0", "v0.14", "v0.14.0-beta.1", "v0.14.0.1", "v+1.0.0", "v-1.0.0", "v٣.0.0", "release",
                "V0.14.0"]
    {
        guard case .failure = UpdateCheck.latestVersion(release(tag)) else {
            Issue.record("took \(tag)")
            continue
        }
    }
    for body in ["", "[]", #"{"name": "v0.14.0"}"#, #"{"tag_name": 14}"#, "<html>"] {
        guard case .failure = UpdateCheck.latestVersion(Data(body.utf8)) else {
            Issue.record("took \(body)")
            continue
        }
    }
}

@Test func thePageIsOursAndNamesTheCheckedVersion() async {
    #expect(UpdateCheck.page("0.14.0").absoluteString == "https://github.com/mh-mobile/RoamRun/releases/tag/v0.14.0")
    // The answer's own URL is never what is offered.
    let result = await UpdateCheck.check(current: "0.13.0", fetch: answering(200, release("v0.14.0")))
    #expect(result == .success(.newer("0.14.0")))
}

@Test func theRequestCarriesNothingOfTheUser() {
    let r = UpdateCheck.request
    #expect(r.url?.absoluteString == "https://api.github.com/repos/mh-mobile/RoamRun/releases/latest")
    #expect(r.httpMethod == "GET" && r.httpBody == nil && !r.httpShouldHandleCookies)
    #expect(r.allHTTPHeaderFields == [
        "User-Agent": "RoamRun",
        "Accept": "application/vnd.github+json",
        "Accept-Language": "en"
    ])
    let c = UpdateCheck.session.configuration
    #expect(c.httpCookieStorage == nil && c.urlCredentialStorage == nil && c.urlCache == nil)
    #expect(c.timeoutIntervalForResource <= 30)
}

@Test func aRedirectIsAnsweredAsItCameNotFollowed() async {
    #expect(UpdateCheck.session.delegate is UpdateCheck.NoRedirects)
    let elsewhere = URL(string: "https://example.com/")!
    let moved = HTTPURLResponse(url: UpdateCheck.latestURL, statusCode: 301, httpVersion: nil,
                                headerFields: ["Location": elsewhere.absoluteString])!
    // Never resumed: nothing is sent.
    let task = UpdateCheck.session.dataTask(with: UpdateCheck.request)
    let next = await UpdateCheck.NoRedirects().urlSession(UpdateCheck.session, task: task,
                                                          willPerformHTTPRedirection: moved,
                                                          newRequest: URLRequest(url: elsewhere))
    #expect(next == nil)
    // And the 301 itself is a failed check.
    guard case .failure = await UpdateCheck.check(current: "0.13.0", fetch: answering(301, Data())) else {
        Issue.record("301 answered")
        return
    }
}

@Test func anAnswerOtherThanAReleaseIsAFailedCheck() async {
    for (status, body) in [(404, Data()), (403, release("v0.14.0")), (200, Data("{}".utf8))] {
        guard case .failure = await UpdateCheck.check(current: "0.13.0", fetch: answering(status, body)) else {
            Issue.record("\(status) answered")
            continue
        }
    }
    let unreachable: UpdateCheck.Fetch = { _ in
        throw URLError(.notConnectedToInternet)
    }
    guard case .failure = await UpdateCheck.check(current: "0.13.0", fetch: unreachable) else {
        Issue.record("no network answered")
        return
    }
}

@Test func aCheckIsDueOnlyWhenTurnedOnAndADayOld() {
    let now = Date()
    #expect(!UpdateCheck.isDue(enabled: false, last: nil, now: now))
    #expect(!UpdateCheck.isDue(enabled: false, last: now - 3 * UpdateCheck.interval, now: now))
    #expect(UpdateCheck.isDue(enabled: true, last: nil, now: now))
    #expect(!UpdateCheck.isDue(enabled: true, last: now - 3600, now: now))
    #expect(UpdateCheck.isDue(enabled: true, last: now - UpdateCheck.interval, now: now))
    #expect(UpdateCheck.isDue(enabled: true, last: now + 3600, now: now)) // the clock went back
}

@MainActor @Test func noRequestIsMadeWithTheSettingOff() async throws {
    let suite = "roamrun-update-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let calls = Counter()
    var now = Date()
    let checker = UpdateChecker(current: "0.13.0", defaults: defaults,
                                fetch: answering(200, release("v0.14.0"), calls: calls), now: {
                                    now
                                })

    #expect(checker.checkIfDue() == nil) // never turned on
    defaults.set(false, forKey: UpdateCheck.automaticKey)
    #expect(checker.checkIfDue() == nil)
    #expect(calls.value == 0 && defaults.object(forKey: UpdateCheck.lastAttemptKey) == nil)

    defaults.set(true, forKey: UpdateCheck.automaticKey)
    await checker.checkIfDue()?.value
    #expect(calls.value == 1 && checker.available == "0.14.0")
    #expect(checker.lastAnswer == nil) // only a check the user asked for opens the window's answer

    now += 3600
    #expect(checker.checkIfDue() == nil) // once a day
    now += UpdateCheck.interval
    await checker.checkIfDue()?.value
    #expect(calls.value == 2)

    defaults.set(false, forKey: UpdateCheck.automaticKey)
    now += 3 * UpdateCheck.interval
    #expect(checker.checkIfDue() == nil)
    #expect(calls.value == 2)
}

@MainActor @Test func aFailedAutomaticCheckShowsNothing() async throws {
    let suite = "roamrun-update-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: UpdateCheck.automaticKey)
    let checker = UpdateChecker(current: "0.13.0", defaults: defaults, fetch: answering(500, Data()))
    await checker.checkIfDue()?.value
    #expect(checker.available == nil && checker.lastAnswer == nil)
    #expect(defaults.object(forKey: UpdateCheck.lastAttemptKey) != nil) // and waits a day like any other

    await checker.checkNow()?.value // asked for: said
    guard case .failure = checker.lastAnswer else {
        Issue.record("an asked-for failure wasn't shown")
        return
    }
}

@MainActor @Test func aCheckThatSentNothingIsDueAgain() async throws {
    let suite = "roamrun-update-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: UpdateCheck.automaticKey)
    let offline: UpdateCheck.Fetch = { _ in
        throw URLError(.notConnectedToInternet)
    }
    await UpdateChecker(current: "0.13.0", defaults: defaults, fetch: offline).checkIfDue()?.value
    #expect(defaults.object(forKey: UpdateCheck.lastAttemptKey) == nil) // just after login, say: the next hour tries
    let timedOut: UpdateCheck.Fetch = { _ in
        throw URLError(.timedOut)
    }
    await UpdateChecker(current: "0.13.0", defaults: defaults, fetch: timedOut).checkIfDue()?.value
    #expect(defaults.object(forKey: UpdateCheck.lastAttemptKey) != nil) // it may have reached GitHub: a day
}

@MainActor @Test func askingDuringAnAutomaticCheckGetsItsAnswer() async throws {
    let suite = "roamrun-update-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: UpdateCheck.automaticKey)
    let calls = Counter()
    let checker = UpdateChecker(current: "0.13.0", defaults: defaults,
                                fetch: answering(200, release("v0.13.0"), calls: calls))
    let automatic = try #require(checker.checkIfDue())
    #expect(checker.checkNow() == nil) // one request, not two
    await automatic.value
    #expect(calls.value == 1 && checker.lastAnswer == .success(.upToDate))
}
