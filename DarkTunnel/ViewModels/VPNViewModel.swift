import Foundation
import SwiftUI

@MainActor
final class VPNViewModel: ObservableObject {
    @Published var state: VPNConnectionState = .disconnected
    @Published var selectedServer = VPNServer(id: UUID(), name: "", country: "", city: "", flag: "🌐", latitude: 55.7558, longitude: 37.6173, latencyMilliseconds: 0)
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
    @Published private(set) var servers: [VPNServer] = []
    @Published private(set) var isRefreshingServers = false

    private var remoteServers: [UUID: RemoteVPNServer] = [:]

    init() {
        Task { await refreshServers() }
    }

    var networkName: String { "Текущая сеть" }
    var selectedRemoteServer: RemoteVPNServer? { remoteServers[selectedServer.id] }
    var selectedServerHost: String { selectedRemoteServer?.host ?? ActivationStore.shared.serverProfile?.host ?? "—" }

    var serverDisplayName: String {
        if servers.isEmpty { return "Нет доступных серверов" }
        return usesAutomaticServer ? "Автовыбор" : (selectedServer.city.isEmpty ? selectedServer.name : selectedServer.city)
    }

    var activeTransport: TransportKind {
        switch preferredTransport {
        case .automatic: return .vkTurn
        case .amneziaWG: return .amneziaWG
        case .vkTurn: return .vkTurn
        }
    }

    var statusDetail: String {
        switch state {
        case .disconnected: return connectionError ?? connectivity.summary
        case .connecting: return "Подключаем VK TURN и защищённый туннель"
        case .connected: return "\(activeTransport.rawValue) · \(selectedServer.latencyMilliseconds) мс"
        case .reconnecting: return "Переключаем сервер"
        }
    }

    private var normalizedVKLink: String { vkCallLink.trimmingCharacters(in: .whitespacesAndNewlines) }

    var hasValidVKLink: Bool {
        guard let url = URL(string: normalizedVKLink), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        let validHost = host == "vk.ru" || host.hasSuffix(".vk.ru") || host == "vk.com" || host.hasSuffix(".vk.com") || host == "vk.me" || host.hasSuffix(".vk.me")
        return validHost && url.path.contains("/call/")
    }

    func saveVKLink() {
        vkCallLink = normalizedVKLink
        UserDefaults.standard.set(vkCallLink, forKey: "vkCallLink")
    }

    func refreshConnectivity() { Task { connectivity = await ConnectivityDiagnostics.shared.run() } }

    func refreshServers() async {
        guard !isRefreshingServers else { return }
        isRefreshingServers = true
        defer { isRefreshingServers = false }
        do {
            let remote = try await ServerDirectoryClient.shared.fetchServers()
            remoteServers = Dictionary(uniqueKeysWithValues: remote.map { ($0.displayModel.id, $0) })
            servers = remote.map(\.displayModel)
            guard !servers.isEmpty else { throw ServerDirectoryError.noServers }
            if usesAutomaticServer {
                let recommended = try await ServerDirectoryClient.shared.fetchRecommended()
                selectedServer = recommended.displayModel
                remoteServers[selectedServer.id] = recommended
            } else if !servers.contains(where: { $0.id == selectedServer.id }) {
                selectedServer = servers[0]
            }
            connectionError = nil
            AppLog.shared.info("Servers", "Получено серверов: \(servers.count)")
        } catch {
            servers = []
            remoteServers = [:]
            connectionError = "Не удалось загрузить серверы: \(error.localizedDescription)"
            AppLog.shared.error("Servers", error.localizedDescription)
        }
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
            if servers.isEmpty { await refreshServers() }
            guard !servers.isEmpty else {
                state = .disconnected
                return
            }
            if usesAutomaticServer {
                do {
                    let recommended = try await ServerDirectoryClient.shared.fetchRecommended()
                    selectedServer = recommended.displayModel
                    remoteServers[selectedServer.id] = recommended
                } catch {
                    connectionError = "Автовыбор недоступен: \(error.localizedDescription)"
                    state = .disconnected
                    return
                }
            }
            let chosenTransport = activeTransport
            if chosenTransport == .vkTurn && !hasValidVKLink {
                connectionError = "Вставьте ссылку VK-звонка вида https://vk.ru/call/join/..."
                state = .disconnected
                return
            }
            saveVKLink()
            guard let profile = remoteServers[selectedServer.id]?.tunnelProfile ?? ActivationStore.shared.serverProfile else {
                connectionError = "Конфигурация сервера недоступна"
                state = .disconnected
                return
            }
            UserDefaults.standard.set(speedMode == .balanced ? profile.connectionsBalanced : profile.connectionsMaximum, forKey: "vkTurnConnections")
            do {
                try await VPNController.shared.connect(transport: chosenTransport, vkCallLink: normalizedVKLink, profile: profile)
                guard state == .connecting else { return }
                withAnimation(.snappy(duration: 0.35)) { state = .connected }
                if liveActivitiesEnabled {
                    LiveActivityController.shared.start(server: selectedServer.city, latency: selectedServer.latencyMilliseconds, transport: chosenTransport.rawValue)
                }
            } catch {
                connectionError = "Не удалось запустить VPN: \(error.localizedDescription)"
                state = .disconnected
                AppLog.shared.error("VPN", error.localizedDescription)
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
        Task {
            await refreshServers()
            reconnectIfNeeded()
        }
    }

    func select(_ server: VPNServer) {
        usesAutomaticServer = false
        selectedServer = server
        reconnectIfNeeded()
    }

    private func reconnectIfNeeded() {
        guard state == .connected else { return }
        disconnect()
        connect()
    }
}
