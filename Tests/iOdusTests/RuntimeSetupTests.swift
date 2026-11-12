import XCTest
@testable import iOdus

/// Tests for the GPTK download check, the extraction, the detection, and the
/// setup flow. Nothing here downloads, runs Wine, or runs softwareupdate.
final class RuntimeSetupTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private var release: GPTKRelease {
        GPTKRelease(version: "3.0-3", url: URL(string: "https://example.invalid/gptk.tar.xz")!,
                    sha256: "", size: 1, folder: "gptk-3.0-3")
    }

    /// Makes a small app with an executable wine64 and an Info.plist version.
    @discardableResult
    private func makeApp(at app: URL, version: String = "3.0-3", wine: Bool = true) throws -> URL {
        let fm = FileManager.default
        let bin = app.appendingPathComponent("Contents/Resources/wine/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        if wine {
            let wine64 = bin.appendingPathComponent("wine64")
            try "#!/bin/sh\n".write(to: wine64, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine64.path)
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version],
                                                       format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    /// Makes a .tar.xz with the app at the top, the same layout as the Gcenx release.
    private func makeArchive(wine: Bool = true) throws -> URL {
        let source = temp.appendingPathComponent("source", isDirectory: true)
        try makeApp(at: source.appendingPathComponent(GPTKRelease.appName), wine: wine)
        let archive = temp.appendingPathComponent("gptk-\(UUID().uuidString).tar.xz")
        try RuntimeSetup.run("/usr/bin/tar", ["-cJf", archive.path, "-C", source.path, GPTKRelease.appName])
        try FileManager.default.removeItem(at: source)
        return archive
    }

    // MARK: SHA-256

    func testSHA256OfAKnownValue() throws {
        let file = temp.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try RuntimeSetup.sha256(of: file),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertNoThrow(try RuntimeSetup.verify(file, sha256: "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"))
        XCTAssertThrowsError(try RuntimeSetup.verify(file, sha256: String(repeating: "0", count: 64))) { error in
            guard case RuntimeSetupError.checksum = error else { return XCTFail("Expected a checksum error, got \(error)") }
        }
    }

    func testPinnedReleaseMatchesTheRuntimeLayout() {
        let pinned = GPTKRelease.pinned
        XCTAssertEqual(pinned.sha256.count, 64)
        XCTAssertTrue(GameRuntime.wineBundle.hasPrefix(pinned.folder + "/" + GPTKRelease.appName),
                      "The installer must put the app where GameRuntime looks for wine64")
        XCTAssertEqual(GPTKRelease.wine64(inApp: pinned.installedApp(in: temp)).path,
                       GameRuntime.gptk(root: temp, prefix: temp).wine64.path)
    }

    // MARK: Extraction

    func testExtractInstallsTheAppAndRefusesAnExistingRuntime() throws {
        let archive = try makeArchive()
        let root = temp.appendingPathComponent("Runtime", isDirectory: true)
        try RuntimeSetup.extract(archive: archive, release: release, into: root)
        XCTAssertTrue(release.isInstalled(in: root))
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".setup-") }
        XCTAssertEqual(left, [], "The staging folder is removed")

        XCTAssertThrowsError(try RuntimeSetup.extract(archive: archive, release: release, into: root)) { error in
            guard case RuntimeSetupError.alreadyInstalled = error else { return XCTFail("Got \(error)") }
        }
        XCTAssertTrue(release.isInstalled(in: root), "The existing runtime stays")
    }

    func testExtractRefusesAnArchiveWithoutWine() throws {
        let archive = try makeArchive(wine: false)
        let root = temp.appendingPathComponent("Runtime", isDirectory: true)
        XCTAssertThrowsError(try RuntimeSetup.extract(archive: archive, release: release, into: root)) { error in
            guard case RuntimeSetupError.badArchive = error else { return XCTFail("Got \(error)") }
        }
        XCTAssertFalse(release.isInstalled(in: root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testCopyExistingApp() throws {
        let app = try makeApp(at: temp.appendingPathComponent("Applications/\(GPTKRelease.appName)"))
        let root = temp.appendingPathComponent("Runtime", isDirectory: true)
        try RuntimeSetup.copyExisting(ExistingGPTK(app: app, version: "3.0-3"), release: release, into: root)
        XCTAssertTrue(release.isInstalled(in: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path), "The source copy stays")
    }

    // MARK: Detection

    func testFindExistingReadsVersionsAndSkipsFoldersWithoutWine() throws {
        let good = try makeApp(at: temp.appendingPathComponent("a/\(GPTKRelease.appName)"))
        let old = try makeApp(at: temp.appendingPathComponent("b/\(GPTKRelease.appName)"), version: "2.1")
        let broken = try makeApp(at: temp.appendingPathComponent("c/\(GPTKRelease.appName)"), wine: false)
        let missing = temp.appendingPathComponent("d/\(GPTKRelease.appName)")
        let found = RuntimeSetup.findExisting(in: [good, old, broken, missing, good])
        XCTAssertEqual(found.map(\.version), ["3.0-3", "2.1"], "No duplicates, no broken or missing apps")
        XCTAssertEqual(found.map(\.matches), [true, false])
    }

    func testRosettaDetection() {
        XCTAssertEqual(RosettaStatus.detect(appleSilicon: true, fileExists: { $0 == RosettaStatus.runtimeFile }), .installed)
        XCTAssertEqual(RosettaStatus.detect(appleSilicon: true, fileExists: { _ in false }), .missing)
        XCTAssertEqual(RosettaStatus.detect(appleSilicon: false, fileExists: { _ in true }), .notAppleSilicon)
    }

    // MARK: Flow

    func testStepOrderSkipsStepsThatAreDone() {
        XCTAssertEqual(SetupFlow.steps(rosetta: .missing, runtimeReady: false), [.rosetta, .runtimes])
        XCTAssertEqual(SetupFlow.steps(rosetta: .installed, runtimeReady: false), [.runtimes])
        XCTAssertEqual(SetupFlow.steps(rosetta: .missing, runtimeReady: true), [.rosetta])
        XCTAssertEqual(SetupFlow.steps(rosetta: .installed, runtimeReady: true), [])
        XCTAssertEqual(SetupFlow.steps(rosetta: .notAppleSilicon, runtimeReady: false), [.runtimes],
                       "An Intel Mac sees why games do not start")
    }

    func testOptionalStepsComeAfterTheRuntimes() {
        XCTAssertEqual(SetupFlow.steps(rosetta: .missing, runtimeReady: false, offerRuntimes: true, vcRuntime: true),
                       [.rosetta, .runtimes, .vcRuntime])
        XCTAssertEqual(SetupFlow.steps(rosetta: .installed, runtimeReady: true, offerRuntimes: true),
                       [.runtimes], "The start offers the recommended runtime")
        XCTAssertEqual(SetupFlow.steps(rosetta: .installed, runtimeReady: true, vcRuntime: true), [.vcRuntime])
        XCTAssertEqual(SetupFlow.steps(rosetta: .notAppleSilicon, runtimeReady: false, offerRuntimes: true, vcRuntime: true),
                       [.runtimes], "An Intel Mac gets no optional steps")
        XCTAssertTrue(SetupStep.vcRuntime.isOptional)
        XCTAssertFalse(SetupStep.runtimes.isOptional)
    }

    func testItemsOfEachStage() {
        var flow = SetupFlow(steps: [.rosetta, .runtimes, .vcRuntime], rosetta: .missing)
        XCTAssertEqual(flow.items, [.installRosetta, .checkRosetta, .notNow])
        flow.rosettaBusy = true
        XCTAssertEqual(flow.items, [])
        flow.index = 1
        flow.choices = [SetupChoice(kind: .download(RuntimeDownload.crossover), checked: true),
                        SetupChoice(kind: .download(RuntimeDownload.crossoverD3DMetal4), checked: false, installed: true),
                        SetupChoice(kind: .gptk, checked: false)]
        XCTAssertEqual(flow.items, [.choice(0), .choice(2), .openLicense, .license, .install, .notNow],
                       "An installed runtime cannot be checked")
        flow.runtime = .downloading(done: 1, total: 2)
        XCTAssertEqual(flow.items, [.cancel])
        flow.runtime = .extracting
        XCTAssertEqual(flow.items, [])
        flow.runtime = .choose
        flow.index = 2
        XCTAssertEqual(flow.items, [.install, .skip])
        flow.index = 1
        flow.rosetta = .notAppleSilicon
        XCTAssertEqual(flow.items, [.notNow])
    }

    func testTheLicenseIsNeededOnlyForD3DMetal() {
        var flow = SetupFlow(steps: [.runtimes], rosetta: .installed)
        flow.choices = [SetupChoice(kind: .download(RuntimeDownload.crossover), checked: false),
                        SetupChoice(kind: .download(RuntimeDownload.highballArm64), checked: true),
                        SetupChoice(kind: .gptk, checked: false, installed: true)]
        XCTAssertEqual(flow.checkedChoices, [1])
        XCTAssertFalse(flow.needsLicense, "FEX has no Apple software")
        flow.choices[0].checked = true
        XCTAssertTrue(flow.needsLicense)
        XCTAssertEqual(flow.checkedChoices, [0, 1])
        XCTAssertGreaterThan(flow.choices[0].size, RuntimeDownload.crossover.size, "The size includes D3DMetal 3")
    }
}

@MainActor
final class SetupModelTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("setup-model-\(UUID().uuidString)")
        UserDefaults.standard.removeObject(forKey: "setupPostponed")
        UserDefaults.standard.removeObject(forKey: AppModel.skippedWineKey)
        UserDefaults.standard.removeObject(forKey: AppModel.skippedVCKey)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removeObject(forKey: "setupPostponed")
        UserDefaults.standard.removeObject(forKey: AppModel.skippedWineKey)
        UserDefaults.standard.removeObject(forKey: AppModel.skippedVCKey)
    }

    private func model() -> AppModel {
        let model = AppModel()
        model.startDemo()
        model.setupRootOverride = root
        return model
    }

    func testPlayShowsOnlyTheRuntimes() {
        let model = model()
        XCTAssertTrue(model.openSetup(rosetta: .installed))
        XCTAssertEqual(model.setup?.steps, [.runtimes])
    }

    func testTheListChecksOnlyTheRecommendedRuntime() {
        let model = model()
        model.openSetup(rosetta: .installed)
        let choices = model.setup?.choices ?? []
        XCTAssertEqual(choices.first?.downloadID, RuntimeDownload.catalog.first?.id)
        XCTAssertEqual(choices.filter(\.checked).count, 1)
        XCTAssertEqual(choices.last?.kind, .gptk, "The toolkit is the last, and not checked")
        XCTAssertEqual(choices.count, RuntimeDownload.catalog.count + 1)
    }

    func testABoxChecksAndClears() {
        let model = model()
        model.openSetup(rosetta: .installed)
        XCTAssertEqual(model.setup?.focusedItem, .choice(0))
        model.confirm()
        XCTAssertEqual(model.setup?.choices[0].checked, false)
        model.confirm()
        XCTAssertEqual(model.setup?.choices[0].checked, true)
    }

    func testNotNowOnTheRuntimesEndsTheSetup() {
        let model = model()
        model.setup = SetupFlow(steps: [.runtimes, .vcRuntime], rosetta: .installed)
        model.tapSetup(.notNow)
        XCTAssertNil(model.setup, "Without a runtime, the other steps do not help")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "setupPostponed"), "The start does not show it again")
    }

    func testSkipRemembersTheVisualCStep() {
        let model = model()
        model.setup = SetupFlow(steps: [.vcRuntime], rosetta: .installed)
        model.tapSetup(.skip)
        XCTAssertNil(model.setup)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: AppModel.skippedVCKey))
    }

    func testOpenSetupOnlyWithStepsLeft() throws {
        let model = model()
        XCTAssertTrue(model.openSetup(rosetta: .installed))
        XCTAssertEqual(model.setup?.steps, [.runtimes])
        XCTAssertFalse(model.isTyping, "The setup takes the input")

        let wine = GPTKRelease.wine64(inApp: GPTKRelease.pinned.installedApp(in: root))
        try FileManager.default.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: wine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        XCTAssertFalse(model.openSetup(rosetta: .installed), "Nothing left to do")
        XCTAssertNil(model.setup)
    }

    func testInstallNeedsACheckedRuntimeAndTheLicense() {
        let model = model()
        model.openSetup(rosetta: .installed)
        model.tapSetup(.install)
        XCTAssertEqual(model.setup?.runtime, .choose, "No download without the license")
        XCTAssertNil(model.setup?.current)
        XCTAssertEqual(model.setup?.focusedItem, .license, "The focus goes to the license box")
        XCTAssertNotNil(model.setup?.error)

        model.tapSetup(.choice(0))
        model.tapSetup(.install)
        XCTAssertEqual(model.setup?.error, "Check at least one runtime, or select Not now.")
        model.back()
        XCTAssertNotNil(model.setup, "B does not leave the setup")
    }
}

/// The real download of the pinned release into a temporary folder: the GitHub
/// redirect, the progress, the SHA-256, and the extraction. It reads from
/// GitHub only. Runs only with IODUS_LIVE=1.
final class RuntimeSetupLiveTests: XCTestCase {
    func testDownloadVerifyAndExtractThePinnedRelease() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IODUS_LIVE"] == "1")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("setup-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let release = GPTKRelease.pinned
        let archive = root.appendingPathComponent("download/\(release.folder).tar.xz")
        let reports = LockedCounter()
        try await RuntimeSetup.download(release, to: archive) { done, total in
            reports.add()
            XCTAssertEqual(total, release.size)
            XCTAssertLessThanOrEqual(done, total)
        }
        XCTAssertGreaterThan(reports.value, 10, "Progress arrives during the download")
        XCTAssertLessThanOrEqual(reports.value, 201, "Progress is limited to each 0.5 %")
        try RuntimeSetup.verify(archive, sha256: release.sha256)
        try RuntimeSetup.extract(archive: archive, release: release, into: root)
        XCTAssertTrue(release.isInstalled(in: root))
        XCTAssertEqual(RuntimeSetup.version(of: release.installedApp(in: root)), release.version)
        print("LIVE reports \(reports.value)")
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
