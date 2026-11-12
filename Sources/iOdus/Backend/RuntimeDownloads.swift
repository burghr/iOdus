import Foundation

/// Apple's D3DMetal as a release file of the iOdus repository: the unchanged
/// `redist` folder of a Game Porting Toolkit with Apple's license files. Apple's
/// license allows its free, non-commercial distribution (sections 2A and 2C).
struct D3DMetalPackage: Sendable, Equatable {
    let version: String                 // "4.0b3"
    let url: URL
    let sha256: String
    let size: Int64
    let folder: String                  // The top folder in the archive
}

/// One release file of a native arm64 (FEX) runtime.
struct FEXArchive: Sendable, Equatable {
    let url: URL
    let sha256: String
    let size: Int64
}

/// The three release files of a native arm64 runtime, from the Highball arm64
/// engine (https://github.com/gauthierpiarrette/highball-engine), hosted
/// unchanged in an iOdus release: the engine (Wine 11.18 for Apple silicon with
/// FEX), vkd3d-proton and DXVK, and KosmicKrisp with the Khronos Vulkan loader.
/// RuntimeInstaller.installFEX makes the runtime folder from them.
struct FEXPackage: Sendable, Equatable {
    let engine: FEXArchive
    let renderers: FEXArchive
    let kosmickrisp: FEXArchive
    var archives: [FEXArchive] { [engine, renderers, kosmickrisp] }
}

