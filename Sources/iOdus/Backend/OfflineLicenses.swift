import Foundation

/// The offline PC setting of the Microsoft account ("Offline permissions" in
/// the Xbox app), as `xodus-cli offline-pc` prints it (schema 1).
struct OfflinePCStatus: Decodable, Equatable {
    let schema: Int
    let enabled: Bool
    var requestSuccess: Bool = false
    var remainingToggles: Int? = nil
    var maxToggles: Int? = nil
    var periodDays: Int? = nil
    var nextChangeAt: String? = nil

    /// "Changes left: 2 of 3 in 365 days", or nil when Microsoft gave no count.
    var changesText: String? {
        guard let remainingToggles else { return nil }
        var text = "Changes left: \(remainingToggles)"
        if let maxToggles { text += " of \(maxToggles)" }
        if let periodDays { text += " in \(periodDays) days" }
        return text
    }

    /// The date of the next possible change, when no change is left.
    var nextChange: Date? { nextChangeAt.flatMap(OfflineLicenses.date) }
}

extension XodusCLI {
    /// Reads the offline PC setting. With the license folder, the backend
    /// removes the stored licenses when this Mac is not the offline PC.
    func offlinePC(licenses: URL) async throws -> OfflinePCStatus {
        let result = try await run(["offline-pc", "--license-cache", licenses.path], timeout: 90)
        if result.timedOut { throw BackendError.failed("The backend did not answer in time.") }
        if result.status == 0, let status = Self.offlinePCStatus(in: result.stdout) { return status }
        Self.logOfflinePCFailure(result)
        throw BackendError.failed(Self.message(from: result.stderr))
    }

    /// ~/Library/Logs/iOdus/Offline PC.log: the backend output of the last
    /// failed request, to find the cause. The backend prints no tokens.
    static func logOfflinePCFailure(_ result: CLIResult) {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/iOdus", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = "\(Date().formatted(.iso8601)) exit \(result.status)\n\(result.stderr)\n"
        try? Data(text.utf8).write(to: folder.appendingPathComponent("Offline PC.log"))
    }

    /// Makes this Mac the offline PC of the account. This changes a setting on
    /// the Microsoft account: call it only after the player confirmed.
    /// A refusal from Microsoft comes back as a status with `requestSuccess` false.
    func makeOfflinePC(licenses: URL) async throws -> OfflinePCStatus {
        let result = try await run(["offline-pc", "--set", "true", "--confirm", "--license-cache", licenses.path],
                                   timeout: 90)
        if result.timedOut { throw BackendError.failed("The backend did not answer in time.") }
        if let status = Self.offlinePCStatus(in: result.stdout) { return status }
        Self.logOfflinePCFailure(result)
        throw BackendError.failed(Self.message(from: result.stderr))
    }

    /// The last JSON line of the output of `offline-pc`.
    static func offlinePCStatus(in stdout: Data) -> OfflinePCStatus? {
        String(decoding: stdout, as: UTF8.self).split(separator: "\n")
            .last { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
            .flatMap { try? JSONDecoder().decode(OfflinePCStatus.self, from: Data($0.utf8)) }
    }
}

/// The offline license of one game: Microsoft's lease, stored by the backend.
struct OfflineLease: Equatable {
    let contentId: String
    let issued: Date
    let expires: Date

    /// Full or started days until the lease ends, as the backend counts them.
    func daysLeft(now: Date = Date()) -> Int {
        max(0, Int((expires.timeIntervalSince(now) / 86_400).rounded(.up)))
    }

    var text: String {
        let days = daysLeft()
        return days == 1 ? "Offline play: 1 day left" : "Offline play: \(days) days left"
    }
}

/// Reads the offline licenses that `xodus-cli run --license-cache` stores.
/// iOdus only shows them and decides whether an offline start can work. The
/// backend checks each license again at the start, with the device key from
/// the Keychain, so a changed file gives no access.
enum OfflineLicenses {
    /// The folder that the backend gets at each game start.
    static var folder: URL { GameRuntime.support.appendingPathComponent("Licenses", isDirectory: true) }

    /// The backend limits: 30 days after the issue, and 10 minutes of clock change.
    static let window: TimeInterval = 30 * 24 * 60 * 60
    static let clockSkew: TimeInterval = 10 * 60
    private static let schema = 4
    private static let maxBytes = 160 * 1024

    /// The valid lease for a content ID, or nil.
    static func lease(contentId: String, in folder: URL = folder, now: Date = Date()) -> OfflineLease? {
        let id = contentId.lowercased()
        guard !id.isEmpty, id.count <= 64, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              !FileManager.default.fileExists(atPath: folder.appendingPathComponent(".revoked").path),
              let lease = read(folder.appendingPathComponent("\(id).json"), now: now), lease.contentId == id
        else { return nil }
        return lease
    }

    /// All valid leases in the folder that Microsoft issued at or after `date`.
    static func leases(in folder: URL = folder, issuedSince date: Date, now: Date = Date()) -> [OfflineLease] {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.appendingPathComponent(".revoked").path),
              let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { read(folder.appendingPathComponent($0), now: now) }
            .filter { $0.issued >= date }
    }

    private static func read(_ file: URL, now: Date) -> OfflineLease? {
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxBytes,
              let data = try? Data(contentsOf: file) else { return nil }
        return lease(fromEntry: data, now: now)
    }

