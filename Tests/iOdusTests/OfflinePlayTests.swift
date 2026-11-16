import XCTest
@testable import iOdus

/// Offline play. All data here is synthetic, in the format of the backend
/// (`license_cache.rs`). No test contacts Microsoft.
final class OfflineLicenseTests: XCTestCase {
    static let day: TimeInterval = 86_400
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// A lease document as Microsoft issues it: base64 XML with a base64 JSON policy.
    static func lease(expires: Date, offline: Bool = true, expiration: String? = nil) -> String {
        let policy = #"{"isOffline":\#(offline),"expiresAt":"\#(rfc3339(expires))","leaseEnforcement":"EnforceConcurrency"}"#
        let date = expiration.map { "<ExpirationDate>\($0)</ExpirationDate>" } ?? ""
        let xml = """
        <License><SPLicenseBlock>synthetic-lease</SPLicenseBlock><LicenseInfo Type="Lease" LicenseUsage="Online">\(date)</LicenseInfo>\
        <CustomPolicies>\(Data(policy.utf8).base64EncodedString())</CustomPolicies>\
        <Binding Binding_Type="Machine"><DeviceId>synthetic-device</DeviceId><LeaseRequired>True</LeaseRequired></Binding></License>
        """
        return Data(xml.utf8).base64EncodedString()
    }

