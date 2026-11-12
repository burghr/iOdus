import CryptoKit
import Foundation

/// The description of a runtime folder: `Runtimes/<id>/runtime.json`.
/// Paths are relative to the runtime folder.
struct RuntimeManifest: Codable, Equatable, Sendable {
    var id: String
    var name: String                    // "CrossOver 26.3 Wine"
    var wineVersion: String             // "11.0"
    var wine: String                    // "bin/wine"
    var wineserver: String              // "bin/wineserver"
    var libraries: String?              // "lib": DYLD_FALLBACK_LIBRARY_PATH for GnuTLS and FreeType
    var components: [String]            // iOdus DLLs for system32 (from the app bundle)
    var overrides: [String: String]     // Wine DLL overrides that the prefix setup sets
    var register: [String]?             // DLLs for regsvr32
    var propertySet: String?            // DLL for Windows.Foundation.Collections.PropertySet, if Wine has none
    var environment: [String: String]?  // Extra variables; "{root}" is the runtime folder
    var release: Int?                   // The package release; a higher one is an update
    var d3dmetal: D3DMetalFiles?        // Apple's files that iOdus copies from the installed GPTK
    var inputGate: Bool?                // The controller driver honors C:\.iodus-input-gate (see InputGate)
    var overlay: RuntimeOverlay?        // iOdus DLLs that come before Wine's own DLLs (native arm64 runtimes)
    var signedLoader: String?           // Path that must link to the app's signed Wine loader (native arm64 runtimes)
}

/// iOdus DLLs in a DLL folder that Wine searches before its own DLLs
/// (WINEDLLPATH_PREPEND of the Highball arm64 engine). An x86-64 game loads
/// these x86-64 builds through the emulator, in place of Wine's own builtins.
struct RuntimeOverlay: Codable, Equatable, Sendable {
    var folder: String                  // "xbox/wine/aarch64-windows", relative to the runtime folder
    var files: [String: String]         // file name in the folder -> iOdus DLL ("wintypes.dll": "iodus_wintypes.dll")
}

/// The D3DMetal files of a runtime. They are not in the runtime package: iOdus
/// copies them from the Game Porting Toolkit that the player installed.
struct D3DMetalFiles: Codable, Equatable, Sendable {
    var windows: [String]               // lib/wine/x86_64-windows
    var unix: [String]                  // lib/wine/x86_64-unix (links to ../../external/libd3dshared.dylib)
}

/// A Wine runtime that starts games: a Wine build, the Xbox runtime DLLs
/// from scripts/build-runtime.sh, and the Wine prefix of that runtime.
/// Two Wine versions never share a prefix.
struct GameRuntime: Sendable, Equatable {
    let id: String
    let name: String
    let wineVersion: String
    let root: URL                       // The runtime folder
    let wine64: URL                     // The Wine program (wine64 on Wine 7.7, wine on Wine 11)
    let wineserver: URL
    let prefix: URL
    var libraries: URL?
    var componentNames: [String]
    var overrides: [(String, String)]
    var register: [String]
    var propertySet: String?
    var extraEnvironment: [String: String] = [:]
    /// The iOdus DLLs for a development build (no app bundle), and whether the
    /// DLLs of the app bundle take its place. A test runtime never uses the bundle.
    var componentRoot: URL
    var usesBundle: Bool
    /// True when the controller driver of the runtime stops the game input while
    /// the gate file exists (the iOdus overlay is open). GPTK Wine 7.7 has no gate.
    var inputGate = false
    /// The overlay folder and its files (file name -> iOdus DLL), if the runtime has one.
    var overlayFolder: URL?
    var overlayFiles: [String: String] = [:]
    /// The path in the runtime that must be a link to the app's signed Wine loader.
    var signedLoaderLink: URL?

    /// The gate file: while it exists, the game gets no controller input.
    var inputGateFile: URL { prefix.appendingPathComponent("drive_c/.iodus-input-gate") }

    static func == (a: GameRuntime, b: GameRuntime) -> Bool { a.id == b.id && a.root == b.root && a.prefix == b.prefix }

    static let wineBundle = "gptk-3.0-3/Game Porting Toolkit.app/Contents/Resources/wine"
    static let gptkID = "gptk-3.0-3"

