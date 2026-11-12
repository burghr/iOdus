import SwiftUI

/// The window content plus keyboard input. Snapshots use `RootContent` only.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        RootContent()
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onAppear {
                focused = true
                ControllerInput.shared.start(model)
                NetworkMonitor.shared.start(model)
                MouseBackButton.install(model)
            }
            .task { await model.start() }
            .onKeyPress(phases: [.down, .repeat]) { press in handle(press) ? .handled : .ignored }
            .onChange(of: model.stream == nil) { _, closed in
                if closed { focused = true }
            }
    }
}

/// Mouse input that SwiftUI does not give: the side "back" button (button
/// number 3), and the scroll wheel or trackpad. Scrolling moves the focus,
/// the same as the D-pad, and the lists follow the focus.
@MainActor
enum MouseBackButton {
    private static var monitors: [Any] = []
    private static var pending = CGSize.zero

    /// Trackpad points for one step. A mouse wheel notch is always one step.
    static let stepPoints: CGFloat = 40

    static func install(_ model: AppModel) {
        guard monitors.isEmpty else { return }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            StreamKeys.handle(event, model) ? nil : event
        }) { monitors.append(keys) }
        if let back = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown, handler: { event in
            guard event.buttonNumber == 3, model.stream == nil else { return event }
            model.back()
            return nil
        }) { monitors.append(back) }
        if let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { event in
            scrolled(event, model)
            return event
        }) { monitors.append(scroll) }
    }

    private static func scrolled(_ event: NSEvent, _ model: AppModel) {
        // A stream: the wheel belongs to the web player.
        if model.stream != nil { return }
        // Momentum after the fingers leave the trackpad would run far past the end.
        if !event.momentumPhase.isEmpty { return }
        if event.phase == .began { pending = .zero }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        guard event.hasPreciseScrollingDeltas else {
            // A mouse wheel: one notch is one step.
            if abs(dy) >= abs(dx), dy != 0 { model.scroll(vertical: true, forward: dy < 0) }
            else if dx != 0 { model.scroll(vertical: false, forward: dx < 0) }
            return
        }
        pending.width += dx
        pending.height += dy
        // Content follows the fingers: a negative delta shows the items after.
        while abs(pending.height) >= stepPoints {
            model.scroll(vertical: true, forward: pending.height < 0)
            pending.height += pending.height < 0 ? stepPoints : -stepPoints
            pending.width = 0
        }
        while abs(pending.width) >= stepPoints {
            model.scroll(vertical: false, forward: pending.width < 0)
            pending.width += pending.width < 0 ? stepPoints : -stepPoints
            pending.height = 0
        }
    }
}

/// Keys while a cloud stream is open. The web view has the keyboard then, so
/// SwiftUI does not see the keys; a local monitor sees them first.
@MainActor
enum StreamKeys {
    static let escape: UInt16 = 53, returnKey: UInt16 = 36, space: UInt16 = 49
    static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126

    /// Returns true when iOdus used the key.
    static func handle(_ event: NSEvent, _ model: AppModel) -> Bool {
        guard let session = model.stream else { return false }
        if session.menuOpen {
            switch event.keyCode {
            case up: model.move(.up)
            case down: model.move(.down)
            case left: model.move(.left)
            case right: model.move(.right)
            case returnKey, space: model.confirm()
            case escape: model.back()
            default: break
            }
            return true    // The menu has the keyboard; the stream gets nothing.
        }
        let input: StreamInput = event.keyCode == escape && event.modifierFlags.contains(.shift) ? .shiftEscape : .other
        guard StreamInputGate.route(input, session: session) == .openMenu else { return false }
        model.openStreamMenu()
        return true
    }
}

extension RootView {
    /// Backspace: U+007F from the Mac keyboard, or U+0008 (KeyEquivalent.delete).
    static func isBackspace(_ press: KeyPress) -> Bool {
        press.key == .delete || press.characters == "\u{7F}" || press.characters == "\u{8}"
    }