    static func entry(content: String = "content-a", issued: Date, lastUsed: Date? = nil, lease: String,
                      keyExpiration: String? = nil) -> Data {
        var validity: [String: Any] = [:]
        if let keyExpiration { validity["expirationDate"] = keyExpiration }
        let object: [String: Any] = [
            "schema": 4, "contentId": content, "puid": "synthetic", "deviceId": "puid:synthetic", "market": "US",
            "issuedAt": Int(issued.timeIntervalSince1970), "lastUsedAt": Int((lastUsed ?? issued).timeIntervalSince1970),
            "keyBinding": ["type": "Machine", "leaseRequired": "True"], "keyValidity": validity,
            "lease": lease, "splicenseBlock": "synthetic-block", "integrity": "synthetic-tag",
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testReadsTheExpiryOfAnOfflineLease() throws {
        let data = Self.entry(issued: now, lease: Self.lease(expires: now.addingTimeInterval(20 * Self.day)))
        let lease = try XCTUnwrap(OfflineLicenses.lease(fromEntry: data, now: now))
        XCTAssertEqual(lease.contentId, "content-a")
        XCTAssertEqual(lease.expires, now.addingTimeInterval(20 * Self.day))
        XCTAssertEqual(lease.daysLeft(now: now), 20)
        XCTAssertEqual(lease.daysLeft(now: now.addingTimeInterval(19.5 * Self.day)), 1, "A started day counts")
    }

    func testAppliesTheLimitsOfTheBackend() {
        let month = now.addingTimeInterval(30 * Self.day)
        // Never more than 30 days after the issue.
        let long = Self.entry(issued: now, lease: Self.lease(expires: now.addingTimeInterval(400 * Self.day)))
        XCTAssertEqual(OfflineLicenses.lease(fromEntry: long, now: now)?.expires, month)
        // The expiration date of the lease, in Microsoft's format without an offset.
        let short = Self.entry(issued: now, lease: Self.lease(expires: month, expiration: "2027-01-20T08:00:00.0000000"))
        XCTAssertEqual(OfflineLicenses.lease(fromEntry: short, now: now)?.expires,
                       OfflineLicenses.date("2027-01-20T08:00:00Z"))
        // The expiration date of the key (for example a trial).
        let trial = Self.entry(issued: now, lease: Self.lease(expires: month),
                               keyExpiration: Self.rfc3339(now.addingTimeInterval(Self.day)))
        XCTAssertEqual(OfflineLicenses.lease(fromEntry: trial, now: now)?.daysLeft(now: now), 1)
        // An expiration date that iOdus cannot read gives no lease, as in the backend.
        let unreadable = Self.entry(issued: now, lease: Self.lease(expires: month, expiration: "next week"))
        XCTAssertNil(OfflineLicenses.lease(fromEntry: unreadable, now: now))
    }

    func testRefusesLeasesThatTheBackendRefuses() {
        let month = now.addingTimeInterval(30 * Self.day)
        let valid = Self.entry(issued: now, lease: Self.lease(expires: month))
        XCTAssertNil(OfflineLicenses.lease(fromEntry: valid, now: month), "Expired")
        XCTAssertNil(OfflineLicenses.lease(fromEntry: Self.entry(issued: now, lease: Self.lease(expires: month, offline: false)),
                                           now: now), "Not an offline lease")
        // The clock is behind the last use.
        let used = Self.entry(issued: now, lastUsed: now.addingTimeInterval(2 * Self.day), lease: Self.lease(expires: month))
        XCTAssertNil(OfflineLicenses.lease(fromEntry: used, now: now.addingTimeInterval(Self.day)))
        XCTAssertNotNil(OfflineLicenses.lease(fromEntry: used, now: now.addingTimeInterval(2 * Self.day)))
        XCTAssertNil(OfflineLicenses.lease(fromEntry: Data("{}".utf8), now: now))
        XCTAssertNil(OfflineLicenses.lease(fromEntry: Self.entry(issued: now, lease: "not base64"), now: now))
    }

    func testReadsTheFolderOfTheBackend() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("iodus-lic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lease = Self.lease(expires: now.addingTimeInterval(30 * Self.day))
        try Self.entry(content: "aaaa-1111", issued: now, lease: lease).write(to: folder.appendingPathComponent("aaaa-1111.json"))
        try Self.entry(content: "bbbb-2222", issued: now.addingTimeInterval(-Self.day), lease: lease)
            .write(to: folder.appendingPathComponent("bbbb-2222.json"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("owner.holder"))

        XCTAssertNotNil(OfflineLicenses.lease(contentId: "AAAA-1111", in: folder, now: now), "The file name is lower case")
        XCTAssertNil(OfflineLicenses.lease(contentId: "cccc-3333", in: folder, now: now))
        XCTAssertNil(OfflineLicenses.lease(contentId: "../aaaa-1111", in: folder, now: now))
        XCTAssertNil(OfflineLicenses.lease(contentId: "", in: folder, now: now))
        XCTAssertEqual(OfflineLicenses.leases(in: folder, issuedSince: now.addingTimeInterval(-5), now: now).map(\.contentId),
                       ["aaaa-1111"])
        // A file under a different name gives no license for that name.
        try Self.entry(content: "aaaa-1111", issued: now, lease: lease).write(to: folder.appendingPathComponent("dddd-4444.json"))
        XCTAssertNil(OfflineLicenses.lease(contentId: "dddd-4444", in: folder, now: now))
        // The backend marks a revocation that did not complete.
        try Data().write(to: folder.appendingPathComponent(".revoked"))
        XCTAssertNil(OfflineLicenses.lease(contentId: "aaaa-1111", in: folder, now: now))
        XCTAssertTrue(OfflineLicenses.leases(in: folder, issuedSince: .distantPast, now: now).isEmpty)
    }

    func testReadsTheDatesOfMicrosoft() {
        let expected = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(OfflineLicenses.date("2027-01-15T08:00:00Z"), expected)
        XCTAssertEqual(OfflineLicenses.date("2027-01-15T08:00:00+00:00"), expected)
        XCTAssertEqual(OfflineLicenses.date("2027-01-15T08:00:00.0000000"), expected)
        XCTAssertEqual(OfflineLicenses.date("2027-01-15T08:00:00.0000000Z"), expected)
        XCTAssertEqual(OfflineLicenses.date("2027-01-15 08:00:00.123"), expected)
        XCTAssertNil(OfflineLicenses.date("01/15/2027"))
        XCTAssertNil(OfflineLicenses.date(""))
    }
}

final class OfflinePCTests: XCTestCase {
    func testReadsTheStatusOfTheBackend() throws {
        let line = #"{"schema":1,"enabled":false,"requestSuccess":false,"remainingToggles":2,"maxToggles":3,"periodDays":365,"nextChangeAt":null}"#
        let status = try XCTUnwrap(XodusCLI.offlinePCStatus(in: Data("note\n\(line)\n".utf8)))
        XCTAssertFalse(status.enabled)
        XCTAssertEqual(status.changesText, "Changes left: 2 of 3 in 365 days")
        XCTAssertNil(status.nextChange)
        // Microsoft gave no counts.
        let bare = try XCTUnwrap(XodusCLI.offlinePCStatus(in: Data(
            #"{"schema":1,"enabled":true,"requestSuccess":true,"remainingToggles":null,"maxToggles":null,"periodDays":null,"nextChangeAt":"2027-01-15T08:00:00+00:00"}"#.utf8)))
        XCTAssertTrue(bare.enabled)
        XCTAssertNil(bare.changesText)
        XCTAssertEqual(bare.nextChange, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(XodusCLI.offlinePCStatus(in: Data("no JSON".utf8)))
    }

    @MainActor
    func testTheSettingsRowAsksBeforeTheChange() {
        let model = AppModel()
        model.account = .ready
        XCTAssertEqual(SettingsCategory.account.rows, [.account, .offlinePC])
        XCTAssertEqual(model.offlinePCRow.action, "Check")

        model.offlinePC = .known(OfflinePCStatus(schema: 1, enabled: false, remainingToggles: 2, maxToggles: 3, periodDays: 365))
        XCTAssertEqual(model.offlinePCRow.action, "Make offline PC")
        model.offlinePCAction()
        XCTAssertEqual(model.installPrompt?.stage, .offlinePC(changes: "Changes left: 2 of 3 in 365 days"))
        XCTAssertEqual(model.installPrompt?.focus, 1, "Cancel is the default")
        model.confirm()
        XCTAssertNil(model.installPrompt)
        XCTAssertEqual(model.offlinePC, .known(OfflinePCStatus(schema: 1, enabled: false, remainingToggles: 2, maxToggles: 3,
                                                               periodDays: 365)), "Cancel changes nothing")

        // No change left: no dialog.
        model.offlinePC = .known(OfflinePCStatus(schema: 1, enabled: false, remainingToggles: 0))
        model.offlinePCAction()
        XCTAssertNil(model.installPrompt)

        model.offlinePC = .known(OfflinePCStatus(schema: 1, enabled: true, remainingToggles: 1))
        XCTAssertEqual(model.offlinePCRow.action, "Check again")
        model.offlinePCAction()
        XCTAssertNil(model.installPrompt, "The offline PC gets no dialog")

        // Without internet, the row has no action, and A does not open the dialog.
        model.network.kind = .offline
        XCTAssertNil(model.offlinePCRow.action)
        model.offlinePC = .known(OfflinePCStatus(schema: 1, enabled: false, remainingToggles: 2))
        model.offlinePCAction()
        XCTAssertNil(model.installPrompt)
    }
}

final class OfflineStartTests: XCTestCase {
    func testTheBackendGetsTheLicenseFolderAtEachStart() {
        let folder = URL(fileURLWithPath: "/Games/DREDGE"), licenses = URL(fileURLWithPath: "/Support/Licenses")
        XCTAssertEqual(
            GameLauncher.runArguments(folder: folder, wine: "/r/wine64", exe: "DREDGE.exe", market: "US",
                                      licenses: licenses, offline: false, gameArguments: []),
            ["run", "/Games/DREDGE", "/r/wine64", "--exe", "DREDGE.exe", "--materialize-chain", "--market", "US",
             "--license-cache", "/Support/Licenses"])
        XCTAssertEqual(
            GameLauncher.runArguments(folder: folder, wine: "/r/wine64", exe: "DREDGE.exe", market: "US",
                                      licenses: licenses, offline: true, gameArguments: ["-window-mode", "borderless"])
                .suffix(6),
            ["--license-cache", "/Support/Licenses", "--offline", "--", "-window-mode", "borderless"])
    }

    @MainActor
    func testAGameStartsOfflineOnlyWithALease() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("iodus-off-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "iodus-offline-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        }
        let model = AppModel()
        model.licenseFolder = folder
        model.offlineDefaults = defaults
        XCTAssertEqual(model.launcher.licenseFolder, folder)
        let game = Game(id: "9P0000000001", title: "Harbor Lights", publisher: "Northwind Studio")

        XCTAssertNil(model.offlineLease(for: game))
        XCTAssertTrue(try XCTUnwrap(model.offlineStartProblem(for: game, saveSync: nil)).contains("no valid offline license"))

        // The backend stored a license at the start of the game.
        let started = Date()
        let lease = OfflineLicenseTests.lease(expires: started.addingTimeInterval(30 * 86_400))
        try OfflineLicenseTests.entry(content: "aaaa-1111", issued: started, lease: lease)
            .write(to: folder.appendingPathComponent("aaaa-1111.json"))
        model.learnOfflineLicense(gameID: game.id, startedAt: started)
        XCTAssertEqual(model.offlineLease(for: game)?.contentId, "aaaa-1111")
        XCTAssertNil(model.offlineStartProblem(for: game, saveSync: nil))
        XCTAssertNotNil(model.offlineStartProblem(for: game, saveSync: .download), "A save sync needs the internet")

        // Two new licenses: iOdus cannot know which one is of this game.
        let other = Game(id: "9P0000000002", title: "Iron Meridian", publisher: "Forge Nine")
        try OfflineLicenseTests.entry(content: "bbbb-2222", issued: started, lease: lease)
            .write(to: folder.appendingPathComponent("bbbb-2222.json"))
        model.learnOfflineLicense(gameID: other.id, startedAt: started)
        XCTAssertNil(model.offlineLease(for: other))

        // The backend removed the license (for example, a different offline PC).
        try FileManager.default.removeItem(at: folder.appendingPathComponent("aaaa-1111.json"))
        XCTAssertNil(model.offlineLease(for: game))
    }
}

final class LibraryCacheTests: XCTestCase {
    @MainActor
    func testTheLibraryOfTheLastOnlineSessionLoadsWithoutInternet() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("iodus-lib-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let played = Date(timeIntervalSince1970: 1_800_000_000)
        let games = [
            Game(id: "9P0000000001", title: "Harbor Lights", publisher: "Northwind Studio",
                 tileArt: URL(string: "https://example.com/a.png"), access: .gamePass, installState: .installed,
                 titleId: "123", lastPlayed: played),
            Game(id: "9P0000000002", title: "Iron Meridian", publisher: "Forge Nine", launcher: "Ubisoft Connect"),
        ]
        LibraryCache(account: "Player@Example.com", games: games).save(to: file)

        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.lowercased().contains("player@example.com"), "The file does not name the account")
        XCTAssertNil(LibraryCache.load(account: "other@example.com", from: file))

        let model = AppModel()
        model.libraryCacheFile = file
        model.accountName = "player@example.com"
        XCTAssertTrue(model.useStoredLibrary())
        XCTAssertEqual(model.account, .ready)
        XCTAssertTrue(model.libraryFromCache)
        let first = try XCTUnwrap(model.game("9P0000000001"))
        XCTAssertEqual(first.title, "Harbor Lights")
        XCTAssertEqual(first.access, .gamePass)
        XCTAssertEqual(first.titleId, "123")
        XCTAssertEqual(first.tileArt, URL(string: "https://example.com/a.png"))
        XCTAssertEqual(first.installState, .notInstalled, "The install state comes from this Mac, not from the file")
        XCTAssertEqual(model.game("9P0000000002")?.launcher, "Ubisoft Connect")

        model.accountName = "other@example.com"
        model.account = .failed("offline")
        XCTAssertFalse(model.useStoredLibrary())
        XCTAssertEqual(model.account, .failed("offline"))
    }
}

final class OfflineIdentityTests: XCTestCase {
    func testTheRuntimeGetsTheAccountKeyAndTheOfflineMark() {
        let key = LibraryCache.key("player@example.com")
        XCTAssertEqual(key.count, 16)
        XCTAssertTrue(key.allSatisfy { "0123456789abcdef".contains($0) }, "The runtime accepts lower-case hex only")
        XCTAssertEqual(key, LibraryCache.key("Player@Example.com"))
        XCTAssertEqual(LibraryCache.key("").count, 16)
        XCTAssertEqual(GameLauncher.offlineEnvironment(accountKey: key, offline: false), ["XODUS_ACCOUNT_HASH": key])
        XCTAssertEqual(GameLauncher.offlineEnvironment(accountKey: key, offline: true),
                       ["XODUS_ACCOUNT_HASH": key, "XODUS_FORCE_OFFLINE": "1"])
        XCTAssertEqual(GameLauncher.offlineEnvironment(accountKey: nil, offline: false), [:])
        // The Xbox service of an offline start has an old device token.
        XCTAssertTrue(GameLauncher.canReuseService(startedOffline: false, offline: false))
        XCTAssertTrue(GameLauncher.canReuseService(startedOffline: false, offline: true))
        XCTAssertTrue(GameLauncher.canReuseService(startedOffline: true, offline: true))
        XCTAssertFalse(GameLauncher.canReuseService(startedOffline: true, offline: false))
    }

    func testRemovesTheStoredIdentitiesOfAPrefix() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("iodus-prefix-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: prefix) }
        let local = prefix.appendingPathComponent("drive_c/users/crossover/AppData/Local")
        let identity = local.appendingPathComponent("iOdus/offline-identity/0123456789abcdef")
        try FileManager.default.createDirectory(at: identity, withIntermediateDirectories: true)
        try Data("schema=1\n".utf8).write(to: identity.appendingPathComponent("identity.txt"))
        let other = local.appendingPathComponent("Game/save.dat")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("save".utf8).write(to: other)

        XCTAssertEqual(OfflineIdentities.folders(prefix: prefix).count, 1)
        OfflineIdentities.remove(prefixes: [prefix, prefix])
        XCTAssertFalse(FileManager.default.fileExists(atPath: identity.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "Only the identity folder goes")
        XCTAssertTrue(OfflineIdentities.folders(prefix: prefix).isEmpty)
    }
}