/// A runtime that iOdus can download: a release file of the iOdus repository,
/// made by scripts/build-wine-runtime.sh (STAGE=package). The package has no
/// D3DMetal; iOdus adds it from the installed Game Porting Toolkit, or from a
/// D3DMetal package (`d3dmetal`) for a beta runtime.
struct RuntimeDownload: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let wineVersion: String
    let release: Int
    let url: URL
    let sha256: String
    let size: Int64                     // The archive
    let unpackedBytes: Int64            // On disk after the install
    /// The runtime ID inside the archive, when this download is a variant of it.
    var baseID: String? = nil
    /// D3DMetal from a D3DMetal package instead of the installed GPTK.
    var d3dmetal: D3DMetalPackage? = nil
    /// The oldest macOS major version that can run it (D3DMetal 4: macOS 27).
    var minimumMacOS: Int? = nil
    /// A native arm64 runtime from three archives (url, sha256 and size are the engine's).
    var fex: FEXPackage? = nil

    var displayName: String { "\(name) (Wine \(wineVersion))" }
    var neededBytes: Int64 {
        if let fex { return fex.archives.reduce(0) { $0 + $1.size } + unpackedBytes }
        return size + unpackedBytes + (d3dmetal?.size ?? 0) * 3
    }
    var isBeta: Bool { d3dmetal != nil || fex != nil }
    var family: RuntimeFamily { fex == nil ? .d3dmetal : .fex }

    static let crossover = RuntimeDownload(
        id: "crossover-26.3", name: "CrossOver 26.3 Wine", wineVersion: "11.0", release: 6,
        url: URL(string: "https://github.com/burghr/iOdus/releases/download/v0.1.8/crossover-26.3-6.tar.xz")!,
        sha256: "aff0279fd1026e4463ae3e2ab1da2bf056ca673e94de2ef6fc75cc1732cbd41d",
        size: 277_365_752, unpackedBytes: 1_600_000_000)

    /// The D3DMetal 4 beta runtime: the same Wine package, with D3DMetal 4 from
    /// Game Porting Toolkit 4 and the d3d12.dll layer. Forza Horizon 6 needs it.
    static let crossoverD3DMetal4 = d3dmetal4Variant(of: crossover, d3dmetal: d3dmetal4)

    static let d3dmetal4 = D3DMetalPackage(
        version: "4.0b3",
        url: URL(string: "https://github.com/burghr/iOdus/releases/download/v0.1.4/d3dmetal-4.0b3.tar.xz")!,
        sha256: "290cd7731de7721da1c1c25b3b1bd2245cf19d8591a5f40cbf2b04849f96455b",
        size: 16_556_056, folder: "d3dmetal-4.0b3")

    static func d3dmetal4Variant(of base: RuntimeDownload, d3dmetal: D3DMetalPackage) -> RuntimeDownload {
        var variant = RuntimeDownload(id: "\(base.id)-d3dm4", name: "\(base.name) + D3DMetal 4 (beta)",
                                      wineVersion: base.wineVersion, release: base.release, url: base.url,
                                      sha256: base.sha256, size: base.size, unpackedBytes: base.unpackedBytes)
        variant.baseID = base.id
        variant.d3dmetal = d3dmetal
        variant.minimumMacOS = 27
        return variant
    }

    /// The native arm64 runtimes (FEX). The release files are Highball's, unchanged,
    /// except the engine of the alpha runtime: Highball's r5 source with patch 0058
    /// (burghr/highball-engine, branch iodus-alpha), until Highball has the fix.
    static let fexRelease = "https://github.com/burghr/iOdus/releases/download/v0.1.9/"
    static let fexRenderers = FEXArchive(
        url: URL(string: fexRelease + "renderers-arm64-20261031T230303Z-manual.tar.gz")!,
        sha256: "1b101d93ad23ec72a89216388f250afcbd9b64babb49f21cc5feccea05fbac37", size: 11_818_314)
    static let fexKosmicKrisp = FEXArchive(
        url: URL(string: fexRelease + "kosmickrisp-arm64-20261104T165852Z-push.tar.gz")!,
        sha256: "c88f1067802569b6db055b83884d62bd178c11b778977501a545ed724520ecae", size: 2_544_432)

    static let highballArm64 = fexRuntime(
        id: "highball-arm64-r5", name: "Highball arm64 engine",
        engine: FEXArchive(url: URL(string: fexRelease + "engine-arm64-wine-11.18-20261108T132317Z-spatial-0056-0057.tar.gz")!,
                           sha256: "6721b1f4ee2665283f7c16e4e0b3cf5737c454399fac3d74657fde181d148f33", size: 402_959_865))
    static let highballArm64Alpha = fexRuntime(
        id: "highball-arm64-r5-alpha", name: "iOdus patched (alpha)",
        engine: FEXArchive(url: URL(string: fexRelease + "engine-arm64-wine-11.18-20261112T050227Z-iodus-alpha-r5-0058.tar.gz")!,
                           sha256: "a5b92ddcd9682dfb4d25312baca512fd2893e790ac7df8c0cd509d46b1a54376", size: 402_960_205))

    static func fexRuntime(id: String, name: String, engine: FEXArchive, release: Int = 1) -> RuntimeDownload {
        var download = RuntimeDownload(id: id, name: name, wineVersion: "11.18", release: release, url: engine.url,
                                       sha256: engine.sha256, size: engine.size, unpackedBytes: 1_300_000_000)
        download.fex = FEXPackage(engine: engine, renderers: fexRenderers, kosmickrisp: fexKosmicKrisp)
        download.minimumMacOS = 27
        return download
    }

    /// The runtimes that the Runtimes page and the setup offer. A runtime that
    /// needs a newer macOS is not offered, and the native arm64 runtimes only in
    /// an app with the signed Wine loader.
    static var catalog: [RuntimeDownload] {
        let base = localArchive ?? crossover
        let beta = localD3DMetal.map { d3dmetal4Variant(of: base, d3dmetal: $0) } ?? crossoverD3DMetal4
        let macOS = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let native = GameRuntime.signedLoader == nil ? [] : [highballArm64, highballArm64Alpha]
        return ([base, beta] + native).filter { ($0.minimumMacOS ?? 0) <= macOS }
    }

    /// A test switch for a D3DMetal package that has no published release:
    /// --d3dmetal-archive <file.tar.xz> (with <file>.sha256, as --runtime-archive).
    static let localD3DMetal: D3DMetalPackage? = {
        guard let (file, size, sha) = localFile(after: "--d3dmetal-archive") else { return nil }
        return D3DMetalPackage(version: d3dmetal4.version, url: file, sha256: sha, size: size, folder: d3dmetal4.folder)
    }()

    /// The file after `option` on the command line, its size, and its SHA-256 from <file>.sha256.
    static func localFile(after option: String) -> (URL, Int64, String)? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: option), i + 1 < args.count else { return nil }
        let file = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64,
              let text = try? String(contentsOf: URL(fileURLWithPath: file.path + ".sha256"), encoding: .utf8) else { return nil }
        let sha = String(text.prefix(64)).lowercased()
        guard sha.count == 64, sha.allSatisfy(\.isHexDigit) else { return nil }
        return (file, size, sha)
    }

    /// A test switch for a runtime that has no published release:
    /// --runtime-archive <file.tar.gz> installs the Wine 11 runtime from a local
    /// archive. The file <archive>.sha256 must hold its SHA-256, so the check still runs.
    static let localArchive: RuntimeDownload? = {
        guard let (file, size, sha) = localFile(after: "--runtime-archive") else { return nil }
        return RuntimeDownload(id: crossover.id, name: crossover.name, wineVersion: crossover.wineVersion,
                               release: crossover.release, url: file, sha256: sha, size: size,
                               unpackedBytes: crossover.unpackedBytes)
    }()
}