    /// One handler for all keys, so that typed text in the search box and the
    /// control keys do not collide.
    fileprivate func handle(_ press: KeyPress) -> Bool {
        // A stream: the keys go to the web player. StreamKeys handles the menu keys.
        if model.stream != nil { return false }
        // The Mac Backspace key sends U+007F, not KeyEquivalent.delete (U+0008).
        if Self.isBackspace(press) {
            model.deleteKey()
            return true
        }
        switch press.key {
        case .leftArrow: model.move(.left)
        case .rightArrow: model.move(.right)
        case .upArrow: model.move(.up)
        case .downArrow: model.move(.down)
        case .return: if press.phase == .down { model.confirm() }
        case .escape: if press.phase == .down { model.back() }
        case .space:
            if model.isTyping { model.type(" ") } else if press.phase == .down { model.confirm() }
        default:
            let text = press.characters
            if press.modifiers.contains(.command) {
                guard text.lowercased() == "f" else { return false }
                model.focusSearch()
                return true
            }
            if model.isTyping {
                let printable = text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
                guard !text.isEmpty, printable else { return false }
                model.type(text)
                return true
            }
            switch text.lowercased() {
            case "x": if press.phase == .down { model.xPressed() }
            case "/": model.focusSearch()
            default: return false
            }
        }
        return true
    }
}

