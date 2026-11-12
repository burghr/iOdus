import XCTest
@testable import iOdus

final class UpdateVersionTests: XCTestCase {
    func testCompare() {
        XCTAssertEqual(UpdateCheck.compare("0.10.0", "0.9.1"), .orderedDescending, "Numbers, not text")
        XCTAssertEqual(UpdateCheck.compare("v0.2", "0.2.0"), .orderedSame, "A v prefix and a missing part")
        XCTAssertEqual(UpdateCheck.compare("1.0.0-beta.2", "1.0.0"), .orderedSame, "The suffix is ignored")
        XCTAssertEqual(UpdateCheck.compare("0.1.0", "0.1.1"), .orderedAscending)
    }

    func testNewestSkipsDraftsAndPreReleases() {
        let releases = [
            ReleaseInfo(tagName: "v0.2.0", htmlURL: "a", draft: false, prerelease: false),
            ReleaseInfo(tagName: "v0.4.0", htmlURL: "b", draft: true, prerelease: false),
            ReleaseInfo(tagName: "v0.3.0", htmlURL: "c", draft: false, prerelease: true),
            ReleaseInfo(tagName: "v0.10.0", htmlURL: "d", draft: false, prerelease: false),
        ]
        XCTAssertEqual(UpdateCheck.newest(releases)?.tagName, "v0.10.0")
        XCTAssertNil(UpdateCheck.newest([releases[1], releases[2]]))
        XCTAssertEqual(UpdateCheck.newest([releases[0], releases[1], releases[2]], prereleases: true)?.tagName, "v0.3.0",
                       "With the switch on, a pre-release counts, a draft does not")
        XCTAssertEqual(UpdateCheck.newest(releases, prereleases: true)?.tagName, "v0.10.0",
                       "A newer full release still wins")
    }
}

