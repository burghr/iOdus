import AppKit

/// A step of the first-start setup. The sign-in comes before these steps.
enum SetupStep: Equatable {
    case rosetta
    case runtimes       // A list of the runtimes, each with a check box
    case vcRuntime      // Optional, recommended: Microsoft's Visual C++ runtime

    /// The name in the step bar.
    var title: String {
        switch self {
        case .rosetta: return "Rosetta"
        case .runtimes: return "Runtimes"
        case .vcRuntime: return "Visual C++"
        }
    }

    /// The optional steps have Skip in place of Not now.
    var isOptional: Bool { self == .vcRuntime }
}

/// The focusable items of the setup screen, in focus order.
enum SetupItem: Equatable {
    case installRosetta
    case checkRosetta
    case choice(Int)            // A runtime in SetupFlow.choices: A checks or clears it
    case openLicense            // Opens Apple's license PDF in the browser
    case license
    case install                // Runtimes: install the checked runtimes. Visual C++: install it.
    case cancel
    case notNow
    case skip                   // Optional steps: go to the next step
}

/// A runtime in the list of the setup.
struct SetupChoice: Equatable {
    enum Kind: Equatable {
        case gptk                       // The Game Porting Toolkit (Wine 7.7)
        case download(RuntimeDownload)  // A runtime from RuntimeDownload.catalog
    }

    var kind: Kind
    var checked: Bool
    var installed = false

    var downloadID: String? {
        if case .download(let download) = kind { return download.id }
        return nil
    }

    var name: String {
        switch kind {
        case .gptk: return "Game Porting Toolkit \(GPTKRelease.pinned.version)"
        case .download(let download): return download.name
        }
    }

    var size: Int64 {
        switch kind {
        case .gptk: return GPTKRelease.pinned.size
        case .download(let download): return download.downloadBytes
        }
    }

    /// The runtime has Apple's D3DMetal, so Apple's license applies.
    var usesD3DMetal: Bool {
        if case .download(let download) = kind { return download.fex == nil }
        return true
    }

    /// One line about the runtime.
    var detail: String {
        switch kind {
        case .gptk:
            return "Wine 7.7 with D3DMetal 3 · Rosetta 2 · the older runtime, for a game that does not work on Wine 11"
        case .download(let download):
            if download.fex != nil {
                return download.id.hasSuffix("-alpha")
                    ? "Wine \(download.wineVersion) with FEX · native Apple silicon · alpha, with more fixes (Football Manager 27)"
                    : "Wine \(download.wineVersion) with FEX · native Apple silicon · beta"
            }
            if let package = download.d3dmetal, package.needsLayer {
                return "Wine \(download.wineVersion) with D3DMetal \(package.version) · Rosetta 2 · beta, for newer DirectX 12 games"
            }
            return "Wine \(download.wineVersion) with D3DMetal 3 · Rosetta 2 · recommended for most games"
        }
    }
}

/// The state of the setup screen after the sign-in: Rosetta, then the
/// runtimes, then the library. Steps that are done do not show.
struct SetupFlow: Equatable {
    enum RuntimeStage: Equatable {
        case choose
        case downloading(done: Int64, total: Int64)
        case verifying
        case extracting
        case copying
    }

    var steps: [SetupStep]
    var index = 0
    var focus = 0
    var rosetta: RosettaStatus
    var rosettaBusy = false
    var licenseAccepted = false
    var existing: [ExistingGPTK] = []
    /// The runtimes of the list, and the stage of the runtime that installs now.
    var choices: [SetupChoice] = []
    var runtime: RuntimeStage = .choose
    /// The index in `choices` of the runtime that installs now, and its place in the queue.
    var current: Int?
    var queue: [Int] = []
    var error: String?
    /// The Visual C++ step: true when a game prefix exists, so that the install starts now.
    var vcInstallsNow = false

    var step: SetupStep? { index < steps.count ? steps[index] : nil }

    /// The checked runtimes that are not installed.
    var checkedChoices: [Int] { choices.indices.filter { choices[$0].checked && !choices[$0].installed } }