    /// All iOdus DLLs. A runtime uses a part of them (`componentNames`).
    static let components = [
        "xgameruntime.dll",
        "windows.web.dll",
        "twinapi.appcore.dll",
        "iodus_wintypes.dll",
        "api-ms-win-core-psm-appnotify-l1-1-0.dll",
        // GPTK only: Wine 11 has this API set in its schema (wine11-patches).
        "api-ms-win-core-debug-minidump-l1-1-0.dll",
        "d3d11.dll",   // The iOdus proxy in front of the D3DMetal d3d11.dll
        "winhttp.dll", // The iOdus proxy in front of the GPTK winhttp.dll (WINHTTP_OPTION_URL)
    ]

    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iOdus", isDirectory: true)
    }

    /// The GPTK 3.0 runtime (Wine 7.7). Its folders stay where they were before
    /// iOdus had more than one runtime: `Runtime` and `Prefix`.
    static let standard = gptk(root: support.appendingPathComponent("Runtime", isDirectory: true),
                               prefix: support.appendingPathComponent("Prefix", isDirectory: true))

    static func gptk(root: URL, prefix: URL) -> GameRuntime {
        let wine = root.appendingPathComponent(wineBundle, isDirectory: true)
        return GameRuntime(
            id: gptkID, name: "Game Porting Toolkit 3.0", wineVersion: "7.7", root: root,
            wine64: wine.appendingPathComponent("bin/wine64"), wineserver: wine.appendingPathComponent("bin/wineserver"),
            prefix: prefix, libraries: nil, componentNames: components,
            overrides: [("api-ms-win-core-psm-appnotify-l1-1-0", "native"),
                        // The proxy d3d11.dll in system32 first; it loads the D3DMetal one itself.
                        ("d3d11", "native,builtin"),
                        // The proxy winhttp.dll first; it loads the GPTK one itself. Without it,
                        // Xbox Live requests of the game (libHttpClient, XCurl) fail.
                        ("winhttp", "native,builtin")],
            register: ["windows.web.dll"], propertySet: "iodus_wintypes.dll",
            componentRoot: root.appendingPathComponent("components", isDirectory: true),
            usesBundle: root == support.appendingPathComponent("Runtime", isDirectory: true))
    }

    /// A runtime from a runtime folder with a runtime.json.
    static func from(manifest m: RuntimeManifest, root: URL, prefix: URL,
                     componentRoot: URL = standard.componentRoot, usesBundle: Bool = true) -> GameRuntime {
        GameRuntime(id: m.id, name: m.name, wineVersion: m.wineVersion, root: root,
                    wine64: root.appendingPathComponent(m.wine), wineserver: root.appendingPathComponent(m.wineserver),
                    prefix: prefix, libraries: m.libraries.map { root.appendingPathComponent($0, isDirectory: true) },
                    componentNames: m.components.filter { components.contains($0) },
                    overrides: m.overrides.sorted { $0.key < $1.key }.map { ($0.key, $0.value) },
                    register: m.register ?? [], propertySet: m.propertySet,
                    extraEnvironment: (m.environment ?? [:]).mapValues {
                        $0.replacingOccurrences(of: "{root}", with: root.path).replacingOccurrences(of: "{prefix}", with: prefix.path)
                    },
                    componentRoot: componentRoot, usesBundle: usesBundle, inputGate: m.inputGate ?? false,
                    overlayFolder: m.overlay.map { root.appendingPathComponent($0.folder, isDirectory: true) },
                    overlayFiles: (m.overlay?.files ?? [:]).filter { components.contains($0.value) && RuntimeCatalog.isValidID($0.key) },
                    signedLoaderLink: m.signedLoader.map { root.appendingPathComponent($0) })
    }

    /// A runtime that starts through the app's signed loader is a native arm64 (FEX) runtime.
    var family: RuntimeFamily { signedLoaderLink == nil ? .d3dmetal : .fex }

    /// "Game Porting Toolkit 3.0 (Wine 7.7)"
    var displayName: String { "\(name) (Wine \(wineVersion))" }

    /// The Xbox runtime DLLs: in the app bundle (Contents/Resources/runtime), or
    /// in `componentRoot` for a development build or a test.
    var componentFolder: URL {
        if usesBundle, let bundled = Self.bundledComponents { return bundled }
        return componentRoot
    }

    static var bundledComponents: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("runtime", isDirectory: true),
              FileManager.default.fileExists(atPath: url.appendingPathComponent(components[0]).path) else { return nil }
        return url
    }
    var marker: URL { prefix.appendingPathComponent(".iodus-runtime") }

    /// The signed Wine loader of the app (Contents/Helpers/WineLoader.app). Only a
    /// loader with Apple's cross-architecture entitlement can run x86-64 code in a
    /// native arm64 Wine. IODUS_WINE_LOADER names one for a development build.
    static var signedLoader: URL? {
        let fm = FileManager.default
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/WineLoader.app/Contents/MacOS/wine")
        if fm.isExecutableFile(atPath: helper.path) { return helper }
        if let path = ProcessInfo.processInfo.environment["IODUS_WINE_LOADER"], fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Points the runtime's loader link at the app's signed loader. The app can
    /// move or change, so this runs before each start. Returns true when it changed the link.
    @discardableResult
    func linkSignedLoader(to loader: URL? = GameRuntime.signedLoader) throws -> Bool {
        guard let link = signedLoaderLink, let loader else { return false }
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == loader.path { return false }
        if (try? fm.attributesOfItem(atPath: link.path)) != nil || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try fm.removeItem(at: link)
        }
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: loader)
        return true
    }

    /// Copies the iOdus DLLs of the overlay from the app when they are missing or
    /// different (a new app version). Returns true when it changed a file.
    @discardableResult
    func updateOverlay() throws -> Bool {
        guard let overlayFolder, !overlayFiles.isEmpty else { return false }
        let fm = FileManager.default
        try fm.createDirectory(at: overlayFolder, withIntermediateDirectories: true)
        var changed = false
        for (file, component) in overlayFiles.sorted(by: { $0.key < $1.key }) {
            let data = try Data(contentsOf: componentFolder.appendingPathComponent(component))
            let target = overlayFolder.appendingPathComponent(file)
            if let installed = try? Data(contentsOf: target), installed == data { continue }
            try data.write(to: target, options: .atomic)
            changed = true
        }
        return changed
    }

    /// The d3d12.dll layer of the app (RuntimeInstaller.addD3DMetal4).
    var d3d12LayerSource: URL { componentFolder.appendingPathComponent("compat/highball-d3d12-shim.dll") }
    /// The copy of the layer in a D3DMetal 4 runtime, in front of Apple's d3d12.dll.
    var d3d12LayerTarget: URL { root.appendingPathComponent("lib/wine/x86_64-windows/d3d12.dll") }

    /// The installer copies the d3d12.dll layer into a D3DMetal 4 runtime only one time.
    /// A new app can bring a new layer, so this function copies the layer again
    /// when the two files are different. Other runtimes have no layer.
    /// Returns true when it changed the file in the runtime.
    @discardableResult
    func updateD3D12Layer() throws -> Bool {
        guard extraEnvironment["WINE_BUILTIN_BY_FILE_NAME"] == RuntimeInstaller.renamedD3D12,
              FileManager.default.fileExists(atPath: d3d12LayerSource.path) else { return false }
        let layer = try Data(contentsOf: d3d12LayerSource)
        if let installed = try? Data(contentsOf: d3d12LayerTarget), installed == layer { return false }
        // The atomic write puts a new file in place of the old file.
        // A Wine process that runs keeps the old file open.
        try layer.write(to: d3d12LayerTarget, options: .atomic)
        return true
    }

    /// Why the runtime cannot start games, or nil when all parts exist.
    var problem: String? {
        problem(signedLoader: Self.signedLoader)
    }

    /// The problem with a given signed loader of the app (a test passes its own).
    func problem(signedLoader: URL?) -> String? {
        let fm = FileManager.default
        if signedLoaderLink != nil {
            // The Wine program goes through the loader link, which iOdus makes at the start.
            if signedLoader == nil {
                return "This build of iOdus has no signed Wine loader, so it cannot start native arm64 runtimes."
            }
            if !fm.isExecutableFile(atPath: wineserver.path) {
                return "The Wine of \(displayName) is missing in \(root.path)."
            }
        } else if !fm.isExecutableFile(atPath: wine64.path) {
            return id == Self.gptkID ? "The Game Porting Toolkit Wine is missing in \(root.path)."
                : "The Wine of \(displayName) is missing in \(root.path)."
        }
        let missing = componentNames.filter {
            !fm.fileExists(atPath: componentFolder.appendingPathComponent($0).path)
        }
        if !missing.isEmpty {
            return "Runtime DLLs are missing: \(missing.joined(separator: ", ")). Run scripts/build-runtime.sh."
        }
        return nil
    }

    /// A hash of the component files and the setup steps. A new build of the
    /// DLLs or a changed runtime.json changes it, so that the prefix setup runs again.
    func componentHash() throws -> String {
        var hasher = SHA256()
        for name in componentNames {
            hasher.update(data: Data(name.utf8))
            hasher.update(data: try Data(contentsOf: componentFolder.appendingPathComponent(name)))
        }
        // The GPTK hash stays the same as before (no setup data), so that its prefix is not prepared again.
        if id != Self.gptkID {
            for (key, value) in overrides { hasher.update(data: Data("\(key)=\(value)".utf8)) }
            for name in register { hasher.update(data: Data("register \(name)".utf8)) }
            if let propertySet { hasher.update(data: Data("propertyset \(propertySet)".utf8)) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    var isPrepared: Bool {
        guard let saved = try? String(contentsOf: marker, encoding: .utf8),
              let current = try? componentHash() else { return false }
        return saved == current
    }

    /// The environment for Wine and for `xodus-cli run`.
    func environment(extra: [String: String] = [:], removing: [String] = []) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefix.path
        env["WINEDEBUG"] = env["IODUS_WINEDEBUG"] ?? "-all"
        // Rosetta runs AVX, AVX2, FMA, F16C, BMI1, and BMI2 code, but it reports
        // these features in CPUID only with this variable. Without them, some
        // games fail: Forza Horizon 6 stops with "illegal instruction" in its
        // own encrypted code. IODUS_ROSETTA_AVX=0 turns it off for a test.
        if env["IODUS_ROSETTA_AVX"] != "0" { env["ROSETTA_ADVERTISE_AVX"] = "1" }
        // A runtime with its own GnuTLS and FreeType: Wine loads them with dlopen.
        if let libraries {
            env["DYLD_FALLBACK_LIBRARY_PATH"] = [libraries.path, env["DYLD_FALLBACK_LIBRARY_PATH"] ?? "/usr/lib"]
                .joined(separator: ":")
        }
        for (key, value) in extraEnvironment { env[key] = value }
        for (key, value) in extra { env[key] = value }
        for key in removing { env[key] = nil }
        return env
    }

    /// Makes the prefix and installs the Xbox runtime into it:
    /// 1. wineboot makes the prefix.
    /// 2. The DLLs of the runtime go into system32.
    /// 3. The DLL overrides of the runtime (GPTK: the app state API set, the
    ///    d3d11 proxy, and the winhttp proxy).
    /// 4. regsvr32 registers the DLLs of the runtime (GPTK: windows.web.dll).
    /// 5. PropertySet goes to a Wine 11 wintypes copy, if the runtime needs it.
    func prepare(log: @escaping @Sendable (String) -> Void) async throws {
        if let problem { throw BackendError.failed(problem) }
        let hash = try componentHash()
        let fm = FileManager.default
        try fm.createDirectory(at: prefix, withIntermediateDirectories: true)

        try linkSignedLoader()
        try updateOverlay()
        log("Preparing the Wine prefix")
        // Without Wine Mono and Wine Gecko, wineboot asks to download them in a
        // dialog. GDK games are native programs and need neither (.NET, web views).
        try await wine(["wineboot", "--init"], extra: ["WINEDLLOVERRIDES": "mscoree=;mshtml="])
        let system32 = prefix.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        guard fm.fileExists(atPath: system32.path) else {
            throw BackendError.failed("Wine did not make the prefix in \(prefix.path).")
        }

        log("Installing the Xbox runtime")
        for name in componentNames {
            let target = system32.appendingPathComponent(name)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: componentFolder.appendingPathComponent(name), to: target)
        }
        for (dll, value) in overrides {
            try await wine(["reg", "add", #"HKCU\Software\Wine\DllOverrides"#, "/v", dll, "/d", value, "/f"])
        }
        // /s: no message box ("Successfully registered DLL") on newer Wine.
        // regsvr32 is a native program: it registers Wine's own DLL, not the x86-64 one of the overlay.
        for dll in register {
            try await wine(["regsvr32", "/s", dll], removing: overlayFolder == nil ? [] : ["WINEDLLPATH_PREPEND"])
        }
        if let propertySet {
            try await wine(["reg", "add",
                            #"HKLM\Software\Microsoft\WindowsRuntime\ActivatableClassId\Windows.Foundation.Collections.PropertySet"#,
                            "/v", "DllPath", "/d", #"C:\windows\system32\"# + propertySet, "/f"])
        }
        // Wait until wineserver writes the registry files.
        _ = try await XodusCLI.runProcess(wineserver, ["-w"], environment: environment(), timeout: 60)
        try hash.write(to: marker, atomically: true, encoding: .utf8)
        log("The game runtime is ready")
    }

    /// The wine.inf of the runtime. Its modification time decides when Wine updates
    /// the prefix (both runtimes have bin/<wine> next to share/wine).
    var wineInf: URL {
        wine64.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("share/wine/wine.inf")
    }

    /// True when Wine would update the prefix at the next start: the prefix file
    /// .update-timestamp does not hold the modification time of wine.inf. This
    /// happens after a new build of the runtime. Wine's own update would ask to
    /// download Wine Mono in a dialog, so iOdus does the update first.
    func needsWineUpdate() -> Bool {
        Self.needsWineUpdate(prefix: prefix, wineInf: wineInf)
    }

    nonisolated static func needsWineUpdate(prefix: URL, wineInf: URL) -> Bool {
        let fm = FileManager.default
        guard let date = (try? fm.attributesOfItem(atPath: wineInf.path))?[.modificationDate] as? Date,
              fm.fileExists(atPath: prefix.appendingPathComponent("drive_c").path) else { return false }
        let stamp = (try? String(contentsOf: prefix.appendingPathComponent(".update-timestamp"), encoding: .utf8)) ?? ""
        if stamp.hasPrefix("disable") { return false }
        return UInt64(stamp.trimmingCharacters(in: .whitespacesAndNewlines)) != UInt64(date.timeIntervalSince1970)
    }

    /// The prefix update of Wine (wineboot -u), without the Wine Mono and Wine Gecko
    /// download dialogs. GDK games need neither.
    func updatePrefix() async throws {
        try await wine(["wineboot", "-u"], extra: ["WINEDLLOVERRIDES": "mscoree=;mshtml="])
        _ = try await XodusCLI.runProcess(wineserver, ["-w"], environment: environment(), timeout: 60)
    }

    func wine(_ arguments: [String], extra: [String: String] = [:], removing: [String] = []) async throws {
        let result = try await XodusCLI.runProcess(wine64, arguments, environment: environment(extra: extra, removing: removing),
                                                   timeout: 300)
        if result.timedOut { throw BackendError.failed("Wine did not finish \(arguments[0]) in time.") }
        guard result.status == 0 else {
            throw BackendError.failed("Wine \(arguments[0]) failed: \(XodusCLI.message(from: result.stderr))")
        }
    }

    /// Stops all Wine processes of the prefix.
    /// Closes a game the Windows way: taskkill without /f sends WM_CLOSE to the
    /// windows of the process. The game then shuts down, and the runtime
    /// removes the Xbox title presence. A kill from outside cannot do that.
    func closeGame(image: String) async {
        _ = try? await XodusCLI.runProcess(wine64, ["taskkill", "/im", image], environment: environment(), timeout: 30)
    }

    /// The Wine path of a Mac file: "/Users/a/b" -> "Z:\\Users\\a\\b".
    static func windowsPath(_ url: URL) -> String {
        "Z:" + url.path.replacingOccurrences(of: "/", with: "\\")
    }

    /// Uploads the saves that a game wrote just before it ended. The runtime
    /// helper (rundll32 xgameruntime.dll,XodusSyncSaves) signs in silently and
    /// runs the same save sync as a game start, without the title presence.
    /// Returns the "iodus-savesync: ..." line, or nil.
    func syncSaves(config: URL, extra: [String: String]) async -> String? {
        var extra = extra
        extra["IODUS_PRESENCE"] = "0"
        let result = try? await XodusCLI.runProcess(wine64, ["rundll32", "xgameruntime.dll,XodusSyncSaves", Self.windowsPath(config)],
                                                    environment: environment(extra: extra), timeout: 180)
        return result?.stderr.split(whereSeparator: \.isNewline)
            .first { $0.contains("iodus-savesync:") }.map(String.init)
    }

    func killWineserver() async {
        _ = try? await XodusCLI.runProcess(wineserver, ["-k"], environment: environment(), timeout: 30)
    }

    // MARK: Retina mode

    /// The Retina mode that iOdus last wrote into the prefix ("y" or "n").
    var retinaMarker: URL { prefix.appendingPathComponent(".iodus-retina") }

    /// True when the prefix must change. No marker means Wine's default: off.
    static func retinaNeedsChange(marker: String?, wanted: Bool) -> Bool {
        (marker?.hasPrefix("y") ?? false) != wanted
    }

    /// Sets Wine's Retina mode for the next game. Call it only when no game runs:
    /// the Wine processes of the prefix stop, so that all of them use the new screen size.
    func applyRetinaMode(_ on: Bool) async throws {
        let marker = try? String(contentsOf: retinaMarker, encoding: .utf8)
        guard Self.retinaNeedsChange(marker: marker, wanted: on) else { return }
        try await wine(["reg", "add", #"HKCU\Software\Wine\Mac Driver"#, "/v", "RetinaMode", "/d", on ? "y" : "n", "/f"])
        await killWineserver()
        try (on ? "y" : "n").write(to: retinaMarker, atomically: true, encoding: .utf8)
    }

    // MARK: Gaming Services version

    /// The Gaming Services version that iOdus reports: 38.117.27001.0. Games such
    /// as Forza Horizon 6 read it from the registry and stop with "Invalid Gaming
    /// Services Detected" when it is missing or old. This is only a version
    /// number in the prefix, not an installed Microsoft service. Xodus Nexus
    /// found the key and the value (xodus-nexus PR #15,
    /// scripts/runtime-compat/gaming-services-version.c, MIT).
    static let gamingServicesVersion = "38.117.27001.0"
    static let gamingServicesKey = #"HKLM\SOFTWARE\Microsoft\GamingServices"#

    /// The version as the registry keeps it: a QWORD with 16 bits for each part.
    static func packedVersion(_ text: String) -> UInt64? {
        let parts = text.split(separator: ".").compactMap { UInt64($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 <= 0xFFFF }) else { return nil }
        return parts.reduce(0) { ($0 << 16) | $1 }
    }

    var gamingServicesMarker: URL { prefix.appendingPathComponent(".iodus-gaming-services") }

    /// Writes CurrentVersion and AvailableVersion once for each prefix and version.
    func applyGamingServicesVersion() async throws {
        let marker = try? String(contentsOf: gamingServicesMarker, encoding: .utf8)
        guard marker != Self.gamingServicesVersion,
              let value = Self.packedVersion(Self.gamingServicesVersion) else { return }
        for name in ["CurrentVersion", "AvailableVersion"] {
            try await wine(["reg", "add", Self.gamingServicesKey, "/v", name, "/t", "REG_QWORD",
                            "/d", String(value), "/f"])
        }
        try Self.gamingServicesVersion.write(to: gamingServicesMarker, atomically: true, encoding: .utf8)
    }
}

/// Unity games. D3DMetal crashes on a focus change (Cmd+Tab) when a game uses
/// exclusive full screen. Borderless full screen does not crash, so iOdus
/// asks Unity for borderless full screen.
struct UnityGame: Equatable {
    let company: String
    let product: String

    /// The Unity value of the window mode. The hash suffix is fixed for this name.
    /// 0 = exclusive full screen, 1 = full screen window, 2 = maximized, 3 = windowed.
    static let modeValue = "Screenmanager Fullscreen mode_h3630240806"

    /// Unity start options: every full-screen request uses a borderless window.
    static let arguments = ["-window-mode", "borderless"]

    var registryKey: String { #"HKCU\Software\"# + company + #"\"# + product }

    /// A Unity game has UnityPlayer.dll and <Name>_Data/app.info (company, then product).
    static func detect(in folder: URL) -> UnityGame? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path),
              names.contains(where: { $0.lowercased() == "unityplayer.dll" }) else { return nil }
        for name in names where name.hasSuffix("_Data") {
            let info = folder.appendingPathComponent(name).appendingPathComponent("app.info")
            guard let text = try? String(contentsOf: info, encoding: .utf8) else { continue }
            if let game = parse(appInfo: text) { return game }
        }
        return nil
    }

    static func parse(appInfo text: String) -> UnityGame? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, !lines[0].isEmpty, !lines[1].isEmpty else { return nil }
        // A registry key name cannot hold a backslash. Refuse odd values.
        guard !lines[0].contains("\\"), !lines[1].contains("\\") else { return nil }
        return UnityGame(company: lines[0], product: lines[1])
    }

    /// Reads the mode from `reg query` output, for example "REG_DWORD    0x0".
    static func mode(fromQuery output: String) -> Int? {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.contains(modeValue) }),
              let hex = line.split(separator: " ").last(where: { $0.hasPrefix("0x") }) else { return nil }
        return Int(hex.dropFirst(2), radix: 16)
    }
}

extension GameRuntime {
    /// Changes exclusive full screen (0) to a full screen window (1). Other modes stay.
    func preferBorderless(_ game: UnityGame) async {
        let query = try? await XodusCLI.runProcess(wine64, ["reg", "query", game.registryKey, "/v", UnityGame.modeValue],
                                                   environment: environment(), timeout: 60)
        guard let query, query.status == 0,
              UnityGame.mode(fromQuery: String(decoding: query.stdout, as: UTF8.self)) == 0 else { return }
        _ = try? await XodusCLI.runProcess(wine64, ["reg", "add", game.registryKey, "/v", UnityGame.modeValue,
                                                    "/t", "REG_DWORD", "/d", "1", "/f"],
                                           environment: environment(), timeout: 60)
    }
}

/// Reads the start executable from MicrosoftGame.Config.
enum GameConfig {
    /// The `Name` of the `<Executable>` with `Id="Game"`, else the first one.
    static func executable(in gameFolder: URL) -> String? {
        guard let file = configFile(in: gameFolder),
              let data = FileManager.default.contents(atPath: file.path) else { return nil }
        return executable(fromConfig: data)
    }

    /// The MicrosoftGame.config file of a game folder (the name case can differ).
    static func configFile(in gameFolder: URL) -> URL? {
        guard let name = (try? FileManager.default.contentsOfDirectory(atPath: gameFolder.path))?
                .first(where: { $0.lowercased() == "microsoftgame.config" }) else { return nil }
        return gameFolder.appendingPathComponent(name)
    }

    static func executable(fromConfig data: Data) -> String? {
        let delegate = ExecutableParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        let all = delegate.executables
        let chosen = all.first { $0.id?.caseInsensitiveCompare("Game") == .orderedSame } ?? all.first
        guard let name = chosen?.name, isSafeRelativePath(name) else { return nil }
        return name
    }

    /// A relative path without "..", so that a config cannot point outside the game.
    static func isSafeRelativePath(_ name: String) -> Bool {
        let parts = name.split(whereSeparator: { $0 == "\\" || $0 == "/" })
        return !name.isEmpty && !name.hasPrefix("/") && !name.hasPrefix("\\") && !name.contains(":")
            && !parts.isEmpty && !parts.contains("..")
    }

    private final class ExecutableParser: NSObject, XMLParserDelegate {
        var executables: [(name: String?, id: String?)] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            guard elementName == "Executable" else { return }
            executables.append((attributes["Name"], attributes["Id"]))
        }
    }
}
