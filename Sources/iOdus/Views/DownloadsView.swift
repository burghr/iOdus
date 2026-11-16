import SwiftUI

/// The download queue: one row for each download, with progress.
struct DownloadsView: View {
    @EnvironmentObject private var model: AppModel
    let scale: CGFloat

    var body: some View {
        let s = scale
        VStack(alignment: .leading, spacing: 18 * s) {
            Text("Downloads")
                .font(.system(size: 40 * s, weight: .semibold))
                .padding(.bottom, 10 * s)
            if model.downloadTasks.isEmpty {
                Text("There are no downloads. Choose a game and select Install.")
                    .font(.system(size: 22 * s))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(Array(model.downloadTasks.enumerated()), id: \.element.id) { i, task in
                    DownloadRow(task: task, scale: s)
                        .focusFrame(model.downloadIndex == i, scale: s)
                        .contentShape(Rectangle())
                        .onTapGesture { model.tapDownload(i) }
                }
            }
            Spacer()
        }
        .foregroundStyle(Theme.textPrimary)
        .frame(maxWidth: 1300 * s, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.sidePadding * s)
        .padding(.top, 150 * s)
        .background(
            LinearGradient(colors: [Color(white: 0.10), Theme.background], startPoint: .top, endPoint: .bottom)
        )
    }
}

struct DownloadRow: View {
    let task: DownloadTask
    let scale: CGFloat