    /// Apple's license is needed when a checked runtime has D3DMetal.
    var needsLicense: Bool { checkedChoices.contains { choices[$0].usesD3DMetal } }

    /// The steps that are still to do. On an Intel Mac, the runtimes step stays,
    /// so that the screen can tell why games do not start.
    /// `offerRuntimes` shows the runtimes step also when a runtime is ready
    /// (at the start, when the recommended runtime is missing).
    static func steps(rosetta: RosettaStatus, runtimeReady: Bool,
                      offerRuntimes: Bool = false, vcRuntime: Bool = false) -> [SetupStep] {
        var list: [SetupStep] = []
        if rosetta == .missing { list.append(.rosetta) }
        if rosetta == .notAppleSilicon { return [.runtimes] }
        if !runtimeReady || offerRuntimes { list.append(.runtimes) }
        if vcRuntime { list.append(.vcRuntime) }
        return list
    }

    var items: [SetupItem] {
        switch step {
        case .rosetta:
            return rosettaBusy ? [] : [.installRosetta, .checkRosetta, .notNow]
        case .runtimes:
            if rosetta == .notAppleSilicon { return [.notNow] }
            switch runtime {
            case .choose:
                let rows = choices.indices.filter { !choices[$0].installed }.map { SetupItem.choice($0) }
                return rows + [.openLicense, .license, .install, .notNow]
            case .downloading: return [.cancel]
            case .verifying, .extracting, .copying: return []
            }
        case .vcRuntime:
            return [.install, .skip]
        case nil:
            return []
        }
    }

    var focusedItem: SetupItem? {
        let list = items
        return list.indices.contains(focus) ? list[focus] : nil
    }
}

extension AppModel {
    private static let postponedKey = "setupPostponed"
    /// The user installed runtimes without the recommended Wine 11 runtime, or skipped
    /// the Visual C++ step. The start does not offer them again.
    static let skippedWineKey = "setupSkippedWineRuntime"
    static let skippedVCKey = "setupSkippedVCRuntime"

    var setupRoot: URL { setupRootOverride ?? GameRuntime.standard.root }

    /// True when a runtime can start games: the Game Porting Toolkit or a downloaded runtime.
    var hasReadyRuntime: Bool {
        if GPTKRelease.pinned.isInstalled(in: setupRoot) { return true }
        guard setupRootOverride == nil else { return false }
        return RuntimeCatalog.discover().dropFirst().contains { $0.problem == nil }
    }

    /// The runtimes of the setup list. Only the recommended runtime (the first
    /// of the catalog) is checked at first.
    func setupChoices() -> [SetupChoice] {
        let ready = setupRootOverride == nil
            ? Set(RuntimeCatalog.discover().dropFirst().filter { $0.problem == nil }.map(\.id)) : []
        var list = RuntimeDownload.catalog.enumerated().map { i, download in
            SetupChoice(kind: .download(download), checked: i == 0 && !ready.contains(download.id),
                        installed: ready.contains(download.id))
        }
        list.append(SetupChoice(kind: .gptk, checked: false, installed: GPTKRelease.pinned.isInstalled(in: setupRoot)))
        return list
    }

    /// Opens the setup at the start when a step is left, unless the user chose
    /// "Not now" before. Play opens it again when no runtime is ready.
    func checkSetupAtStart() {
        guard !UserDefaults.standard.bool(forKey: Self.postponedKey) else { return }
        openSetup(optional: true)
    }

    /// Opens the setup with the steps that are still to do. Returns false when nothing is left.
    /// `optional` offers the recommended runtime and the Visual C++ step (at the start, not from Play).
    @discardableResult
    func openSetup(rosetta: RosettaStatus = RosettaStatus.detect(), optional: Bool = false) -> Bool {
        let defaults = UserDefaults.standard
        let choices = setupChoices()
        let recommendedMissing = choices.first.map { !$0.installed } ?? false
        let offer = optional && !demo && recommendedMissing && !defaults.bool(forKey: Self.skippedWineKey)
        let vcWanted = optional && !demo && !AppSettings.vcRuntimeWanted && !defaults.bool(forKey: Self.skippedVCKey)
        let steps = SetupFlow.steps(rosetta: rosetta, runtimeReady: hasReadyRuntime,
                                    offerRuntimes: offer, vcRuntime: vcWanted)
        guard !steps.isEmpty else {
            setup = nil
            return false
        }
        var flow = SetupFlow(steps: steps, rosetta: rosetta)
        flow.choices = choices
        flow.existing = RuntimeSetup.findExisting(in: RuntimeSetup.candidates())
        setup = flow
        return true
    }