@MainActor
final class UpdateCheckerTests: XCTestCase {
    private let releasesJSON = #"""
    [{"tag_name":"v0.3.0","html_url":"https://github.com/burghr/iOdus/releases/tag/v0.3.0","draft":false,"prerelease":false,"name":"x"},
     {"tag_name":"v0.4.0","html_url":"https://github.com/burghr/iOdus/releases/tag/v0.4.0","draft":false,"prerelease":true}]
    """#

    /// Separate settings, so that the real ones do not change. One fixed name:
    /// a new name for each test leaves one settings file for each test run.
    private static let suite = "iodus-update-tests"

    private func defaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: Self.suite)!
        defaults.removePersistentDomain(forName: Self.suite)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: Self.suite) }
        return defaults
    }

    /// A fake GitHub: returns `body` with `status`, and counts the requests.
    private final class FakeGitHub: @unchecked Sendable {
        var calls = 0
        var lastURL: URL?
        let status: Int
        let body: Data
        init(status: Int, body: String) { self.status = status; self.body = Data(body.utf8) }
        var fetch: UpdateChecker.Fetch {
            { url in self.calls += 1; self.lastURL = url; return (self.body, self.status) }
        }
    }

    func testPreReleasesNeedTheSwitch() async throws {
        let github = FakeGitHub(status: 200, body: releasesJSON)
        let store = defaults()
        let checker = UpdateChecker(repository: "burghr/iOdus", currentVersion: "0.3.0", defaults: store, fetch: github.fetch)
        XCTAssertFalse(checker.prereleases, "Off by default")
        let none = await checker.check(force: true)
        XCTAssertNil(none)
        XCTAssertNil(checker.available, "0.4.0 is a pre-release")

        checker.prereleases = true
        let found = await checker.check(force: true)
        let item = try XCTUnwrap(found)
        XCTAssertEqual(checker.available?.version, "0.4.0")
        XCTAssertEqual(item.title, "iOdus 0.4.0 (pre-release) is available")

        checker.prereleases = false
        _ = await checker.check(force: true)
        XCTAssertNil(checker.available, "Off again: the pre-release is not offered")
    }

    func testNewVersionGivesOneNotification() async throws {
        let github = FakeGitHub(status: 200, body: releasesJSON)
        let store = defaults()
        let checker = UpdateChecker(repository: "burghr/iOdus", currentVersion: "0.1.0", defaults: store, fetch: github.fetch)
        let first = await checker.check(force: true)
        let item = try XCTUnwrap(first)
        XCTAssertEqual(item.kind, .update)
        XCTAssertEqual(item.title, "iOdus 0.3.0 is available", "The pre-release 0.4.0 is skipped")
        XCTAssertEqual(item.action, .openUpdate, "The notification opens Settings > Updates")
        XCTAssertEqual(checker.available?.version, "0.3.0")
        XCTAssertEqual(github.lastURL?.absoluteString, "https://api.github.com/repos/burghr/iOdus/releases?per_page=20")
        let again = await checker.check(force: true)
        XCTAssertNil(again, "The same version is not announced two times")
        XCTAssertEqual(store.string(forKey: UpdateChecker.announcedKey), "0.3.0")
    }

    func testOnceADay() async {
        let github = FakeGitHub(status: 200, body: "[]")
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let checker = UpdateChecker(repository: "o/r", currentVersion: "0.1.0", defaults: defaults(),
                                    fetch: github.fetch, now: { clock })
        _ = await checker.check()
        _ = await checker.check()
        XCTAssertEqual(github.calls, 1, "The second check is not due")
        clock = clock.addingTimeInterval(UpdateChecker.interval)
        _ = await checker.check()
        XCTAssertEqual(github.calls, 2, "One day later the check is due again")
    }

    func testQuietCases() async {
        // The repository does not exist yet: GitHub answers 404.
        let missing = FakeGitHub(status: 404, body: #"{"message":"Not Found"}"#)
        var result = await UpdateChecker(repository: "o/r", currentVersion: "0.1.0", defaults: defaults(),
                                         fetch: missing.fetch).check(force: true)
        XCTAssertNil(result)

        // The same or an older version.
        let same = FakeGitHub(status: 200, body: releasesJSON)
        result = await UpdateChecker(repository: "o/r", currentVersion: "0.3.0", defaults: defaults(),
                                     fetch: same.fetch).check(force: true)
        XCTAssertNil(result)

        // A development build has no version: no request.
        let dev = FakeGitHub(status: 200, body: releasesJSON)
        result = await UpdateChecker(repository: "o/r", currentVersion: nil, defaults: defaults(),
                                     fetch: dev.fetch).check(force: true)
        XCTAssertNil(result)
        XCTAssertEqual(dev.calls, 0)

        // The check is off.
        let off = FakeGitHub(status: 200, body: releasesJSON)
        let checker = UpdateChecker(repository: "o/r", currentVersion: "0.1.0", defaults: defaults(), fetch: off.fetch)
        XCTAssertTrue(checker.enabled, "On by default")
        checker.enabled = false
        result = await checker.check(force: true)
        XCTAssertNil(result)
        XCTAssertEqual(off.calls, 0)

        // Check now works also when the automatic check is off.
        result = await checker.check(force: true, manual: true)
        XCTAssertNotNil(result)
        XCTAssertEqual(off.calls, 1)
        XCTAssertEqual(checker.available?.version, "0.3.0")
    }

    func testAnUpToDateCheckClearsTheAvailableRelease() async {
        let github = FakeGitHub(status: 200, body: releasesJSON)
        let checker = UpdateChecker(repository: "o/r", currentVersion: "0.3.0", defaults: defaults(), fetch: github.fetch)
        _ = await checker.check(force: true)
        XCTAssertNil(checker.available)
    }

    func testNetworkErrorIsQuiet() async {
        struct Offline: Error {}
        let checker = UpdateChecker(repository: "o/r", currentVersion: "0.1.0", defaults: defaults(),
                                    fetch: { _ in throw Offline() })
        let result = await checker.check(force: true)
        XCTAssertNil(result)
    }
}
