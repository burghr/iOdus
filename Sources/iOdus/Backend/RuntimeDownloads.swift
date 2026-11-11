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

    var displayName: String { "\(name) (Wine \(wineVersion))" }
    var neededBytes: Int64 { size + unpackedBytes + (d3dmetal?.size ?? 0) * 3 }
    var isBeta: Bool { d3dmetal != nil }

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

    /// The runtimes that the Runtimes page and the setup offer. A runtime that
    /// needs a newer macOS is not offered.
    static var catalog: [RuntimeDownload] {
        let base = localArchive ?? crossover
        let beta = localD3DMetal.map { d3dmetal4Variant(of: base, d3dmetal: $0) } ?? crossoverD3DMetal4
        let macOS = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return [base, beta].filter { ($0.minimumMacOS ?? 0) <= macOS }
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