enum RuntimeInstallError: LocalizedError, Equatable {
    case badPackage(String)
    case noGPTK

    var errorDescription: String? {
        switch self {
        case .badPackage(let detail): return "The runtime package is not valid. \(detail)"
        case .noGPTK: return "This runtime uses D3DMetal from the Game Porting Toolkit. Install the Game Porting Toolkit first."
        }
    }
}

/// Puts a downloaded runtime package into the Runtimes folder. All folders are
/// parameters, so that tests use temporary folders.
enum RuntimeInstaller {
    /// The wine folder of the installed GPTK (it has lib/external/D3DMetal.framework).
    static var gptkWine: URL {
        GameRuntime.standard.root.appendingPathComponent(GameRuntime.wineBundle, isDirectory: true)
    }

    /// 1. Extract into a staging folder in `runtimes`.
    /// 2. Check runtime.json: the ID of the download, and an executable Wine.
    /// 3. Add D3DMetal from GPTK.
    /// 4. Move the folder to Runtimes/<id>. An older release there is replaced;
    ///    its prefix (Prefixes/<id>) stays.
    static func install(archive: URL, download: RuntimeDownload, runtimes: URL, gptkWine: URL = gptkWine,
                        d3dmetalArchive: URL? = nil, shim: URL? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: runtimes, withIntermediateDirectories: true)
        let staging = runtimes.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        // bsdtar refuses absolute paths and ".." entries by default.
        try RuntimeSetup.run("/usr/bin/tar", ["-xf", archive.path, "-C", staging.path])

