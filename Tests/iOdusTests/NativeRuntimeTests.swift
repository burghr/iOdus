import XCTest
@testable import iOdus

/// The native arm64 runtimes (Highball arm64 engine with FEX): the overlay of
/// iOdus DLLs, the link to the signed Wine loader, and the {prefix} placeholder.
final class NativeRuntimeTests: XCTestCase {
    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iodus-native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func manifest(id: String = "highball-arm64-r5") -> RuntimeManifest {
        RuntimeManifest(id: id, name: "Highball arm64 engine (FEX)", wineVersion: "11.18",
                        wine: "engine/bin/wine", wineserver: "engine/bin/wineserver", libraries: "engine/lib",
                        components: ["xgameruntime.dll"], overrides: [:], register: ["windows.web.dll"], propertySet: "wintypes.dll",
                        environment: ["MESA_SHADER_CACHE_DIR": "{prefix}/.mesa-cache",
                                      "VK_DRIVER_FILES": "{root}/renderers/kosmickrisp/kosmickrisp_icd.json"],
                        release: 1, d3dmetal: nil, inputGate: true,
                        overlay: RuntimeOverlay(folder: "xbox/wine/aarch64-windows",
                                                files: ["windows.web.dll": "windows.web.dll", "wintypes.dll": "iodus_wintypes.dll",
                                                        "evil/../x.dll": "windows.web.dll", "other.dll": "not-an-iodus.dll"]),
                        signedLoader: "engine/lib/wine/aarch64-unix/wine")
    }

    /// A runtime in a temporary folder, with iOdus DLLs in `components`.
    private func makeRuntime() throws -> (GameRuntime, URL) {
        let work = try tempFolder()
        let components = work.appendingPathComponent("components")
        try FileManager.default.createDirectory(at: components, withIntermediateDirectories: true)
        try Data("WEB 1".utf8).write(to: components.appendingPathComponent("windows.web.dll"))
        try Data("TYPES 1".utf8).write(to: components.appendingPathComponent("iodus_wintypes.dll"))
        let runtime = GameRuntime.from(manifest: manifest(), root: work.appendingPathComponent("runtime"),
                                       prefix: work.appendingPathComponent("prefix"), componentRoot: components, usesBundle: false)
        return (runtime, components)
    }

    func testTheManifestReadsTheNewFields() throws {
        let data = try JSONEncoder().encode(manifest())
        let decoded = try JSONDecoder().decode(RuntimeManifest.self, from: data)
        XCTAssertEqual(decoded, manifest())
        // An older runtime.json without the fields still reads.
        let old = #"{"id":"crossover-26.3","name":"CrossOver 26.3 Wine","wineVersion":"11.0","wine":"bin/wine","wineserver":"bin/wineserver","components":[],"overrides":{}}"#
        let plain = try JSONDecoder().decode(RuntimeManifest.self, from: Data(old.utf8))
        XCTAssertNil(plain.overlay)
        XCTAssertNil(plain.signedLoader)
    }

    func testPlaceholdersAndOverlayFiles() throws {
        let (runtime, _) = try makeRuntime()
        XCTAssertEqual(runtime.extraEnvironment["MESA_SHADER_CACHE_DIR"], runtime.prefix.path + "/.mesa-cache")
        XCTAssertEqual(runtime.extraEnvironment["VK_DRIVER_FILES"], runtime.root.path + "/renderers/kosmickrisp/kosmickrisp_icd.json")
        XCTAssertEqual(runtime.overlayFiles, ["windows.web.dll": "windows.web.dll", "wintypes.dll": "iodus_wintypes.dll"],
                       "Only plain file names and iOdus DLLs")
        XCTAssertEqual(runtime.signedLoaderLink, runtime.root.appendingPathComponent("engine/lib/wine/aarch64-unix/wine"))
    }