struct RootContent: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let s = Theme.scale(for: geo.size)
            ZStack {
                Theme.background
                if model.account == .ready, let flow = model.setup {
                    SetupView(flow: flow, scale: s)
                } else if model.account == .ready {
                    switch model.screen {
                    case .home:
                        HomeView(scale: s)
                    case .library:
                        LibraryView(scale: s)
                    case .downloads:
                        DownloadsView(scale: s)
                    case .settings:
                        SettingsView(scale: s)
                    case .friends:
                        FriendsView(scale: s)
                    case .store:
                        StoreView(scale: s)
                    case .storeItem(let id):
                        if let item = model.storeItem(id) { StoreItemView(item: item, scale: s) }
                    case .achievements(let titleId):
                        if let title = model.achievementTitles[titleId] { AchievementsView(title: title, scale: s) }
                    case .achievementHub:
                        AchievementHubView(scale: s)
                    case .messages:
                        MessagesView(scale: s)
                    case .conversation(let xuid):
                        ConversationView(peer: xuid, scale: s)
                    case .detail(let id):
                        if let game = model.game(id) { GameDetailView(game: game, scale: s) }
                    case .saveBackups(let id):
                        if let game = model.game(id) { SaveBackupsView(game: game, scale: s) }
                    case .runtimes(let id):
                        RuntimesView(gameID: id, scale: s)
                    case .gameSettings(let id):
                        if let game = model.game(id) { GameSettingsView(game: game, scale: s) }
                    }
                } else {
                    AccountView(scale: s)
                }
            }
            .overlay(alignment: .top) {
                TopBar(scale: s)
                    .padding(.horizontal, Theme.sidePadding * s)
                    .padding(.top, 40 * s)
            }
            .overlay {
                if let panel = model.statusPanel {
                    StatusPanelView(panel: panel, scale: s)
                        .transition(.opacity)
                }
            }
            .overlay {
                if let card = model.friendCard {
                    FriendCardView(card: card, scale: s)
                        .transition(.opacity)
                }
            }
            .overlay {
                if let prompt = model.installPrompt {
                    InstallPromptView(prompt: prompt, scale: s)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                ButtonHints(hints: hints, scale: s)
                    .padding(.horizontal, Theme.sidePadding * s)
                    .padding(.bottom, 36 * s)
            }
            .overlay(alignment: .bottomLeading) {
                if let toast = model.toast {
                    ToastView(text: toast, scale: s)
                        .padding(.leading, Theme.sidePadding * s)
                        .padding(.bottom, 90 * s)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.installPrompt?.game.id)
            .animation(.easeOut(duration: 0.2), value: model.friendCard?.friend.id)
            .animation(.easeOut(duration: 0.15), value: model.statusPanel)
            .animation(.easeOut(duration: 0.2), value: model.toast)
            .animation(.easeOut(duration: 0.18), value: model.stack)
            .overlay {
                // The cloud stream covers all iOdus screens, the top bar, and the hints.
                if let session = model.stream {
                    StreamOverlay(session: session, scale: s)
                }
            }
            .animation(.easeOut(duration: 0.25), value: model.account)
            .animation(.easeOut(duration: 0.25), value: model.setup?.step)
            // Nothing inside may make the screen larger than the window.
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }

    private var hints: [ButtonHint] {
        switch model.account {
        case .signedOut: return [.init(.a, "Sign in")]
        case .failed:
            if model.accountNeedsSignIn { return [.init(.a, "Sign in again"), .init(.x, "Try again")] }
            return [.init(.a, "Try again")]
        case .ready: break
        default: return []
        }
        if let flow = model.setup, model.statusPanel == nil {
            return flow.items.isEmpty ? [] : [.init(.a, "Select")]
        }
        if model.installPrompt != nil {
            return [.init(.a, "Select"), .init(.b, "Cancel")]
        }
        if model.statusPanel == .network {
            return [.init(.a, "Check again"), .init(.b, "Close")]
        }
        if model.statusPanel == .notifications {
            return model.notifications.isEmpty ? [.init(.b, "Close")]
                : [.init(.a, "Open"), .init(.b, "Close"), .init(.x, "Clear all")]
        }
        if model.friendCard != nil {
            return [.init(.a, "Message"), .init(.b, "Close")]
        }
        if model.statusPanel != nil {
            return [.init(.b, "Close")]
        }
        switch model.screen {
        case .home:
            return [.init(.a, "Select"), .init(.y, "Search")]
        case .library:
            switch model.libraryFocus {
            case .search:
                return [.init(.a, "Show games"), .init(.b, model.librarySearch.isEmpty ? "Leave search" : "Clear")]
            case .filters:
                return [.init(.a, "Show games"), .init(.b, "Back"), .init(.x, "Next filter"), .init(.y, "Search")]
            case .grid:
                return [.init(.a, "Select"), .init(.b, "Back"), .init(.x, "Next filter"), .init(.y, "Search")]
            }
        case .downloads:
            guard let task = model.focusedDownload else { return [.init(.b, "Back")] }
            var hints: [ButtonHint] = []
            switch task.status {
            case .running where task.canPause: hints.append(.init(.a, "Pause"))
            case .paused, .stopped: hints.append(.init(.a, "Resume"))
            case .failed: hints.append(.init(.a, "Try again"))
            default: break
            }
            hints.append(.init(.b, "Back"))
            switch task.status {
            case .running, .paused, .queued: hints.append(.init(.x, "Stop"))
            default: hints.append(.init(.x, "Remove from list"))
            }
            return hints
        case .settings:
            guard let row = model.focusedSettingsRow else { return [.init(.a, "Select"), .init(.b, "Back")] }
            switch row {
            case .account: return [.init(.a, "Sign out"), .init(.b, "Back")]
            case .installFolder: return [.init(.a, "Change"), .init(.b, "Back"), .init(.x, "Show in Finder")]
            case .rescan: return [.init(.a, "Rescan"), .init(.b, "Back")]
            case .runtime: return [.init(.a, "Runtimes"), .init(.b, "Back")]
            case .vcRuntime: return [.init(.a, model.vcRuntimeInstalled ? "Install again" : "Install"), .init(.b, "Back")]
            case .appUpdate:
                switch model.appUpdate {
                case .available: return [.init(.a, "Install"), .init(.b, "Back")]
                case .failed: return [.init(.a, "Release page"), .init(.b, "Back")]
                case .idle, .upToDate: return [.init(.a, "Check now"), .init(.b, "Back")]
                default: return [.init(.b, "Back")]
                }
            case .releaseNotes: return [.init(.a, "Open"), .init(.b, "Back")]
            case .fullScreen, .updates, .prereleases:
                return [.init(.a, "Switch"), .init(.b, "Back")]
            case .performance:
                return [.init(.a, "Change"), .init(.b, "Back")]
            default: return [.init(.b, "Back")]
            }
        case .friends:
            return [.init(.a, "Profile"), .init(.b, "Back"), .init(.x, "Refresh")]
        case .store:
            switch model.storeFocus {
            case .search:
                return [.init(.a, "Show results"), .init(.b, model.storeSearch.isEmpty ? "Leave search" : "Clear")]
            default:
                return [.init(.a, "Select"), .init(.b, "Back"), .init(.x, "Refresh"), .init(.y, "Search")]
            }
        case .storeItem:
            return [.init(.a, "Open on xbox.com"), .init(.b, "Back")]
        case .achievements:
            return [.init(.b, "Back"), .init(.x, model.showSecrets ? "Hide secrets" : "Show secrets")]
        case .achievementHub:
            return [.init(.a, "Achievements"), .init(.b, "Back"), .init(.x, "Refresh")]
        case .messages:
            return [.init(.a, "Open"), .init(.b, "Back"), .init(.x, "Refresh")]
        case .conversation:
            return [.init(.a, "Send"), .init(.b, "Back")]
        case .detail:
            return [.init(.a, "Select"), .init(.b, "Back")]
        case .saveBackups:
            return model.saveBackupList.isEmpty ? [.init(.b, "Back")]
                : [.init(.a, "Restore"), .init(.b, "Back"), .init(.x, "Delete")]
        case .runtimes(let id):
            let rows = model.runtimeRows(for: id)
            if model.runtimeIndex == -1 { return [.init(.a, "Switch"), .init(.b, "Back")] }
            if model.runtimeIndex >= 0, model.runtimeIndex < rows.count, case .available = rows[model.runtimeIndex] {
                return [.init(.a, "Download"), .init(.b, "Back")]
            }
            return id == nil ? [.init(.a, "Set as default"), .init(.b, "Back"), .init(.x, "Prepare again")]
                : [.init(.a, "Use"), .init(.b, "Back")]
        case .gameSettings:
            let row = GameSettingsRow(rawValue: model.gameSettingsIndex)
            let action = switch row {
            case .runtime, .showInFinder: "Open"
            case .uninstall: "Uninstall"
            default: "Change"
            }
            return [.init(.a, action), .init(.b, "Back")]
        }
    }
}

