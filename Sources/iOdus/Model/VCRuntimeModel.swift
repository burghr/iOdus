import Foundation

/// Settings: Microsoft's Visual C++ runtime in the game prefixes. One action
/// installs it into every runtime prefix that exists; a runtime prefix that
/// iOdus makes later gets it during its setup (AppSettings.vcRuntimeWanted).
extension AppModel {
    /// The runtimes whose prefix exists (the others get the runtime at their setup).
    /// The native arm64 runtimes use Wine's own C++ runtime (GameRuntime.installsVCRuntime).
    private var preparedRuntimes: [GameRuntime] {
        runtimes.filter { $0.installsVCRuntime && FileManager.default.fileExists(atPath: VCRuntime.system32($0.prefix).path) }
    }

    /// (runtimes with Microsoft's runtime, runtimes with a prefix)
    var vcRuntimeCount: (installed: Int, total: Int) {
        if demo { return (0, 1) }
        let prepared = preparedRuntimes
        return (prepared.filter { VCRuntime.isInstalled(prefix: $0.prefix) }.count, prepared.count)
    }

    var vcRuntimeInstalled: Bool {
        let count = vcRuntimeCount
        return count.total > 0 && count.installed == count.total
    }

    /// The Settings line under the title.
    var vcRuntimeStatus: String {
        let count = vcRuntimeCount
        if count.total == 0 { return "Some games need it. iOdus installs it when it makes a game prefix." }
        if count.installed == count.total {
            return count.total == 1 ? "Installed. Games use Microsoft's DLLs first."
                : "Installed in all \(count.total) runtimes. Games use Microsoft's DLLs first."
        }
        if count.installed > 0 { return "Installed in \(count.installed) of \(count.total) runtimes. Install adds it to the others." }
        return "Some games need it. Downloads Microsoft's installer (about 25 MB) and installs it in each runtime."
    }

    func installVCRuntime() {
        guard !demo else {
            showToast("Demo mode cannot install the runtime.")
            return
        }
        guard playState == .idle, uploadingSaves == nil else {
            showToast("Stop the game first.")
            return
        }
        guard !installingVCRuntime else { return }
        AppSettings.vcRuntimeWanted = true
        // "Install again" on a full install repairs all prefixes; else only the missing ones.
        let all = vcRuntimeInstalled
        let targets = preparedRuntimes.filter { all || !VCRuntime.isInstalled(prefix: $0.prefix) }
        guard !targets.isEmpty else {
            showToast("iOdus installs the Visual C++ runtime when it makes a game prefix.")
            objectWillChange.send()
            return
        }
        installingVCRuntime = true
        showToast("Installing the Visual C++ runtime…", seconds: 180)
        Task {
            var failures: [String] = []
            for runtime in targets {
                do {
                    try await runtime.installVCRuntime()
                } catch {
                    failures.append("\(runtime.name): \(error.localizedDescription)")
                }
            }
            installingVCRuntime = false
            objectWillChange.send()
            if failures.isEmpty {
                showToast("The Visual C++ runtime is installed.")
            } else {
                showToast(failures.joined(separator: " "), seconds: 10)
            }
        }
    }
}