    func testTheOverlayCopiesNewAndChangedFilesOnly() throws {
        let (runtime, components) = try makeRuntime()
        let folder = try XCTUnwrap(runtime.overlayFolder)
        XCTAssertTrue(try runtime.updateOverlay())
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("wintypes.dll"), encoding: .utf8), "TYPES 1")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("windows.web.dll"), encoding: .utf8), "WEB 1")
        XCTAssertFalse(try runtime.updateOverlay(), "The same files are not copied again")

        try Data("TYPES 2".utf8).write(to: components.appendingPathComponent("iodus_wintypes.dll"))
        XCTAssertTrue(try runtime.updateOverlay())
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("wintypes.dll"), encoding: .utf8), "TYPES 2")
    }

    func testTheLoaderLinkPointsAtTheSignedLoader() throws {
        let (runtime, _) = try makeRuntime()
        let work = runtime.root.deletingLastPathComponent()
        let loader = work.appendingPathComponent("WineLoader.app/Contents/MacOS/wine")
        let moved = work.appendingPathComponent("Moved.app/Contents/MacOS/wine")
        for file in [loader, moved] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: file)
        }
        let link = try XCTUnwrap(runtime.signedLoaderLink)

        // The engine's own ad-hoc signed loader is a plain file there: it goes.
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("ADHOC".utf8).write(to: link)
        XCTAssertTrue(try runtime.linkSignedLoader(to: loader))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), loader.path)
        XCTAssertFalse(try runtime.linkSignedLoader(to: loader), "An unchanged link stays")
        XCTAssertTrue(try runtime.linkSignedLoader(to: moved), "The app moved")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), moved.path)
    }

    func testANativeRuntimeNeedsTheSignedLoaderNotTheLink() throws {
        let (runtime, components) = try makeRuntime()
        for name in ["xgameruntime.dll"] { try Data("X".utf8).write(to: components.appendingPathComponent(name)) }
        let server = runtime.wineserver
        try FileManager.default.createDirectory(at: server.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
        let loader = runtime.root.deletingLastPathComponent().appendingPathComponent("loader")
        // No link yet (iOdus makes it at the start): no problem with a signed loader in the app.
        XCTAssertNil(runtime.problem(signedLoader: loader))
        XCTAssertNotNil(runtime.problem(signedLoader: nil), "An app without the loader cannot start it")
    }

    func testOtherRuntimesHaveNoOverlayOrLoader() throws {
        let work = try tempFolder()
        let plain = RuntimeManifest(id: "crossover-26.3", name: "CrossOver 26.3 Wine", wineVersion: "11.0", wine: "bin/wine",
                                    wineserver: "bin/wineserver", libraries: "lib", components: [], overrides: [:],
                                    register: nil, propertySet: nil, environment: nil, release: 6, d3dmetal: nil, inputGate: true)
        let runtime = GameRuntime.from(manifest: plain, root: work, prefix: work.appendingPathComponent("prefix"),
                                       componentRoot: work, usesBundle: false)
        XCTAssertNil(runtime.overlayFolder)
        XCTAssertNil(runtime.signedLoaderLink)
        XCTAssertFalse(try runtime.updateOverlay())
        XCTAssertFalse(try runtime.linkSignedLoader(to: work))
    }

    func testRuntimesHaveAKind() throws {
        let (native, _) = try makeRuntime()
        XCTAssertEqual(native.family, .fex)
        XCTAssertEqual(RuntimeRow.installed(native).family, .fex)
        let work = try tempFolder()
        let plain = RuntimeManifest(id: "crossover-26.3", name: "CrossOver 26.3 Wine", wineVersion: "11.0", wine: "bin/wine",
                                    wineserver: "bin/wineserver", libraries: "lib", components: [], overrides: [:],
                                    register: nil, propertySet: nil, environment: nil, release: 6, d3dmetal: nil, inputGate: true)
        let rosetta = GameRuntime.from(manifest: plain, root: work, prefix: work, componentRoot: work, usesBundle: false)
        XCTAssertEqual(rosetta.family, .d3dmetal)
        XCTAssertEqual(RuntimeRow.available(RuntimeDownload.crossover).family, .d3dmetal)
        XCTAssertNil(RuntimeRow.useDefault.family)
        XCTAssertLessThan(RuntimeFamily.d3dmetal, RuntimeFamily.fex, "D3DMetal comes first")
        XCTAssertTrue(rosetta.installsVCRuntime)
        XCTAssertFalse(native.installsVCRuntime, "Wine's own C++ runtime on the native runtimes")
    }

    /// Writes files (path -> contents; "+x" at the end makes it executable) and packs them as a .tar.gz.
    private func archive(_ name: String, _ files: [String: String], in work: URL) throws -> URL {
        let fm = FileManager.default
        let dir = work.appendingPathComponent("src-\(name)")
        for (path, contents) in files {
            let executable = path.hasSuffix("+x")
            let file = dir.appendingPathComponent(executable ? String(path.dropLast(2)) : path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
            if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        }
        let out = work.appendingPathComponent("\(name).tar.gz")
        try RuntimeSetup.run("/usr/bin/tar", ["-czf", out.path, "-C", dir.path, "."])
        return out
    }

    func testTheFEXInstallerMakesTheRuntimeFolder() throws {
        let work = try tempFolder()
        let engine = try archive("engine", [
            "engine/bin/wine": "ADHOC LOADER", "engine/bin/wineserver+x": "#!/bin/sh\n",
            "engine/lib/wine/aarch64-unix/wine": "ADHOC LOADER", "engine/lib/wine/aarch64-unix/ntdll.so": "NTDLL",
            "engine/lib/libMoltenVK.dylib": "ENGINE MOLTENVK", "engine/share/wine/wine.inf": "INF",
            "frameworks/GStreamer.framework/Versions/1.0/lib/x": "GST"], in: work)
        let renderers = try archive("renderers", [
            "renderers/vkd3d/wine/aarch64-windows/d3d12.dll": "VKD3D", "renderers/dxvk/wine/aarch64-windows/d3d11.dll": "DXVK",
            "licenses/vkd3d-proton-COPYING": "LGPL", "BUILD.txt": "build"], in: work)
        let kk = try archive("kk", [
            "lib/libMoltenVK.dylib": "KHRONOS LOADER", "renderers/kosmickrisp/kosmickrisp_icd.json": "{}",
            "renderers/kosmickrisp/libvulkan_kosmickrisp.dylib": "KK", "licenses/Mesa-license.rst": "MIT"], in: work)
        let runtimes = work.appendingPathComponent("Runtimes")
        let download = RuntimeDownload.highballArm64
        try RuntimeInstaller.installFEX(engine: engine, renderers: renderers, kosmickrisp: kk, download: download, runtimes: runtimes)

        let root = runtimes.appendingPathComponent(download.id)
        let fm = FileManager.default
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: root.appendingPathComponent("engine/bin/wine").path),
                       "../lib/wine/aarch64-unix/wine")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("engine/lib/wine/aarch64-unix/wine").path),
                       "The engine's ad-hoc loader goes")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("engine/lib/libMoltenVK.dylib"), encoding: .utf8),
                       "KHRONOS LOADER")
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("renderers/vkd3d/wine/aarch64-windows/d3d12.dll").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("renderers/kosmickrisp/kosmickrisp_icd.json").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("LICENSES/kosmickrisp/Mesa-license.rst").path))
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: root.appendingPathComponent("runtime.json")))
        XCTAssertEqual(manifest, RuntimeInstaller.fexManifest(id: download.id, name: download.name, release: download.release))
        let runtime = try XCTUnwrap(RuntimeCatalog.discover(folder: runtimes, prefixes: work.appendingPathComponent("Prefixes"))
            .first { $0.id == download.id })
        XCTAssertEqual(runtime.family, .fex)
        XCTAssertEqual(runtime.wineInf.resolvingSymlinksInPath().path,
                       root.appendingPathComponent("engine/share/wine/wine.inf").resolvingSymlinksInPath().path)

        // An update replaces the folder; the prefix stays.
        let prefix = work.appendingPathComponent("Prefixes/\(download.id)")
        try fm.createDirectory(at: prefix, withIntermediateDirectories: true)
        try RuntimeInstaller.installFEX(engine: engine, renderers: renderers, kosmickrisp: kk, download: download, runtimes: runtimes)
        XCTAssertTrue(fm.fileExists(atPath: prefix.path))
        XCTAssertNil(try? fm.contentsOfDirectory(atPath: runtimes.path).first { $0.hasPrefix(".install") })
    }

    func testTheFEXInstallerWithTheRealArchives() throws {
        // The release files of Highball's arm64 engine, if this Mac has a copy.
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("projects/iodus-runtimes/fex/download")
        let engine = folder.appendingPathComponent("engine-arm64-wine-11.18-20261108T132317Z-spatial-0056-0057.tar.gz")
        let renderers = folder.appendingPathComponent("renderers-arm64-20261031T230303Z-manual.tar.gz")
        let kk = folder.appendingPathComponent("kosmickrisp-arm64-20261104T165852Z-push.tar.gz")
        try XCTSkipUnless([engine, renderers, kk].allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                          "No Highball arm64 release files on this Mac")
        let package = try XCTUnwrap(RuntimeDownload.highballArm64.fex)
        for (archive, file) in zip(package.archives, [engine, renderers, kk]) {
            XCTAssertNoThrow(try RuntimeSetup.verify(file, sha256: archive.sha256), file.lastPathComponent)
        }
        let work = try tempFolder()
        let runtimes = work.appendingPathComponent("Runtimes")
        try RuntimeInstaller.installFEX(engine: engine, renderers: renderers, kosmickrisp: kk,
                                        download: RuntimeDownload.highballArm64, runtimes: runtimes)
        let root = runtimes.appendingPathComponent(RuntimeDownload.highballArm64.id)
        for path in ["engine/bin/wineserver", "engine/lib/wine/aarch64-unix/ntdll.so", "engine/lib/wine/aarch64-windows/xtajit64.dll",
                     "renderers/vkd3d/wine/aarch64-windows/d3d12.dll", "renderers/kosmickrisp/kosmickrisp_icd.json",
                     "frameworks/GStreamer.framework"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), path)
        }
    }

    func testTheFEXDownloadsAreNativeBetaRuntimes() {
        for download in [RuntimeDownload.highballArm64, RuntimeDownload.highballArm64Alpha] {
            XCTAssertEqual(download.family, .fex)
            XCTAssertTrue(download.isBeta)
            XCTAssertEqual(download.minimumMacOS, 27)
            XCTAssertEqual(download.fex?.archives.count, 3)
            XCTAssertEqual(download.url, download.fex?.engine.url)
        }
        XCTAssertEqual(RuntimeDownload.crossover.family, .d3dmetal)
    }

    @MainActor
    func testAGamePageOffersTheDownloadsOfTheChosenTechnology() throws {
        let model = AppModel()
        model.runtimes = []
        model.runtimeDownloadCatalog = [RuntimeDownload.crossover, RuntimeDownload.highballArm64, RuntimeDownload.highballArm64Alpha]
        model.runtimeFamily = .fex
        let rows = model.runtimeRows(for: "9N4NKMXDZCX6")
        XCTAssertEqual(rows, [.useDefault, .available(RuntimeDownload.highballArm64), .available(RuntimeDownload.highballArm64Alpha)])
        model.runtimeFamily = .d3dmetal
        XCTAssertEqual(model.runtimeRows(for: "9N4NKMXDZCX6"), [.useDefault, .available(RuntimeDownload.crossover)])
    }

    func testEnvironmentCanRemoveAVariable() throws {
        let (runtime, _) = try makeRuntime()
        let env = runtime.environment(extra: ["WINEDLLPATH_PREPEND": "/x"], removing: ["WINEDLLPATH_PREPEND"])
        XCTAssertNil(env["WINEDLLPATH_PREPEND"])
        XCTAssertEqual(env["WINEPREFIX"], runtime.prefix.path)
    }
}