/// Art for a game: the Store box art, or a gradient while it loads.
struct GameArt: View {
    let game: Game
    var hero = false
    var width = 400

    var body: some View {
        let url = (hero ? game.heroArt ?? game.tileArt : game.tileArt).map { ImageStore.sized($0, width: width) }
        RemoteImage(url: url) {
            LinearGradient(colors: game.artColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay {
                    GeometryReader { g in
                        Circle()
                            .fill(.white.opacity(0.10))
                            .frame(width: g.size.width * 0.9)
                            .offset(x: g.size.width * 0.35, y: -g.size.height * 0.25)
                    }
                }
        }
    }
}

/// The screens before the library is ready: check, sign in, load, or error.
struct AccountView: View {
    @EnvironmentObject private var model: AppModel
    let scale: CGFloat

    var body: some View {
        let s = scale
        ZStack {
            LinearGradient(colors: [Theme.accent.opacity(0.45), Theme.background],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
            VStack(spacing: 22 * s) {
                switch model.account {
                case .checking, .loading:
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text(model.account == .checking ? "Checking your account" : "Loading your library")
                        .font(.system(size: 28 * s, weight: .semibold))
                case .signingIn:
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("Sign in with the Microsoft window")
                        .font(.system(size: 28 * s, weight: .semibold))
                    Text("iOdus continues when the sign-in is complete.")
                        .font(.system(size: 20 * s))
                        .foregroundStyle(Theme.textSecondary)
                case .signedOut:
                    Text("Welcome to iOdus")
                        .font(.system(size: 52 * s, weight: .bold))
                    Text("Sign in with your Microsoft account to see your games.")
                        .font(.system(size: 22 * s))
                        .foregroundStyle(Theme.textSecondary)
                    actionButton("Sign in", symbol: "person.crop.circle", s)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48 * s))
                        .foregroundStyle(Theme.buttonY)
                    Text(model.accountNeedsSignIn ? "Sign in again" : "Something went wrong")
                        .font(.system(size: 36 * s, weight: .semibold))
                    if model.accountNeedsSignIn {
                        Text("Microsoft no longer accepts the stored Xbox sign-in. It can come from an earlier sign-in, or from another app that uses the Xodus backend. Sign in again to continue; your installed games stay.")
                            .font(.system(size: 20 * s))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 900 * s)
                    }
                    Text(message)
                        .font(.system(size: (model.accountNeedsSignIn ? 16 : 20) * s))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900 * s)
                    if model.accountNeedsSignIn {
                        actionButton("Sign in again", symbol: "person.crop.circle", s)
                    } else {
                        actionButton("Try again", symbol: "arrow.clockwise", s)
                    }
                case .ready:
                    EmptyView()
                }
            }
            .foregroundStyle(Theme.textPrimary)
        }
    }

    private func actionButton(_ title: String, symbol: String, _ s: CGFloat) -> some View {
        HStack(spacing: 12 * s) {
            Image(systemName: symbol)
            Text(title)
        }
        .font(.system(size: 22 * s, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 48 * s)
        .frame(height: 64 * s)
        .background(Theme.accent)
        .focusFrame(true, scale: s, radius: 4)
        .contentShape(Rectangle())
        .onTapGesture { model.confirm() }
        .padding(.top, 20 * s)
    }
}
