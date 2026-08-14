import Foundation
import SwiftUI
import NetworkExtension

@MainActor
final class VPNViewModel: ObservableObject {
    @Published var state: VPNConnectionState = .disconnected
    @Published var selectedServer = VPNServer(id: UUID(), name: "", country: "", city: "", flag: "🌐", latitude: 55.7558, longitude: 37.6173, latencyMilliseconds: 0)
    @Published var usesAutomaticServer = UserDefaults.standard.object(forKey: "usesAutomaticServer") as? Bool ?? true { didSet { UserDefaults.standard.set(usesAutomaticServer, forKey: "usesAutomaticServer") } }
    @Published var speedMode: SpeedMode = SpeedMode(rawValue: UserDefaults.standard.integer(forKey: "speedMode")) ?? .balanced { didSet { UserDefaults.standard.set(speedMode.rawValue, forKey: "speedMode") } }
    @Published var preferredTransport: TransportKind = .automatic { didSet { UserDefaults.standard.set(preferredTransport.rawValue, forKey: "preferredTransport") } }
    @Published var disconnectOnSleep = UserDefaults.standard.bool(forKey: "disconnectOnSleep") { didSet { UserDefaults.standard.set(disconnectOnSleep, forKey: "disconnectOnSleep") } }
    @Published var reconnectAfterWake = UserDefaults.standard.object(forKey: "reconnectAfterWake") as? Bool ?? true { didSet { UserDefaults.standard.set(reconnectAfterWake, forKey: "reconnectAfterWake") } }
    @Published var routeAPNsThroughVPN = UserDefaults.standard.bool(forKey: "routeAPNsThroughVPN") { didSet { UserDefaults.standard.set(routeAPNsThroughVPN, forKey: "routeAPNsThroughVPN") } }
    @Published var liveActivitiesEnabled = UserDefaults.standard.object(forKey: "liveActivitiesEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(liveActivitiesEnabled, forKey: "liveActivitiesEnabled")
            if liveActivitiesEnabled { syncLiveActivity() }
            else { LiveActivityController.shared.end() }
        }
    }
    @Published var connectionError: String?
    @Published var vkCallLink = UserDefaults.standard.string(forKey: "vkCallLink") ?? ""
    @Published private(set) var servers: [VPNServer] = []
    @Published private(set) var isRefreshingServers = false
    @Published private(set) var isMeasuringLatency = false
    @Published private(set) var connectivity = ConnectivitySnapshot(hasNetworkPath: true, networkKind: .other, vk: .unknown, google: .unknown, checkedAt: Date())
    @Published private(set) var resolvedTransport: TransportKind = .amneziaWG

    private var remoteServers: [UUID: RemoteVPNServer] = [:]
    private var wasConnectedBeforeSleep = false
    private var latencyMonitorTask: Task<Void, Never>?

    init() {
        if let raw = UserDefaults.standard.string(forKey: "preferredTransport"), let value = TransportKind(rawValue: raw) { preferredTransport = value }
        restoreLocalServers()
        Task { await restoreSystemState() }
    }

    deinit { latencyMonitorTask?.cancel() }

    var networkName: String { connectivity.networkKind.rawValue }
    var selectedRemoteServer: RemoteVPNServer? { remoteServers[selectedServer.id] }
    var serverDisplayName: String { servers.isEmpty ? "Нет сохранённых серверов" : (usesAutomaticServer ? "Автовыбор" : (selectedServer.city.isEmpty ? selectedServer.name : selectedServer.city)) }
    var activeTransport: TransportKind { preferredTransport == .automatic ? resolvedTransport : preferredTransport }
    var statusDetail: String {
        switch state {
        case .disconnected: return connectionError ?? connectivity.summary
        case .connecting: return activeTransport == .vkTurn ? "Подключаем VK обход" : "Подключаем AmneziaWG"
        case .connected: return isMeasuringLatency ? "Проверяем пинг…" : connectivity.summary
        case .reconnecting: return "Переподключение через \(activeTransport.rawValue)"
        }
    }

    var pingText: String {
        let latency = effectiveSelectedLatency
        return latency > 0 ? "\(latency) мс" : "—"
    }

    var effectiveSelectedLatency: Int {
        if selectedServer.latencyMilliseconds > 0 { return selectedServer.latencyMilliseconds }
        return remoteServers[selectedServer.id]?.latencyMS ?? 0
    }

    private var normalizedVKLink: String { vkCallLink.trimmingCharacters(in: .whitespacesAndNewlines) }

    var hasValidVKLink: Bool {
        guard let url = URL(string: normalizedVKLink), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        let validHost = host == "vk.ru" || host.hasSuffix(".vk.ru") || host == "vk.com" || host.hasSuffix(".vk.com") || host == "vk.me" || host.hasSuffix(".vk.me")
        return validHost && url.path.contains("/call/")
    }

    func saveVKLink() { vkCallLink = normalizedVKLink; UserDefaults.standard.set(vkCallLink, forKey: "vkCallLink") }
    func refreshConnectivity() { Task { connectivity = await ConnectivityDiagnostics.shared.run(); if preferredTransport == .automatic { resolvedTransport = connectivity.recommendedTransport } } }

    func refreshServers() async {
        guard !isRefreshingServers else { return }
        isRefreshingServers = true
        defer { isRefreshingServers = false }
        do {
            let fetched = try await ServerDirectoryClient.shared.fetchServers()
            var merged = ServerDirectoryCache.merge(fetched, provisioned: ActivationStore.shared.serverProfile)
            let secureServers = await ServerDirectoryClient.shared.fetchActivatedServers(fetched.map(\.id))
            for secure in secureServers { merged = ServerDirectoryCache.mergeSecure(secure, into: merged) }
            if let securePrimary = try? await ServerDirectoryClient.shared.fetchActivatedPrimary() { merged = ServerDirectoryCache.mergeSecure(securePrimary, into: merged) }
            ServerDirectoryCache.save(merged)
            apply(merged, preserveSelection: true)
            connectionError = nil
            let awgCount = secureServers.filter { !($0.amneziaConfig?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }.count
            AppLog.shared.info("Servers", "Список серверов обновлён: \(servers.count), AWG-профилей: \(awgCount)")
        } catch {
            if servers.isEmpty { restoreLocalServers() }
            if servers.isEmpty { connectionError = "Нет сохранённой конфигурации сервера" }
            AppLog.shared.warning("Servers", "Backend недоступен, используется локальная конфигурация: \(error.localizedDescription)")
        }
    }

    func toggleConnection() { switch state { case .disconnected: connect(); case .connecting, .reconnecting, .connected: disconnect() } }

    func connect() {
        connectionError = nil
        state = .connecting
        Task {
            if servers.isEmpty { restoreLocalServers() }
            guard !servers.isEmpty else { connectionError = "Нет сохранённой конфигурации. Повторите активацию по ссылке"; state = .disconnected; return }
            if usesAutomaticServer { selectBestLocalServer() }
            connectivity = await ConnectivityDiagnostics.shared.run()
            let chosenTransport: TransportKind
            if preferredTransport == .automatic { chosenTransport = connectivity.recommendedTransport; resolvedTransport = chosenTransport } else { chosenTransport = preferredTransport; resolvedTransport = chosenTransport }
            if usesAutomaticServer { selectBestServer(for: chosenTransport) }
            if chosenTransport == .vkTurn && !hasValidVKLink { connectionError = "Добавьте ссылку VK-звонка для режима VK обход"; state = .disconnected; return }
            if chosenTransport == .amneziaWG {
                let ready = await ensureAmneziaProfile()
                if !ready {
                    connectionError = usesAutomaticServer ? "Нет доступного сервера с конфигурацией AmneziaWG" : "Для этого сервера нет конфигурации AmneziaWG"
                    state = .disconnected
                    return
                }
            }
            saveVKLink()
            guard let profile = remoteServers[selectedServer.id]?.tunnelProfile ?? ActivationStore.shared.serverProfile else { connectionError = "Сохранённая конфигурация сервера повреждена"; state = .disconnected; return }
            UserDefaults.standard.set(speedMode.rawValue, forKey: "vkTurnConnections")
            do {
                try await VPNController.shared.connect(transport: chosenTransport, vkCallLink: normalizedVKLink, profile: profile)
                guard state == .connecting else { return }
                withAnimation(.snappy(duration: 0.35)) { state = .connected }
                await measureTunnelLatency(updateLiveActivity: true)
                startLatencyMonitor()
                if liveActivitiesEnabled { syncLiveActivity() }
                Task { connectivity = await ConnectivityDiagnostics.shared.run(); await refreshServers() }
            } catch { connectionError = "Не удалось подключиться: \(error.localizedDescription)"; state = .disconnected; stopLatencyMonitor(); LiveActivityController.shared.end(); AppLog.shared.error("VPN", error.localizedDescription) }
        }
    }

    func disconnect() {
        stopLatencyMonitor()
        VPNController.shared.disconnect()
        withAnimation(.snappy(duration: 0.3)) { state = .disconnected }
        LiveActivityController.shared.end()
    }

    func syncLiveActivity() {
        guard liveActivitiesEnabled, state == .connected else { return }
        LiveActivityController.shared.start(
            server: selectedServer.city.isEmpty ? selectedServer.name : selectedServer.city,
            latency: effectiveSelectedLatency,
            transport: activeTransport.rawValue
        )
    }

    func repairLiveActivity() {
        if state == .connected && liveActivitiesEnabled {
            LiveActivityController.shared.end()
            LiveActivityController.shared.start(
                server: selectedServer.city.isEmpty ? selectedServer.name : selectedServer.city,
                latency: effectiveSelectedLatency,
                transport: activeTransport.rawValue
            )
        } else {
            LiveActivityController.shared.end()
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            wasConnectedBeforeSleep = state == .connected
            if disconnectOnSleep && wasConnectedBeforeSleep { disconnect() }
        case .active:
            if wasConnectedBeforeSleep && reconnectAfterWake && state == .disconnected { wasConnectedBeforeSleep = false; connect() }
            if state == .connected { startLatencyMonitor(); syncLiveActivity() }
        default: break
        }
    }

    func restoreSystemState() async {
        let restored = await VPNController.shared.restoreState()
        switch restored.status {
        case .connected, .reasserting, .connecting:
            if let transport = restored.transport { resolvedTransport = transport }
            state = restored.status == .connected ? .connected : .connecting
            await refreshServers()
            if state == .connected {
                await measureTunnelLatency(updateLiveActivity: true)
                startLatencyMonitor()
                syncLiveActivity()
            }
        default:
            LiveActivityController.shared.end()
        }
    }

    func handleDeepLink(_ url: URL) { guard url.scheme?.lowercased() == "darktunnel", url.host?.lowercased() == "disconnect" else { return }; disconnect() }
    func selectAutomaticServer() { usesAutomaticServer = true; selectBestLocalServer(); reconnectIfNeeded() }
    func select(_ server: VPNServer) { usesAutomaticServer = false; selectedServer = server; reconnectIfNeeded() }

    private func ensureAmneziaProfile() async -> Bool {
        let candidates: [VPNServer] = usesAutomaticServer ? servers.sorted(by: latencyOrder) : [selectedServer]
        for candidate in candidates {
            guard let remote = remoteServers[candidate.id] else { continue }
            if remote.amneziaConfig?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                selectedServer = candidate
                return true
            }
            guard let secure = try? await ServerDirectoryClient.shared.fetchActivatedServer(remote.id) else { continue }
            let merged = ServerDirectoryCache.mergeSecure(secure, into: Array(remoteServers.values))
            ServerDirectoryCache.save(merged)
            remoteServers = Dictionary(uniqueKeysWithValues: merged.map { ($0.displayModel.id, $0) })
            selectedServer = secure.displayModel
            if secure.amneziaConfig?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return true }
        }
        return false
    }

    private func startLatencyMonitor() {
        stopLatencyMonitor()
        guard state == .connected else { return }
        latencyMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(7))
                guard !Task.isCancelled else { return }
                guard let self, self.state == .connected else { return }
                await self.measureTunnelLatency(updateLiveActivity: true)
            }
        }
    }

    private func stopLatencyMonitor() {
        latencyMonitorTask?.cancel()
        latencyMonitorTask = nil
    }

    private func measureTunnelLatency(updateLiveActivity: Bool = false) async {
        guard state == .connected, let url = URL(string: "https://api.31-77-148-80.sslip.io/health") else { return }
        isMeasuringLatency = true
        defer { isMeasuringLatency = false }
        var samples: [Int] = []
        for _ in 0..<3 {
            var request = URLRequest(url: url); request.timeoutInterval = 5; request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let started = ContinuousClock.now
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) else { continue }
                let elapsed = started.duration(to: .now)
                let milliseconds = Int(Double(elapsed.components.attoseconds) / 1_000_000_000_000_000 + Double(elapsed.components.seconds) * 1000)
                samples.append(max(1, milliseconds))
            } catch { }
        }
        guard !samples.isEmpty else { return }
        samples.sort(); updateSelectedLatency(samples[samples.count / 2])
        if updateLiveActivity { syncLiveActivity() }
    }

    private func updateSelectedLatency(_ latency: Int) {
        selectedServer = VPNServer(id: selectedServer.id, name: selectedServer.name, country: selectedServer.country, city: selectedServer.city, flag: selectedServer.flag, latitude: selectedServer.latitude, longitude: selectedServer.longitude, latencyMilliseconds: latency)
        if let index = servers.firstIndex(where: { $0.id == selectedServer.id }) { servers[index] = selectedServer }
        AppLog.shared.info("Latency", "Пинг туннеля: \(latency) мс")
    }

    private func restoreLocalServers() { let merged = ServerDirectoryCache.merge(ServerDirectoryCache.load(), provisioned: ActivationStore.shared.serverProfile); if !merged.isEmpty { ServerDirectoryCache.save(merged) }; apply(merged, preserveSelection: false) }

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

    private func selectBestLocalServer() { guard !servers.isEmpty else { return }; selectedServer = servers.min { latencyOrder($0, $1) } ?? servers[0] }
    private func selectBestServer(for transport: TransportKind) {
        guard !servers.isEmpty else { return }
        if transport == .amneziaWG {
            let candidates = servers.filter { server in
                guard let remote = remoteServers[server.id] else { return false }
                return remote.online && !(remote.amneziaConfig?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }
            if let best = candidates.min(by: latencyOrder) { selectedServer = best; return }
        }
        if let best = servers.min(by: latencyOrder) { selectedServer = best }
    }
    private func latencyOrder(_ lhs: VPNServer, _ rhs: VPNServer) -> Bool { (lhs.latencyMilliseconds > 0 ? lhs.latencyMilliseconds : Int.max) < (rhs.latencyMilliseconds > 0 ? rhs.latencyMilliseconds : Int.max) }
    private func reconnectIfNeeded() { guard state == .connected else { return }; state = .reconnecting; stopLatencyMonitor(); VPNController.shared.disconnect(); Task { try? await Task.sleep(for: .milliseconds(450)); connect() } }
}
