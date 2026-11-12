import SwiftUI

/// The runtimes. From Settings (no game): A sets the default, X prepares a
/// runtime again. From a game page: A sets the runtime of the game.
struct RuntimesView: View {
    @EnvironmentObject private var model: AppModel
    let gameID: Game.ID?
    let scale: CGFloat

    var body: some View {
        let s = scale
        let game = gameID.flatMap { model.game($0) }
        VStack(alignment: .leading, spacing: 14 * s) {
            HStack(alignment: .firstTextBaseline, spacing: 20 * s) {
                Text(game == nil ? "Game runtimes" : "Runtime")
                    .font(.system(size: 40 * s, weight: .semibold))
                if let game {
                    Text(game.title).font(.system(size: 20 * s)).foregroundStyle(Theme.textSecondary)
                }
            }
            Text(game == nil
                 ? "The default runtime starts games that have no runtime of their own. Each runtime has its own Wine prefix."
                 : "Each runtime has its own Wine prefix. The game gets its cloud save at the first start on a new runtime.")
                .font(.system(size: 18 * s))
                .foregroundStyle(Theme.textSecondary)
                .padding(.bottom, 10 * s)
            // The top box: the technology. The box below: its runtimes.
            RuntimeFamilyBox(selected: model.runtimeFamily, focused: model.runtimeIndex == -1, scale: s) { family in
                model.selectRuntimeFamily(family)
            }
            Text(model.runtimeFamily.detail)
                .font(.system(size: 17 * s))
                .foregroundStyle(Theme.textSecondary)
                .padding(.bottom, 6 * s)
            let rows = model.runtimeRows(for: gameID)
            let inUse = model.runtimeRowInUse(for: gameID)
            VStack(alignment: .leading, spacing: 10 * s) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    RuntimeRowView(row: row, defaultRuntime: model.defaultRuntime, selected: i == inUse,
                                   download: model.runtimeDownload, release: rowRelease(row), scale: s)
                        .frame(height: 86 * s)
                        .focusFrame(model.runtimeIndex == i, scale: s)
                        .contentShape(Rectangle())
                        .onTapGesture { model.tapRuntime(i) }
                }
                if rows.isEmpty {
                    Text("No runtime of this kind is available on this Mac.")
                        .font(.system(size: 18 * s))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.vertical, 20 * s)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.textPrimary)
        .frame(maxWidth: 1100 * s, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.sidePadding * s)
        .padding(.top, 150 * s)
        .background(
            LinearGradient(colors: [Color(white: 0.10), Theme.background], startPoint: .top, endPoint: .bottom)
        )
    }

    /// The installed release of a download row (an update), or nil.
    private func rowRelease(_ row: RuntimeRow) -> Int? {
        if case .available(let download) = row { return model.installedRelease(download.id) }
        return nil
    }
}

struct RuntimeRowView: View {
    let row: RuntimeRow
    let defaultRuntime: GameRuntime
    let selected: Bool
    let download: RuntimeDownloadState?
    let release: Int?                   // For an update: the installed release
    let scale: CGFloat

    var body: some View {
        let s = scale
        HStack(spacing: 20 * s) {
            Image(systemName: symbol)
                .font(.system(size: 26 * s))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 56 * s, height: 56 * s)
                .background(Color.white.opacity(0.06), in: Circle())
            VStack(alignment: .leading, spacing: 6 * s) {
                Text(title)
                    .font(.system(size: 22 * s, weight: .semibold))
                Text(detail)
                    .font(.system(size: 17 * s))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if selected {
                Label("In use", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 18 * s, weight: .medium))
                    .foregroundStyle(Theme.accentBright)
            } else if case .available = row, !isDownloading {
                Text(release == nil ? "Download" : "Update")
                    .font(.system(size: 18 * s, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 22 * s)
        .background(Theme.tile.opacity(0.9))
    }

    private var isDownloading: Bool {
        if case .available(let d) = row { return download?.id == d.id }
        return false
    }

    private var symbol: String {
        switch row {
        case .useDefault: return "arrow.uturn.backward.circle"
        case .installed: return "cpu"
        case .available: return "arrow.down.circle"
        }
    }

    private var title: String {
        switch row {
        case .useDefault: return "Use the default"
        case .installed(let runtime): return runtime.displayName
        case .available(let d): return d.displayName
        }
    }

    private var detail: String {
        switch row {
        case .useDefault:
            return "Now: \(defaultRuntime.displayName)"
        case .installed(let runtime):
            if let problem = runtime.problem { return problem }
            return runtime.isPrepared ? "Prefix ready" : "The prefix is prepared at the first game start"
        case .available(let d):
            if let state = download, state.id == d.id {
                if state.installing { return "Checking and installing…" }
                let percent = state.total > 0 ? Int(Double(state.done) / Double(state.total) * 100) : 0
                return "Downloading \(Bytes.text(state.done)) of \(Bytes.text(state.total)) · \(percent)%"
            }
            let what = release.map { "Release \(d.release) (installed: \($0))" } ?? "Not installed"
            if let fex = d.fex {
                return "\(what) · \(Bytes.text(fex.archives.reduce(0) { $0 + $1.size })) download · native Apple silicon, beta"
            }
            if let package = d.d3dmetal {
                return "\(what) · \(Bytes.text(d.size + package.size)) download · with Apple's D3DMetal \(package.version)"
            }
            return "\(what) · \(Bytes.text(d.size)) download · uses D3DMetal from your Game Porting Toolkit"
        }
    }
}

/// The technology choice at the top of the runtimes page: two parts side by side.
/// Left and right (or a click) switch it; the list below shows that technology.
struct RuntimeFamilyBox: View {
    let selected: RuntimeFamily
    let focused: Bool
    let scale: CGFloat
    let choose: (RuntimeFamily) -> Void

    var body: some View {
        let s = scale
        HStack(spacing: 0) {
            ForEach(RuntimeFamily.allCases, id: \.self) { family in
                let on = family == selected
                Text(family.title)
                    .font(.system(size: 20 * s, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56 * s)
                    .background(on ? Theme.accent.opacity(0.85) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { choose(family) }
            }
        }
        .background(Theme.tile.opacity(0.9))
        .focusFrame(focused, scale: s)
    }
}
