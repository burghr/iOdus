import XCTest
@testable import iOdus

final class GameOptionsTests: XCTestCase {
    private let suite = "iodus-game-options-tests"
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testStoreKeepsEachGameAndDropsDefaults() {
        let store = GameOptionsStore(defaults: defaults)
        XCTAssertEqual(store.options("9PCR3Z2MSM4T"), GameOptions())
        store.set("9pcr3z2msm4t", GameOptions(retina: true, overlay: .system))
        XCTAssertEqual(store.options("9PCR3Z2MSM4T"), GameOptions(retina: true, overlay: .system), "IDs ignore case")
        XCTAssertEqual(store.options("OTHER"), GameOptions())
        store.set("9PCR3Z2MSM4T", GameOptions())
        XCTAssertEqual(store.options("9PCR3Z2MSM4T"), GameOptions())
        XCTAssertEqual(defaults.data(forKey: GameOptionsStore.key).flatMap { try? JSONDecoder().decode([String: GameOptions].self, from: $0) },
                       [:], "The default settings remove the entry")
    }

    func testOverlayChoiceCyclesThroughTheDefault() {
        var choice: PerformanceOverlayMode? = nil
        var seen: [PerformanceOverlayMode?] = []
        for _ in 0..<5 {
            choice = PerformanceOverlayMode.nextGameChoice(after: choice)
            seen.append(choice)
        }
        XCTAssertEqual(seen, [.off, .fps, .system, .full, nil])
    }

    func testRetinaChangesOnlyWhenTheMarkerDiffers() {
        XCTAssertFalse(GameRuntime.retinaNeedsChange(marker: nil, wanted: false), "No marker is Wine's default: off")
        XCTAssertTrue(GameRuntime.retinaNeedsChange(marker: nil, wanted: true))
        XCTAssertFalse(GameRuntime.retinaNeedsChange(marker: "y", wanted: true))
        XCTAssertTrue(GameRuntime.retinaNeedsChange(marker: "y", wanted: false))
        XCTAssertTrue(GameRuntime.retinaNeedsChange(marker: "n", wanted: true))
    }

    func testScreenSizeInPixels() {
        let screen = ScreenSize(points: CGSize(width: 1512, height: 982), scale: 2)
        XCTAssertEqual(ScreenSize.text(screen.points), "1512 × 982")
        XCTAssertEqual(ScreenSize.text(screen.pixels), "3024 × 1964")
    }
}

@MainActor
final class GameSettingsModelTests: XCTestCase {
    private let suite = "iodus-game-settings-tests"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func model() -> AppModel {
        let model = AppModel()
        model.startDemo()
        model.gameOptions = GameOptionsStore(defaults: defaults)
        model.runtimeChoice = RuntimeChoice(defaults: defaults)
        return model
    }

    func testGameSettingsPageChangesOnlyThatGame() throws {
        let model = model()
        let game = try XCTUnwrap(model.games.first { $0.installState == .installed })
        let other = try XCTUnwrap(model.games.first { $0.id != game.id })
        model.stack = [.home, .detail(game.id)]
        model.detailIndex = try XCTUnwrap(model.detailActions(for: game).firstIndex(of: .gameSettings))
        model.confirm()
        XCTAssertEqual(model.screen, .gameSettings(game.id))

        // Display: the demo game is not a Unity game, so A changes nothing.
        model.move(.down)
        model.confirm()
        XCTAssertNil(model.gameOptions.options(game.id).display)

        // Reset display settings: also only for Unity games; nothing changes.
        model.move(.down)
        model.confirm()
        XCTAssertEqual(model.gameOptions.options(game.id), model.gameOptions.options(other.id))

        model.move(.down)
        model.confirm()
        XCTAssertTrue(model.gameOptions.options(game.id).retina)
        XCTAssertFalse(model.gameOptions.options(other.id).retina)

        let global = model.overlayMode(for: other.id)
        model.move(.down)
        model.confirm()
        XCTAssertEqual(model.gameOptions.options(game.id).overlay, .off)
        XCTAssertEqual(model.overlayMode(for: game.id), .off)
        XCTAssertEqual(model.overlayMode(for: other.id), global, "Other games keep the default")

        model.move(.up); model.move(.up); model.move(.up); model.move(.up)
        model.confirm()
        XCTAssertEqual(model.screen, .runtimes(game.id), "The Runtime row opens the runtimes of the game")
        model.back()
        XCTAssertEqual(model.screen, .gameSettings(game.id))
        XCTAssertFalse(model.detailActions(for: game).contains(.uninstall), "Uninstall is in Game settings")
    }
}

final class GameCompatTests: XCTestCase {
    func testDirtGetsTheDepthBoundsBehavior() {
        XCTAssertEqual(GameCompat.environment(for: "9pjgm0t0827v")["D3DM_EXE_OVERRIDE"], "GoWR.exe")
        XCTAssertEqual(GameCompat.environment(for: "9PCR3Z2MSM4T"), [:], "Other games get nothing")
        XCTAssertEqual(GameCompat.environment(for: "9pc288tn7r8k")["CX_FWD_COMPAT_GL_CTX"], "1",
                       "Grim Fandango Remastered gets a forward-compatible OpenGL context")
        for edition in ["9NR1R1XWLCNB", "9n431px143p8", "9N4XW3N02MNJ"] {
            XCTAssertEqual(GameCompat.environment(for: edition)["D3DM_VENDOR_ID"], "0x8086", "Forza Horizon 6 reports an Intel GPU")
        }
        for edition in ["9N98Z825TNFW", "9n98z825tnfw", "9MV69L4JSD31"] {
            XCTAssertEqual(GameCompat.requiredRuntime(for: edition), GameCompat.d3dmetal4Runtime, "Minecraft Legends requires D3DMetal 4")
        }
    }
}

@MainActor
final class LauncherReserveTests: XCTestCase {
    func testASecondPressDoesNotStartTheGameAgain() async {
        let launcher = GameLauncher()
        XCTAssertTrue(launcher.reserve(id: "A", title: "Game A"))
        XCTAssertEqual(launcher.state, .preparing(id: "A", step: "Starting Game A"))
        XCTAssertFalse(launcher.reserve(id: "A", title: "Game A"), "The game is busy")
        XCTAssertFalse(launcher.reserve(id: "B", title: "Game B"), "Another game is busy")

        // The reserved start runs (no backend here, so it ends at once); a second call does not start.
        var finished: [String] = []
        launcher.onFinish = { id, _ in finished.append(id) }
        await launcher.play(id: "A", title: "Game A", folder: URL(fileURLWithPath: "/nonexistent"))
        XCTAssertEqual(finished, ["A"])
        XCTAssertEqual(launcher.state, .idle)
        XCTAssertTrue(launcher.reserve(id: "A", title: "Game A"), "After the end, the game can start again")
    }
}

final class GamingServicesVersionTests: XCTestCase {
    func testTheVersionIsPackedAsTheRegistryKeepsIt() {
        // 38.117.27001.0: the value that Xodus Nexus writes (0x0026007569790000).
        XCTAssertEqual(GameRuntime.packedVersion(GameRuntime.gamingServicesVersion), 0x0026_0075_6979_0000)
        XCTAssertEqual(GameRuntime.packedVersion("1.2.3.4"), 0x0001_0002_0003_0004)
        XCTAssertNil(GameRuntime.packedVersion("1.2.3"), "Four parts")
        XCTAssertNil(GameRuntime.packedVersion("1.2.3.70000"), "Each part fits in 16 bits")
    }
}
