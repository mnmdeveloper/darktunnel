import Foundation
import NetworkExtension

@MainActor
final class VPNController: ObservableObject {
    static let shared = VPNController()

    @Published private(set) var status: NEVPNStatus = .invalid
    private var manager: NETunnelProviderManager?

    private init() {
        NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                if let session = notification.object as? NETunnelProviderSession, let changedManager = session.manager as? NETunnelProviderManager, changedManager.localizedDescription == "DarkTunnel" {
                    self.manager = changedManager
                    self.status = session.status
                } else {
                    self.status = self.manager?.connection.status ?? .invalid
                }
                AppLog.shared.info("VPN", "Системный статус: \(self.status.rawValue)")
            }
        }
        Task { await loadExistingManager() }
    }

    func restoreState() async -> (status: NEVPNStatus, transport: TransportKind?) {
        await loadExistingManager()
        return (status, currentTransport())
    }

    func prepare(transport: TransportKind, vkCallLink: String, profile: DarkTunnelServerProfile) async throws {
        let manager = try await loadOrCreateManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "app.lavender3512.currant6944.PacketTunnel"
        proto.serverAddress = profile.host
        var providerConfiguration: [String: Any] = ["mode": modeIdentifier(for: transport), "mtu": profile.mtu, "dns_servers": profile.dns]

        switch transport {
        case .automatic:
            throw VPNControllerError.invalidTransport
        case .amneziaWG:
            guard let config = profile.amneziaConfig?.trimmingCharacters(in: .whitespacesAndNewlines), !config.isEmpty else { throw VPNControllerError.amneziaConfigUnavailable }
            providerConfiguration["awg_config"] = config
        case .vkTurn:
            let connections = UserDefaults.standard.integer(forKey: "vkTurnConnections")
            let runtime = VKTurnRuntimeConfig(host: profile.host, port: profile.port, callLink: vkCallLink, serverPassword: profile.wrapAPassword, deviceID: VKTurnRuntimeConfig.persistentDeviceID(), connections: connections > 0 ? connections : 5)
            guard let proxyConfig = runtime.proxyConfigJSON, !proxyConfig.isEmpty else { throw VPNControllerError.invalidVKConfiguration }
            providerConfiguration["use_wrap_a"] = true
            providerConfiguration["wg_config"] = "wrap-a-provisioned"
            providerConfiguration["tunnel_address"] = "0.0.0.0/0"
            providerConfiguration["vkCallLink"] = vkCallLink
            providerConfiguration["vkTurnHost"] = profile.host
            providerConfiguration["vkTurnPort"] = profile.port
            providerConfiguration["device_id"] = runtime.deviceID
            providerConfiguration["proxy_config"] = proxyConfig
        }

        proto.providerConfiguration = providerConfiguration
        manager.protocolConfiguration = proto
        manager.localizedDescription = "DarkTunnel"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        self.manager = manager
        self.status = manager.connection.status
        AppLog.shared.info("VPN", "Профиль подготовлен для \(profile.host):\(profile.port) через \(transport.rawValue)")
    }

    func connect(transport: TransportKind, vkCallLink: String, profile: DarkTunnelServerProfile) async throws {
        AppLog.shared.info("VPN", "Запуск подключения через \(transport.rawValue)")
        try await prepare(transport: transport, vkCallLink: vkCallLink, profile: profile)
        guard let manager else { throw VPNControllerError.managerUnavailable }
        try manager.connection.startVPNTunnel()
        try await waitUntilConnected(manager: manager, timeout: 155)
        AppLog.shared.info("VPN", "Туннель подключён")
    }

    func disconnect() {
        if let manager {
            manager.connection.stopVPNTunnel()
            AppLog.shared.info("VPN", "Запрошено отключение")
        } else {
            Task { await loadExistingManager(); self.manager?.connection.stopVPNTunnel() }
        }
    }

    func currentTransport() -> TransportKind? {
        guard let proto = manager?.protocolConfiguration as? NETunnelProviderProtocol, let mode = proto.providerConfiguration?["mode"] as? String else { return nil }
        switch mode {
        case "amnezia": return .amneziaWG
        case "vk-turn-wrap-a": return .vkTurn
        default: return .automatic
        }
    }

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = managers.first(where: { $0.localizedDescription == "DarkTunnel" }) ?? managers.first ?? NETunnelProviderManager()
        self.manager = manager
        self.status = manager.connection.status
        return manager
    }

    private func loadExistingManager() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            if let existing = managers.first(where: { $0.localizedDescription == "DarkTunnel" }) ?? managers.first {
                manager = existing
                status = existing.connection.status
            } else { status = .invalid }
        } catch {
            status = .invalid
            AppLog.shared.warning("VPN", "Не удалось восстановить системный VPN-профиль: \(error.localizedDescription)")
        }
    }

    private func waitUntilConnected(manager: NETunnelProviderManager, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var observedStart = false
        while Date() < deadline {
            let current = manager.connection.status
            status = current
            switch current {
            case .connected: return
            case .connecting, .reasserting, .disconnecting: observedStart = true
            case .disconnected, .invalid: if observedStart { throw VPNControllerError.tunnelStoppedBeforeReady }
            @unknown default: break
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        manager.connection.stopVPNTunnel()
        throw VPNControllerError.connectionTimeout
    }

    private func modeIdentifier(for transport: TransportKind) -> String {
        switch transport {
        case .automatic: return "automatic"
        case .amneziaWG: return "amnezia"
        case .vkTurn: return "vk-turn-wrap-a"
        }
    }
}

private enum VPNControllerError: LocalizedError {
    case managerUnavailable, invalidTransport, invalidVKConfiguration, amneziaConfigUnavailable, tunnelStoppedBeforeReady, connectionTimeout
    var errorDescription: String? {
        switch self {
        case .managerUnavailable: return "Системный VPN-профиль недоступен"
        case .invalidTransport: return "Не выбран транспорт VPN"
        case .invalidVKConfiguration: return "Не удалось сформировать настройки VK обхода"
        case .amneziaConfigUnavailable: return "Для этого сервера нет конфигурации AmneziaWG"
        case .tunnelStoppedBeforeReady: return "VPN остановился до завершения подключения"
        case .connectionTimeout: return "Туннель не подключился за отведённое время"
        }
    }
}
