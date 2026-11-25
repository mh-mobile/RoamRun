import Foundation

/// Asks GitHub for the newest release: when the user asks, or once a day if they turned that on.
/// Nothing is downloaded; the page opened is built here, never taken from the answer.
enum UpdateCheck {
    static let latestURL = URL(string: "https://api.github.com/repos/mh-mobile/RoamRun/releases/latest")!
    /// Off unless the user turns it on in Settings.
    static let automaticKey = "checkForUpdatesAutomatically"
    static let lastAttemptKey = "lastUpdateCheck"
    static let interval: TimeInterval = 24 * 60 * 60

    enum Answer: Equatable {
        case upToDate
        case newer(String)
    }

    struct Failure: Error, Equatable {
        let reason: String
    }

    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// 0.13.0 as [0, 13, 0]; nil for anything else (no signs, no fourth number).
    static func numbers(_ version: String) -> [Int]? {
        guard let m = version.wholeMatch(of: #/([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9})/#) else { return nil }
        return [m.1, m.2, m.3].compactMap {
            Int($0)
        }
    }

    /// The version of a releases/latest answer, when its tag is v<major>.<minor>.<patch>.
    static func latestVersion(_ data: Data) -> Result<String, Failure> {
        struct Release: Decodable { let tag_name: String }
        guard let tag = try? JSONDecoder().decode(Release.self, from: data).tag_name else {
            return .failure(Failure(reason: "GitHub's answer named no release"))
        }
        guard tag.hasPrefix("v"), numbers(String(tag.dropFirst())) != nil else {
            return .failure(Failure(reason: "the newest release's tag isn't a version: \(tag.debugDescription)"))
        }
        return .success(String(tag.dropFirst()))
    }

    static func answer(current: String, latest: String) -> Result<Answer, Failure> {
        guard let have = numbers(current) else {
            return .failure(Failure(reason: "this build has no version to compare (\(current))"))
        }
        guard let out = numbers(latest) else {
            return .failure(Failure(reason: "not a version: \(latest)"))
        }
        return .success(have.lexicographicallyPrecedes(out) ? .newer(latest) : .upToDate)
    }

    /// The release page of a version checked above, on this repository.
    static func page(_ version: String) -> URL {
        URL(string: "https://github.com/mh-mobile/RoamRun/releases/tag/v\(version)")!
    }

    /// Due when turned on and the last attempt is a day old, or none was made, or it is in the future (the clock moved).
    static func isDue(enabled: Bool, last: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        guard let last else { return true }
        let since = now.timeIntervalSince(last)
        return since < 0 || since >= interval
    }

    /// The one request: no cookies, no credentials, and headers that say nothing about the Mac or its user.
    static var request: URLRequest {
        var r = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        r.httpShouldHandleCookies = false
        r.setValue("RoamRun", forHTTPHeaderField: "User-Agent")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("en", forHTTPHeaderField: "Accept-Language")
        return r
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        c.urlCache = nil
        c.timeoutIntervalForResource = 20 // the whole request, not only a pause in it
        return URLSession(configuration: c)
    }()

    static let fetch: Fetch = { request in
        try await session.data(for: request)
    }

    static func check(current: String, fetch: Fetch = fetch) async -> Result<Answer, Failure> {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await fetch(request)
        } catch {
            return .failure(Failure(reason: error.localizedDescription))
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            let code = (response as? HTTPURLResponse).map {
                " \($0.statusCode)"
            } ?? ""
            return .failure(Failure(reason: "GitHub answered\(code) instead of a release"))
        }
        return latestVersion(data).flatMap {
            answer(current: current, latest: $0)
        }
    }
}

/// The app's checks: on request, and hourly a look whether the daily one is due.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    /// A newer release the last check that answered found; the menu offers its page.
    @Published private(set) var available: String?
    @Published private(set) var checking = false
    /// What the last check the user asked for came to, for the window.
    @Published private(set) var lastAnswer: Result<UpdateCheck.Answer, UpdateCheck.Failure>?

    let current: String
    private let defaults: UserDefaults
    private let fetch: UpdateCheck.Fetch
    private let now: () -> Date
    private var timer: Timer?

    init(current: String = Bundle.main.versionText, defaults: UserDefaults = .standard,
         fetch: @escaping UpdateCheck.Fetch = UpdateCheck.fetch, now: @escaping () -> Date = Date.init)
    {
        self.current = current
        self.defaults = defaults
        self.fetch = fetch
        self.now = now
    }

    func start() {
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                _ = UpdateChecker.shared.checkIfDue()
            }
        }
    }

    /// Makes no request unless the automatic check is on and a day has passed.
    @discardableResult func checkIfDue() -> Task<Void, Never>? {
        let last = defaults.object(forKey: UpdateCheck.lastAttemptKey) as? Date
        guard !checking,
              UpdateCheck.isDue(enabled: defaults.bool(forKey: UpdateCheck.automaticKey), last: last, now: now())
        else { return nil }
        return check(asked: false)
    }

    @discardableResult func checkNow() -> Task<Void, Never>? {
        guard !checking else { return nil }
        lastAnswer = nil
        return check(asked: true)
    }

    private func check(asked: Bool) -> Task<Void, Never> {
        checking = true
        defaults.set(now(), forKey: UpdateCheck.lastAttemptKey) // a failed one waits a day too
        let (current, fetch) = (current, fetch)
        return Task {
            let result = await UpdateCheck.check(current: current, fetch: fetch)
            checking = false
            if case .success(let answer) = result {
                if case .newer(let version) = answer {
                    available = version
                } else {
                    available = nil
                }
            }
            if asked {
                lastAnswer = result
            } // a failed automatic check shows nothing
        }
    }
}
