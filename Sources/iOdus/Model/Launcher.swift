import AppKit
import Foundation

/// The direction of a forced save sync (the XODUS_SAVE_SYNC value of the runtime).
enum SaveSync: String {
    case download   // The cloud save replaces the Mac save
    case upload     // The Mac save replaces the cloud save
}

enum PlayState: Equatable {
    case idle
    case preparing(id: String, step: String)
    case playing(id: String)

    var gameID: String? {
        switch self {
        case .idle: return nil
        case .preparing(let id, _), .playing(let id): return id
        }
    }
}

/// Starts installed games:
/// 1. The Wine prefix gets the Xbox runtime (first start only).
/// 2. `xodus-cli service` runs, with the TCP bridge in front of its socket.
/// 3. `xodus-cli run <folder> <wine64> --exe <exe> --materialize-chain` starts the game.
/// One game runs at a time. Logs go to ~/Library/Logs/iOdus.
@MainActor
final class GameLauncher {
    var cli: XodusCLI?
    var market = "US"
    /// The runtime of the running (or last) game.
    private(set) var runtime: GameRuntime
    private(set) var state: PlayState = .idle {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?
    /// The game that `reserve` marked; its `play` call may start from that state.
    private var reservedID: String?
    /// Called when a game stops: the product ID and an error text, or nil.
    var onFinish: ((String, String?) -> Void)?

    private var service: StreamingProcess?
    private var bridge: XodusBridge?
    private var game: Process?
    private var gameImage: String?      // The file name of the game executable, for taskkill
    private var gameLog: URL?
    private var started = Date()
    private var stopRequested = false

    static var socketPath: String { GameRuntime.support.appendingPathComponent("xodus.sock").path }
    static var logFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/iOdus", isDirectory: true)
    }

    init(runtime: GameRuntime = .standard) {
        self.runtime = runtime
    }

    /// The performance overlay of the game that starts (its own choice, or the default).
    private var overlayMode: PerformanceOverlayMode = .off

    var runtimeProblem: String? { runtime.problem }

    // MARK: - Play

    /// Marks a game as starting at once, before the async `play` runs. A second
    /// press then finds the game busy and does not start it again.
    func reserve(id: String, title: String) -> Bool {
        guard state == .idle else { return false }
        reservedID = id
        state = .preparing(id: id, step: "Starting \(title)")
        return true
    }

    func play(id: String, title: String, folder: URL, saveSync: SaveSync? = nil, using chosen: GameRuntime? = nil,
              options: GameOptions = GameOptions(), overlay: PerformanceOverlayMode = .off) async {
        if reservedID == id {
            reservedID = nil
        } else {
            guard state == .idle else { return }
        }
        overlayMode = overlay
        if let chosen { runtime = chosen }
        guard let cli else { return finish(id, "The backend is not available.") }
        if let problem = runtime.problem { return finish(id, problem) }
        guard let exe = GameConfig.executable(in: folder) else {
            return finish(id, "MicrosoftGame.Config of \(title) names no executable.")
        }
        stopRequested = false
        do {
            if !runtime.isPrepared {
                state = .preparing(id: id, step: "Preparing the game runtime")
                try await runtime.prepare { step in
                    Task { @MainActor in
                        if case .preparing = self.state { self.state = .preparing(id: id, step: step) }
                    }
                }
                // The VC++ runtime that the player chose. A failure does not stop the game.
                if AppSettings.vcRuntimeWanted, !VCRuntime.isInstalled(prefix: runtime.prefix) {
                    state = .preparing(id: id, step: "Installing the Visual C++ runtime")
                    try? await runtime.installVCRuntime()
                }
            }
            // A new build of the runtime: update the prefix without the Wine Mono dialog.
            if runtime.needsWineUpdate() {
                state = .preparing(id: id, step: "Updating the game runtime")
                try await runtime.updatePrefix()
            }
            // The d3d12.dll layer of this app version (D3DMetal 4 runtimes only).
            // If the copy fails, the game starts with the layer that the runtime has.
            _ = try? runtime.updateD3D12Layer()
            // Native arm64 runtimes: the app's signed loader and its Xbox DLLs.
            try runtime.linkSignedLoader()
            _ = try? runtime.updateOverlay()
            // The game's Retina choice. A change restarts the Wine processes of the prefix.
            try await runtime.applyRetinaMode(options.retina)
            // Some games check the Gaming Services version in the registry.
            try? await runtime.applyGamingServicesVersion()
            state = .preparing(id: id, step: "Starting the Xbox services")
            let bridge = try await ensureService(cli)
            if stopRequested { return finish(id, nil) }

            state = .preparing(id: id, step: "Starting \(title)")
            Self.removeEmptyMountFolders(near: folder)
            var gameArguments: [String] = []
            if let unity = UnityGame.detect(in: folder) {
                // D3DMetal crashes on Cmd+Tab in exclusive full screen. Use borderless.
                await runtime.preferBorderless(unity)
                gameArguments = UnityGame.arguments
                if let display = Displays.find(options.display) {
                    gameArguments += Displays.unityArguments(display, retina: options.retina)
                }
            }
            try startGame(id: id, title: title, folder: folder, exe: exe, cli: cli, bridge: bridge,
                          gameArguments: gameArguments, saveSync: saveSync)
        } catch {
            finish(id, error.localizedDescription)
        }
    }

