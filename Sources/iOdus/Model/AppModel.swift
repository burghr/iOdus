import AppKit
import SwiftUI

enum Screen: Hashable {
    case home
    case library
    case downloads
    case settings
    case friends
    case store
    case storeItem(String)
    case achievements(String)       // Xbox title ID
    case messages
    case conversation(String)       // XUID of the friend
    case achievementHub
    case detail(Game.ID)
    case saveBackups(Game.ID)
    case runtimes(Game.ID?)         // nil: the default runtime (Settings)
    case gameSettings(Game.ID)      // The runtime, Retina mode, and overlay of one game
}

enum Direction {
    case up, down, left, right
}

/// The state of the Microsoft account and the library.
enum AccountState: Equatable {
    case checking
    case signedOut
    case signingIn
    case loading
    case ready
    case failed(String)
}

enum LoadState: Equatable {
    case idle, loading, ready
    case failed(String)
}

enum StoreFocus {
    case search, rows, results
}

enum LibraryFocus {
    case grid, filters, search
}

enum LibraryFilter: String, CaseIterable {
    case all = "All games"
    case owned = "Owned"
    case gamePass = "Game Pass"
    case installed = "Installed"
}

/// The dialog before a download starts.
struct InstallPrompt: Equatable {
    enum Stage: Equatable {
        case loading
        case ready(InstallChoice)
        case failed(String)
        case saveConflict(local: Date?, cloud: Date?)   // Not an install: choose a save before Play
        case restoreBackup(SaveBackup)                  // 0 = Restore, 1 = Cancel
        case deleteBackup(SaveBackup)                   // 0 = Delete, 1 = Cancel
        case uninstall(path: String, bytes: Int64?)     // 0 = Uninstall, 1 = Cancel
    }

    /// 0 = Install, 1 = Cancel; for a save conflict 0 = cloud, 1 = Mac, 2 = Cancel.
    var buttonCount: Int {
        if case .saveConflict = stage { return 3 }
        if case .failed = stage { return 1 }     // 0 = Close
        return 2
    }

    let game: Game
    var stage: Stage = .loading
    var focus = 0           // 0 = Install, 1 = Cancel
    var destination = ""
    var freeBytes: Int64?
}

