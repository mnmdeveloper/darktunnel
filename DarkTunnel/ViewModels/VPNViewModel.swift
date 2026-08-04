import Foundation
import SwiftUI

@MainActor
final class VPNViewModel: ObservableObject {
    @Published var state: VPNConnectionState = .disconnected
    @Published var selectedServer: VPNServer = VPNServer.samples[0]
    @Published var usesAutomaticServer = true
    @Published var speedMode: SpeedMode = .maximum
    @Published var preferredTransport: TransportKind = .automatic
    @Published var disconnectOnSleep = false
    @Published var reconnectAfterWake = true
    @Published var routeAPNsThroughVPN = false
    @Published var connectivity = ConnectivitySnapshot(hasNetworkPath: true, vk: .unknown, google: .unknown, checkedAt: Date())
    @Published var liveActivitiesEnabled = UserDefaults.standard.object(forKey: "liveActivitiesEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(liveActivitiesEnabled, forKey: "liveActivitiesEnabled")
            if !liveActivitiesEnabled { LiveActivityController.shared.end() }
        }
    }
    @Published var connectionError: String?
    @Published var vkCallLink = UserDefaults.standard.string(forKey: "vkCallLink") ?? ""

    let servers = VPNServer.samples

    var networkName: String { "Текущая сеть" }

    var serverDisplayName: String {
        usesAutomaticServer ? "Автовыбор" : "\(selectedServer.flag) \(selectedServer.country)"
    }

    var activeTransport: TransportKind {
        switch preferredTransport {
        case .automatic:
            return connectivity.recommendedTransport
        case .amneziaWG:
            return .amneziaWG
        case .vkTurn:
            return .vkTurn
        }
    }

    var statusDetail: String {
        switch state {
        case .disconnected: return connectionError ?? connectivity.summary
        case .connecting: return "Проверяем VK и внешний интернет, затем выбираем режим"
        case .connected: return "\(activeTransport.rawValue) · \(selectedServer.latencyMilliseconds) мс"
        case .reconnecting: return "Переключаем сервер"
        }
    }

    private var normalizedVKLink: String {
        vkCallLink.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasValidVKLink: Bool {
        guard let url = URL(string: normalizedVKLink),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return false
        }

        let validHost = host == "vk.ru" || host.hasSuffix(".vk.ru") ||
            host == "vk.com" || host.hasSuffix(".vk.com") ||
            host == "vk.me" || host.hasSuffix(".vk.me")
        let validPath = url.path.contains("/call/") || url.path.contains("/call/join/")
        return validHost && validPath
    }

    func saveVKLink() {
        vkCallLink = normalizedVKLink
        UserDefaults.standard.set(vkCallLink, forKey: "vkCallLink")
    }

    func refreshConnectivity() {
        Task { connectivity = await ConnectivityDiagnostics.shared.run() }
    }

    func toggleConnection() {
        switch state {
        case .disconnected: connect()
        case .connecting, .reconnecting, .connected: disconnect()
        }
    }

    func connect() {
        connectionError = nil
        state = .connecting

        Task {
            connectivity = await ConnectivityDiagnostics.shared.run()
            guard connectivity.hasNetworkPath else {
                connectionError = "Нет доступа к сети"
                state = .disconnected
                return
            }

            let chosenTransport = activeTransport
            if chosenTransport == .vkTurn && !hasValidVKLink {
                connectionError = "Вставьте полную ссылку VK-звонка вида https://vk.ru/call/join/..."
                state = .disconnected
                return
            }

            saveVKLink()

            do {
                try await VPNController.shared.connect(transport: chosenTransport, vkCallLink: normalizedVKLink)
                guard state == .connecting else { return }
                withAnimation(.snappy(duration: 0.35)) { state = .connected }
                if liveActivitiesEnabled {
                    LiveActivityController.shared.start(server: selectedServer.city, latency: selectedServer.latencyMilliseconds, transport: chosenTransport.rawValue)
                }
            } catch {
                connectionError = "Не удалось запустить VPN: \(error.localizedDescription)"
                state = .disconnected
            }
        }
    }

    func disconnect() {
        VPNController.shared.disconnect()
        withAnimation(.snappy(duration: 0.3)) { state = .disconnected }
        LiveActivityController.shared.end()
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme == "darktunnel", url.host == "disconnect" else { return }
        disconnect()
    }

    func selectAutomaticServer() {
        usesAutomaticServer = true
        if let fastest = servers.min(by: { $0.latencyMilliseconds < $1.latencyMilliseconds }) { selectedServer = fastest }
        reconnectIfNeeded()
    }

    func select(_ server: VPNServer) {
        usesAutomaticServer = false
        selectedServer = server
        reconnectIfNeeded()
    }

    private func reconnectIfNeeded() {
        guard state == .connected else { return }
        state = .reconnecting
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard state == .reconnecting else { return }
            state = .connected
            if liveActivitiesEnabled {
                LiveActivityController.shared.update(server: selectedServer.city, latency: selectedServer.latencyMilliseconds, transport: activeTransport.rawValue)
            }
        }
    }
}