    /// A on a running game: stop it. The backend forwards SIGINT to Wine.
    func stop() {
        stopRequested = true
        guard let game, game.isRunning else { return }
        let runtime = self.runtime
        let image = gameImage
        Task {
            // 1. Close the windows, as Windows does. The game shuts down
            //    normally, and the runtime removes the Xbox title presence.
            if let image {
                await runtime.closeGame(image: image)
                for _ in 0..<Self.closeWaitSteps where game.isRunning {
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            // 2. The game did not close (for example, it asks "Quit?"): interrupt it.
            guard game.isRunning else { return }
            game.interrupt()
            try? await Task.sleep(for: .seconds(8))
            if game.isRunning { await runtime.killWineserver() }
        }
    }

    /// After a game ends: upload its waiting saves. Needs the running Xbox
    /// service (the bridge), the same as a game start.
    func syncSaves(folder: URL) async -> String? {
        guard let bridge, let config = GameConfig.configFile(in: folder) else { return nil }
        return await runtime.syncSaves(config: config, extra: bridge.environment)
    }

    /// Half seconds to wait for a game to close after WM_CLOSE.
    static let closeWaitSteps = 20

    /// "bin\\Game.exe" or "bin/Game.exe" -> "Game.exe" (taskkill /im takes the file name).
    static func imageName(_ exe: String) -> String? {
        let name = exe.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? ""
        return name.isEmpty ? nil : name
    }

    /// At app quit: stop the game, the service, and the bridge.
    func shutdown() {
        stopRequested = true
        if let game, game.isRunning { game.interrupt() }
        service?.interrupt()
        bridge?.stop()
        service = nil
        bridge = nil
    }

    // MARK: - Service

    private func ensureService(_ cli: XodusCLI) async throws -> XodusBridge {
        if let service, service.isRunning, let bridge,
           FileManager.default.fileExists(atPath: Self.socketPath) {
            return bridge
        }
        service?.interrupt()
        bridge?.stop()
        // A service from an earlier iOdus can still run. Stop it before a new one binds the socket.
        let orphans = Orphans.find(cli: cli.url, arguments: ["service"])
        if !orphans.isEmpty { _ = await Orphans.stop(orphans, timeout: 10) }

        var env = ProcessInfo.processInfo.environment
        env["XODUS_SOCKET"] = Self.socketPath
        env["XODUS_LOG"] = env["XODUS_LOG"] ?? "warn"
        let process = StreamingProcess(url: cli.url, arguments: ["service"], environment: env)
        service = process

        // The first start can wait for Keychain dialogs, so the limit is long.
        let ready: Bool = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let resume: @MainActor (Result<Bool, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            do {
                try process.start(
                    onLine: { line in if line.hasPrefix("XODUS_SERVICE_READY") { resume(.success(true)) } },
                    onExit: { _, stderr in
                        resume(.failure(BackendError.failed("The Xbox service stopped: \(XodusCLI.message(from: stderr))")))
                    })
            } catch {
                resume(.failure(error))
                return
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(180))
                resume(.success(false))
            }
        }
        guard ready else {
            process.interrupt()
            throw BackendError.failed("The Xbox service did not start. Check for a Keychain dialog.")
        }
        let bridge = try XodusBridge(socketPath: Self.socketPath)
        self.bridge = bridge
        return bridge
    }

    // MARK: - Game

    private func startGame(id: String, title: String, folder: URL, exe: String,
                           cli: XodusCLI, bridge: XodusBridge, gameArguments: [String], saveSync: SaveSync?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.logFolder, withIntermediateDirectories: true)
        let safe = title.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        let log = Self.logFolder.appendingPathComponent("\(String(safe).isEmpty ? id : String(safe)).log")
        fm.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)

