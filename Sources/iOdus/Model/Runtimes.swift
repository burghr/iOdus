import Foundation

/// The installed runtimes: the built-in GPTK runtime, then each folder in
/// `Runtimes/` with a valid runtime.json. Each runtime has its own prefix in
/// `Prefixes/<id>`.
enum RuntimeCatalog {
    static var runtimesFolder: URL { GameRuntime.support.appendingPathComponent("Runtimes", isDirectory: true) }
    static var prefixesFolder: URL { GameRuntime.support.appendingPathComponent("Prefixes", isDirectory: true) }

    static func discover(folder: URL = runtimesFolder, prefixes: URL = prefixesFolder,
                         standard: GameRuntime = .standard) -> [GameRuntime] {
        // A test passes its own GPTK runtime; then the other runtimes use its DLL folder too.
        let testing = standard.root != GameRuntime.standard.root
        var list = [standard]
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for root in folders {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("runtime.json")),
                  let manifest = try? JSONDecoder().decode(RuntimeManifest.self, from: data),
                  isValidID(manifest.id), manifest.id == root.lastPathComponent,
                  !list.contains(where: { $0.id == manifest.id }) else { continue }
            list.append(.from(manifest: manifest, root: root,
                              prefix: prefixes.appendingPathComponent(manifest.id, isDirectory: true),
                              componentRoot: standard.componentRoot, usesBundle: !testing))
        }
        return list
    }

    /// Letters, digits, ".", "-", and "_" only: the ID is a folder name.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && !id.hasPrefix(".")
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) }
    }
}

/// The default runtime and the runtime of each game (product ID), in UserDefaults.
struct RuntimeChoice {
    static let defaultKey = "defaultRuntime"
    static let gamesKey = "gameRuntimes"
    let defaults: UserDefaults

    var defaultID: String? {
        get { defaults.string(forKey: Self.defaultKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.defaultKey) }
    }

    func gameID(_ productId: String) -> String? {
        (defaults.dictionary(forKey: Self.gamesKey) as? [String: String])?[productId.uppercased()]
    }

    /// nil: the game uses the default runtime.
    func setGame(_ productId: String, _ runtimeID: String?) {
        var map = (defaults.dictionary(forKey: Self.gamesKey) as? [String: String]) ?? [:]
        map[productId.uppercased()] = runtimeID
        defaults.set(map, forKey: Self.gamesKey)
    }

    /// The default runtime: the saved one if it is installed, else the first (GPTK).
    func defaultRuntime(in list: [GameRuntime]) -> GameRuntime {
        list.first { $0.id == defaultID } ?? list[0]
    }

    /// The runtime of a game: its own choice if installed, else the default.
    func runtime(for productId: String, in list: [GameRuntime]) -> GameRuntime {
        if let id = gameID(productId), let runtime = list.first(where: { $0.id == id }) { return runtime }
        return defaultRuntime(in: list)
    }
}

/// One row of the Runtimes page.
enum RuntimeRow: Equatable {
    case useDefault                     // Game page only: the game uses the default
    case installed(GameRuntime)
    case available(RuntimeDownload)     // Settings only: not installed, or a newer release

    /// The kind of runtime; nil for "Use the default".
    var family: RuntimeFamily? {
        switch self {
        case .useDefault: return nil
        case .installed(let runtime): return runtime.family
        case .available(let download): return download.family
        }
    }
}

/// The two kinds of runtime. The Runtimes page shows them in two groups.
enum RuntimeFamily: Int, CaseIterable, Comparable {
    case d3dmetal   // x86-64 Wine through Rosetta 2, Direct3D through Apple's D3DMetal
    case fex        // Native arm64 Wine, FEX for the game's x86-64 code, DXVK and vkd3d-proton on Vulkan

    static func < (a: RuntimeFamily, b: RuntimeFamily) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .d3dmetal: return "D3DMetal · Rosetta 2"
        case .fex: return "FEX · native Apple silicon (beta)"
        }
    }

    var detail: String {
        switch self {
        case .d3dmetal:
            return "Rosetta 2 runs Wine and the game. Apple's D3DMetal draws Direct3D with Metal."
        case .fex:
            return "Wine runs natively. FEX runs the game's x86-64 code. DXVK and vkd3d-proton draw Direct3D through Vulkan."
        }
    }
}

/// A runtime download in progress.
struct RuntimeDownloadState: Equatable {
    let id: String
    var done: Int64 = 0
    var total: Int64 = 0
    var installing = false
}

