import Foundation
import SwiftUI
import NetworkExtension

@MainActor
final class VPNViewModel: ObservableObject {
    @Published var state: VPNConnectionState = .disconnected
    @Published var selectedServer = VPNServer(id: UUID(), name: "", country: "", city: "", flag: "🌐", latitude: 55.7558, longitude: 37.6173, latencyMilliseconds: 0)
    @Published var usesAutomaticServer = UserDefaults.standard.object(forKey: "usesAutomaticServer") as? Bool ?? true {
        didSet { UserDefaults.standard.set(usesAutomaticServer, forKey: "usesAutomaticServer") }
    }
    @Published var speedMode: SpeedMode = SpeedMode(rawValue: UserDefaults.standard.integer(forKey: "speedMode")) ?? .balanced {
        didSet { UserDefaults.standard.set(speedMode.rawValue, forKey: "speedMode") }
    }
    @Published var preferredTransport: TransportKind = .automatic {
        didSet { UserDefaults.standard.set(preferredTransport.rawValue, forKey: "preferredTransport") }
    }
    @Published var disconnectOnSleep = UserDefaults.standard.bool(forKey: "disconnectOnSleep") {
        didSet { UserDefaults.standard.set(disconnectOnSleep, forKey: "disconnectOnSleep") }
    }
    @Published var reconnectAfterWake = UserDefaults.standard.object(forKey: "reconnectAfterWake") as? Bool ?? true {
        didSet { UserDefaults.standard.set(reconnectAfterWake, forKey: "reconnectAfterWake") }
    }
    @Published var routeAPNsThroughVPN = UserDefaults.standard.bool(forKey: "routeAPNsThroughVPN") {
        didSet { UserDefaults.standard.set(routeAPNsThroughVPN, forKey: "routeAPNsThroughVPN") }
    }
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
    @Published private(set) var isMeasuringLatency = false
    @Published private(set) var connectivity = ConnectivitySnapshot(
        hasNetworkPath: true,
        networkKind: .other,
        vk: .unknown,
        google: .unknown,
        checkedAt: Date()
    )
    @Published private(set) var resolvedTransport: TransportKind = .amneziaWG

    private var remoteServers: [UUID: RemoteVPNServer] = [:]
    private var wasConnectedBeforeSleep = false

    init() {
        if let raw = UserDefaults.standard.string(forKey: "preferredTransport"), let value = TransportKind(rawValue: raw) {
            preferredTransport = value
        }
        restoreLocalServers()
        Task { await restoreSystemState() }
    }

    var networkName: String { connectivity.networkKind.rawValue }
    var selectedRemoteServer: RemoteVPNServer? { remoteServers[selectedServer.id] }

    var serverDisplayName: String {
        if servers.isEmpty { return "Нет сохранённых серверов" }
        return usesAutomaticServer ? "Автовыбор" : (selectedServer.city.isEmpty ? selectedServer.name : selectedServer.city)
    }

    var activeTransport: TransportKind {
        preferredTransport == .automatic ? resolvedTransport : preferredTransport
    }

    var statusDetail: String {
        switch state {
        case .disconnected:
            return connectionError ?? connectivity.summary
        case .connecting:
            return activeTransport == .vkTurn ? "Подключаем VK обход" : "Подключаем AmneziaWG"
        case .connected:
            if isMeasuringLatency { return "Проверяем пинг…" }
            return connectivity.summary
        case .reconnecting:
            return "Переподключение через \(activeTransport.rawValue)"
        }
    }

