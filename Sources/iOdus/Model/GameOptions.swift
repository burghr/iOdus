import Foundation

/// The settings of one game. The runtime choice of a game is in RuntimeChoice.
struct GameOptions: Codable, Equatable {
    /// Wine's Retina mode: the game sees the screen in pixels, not in points.
    var retina = false
    /// nil: the game uses the performance overlay from Settings.
    var overlay: PerformanceOverlayMode?
    /// nil: the game chooses its display. Only Unity games can use a choice now.
    var display: DisplayChoice?
}

/// A display that a game starts on. The name shows the choice when the
/// display is not connected.
struct DisplayChoice: Codable, Equatable {
    let id: String
    let name: String
}

/// The settings of each game (product ID), as JSON in UserDefaults.
struct GameOptionsStore {
    static let key = "gameOptions"
    let defaults: UserDefaults

    func options(_ productId: String) -> GameOptions {
        all()[productId.uppercased()] ?? GameOptions()
    }

    /// The default settings remove the entry of the game.
    func set(_ productId: String, _ options: GameOptions) {
        var map = all()
        map[productId.uppercased()] = options == GameOptions() ? nil : options
        defaults.set(try? JSONEncoder().encode(map), forKey: Self.key)
    }

    private func all() -> [String: GameOptions] {
        guard let data = defaults.data(forKey: Self.key),
              let map = try? JSONDecoder().decode([String: GameOptions].self, from: data) else { return [:] }
        return map
    }
}

/// The rows of the Game settings page.
enum GameSettingsRow: Int, CaseIterable {
    case runtime, display, resetDisplay, retina, performance, showInFinder, uninstall
}

extension PerformanceOverlayMode {
    /// The per-game cycle: the default from Settings (nil), then each mode.
    static func nextGameChoice(after choice: PerformanceOverlayMode?) -> PerformanceOverlayMode? {
        guard let choice else { return allCases.first }
        return choice == allCases.last ? nil : choice.next
    }
}

/// The screen size that a game sees, for the Retina row.
struct ScreenSize: Equatable {
    let points: CGSize
    let scale: CGFloat

    var pixels: CGSize { CGSize(width: points.width * scale, height: points.height * scale) }

    static func text(_ size: CGSize) -> String { "\(Int(size.width)) × \(Int(size.height))" }
}