/// The Runtimes page: from Settings it sets the default runtime and offers
/// downloads; from a game page it sets the runtime of that game.
extension AppModel {
    var defaultRuntime: GameRuntime { runtimeChoice.defaultRuntime(in: runtimes) }

    /// The player's choice for the game, else the runtime that the game needs
    /// (GameCompat) when it is installed, else the default.
    func runtime(for game: Game) -> GameRuntime {
        if runtimeChoice.gameID(game.id) == nil, let required = GameCompat.requiredRuntime(for: game.id),
           let runtime = runtimes.first(where: { $0.id == required }) {
            return runtime
        }
        return runtimeChoice.runtime(for: game.id, in: runtimes)
    }

    /// The note on the game page for a game that runs only with one runtime, or nil.
    func runtimeNote(for game: Game) -> String? {
        guard let required = GameCompat.requiredRuntime(for: game.id) else { return nil }
        let name = "the D3DMetal 4 beta runtime"
        if runtime(for: game).id == required { return nil }
        if runtimes.contains(where: { $0.id == required }) {
            return "\(game.title) runs only with \(name). Choose it in Game settings > Runtime."
        }
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 {
            return "\(game.title) runs only with \(name), which needs macOS 27 or later."
        }
        return "\(game.title) runs only with \(name). Download it in Settings > Runtimes > Game runtime."
    }

    /// The prefix with the saves of a game (tests can override all prefixes).
    func savePrefix(for game: Game) -> URL {
        savePrefixOverride ?? runtime(for: game).prefix
    }

    func reloadRuntimes() {
        guard !demo else { return }
        runtimes = RuntimeCatalog.discover()
    }

    /// The release of an installed runtime (from its runtime.json), or nil.
    func installedRelease(_ id: String) -> Int? {
        guard let runtime = runtimes.first(where: { $0.id == id }),
              let data = try? Data(contentsOf: runtime.root.appendingPathComponent("runtime.json")),
              let manifest = try? JSONDecoder().decode(RuntimeManifest.self, from: data) else { return nil }
        return manifest.release ?? 0
    }

    /// Downloads that are not installed, or that have a newer release.
    var availableDownloads: [RuntimeDownload] {
        guard !demo else { return [] }
        return runtimeDownloadCatalog.filter { download in
            guard runtimes.contains(where: { $0.id == download.id }) else { return true }
            return (installedRelease(download.id) ?? 0) < download.release
        }
    }

    func runtimeRows(for gameID: Game.ID?) -> [RuntimeRow] {
        runtimeRows(for: gameID, family: runtimeFamily)
    }

    /// The rows of one technology (the box under the technology choice).
    func runtimeRows(for gameID: Game.ID?, family: RuntimeFamily) -> [RuntimeRow] {
        let rows: [RuntimeRow] = gameID == nil
            ? runtimes.map { .installed($0) } + availableDownloads.map { .available($0) }
            : runtimes.map { .installed($0) }
        let mine = rows.filter { $0.family == family }
        return gameID == nil ? mine : [.useDefault] + mine
    }

    /// The runtime that the game or the default uses now.
    func chosenRuntime(for gameID: Game.ID?) -> GameRuntime {
        guard let gameID, let game = game(gameID) else { return defaultRuntime }
        return runtime(for: game)
    }

    /// The row in use in the shown technology: "Use the default" for a game without its
    /// own runtime, else the runtime in use. nil when it belongs to the other technology.
    func runtimeRowInUse(for gameID: Game.ID?) -> Int? {
        let rows = runtimeRows(for: gameID)
        guard let chosen = gameID.map({ runtimeChoice.gameID($0) }) ?? defaultRuntime.id else {
            return rows.isEmpty ? nil : 0
        }
        return rows.firstIndex { if case .installed(let r) = $0 { return r.id == chosen }; return false }
    }

    /// The row that gets the focus when the page opens: the row in use, else the first row.
    func selectedRuntimeRow(for gameID: Game.ID?) -> Int {
        runtimeRowInUse(for: gameID) ?? (runtimeRows(for: gameID).isEmpty ? -1 : 0)
    }

    func openRuntimes(gameID: Game.ID?) {
        reloadRuntimes()
        // The page opens on the technology of the runtime in use, with the focus on it.
        runtimeFamily = chosenRuntime(for: gameID).family
        runtimeIndex = selectedRuntimeRow(for: gameID)
        stack.append(.runtimes(gameID))
    }

    /// Shows the runtimes of another technology (left, right, or a click in the top box).
    func selectRuntimeFamily(_ family: RuntimeFamily) {
        guard family != runtimeFamily, case .runtimes = screen else { return }
        runtimeFamily = family
        // The focus stays in the top box.
        runtimeIndex = -1
    }

