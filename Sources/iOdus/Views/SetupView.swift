import SwiftUI

/// The setup after the sign-in: Rosetta, then the runtimes. The steps
/// that are done do not show. A, the mouse, or a click selects an item.
struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    let flow: SetupFlow
    let scale: CGFloat

    var body: some View {
        let s = scale
        ZStack {
            LinearGradient(colors: [Theme.accent.opacity(0.40), Theme.background],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
            VStack(alignment: .leading, spacing: 28 * s) {
                stepBar(s)
                switch flow.step {
                case .rosetta: rosetta(s)
                case .runtimes: runtimes(s)
                case .vcRuntime: vcRuntime(s)
                case nil: EmptyView()
                }
                if let error = flow.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 19 * s, weight: .medium))
                        .foregroundStyle(Theme.buttonY)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(56 * s)
            .frame(width: 1120 * s, alignment: .leading)
            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14 * s))
            .overlay(RoundedRectangle(cornerRadius: 14 * s).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
    }

    // MARK: Step bar

    /// "Setup" and, when there is more than one step, the steps in order.
    private func stepBar(_ s: CGFloat) -> some View {
        HStack(spacing: 12 * s) {
            Text("SETUP")
                .font(.system(size: 15 * s, weight: .bold))
                .tracking(2 * s)
                .foregroundStyle(Theme.accentBright)
            if flow.steps.count > 1 {
                ForEach(Array(flow.steps.enumerated()), id: \.offset) { i, step in
                    HStack(spacing: 8 * s) {
                        Image(systemName: i < flow.index ? "checkmark.circle.fill" : "\(i + 1).circle.fill")
                        Text(step.title)
                    }
                    .font(.system(size: 15 * s, weight: .semibold))
                    .foregroundStyle(i == flow.index ? Color.white : Theme.textSecondary)
                    .opacity(i > flow.index ? 0.6 : 1)
                }
            }
            Spacer(minLength: 0)
            if let step = flow.step, step.isOptional {
                Text(step == .vcRuntime ? "OPTIONAL · RECOMMENDED" : "OPTIONAL")
                    .font(.system(size: 13 * s, weight: .bold))
                    .tracking(1 * s)
                    .padding(.horizontal, 10 * s)
                    .frame(height: 24 * s)
                    .background(Color.white.opacity(0.10), in: Capsule())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: Rosetta

    @ViewBuilder
    private func rosetta(_ s: CGFloat) -> some View {
        header("Install Rosetta", symbol: "cpu",
               "The game runtime is an Intel program. macOS runs it with Rosetta, and Rosetta is not installed on this Mac.", s)
        VStack(alignment: .leading, spacing: 10 * s) {
            Text("macOS asks for an administrator password. You can also run this command in Terminal:")
                .font(.system(size: 17 * s))
                .foregroundStyle(Theme.textSecondary)
            Text("softwareupdate --install-rosetta --agree-to-license")
                .font(.system(size: 17 * s, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 16 * s)
                .padding(.vertical, 10 * s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 6 * s))
        }
        if flow.rosettaBusy {
            busy("Installing Rosetta. Use the macOS window to continue.", s)
        } else {
            HStack(spacing: 16 * s) {
                button("Install Rosetta", symbol: "arrow.down.circle", item: .installRosetta, primary: true, s)
                button("Check again", symbol: "arrow.clockwise", item: .checkRosetta, s)
                button("Not now", item: .notNow, s)
            }
        }
    }

    // MARK: Runtimes

    @ViewBuilder
    private func runtimes(_ s: CGFloat) -> some View {
        if flow.rosetta == .notAppleSilicon {
            header("This Mac cannot run games", symbol: "exclamationmark.triangle",
                   "The game runtimes need a Mac with Apple silicon. You can still use your library, your friends, your messages, and the Store.", s)
            button("Continue", item: .notNow, primary: true, s)
        } else if let index = flow.current, flow.choices.indices.contains(index) {
            installing(flow.choices[index], s)
        } else {
            runtimeList(s)
        }
    }

    /// The runtime that installs now, with its place in the queue.
    @ViewBuilder
    private func installing(_ choice: SetupChoice, _ s: CGFloat) -> some View {
        let place = flow.queue.count > 1
            ? "\((flow.queue.firstIndex(of: flow.current ?? -1) ?? 0) + 1) of \(flow.queue.count): " : ""
        switch flow.runtime {
        case .choose, .downloading:
            header("Downloading \(place)\(choice.name)", symbol: "arrow.down.circle",
                   "iOdus downloads the runtime from GitHub and checks its SHA-256.", s)
            if case .downloading(let done, let total) = flow.runtime {
                progress(done: done, total: total, s)
            }
            button("Cancel", item: .cancel, s)
        case .verifying:
            header("Checking \(place)\(choice.name)", symbol: "checkmark.shield", nil, s)
            busy("iOdus compares the SHA-256 of the file with the pinned value.", s)
        case .extracting:
            header("Installing \(place)\(choice.name)", symbol: "shippingbox", nil, s)
            busy("iOdus checks and extracts the runtime. This can take a minute.", s)
        case .copying:
            header("Copying \(place)\(choice.name)", symbol: "doc.on.doc", nil, s)
            busy("iOdus copies the Game Porting Toolkit from this Mac into its own folder.", s)
        }
    }

    @ViewBuilder
    private func runtimeList(_ s: CGFloat) -> some View {
        header("Choose the runtimes", symbol: "square.stack.3d.up",
               "A runtime runs Windows games on your Mac. Check the runtimes to install now. You can add or remove runtimes later in Settings > Runtimes.", s)

        VStack(spacing: 8 * s) {
            ForEach(flow.choices.indices, id: \.self) { index in
                choiceRow(index, s)
            }
        }

        let total = flow.checkedChoices.reduce(Int64(0)) { $0 + flow.choices[$1].size }
        if flow.needsLicense {
            VStack(alignment: .leading, spacing: 12 * s) {
                Text("D3DMetal is Apple software under Apple's license. Wine is free software under the GNU LGPL. Read the license before you continue.")
                    .font(.system(size: 17 * s))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16 * s) {
                    button("Read the license", symbol: "doc.text", item: .openLicense, s)
                    checkbox(s)
                }
            }
        }

        Divider().overlay(Color.white.opacity(0.12))

        HStack(spacing: 16 * s) {
            let ready = !flow.checkedChoices.isEmpty && (!flow.needsLicense || flow.licenseAccepted)
            button(flow.checkedChoices.isEmpty ? "Install" : "Install (\(Bytes.text(total)))",
                   symbol: "arrow.down.circle", item: .install, primary: true, dimmed: !ready, s)
            button("Not now", item: .notNow, s)
            Spacer(minLength: 0)
            if flow.checkedChoices.isEmpty {
                hint("Check at least one runtime.", s)
            } else if flow.needsLicense && !flow.licenseAccepted {
                hint("Accept the license to continue.", s)
            }
        }
    }

    /// One runtime of the list: a check box, the name and a line about it, and the size.
    private func choiceRow(_ index: Int, _ s: CGFloat) -> some View {
        let choice = flow.choices[index]
        let focused = flow.focusedItem == .choice(index)
        let symbol = choice.installed ? "checkmark.circle.fill" : (choice.checked ? "checkmark.square.fill" : "square")
        return HStack(spacing: 16 * s) {
            Image(systemName: symbol)
                .font(.system(size: 26 * s))
                .foregroundStyle(choice.checked || choice.installed
                                 ? (focused ? Theme.accent : Theme.accentBright)
                                 : (focused ? Color.black : .white))
            VStack(alignment: .leading, spacing: 3 * s) {
                Text(choice.name)
                    .font(.system(size: 19 * s, weight: .semibold))
                Text(choice.detail)
                    .font(.system(size: 15 * s))
                    .foregroundStyle(focused ? Color.black.opacity(0.7) : Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12 * s)
            Text(choice.installed ? "Installed" : Bytes.text(choice.size))
                .font(.system(size: 16 * s, weight: .medium))
                .foregroundStyle(focused ? Color.black.opacity(0.7) : Theme.textSecondary)
        }
        .foregroundStyle(focused ? Color.black : .white)
        .padding(.horizontal, 20 * s)
        .frame(height: 64 * s)
        .background(focused ? Color.white : Theme.tile.opacity(choice.installed ? 0.5 : 0.9))
        .opacity(choice.installed ? 0.6 : 1)
        .focusFrame(focused, scale: s, radius: 4)
        .contentShape(Rectangle())
        .onTapGesture { if !choice.installed { model.tapSetup(.choice(index)) } }
    }

    private func hint(_ text: String, _ s: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 16 * s))
            .foregroundStyle(Theme.textSecondary)
    }

    // MARK: Visual C++

    @ViewBuilder
    private func vcRuntime(_ s: CGFloat) -> some View {
        header("Install the Visual C++ runtime", symbol: "puzzlepiece.extension",
               "Microsoft's Visual C++ 2015-2022 runtime. Some games do not start without it.", s)
        facts([("Publisher", "Microsoft"),
               ("Download", "About 25 MB"),
               ("Check", "Microsoft's SHA-256"),
               ("Install", flow.vcInstallsNow ? "Now" : "At the first game")], s)
        Text(flow.vcInstallsNow
             ? "iOdus downloads Microsoft's installer and installs it in each game prefix now. You can change this in Settings."
             : "iOdus downloads Microsoft's installer when it makes a game prefix, at the first start of a game. You can change this in Settings.")
            .font(.system(size: 17 * s))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        actions(s) {
            button(flow.vcInstallsNow ? "Install now" : "Install at the first game", symbol: "checkmark.circle",
                   item: .install, primary: true, s)
            button("Skip", item: .skip, s)
        }
    }

    // MARK: Shared parts

    /// The facts row: up to four labeled columns.
    private func facts(_ items: [(String, String)], _ s: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in fact(item.0, item.1, s) }
        }
        .padding(.vertical, 18 * s)
        .padding(.horizontal, 22 * s)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8 * s))
    }

    /// A line, then the buttons of a step.
    private func actions<Content: View>(_ s: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 28 * s) {
            Divider().overlay(Color.white.opacity(0.12))
            HStack(spacing: 16 * s) { content() }
        }
    }

    private func progress(done: Int64, total: Int64, _ s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12 * s) {
            ProgressStrip(progress: total > 0 ? Double(done) / Double(total) : 0, scale: s)
                .frame(maxWidth: .infinity)
                .clipShape(Capsule())
            Text("\(Bytes.text(done)) of \(Bytes.text(total)) · \(total > 0 ? Int(Double(done) * 100 / Double(total)) : 0)%")
                .font(.system(size: 18 * s))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
        }
    }

    /// A text link for the mouse. (SwiftUI Link does not draw in snapshots.)
    private func link(_ title: String, symbol: String, url: URL, _ s: CGFloat) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 17 * s, weight: .medium))
            .foregroundStyle(Theme.accentBright)
            .contentShape(Rectangle())
            .onTapGesture { NSWorkspace.shared.open(url) }
    }

    /// "/Applications" or "~/Applications" for a button label.
    static func place(_ app: URL) -> String {
        app.deletingLastPathComponent().path
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    // MARK: Parts

    /// The icon, the title, and an optional short text of a step.
    private func header(_ title: String, symbol: String, _ text: String?, _ s: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 24 * s) {
            Image(systemName: symbol)
                .font(.system(size: 34 * s, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 76 * s, height: 76 * s)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16 * s))
            VStack(alignment: .leading, spacing: 6 * s) {
                Text(title)
                    .font(.system(size: 40 * s, weight: .bold))
                if let text {
                    Text(text)
                        .font(.system(size: 19 * s))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// One column of the facts row: a small label over a value.
    private func fact(_ label: String, _ value: String, _ s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4 * s) {
            Text(label.uppercased())
                .font(.system(size: 13 * s, weight: .bold))
                .tracking(1 * s)
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.system(size: 18 * s, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func busy(_ text: String, _ s: CGFloat) -> some View {
        HStack(spacing: 14 * s) {
            ProgressView().controlSize(.small).tint(.white)
            Text(text)
        }
        .font(.system(size: 19 * s))
        .foregroundStyle(Theme.textSecondary)
    }

    private func checkbox(_ s: CGFloat) -> some View {
        let focused = flow.focusedItem == .license
        let on = flow.licenseAccepted
        return HStack(spacing: 14 * s) {
            Image(systemName: on ? "checkmark.square.fill" : "square")
                .font(.system(size: 26 * s))
                .foregroundStyle(on ? Theme.accentBright : (focused ? Color.black : .white))
            Text("I accept Apple's license for D3DMetal")
                .font(.system(size: 20 * s, weight: .semibold))
        }
        .foregroundStyle(focused ? Color.black : .white)
        .padding(.horizontal, 22 * s)
        .frame(height: 58 * s)
        .background(focused ? Color.white : Theme.tile.opacity(0.9))
        .focusFrame(focused, scale: s, radius: 4)
        .contentShape(Rectangle())
        .onTapGesture { model.tapSetup(.license) }
    }

    /// A focusable button. `dimmed` shows a button that needs the license first.
    private func button(_ title: String, symbol: String? = nil, item: SetupItem, primary: Bool = false,
                        dimmed: Bool = false, _ s: CGFloat) -> some View {
        let focused = flow.focusedItem == item
        return HStack(spacing: 10 * s) {
            if let symbol { Image(systemName: symbol) }
            Text(title)
        }
        .font(.system(size: 20 * s, weight: .semibold))
        .foregroundStyle(focused && !primary ? Color.black : .white)
        .padding(.horizontal, 28 * s)
        .frame(height: 58 * s)
        .background(primary ? Theme.accent : (focused ? Color.white : Theme.tile.opacity(0.9)))
        .opacity(dimmed && !focused ? 0.45 : 1)
        .focusFrame(focused, scale: s, radius: 4)
        .contentShape(Rectangle())
        .onTapGesture { model.tapSetup(item) }
    }
}
