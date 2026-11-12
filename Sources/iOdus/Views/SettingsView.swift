import SwiftUI

/// Settings: a list of categories on the left (as the filters of "My games &
/// apps"), and the rows of the selected category on the right. A category has
/// few rows, so the page always fits in the window.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    let scale: CGFloat

    var body: some View {
        let s = scale
        HStack(alignment: .top, spacing: 48 * s) {
            categories(s)
                .frame(width: 280 * s)
            VStack(alignment: .leading, spacing: 10 * s) {
                // The rows start at the height of the first category.
                Spacer().frame(height: 58 * s)
                ForEach(Array(model.settingsRows.enumerated()), id: \.element) { index, row in
                    rowView(row, s)
                        .focusFrame(model.focusedSettingsRow == row, scale: s)
                        .opacity(model.settingsFocus == .rows ? 1 : 0.75)
                        .contentShape(Rectangle())
                        .onTapGesture { model.tapSettings(index) }
                }
            }
            .frame(maxWidth: 1000 * s, alignment: .leading)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.textPrimary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Theme.sidePadding * s)
        .padding(.top, 150 * s)
        .background(
            LinearGradient(colors: [Color(white: 0.10), Theme.background], startPoint: .top, endPoint: .bottom)
        )
    }

    private func categories(_ s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8 * s) {
            Text("Settings")
                .font(.system(size: 34 * s, weight: .semibold))
                .padding(.bottom, 10 * s)
            ForEach(SettingsCategory.allCases, id: \.self) { category in
                let selected = model.settingsCategory == category.rawValue
                HStack(spacing: 14 * s) {
                    Image(systemName: category.symbol)
                        .frame(width: 28 * s)
                    Text(category.title)
                    Spacer()
                }
                .font(.system(size: 20 * s, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .padding(.vertical, 10 * s)
                .padding(.horizontal, 14 * s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Theme.tile : .clear,
                            in: RoundedRectangle(cornerRadius: Theme.cornerRadius * s))
                .focusFrame(selected && model.settingsFocus == .categories, scale: s, radius: Theme.cornerRadius)
                .contentShape(Rectangle())
                .onTapGesture { model.tapSettingsCategory(category.rawValue) }
            }
        }
    }

    private func rowView(_ row: SettingsRow, _ s: CGFloat) -> some View {
        let (symbol, title, detail, action) = content(row)
        return HStack(spacing: 24 * s) {
            Image(systemName: symbol)
                .font(.system(size: 30 * s))
                .frame(width: 56 * s)
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 6 * s) {
                Text(title)
                    .font(.system(size: 24 * s, weight: .semibold))
                ForEach(detail, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 18 * s))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(row == .appUpdate ? 2 : 1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if row == .fullScreen {
                SwitchView(on: AppSettings.startFullScreen, scale: s)
            } else if row == .updates {
                SwitchView(on: model.updateChecker.enabled, scale: s)
            } else if row == .prereleases {
                SwitchView(on: model.updateChecker.prereleases, scale: s)
            } else if let action {
                Text(action)
                    .font(.system(size: 18 * s, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 22 * s)
        .padding(.vertical, 10 * s)
        .background(Theme.tile.opacity(0.9))
    }

    private func content(_ row: SettingsRow) -> (String, String, [String], String?) {
        switch row {
        case .account:
            let name = [model.gamertag, model.accountName].filter { !$0.isEmpty }.joined(separator: " · ")
            return ("person.crop.circle", "Account", [name.isEmpty ? "Signed in" : name], "Sign out")
        case .installFolder:
            let free = Bytes.freeSpace(at: model.downloads.installRoot).map { "\(Bytes.text($0)) free" }
            return ("folder", "Install folder", [model.installFolderText] + (free.map { [$0] } ?? []), "Change")
        case .rescan:
            return ("arrow.clockwise", "Rescan install folder",
                    ["Finds the games in the install folder that iOdus does not know, for example after a fresh install."],
                    "Rescan")
        case .fullScreen:
            return ("arrow.up.left.and.arrow.down.right", "Start in full screen", [], nil)
        case .performance:
            let mode = AppSettings.performanceOverlay
            let detail: String = switch mode {
            case .off: "FPS and system load while you play"
            case .fps: "FPS in the game window (Metal HUD) · FPS changes apply at the next game start"
            case .system: "CPU, GPU, memory, and temperature at the top left"
            case .full: "FPS in the game window, and the system panel · FPS changes apply at the next game start"
            }
            return ("speedometer", "Performance overlay", [detail], mode.title)
        case .appUpdate:
            let current = UpdateCheck.currentVersion ?? "development build"
            switch model.appUpdate {
            case .idle:
                return ("arrow.down.circle", "iOdus \(current)", ["Checks GitHub for a new version."], "Check now")
            case .checking:
                return ("arrow.down.circle", "iOdus \(current)", ["Checking for a new version…"], nil)
            case .upToDate:
                return ("checkmark.circle", "iOdus \(current)", ["This is the newest version."], "Check now")
            case .available(let version):
                return ("arrow.down.circle.fill", "iOdus \(version) is available",
                        ["You have version \(current). iOdus downloads the update, checks its signature, and restarts."],
                        "Install")
            case .downloading(let version, let fraction):
                return ("arrow.down.circle.fill", "Downloading iOdus \(version)",
                        ["\(Int(fraction * 100))%"], nil)
            case .verifying(let version):
                return ("checkmark.shield", "Checking iOdus \(version)",
                        ["The checksum, the signature, and the notarization."], nil)
            case .installing(let version):
                return ("arrow.triangle.2.circlepath", "Installing iOdus \(version)",
                        ["iOdus restarts in a moment."], nil)
            case .failed(let version, let reason):
                return ("exclamationmark.triangle", "iOdus \(version) did not install", [reason], "Release page")
            }
        case .releaseNotes:
            let detail: String
            if case .available(let version) = model.appUpdate {
                detail = "What is new in iOdus \(version)."
            } else if let current = UpdateCheck.currentVersion {
                detail = "The release of iOdus \(current), with its notes and files."
            } else {
                detail = "The iOdus releases."
            }
            return ("safari", "Release notes on GitHub", [detail], "Open")
        case .updates:
            return ("clock.arrow.circlepath", "Check for updates automatically", ["Once a day."], nil)
        case .prereleases:
            return ("flask", "Install pre-releases",
                    ["Get test versions before the full release. A pre-release can have more problems."], nil)
        case .runtime:
            // A opens the runtimes page: the installed runtimes, downloads, and updates.
            var lines = model.runtimeStatus
            let available = model.availableDownloads.map { download in
                model.runtimes.contains { $0.id == download.id } ? "\(download.name) (update)" : download.name
            }
            if !available.isEmpty { lines.append("Available: " + available.joined(separator: ", ")) }
            return ("cpu", "Game runtime", lines, "Manage")
        case .vcRuntime:
            let installed = model.vcRuntimeInstalled
            return ("shippingbox", "Microsoft Visual C++ runtime", [model.vcRuntimeStatus],
                    model.installingVCRuntime ? "Installing…" : (installed ? "Install again" : "Install"))
        case .backend:
            guard let info = model.backendInfo else {
                return ("server.rack", "Backend", ["Reading… · Store region \(model.market)"], nil)
            }
            return ("server.rack", "Backend",
                    ["\(info.version) · Store region \(model.market)"] + (info.source.map { [$0] } ?? []) + [info.path], nil)
        case .exportLogs:
            return ("doc.zipper", "Export logs",
                    ["Makes a zip file on the Desktop for a bug report, without passwords, tokens, or account names."],
                    model.exportingLogs ? "Exporting…" : "Export")
        case .about:
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            return ("info.circle", "About iOdus",
                    ["Version \(version ?? "development build") · Uses Xodus and the Game Porting Toolkit Wine"], nil)
        }
    }
}

/// An on/off switch in the iOdus style. The row handles A and the click.
struct SwitchView: View {
    let on: Bool
    let scale: CGFloat

    var body: some View {
        let s = scale
        Capsule()
            .fill(on ? Theme.accent : Color(white: 0.32))
            .frame(width: 64 * s, height: 36 * s)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 28 * s, height: 28 * s)
                    .padding(4 * s)
                    .shadow(color: .black.opacity(0.3), radius: 2 * s, y: 1 * s)
            }
            .animation(.easeOut(duration: 0.15), value: on)
    }
}
