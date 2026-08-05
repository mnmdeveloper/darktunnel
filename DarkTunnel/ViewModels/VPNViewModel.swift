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
        restoreLocalServers()
    }

    var networkName: String { "Текущая сеть" }
    var selectedRemoteServer: RemoteVPNServer? { remoteServers[selectedServer.id] }
    var selectedServerHost: String { selectedRemoteServer?.host ?? ActivationStore.shared.serverProfile?.host ?? "—" }

    var serverDisplayName: String {
        if servers.isEmpty { return "Нет сохранённых серверов" }
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
        case .disconnected: return connectionError ?? "Готов к подключению через VK TURN"
        case .connecting: return "Подключаемся к VK TURN и через него открываем WDTT"
        case .connected: return "\(activeTransport.rawValue) · \(selectedServer.latencyMilliseconds) мс"
        case .reconnecting: return "Переключаем сервер"
        }
    }

    private var normalizedVKLink: String { vkCallLink.trimmingCharacters(in: .whitespacesAndNewlines) }

    var hasValidVKLink: Bool {
        guard let url = URL(string: normalizedVKLink),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              scheme == "https" || scheme == "http" else { return false }
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
            let fetched = try await ServerDirectoryClient.shared.fetchServers()
            let merged = ServerDirectoryCache.merge(fetched, provisioned: ActivationStore.shared.serverProfile)
            ServerDirectoryCache.save(merged)
            apply(merged, preserveSelection: true)
            connectionError = nil
            AppLog.shared.info("Servers", "Список серверов обновлён: \(servers.count)")
        } catch {
            if servers.isEmpty { restoreLocalServers() }
            if servers.isEmpty { connectionError = "Нет сохранённой конфигурации сервера" }
            AppLog.shared.warning("Servers", "Backend недоступен, используется локальная конфигурация: \(error.localizedDescription)")
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
            if servers.isEmpty { restoreLocalServers() }
            guard !servers.isEmpty else {
                connectionError = "Нет сохранённой конфигурации. Повторите активацию по ссылке"
                state = .disconnected
                return
            }

            if usesAutomaticServer { selectBestLocalServer() }

            let chosenTransport = activeTransport
            if chosenTransport == .vkTurn && !hasValidVKLink {
                connectionError = "Вставьте ссылку VK-звонка вида https://vk.ru/call/join/..."
                state = .disconnected
                return
            }

            saveVKLink()
            guard let profile = remoteServers[selectedServer.id]?.tunnelProfile ?? ActivationStore.shared.serverProfile else {
                connectionError = "Сохранённая конфигурация сервера повреждена"
                state = .disconnected
                return
            }

            UserDefaults.standard.set(
                speedMode == .balanced ? profile.connectionsBalanced : profile.connectionsMaximum,
                forKey: "vkTurnConnections"
            )

            do {
                try await VPNController.shared.connect(
                    transport: chosenTransport,
                    vkCallLink: normalizedVKLink,
                    profile: profile
                )
                guard state == .connecting else { return }
                withAnimation(.snappy(duration: 0.35)) { state = .connected }
                if liveActivitiesEnabled {
                    LiveActivityController.shared.start(
                        server: selectedServer.city,
                        latency: selectedServer.latencyMilliseconds,
                        transport: chosenTransport.rawValue
                    )
                }
                Task {
                    connectivity = await ConnectivityDiagnostics.shared.run()
                    await refreshServers()
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
        selectBestLocalServer()
        reconnectIfNeeded()
    }

    func select(_ server: VPNServer) {
        usesAutomaticServer = false
        selectedServer = server
        reconnectIfNeeded()
    }

    private func restoreLocalServers() {
        let merged = ServerDirectoryCache.merge(
            ServerDirectoryCache.load(),
            provisioned: ActivationStore.shared.serverProfile
        )
        if !merged.isEmpty { ServerDirectoryCache.save(merged) }
        apply(merged, preserveSelection: false)
    }

    private func apply(_ remote: [RemoteVPNServer], preserveSelection: Bool) {
        let previousID = selectedServer.id
        remoteServers = Dictionary(uniqueKeysWithValues: remote.map { ($0.displayModel.id, $0) })
        servers = remote.map(\.displayModel)
        if preserveSelection, let existing = servers.first(where: { $0.id == previousID }) {
            selectedServer = existing
        } else {
            selectBestLocalServer()
        }
    }

    private func selectBestLocalServer() {
        guard !servers.isEmpty else { return }
        selectedServer = servers.min {
            let lhs = $0.latencyMilliseconds > 0 ? $0.latencyMilliseconds : Int.max
            let rhs = $1.latencyMilliseconds > 0 ? $1.latencyMilliseconds : Int.max
            return lhs < rhs
        } ?? servers[0]
    }

    private func reconnectIfNeeded() {
        guard state == .connected else { return }
        disconnect()
        connect()
    }
}
