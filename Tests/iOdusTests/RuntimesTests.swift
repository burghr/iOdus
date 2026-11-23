import CryptoKit
import XCTest
@testable import iOdus

/// Runtime discovery and the choice per game. No Wine runs in these tests.
final class RuntimesTests: XCTestCase {
    private var temp: URL!
    private var defaults: UserDefaults!
    private let suite = "iodus-runtime-tests"

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("runtimes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
        defaults.removePersistentDomain(forName: suite)
    }

    private var standard: GameRuntime { .gptk(root: temp.appendingPathComponent("Runtime"), prefix: temp.appendingPathComponent("Prefix")) }

    private func addRuntime(_ id: String, folder: String? = nil, json: String? = nil) throws {
        let root = temp.appendingPathComponent("Runtimes/\(folder ?? id)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let text = json ?? """
        {"id":"\(id)","name":"CrossOver 26.3 Wine","wineVersion":"11.0","wine":"bin/wine","wineserver":"bin/wineserver",
         "libraries":"lib","components":["xgameruntime.dll","d3d11.dll","unknown.dll"],
         "overrides":{"d3d11":"native,builtin"},
         "environment":{"CX_APPLEGPTK_LIBD3DSHARED_PATH":"{root}/lib/external/libd3dshared.dylib"}}
        """
        try text.write(to: root.appendingPathComponent("runtime.json"), atomically: true, encoding: .utf8)
    }

    private func discover() -> [GameRuntime] {
        RuntimeCatalog.discover(folder: temp.appendingPathComponent("Runtimes"),
                                prefixes: temp.appendingPathComponent("Prefixes"), standard: standard)
    }

    func testWinhttpProxyForOldWine() {
        func manifest(_ version: String, loader: String? = nil) -> RuntimeManifest {
            RuntimeManifest(id: "r", name: "R", wineVersion: version, wine: "bin/wine", wineserver: "bin/wineserver",
                            libraries: nil, components: ["xgameruntime.dll"], overrides: [:], register: nil,
                            propertySet: nil, environment: nil, release: nil, d3dmetal: nil, inputGate: nil,
                            overlay: nil, signedLoader: loader)
        }
        let old = GameRuntime.withWinhttpProxy(manifest("11.0"))
        XCTAssertEqual(old.components, ["xgameruntime.dll", "winhttp.dll"])
        XCTAssertEqual(old.overrides["winhttp"], "native,builtin")
        XCTAssertEqual(GameRuntime.withWinhttpProxy(manifest("11.4")), manifest("11.4"), "11.4 accepts the option")
        XCTAssertEqual(GameRuntime.withWinhttpProxy(manifest("11.18")), manifest("11.18"))
        XCTAssertEqual(GameRuntime.withWinhttpProxy(manifest("11.0", loader: "bin/wine")), manifest("11.0", loader: "bin/wine"),
                       "Native arm64 runtimes keep their manifest")
        let twice = GameRuntime.withWinhttpProxy(old)
        XCTAssertEqual(twice.components.filter { $0 == "winhttp.dll" }.count, 1)
    }

    func testDiscovery() throws {
        XCTAssertEqual(discover().map(\.id), ["gptk-3.0-3"], "Only GPTK without runtime folders")
        try addRuntime("crossover-26.3")
        try addRuntime("other", folder: "wrong-folder")                  // The ID must be the folder name
        try addRuntime("gptk-3.0-3")                                       // The built-in ID cannot come twice
        try addRuntime("bad", json: "{not json")
        let list = discover()
        XCTAssertEqual(list.map(\.id), ["gptk-3.0-3", "crossover-26.3"])
        let wine11 = list[1]
        XCTAssertEqual(wine11.displayName, "CrossOver 26.3 Wine (Wine 11.0)")
        XCTAssertEqual(wine11.wine64.lastPathComponent, "wine")
        XCTAssertEqual(wine11.prefix.lastPathComponent, "crossover-26.3")
        XCTAssertEqual(wine11.prefix.deletingLastPathComponent().lastPathComponent, "Prefixes")
        XCTAssertEqual(wine11.componentNames, ["xgameruntime.dll", "d3d11.dll", "winhttp.dll"],
                       "Unknown DLL names are dropped; Wine 11.0 gets the winhttp proxy")
        XCTAssertTrue(wine11.overrides.contains { $0.0 == "winhttp" && $0.1 == "native,builtin" })
        XCTAssertEqual(wine11.environment()["DYLD_FALLBACK_LIBRARY_PATH"]?.hasPrefix(wine11.root.path + "/lib"), true)
        XCTAssertEqual(wine11.environment()["CX_APPLEGPTK_LIBD3DSHARED_PATH"],
                       wine11.root.path + "/lib/external/libd3dshared.dylib")
        XCTAssertNil(list[0].environment()["DYLD_FALLBACK_LIBRARY_PATH"].flatMap { $0.contains("Runtime") ? $0 : nil })
    }

    func testValidIDs() {
        XCTAssertTrue(RuntimeCatalog.isValidID("crossover-26.3"))
        XCTAssertFalse(RuntimeCatalog.isValidID("../escape"))
        XCTAssertFalse(RuntimeCatalog.isValidID(".hidden"))
        XCTAssertFalse(RuntimeCatalog.isValidID(""))
        XCTAssertFalse(RuntimeCatalog.isValidID("a/b"))
    }

    func testChoicePerGame() throws {
        try addRuntime("crossover-26.3")
        let list = discover()
        let choice = RuntimeChoice(defaults: defaults)
        XCTAssertEqual(choice.defaultRuntime(in: list).id, "gptk-3.0-3")
        XCTAssertEqual(choice.runtime(for: "9nr1r1xwlcnb", in: list).id, "gptk-3.0-3")
        choice.setGame("9nr1r1xwlcnb", "crossover-26.3")
        XCTAssertEqual(choice.runtime(for: "9NR1R1XWLCNB", in: list).id, "crossover-26.3", "Product IDs ignore case")
        XCTAssertEqual(choice.runtime(for: "9MSVVM5NS9L6", in: list).id, "gptk-3.0-3")
        choice.defaultID = "crossover-26.3"
        XCTAssertEqual(choice.runtime(for: "9MSVVM5NS9L6", in: list).id, "crossover-26.3")
        choice.setGame("9NR1R1XWLCNB", nil)
        choice.defaultID = "removed-runtime"
        XCTAssertEqual(choice.runtime(for: "9NR1R1XWLCNB", in: list).id, "gptk-3.0-3", "A removed runtime falls back to GPTK")
    }

    /// A test runtime must never point to the real DLL folder or the app bundle.
    func testTestRuntimesUseTheirOwnFolders() throws {
        XCTAssertEqual(standard.componentFolder.path, temp.appendingPathComponent("Runtime/components").path)
        try addRuntime("crossover-26.3")
        XCTAssertEqual(discover()[1].componentFolder.path, temp.appendingPathComponent("Runtime/components").path)
        XCTAssertFalse(standard.componentFolder.path.contains("Application Support"))
    }

    /// The GPTK hash has only the DLL names and bytes, the same as before more
    /// runtimes existed. So the existing prefix is not prepared again.
    func testGPTKHashIsTheOldHash() throws {
        let folder = standard.componentFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var old = SHA256()
        for name in GameRuntime.components {
            try Data("bytes of \(name)".utf8).write(to: folder.appendingPathComponent(name))
            old.update(data: Data(name.utf8))
            old.update(data: Data("bytes of \(name)".utf8))
        }
        let oldHash = old.finalize().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try standard.componentHash(), oldHash)
    }

    func testPrefixUpdateFollowsTheWineInfTime() throws {
        let fm = FileManager.default
        let inf = temp.appendingPathComponent("share/wine/wine.inf")
        try fm.createDirectory(at: inf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: inf)
        let time = Date(timeIntervalSince1970: 1_780_000_000)
        try fm.setAttributes([.modificationDate: time], ofItemAtPath: inf.path)
        let prefix = temp.appendingPathComponent("Prefix")
        XCTAssertFalse(GameRuntime.needsWineUpdate(prefix: prefix, wineInf: inf), "No prefix yet: prepare makes it")
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        let stamp = prefix.appendingPathComponent(".update-timestamp")
        try "1780000000\n".write(to: stamp, atomically: true, encoding: .utf8)
        XCTAssertFalse(GameRuntime.needsWineUpdate(prefix: prefix, wineInf: inf))
        try "1770000000\n".write(to: stamp, atomically: true, encoding: .utf8)
        XCTAssertTrue(GameRuntime.needsWineUpdate(prefix: prefix, wineInf: inf), "A new runtime build")
        try "disable\n".write(to: stamp, atomically: true, encoding: .utf8)
        XCTAssertFalse(GameRuntime.needsWineUpdate(prefix: prefix, wineInf: inf))
    }
}
