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

    func testEnvironmentCanRemoveAVariable() throws {
        let (runtime, _) = try makeRuntime()
        let env = runtime.environment(extra: ["WINEDLLPATH_PREPEND": "/x"], removing: ["WINEDLLPATH_PREPEND"])
        XCTAssertNil(env["WINEDLLPATH_PREPEND"])
        XCTAssertEqual(env["WINEPREFIX"], runtime.prefix.path)
    }
}
