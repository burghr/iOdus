import AppKit
import SwiftUI

/// The settings of one game: its runtime, its display, Wine's Retina mode, and
/// its performance overlay. The changes apply at the next start of the game.
struct GameSettingsView: View {
    @EnvironmentObject private var model: AppModel
    let game: Game
    let scale: CGFloat

    var body: some View {
        let s = scale
        VStack(alignment: .leading, spacing: 10 * s) {
            HStack(alignment: .firstTextBaseline, spacing: 20 * s) {
                Text("Game settings")
                    .font(.system(size: 40 * s, weight: .semibold))
                Text(game.title)
                    .font(.system(size: 20 * s))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text("These settings are for this game only. Changes apply at the next start of the game.")
                .font(.system(size: 18 * s))
                .foregroundStyle(Theme.textSecondary)
                .padding(.bottom, 10 * s)
            ForEach(GameSettingsRow.allCases, id: \.self) { row in
                if row == .showInFinder { Spacer().frame(height: 14 * s) }
                rowView(row, s)
                    .focusFrame(model.gameSettingsIndex == row.rawValue, scale: s)
                    .contentShape(Rectangle())
                    .onTapGesture { model.tapGameSettings(row.rawValue) }
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

    private func rowView(_ row: GameSettingsRow, _ s: CGFloat) -> some View {
        let options = model.gameOptions.options(game.id)
        let (symbol, title, detail, value) = content(row, options)
        return HStack(spacing: 24 * s) {
            Image(systemName: symbol)
                .font(.system(size: 30 * s))
                .frame(width: 56 * s)
                .foregroundStyle(row == .uninstall ? Theme.buttonB : Theme.textSecondary)
            VStack(alignment: .leading, spacing: 6 * s) {
                Text(title)
                    .font(.system(size: 24 * s, weight: .semibold))
                ForEach(detail, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 18 * s))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if row == .retina {
                SwitchView(on: options.retina, scale: s)
            } else if let value {
                Text(value)
                    .font(.system(size: 18 * s, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 22 * s)
        .padding(.vertical, 10 * s)
        .background(Theme.tile.opacity(0.9))
    }

    private func content(_ row: GameSettingsRow, _ options: GameOptions) -> (String, String, [String], String?) {
        switch row {
        case .runtime:
            let own = model.runtimeChoice.gameID(game.id) != nil
            let runtime = model.runtime(for: game)
            return ("cpu", "Runtime",
                    [own ? "This game uses \(runtime.displayName)."
                         : "The default runtime: \(runtime.displayName)."],
                    own ? "Change" : "Default")
        case .display:
            guard model.isUnityGame(game) else {
                return ("display", "Display",
                        ["This game chooses its own display. iOdus can choose it only for Unity games now."], nil)
            }
            guard let choice = options.display else {
                return ("display", "Display", ["The game opens on the display that it used last time."], "Default")
            }
            let detail = Displays.find(choice) == nil
                ? "\(choice.name) is not connected. The game chooses its own display."
                : "The game opens in full screen on \(choice.name)."
            return ("display", "Display", [detail, "If the game has its own display setting, that setting wins."],
                    choice.name)
        case .retina:
            let screen = Self.screen(for: options.display)
            let detail = options.retina
                ? "On: the game sees \(ScreenSize.text(screen.pixels)). Sharper, but about four times the GPU work."
                : "Off: the game sees \(ScreenSize.text(screen.points)), and macOS scales it up. Faster."
            return ("rectangle.on.rectangle", "Retina resolution", [detail], nil)
        case .performance:
            let detail: String
            let value: String
            if let mode = options.overlay {
                detail = "This game: \(mode.title). The FPS counter changes at the next game start."
                value = mode.title
            } else {
                detail = "The default from Settings: \(AppSettings.performanceOverlay.title)."
                value = "Default"
            }
            return ("speedometer", "Performance overlay", [detail], value)
        case .resetDisplay:
            guard model.isUnityGame(game) else {
                return ("arrow.counterclockwise", "Reset display settings",
                        ["Only for Unity games: this game keeps its display settings itself."], nil)
            }
            return ("arrow.counterclockwise", "Reset display settings",
                    ["Removes the screen size, window mode, and monitor that the game saved.",
                     "Use it when the game opens with a wrong size or flashes."], "Reset")
        case .showInFinder:
            let path = model.downloads.installs[game.id]?.path ?? ""
            return ("folder", "Show in Finder",
                    [path.isEmpty ? "Opens the folder of the game."
                                  : path.replacingOccurrences(of: NSHomeDirectory(), with: "~")], nil)
        case .uninstall:
            return ("trash", "Uninstall",
                    ["Deletes the game files. The saves stay in the cloud and on this Mac."], nil)
        }
    }

    /// The chosen display if it is connected, else the main screen, or the
    /// 1512 × 982 screen at 2x in a snapshot without a screen.
    static func screen(for choice: DisplayChoice?) -> ScreenSize {
        if let display = Displays.find(choice) { return ScreenSize(points: display.points, scale: display.scale) }
        guard let main = NSScreen.main else { return ScreenSize(points: CGSize(width: 1512, height: 982), scale: 2) }
        return ScreenSize(points: main.frame.size, scale: main.backingScaleFactor)
    }
}