    var body: some View {
        let s = scale
        HStack(spacing: 24 * s) {
            RemoteImage(url: task.tileArt.map { ImageStore.sized($0, width: 200) }) {
                Theme.tile
            }
            .frame(width: 96 * s, height: 96 * s)
            .clipShape(RoundedRectangle(cornerRadius: 4 * s))

            VStack(alignment: .leading, spacing: 10 * s) {
                HStack {
                    Text(task.title)
                        .font(.system(size: 24 * s, weight: .semibold))
                    Spacer()
                    Text(statusText)
                        .font(.system(size: 18 * s, weight: .medium))
                        .foregroundStyle(statusColor)
                }
                ProgressStrip(progress: task.fraction ?? 0, scale: s * 1.4)
                    .clipShape(Capsule())
                HStack {
                    Text(task.error ?? task.phase)
                        .lineLimit(1)
                    Spacer()
                    Text(sizeText)
                        .monospacedDigit()
                }
                .font(.system(size: 17 * s))
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(18 * s)
        .background(Theme.tile.opacity(0.9))
    }

    private var statusText: String {
        switch task.status {
        case .queued: return "Queued"
        case .running: return task.fraction.map { "\(Int($0 * 100))%" } ?? "Starting"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .complete: return "Installed"
        case .failed: return "Failed"
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .complete: return Theme.accentBright
        case .failed: return Theme.buttonB
        case .paused, .stopped: return Theme.buttonY
        default: return Theme.textPrimary
        }
    }

    private var sizeText: String {
        var parts: [String] = []
        if let total = task.total { parts.append("\(Bytes.text(task.completed)) of \(Bytes.text(total))") }
        if task.rate > 0 { parts.append(Bytes.rate(task.rate)) }
        return parts.joined(separator: " · ")
    }
}

/// The dialog before a download: size, folder, free space.
struct InstallPromptView: View {
    @EnvironmentObject private var model: AppModel
    let prompt: InstallPrompt
    let scale: CGFloat

    var body: some View {
        let s = scale
        ZStack {
            Color.black.opacity(0.65)
                .onTapGesture { model.back() }
            VStack(alignment: .leading, spacing: 18 * s) {
                Text(title)
                    .font(.system(size: 34 * s, weight: .semibold))
                switch prompt.stage {
                case .loading:
                    HStack(spacing: 14 * s) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("Reading the package size from the Store…")
                    }
                    .font(.system(size: 20 * s))
                    .foregroundStyle(Theme.textSecondary)
                case .ready(let choice):
                    info("Download size", choice.downloadBytes.map(Bytes.text) ?? "Unknown", s)
                    info("Free space", prompt.freeBytes.map(Bytes.text) ?? "Unknown", s,
                         warn: tooSmall(choice))
                    info("Folder", prompt.destination, s)
                    if tooSmall(choice) {
                        Text("There may not be enough free space for this game.")
                            .font(.system(size: 18 * s))
                            .foregroundStyle(Theme.buttonY)
                    }
                case .failed(let message):
                    Text(message)
                        .font(.system(size: 20 * s))
                        .foregroundStyle(Theme.buttonB)
                case .saveConflict(let local, let cloud):
                    Text("The save on this Mac and the save in the cloud both changed. Choose the save to keep. The other one is replaced.")
                        .font(.system(size: 20 * s))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    info("Mac save", local.map(Self.when) ?? "Unknown time", s)
                    info("Cloud save", cloud.map(Self.when) ?? "Unknown time", s)
                    Text("iOdus keeps a backup copy of the Mac save before it downloads the cloud save.")
                        .font(.system(size: 17 * s))
                        .foregroundStyle(Theme.textSecondary)
                case .restoreBackup(let backup):
                    Text("The backup replaces the save of \(prompt.game.title) on this Mac. iOdus first makes a backup of the current Mac save, so that you can undo the restore.")
                        .font(.system(size: 20 * s))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    info("Backup from", Self.when(backup.date), s)
                    Text("At the next start, the restored save uploads. If the cloud save is newer, Play asks which save to keep.")
                        .font(.system(size: 17 * s))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .deleteBackup(let backup):
                    Text("The backup is deleted from this Mac. You cannot undo this.")
                        .font(.system(size: 20 * s))
                        .foregroundStyle(Theme.textSecondary)
                    info("Backup from", Self.when(backup.date), s)
                case .uninstall(let path, let bytes):
                    Text("The game files are deleted from this Mac. You cannot undo this, but you can install the game again.")
                        .font(.system(size: 20 * s))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    info("Folder", path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), s)
                    info("Frees", bytes.map(Bytes.text) ?? "Measuring…", s)
                case .offlinePC(let changes):
                    Text("Microsoft allows one offline PC for each account. If a different PC is the offline PC now, it loses its offline play.")
                        .font(.system(size: 20 * s))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("This changes a setting on your Microsoft account. Microsoft limits the number of changes.")
                        .font(.system(size: 20 * s))
                        .foregroundStyle(Theme.buttonY)
                        .fixedSize(horizontal: false, vertical: true)
                    if let changes { info("Microsoft", changes, s) }
                    Text("After the change, start each game one time online. Then the game can start without internet for 30 days.")
                        .font(.system(size: 17 * s))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Your saves stay: the cloud saves, and the Mac saves in the game runtimes, are not in the game folder.")
                        .font(.system(size: 17 * s))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 16 * s) {
                    if case .restoreBackup = prompt.stage {
                        button("Restore", index: 0, enabled: true, s)
                        button("Cancel", index: 1, enabled: true, s)
                    } else if case .deleteBackup = prompt.stage {
                        button("Delete", index: 0, enabled: true, s)
                        button("Cancel", index: 1, enabled: true, s)
                    } else if case .uninstall = prompt.stage {
                        button("Uninstall", index: 0, enabled: true, s)
                        button("Cancel", index: 1, enabled: true, s)
                    } else if case .offlinePC = prompt.stage {
                        button("Make offline PC", index: 0, enabled: true, s)
                        button("Cancel", index: 1, enabled: true, s)
                    } else if case .saveConflict = prompt.stage {
                        button("Use cloud save", index: 0, enabled: true, s)
                        button("Keep Mac save", index: 1, enabled: true, s)
                        button("Cancel", index: 2, enabled: true, s)
                    } else if case .failed = prompt.stage {
                        button("Close", index: 0, enabled: true, s)
                    } else {
                        button("Install", index: 0, enabled: isReady, s)
                        button("Cancel", index: 1, enabled: true, s)
                    }
                }
                .padding(.top, 10 * s)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(40 * s)
            .frame(width: 760 * s, alignment: .leading)
            .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 8 * s))
            .shadow(color: .black.opacity(0.6), radius: 30 * s)
        }
    }

    private var title: String {
        switch prompt.stage {
        case .saveConflict: return "Which save of \(prompt.game.title)?"
        case .restoreBackup: return "Restore this save?"
        case .deleteBackup: return "Delete this backup?"
        case .uninstall: return "Uninstall \(prompt.game.title)?"
        case .offlinePC: return "Make this Mac the offline PC?"
        default: break
        }
        return "Install \(prompt.game.title)?"
    }

    static func when(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private var isReady: Bool {
        if case .ready = prompt.stage { return true }
        return false
    }

    private func tooSmall(_ choice: InstallChoice) -> Bool {
        guard let free = prompt.freeBytes, let size = choice.installBytes ?? choice.downloadBytes else { return false }
        return free < size
    }

    private func info(_ label: String, _ value: String, _ s: CGFloat, warn: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 180 * s, alignment: .leading)
            Text(value)
                .foregroundStyle(warn ? Theme.buttonY : Theme.textPrimary)
                .lineLimit(2)
        }
        .font(.system(size: 20 * s))
    }

    private func button(_ title: String, index: Int, enabled: Bool, _ s: CGFloat) -> some View {
        let focused = prompt.focus == index
        // In a save conflict, both saves are real choices: no button is the default.
        var primary = index == 0
        switch prompt.stage {
        case .saveConflict, .restoreBackup, .deleteBackup, .offlinePC: primary = false
        default: break
        }
        return Text(title)
            .font(.system(size: 20 * s, weight: .semibold))
            .foregroundStyle(focused && !primary ? Color.black : .white)
            .frame(width: 200 * s, height: 56 * s)
            .background(primary ? Theme.accent.opacity(enabled ? 1 : 0.35) : (focused ? Color.white : Theme.tile))
            .focusFrame(focused, scale: s, radius: 4)
            .contentShape(Rectangle())
            .onTapGesture { model.tapPrompt(index) }
    }
}

/// A short message above the hint bar.
struct ToastView: View {
    let text: String
    let scale: CGFloat

    var body: some View {
        let s = scale
        HStack(spacing: 12 * s) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Theme.accentBright)
            Text(text)
        }
        .font(.system(size: 19 * s, weight: .medium))
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 22 * s)
        .padding(.vertical, 14 * s)
        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 6 * s))
        .shadow(color: .black.opacity(0.5), radius: 12 * s)
    }
}