        // Wine starts through iodus-wine-launch when the app has it (see the script).
        let launcher = runtime.componentFolder.appendingPathComponent("iodus-wine-launch")
        let useLauncher = fm.isExecutableFile(atPath: launcher.path)
        let process = Process()
        process.executableURL = cli.url
        process.arguments = ["run", folder.path, useLauncher ? launcher.path : runtime.wine64.path, "--exe", exe,
                             "--materialize-chain", "--market", market]
            + (gameArguments.isEmpty ? [] : ["--"] + gameArguments)
        var extra = bridge.environment
        // The player's choice in a save conflict: this start downloads or uploads all saves.
        if let saveSync { extra["XODUS_SAVE_SYNC"] = saveSync.rawValue }
        extra.merge(GameCompat.environment(for: id)) { _, new in new }
        if useLauncher {
            extra["IODUS_REAL_WINE"] = runtime.wine64.path
            // The PlayFab save proxy, for the games that need it (GameCompat).
            let proxy = runtime.componentFolder.appendingPathComponent("compat/PlayFabGameSave.dll")
            if extra["IODUS_PLAYFAB_ADAPTER"] == "1", fm.fileExists(atPath: proxy.path) {
                extra["IODUS_PLAYFAB_PROXY"] = proxy.path
            }
        }
        extra.merge(overlayMode.gameEnvironment) { _, new in new }
        var environment = runtime.environment(extra: extra)
        // macOS removes DYLD_* variables when it starts /bin/sh (a protected
        // program), so iodus-wine-launch gets these copies and restores them for Wine.
        if useLauncher {
            for key in ["DYLD_FALLBACK_LIBRARY_PATH", "DYLD_FALLBACK_FRAMEWORK_PATH"] {
                if let value = environment[key] { environment["IODUS_" + key] = value }
            }
        }
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            try? handle.close()
            Task { @MainActor in self?.gameEnded(id: id, title: title, status: status) }
        }
        try process.run()
        game = process
        gameImage = Self.imageName(exe)
        gameLog = log
        started = Date()
        state = .playing(id: id)
    }

    private func gameEnded(id: String, title: String, status: Int32) {
        game = nil
        var error: String?
        if status != 0 && !stopRequested {
            let tail = gameLog.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                .map { XodusCLI.message(from: $0) } ?? ""
            let path = gameLog?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? ""
            error = "\(title) stopped (code \(status)). \(tail) Log: \(path)"
        }
        finish(id, error)
    }

    private func finish(_ id: String, _ error: String?) {
        reservedID = nil
        state = .idle
        onFinish?(id, error)
    }

    /// `xodus-cli run` leaves an empty `.xodus-mounts-*` folder next to the game.
    static func removeEmptyMountFolders(near folder: URL) {
        let parent = folder.deletingLastPathComponent()
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: parent.path) else { return }
        for name in names where name.hasPrefix(".xodus-mounts-") && !name.hasSuffix(".lock") {
            let url = parent.appendingPathComponent(name)
            if (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == true {
                try? fm.removeItem(at: url)
                try? fm.removeItem(at: parent.appendingPathComponent(name + ".lock"))
            }
        }
    }
}