/// The navigation state. The keyboard, the mouse, and the controller all call
/// `move`, `confirm`, `back`, and `xPressed`, so that the inputs act the same.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var games: [Game] = []
    @Published var stack: [Screen] = [.home]
    @Published var account: AccountState = .checking
    @Published var gamertag = ""
    @Published var gamerpic: NSImage?
    @Published var accountName = ""
    @Published var gamerscore: Int?
    @Published var controllers: [ControllerStatus] = []
    @Published var statusPanel: StatusPanel?
    @Published var network = NetworkStatus()
    var notificationStore = NotificationStore()
    @Published var notifications: [AppNotification] = []
    @Published var notificationIndex = 0
    /// The title history entry of a game at its start, to find new achievements at its end.
    var playBaseline: [String: PlayedTitle] = [:]
    /// Watches the achievements of the running game (popups).
    var achievementWatcher: AchievementWatcher?
    /// The product ID of a game whose saves upload after it ended.
    @Published var uploadingSaves: String?
    /// True while Microsoft's Visual C++ runtime installs in the prefix.
    @Published var installingVCRuntime = false
    /// The installed runtimes (GPTK first) and the choices of the player.
    @Published var runtimes: [GameRuntime] = RuntimeCatalog.discover()
    var runtimeChoice = RuntimeChoice(defaults: .standard)
    var gameOptions = GameOptionsStore(defaults: .standard)
    @Published var runtimeIndex = 0         // -1: the technology box at the top of the runtimes page
    @Published var runtimeFamily: RuntimeFamily = .d3dmetal  // The technology the runtimes page shows
    /// The runtime download that runs now, and the downloads that iOdus offers.
    @Published var runtimeDownload: RuntimeDownloadState?
    var runtimeDownloadCatalog: [RuntimeDownload] = RuntimeDownload.catalog

    // Friends
    @Published var friends: [Friend] = []
    @Published var friendsState: LoadState = .idle
    @Published var friendIndex = 0
    @Published var friendCard: FriendCard?
    var friendsLoadedAt: Date?

    // Messages
    @Published var inbox: [InboxItem] = []
    @Published var inboxState: LoadState = .idle
    @Published var messageIndex = 0
    @Published var conversations: [String: [ChatMessage]] = [:]
    @Published var conversationState: LoadState = .idle
    @Published var chatDraft = ""
    @Published var sendingMessage = false
    @Published var playerProfiles: [String: PlayerProfile] = [:]
    var seenMessages = SeenMessages()
    var socialChannel: SocialChannel?
    var inboxTimer: Timer?
    var conversationTimer: Timer?
    var inboxChecked = false

    // Achievements, by Xbox title ID
    @Published var achievementLists: [String: AchievementList] = [:]
    @Published var achievementState: LoadState = .idle
    @Published var achievementIndex = 0
    @Published var showSecrets = false
    /// Name and art for each achievement page, by title ID.
    var achievementTitles: [String: AchievementTitle] = [:]
    // The title history: recent games with achievement counts, newest first.
    @Published var titleHistory: [PlayedTitle] = []
    @Published var historyState: LoadState = .idle
    @Published var hubIndex = 0
    var historyLoadedAt: Date?

    // Store
    @Published var storeRows: [StoreRow] = []
    @Published var storeState: LoadState = .idle
    @Published var storeFocus: StoreFocus = .rows
    @Published var storeRow = 0
    @Published var storeIndex: [Int] = []
    @Published var storeSearch = ""
    @Published var storeResults: [StoreItem] = []
    @Published var storeSearchState: LoadState = .idle
    @Published var storeResultIndex = 0
    @Published var storeItemIndex = 0
    var storeItems: [String: StoreItem] = [:]
    var storeLoadedAt: Date?
    var storeSearchTask: Task<Void, Never>?
    @Published var backendInfo: BackendInfo?
    @Published var exportingLogs = false
    @Published var installPrompt: InstallPrompt?
    /// The setup after the sign-in (Rosetta and the game runtime), or nil.
    @Published var setup: SetupFlow?
    var setupTask: Task<Void, Never>?
    /// Tests put the runtime into a temporary folder.
    var setupRootOverride: URL?
    @Published var toast: String?
    @Published private(set) var downloadTasks: [DownloadTask] = []
    @Published private(set) var playState: PlayState = .idle

    // Home: row 0 = recent games (plus a "My games & apps" tile), row 1 = shortcuts.
    @Published var homeRow = 0
    @Published var homeIndex = [0, 0]
    @Published var libraryIndex = 0
    @Published var libraryFilter: LibraryFilter = .all
    /// Where the focus is in the library: the grid, the filter list, or the search box.
    @Published var libraryFocus: LibraryFocus = .grid
    @Published var librarySearch = ""
    @Published var detailIndex = 0
    @Published var saveBackupList: [SaveBackup] = []
    @Published var backupIndex = 0
    /// The save locations. Tests set them to temporary folders.
    var saveBackupRoot = SaveBackups.standardRoot
    var savePrefixOverride: URL?
    /// The open cloud stream, or nil.
    @Published var stream: StreamSession?
    /// Product IDs (upper case) that the web player can stream.
    @Published var cloudProducts: Set<String> = []
    /// Games that stream through an edition: product ID -> cloud product ID.
    @Published var cloudEditions: [String: String] = [:]
    /// Product IDs that were checked for a cloud edition in this session.
    var cloudEditionChecked: Set<String> = []
    /// The web view of the open stream. Not in demo mode or snapshots.
    var streamWeb: StreamWebController?
    @Published var downloadIndex = 0
    /// Settings: the category list on the left, the rows of one category on the right.
    @Published var settingsCategory = 0
    @Published var settingsFocus: SettingsFocus = .categories
    @Published var settingsIndex = 0          // The row in the current category
    @Published var gameSettingsIndex = 0
    let updateChecker = UpdateChecker()
    @Published var appUpdate: AppUpdateState = .idle
    var updateTimer: Timer?

    let shortcuts = Shortcut.all
    let libraryColumns = 6
    let recentCount = 8
    let market = Locale.current.region?.identifier.uppercased() ?? "US"
    let downloads = DownloadManager()
    let launcher = GameLauncher()
    var playHistory = PlayHistory()

    private var cli: XodusCLI?
    var backendCLI: XodusCLI? { cli }
    private(set) var demo = false
    private var toastTask: Task<Void, Never>?

    init() {
        downloads.market = market
        downloads.onChange = { [weak self] in self?.syncDownloads() }
        downloadTasks = downloads.tasks
        launcher.market = market
        launcher.onChange = { [weak self] in self?.syncPlayState() }
        launcher.onFinish = { [weak self] id, error in
            guard let self else { return }
            if let error { self.showToast(error, seconds: 10) }
            let before = self.playBaseline.removeValue(forKey: id)
            let watcher = self.achievementWatcher
            self.achievementWatcher = nil
            Task {
                await self.uploadSavesAfterGame(id)
                await watcher?.stop()
                await self.checkNewAchievements(gameID: id, before: before, announced: watcher?.announced.count ?? 0)
            }
        }
        downloads.onFinished = { [weak self] task in self?.downloadFinished(task) }
        notifications = notificationStore.items
    }

    var screen: Screen { stack.last ?? .home }

    /// True when B / Back does something: a dialog, a card, a search text, or a screen to leave.
    var canGoBack: Bool {
        guard account == .ready else { return false }
        return stack.count > 1 || installPrompt != nil || friendCard != nil || statusPanel != nil
    }

    private var unityCache: [String: Bool] = [:]
    private var stubCache: [String: GameStub?] = [:]

    /// Installed Unity games get a hint about the full-screen mode on their page.
    /// The cloud save state of a game; nil without a title ID.
    func cloudSaveStatus(for game: Game) -> CloudSaveStatus? {
        if demo {
            if game.id == games.first?.id { return .synced(Date().addingTimeInterval(-3600)) }
            if game.id == games.dropFirst().first?.id {
                return .conflict(local: Date().addingTimeInterval(-7200), cloud: Date().addingTimeInterval(-86400))
            }
            return .noSaves
        }
        guard let titleId = game.titleId else { return nil }
        return CloudSaveStatus.read(titleId: titleId, prefix: savePrefix(for: game))
    }

    /// The stub of a launcher game (GameStub), for an installed game, or nil.
    func gameStub(_ game: Game) -> GameStub? {
        guard let path = downloads.installs[game.id]?.path else { return nil }
        if let known = stubCache[path] { return known }
        let stub = GameStub.detect(in: URL(fileURLWithPath: path))
        stubCache[path] = .some(stub)
        return stub
    }

    func isUnityGame(_ game: Game) -> Bool {
        guard let path = downloads.installs[game.id]?.path else { return false }
        if let known = unityCache[path] { return known }
        let unity = UnityGame.detect(in: URL(fileURLWithPath: path)) != nil
        unityCache[path] = unity
        return unity
    }

    /// The home row, like on the Xbox: downloads first, then the games that the
    /// account played last, then installed games, then the rest by name.
    var recent: [Game] {
        Array(Self.recentOrder(games).prefix(recentCount))
    }

    nonisolated static func recentOrder(_ games: [Game]) -> [Game] {
        func rank(_ g: Game) -> Int {
            if case .downloading = g.installState { return 0 }
            if g.lastPlayed != nil { return 1 }
            return g.installState == .installed ? 2 : 3
        }
        // `games` is sorted by title, and the sort is stable, so equal ranks keep that order.
        return games.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            if ra != rb { return ra < rb }
            if ra == 1, let da = a.element.lastPlayed, let db = b.element.lastPlayed, da != db { return da > db }
            return a.offset < b.offset
        }.map(\.element)
    }

    var libraryGames: [Game] { games(in: libraryFilter) }

    func games(in filter: LibraryFilter) -> [Game] {
        let filtered: [Game]
        switch filter {
        case .all: filtered = games
        case .owned: filtered = games.filter { $0.access != .gamePass }
        case .gamePass: filtered = games.filter { $0.access == .gamePass }
        case .installed: filtered = games.filter { $0.installState != .notInstalled }
        }
        let query = librarySearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return filtered }
        return filtered.filter { Self.matches($0, query) }
    }

    /// Search in the title and the publisher, without case and accents.
    nonisolated static func matches(_ game: Game, _ query: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return query.split(separator: " ").allSatisfy { word in
            game.title.range(of: word, options: options) != nil
                || game.publisher.range(of: word, options: options) != nil
        }
    }

    var isTyping: Bool {
        guard account == .ready, setup == nil, installPrompt == nil, friendCard == nil, statusPanel == nil else { return false }
        switch screen {
        case .library: return libraryFocus == .search
        case .store: return storeFocus == .search
        case .conversation: return true
        default: return false
        }
    }

    func type(_ text: String) {
        guard isTyping, stream == nil else { return }
        if case .conversation = screen {
            if chatDraft.count + text.count <= Self.maxMessageLength { chatDraft += text }
            return
        }
        if screen == .store {
            setStoreSearch(storeSearch + text)
        } else {
            librarySearch += text
            libraryIndex = 0
        }
    }

    /// Delete key: remove one character while typing, else go back.
    func deleteKey() {
        guard stream == nil else { return }
        if isTyping {
            if case .conversation = screen {
                if !chatDraft.isEmpty { chatDraft.removeLast() }
                return
            }
            if screen == .store {
                if !storeSearch.isEmpty { setStoreSearch(String(storeSearch.dropLast())) }
            } else if !librarySearch.isEmpty {
                librarySearch.removeLast()
                libraryIndex = 0
            }
            return
        }
        back()
    }

    /// Y, "/", or Cmd+F: go to the search box.
    func focusSearch() {
        guard account == .ready, setup == nil, installPrompt == nil, friendCard == nil, stream == nil else { return }
        switch screen {
        case .library: libraryFocus = .search
        case .store: storeFocus = .search
        case .home: openLibrarySearch()
        default: break
        }
    }

    /// The search box of the top bar on the home screen: open the library with the search active.
    func openLibrarySearch() {
        openLibrary()
        libraryFocus = .search
    }

    func tapSearch() { focusSearch() }

    func clearSearch() {
        librarySearch = ""
        libraryIndex = 0
    }

    func setLibraryFilter(_ filter: LibraryFilter) {
        guard filter != libraryFilter else { return }
        libraryFilter = filter
        libraryIndex = 0
    }

    /// LB / RB and X: the previous or the next filter.
    /// LB / RB: the library filter, or the tab of the Social page.
    func shoulder(_ delta: Int) {
        guard account == .ready, setup == nil, installPrompt == nil, friendCard == nil, statusPanel == nil, stream == nil else { return }
        switch screen {
        case .library: shiftLibraryFilter(delta)
        case .friends, .messages: switchSocialTab(to: screen == .friends ? .messages : .friends)
        default: break
        }
    }

    func shiftLibraryFilter(_ delta: Int) {
        guard account == .ready, installPrompt == nil, screen == .library else { return }
        let all = LibraryFilter.allCases
        let index = (all.firstIndex(of: libraryFilter)! + delta + all.count) % all.count
        setLibraryFilter(all[index])
    }

    /// The game that the home background shows.
    var focusedHomeGame: Game? {
        guard homeRow == 0, homeIndex[0] < recent.count else { return nil }
        return recent[homeIndex[0]]
    }

    var focusedDownload: DownloadTask? {
        downloadIndex < downloadTasks.count ? downloadTasks[downloadIndex] : nil
    }

    func game(_ id: Game.ID) -> Game? { games.first { $0.id == id } }

    // MARK: - Account and library

    func startDemo() {
        demo = true
        // Demo mode and tests never read the real Runtimes folder.
        runtimes = [.standard]
        games = MockLibrary.games
        cloudProducts = Set(MockLibrary.games.prefix(2).map { $0.id.uppercased() })
        gamertag = "Player One"
        accountName = "player.one@example.com"
        gamerscore = 48_215
        controllers = [ControllerStatus(id: "1", name: "Xbox Wireless Controller", battery: 0.72, charging: false)]
        network = NetworkStatus(kind: .wifi, xboxLive: .reachable, checkedAt: Date())
        seenMessages = SeenMessages(file: FileManager.default.temporaryDirectory
            .appendingPathComponent("iodus-demo-seen-\(UUID().uuidString).json"))
        inbox = MockLibrary.inbox
        inboxState = .ready
        conversations[MockLibrary.friends[0].xuid] = MockLibrary.chat
        conversationState = .ready
        notificationStore = NotificationStore(file: FileManager.default.temporaryDirectory
            .appendingPathComponent("iodus-demo-notifications-\(UUID().uuidString).json"))
        notifications = MockLibrary.notifications
        friends = Friend.sorted(MockLibrary.friends)
        friendsState = .ready
        friendsLoadedAt = Date()
        storeRows = MockLibrary.storeRows
        storeIndex = storeRows.map { _ in 0 }
        storeState = .ready
        storeLoadedAt = Date()
        for row in storeRows { for item in row.items { storeItems[item.id] = item } }
        backendInfo = BackendInfo(version: "xodus-cli 0.1.0", source: "Xodus 53ea781 · Nexus patches 0.2.14 (76)",
                                  path: "~/projects/iodus-xodus/target/release/xodus-cli")
        account = .ready
    }

    func start() async {
        guard !demo else { return }
        guard let cli = XodusCLI.locate() else {
            account = .failed(BackendError.cliNotFound.localizedDescription)
            return
        }
        self.cli = cli
        Task { await loadCloudGames() }
        downloads.cli = cli
        launcher.cli = cli
        if setup == nil { checkSetupAtStart() }
        account = .checking
        Task { backendInfo = await BackendInfo.read(cli) }
        do {
            let status = try await cli.account()
            accountName = status.username ?? ""
            if status.stored {
                await loadAccount()
            } else {
                account = .signedOut
            }
        } catch {
            account = .failed(error.localizedDescription)
        }
    }

    func signIn() async {
        guard let cli, account != .signingIn else { return }
        account = .signingIn
        // The CLI opens its own window. In a full-screen space, that window is hidden.
        if let window = NSApp.windows.first, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        do {
            try await cli.login()
            NSApp.activate(ignoringOtherApps: true)
            accountName = (try? await cli.account())?.username ?? ""
            await loadAccount()
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            account = .failed(error.localizedDescription)
        }
    }

    func retry() async {
        await start()
    }

    /// True when the failure is a stored sign-in that Microsoft refuses, for
    /// example an old sign-in of another Xodus-based app (issue #5). Then only
    /// a new sign-in helps, and "Try again" repeats the same failure.
    var accountNeedsSignIn: Bool {
        guard case .failed(let message) = account else { return false }
        return Self.isSignInFailure(message)
    }

    static func isSignInFailure(_ message: String) -> Bool {
        message.contains("ticket-interaction-required") || message.contains("ticket-refused")
    }

    /// Removes the refused sign-in (the device registration stays) and opens
    /// the Microsoft sign-in window.
    func signInAgain() async {
        guard let cli else { return }
        try? await cli.logoutAccount()
        accountName = ""
        account = .signedOut
        await signIn()
    }

    private func loadAccount() async {
        guard let cli else { return }
        account = .loading
        // The profile is optional. A failure must not stop the library.
        async let profileTask: Void = loadProfile(cli)
        let name = accountName
        // The history is optional too. Without it, the home row uses the install state.
        async let historyTask = try? cli.titleHistory(account: name)
        do {
            let library = try await cli.library(market: market)
            let access = LibraryRules.accessByProduct(library.entitlements)
            let catalog = Catalog(session: ImageStore.shared.session)
            let products = try await catalog.products(ids: Array(access.keys), market: market)
            let shown = LibraryRules.withoutDuplicates(access, products: products)
            games = shown.compactMap { id, access -> Game? in
                guard let product = products[id], product.kind == "Game" else { return nil }
                return Game(id: id, title: product.title, publisher: product.publisher ?? "",
                            tileArt: product.tileArt, heroArt: product.heroArt, access: access,
                            installState: downloads.installState(for: id), titleId: product.titleId,
                            launcher: product.launcher)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            if !name.isEmpty, let history = await historyTask {
                games = Self.applyHistory(history, to: games)
                titleHistory = history
                historyLoadedAt = Date()
                historyState = .ready
            }
            // Games that iOdus started are not in Microsoft's history yet.
            games = playHistory.merged(into: games)
            homeIndex = [0, 0]
            libraryIndex = 0
            account = .ready
            startMessagePolling()
            startUpdateChecks()
        } catch {
            account = .failed(error.localizedDescription)
        }
        await profileTask
    }

    /// Matches the title history to the library by the Xbox title ID, or by the name.
    nonisolated static func applyHistory(_ history: [PlayedTitle], to games: [Game]) -> [Game] {
        func key(_ name: String) -> String {
            String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        var byTitle: [String: PlayedTitle] = [:], byName: [String: PlayedTitle] = [:]
        for item in history {
            if byTitle[item.titleId] == nil { byTitle[item.titleId] = item }
            if byName[key(item.name)] == nil { byName[key(item.name)] = item }
        }
        return games.map { game in
            var game = game
            guard let item = game.titleId.flatMap({ byTitle[$0] }) ?? byName[key(game.title)] else { return game }
            game.lastPlayed = item.lastPlayedDate
            if let current = item.currentGamerscore, let total = item.totalGamerscore, total > 0 {
                game.gamerscore = (current, total)
            }
            return game
        }
    }

    private func loadProfile(_ cli: XodusCLI) async {
        guard let profile = try? await cli.profile() else { return }
        gamertag = profile.gamertag
        if let dataURL = profile.gamerpicDataUrl,
           let comma = dataURL.firstIndex(of: ","),
           let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) {
            gamerpic = NSImage(data: data)
        }
        // The gamerscore comes from the people profile, not from `profile`.
        if !accountName.isEmpty, let me = try? await cli.playerProfile(account: accountName) {
            gamerscore = me.gamerscoreValue
        }
    }

    // MARK: - Settings

    private func signOut() {
        guard let cli else { return }
        if playState != .idle {
            showToast("Stop the game before you sign out.")
            return
        }
        if downloadTasks.contains(where: { $0.status == .running || $0.status == .paused }) {
            showToast("Stop the download before you sign out.")
            return
        }
        Task {
            do {
                try await cli.logout()
                socialChannel?.stop()
                socialChannel = nil
                inboxTimer?.invalidate()
                inboxTimer = nil
                inbox = []
                conversations = [:]
                inboxChecked = false
                games = []
                gamertag = ""
                gamerpic = nil
                accountName = ""
                stack = [.home]
                account = .signedOut
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    private func chooseInstallFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use folder"
        panel.message = "Choose the folder for new game installs."
        panel.directoryURL = downloads.installRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        downloads.setInstallRoot(url)
        objectWillChange.send()
        showToast("New games install to \(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).")
    }

    /// A on "Rescan install folder": add the games in the folder that have no record.
    func rescanInstallFolder() {
        guard !demo else {
            showToast("Demo mode cannot rescan the install folder.")
            return
        }
        let titles = Dictionary(games.map { ($0.id.uppercased(), $0.title) }, uniquingKeysWith: { first, _ in first })
        showToast(Self.rescanMessage(downloads.rescan(titles: titles)), seconds: 8)
    }

    nonisolated static func rescanMessage(_ result: DownloadManager.RescanResult) -> String {
        var parts: [String] = []
        let names = result.added.map(\.title)
        switch names.count {
        case 0: parts.append("iOdus found no new games.")
        case 1: parts.append("iOdus found 1 game: \(names[0]).")
        default: parts.append("iOdus found \(names.count) games: \(names.joined(separator: ", ")).")
        }
        if !result.copies.isEmpty {
            parts.append("Not added, because iOdus already uses another folder for the game: \(result.copies.joined(separator: ", ")).")
        }
        if !result.forgotten.isEmpty {
            parts.append("Removed from the list, because the folder is gone: \(result.forgotten.joined(separator: ", ")).")
        }
        return parts.joined(separator: " ")
    }

    var installFolderText: String {
        downloads.installRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // MARK: - Play

    private func syncPlayState() {
        let state = launcher.state
        if case .preparing(_, let step) = state, state != playState { showToast(step, seconds: 30) }
        if case .playing(let id) = state, playState != state {
            showToast("\(game(id)?.title ?? "The game") is running. Press View + Menu for the iOdus menu.", seconds: 6)
        }
        playState = state
        PerformanceOverlay.shared.update(playing: isPlaying, mode: overlayMode(for: playState.gameID))
    }

    /// The overlay of a game: its own choice, or the default from Settings.
    func overlayMode(for gameID: Game.ID?) -> PerformanceOverlayMode {
        gameID.flatMap { gameOptions.options($0).overlay } ?? AppSettings.performanceOverlay
    }

    var isPlaying: Bool {
        if case .playing = playState { return true }
        return false
    }

    /// Stops the running game in the normal way ("Close game" in the guide menu).
    func stopRunningGame() {
        guard case .playing(let id) = playState, let game = game(id) else { return }
        playOrStop(game)
    }

    private func playOrStop(_ game: Game, saveSync: SaveSync? = nil) {
        if playState.gameID == game.id {
            if case .playing = playState {
                launcher.stop()
                showToast("Stopping \(game.title)…")
            }
            return
        }
        if playState != .idle {
            showToast("Another game is running. Stop it first.")
            return
        }
        if uploadingSaves != nil {
            showToast("iOdus is uploading a save. Try again in a moment.")
            return
        }
        if installingVCRuntime {
            showToast("The Visual C++ runtime is installing. Try again in a moment.")
            return
        }
        guard !demo else {
            showToast("Demo mode cannot start games.")
            return
        }
        guard let path = downloads.installs[game.id]?.path else { return }
        // A starter for another launcher (STEEP: Ubisoft Connect) cannot run here.
        if let stub = gameStub(game) {
            showToast(stub.note(for: game.title), seconds: 7)
            return
        }
        if !GPTKRelease.pinned.isInstalled(in: setupRoot) || RosettaStatus.detect() == .missing, openSetup() {
            return
        }
        if saveSync == nil, case .conflict(let local, let cloud) = cloudSaveStatus(for: game) {
            var prompt = InstallPrompt(game: game)
            prompt.stage = .saveConflict(local: local, cloud: cloud)
            installPrompt = prompt
            return
        }
        if saveSync == .download, let titleId = game.titleId {
            do {
                try CloudSaveStatus.backup(titleId: titleId, prefix: savePrefix(for: game), into: saveBackupRoot)
            } catch {
                showToast("iOdus could not back up the Mac save, so it did not download the cloud save. \(error.localizedDescription)", seconds: 6)
                return
            }
        }
        if let index = games.firstIndex(where: { $0.id == game.id }) { games[index].lastPlayed = Date() }
        playHistory.record(game.id)
        if let titleId = game.titleId {
            playBaseline[game.id] = titleHistory.first { $0.titleId == titleId }
                ?? PlayedTitle(titleId: titleId, name: game.title, lastPlayed: nil, currentGamerscore: 0,
                               totalGamerscore: nil, achievementsUnlocked: 0)
        }
        let runtime = runtime(for: game)
        // The button changes to "Starting…" now; the start itself takes a moment.
        guard launcher.reserve(id: game.id, title: game.title) else { return }
        Task { await launcher.play(id: game.id, title: game.title, folder: URL(fileURLWithPath: path), saveSync: saveSync,
                                   using: runtime, options: gameOptions.options(game.id), overlay: overlayMode(for: game.id)) }
        startAchievementWatcher(for: game)
        if saveSync == nil { watchForSaveConflict(game) }
    }

    /// Many games write the save when the player quits, and then end at once.
    /// The upload in the game process then cannot finish. If a save waits,
    /// the runtime helper uploads it now, not at the next start.
    func uploadSavesAfterGame(_ id: String) async {
        guard !demo, let game = game(id), case .waiting = cloudSaveStatus(for: game),
              let path = downloads.installs[id]?.path else { return }
        uploadingSaves = id
        showToast("Uploading the save of \(game.title)…", seconds: 120)
        let line = await launcher.syncSaves(folder: URL(fileURLWithPath: path))
        uploadingSaves = nil
        switch cloudSaveStatus(for: game) {
        case .synced?:
            showToast("The save of \(game.title) is in the cloud.")
        case .conflict?:
            showToast("Save conflict in \(game.title). Choose a save at the next start.", seconds: 8)
        default:
            showToast("The save of \(game.title) did not upload. It uploads at the next start.", seconds: 6)
            if let line { NSLog("iOdus save sync: %@", line) }
        }
        objectWillChange.send()
    }

    /// The runtime finds a conflict at the start of the game. Then the game uses
    /// the Mac save, and nothing uploads. Tell the player while the game runs.
    private func watchForSaveConflict(_ game: Game) {
        Task {
            try? await Task.sleep(for: .seconds(45))
            guard playState.gameID == game.id, case .conflict = cloudSaveStatus(for: game) else { return }
            let text = "The cloud save and the Mac save of \(game.title) are different. This session does not upload. Quit the game, then choose a save at the next start."
            showToast("Save conflict in \(game.title). Quit to choose a save.", seconds: 8)
            notify(AppNotification(date: Date(), kind: .info, title: "Save conflict: \(game.title)", detail: text,
                                   action: .openGame(game.id)))
        }
    }

    /// Runtimes page, X: make the Wine prefix of a runtime again with the current runtime DLLs.
    func prepareRuntime(_ runtime: GameRuntime) {
        guard playState == .idle else {
            showToast("Stop the game first.")
            return
        }
        if runtime.id == GameRuntime.gptkID, !GPTKRelease.pinned.isInstalled(in: setupRoot), openSetup() { return }
        if let problem = runtime.problem {
            showToast(problem, seconds: 8)
            return
        }
        showToast("Preparing \(runtime.displayName)…", seconds: 60)
        Task {
            do {
                try await runtime.prepare { _ in }
                showToast("The game runtime is ready.")
            } catch {
                showToast(error.localizedDescription, seconds: 8)
            }
            objectWillChange.send()
        }
    }

    /// Settings: the default runtime.
    var runtimeStatus: [String] {
        let runtime = defaultRuntime
        var lines = ["Default: \(runtime.displayName) with D3DMetal"
                     + (runtimes.count > 1 ? " · \(runtimes.count) runtimes installed" : "")]
        if let problem = runtime.problem { return lines + [problem] }
        lines.append(runtime.isPrepared ? "Prefix ready: " + runtime.prefix.path
                        .replacingOccurrences(of: NSHomeDirectory(), with: "~")
                     : "The prefix is prepared at the first game start")
        return lines
    }

    // MARK: - Downloads

    private func syncDownloads() {
        downloadTasks = downloads.tasks
        downloadIndex = min(downloadIndex, max(0, downloadTasks.count - 1))
        for i in games.indices {
            let state = downloads.installState(for: games[i].id)
            if games[i].installState != state { games[i].installState = state }
        }
    }

    private func requestInstall(_ game: Game) {
        guard let cli else {
            showToast("Downloads need a signed-in account.")
            return
        }
        var prompt = InstallPrompt(game: game)
        prompt.destination = downloads.destination(for: game.title, productId: game.id).path
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        prompt.freeBytes = Bytes.freeSpace(at: downloads.installRoot)
        installPrompt = prompt
        Task {
            do {
                let plan = try await cli.resolvePackage(game.id, market: market)
                guard installPrompt?.game.id == game.id else { return }
                if let choice = plan.gameChoice {
                    installPrompt?.stage = .ready(choice)
                } else {
                    installPrompt?.stage = .failed("This game has no PC package that Xodus can install.")
                }
            } catch {
                guard installPrompt?.game.id == game.id else { return }
                installPrompt?.stage = .failed(error.localizedDescription)
            }
        }
    }

    private func confirmPrompt() {
        guard let prompt = installPrompt else { return }
        switch prompt.stage {
        case .restoreBackup(let backup):
            installPrompt = nil
            if prompt.focus == 0 { restoreBackup(backup, game: prompt.game) }
            return
        case .deleteBackup(let backup):
            installPrompt = nil
            if prompt.focus == 0 { deleteBackup(backup) }
            return
        case .uninstall:
            installPrompt = nil
            if prompt.focus == 0 { uninstallGame(prompt.game) }
            return
        default: break
        }
        if case .saveConflict = prompt.stage {
            installPrompt = nil
            switch prompt.focus {
            case 0: playOrStop(prompt.game, saveSync: .download)
            case 1: playOrStop(prompt.game, saveSync: .upload)
            default: break
            }
            return
        }
        guard prompt.focus == 0, case .ready(let choice) = prompt.stage else {
            installPrompt = nil
            return
        }
        installPrompt = nil
        downloads.enqueue(game: prompt.game, choice: choice)
        showToast("\(prompt.game.title) is in the download queue.")
    }

    func showToast(_ text: String, seconds: Double = 3) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: - Input

    func move(_ direction: Direction) {
        if stream != nil {
            if stream?.menuOpen == true { stream?.moveMenu(direction) }
            return
        }
        if statusPanel == .notifications {
            moveNotifications(direction)
            return
        }
        guard account == .ready, statusPanel == nil else { return }
        if setup != nil {
            moveSetup(direction)
            return
        }
        if installPrompt != nil {
            let count = installPrompt?.buttonCount ?? 2
            if direction == .left { installPrompt?.focus = max(0, (installPrompt?.focus ?? 0) - 1) }
            if direction == .right { installPrompt?.focus = min(count - 1, (installPrompt?.focus ?? 0) + 1) }
            return
        }
        switch screen {
        case .home: moveHome(direction)
        case .library: moveLibrary(direction)
        case .downloads: moveDownloads(direction)
        case .settings: moveSettings(direction)
        case .friends: moveFriends(direction)
        case .store: moveStore(direction)
        case .storeItem: break
        case .achievements: moveAchievements(direction)
        case .messages: moveMessages(direction)
        case .conversation: break
        case .achievementHub: moveHub(direction)
        case .detail: moveDetail(direction)
        case .saveBackups: moveBackups(direction)
        case .runtimes: moveRuntimes(direction)
        case .gameSettings: moveGameSettings(direction)
        }
    }

    func confirm() {
        if stream != nil {
            if stream?.menuOpen == true { chooseStreamMenu() }
            return
        }
        switch account {
        case .signedOut: Task { await signIn() }; return
        case .failed:
            Task { if accountNeedsSignIn { await signInAgain() } else { await retry() } }
            return
        case .ready: break
        default: return
        }
        if installPrompt != nil {
            confirmPrompt()
            return
        }
        if let panel = statusPanel {
            // A on the network panel checks again; on other panels A closes.
            switch panel {
            case .network: NetworkMonitor.shared.checkXboxLive()
            case .notifications: openNotification(notificationIndex)
            case .controllers: statusPanel = nil
            }
            return
        }
        if setup != nil {
            confirmSetup()
            return
        }
        if let card = friendCard {
            messageFriend(card.friend)
            return
        }
        switch screen {
        case .home:
            if homeRow == 0 {
                let i = homeIndex[0]
                if i < recent.count { openDetail(recent[i].id) } else { openLibrary() }
            } else {
                open(shortcut: shortcuts[homeIndex[1]])
            }
        case .library:
            switch libraryFocus {
            case .search:
                libraryFocus = libraryGames.isEmpty ? .filters : .grid
                return
            case .filters:
                if !libraryGames.isEmpty { libraryFocus = .grid }
                return
            case .grid:
                break
            }
            let list = libraryGames
            if libraryIndex < list.count { openDetail(list[libraryIndex].id) }
        case .downloads:
            if let task = focusedDownload { downloads.toggle(task.id) }
        case .settings:
            guard let row = focusedSettingsRow else {
                // A on a category: go into its rows.
                settingsFocus = .rows
                settingsIndex = 0
                return
            }
            switch row {
            case .account: signOut()
            case .installFolder: chooseInstallFolder()
            case .rescan: rescanInstallFolder()
            case .runtime: openRuntimes(gameID: nil)
            case .vcRuntime: installVCRuntime()
            case .fullScreen:
                AppSettings.startFullScreen.toggle()
                objectWillChange.send()
            case .performance:
                let old = overlayMode(for: playState.gameID)
                AppSettings.performanceOverlay = AppSettings.performanceOverlay.next
                overlayChanged(from: old)
            case .appUpdate:
                switch appUpdate {
                case .available: installAppUpdate()
                case .failed: openReleasePage()
                case .idle, .upToDate: checkForUpdatesNow()
                default: break
                }
            case .releaseNotes: openReleasePage()
            case .updates:
                updateChecker.enabled.toggle()
                objectWillChange.send()
                if updateChecker.enabled { Task { await checkForUpdates(force: true) } }
            case .exportLogs: exportLogs()
            default: break
            }
        case .friends:
            openFriendCard()
        case .store:
            confirmStore()
        case .storeItem(let id):
            openOnXbox(id)
        case .achievements:
            break
        case .messages:
            openSelectedConversation()
        case .conversation:
            sendDraft()
        case .achievementHub:
            openHubTitle()
        case .detail(let id):
            guard let game = game(id) else { return }
            let actions = detailActions(for: game)
            guard detailIndex < actions.count else { return }
            detailAction(actions[detailIndex], game: game)
        case .saveBackups(let id):
            requestRestore(gameID: id)
        case .runtimes:
            chooseRuntime()
        case .gameSettings(let id):
            guard let game = game(id) else { return }
            chooseGameSetting(GameSettingsRow.allCases[gameSettingsIndex], game: game)
        }
    }

    func back() {
        if stream != nil {
            if stream?.menuOpen == true { stream?.menuOpen = false }
            return
        }
        guard account == .ready else { return }
        if installPrompt != nil {
            installPrompt = nil
            return
        }
        if statusPanel != nil {
            statusPanel = nil
            return
        }
        if setup != nil { return }
        if friendCard != nil {
            friendCard = nil
            return
        }
        // In a search box, B or Escape first clears the text, then leaves the box.
        // A conversation keeps its draft and goes back at once.
        if isTyping, case .conversation = screen {
            stack.removeLast()
            return
        }
        if isTyping {
            if screen == .store {
                if !storeSearch.isEmpty { setStoreSearch("") } else { storeFocus = .rows }
            } else if !librarySearch.isEmpty {
                clearSearch()
            } else {
                libraryFocus = .filters
            }
            return
        }
        // Settings: B in the rows goes back to the category list first.
        if screen == .settings, settingsFocus == .rows {
            settingsFocus = .categories
            return
        }
        guard stack.count > 1 else { return }
        stack.removeLast()
    }

    /// One scroll step of the mouse wheel or the trackpad. `forward` shows the
    /// items after the focus (down, or right).
    func scroll(vertical: Bool, forward: Bool) {
        guard account == .ready, installPrompt == nil, friendCard == nil, stream == nil else { return }
        if statusPanel != nil {
            if statusPanel == .notifications, vertical { moveNotifications(forward ? .down : .up) }
            return
        }
        if setup != nil {
            moveSetup(forward ? (vertical ? .down : .right) : (vertical ? .up : .left))
            return
        }
        // These lists scroll natively, so the wheel must not also move the focus.
        switch screen {
        case .library, .achievementHub, .achievements, .friends, .saveBackups: return
        case .store where showsStoreResults: return
        default: break
        }
        guard vertical else {
            move(forward ? .right : .left)
            return
        }
        switch screen {
        case .home where homeRow == 0:
            move(forward ? .right : .left)   // The game row is horizontal.
        case .detail, .storeItem:
            break                            // One row of buttons only.
        default:
            move(forward ? .down : .up)
        }
    }

    func home() {
        if stream != nil {
            openStreamMenu()
            return
        }
        installPrompt = nil
        friendCard = nil
        stack = [.home]
    }

    /// X: the library filter, or stop / remove in Downloads.
    func xPressed() {
        guard stream == nil else { return }
        if statusPanel == .notifications {
            clearNotifications()
            return
        }
        // A sign-in failure: A signs in again, X only tries again.
        if accountNeedsSignIn {
            Task { await retry() }
            return
        }
        guard account == .ready, setup == nil, installPrompt == nil, statusPanel == nil else { return }
        switch screen {
        case .library:
            shiftLibraryFilter(1)
        case .downloads:
            if let task = focusedDownload { downloads.stopOrRemove(task.id) }
        case .messages:
            Task { await loadInbox(notify: false) }
        case .friends where friendCard == nil:
            Task { await loadFriends(force: true) }
        case .store where !isTyping:
            Task { await loadStore(force: true) }
        case .achievements:
            showSecrets.toggle()
        case .achievementHub:
            Task { await loadHistory(force: true) }
        case .saveBackups(let id):
            requestDelete(gameID: id)
        case .runtimes(nil):
            prepareFocusedRuntime()
        case .settings where focusedSettingsRow == .installFolder:
            let root = downloads.installRoot
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([root])
        default:
            break
        }
    }

    // MARK: - Mouse

    func tapHome(row: Int, index: Int) {
        homeRow = row
        homeIndex[row] = index
        confirm()
    }

    func tapFilter(_ filter: LibraryFilter) {
        setLibraryFilter(filter)
        libraryFocus = .filters
    }

    func tapLibrary(_ index: Int) {
        libraryFocus = .grid
        libraryIndex = index
        confirm()
    }

    func tapDetail(_ index: Int) {
        detailIndex = index
        confirm()
    }

    func tapDownload(_ index: Int) {
        downloadIndex = index
        confirm()
    }

    /// A click on a row of the current category.
    func tapSettings(_ index: Int) {
        settingsFocus = .rows
        settingsIndex = index
        confirm()
    }

    /// A click on a category: show its rows; the focus stays on the list.
    func tapSettingsCategory(_ index: Int) {
        settingsCategory = index
        settingsIndex = 0
        settingsFocus = .categories
    }

    /// The rows of the selected category.
    var settingsRows: [SettingsRow] { SettingsCategory.allCases[settingsCategory].rows }

    /// The row with the focus, or nil when the focus is on the category list.
    var focusedSettingsRow: SettingsRow? {
        guard settingsFocus == .rows, settingsRows.indices.contains(settingsIndex) else { return nil }
        return settingsRows[settingsIndex]
    }

    /// Settings opens on the first category, with the focus on the list.
    func resetSettings() {
        settingsCategory = 0
        settingsFocus = .categories
        settingsIndex = 0
    }

    func tapPrompt(_ index: Int) {
        installPrompt?.focus = index
        confirm()
    }

    // MARK: - Navigation

    private func detailAction(_ action: DetailAction, game: Game) {
        switch action {
        case .primary:
            switch game.installState {
            case .notInstalled: requestInstall(game)
            case .downloading: openDownloads(focus: game.id)
            case .installed: playOrStop(game)
            }
        case .manage:
            if case .installed = game.installState, let path = downloads.installs[game.id]?.path {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } else {
                showToast("Manage game comes later.")
            }
        case .achievements:
            openAchievements(game)
        case .saves:
            openSaveBackups(game)
        case .stream:
            startStream(game)
        case .gameSettings:
            gameSettingsIndex = 0
            stack.append(.gameSettings(game.id))
        case .uninstall:
            requestUninstall(game)
        }
    }

    /// A on Uninstall: ask first. The focus starts on Cancel.
    func requestUninstall(_ game: Game) {
        guard let install = downloads.installs[game.id] else { return }
        if playState.gameID == game.id {
            showToast("Stop \(game.title) first.")
            return
        }
        var prompt = InstallPrompt(game: game)
        prompt.stage = .uninstall(path: install.path, bytes: nil)
        prompt.focus = 1
        installPrompt = prompt
        let path = install.path
        Task.detached {
            let bytes = DownloadManager.folderSize(path)
            await MainActor.run {
                guard let current = self.installPrompt, current.game.id == game.id,
                      case .uninstall(let p, nil) = current.stage else { return }
                self.installPrompt?.stage = .uninstall(path: p, bytes: bytes)
            }
        }
    }

    func uninstallGame(_ game: Game) {
        guard !demo else {
            showToast("Demo mode cannot delete games.")
            return
        }
        guard playState.gameID != game.id, uploadingSaves != game.id else {
            showToast("Stop \(game.title) first.")
            return
        }
        do {
            try downloads.uninstall(game.id)
            detailIndex = 0
            // Game settings is only for an installed game: go back to the game page.
            if screen == .gameSettings(game.id) { stack.removeLast() }
            showToast("\(game.title) is uninstalled. Its saves stay in the cloud and on this Mac.", seconds: 5)
        } catch {
            showToast(error.localizedDescription, seconds: 8)
        }
    }

    /// The buttons of the game page. Stream shows only for cloud games.
    func detailActions(for game: Game) -> [DetailAction] {
        // A game that only a publisher launcher can install has no Install button.
        var actions: [DetailAction] = game.launcher != nil && game.installState == .notInstalled ? [] : [.primary]
        if isCloudGame(game) { actions.append(.stream) }
        // An installed game has Show in Finder and Uninstall in Game settings.
        if game.installState != .installed { actions.append(.manage) }
        actions.append(.achievements)
        if game.installState == .installed { actions.append(.gameSettings) }
        if hasSaveBackups(game) { actions.append(.saves) }
        return actions
    }

    func openDetail(_ id: Game.ID) {
        detailIndex = 0
        stack.append(.detail(id))
        if let game = game(id) { Task { await resolveCloudEdition(game) } }
    }

    private func openLibrary() {
        libraryIndex = 0
        libraryFocus = .grid
        librarySearch = ""
        stack.append(.library)
    }

    private func openDownloads(focus id: String? = nil) {
        downloadIndex = id.flatMap { id in downloadTasks.firstIndex { $0.id == id } } ?? 0
        stack.append(.downloads)
    }

    private func moveHome(_ d: Direction) {
        switch d {
        case .up: homeRow = 0
        case .down: homeRow = 1
        case .left: homeIndex[homeRow] = max(0, homeIndex[homeRow] - 1)
        case .right:
            let last = homeRow == 0 ? recent.count : shortcuts.count - 1
            homeIndex[homeRow] = min(last, homeIndex[homeRow] + 1)
        }
    }

    private func moveLibrary(_ d: Direction) {
        switch libraryFocus {
        case .search:
            // The search box is at the top middle, above the grid.
            switch d {
            case .down: libraryFocus = libraryGames.isEmpty ? .filters : .grid
            case .left: libraryFocus = .filters
            default: break
            }
            return
        case .filters:
            let all = LibraryFilter.allCases
            let index = all.firstIndex(of: libraryFilter)!
            switch d {
            case .up: if index > 0 { setLibraryFilter(all[index - 1]) } else { libraryFocus = .search }
            case .down: if index < all.count - 1 { setLibraryFilter(all[index + 1]) }
            case .right: if !libraryGames.isEmpty { libraryFocus = .grid }
            case .left: break
            }
            return
        case .grid:
            break
        }
        let n = libraryGames.count, c = libraryColumns
        guard n > 0 else {
            libraryFocus = .filters
            return
        }
        switch d {
        case .left:
            if libraryIndex % c > 0 { libraryIndex -= 1 } else { libraryFocus = .filters }
        case .right: if libraryIndex % c < c - 1, libraryIndex + 1 < n { libraryIndex += 1 }
        case .up: if libraryIndex - c >= 0 { libraryIndex -= c } else { libraryFocus = .search }
        case .down: libraryIndex = min(n - 1, libraryIndex + c)
        }
    }

    private func moveDownloads(_ d: Direction) {
        switch d {
        case .up: downloadIndex = max(0, downloadIndex - 1)
        case .down: downloadIndex = min(max(0, downloadTasks.count - 1), downloadIndex + 1)
        default: break
        }
    }

    private func moveGameSettings(_ d: Direction) {
        switch d {
        case .up: gameSettingsIndex = max(0, gameSettingsIndex - 1)
        case .down: gameSettingsIndex = min(GameSettingsRow.allCases.count - 1, gameSettingsIndex + 1)
        default: break
        }
    }

    func tapGameSettings(_ index: Int) {
        gameSettingsIndex = index
        confirm()
    }

    /// A on a row of the Game settings page.
    func chooseGameSetting(_ row: GameSettingsRow, game: Game) {
        var options = gameOptions.options(game.id)
        let running = playState.gameID == game.id
        switch row {
        case .runtime:
            openRuntimes(gameID: game.id)
            return
        case .showInFinder:
            if let path = downloads.installs[game.id]?.path {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            return
        case .uninstall:
            requestUninstall(game)
            return
        case .resetDisplay:
            resetDisplaySettings(game)
            return
        case .display:
            guard isUnityGame(game) else {
                showToast("iOdus can choose the display only for Unity games now.", seconds: 5)
                return
            }
            options.display = Displays.next(after: options.display, in: Displays.wineOrder())
            gameOptions.set(game.id, options)
            if running { showToast("The display changes when you start the game again.", seconds: 5) }
        case .retina:
            options.retina.toggle()
            gameOptions.set(game.id, options)
            if running { showToast("The resolution changes when you start the game again.", seconds: 5) }
        case .performance:
            let old = overlayMode(for: playState.gameID)
            options.overlay = PerformanceOverlayMode.nextGameChoice(after: options.overlay)
            gameOptions.set(game.id, options)
            overlayChanged(from: old)
        }
        objectWillChange.send()
    }

    /// Removes the screen settings that a Unity game saved in the prefix of its runtime.
    private func resetDisplaySettings(_ game: Game) {
        guard let path = downloads.installs[game.id]?.path,
              let unity = UnityGame.detect(in: URL(fileURLWithPath: path)) else {
            showToast("iOdus can reset the display settings only for Unity games now.", seconds: 5)
            return
        }
        guard playState.gameID != game.id else {
            showToast("Stop \(game.title) first.")
            return
        }
        let runtime = runtime(for: game)
        guard FileManager.default.fileExists(atPath: runtime.prefix.path), runtime.problem == nil else {
            showToast("\(game.title) saved no display settings on \(runtime.name) yet.", seconds: 5)
            return
        }
        Task {
            do {
                try runtime.linkSignedLoader()
                let count = try await runtime.resetUnityDisplay(unity)
                showToast(count == 0 ? "\(game.title) saved no display settings on \(runtime.name)."
                                     : "The display settings of \(game.title) are reset. It starts on its defaults.", seconds: 6)
            } catch {
                showToast(error.localizedDescription, seconds: 8)
            }
        }
    }

    /// After a change of an overlay choice: the system panel changes now;
    /// the Metal HUD starts with the game, so the running game keeps its FPS state.
    private func overlayChanged(from old: PerformanceOverlayMode) {
        objectWillChange.send()
        let new = overlayMode(for: playState.gameID)
        if isPlaying, old.showsFPS != new.showsFPS {
            showToast("The FPS counter changes when you start the game again.", seconds: 5)
        }
        PerformanceOverlay.shared.update(playing: isPlaying, mode: new)
    }

    private func moveSettings(_ d: Direction) {
        switch (settingsFocus, d) {
        case (.categories, .up), (.categories, .down):
            let next = settingsCategory + (d == .up ? -1 : 1)
            settingsCategory = min(max(0, next), SettingsCategory.allCases.count - 1)
            settingsIndex = 0
        case (.categories, .right):
            settingsFocus = .rows
            settingsIndex = 0
        case (.rows, .up): settingsIndex = max(0, settingsIndex - 1)
        case (.rows, .down): settingsIndex = min(settingsRows.count - 1, settingsIndex + 1)
        case (.rows, .left): settingsFocus = .categories
        default: break
        }
    }

    private func moveDetail(_ d: Direction) {
        switch d {
        case .left: detailIndex = max(0, detailIndex - 1)
        case .right:
            let count = game(currentDetailID ?? "").map { detailActions(for: $0).count } ?? DetailAction.allCases.count
            detailIndex = min(count - 1, detailIndex + 1)
        default: break
        }
    }

    func open(shortcut: Shortcut) {
        switch shortcut.id {
        case "library": openLibrary()
        case "downloads": openDownloads()
        case "settings":
            resetSettings()
            stack.append(.settings)

        case "achievements": openAchievementHub()
        case "social": openSocial()
        case "store": openStore()
        default: showToast("\(shortcut.title) comes later.")
        }
    }
}

enum DetailAction: Int, CaseIterable {
    case primary, manage, achievements, stream
    case gameSettings   // Only for an installed game
    case uninstall      // Only for an installed game
    case saves          // Only when the title has save backups; always the last button

    func title(for game: Game, play: PlayState = .idle) -> String {
        switch self {
        case .primary:
            if play.gameID == game.id {
                if case .playing = play { return "Stop game" }
                return "Starting…"
            }
            switch game.installState {
            case .installed: return "Play"
            case .notInstalled: return "Install"
            case .downloading: return "View download"
            }
        case .manage: return game.installState == .installed ? "Show in Finder" : "Manage game"
        case .achievements: return "Achievements"
        case .stream: return "Stream"
        case .gameSettings: return "Game settings"
        case .uninstall: return "Uninstall"
        case .saves: return "Save backups"
        }
    }

    func symbol(for game: Game, play: PlayState = .idle) -> String {
        switch self {
        case .primary:
            if play.gameID == game.id {
                if case .playing = play { return "stop.fill" }
                return "hourglass"
            }
            switch game.installState {
            case .installed: return "play.fill"
            case .notInstalled: return "arrow.down.to.line"
            case .downloading: return "arrow.down.circle"
            }
        case .manage: return game.installState == .installed ? "folder" : "ellipsis"
        case .achievements: return "trophy.fill"
        case .stream: return "cloud.fill"
        case .gameSettings: return "slider.horizontal.3"
        case .uninstall: return "trash"
        case .saves: return "clock.arrow.circlepath"
        }
    }
}

enum SettingsRow: Int, CaseIterable {
    case account, installFolder, rescan, fullScreen, performance, appUpdate, releaseNotes, updates, runtime, vcRuntime,
         backend, exportLogs, about
}

/// The state of the in-app update (Settings > Updates).
enum AppUpdateState: Equatable {
    case idle                               // No check yet, or nothing found
    case checking
    case upToDate
    case available(String)                  // The version
    case downloading(String, Double)        // The version, 0...1
    case verifying(String)
    case installing(String)
    case failed(String, String)             // The version, the reason

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .verifying, .installing: true
        default: false
        }
    }
}

/// The categories of the Settings page. Each one has few rows, so that a
/// category always fits in the window.
enum SettingsCategory: Int, CaseIterable {
    case account, games, display, runtimes, updates, about

    var title: String {
        switch self {
        case .account: "Account"
        case .games: "Games"
        case .display: "Display"
        case .runtimes: "Runtimes"
        case .updates: "Updates"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .account: "person.crop.circle"
        case .games: "gamecontroller"
        case .display: "display"
        case .runtimes: "cpu"
        case .updates: "arrow.down.circle"
        case .about: "info.circle"
        }
    }

    var rows: [SettingsRow] {
        switch self {
        case .account: [.account]
        case .games: [.installFolder, .rescan]
        case .display: [.fullScreen, .performance]
        case .runtimes: [.runtime, .vcRuntime]
        case .updates: [.appUpdate, .releaseNotes, .updates]
        case .about: [.about, .backend, .exportLogs]
        }
    }
}

/// Where the focus is on the Settings page.
enum SettingsFocus: Equatable {
    case categories, rows
}

/// The version and the source of the backend, for the Settings page.
struct BackendInfo: Equatable {
    let version: String
    let source: String?
    let path: String

    /// The app bundle has the lock file in Resources; a dev build of the fork has it in nexus/.
    static func lockFile(for cli: XodusCLI) -> URL {
        let repo = cli.url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Bundle.main.url(forResource: "backend-source.lock", withExtension: "json")
            ?? repo.appendingPathComponent("nexus/backend-source.lock.json")
    }

    static func read(_ cli: XodusCLI) async -> BackendInfo {
        let result = try? await cli.run(["--version"], timeout: 10)
        let version = result.map { String(decoding: $0.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        // A dev build of the fork has the lock file at <repo>/nexus/backend-source.lock.json.
        var source: String?
        let lockFile = lockFile(for: cli)
        if let data = try? Data(contentsOf: lockFile),
           let lock = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let commit = lock["commit"] as? String, let nexus = lock["version"] as? String {
            let patches = (lock["patches"] as? [Any])?.count ?? 0
            source = "Xodus \(commit.prefix(7)) · Nexus patches \(nexus) (\(patches))"
        }
        return BackendInfo(version: version.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown version", source: source,
                           path: cli.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
    }
}