    /// Applies the same limits as the backend (`check_lease`): an offline lease,
    /// its expiry, the expiration dates of the lease and the key, the 30-day
    /// window, and a clock that is not behind the last use.
    static func lease(fromEntry data: Data, now: Date = Date()) -> OfflineLease? {
        guard let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              entry["schema"] as? Int == schema,
              let contentId = entry["contentId"] as? String,
              let issuedAt = (entry["issuedAt"] as? NSNumber)?.doubleValue,
              let lastUsedAt = (entry["lastUsedAt"] as? NSNumber)?.doubleValue,
              let document = entry["lease"] as? String,
              let xml = Data(base64Encoded: document).map({ String(decoding: $0, as: UTF8.self) }),
              let policyText = tag("CustomPolicies", in: xml), let policyData = Data(base64Encoded: policyText),
              let policy = try? JSONSerialization.jsonObject(with: policyData) as? [String: Any],
              policy["isOffline"] as? Bool == true,
              let expiresAt = (policy["expiresAt"] as? String).flatMap(date)
        else { return nil }
        if now.timeIntervalSince1970 + clockSkew < max(issuedAt, lastUsedAt) { return nil }
        var until = expiresAt
        let keyExpiration = (entry["keyValidity"] as? [String: Any])?["expirationDate"] as? String
        for text in [tag("ExpirationDate", in: xml), keyExpiration].compactMap({ $0 }) {
            guard let limit = date(text) else { return nil }
            until = min(until, limit)
        }
        let issued = Date(timeIntervalSince1970: issuedAt)
        until = min(until, issued.addingTimeInterval(window))
        guard until > now else { return nil }
        return OfflineLease(contentId: contentId.lowercased(), issued: issued, expires: until)
    }

    /// The text of the first `<name>…</name>` element.
    private static func tag(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)>"),
              let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex) else { return nil }
        return String(xml[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Microsoft writes RFC 3339 in the policy, and a UTC time without an
    /// offset (seven fraction digits) in the license.
    static func date(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            iso.formatOptions = options
            if let date = iso.date(from: text) { return date }
        }
        // No offset, or more fraction digits than the ISO parser accepts: read the seconds as UTC.
        guard text.count >= 19 else { return nil }
        let plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.timeZone = TimeZone(identifier: "UTC")
        plain.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let seconds = String(text.prefix(19)).replacingOccurrences(of: " ", with: "T")
        let rest = text.dropFirst(19)
        // After the seconds: only a fraction, then nothing or "Z".
        guard rest.allSatisfy({ $0.isNumber || $0 == "." || $0 == "Z" }) else { return nil }
        return plain.date(from: seconds)
    }
}

/// The library of the last online session, for a start without internet.
/// The file has the same public catalog data as the library page. It has no
/// tokens and no account name: the account is stored as a hash.
struct LibraryCache: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let id: String
        let title: String
        let publisher: String
        var tileArt: URL?
        var heroArt: URL?
        let access: String
        var titleId: String?
        var lastPlayed: Date?
        var launcher: String?
    }

    let account: String
    let savedAt: Date
    let games: [Entry]

    static var file: URL { GameRuntime.support.appendingPathComponent("library.json") }

    init(account: String, games: [Game], savedAt: Date = Date()) {
        self.account = Self.key(account)
        self.savedAt = savedAt
        self.games = games.map {
            Entry(id: $0.id, title: $0.title, publisher: $0.publisher, tileArt: $0.tileArt, heroArt: $0.heroArt,
                  access: $0.access.rawValue, titleId: $0.titleId, lastPlayed: $0.lastPlayed, launcher: $0.launcher)
        }
    }

    /// The games, with the install state from `state`.
    func restored(installState state: (String) -> InstallState) -> [Game] {
        games.map {
            Game(id: $0.id, title: $0.title, publisher: $0.publisher, tileArt: $0.tileArt, heroArt: $0.heroArt,
                 access: Access(rawValue: $0.access) ?? .other, installState: state($0.id), titleId: $0.titleId,
                 lastPlayed: $0.lastPlayed, launcher: $0.launcher)
        }
    }

    func save(to file: URL = file) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// The stored library of this account, or nil.
    static func load(account: String, from file: URL = file) -> LibraryCache? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: file),
              let cache = try? decoder.decode(LibraryCache.self, from: data),
              cache.account == key(account), !cache.games.isEmpty else { return nil }
        return cache
    }

    static func remove(_ file: URL = file) {
        try? FileManager.default.removeItem(at: file)
    }

    /// A stable hash of the account name (FNV-1a), so that the file does not name the account.
    static func key(_ account: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in account.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let text = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - text.count) + text
    }
}

/// The offline identity that the Xbox runtime stores in a Wine prefix
/// (`%LOCALAPPDATA%\iOdus\offline-identity`): the XUID and the gamertags of
/// the last online sign-in, without tokens. The runtime uses it only when the
/// backend started the game on a valid offline license.
enum OfflineIdentities {
    /// The identity folders in a prefix, one for each Windows user folder.
    static func folders(prefix: URL) -> [URL] {
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? []
        return names.map { users.appendingPathComponent("\($0)/AppData/Local/iOdus/offline-identity", isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Removes the stored identities of all accounts from the prefixes: after
    /// a sign-out, and after a change of the offline PC.
    static func remove(prefixes: [URL]) {
        for folder in Set(prefixes).flatMap(folders) { try? FileManager.default.removeItem(at: folder) }
    }
}
