import AppKit
import SwiftUI

/// The entry point. `--snapshot <file.png> [screen]` writes one frame of the UI
/// to a PNG file and stops. `--export-iconset <folder>` writes the app icon
/// files for `iconutil`. All other starts open the app. `--fullscreen` and
/// `--windowed` override the "Start in full screen" setting for one start.
@main
enum Entry {
    static func main() {
        // A write to the stdin of a CLI that stopped must not stop iOdus.
        signal(SIGPIPE, SIG_IGN)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let screen = i + 2 < args.count ? args[i + 2] : "home"
            MainActor.assumeIsolated {
                Snapshot.write(to: args[i + 1], screen: screen)
            }
            return
        }
        if let i = args.firstIndex(of: "--export-iconset"), i + 1 < args.count {
            MainActor.assumeIsolated {
                do {
                    try AppIconView.writeIconset(to: URL(fileURLWithPath: args[i + 1]))
                } catch {
                    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
            return
        }
        AppSettings.migrateFromDevelopmentBuild()
        QuitSignals.install()
        if args.contains("--demo") {
            MainActor.assumeIsolated { AppModel.shared.startDemo() }
        }
        IOdusApp.main()
    }
}

struct IOdusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("iOdus") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1280, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        MainActor.assumeIsolated {
            // A build from `swift build` has no bundle icon, so set the Dock icon here.
            if let icon = AppIconView.image(size: 512) { NSApp.applicationIconImage = icon }
        }
        NSApp.activate(ignoringOtherApps: true)
        let args = CommandLine.arguments
        let fullScreen = args.contains("--fullscreen") || (!args.contains("--windowed") && AppSettings.startFullScreen)
        if fullScreen {
            DispatchQueue.main.async { NSApp.windows.first?.toggleFullScreen(nil) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.downloads.stopForQuit()
            AppModel.shared.launcher.shutdown()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
enum Snapshot {
    static func write(to path: String, screen: String) {
        let model = AppModel.shared
        model.startDemo()
        switch screen {
        case "library": model.stack = [.home, .library]
        case "detail": model.stack = [.home, .detail(model.games[0].id)]
        case "savebackups", "saverestore":
            let game = model.games[1]
            model.stack = [.home, .detail(game.id)]
            model.openSaveBackups(game)
            model.backupIndex = 1
            if screen == "saverestore" { model.requestRestore(gameID: game.id) }
        case "streamcover", "streamqueue", "streammenu", "streamsignin", "streampage":
            let game = model.games[0]
            model.stack = [.home, .detail(game.id)]
            model.startStream(game)
            switch screen {
            case "streamqueue":
                _ = model.stream?.apply(PageReport(state: "queue", text: "Lots of people are playing! Wait time is about 3 minutes."))
            case "streammenu":
                _ = model.stream?.apply(PageReport(state: "streaming"))
                model.openStreamMenu()
            case "streamsignin":
                _ = model.stream?.apply(PageReport(state: "signIn", host: "login.live.com"))
            case "streampage":
                model.stream?.timeout()
            default: break
            }
        case "setup-rosetta":
            model.setup = SetupFlow(steps: [.rosetta, .runtimes], rosetta: .missing)
        case "setup-runtime", "setup-fresh", "setup-wine":
            // The first start: the list of runtimes, the recommended one checked.
            var flow = SetupFlow(steps: [.rosetta, .runtimes, .vcRuntime], index: 1, rosetta: .installed)
            flow.choices = model.setupChoices()
            model.setup = flow
        case "setup-download", "setup-wine-download":
            var flow = SetupFlow(steps: [.rosetta, .runtimes, .vcRuntime], index: 1, rosetta: .installed,
                                 licenseAccepted: true)
            flow.choices = model.setupChoices()
            if flow.choices.count > 2 { flow.choices[2].checked = true }
            flow.queue = flow.checkedChoices
            flow.current = flow.queue.first
            flow.runtime = .downloading(done: 120_000_000, total: flow.choices[0].size)
            model.setup = flow
        case "setup-vc":
            var flow = SetupFlow(steps: [.rosetta, .runtimes, .vcRuntime], index: 2, rosetta: .installed)
            flow.choices = model.setupChoices()
            model.setup = flow
        case "setup-intel":
            model.setup = SetupFlow(steps: [.runtimes], rosetta: .notAppleSilicon)
        case "saveconflict":
            let game = model.games[1]
            model.stack = [.home, .detail(game.id)]
            var prompt = InstallPrompt(game: game)
            prompt.stage = .saveConflict(local: Date().addingTimeInterval(-7200), cloud: Date().addingTimeInterval(-86400))
            model.installPrompt = prompt
        case "install":
            let game = model.games[3]
            model.stack = [.home, .detail(game.id)]
            model.installPrompt = InstallPrompt(
                game: game,
                stage: .ready(InstallChoice(productId: game.id, contentId: "", title: game.title,
                                            platform: "Windows.Desktop", packageFormat: "MSIXVC", kind: "Game",
                                            supported: true, downloadBytes: 825_229_312, installBytes: nil)),
                destination: "~/Games/iOdus/\(game.title)",
                freeBytes: 412_000_000_000)
        case "downloads": model.stack = [.home, .downloads]
        case "settings":
            model.stack = [.home, .settings]
            model.settingsCategory = SettingsCategory.display.rawValue
            model.settingsFocus = .rows
            model.settingsIndex = 0
        case "settings-updates":
            model.stack = [.home, .settings]
            model.settingsCategory = SettingsCategory.updates.rawValue
            model.settingsFocus = .rows
            model.settingsIndex = 3
        case "friends": model.stack = [.home, .friends]
        case "friendcard":
            model.stack = [.home, .friends]
            model.friendCard = FriendCard(friend: model.friends[0], profile: PlayerProfile(
                xuid: model.friends[0].xuid, gamertag: model.friends[0].gamertag, gamerscore: "21350",
                online: true, presence: model.friends[0].presence, avatarUrl: nil,
                bio: "Fishing at night. Do not ask about the lighthouse.", location: "Harbor",
                tenure: "9", counts: PlayerProfile.Counts(friends: 42, followers: 18, following: 7)))
        case "store": model.stack = [.home, .store]
        case "controllers": model.statusPanel = .controllers
        case "messages": model.stack = [.home, .messages]
        case "conversation":
            model.stack = [.home, .messages, .conversation(MockLibrary.friends[0].xuid)]
            model.chatDraft = "Yes, at 9"
        case "notifications": model.statusPanel = .notifications
        case "network":
            model.network = NetworkStatus(kind: .wifi, xboxLive: .reachable, checkedAt: Date())
            model.statusPanel = .network
        case "achievements":
            var game = model.games[0]
            game.titleId = "1907796436"
            model.games[0] = game
            model.achievementLists["1907796436"] = MockLibrary.achievements
            model.achievementState = .ready
            model.achievementTitles["1907796436"] = AchievementTitle(titleId: "1907796436", name: game.title,
                                                                     art: nil, gameID: game.id)
            model.stack = [.home, .detail(game.id), .achievements("1907796436")]
        case "hub":
            model.titleHistory = MockLibrary.history + MockLibrary.history.map {
                PlayedTitle(titleId: $0.titleId + "9", name: $0.name + " II", lastPlayed: $0.lastPlayed,
                            currentGamerscore: $0.currentGamerscore, totalGamerscore: $0.totalGamerscore,
                            achievementsUnlocked: $0.achievementsUnlocked, achievementsTotal: $0.achievementsTotal)
            }
            model.historyState = .ready
            model.stack = [.home, .achievementHub]
        case "gamesettings":
            // A game with its own overlay; the snapshot does not write the settings.
            let game = model.games.first { $0.installState == .installed } ?? model.games[0]
            let suite = "iodus-snapshot"
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            model.gameOptions = GameOptionsStore(defaults: UserDefaults(suiteName: suite)!)
            model.gameOptions.set(game.id, GameOptions(retina: false, overlay: .system))
            model.stack = [.home, .detail(game.id), .gameSettings(game.id)]
            model.gameSettingsIndex = 1
        case "runtimes", "runtimesgame":
            let sample = RuntimeManifest(id: "crossover-26.3", name: "CrossOver 26.3 Wine", wineVersion: "11.0",
                                         wine: "bin/wine", wineserver: "bin/wineserver", libraries: "lib",
                                         components: ["xgameruntime.dll"], overrides: [:])
            model.runtimes = [.standard, .from(manifest: sample, root: URL(fileURLWithPath: "/nonexistent/crossover-26.3"),
                                               prefix: URL(fileURLWithPath: "/nonexistent/prefix"), usesBundle: false)]
            if screen == "runtimes" {
                model.stack = [.home, .settings, .runtimes(nil)]
                model.runtimeIndex = 1
            } else {
                model.stack = [.home, .detail(model.games[0].id), .runtimes(model.games[0].id)]
                model.runtimeIndex = 0
            }
        case "storeitem":
            model.stack = [.home, .store, .storeItem(model.storeRows[1].items[0].id)]
        default: break
        }
        if screen == "performancepanel" {
            // A real sample of this Mac (read only); the second sample has the CPU value.
            let stats = SystemStats()
            _ = stats.sample()
            Thread.sleep(forTimeInterval: 1)
            let panel = PerformancePanelView(sample: stats.sample())
                .padding(40)
                .background(Color(white: 0.3))
            writePNG(ImageRenderer(content: panel.environment(\.colorScheme, .dark)), to: path)
            return
        }
        if screen == "achievementpopup" {
            let popup = AchievementPopupView(name: "Introductions", gamerscore: 20, game: "DREDGE", icon: nil)
                .padding(40)
                .background(Color(white: 0.3))
            writePNG(ImageRenderer(content: popup.environment(\.colorScheme, .dark)), to: path)
            return
        }
        if screen == "guidemenupage" {
            // Friends inside the overlay, over a game.
            var state = GuideMenuState(gameID: model.games[0].id, title: model.games[0].title)
            state.page = .friends
            model.stack = [.home, .friends]
            let page = AnyView(RootContent().environmentObject(model).environment(\.snapshotMode, true))
            let menu = GuideMenuView(state: state, gamertag: model.gamertag, size: CGSize(width: 1920, height: 1080), page: page)
                .background(LinearGradient(colors: [.teal, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
            writePNG(ImageRenderer(content: menu.environment(\.colorScheme, .dark)), to: path)
            return
        }
        if screen == "guidemenu" || screen == "guidemenuclose" {
            // "guidemenuclose": the confirm step of "Close game".
            var state = GuideMenuState(gameID: model.games[0].id, title: model.games[0].title)
            state.index = 1
            if screen == "guidemenuclose" {
                state.index = state.items.count - 1
                _ = state.choose()
            }
            let size = CGSize(width: 1920, height: 1080)
            let menu = GuideMenuView(state: state, gamertag: model.gamertag, size: size)
                .background(LinearGradient(colors: [.teal, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
            writePNG(ImageRenderer(content: menu.environment(\.colorScheme, .dark)), to: path)
            return
        }
        let view = RootContent()
            .environmentObject(model)
            .environment(\.snapshotMode, true)
            .frame(width: 1920, height: 1080)
            .environment(\.colorScheme, .dark)
        writePNG(ImageRenderer(content: view), to: path)
    }

    private static func writePNG<V: View>(_ renderer: ImageRenderer<V>, to path: String) {
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("snapshot write failed: \(error)\n".utf8))
            exit(1)
        }
    }
}

/// SIGTERM and SIGHUP (for example a closed Terminal window) stop iOdus in the
/// same way as a normal quit, so that no download or game is left without an owner.
/// Small user settings in UserDefaults.
enum AppSettings {
    static let startFullScreenKey = "startFullScreen"

    /// The app bundle (com.burghr.iodus) and a `swift build` binary ("iOdus") have
    /// different settings domains. At the first start of the bundle, copy the
    /// settings of the development build once.
    static func migrateFromDevelopmentBuild() {
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleIdentifier == "com.burghr.iodus",
              !defaults.bool(forKey: "migratedDevelopmentSettings"),
              let old = UserDefaults(suiteName: "iOdus") else { return }
        for key in [startFullScreenKey, DownloadManager.installRootKey] where defaults.object(forKey: key) == nil {
            if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "migratedDevelopmentSettings")
    }

    /// The player chose Microsoft's VC++ runtime: every runtime prefix gets it,
    /// also a prefix that iOdus makes later.
    /// The performance overlay while a game runs. The default is off.
    static var performanceOverlay: PerformanceOverlayMode {
        get { UserDefaults.standard.string(forKey: "performanceOverlay").flatMap(PerformanceOverlayMode.init) ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "performanceOverlay") }
    }

    static var vcRuntimeWanted: Bool {
        get { UserDefaults.standard.bool(forKey: "vcRuntimeWanted") }
        set { UserDefaults.standard.set(newValue, forKey: "vcRuntimeWanted") }
    }

    /// Start in full screen. The default is off.
    static var startFullScreen: Bool {
        get { UserDefaults.standard.bool(forKey: startFullScreenKey) }
        set { UserDefaults.standard.set(newValue, forKey: startFullScreenKey) }
    }
}

enum QuitSignals {
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

    static func install() {
        for number in [SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    AppModel.shared.downloads.stopForQuit()
                    AppModel.shared.launcher.shutdown()
                }
                exit(0)
            }
            source.resume()
            sources.append(source)
        }
    }
}