    // MARK: Input

    func moveSetup(_ direction: Direction) {
        guard var flow = setup else { return }
        let count = flow.items.count
        guard count > 0 else { return }
        switch direction {
        case .up, .left: flow.focus = max(0, flow.focus - 1)
        case .down, .right: flow.focus = min(count - 1, flow.focus + 1)
        }
        setup = flow
    }

    func tapSetup(_ item: SetupItem) {
        guard let index = setup?.items.firstIndex(of: item) else { return }
        setup?.focus = index
        confirmSetup()
    }

    func confirmSetup() {
        guard let flow = setup, let item = flow.focusedItem else { return }
        setup?.error = nil
        switch item {
        case .installRosetta: installRosetta()
        case .checkRosetta: checkRosetta(announce: true)
        case .choice(let index):
            guard flow.choices.indices.contains(index), !flow.choices[index].installed else { return }
            setup?.choices[index].checked.toggle()
        case .openLicense: NSWorkspace.shared.open(GPTKRelease.licenseURL)
        case .license: setup?.licenseAccepted.toggle()
        case .install:
            if flow.step == .runtimes { installCheckedRuntimes() }
            if flow.step == .vcRuntime {
                installVCRuntime()
                advanceSetup()
            }
        case .cancel:
            setupTask?.cancel()
        case .notNow:
            if flow.step == .runtimes {
                // Without a runtime, games do not start, so the setup stops here.
                UserDefaults.standard.set(true, forKey: Self.postponedKey)
                setup?.steps = Array(flow.steps.prefix(flow.index + 1))
            }
            advanceSetup()
        case .skip:
            if flow.step == .vcRuntime { UserDefaults.standard.set(true, forKey: Self.skippedVCKey) }
            advanceSetup()
        }
    }

    /// The next step, or the library after the last step.
    func advanceSetup() {
        guard var flow = setup else { return }
        flow.index += 1
        flow.focus = 0
        flow.error = nil
        prepareStep(&flow)
        if flow.step == nil {
            setup = nil
            setupTask = nil
            if hasReadyRuntime && RosettaStatus.detect() != .missing {
                UserDefaults.standard.removeObject(forKey: Self.postponedKey)
                showToast("The setup is complete. You can play your installed games now.", seconds: 5)
            }
        } else {
            setup = flow
        }
    }

    // MARK: Rosetta

    private func installRosetta() {
        setup?.rosettaBusy = true
        setupTask = Task {
            do {
                try await RosettaStatus.install()
                setup?.rosettaBusy = false
                checkRosetta(announce: true)
            } catch {
                setup?.rosettaBusy = false
                setup?.error = "Rosetta was not installed. \(error.localizedDescription)"
            }
        }
    }

    private func checkRosetta(announce: Bool) {
        let status = RosettaStatus.detect()
        setup?.rosetta = status
        if status == .installed {
            advanceSetup()
        } else if announce {
            setup?.error = "Rosetta is still missing."
        }
    }

    // MARK: Runtimes

