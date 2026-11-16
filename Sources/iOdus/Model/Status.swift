import Foundation
import Network

/// One connected game controller, for the top bar and the status panel.
struct ControllerStatus: Identifiable, Equatable {
    let id: String
    let name: String
    let battery: Float?     // 0...1, or nil when the controller does not report it
    let charging: Bool

    /// The SF Symbol for the battery level.
    var batterySymbol: String? {
        guard let battery else { return nil }
        if charging { return "battery.100.bolt" }
        switch battery {
        case 0.88...: return "battery.100"
        case 0.63..<0.88: return "battery.75"
        case 0.38..<0.63: return "battery.50"
        case 0.13..<0.38: return "battery.25"
        default: return "battery.0"
        }
    }

    var batteryText: String {
        guard let battery else { return "Battery level unknown" }
        let percent = Int((battery * 100).rounded())
        return charging ? "Charging · \(percent)%" : "Battery \(percent)%"
    }

    var lowBattery: Bool { !charging && (battery ?? 1) < 0.13 }
}

/// The panel that a top bar icon opens.
enum StatusPanel: Equatable {
    case controllers
    case network
    case notifications
}

extension AppModel {
    func toggleStatusPanel(_ panel: StatusPanel) {
        statusPanel = statusPanel == panel ? nil : panel
    }

    /// Called by ControllerInput when the controller list or a battery changes.
    func updateControllers(_ list: [ControllerStatus], connected: String?, disconnected: String?) {
        let wasLow = Set(controllers.filter(\.lowBattery).map(\.id))
        controllers = list
        if let connected { showToast("\(connected) connected.") }
        if let disconnected { showToast("\(disconnected) disconnected.") }
        if let low = list.first(where: { $0.lowBattery && !wasLow.contains($0.id) }) {
            showToast("\(low.name): the battery is low.")
        }
    }
}

// MARK: - Network

struct NetworkStatus: Equatable {
    enum Kind: Equatable { case wifi, wired, other, offline }
    enum Service: Equatable { case unknown, checking, reachable, unreachable }

    var kind: Kind = .other
    var xboxLive: Service = .unknown
    var checkedAt: Date?

    var online: Bool { kind != .offline }

    var symbol: String {
        switch kind {
        case .wifi: return "wifi"
        case .wired: return "cable.connector.horizontal"
        case .other: return "network"
        case .offline: return "wifi.slash"
        }
    }

    var kindText: String {
        switch kind {
        case .wifi: return "Wi-Fi"
        case .wired: return "Ethernet"
        case .other: return "Connected"
        case .offline: return "Offline"
        }
    }

    var serviceText: String {
        switch xboxLive {
        case .unknown: return "Not checked yet"
        case .checking: return "Checking…"
        case .reachable: return "Reachable"
        case .unreachable: return online ? "Not reachable" : "Not reachable (offline)"
        }
    }
}

/// Watches the network path, and checks that Xbox Live answers.
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private weak var model: AppModel?
    private var timer: Timer?
    private var started = false

    /// Any HTTP answer from this host means that Xbox Live is reachable.
    nonisolated static let probe = URL(string: "https://user.auth.xboxlive.com/")!

    func start(_ model: AppModel) {
        self.model = model
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            let kind = Self.kind(of: path)
            Task { @MainActor in NetworkMonitor.shared.pathChanged(kind) }
        }
        monitor.start(queue: DispatchQueue(label: "iodus.network"))
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { NetworkMonitor.shared.checkXboxLive() }
        }
    }

    nonisolated static func kind(of path: NWPath) -> NetworkStatus.Kind {
        guard path.status == .satisfied else { return .offline }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return .other
    }

    private func pathChanged(_ kind: NetworkStatus.Kind) {
        guard let model else { return }
        let before = model.network.kind
        model.network.kind = kind
        if before != kind, model.network.checkedAt != nil {
            if kind == .offline {
                model.showToast("You are offline. Downloads need the internet. A game with an offline license can start.",
                                seconds: 5)
            }
            else if before == .offline { model.showToast("You are online again.") }
        }
        checkXboxLive()
    }

    func checkXboxLive() {
        guard let model else { return }
        guard model.network.online else {
            model.network.xboxLive = .unreachable
            model.network.checkedAt = Date()
            return
        }
        model.network.xboxLive = .checking
        Task {
            let reachable = await Self.xboxLiveAnswers()
            guard let model = self.model else { return }
            model.network.xboxLive = reachable ? .reachable : .unreachable
            model.network.checkedAt = Date()
            // A library from the last online session: load the account again now.
            if reachable { model.reloadAfterReconnect() }
        }
    }

    /// True when Xbox Live gives an HTTP answer in the time limit.
    nonisolated static func xboxLiveAnswers(timeout: TimeInterval = 10) async -> Bool {
        var request = URLRequest(url: probe, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        return ((try? await URLSession.shared.data(for: request))?.1 is HTTPURLResponse)
    }
}
