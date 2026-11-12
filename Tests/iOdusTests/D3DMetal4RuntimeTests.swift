import XCTest
@testable import iOdus

final class D3DMetal4RuntimeTests: XCTestCase {
    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iodus-d3dm4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A minimal runtime package folder: runtime.json, an executable Wine, the lib folders.
    private func makeBaseRuntime(in folder: URL, id: String) throws {
        let fm = FileManager.default
        let root = folder.appendingPathComponent(id)
        for dir in ["bin", "lib/wine/x86_64-windows", "lib/wine/x86_64-unix"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try Data("#!/bin/sh\n".utf8).write(to: root.appendingPathComponent("bin/wine"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("bin/wine").path)
        let manifest = RuntimeManifest(id: id, name: "CrossOver 26.3 Wine", wineVersion: "11.0", wine: "bin/wine",
                                       wineserver: "bin/wineserver", libraries: "lib", components: [], overrides: [:],
                                       register: nil, propertySet: nil,
                                       environment: ["CX_APPLEGPTK_LIBD3DSHARED_PATH": "{root}/lib/external/libd3dshared.dylib"],
                                       release: 4, d3dmetal: nil, inputGate: true)
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("runtime.json"))
    }

    func testTheBetaRuntimeIsAVariantOfTheWinePackage() {
        let beta = RuntimeDownload.crossoverD3DMetal4
        XCTAssertEqual(beta.id, "crossover-26.3-d3dm4")
        XCTAssertEqual(beta.baseID, RuntimeDownload.crossover.id)
        XCTAssertEqual(beta.url, RuntimeDownload.crossover.url, "The same Wine package")
        XCTAssertEqual(beta.minimumMacOS, 27)
        XCTAssertTrue(beta.isBeta)
        XCTAssertTrue(beta.name.contains("beta"))
        XCTAssertEqual(GameCompat.requiredRuntime(for: "9nr1r1xwlcnb"), beta.id)
        XCTAssertNil(GameCompat.requiredRuntime(for: "9PJGM0T0827V"), "DIRT 5 has no required runtime")
    }

    func testInstallMakesTheD3DMetal4Runtime() throws {
        // Apple's signed redist folder from Game Porting Toolkit 4, if this Mac has a copy.
        let source = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("projects/iodus-runtimes/gptk-4.0b3")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.appendingPathComponent("redist").path),
                          "No GPTK 4 redist folder on this Mac")
        let work = try tempFolder()
        try makeBaseRuntime(in: work.appendingPathComponent("base"), id: "crossover-26.3")
        let archive = work.appendingPathComponent("runtime.tar")
        try RuntimeSetup.run("/usr/bin/tar", ["-cf", archive.path, "-C", work.appendingPathComponent("base").path, "crossover-26.3"])
        let package = work.appendingPathComponent("pkg/d3dmetal-4.0b3")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try RuntimeSetup.run("/usr/bin/ditto", [source.appendingPathComponent("redist").path, package.appendingPathComponent("redist").path])
        try Data("Apple license".utf8).write(to: package.appendingPathComponent("License.rtf"))
        let d3dmetalArchive = work.appendingPathComponent("d3dmetal.tar")
        try RuntimeSetup.run("/usr/bin/tar", ["-cf", d3dmetalArchive.path, "-C", work.appendingPathComponent("pkg").path, "d3dmetal-4.0b3"])
        let shim = work.appendingPathComponent("shim.dll")
        try Data("LAYER".utf8).write(to: shim)

        let runtimes = work.appendingPathComponent("Runtimes")
        try RuntimeInstaller.install(archive: archive, download: RuntimeDownload.crossoverD3DMetal4, runtimes: runtimes,
                                     d3dmetalArchive: d3dmetalArchive, shim: shim)