    /// Installs the checked runtimes one after the other, then goes to the next step.
    private func installCheckedRuntimes() {
        guard let flow = setup else { return }
        let queue = flow.checkedChoices
        guard !queue.isEmpty else {
            if flow.choices.contains(where: \.installed) {
                advanceSetup()
            } else {
                setup?.error = "Check at least one runtime, or select Not now."
            }
            return
        }
        guard !flow.needsLicense || flow.licenseAccepted else {
            setup?.error = "Accept Apple's license for D3DMetal before you continue."
            setup?.focus = flow.items.firstIndex(of: .license) ?? 0
            return
        }
        let recommended = flow.choices.first?.downloadID
        if !queue.contains(where: { flow.choices[$0].downloadID == recommended }) {
            UserDefaults.standard.set(true, forKey: Self.skippedWineKey)
        }
        setup?.queue = queue
        setup?.focus = 0
        setupTask = Task {
            var installed: [String] = []
            for index in queue {
                guard let choice = setup?.choices[index] else { return }
                setup?.current = index
                do {
                    switch choice.kind {
                    case .gptk: try await installGPTK()
                    case .download(let download):
                        try await installSetupDownload(download)
                        installed.append(download.id)
                    }
                    setup?.choices[index].installed = true
                    setup?.choices[index].checked = false
                } catch {
                    runtimeFailed(error)
                    return
                }
            }
            chooseDefaultRuntime(installed: installed, recommended: recommended)
            runtimeInstalled()
        }
    }

    /// The recommended runtime becomes the default when the setup installed it.
    /// Without the Game Porting Toolkit, the first installed runtime becomes the default.
    private func chooseDefaultRuntime(installed: [String], recommended: String?) {
        if let recommended, installed.contains(recommended) {
            runtimeChoice.defaultID = recommended
        } else if let first = installed.first, !GPTKRelease.pinned.isInstalled(in: setupRoot),
                  !runtimes.contains(where: { $0.id == runtimeChoice.defaultID && $0.problem == nil }) {
            runtimeChoice.defaultID = first
        }
    }

    /// The Game Porting Toolkit: a copy of a matching app on this Mac, else the download.
    private func installGPTK() async throws {
        let release = GPTKRelease.pinned
        let root = setupRoot
        if let existing = setup?.existing.first(where: \.matches) {
            setup?.runtime = .copying
            try await Task.detached { try RuntimeSetup.copyExisting(existing, release: release, into: root) }.value
            return
        }
        let archive = root.appendingPathComponent("download", isDirectory: true)
            .appendingPathComponent("\(release.folder).tar.xz")
        setup?.runtime = .downloading(done: 0, total: release.size)
        try RuntimeSetup.checkSpace(for: release, at: root)
        try await RuntimeSetup.download(release, to: archive) { done, total in
            Task { @MainActor in
                guard case .downloading = self.setup?.runtime else { return }
                self.setup?.runtime = .downloading(done: done, total: total)
            }
        }
        try Task.checkCancellation()
        setup?.runtime = .verifying
        try await Task.detached {
            do {
                try RuntimeSetup.verify(archive, sha256: release.sha256)
            } catch {
                try? FileManager.default.removeItem(at: archive)
                throw error
            }
        }.value
        setup?.runtime = .extracting
        try await Task.detached { try RuntimeSetup.extract(archive: archive, release: release, into: root) }.value
        try? FileManager.default.removeItem(at: archive)
    }

    /// A runtime of the catalog, with the same download and checks as Settings > Runtimes.
    private func installSetupDownload(_ download: RuntimeDownload) async throws {
        let total = download.downloadBytes
        setup?.runtime = .downloading(done: 0, total: total)
        try await fetchRuntime(download, progress: { done, size in
            guard case .downloading = self.setup?.runtime else { return }
            self.setup?.runtime = .downloading(done: done, total: size > 0 ? size : total)
        }, installing: { self.setup?.runtime = .extracting })
    }

    /// Reads the state that a step needs when it shows.
    private func prepareStep(_ flow: inout SetupFlow) {
        if flow.step == .vcRuntime { flow.vcInstallsNow = vcRuntimeCount.total > 0 }
    }

    private func runtimeInstalled() {
        setup?.runtime = .choose
        setup?.current = nil
        setup?.queue = []
        objectWillChange.send()
        advanceSetup()
    }

    private func runtimeFailed(_ error: Error) {
        setup?.runtime = .choose
        setup?.current = nil
        setup?.queue = []
        setup?.focus = 0
        objectWillChange.send()
        // A cancel is the user's choice, not an error.
        if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
        setup?.error = error.localizedDescription
    }
}
