import Foundation

/// What iOdus knows about the offline PC setting of the account.
enum OfflinePCState: Equatable {
    case unknown
    case loading
    case known(OfflinePCStatus)
    case changing
    case failed(String)
}

/// Offline play: the offline PC setting, the offline licenses of the games,
/// and the library from the last online session.
extension AppModel {
    static let learnedContentKey = "offlineContentIDs"

    // MARK: - Offline licenses

    /// The valid offline license of a game, or nil. For the game page and for
    /// the decision to start a game without internet.
    func offlineLease(for game: Game) -> OfflineLease? {
        guard !demo else { return nil }
        let learned = (offlineDefaults.dictionary(forKey: Self.learnedContentKey) as? [String: String])?[game.id]
        let ids = [learned, downloads.installs[game.id]?.contentId].compactMap { $0 }.filter { !$0.isEmpty }
        for id in ids {
            if let lease = OfflineLicenses.lease(contentId: id, in: licenseFolder) { return lease }
        }
        return nil
    }

    /// After a game ended: find the license that Microsoft issued at its start,
    /// and remember its content ID for the game. The install record does not
    /// always have the content ID (a rescan cannot read it).
    func learnOfflineLicense(gameID: String, startedAt: Date) {
        // The backend writes the license some seconds after the start: allow a small clock difference.
        let leases = OfflineLicenses.leases(in: licenseFolder, issuedSince: startedAt.addingTimeInterval(-5))
        guard leases.count == 1, let lease = leases.first else { return }
        var learned = offlineDefaults.dictionary(forKey: Self.learnedContentKey) as? [String: String] ?? [:]
        guard learned[gameID] != lease.contentId else { return }
        learned[gameID] = lease.contentId
        offlineDefaults.set(learned, forKey: Self.learnedContentKey)
        objectWillChange.send()
    }

    /// The reason why a game cannot start without internet, or nil when it can.
    func offlineStartProblem(for game: Game, saveSync: SaveSync?) -> String? {
        if saveSync != nil {
            return "You are offline. iOdus cannot download or upload a save without internet."
        }
        if offlineLease(for: game) == nil {
            return "You are offline, and \(game.title) has no valid offline license. Start it one time online on the offline PC of the account."
        }
        return nil
    }

    // MARK: - Offline PC setting

    /// Reads the setting from Microsoft. This is a read request only.
    func loadOfflinePC(force: Bool = false) async {
        guard !demo, let cli = backendCLI, network.online else { return }
        switch offlinePC {
        case .loading, .changing: return
        case .known where !force: return
        default: break
        }
        offlinePC = .loading
        do {
            let status = try await cli.offlinePC(licenses: licenseFolder)
            offlinePC = .known(status)
            // Not the offline PC: the backend removed the licenses, and the identities go too.
            if !status.enabled { OfflineIdentities.remove(prefixes: runtimes.map(\.prefix)) }
        } catch {
            offlinePC = .failed(error.localizedDescription)
        }
    }

    /// Settings, A on the offline PC row.
    func offlinePCAction() {
        guard !demo else { return showToast("Demo mode cannot change the offline PC.") }
        guard network.online else { return showToast("The offline PC setting needs the internet.") }
        switch offlinePC {
        case .loading, .changing:
            break
        case .unknown, .failed:
            Task { await loadOfflinePC(force: true) }
        case .known(let status) where status.enabled:
            Task { await loadOfflinePC(force: true) }
        case .known(let status):
            if status.remainingToggles == 0 {
                let when = status.nextChange.map { " The next change is possible on \($0.formatted(date: .abbreviated, time: .omitted))." } ?? ""
                showToast("Microsoft allows no more changes of the offline PC now.\(when)", seconds: 7)
                return
            }
            var prompt = InstallPrompt(game: Game(id: "", title: "Offline PC", publisher: ""))
            prompt.stage = .offlinePC(changes: status.changesText)
            prompt.focus = 1    // Cancel is the default: the change is on the Microsoft account
            installPrompt = prompt
        }
    }

    /// After the player confirmed: make this Mac the offline PC.
    func makeOfflinePC() {
        guard !demo, let cli = backendCLI, offlinePC != .changing else { return }
        offlinePC = .changing
        Task {
            do {
                var status = try await cli.makeOfflinePC(licenses: licenseFolder)
                // The answer to the change is not always the new state (seen: Microsoft
                // made the change, and the answer did not show it). Read the setting again.
                if !(status.enabled && status.requestSuccess),
                   let read = try? await cli.offlinePC(licenses: licenseFolder) {
                    status = read
                }
                offlinePC = .known(status)
                // Each change of the offline PC starts again: the next online start stores a new identity.
                OfflineIdentities.remove(prefixes: runtimes.map(\.prefix))
                if status.enabled {
                    showToast("This Mac is the offline PC now. Start each game one time online to get its offline license.", seconds: 8)
                } else {
                    showToast("Microsoft did not make this Mac the offline PC.", seconds: 6)
                }
            } catch {
                offlinePC = .failed(error.localizedDescription)
                showToast(error.localizedDescription, seconds: 6)
            }
        }
    }

    /// The Settings row: the symbol, the detail lines, and the action.
    var offlinePCRow: (symbol: String, lines: [String], action: String?) {
        if !network.online {
            if case .known(let status) = offlinePC, status.enabled {
                return ("checkmark.circle", ["This Mac is the offline PC of the account."], nil)
            }
            return ("wifi.slash", ["iOdus reads this setting when the Mac is online."], nil)
        }
        switch offlinePC {
        case .unknown:
            return ("wifi.slash", ["Shows whether this Mac can start games without internet."], "Check")
        case .loading:
            return ("wifi.slash", ["Reading the setting from Microsoft…"], nil)
        case .changing:
            return ("wifi.slash", ["Changing the setting at Microsoft…"], nil)
        case .failed(let message):
            return ("exclamationmark.triangle", [message], "Try again")
        case .known(let status):
            let changes = status.changesText.map { [$0] } ?? []
            if status.enabled {
                return ("checkmark.circle",
                        ["This Mac is the offline PC. Each online game start gives 30 days of offline play."] + changes,
                        "Check again")
            }
            return ("wifi.slash", ["This Mac is not the offline PC. Games need the internet to start."] + changes,
                    "Make offline PC")
        }
    }

    // MARK: - Library without internet

    /// Shows the library of the last online session. Returns false when no
    /// stored library fits the account.
    func useStoredLibrary() -> Bool {
        guard let cache = LibraryCache.load(account: accountName, from: libraryCacheFile) else { return false }
        games = playHistory.merged(into: cache.restored { self.downloads.installState(for: $0) })
        homeIndex = [0, 0]
        libraryIndex = 0
        libraryFromCache = true
        account = .ready
        showToast("iOdus cannot reach Xbox Live. The library is from \(cache.savedAt.formatted(date: .abbreviated, time: .omitted)).",
                  seconds: 6)
        return true
    }

    /// Called when the network or Xbox Live is back, and after a game ended:
    /// load the account again when the library is the stored one.
    func reloadAfterReconnect() {
        guard libraryFromCache, account == .ready, playState == .idle, uploadingSaves == nil,
              network.online, network.xboxLive == .reachable else { return }
        libraryFromCache = false
        Task { await retry() }
    }
}