        let packageID = download.baseID ?? download.id
        let folder = staging.appendingPathComponent(packageID, isDirectory: true)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("runtime.json")),
              var manifest = try? JSONDecoder().decode(RuntimeManifest.self, from: data) else {
            throw RuntimeInstallError.badPackage("runtime.json is missing or not readable.")
        }
        guard manifest.id == packageID, RuntimeCatalog.isValidID(manifest.id), RuntimeCatalog.isValidID(download.id) else {
            throw RuntimeInstallError.badPackage("The package is for \(manifest.id), not \(packageID).")
        }
        guard fm.isExecutableFile(atPath: folder.appendingPathComponent(manifest.wine).path) else {
            throw RuntimeInstallError.badPackage("Wine is missing.")
        }
        if let package = download.d3dmetal {
            guard let d3dmetalArchive, let shim else {
                throw RuntimeInstallError.badPackage("The D3DMetal package or the d3d12 layer is missing.")
            }
            let unpacked = staging.appendingPathComponent("d3dmetal", isDirectory: true)
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: false)
            try RuntimeSetup.run("/usr/bin/tar", ["-xf", d3dmetalArchive.path, "-C", unpacked.path])
            let root = unpacked.appendingPathComponent(package.folder, isDirectory: true)
            manifest = try addD3DMetal4(from: root, shim: shim, to: folder, manifest: manifest,
                                        id: download.id, name: download.name)
        } else if let files = manifest.d3dmetal {
            try addD3DMetal(files, from: gptkWine, to: folder)
        }

        if folder.lastPathComponent != download.id {
            let renamed = staging.appendingPathComponent(download.id, isDirectory: true)
            try fm.moveItem(at: folder, to: renamed)
            return try finish(renamed, download: download, runtimes: runtimes, staging: staging)
        }
        try finish(folder, download: download, runtimes: runtimes, staging: staging)
    }

    private static func finish(_ folder: URL, download: RuntimeDownload, runtimes: URL, staging: URL) throws {
        let fm = FileManager.default
        let target = runtimes.appendingPathComponent(download.id, isDirectory: true)
        if fm.fileExists(atPath: target.path) {
            let old = staging.appendingPathComponent("old", isDirectory: true)
            try fm.moveItem(at: target, to: old)
        }
        try fm.moveItem(at: folder, to: target)
    }

    /// Makes a native arm64 runtime from its three archives, as scripts/make-fex-runtime.sh
    /// does: the engine, the renderers in renderers/, KosmicKrisp in renderers/kosmickrisp
    /// with the Khronos loader as engine/lib/libMoltenVK.dylib, and runtime.json. The
    /// engine's own ad-hoc signed loader goes; iOdus links its signed loader at the start.
    static func installFEX(engine: URL, renderers: URL, kosmickrisp: URL, download: RuntimeDownload,
                           runtimes: URL) throws {
        let fm = FileManager.default
        guard RuntimeCatalog.isValidID(download.id) else { throw RuntimeInstallError.badPackage("Bad runtime ID.") }
        try fm.createDirectory(at: runtimes, withIntermediateDirectories: true)
        let staging = runtimes.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let folder = staging.appendingPathComponent(download.id, isDirectory: true)
        let parts = staging.appendingPathComponent("parts", isDirectory: true)
        for dir in [folder, parts.appendingPathComponent("renderers"), parts.appendingPathComponent("kk")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try RuntimeSetup.run("/usr/bin/tar", ["-xf", engine.path, "-C", folder.path])
        guard fm.isExecutableFile(atPath: folder.appendingPathComponent("engine/bin/wineserver").path) else {
            throw RuntimeInstallError.badPackage("The engine has no Wine.")
        }
        let loader = folder.appendingPathComponent("engine/lib/wine/aarch64-unix/wine")
        let wine = folder.appendingPathComponent("engine/bin/wine")
        try? fm.removeItem(at: loader)
        try? fm.removeItem(at: wine)
        try fm.createSymbolicLink(atPath: wine.path, withDestinationPath: "../lib/wine/aarch64-unix/wine")

        let r = parts.appendingPathComponent("renderers")
        try RuntimeSetup.run("/usr/bin/tar", ["-xf", renderers.path, "-C", r.path])
        guard fm.fileExists(atPath: r.appendingPathComponent("renderers/vkd3d").path) else {
            throw RuntimeInstallError.badPackage("The renderers are missing.")
        }
        try RuntimeSetup.run("/usr/bin/ditto", [r.appendingPathComponent("renderers").path,
                                                folder.appendingPathComponent("renderers").path])
        let k = parts.appendingPathComponent("kk")
        try RuntimeSetup.run("/usr/bin/tar", ["-xf", kosmickrisp.path, "-C", k.path])
        guard fm.fileExists(atPath: k.appendingPathComponent("lib/libMoltenVK.dylib").path) else {
            throw RuntimeInstallError.badPackage("The Vulkan driver is missing.")
        }
        try RuntimeSetup.run("/usr/bin/ditto", [k.appendingPathComponent("renderers/kosmickrisp").path,
                                                folder.appendingPathComponent("renderers/kosmickrisp").path])
        let vulkan = folder.appendingPathComponent("engine/lib/libMoltenVK.dylib")
        try? fm.removeItem(at: vulkan)
        try fm.copyItem(at: k.appendingPathComponent("lib/libMoltenVK.dylib"), to: vulkan)
        for (name, from) in [("renderers", r), ("kosmickrisp", k)] {
            let source = from.appendingPathComponent("licenses")
            guard fm.fileExists(atPath: source.path) else { continue }
            try RuntimeSetup.run("/usr/bin/ditto", [source.path, folder.appendingPathComponent("LICENSES/\(name)").path])
        }

        let manifest = fexManifest(id: download.id, name: download.name, release: download.release)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("runtime.json"))
        try finish(folder, download: download, runtimes: runtimes, staging: staging)
    }

    /// runtime.json of a native arm64 runtime (the same as scripts/make-fex-runtime.sh writes).
    static func fexManifest(id: String, name: String, release: Int) -> RuntimeManifest {
        RuntimeManifest(
            id: id, name: name, wineVersion: "11.18", wine: "engine/bin/wine", wineserver: "engine/bin/wineserver",
            libraries: "engine/lib",
            components: ["xgameruntime.dll", "api-ms-win-core-psm-appnotify-l1-1-0.dll"],
            overrides: ["api-ms-win-core-psm-appnotify-l1-1-0": "native"],
            register: ["windows.web.dll"], propertySet: "wintypes.dll",
            environment: [
                "DYLD_FALLBACK_LIBRARY_PATH": "{root}/engine/lib:{root}/frameworks:{root}/frameworks/GStreamer.framework/Versions/1.0/lib",
                "DYLD_FALLBACK_FRAMEWORK_PATH": "{root}/frameworks",
                "GST_PLUGIN_PATH": "{root}/frameworks/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0",
                "VK_DRIVER_FILES": "{root}/renderers/kosmickrisp/kosmickrisp_icd.json",
                "VK_LOADER_LAYERS_DISABLE": "~implicit~",
                "MESA_SHADER_CACHE_DIR": "{prefix}/.mesa-cache",
                "MESA_SHADER_CACHE_MAX_SIZE": "4G",
                "WINEDLLPATH_PREPEND": "{root}/xbox/wine:{root}/renderers/vkd3d/wine",
                "WINEDLLOVERRIDES": "dxgi,d3d11,d3d10core,d3d12,d3d12core=n,b",
                "DXVK_RELAX_FEATURES": "1",
                "VKD3D_RELAX_DEVICE_CAPS": "1",
                "VKD3D_FEATURE_LEVEL": "12_0",
                "VKD3D_SHADER_MODEL": "6_6",
                "VKD3D_SHADER_CACHE_PATH": "C:\\vkd3d-cache",
            ],
            release: release, d3dmetal: nil, inputGate: nil,
            overlay: RuntimeOverlay(folder: "xbox/wine/aarch64-windows",
                                    files: ["windows.web.dll": "windows.web.dll", "twinapi.appcore.dll": "twinapi.appcore.dll",
                                            "wintypes.dll": "iodus_wintypes.dll"]),
            signedLoader: "engine/lib/wine/aarch64-unix/wine")
    }

    /// Copies Apple's D3DMetal from GPTK into a runtime folder, in the GPTK layout:
    /// lib/external (the framework and libd3dshared), the PE DLLs, and the
    /// unix .so files as the same links that GPTK has.
    static func addD3DMetal(_ files: D3DMetalFiles, from gptkWine: URL, to runtime: URL) throws {
        let fm = FileManager.default
        let external = gptkWine.appendingPathComponent("lib/external", isDirectory: true)
        guard fm.fileExists(atPath: external.appendingPathComponent("D3DMetal.framework").path) else {
            throw RuntimeInstallError.noGPTK
        }
        let target = runtime.appendingPathComponent("lib/external", isDirectory: true)
        try? fm.removeItem(at: target)
        // ditto keeps the links of the framework and the signatures.
        try RuntimeSetup.run("/usr/bin/ditto", [external.path, target.path])
        for name in files.windows where isPlainName(name) {
            let from = gptkWine.appendingPathComponent("lib/wine/x86_64-windows/\(name)")
            let to = runtime.appendingPathComponent("lib/wine/x86_64-windows/\(name)")
            guard fm.fileExists(atPath: from.path) else { continue }
            try? fm.removeItem(at: to)
            try fm.copyItem(at: from, to: to)
        }
        for name in files.unix where isPlainName(name) {
            let from = gptkWine.appendingPathComponent("lib/wine/x86_64-unix/\(name)")
            let to = runtime.appendingPathComponent("lib/wine/x86_64-unix/\(name)")
            guard let link = try? fm.destinationOfSymbolicLink(atPath: from.path) else { continue }
            try? fm.removeItem(at: to)
            try fm.createSymbolicLink(atPath: to.path, withDestinationPath: link)
        }
    }

    /// The file name that Apple's d3d12.dll gets in a D3DMetal 4 runtime. The
    /// d3d12.dll layer takes the name d3d12.dll; Wine finds Apple's file by
    /// this name (wine11-patches/builtin-by-file-name.patch).
    static let renamedD3D12 = "d3d12_d3dmetal.dll"

    /// Puts D3DMetal 4 from an unpacked D3DMetal package into a runtime folder,
    /// as scripts/make-d3dmetal4-runtime.sh does: Apple's signed framework and
    /// redist files, unchanged (d3d12.dll only renamed), the d3d12.dll layer,
    /// Apple's license files, and runtime.json with the new ID.
    static func addD3DMetal4(from package: URL, shim: URL, to runtime: URL, manifest: RuntimeManifest,
                             id: String, name: String) throws -> RuntimeManifest {
        let fm = FileManager.default
        let redist = package.appendingPathComponent("redist", isDirectory: true)
        let framework = redist.appendingPathComponent("lib/external/D3DMetal.framework")
        guard fm.fileExists(atPath: framework.path), fm.fileExists(atPath: shim.path) else {
            throw RuntimeInstallError.badPackage("The D3DMetal package has no D3DMetal.framework.")
        }
        // Apple's signature, and version 4.
        do { try RuntimeSetup.run("/usr/bin/codesign", ["--verify", "--strict", "-R=anchor apple", framework.path]) }
        catch { throw RuntimeInstallError.badPackage("D3DMetal in the package is not signed by Apple.") }
        let info = NSDictionary(contentsOf: framework.appendingPathComponent("Versions/A/Resources/Info.plist"))
        guard let version = info?["CFBundleShortVersionString"] as? String, version.hasPrefix("4.") else {
            throw RuntimeInstallError.badPackage("The package does not have D3DMetal 4.")
        }

        let target = runtime.appendingPathComponent("lib/external", isDirectory: true)
        try? fm.removeItem(at: target)
        try RuntimeSetup.run("/usr/bin/ditto", [redist.appendingPathComponent("lib/external").path, target.path])
        var windows: [String] = [], unix: [String] = []
        let pe = runtime.appendingPathComponent("lib/wine/x86_64-windows", isDirectory: true)
        let so = runtime.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)
        for name in try fm.contentsOfDirectory(atPath: redist.appendingPathComponent("lib/wine/x86_64-windows").path)
        where name.hasSuffix(".dll") && isPlainName(name) {
            let to = pe.appendingPathComponent(name == "d3d12.dll" ? renamedD3D12 : name)
            try? fm.removeItem(at: to)
            try fm.copyItem(at: redist.appendingPathComponent("lib/wine/x86_64-windows/\(name)"), to: to)
            windows.append(to.lastPathComponent)
        }
        for name in try fm.contentsOfDirectory(atPath: redist.appendingPathComponent("lib/wine/x86_64-unix").path)
        where name.hasSuffix(".so") && isPlainName(name) {
            let from = redist.appendingPathComponent("lib/wine/x86_64-unix/\(name)")
            guard let link = try? fm.destinationOfSymbolicLink(atPath: from.path) else { continue }
            let to = so.appendingPathComponent(name)
            try? fm.removeItem(at: to)
            try fm.createSymbolicLink(atPath: to.path, withDestinationPath: link)
            unix.append(name)
        }
        // The layer in front of Apple's d3d12.dll, and the .so link for the renamed file.
        let layer = pe.appendingPathComponent("d3d12.dll")
        try? fm.removeItem(at: layer)
        try fm.copyItem(at: shim, to: layer)
        let renamedSo = so.appendingPathComponent("d3d12_d3dmetal.so")
        try? fm.removeItem(at: renamedSo)
        try fm.createSymbolicLink(atPath: renamedSo.path, withDestinationPath: "../../external/libd3dshared.dylib")
        windows.append("d3d12.dll"); unix.append("d3d12_d3dmetal.so")

        // Apple's license and notices go with every copy (license section 2A).
        let licenses = runtime.appendingPathComponent("LICENSES/D3DMetal", isDirectory: true)
        try fm.createDirectory(at: licenses, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: package.path) where name.hasSuffix(".rtf") || name.hasSuffix(".txt") {
            try? fm.removeItem(at: licenses.appendingPathComponent(name))
            try fm.copyItem(at: package.appendingPathComponent(name), to: licenses.appendingPathComponent(name))
        }

        var m = manifest
        m.id = id
        m.name = name
        var environment = m.environment ?? [:]
        environment["D3DM_MTL4"] = "0"
        environment["WINE_BUILTIN_BY_FILE_NAME"] = renamedD3D12
        m.environment = environment
        m.d3dmetal = D3DMetalFiles(windows: windows.sorted(), unix: unix.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(m).write(to: runtime.appendingPathComponent("runtime.json"))
        return m
    }

    /// A file name without a path, so that runtime.json cannot write outside the folder.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }
}