    func moveRuntimes(_ d: Direction) {
        guard case .runtimes(let gameID) = screen else { return }
        let count = runtimeRows(for: gameID).count
        switch d {
        case .up: runtimeIndex = max(-1, runtimeIndex - 1)
        case .down: runtimeIndex = min(count - 1, runtimeIndex + 1)
        case .left, .right:
            // Left and right switch the technology in the top box only.
            guard runtimeIndex == -1 else { return }
            let all = RuntimeFamily.allCases
            guard let i = all.firstIndex(of: runtimeFamily) else { return }
            let next = d == .right ? min(all.count - 1, i + 1) : max(0, i - 1)
            selectRuntimeFamily(all[next])
        }
    }

    func tapRuntime(_ index: Int) {
        runtimeIndex = index
        chooseRuntime()
    }

    /// A: use the focused runtime, or download it.
    func chooseRuntime() {
        guard case .runtimes(let gameID) = screen else { return }
        let rows = runtimeRows(for: gameID)
        if runtimeIndex == -1 {
            // A in the top box: show the other technology.
            let all = RuntimeFamily.allCases
            if let i = all.firstIndex(of: runtimeFamily) { selectRuntimeFamily(all[(i + 1) % all.count]) }
            return
        }
        guard runtimeIndex >= 0, runtimeIndex < rows.count else { return }
        switch rows[runtimeIndex] {
        case .available(let download):
            downloadRuntime(download)
        case .useDefault:
            guard let gameID, let game = game(gameID) else { return }
            useRuntime(nil, for: game)
        case .installed(let runtime):
            if let problem = runtime.problem {
                showToast(problem, seconds: 8)
                return
            }
            if let gameID, let game = game(gameID) {
                useRuntime(runtime, for: game)
            } else {
                runtimeChoice.defaultID = runtime.id
                objectWillChange.send()
                showToast("New games use \(runtime.displayName).")
            }
        }
    }

    private func useRuntime(_ runtime: GameRuntime?, for game: Game) {
        let target = runtime ?? defaultRuntime
        if let reason = runtimeSwitchBlock(game, to: target) {
            showToast(reason, seconds: 8)
            return
        }
        runtimeChoice.setGame(game.id, runtime?.id)
        objectWillChange.send()
        showToast("\(game.title) uses \(target.displayName).")
    }

    /// A save that is not in the cloud stays in the prefix of the old runtime.
    /// The switch waits until it is uploaded, so that the new prefix gets it.
    func runtimeSwitchBlock(_ game: Game, to target: GameRuntime) -> String? {
        let current = runtime(for: game)
        if playState.gameID == game.id { return "Stop \(game.title) first." }
        guard target.id != current.id, let titleId = game.titleId, savePrefixOverride == nil else { return nil }
        switch CloudSaveStatus.read(titleId: titleId, prefix: current.prefix) {
        case .waiting:
            return "A save of \(game.title) is not uploaded yet. Play it once on \(current.name), so that the save uploads, then switch."
        case .conflict:
            return "\(game.title) has a save conflict. Choose a save at the next start on \(current.name), then switch."
        default:
            return nil
        }
    }

    /// X on the Settings page of runtimes: prepare the focused runtime again.
    func prepareFocusedRuntime() {
        guard case .runtimes(nil) = screen else { return }
        let rows = runtimeRows(for: nil)
        guard runtimeIndex >= 0, runtimeIndex < rows.count, case .installed(let runtime) = rows[runtimeIndex] else { return }
        prepareRuntime(runtime)
    }

    // MARK: Download

    func downloadRuntime(_ download: RuntimeDownload) {
        guard runtimeDownload == nil else {
            showToast("A runtime download is running.")
            return
        }
        guard playState == .idle else {
            showToast("Stop the game first.")
            return
        }
        guard gptkHasD3DMetal else {
            showToast(RuntimeInstallError.noGPTK.errorDescription ?? "", seconds: 8)
            return
        }
        runtimeDownload = RuntimeDownloadState(id: download.id, total: download.size)
        Task {
            do {
                try await fetchRuntime(download, progress: { done, total in
                    guard self.runtimeDownload?.id == download.id else { return }
                    self.runtimeDownload?.done = done
                    if total > 0 { self.runtimeDownload?.total = total }
                }, installing: { self.runtimeDownload?.installing = true })
                showToast("\(download.displayName) is installed. Choose it as the default or on a game page.", seconds: 6)
            } catch {
                showToast(error.localizedDescription, seconds: 8)
            }
            runtimeDownload = nil
        }
    }