    var pingText: String {
        selectedServer.latencyMilliseconds > 0 ? "\(selectedServer.latencyMilliseconds) мс" : "—"
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

    func refreshConnectivity() {
        Task {
            connectivity = await ConnectivityDiagnostics.shared.run()
            if preferredTransport == .automatic { resolvedTransport = connectivity.recommendedTransport }
        }
    }

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

            connectivity = await ConnectivityDiagnostics.shared.run()
            let chosenTransport: TransportKind
            if preferredTransport == .automatic {
                chosenTransport = connectivity.recommendedTransport
                resolvedTransport = chosenTransport
            } else {
                chosenTransport = preferredTransport
                resolvedTransport = chosenTransport
            }

            if chosenTransport == .vkTurn && !hasValidVKLink {
                connectionError = "Добавьте ссылку VK-звонка для режима VK обход"
                state = .disconnected
                return
            }

            saveVKLink()
            guard let profile = remoteServers[selectedServer.id]?.tunnelProfile ?? ActivationStore.shared.serverProfile else {
                connectionError = "Сохранённая конфигурация сервера повреждена"
                state = .disconnected
                return
            }

            UserDefaults.standard.set(speedMode.rawValue, forKey: "vkTurnConnections")

            do {
                try await VPNController.shared.connect(transport: chosenTransport, vkCallLink: normalizedVKLink, profile: profile)
                guard state == .connecting else { return }
                withAnimation(.snappy(duration: 0.35)) { state = .connected }
                await measureTunnelLatency()
                if liveActivitiesEnabled {
                    LiveActivityController.shared.start(server: selectedServer.city, latency: selectedServer.latencyMilliseconds, transport: chosenTransport.rawValue)
                }
                Task {
                    connectivity = await ConnectivityDiagnostics.shared.run()
                    await refreshServers()
                }
            } catch {
                connectionError = "Не удалось подключиться: \(error.localizedDescription)"
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

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            wasConnectedBeforeSleep = state == .connected
            if disconnectOnSleep && wasConnectedBeforeSleep { disconnect() }
        case .active:
            if wasConnectedBeforeSleep && reconnectAfterWake && state == .disconnected {
                wasConnectedBeforeSleep = false
                connect()
            }
        default:
            break
        }
    }

    func restoreSystemState() async {
        let restored = await VPNController.shared.restoreState()
        switch restored.status {
        case .connected, .reasserting, .connecting:
            if let transport = restored.transport { resolvedTransport = transport }
            state = restored.status == .connected ? .connected : .connecting
            await refreshServers()
            await measureTunnelLatency()
        default:
            break
        }
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "darktunnel", url.host?.lowercased() == "disconnect" else { return }
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

    private func measureTunnelLatency() async {
        guard state == .connected, let url = URL(string: "https://api.31-77-148-80.sslip.io/health") else { return }
        isMeasuringLatency = true
        defer { isMeasuringLatency = false }
        var samples: [Int] = []
        for _ in 0..<3 {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let started = ContinuousClock.now
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) else { continue }
                let elapsed = started.duration(to: .now)
                let ms = max(1, Int(Double(elapsed.components.attoseconds) / 1_000_000_000_000_000 + Double(elapsed.components.seconds) * 1000))
                samples.append(ms)
            } catch { }
        }
        guard !samples.isEmpty else { return }
        samples.sort()
        updateSelectedLatency(samples[samples.count / 2])
    }

    private func updateSelectedLatency(_ latency: Int) {
        let updated = VPNServer(id: selectedServer.id, name: selectedServer.name, country: selectedServer.country, city: selectedServer.city, flag: selectedServer.flag, latitude: selectedServer.latitude, longitude: selectedServer.longitude, latencyMilliseconds: latency)
        selectedServer = updated
        if let index = servers.firstIndex(where: { $0.id == updated.id }) { servers[index] = updated }
        AppLog.shared.info("Latency", "Пинг туннеля: \(latency) мс")
    }

    private func restoreLocalServers() {
        let merged = ServerDirectoryCache.merge(ServerDirectoryCache.load(), provisioned: ActivationStore.shared.serverProfile)
        if !merged.isEmpty { ServerDirectoryCache.save(merged) }
        apply(merged, preserveSelection: false)
    }

    private func apply(_ remote: [RemoteVPNServer], preserveSelection: Bool) {
        let previousID = selectedServer.id
        let previousLatency = selectedServer.latencyMilliseconds
        remoteServers = Dictionary(uniqueKeysWithValues: remote.map { ($0.displayModel.id, $0) })
        servers = remote.map(\.displayModel)
        if preserveSelection, let existing = servers.first(where: { $0.id == previousID }) {
            selectedServer = existing
            if previousLatency > 0 { updateSelectedLatency(previousLatency) }
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
        state = .reconnecting
        VPNController.shared.disconnect()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            connect()
        }
    }
}