        let root = runtimes.appendingPathComponent("crossover-26.3-d3dm4")
        let pe = root.appendingPathComponent("lib/wine/x86_64-windows")
        XCTAssertEqual(try String(contentsOf: pe.appendingPathComponent("d3d12.dll"), encoding: .utf8), "LAYER")
        XCTAssertEqual(try Data(contentsOf: pe.appendingPathComponent("d3d12_d3dmetal.dll")),
                       try Data(contentsOf: source.appendingPathComponent("redist/lib/wine/x86_64-windows/d3d12.dll")),
                       "Apple's d3d12.dll is only renamed")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: root.appendingPathComponent("lib/wine/x86_64-unix/d3d12_d3dmetal.so").path), "../../external/libd3dshared.dylib")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("lib/external/D3DMetal.framework").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("LICENSES/D3DMetal/License.rtf").path))
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: root.appendingPathComponent("runtime.json")))
        XCTAssertEqual(manifest.id, "crossover-26.3-d3dm4")
        XCTAssertEqual(manifest.environment?["D3DM_MTL4"], "0")
        XCTAssertEqual(manifest.environment?["WINE_BUILTIN_BY_FILE_NAME"], "d3d12_d3dmetal.dll")
        XCTAssertEqual(manifest.environment?["CX_APPLEGPTK_LIBD3DSHARED_PATH"], "{root}/lib/external/libd3dshared.dylib")
        XCTAssertTrue(manifest.d3dmetal?.windows.contains("d3d12core.dll") ?? false)
        XCTAssertNil(try? FileManager.default.contentsOfDirectory(atPath: runtimes.path).first { $0.hasPrefix(".install") },
                     "No staging folder stays")
    }

    func testTheWine11RuntimeBringsD3DMetal3() {
        let wine = RuntimeDownload.crossover
        XCTAssertEqual(wine.d3dmetal?.version, "3.0")
        XCTAssertEqual(wine.d3dmetal?.major, 3)
        XCTAssertEqual(wine.d3dmetal?.needsLayer, false)
        XCTAssertFalse(wine.isBeta, "D3DMetal 3 is not a beta")
        XCTAssertEqual(RuntimeDownload.crossoverD3DMetal4.d3dmetal?.needsLayer, true)
        XCTAssertTrue(RuntimeDownload.crossoverD3DMetal4.isBeta)
    }

    func testInstallMakesTheD3DMetal3Runtime() throws {
        // Apple's redist folder from Game Porting Toolkit 3.0, if this Mac has a copy.
        let source = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("projects/iodus-runtimes/gptk-3.0")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.appendingPathComponent("redist").path),
                          "No GPTK 3.0 redist folder on this Mac")
        let work = try tempFolder()
        try makeBaseRuntime(in: work.appendingPathComponent("base"), id: "crossover-26.3")
        let archive = work.appendingPathComponent("runtime.tar")
        try RuntimeSetup.run("/usr/bin/tar", ["-cf", archive.path, "-C", work.appendingPathComponent("base").path, "crossover-26.3"])
        let package = work.appendingPathComponent("pkg/d3dmetal-3.0")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try RuntimeSetup.run("/usr/bin/ditto", [source.appendingPathComponent("redist").path, package.appendingPathComponent("redist").path])
        try Data("Apple license".utf8).write(to: package.appendingPathComponent("License.rtf"))
        let d3dmetalArchive = work.appendingPathComponent("d3dmetal.tar")
        try RuntimeSetup.run("/usr/bin/tar", ["-cf", d3dmetalArchive.path, "-C", work.appendingPathComponent("pkg").path, "d3dmetal-3.0"])

        let runtimes = work.appendingPathComponent("Runtimes")
        // No d3d12 layer and no Game Porting Toolkit.
        try RuntimeInstaller.install(archive: archive, download: RuntimeDownload.crossover, runtimes: runtimes,
                                     gptkWine: work.appendingPathComponent("no-gptk"), d3dmetalArchive: d3dmetalArchive, shim: nil)

        let root = runtimes.appendingPathComponent("crossover-26.3")
        let pe = root.appendingPathComponent("lib/wine/x86_64-windows")
        XCTAssertEqual(try Data(contentsOf: pe.appendingPathComponent("d3d12.dll")),
                       try Data(contentsOf: source.appendingPathComponent("redist/lib/wine/x86_64-windows/d3d12.dll")),
                       "Apple's d3d12.dll keeps its name")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pe.appendingPathComponent(RuntimeInstaller.renamedD3D12).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("lib/external/D3DMetal.framework").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("LICENSES/D3DMetal/License.rtf").path))
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: root.appendingPathComponent("runtime.json")))
        XCTAssertEqual(manifest.id, "crossover-26.3")
        XCTAssertNil(manifest.environment?["WINE_BUILTIN_BY_FILE_NAME"])
        XCTAssertNil(manifest.environment?["D3DM_MTL4"])
        XCTAssertTrue(manifest.d3dmetal?.windows.contains("atidxx64.dll") ?? false, "Apple's file list")
        XCTAssertFalse(manifest.d3dmetal?.windows.contains("nvngx.dll") ?? true, "Not Apple's file")
    }

    func testAPackageWithoutApplesSignatureIsRefused() throws {
        let work = try tempFolder()
        try makeBaseRuntime(in: work.appendingPathComponent("base"), id: "crossover-26.3")
        let archive = work.appendingPathComponent("runtime.tar")
        try RuntimeSetup.run("/usr/bin/tar", ["-cf", archive.path, "-C", work.appendingPathComponent("base").path, "crossover-26.3"])
        let framework = work.appendingPathComponent("pkg/d3dmetal-4.0b3/redist/lib/external/D3DMetal.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        let d3dmetalArchive = work.appendingPathComponent("d3dmetal.tar")
        try RuntimeSetup.run("/usr/bin/tar", ["-cf", d3dmetalArchive.path, "-C", work.appendingPathComponent("pkg").path, "d3dmetal-4.0b3"])
        let shim = work.appendingPathComponent("shim.dll")
        try Data("LAYER".utf8).write(to: shim)
        let runtimes = work.appendingPathComponent("Runtimes")
        XCTAssertThrowsError(try RuntimeInstaller.install(archive: archive, download: RuntimeDownload.crossoverD3DMetal4,
                                                          runtimes: runtimes, d3dmetalArchive: d3dmetalArchive, shim: shim))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimes.appendingPathComponent("crossover-26.3-d3dm4").path))
    }

    /// A runtime in a temporary folder with a d3d12.dll layer, and the app's layer in `components/compat`.
    private func makeLayerRuntime(environment: [String: String], installed: String?, app: String?) throws -> GameRuntime {
        let work = try tempFolder()
        let root = work.appendingPathComponent("crossover-26.3-d3dm4")
        let components = work.appendingPathComponent("components")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib/wine/x86_64-windows"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: components.appendingPathComponent("compat"), withIntermediateDirectories: true)
        let manifest = RuntimeManifest(id: "crossover-26.3-d3dm4", name: "CrossOver 26.3 Wine + D3DMetal 4.0", wineVersion: "11.0",
                                       wine: "bin/wine", wineserver: "bin/wineserver", libraries: "lib", components: [],
                                       overrides: [:], register: nil, propertySet: nil, environment: environment,
                                       release: 5, d3dmetal: nil, inputGate: true)
        let runtime = GameRuntime.from(manifest: manifest, root: root, prefix: work.appendingPathComponent("prefix"),
                                       componentRoot: components, usesBundle: false)
        if let installed { try Data(installed.utf8).write(to: runtime.d3d12LayerTarget) }
        if let app { try Data(app.utf8).write(to: runtime.d3d12LayerSource) }
        return runtime
    }

    private let layerEnvironment = ["WINE_BUILTIN_BY_FILE_NAME": RuntimeInstaller.renamedD3D12]

    func testANewLayerReplacesTheOldLayerInTheRuntime() throws {
        let runtime = try makeLayerRuntime(environment: layerEnvironment, installed: "OLD LAYER", app: "NEW LAYER")
        XCTAssertTrue(try runtime.updateD3D12Layer())
        XCTAssertEqual(try String(contentsOf: runtime.d3d12LayerTarget, encoding: .utf8), "NEW LAYER")
        XCTAssertFalse(try runtime.updateD3D12Layer(), "The same layer is not copied again")
    }

    func testTheLayerStaysWhenItIsTheSame() throws {
        let runtime = try makeLayerRuntime(environment: layerEnvironment, installed: "LAYER", app: "LAYER")
        let before = try FileManager.default.attributesOfItem(atPath: runtime.d3d12LayerTarget.path)[.modificationDate] as? Date
        XCTAssertFalse(try runtime.updateD3D12Layer())
        let after = try FileManager.default.attributesOfItem(atPath: runtime.d3d12LayerTarget.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }

    func testARuntimeWithoutTheLayerIsNotChanged() throws {
        // A D3DMetal 3 runtime: its d3d12.dll is Apple's file, not the layer.
        let runtime = try makeLayerRuntime(environment: [:], installed: "APPLE D3D12", app: "NEW LAYER")
        XCTAssertFalse(try runtime.updateD3D12Layer())
        XCTAssertEqual(try String(contentsOf: runtime.d3d12LayerTarget, encoding: .utf8), "APPLE D3D12")
    }

    func testAnAppWithoutTheLayerDoesNotChangeTheRuntime() throws {
        let runtime = try makeLayerRuntime(environment: layerEnvironment, installed: "OLD LAYER", app: nil)
        XCTAssertFalse(try runtime.updateD3D12Layer())
        XCTAssertEqual(try String(contentsOf: runtime.d3d12LayerTarget, encoding: .utf8), "OLD LAYER")
    }
}
