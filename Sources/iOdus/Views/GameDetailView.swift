import SwiftUI

/// The game page: full art, the title, and a row of actions.
struct GameDetailView: View {
    @EnvironmentObject private var model: AppModel
    let game: Game
    let scale: CGFloat

    var body: some View {
        let s = scale
        ZStack(alignment: .bottomLeading) {
            HeroBackground(game: game)
            VStack(alignment: .leading, spacing: 18 * s) {
                Text(game.title)
                    .font(.system(size: 64 * s, weight: .bold))
                Text(game.publisher)
                    .font(.system(size: 22 * s))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 22 * s) {
                    Text(game.access == .gamePass ? "Included with Game Pass" : "Owned")
                        .foregroundStyle(game.access == .gamePass ? Theme.accentBright : Theme.textSecondary)
                    if let played = game.lastPlayed {
                        Text("Last played \(Self.relative(played))")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if game.installState == .installed, let lease = model.offlineLease(for: game) {
                        Label(lease.text, systemImage: "wifi.slash")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let score = game.gamerscore {
                        HStack(spacing: 6 * s) {
                            GamerscoreMark(size: 18 * s)
                            Text("\(score.current) / \(score.total)")
                                .monospacedDigit()
                        }
                        .foregroundStyle(Theme.textSecondary)
                    }
                }
                .font(.system(size: 18 * s, weight: .medium))
                if game.installState == .installed, let line = saveLine {
                    Label(line.text, systemImage: line.symbol)
                        .font(.system(size: 18 * s, weight: .medium))
                        .foregroundStyle(line.color)
                }
                Spacer().frame(height: 20 * s - 18 * s)
                HStack(spacing: 16 * s) {
                    ForEach(Array(model.detailActions(for: game).enumerated()), id: \.element) { i, action in
                        actionButton(action, index: i, s)
                    }
                }
                if let launcher = game.launcher, game.installState == .notInstalled {
                    Label("This game installs with \(launcher). iOdus cannot install it.",
                          systemImage: "info.circle")
                        .font(.system(size: 17 * s))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 8 * s)
                }
                if game.installState == .installed, let stub = model.gameStub(game) {
                    Label(stub.note(for: game.title), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 17 * s))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 8 * s)
                }
                if let note = model.runtimeNote(for: game) {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 17 * s))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 8 * s)
                }
                if game.installState == .installed && model.isUnityGame(game) {
                    Label("Use Borderless in the game settings. Exclusive full screen is not stable with D3DMetal.",
                          systemImage: "info.circle")
                        .font(.system(size: 17 * s))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 8 * s)
                }
                if case .downloading(let p) = game.installState {
                    VStack(alignment: .leading, spacing: 8 * s) {
                        Text("\(model.downloads.task(game.id)?.phase ?? "Downloading") · \(Int(p * 100))%")
                            .font(.system(size: 18 * s))
                            .foregroundStyle(Theme.textSecondary)
                        ProgressStrip(progress: p, scale: s)
                            .frame(width: 520 * s)
                            .clipShape(Capsule())
                    }
                    .padding(.top, 12 * s)
                }
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.sidePadding * s)
            .padding(.bottom, 170 * s)
        }
    }

    /// The cloud save line: the state from the local save folders of the runtime.
    private var saveLine: (text: String, symbol: String, color: Color)? {
        let status = model.cloudSaveStatus(for: game)
        let playing = model.playState.gameID == game.id
        switch status {
        case .noSaves:
            return ("No cloud saves from iOdus yet", "icloud", Theme.textSecondary)
        case .synced(let date):
            return ("Cloud saves synced" + (date.map { " · \(Self.moment($0))" } ?? ""),
                    "checkmark.icloud", Theme.accentBright)
        case .conflict:
            return ("Save conflict · choose a save when you press Play", "exclamationmark.icloud.fill",
                    Color(red: 1.0, green: 0.6, blue: 0.2))
        case .waiting:
            if playing { return ("Cloud saves upload while you play", "arrow.triangle.2.circlepath.icloud", Theme.accentBright) }
            if model.uploadingSaves == game.id {
                return ("Uploading the save…", "arrow.triangle.2.circlepath.icloud", Theme.accentBright)
            }
            return ("Saves not uploaded yet · they upload at the next start", "exclamationmark.icloud",
                    Color(red: 1.0, green: 0.75, blue: 0.25))
        case nil:
            return nil
        }
    }

    static func moment(_ date: Date, now: Date = Date()) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let day = relative(date, now: now)
        return day == "today" || day == "yesterday" ? "\(day) \(time)" : day
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today" }
        if calendar.isDateInYesterday(date) { return "yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if days > 0 && days < 30 { return "\(days) days ago" }
        return "on " + date.formatted(date: .abbreviated, time: .omitted)
    }

    private func actionButton(_ action: DetailAction, index: Int, _ s: CGFloat) -> some View {
        let focused = model.detailIndex == index
        let primary = action == .primary
        return HStack(spacing: 12 * s) {
            Image(systemName: action.symbol(for: game, play: model.playState))
            Text(action.title(for: game, play: model.playState))
        }
        .font(.system(size: 20 * s, weight: .semibold))
        .foregroundStyle(focused && !primary ? Color.black : .white)
        .padding(.horizontal, primary ? 44 * s : 26 * s)
        .frame(height: 60 * s)
        .background(primary ? Theme.accent : (focused ? Color.white : Theme.tile.opacity(0.9)))
        .focusFrame(focused, scale: s, radius: 4)
        .contentShape(Rectangle())
        .onTapGesture { model.tapDetail(index) }
    }
}