    /// True when the Game Porting Toolkit has D3DMetal for a downloaded runtime.
    var gptkHasD3DMetal: Bool {
        FileManager.default.fileExists(atPath: RuntimeInstaller.gptkWine.appendingPathComponent("lib/external/D3DMetal.framework").path)
    }

    /// A native arm64 runtime: three archives, one progress, then the install.
    private func fetchFEXRuntime(_ download: RuntimeDownload, package: FEXPackage,
                                 progress: @escaping @MainActor (Int64, Int64) -> Void,
                                 installing: @escaping @MainActor () -> Void) async throws {
        let temp = FileManager.default.temporaryDirectory
        let files = package.archives.enumerated().map { i, archive in
            temp.appendingPathComponent("iodus-\(download.id)-\(download.release)-\(i).tar.gz")
        }
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }
        let total = package.archives.reduce(0) { $0 + $1.size }
        var before: Int64 = 0
        for (archive, file) in zip(package.archives, files) {
            try Task.checkCancellation()
            let offset = before
            try await RuntimeSetup.download(url: archive.url, size: archive.size, to: file) { done, _ in
                Task { @MainActor in progress(offset + done, total) }
            }
            before += archive.size
        }
        try Task.checkCancellation()
        installing()
        let runtimesFolder = RuntimeCatalog.runtimesFolder
        try await Task.detached {
            for (archive, file) in zip(package.archives, files) {
                try RuntimeSetup.verify(file, sha256: archive.sha256)
            }
            try RuntimeInstaller.installFEX(engine: files[0], renderers: files[1], kosmickrisp: files[2],
                                            download: download, runtimes: runtimesFolder)
        }.value
        reloadRuntimes()
    }

    /// Downloads, checks, and installs a runtime, then reloads the list.
    /// Settings and the setup use it. The archive is removed in all cases.
    func fetchRuntime(_ download: RuntimeDownload,
                      progress: @escaping @MainActor (Int64, Int64) -> Void,
                      installing: @escaping @MainActor () -> Void) async throws {
        // A beta runtime brings its own D3DMetal; the others copy it from GPTK. A native
        // arm64 (FEX) runtime has no D3DMetal.
        if download.d3dmetal == nil, download.fex == nil { guard gptkHasD3DMetal else { throw RuntimeInstallError.noGPTK } }
        if let free = Bytes.freeSpace(at: GameRuntime.support), free < download.neededBytes {
            throw RuntimeSetupError.notEnoughSpace(needed: download.neededBytes, free: free)
        }
        if let fex = download.fex {
            try await fetchFEXRuntime(download, package: fex, progress: progress, installing: installing)
            return
        }
        let shim = GameRuntime.standard.componentFolder.appendingPathComponent("compat/highball-d3d12-shim.dll")
        if download.d3dmetal != nil, !FileManager.default.fileExists(atPath: shim.path) {
            throw RuntimeInstallError.badPackage("This build of iOdus has no d3d12 layer for D3DMetal 4.")
        }
        let temp = FileManager.default.temporaryDirectory
        let archive = temp.appendingPathComponent("iodus-\(download.id)-\(download.release).tar.xz")
        let d3dmetalArchive = download.d3dmetal.map { temp.appendingPathComponent("iodus-d3dmetal-\($0.version).tar.xz") }
        defer {
            try? FileManager.default.removeItem(at: archive)
            if let d3dmetalArchive { try? FileManager.default.removeItem(at: d3dmetalArchive) }
        }
        let extra = download.d3dmetal?.size ?? 0
        let total = download.size + extra
        try await RuntimeSetup.download(url: download.url, size: download.size, to: archive) { done, _ in
            Task { @MainActor in progress(done, total) }
        }
        if let package = download.d3dmetal, let d3dmetalArchive {
            try Task.checkCancellation()
            try await RuntimeSetup.download(url: package.url, size: package.size, to: d3dmetalArchive) { done, _ in
                Task { @MainActor in progress(download.size + done, total) }
            }
        }
        try Task.checkCancellation()
        installing()
        let runtimesFolder = RuntimeCatalog.runtimesFolder
        try await Task.detached {
            try RuntimeSetup.verify(archive, sha256: download.sha256)
            if let package = download.d3dmetal, let d3dmetalArchive {
                try RuntimeSetup.verify(d3dmetalArchive, sha256: package.sha256)
            }
            try RuntimeInstaller.install(archive: archive, download: download, runtimes: runtimesFolder,
                                         d3dmetalArchive: d3dmetalArchive, shim: shim)
        }.value
        reloadRuntimes()
    }
}
