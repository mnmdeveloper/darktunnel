import Foundation
import NetworkExtension

@MainActor
final class VPNController: ObservableObject {
    static let shared = VPNController()

    @Published private(set) var status: NEVPNStatus = .invalid
    private var manager: NETunnelProviderManager?

    private init() {
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.status = self?.manager?.connection.status ?? .invalid
            }
        }
    }

    func prepare(transport: TransportKind, vkCallLink: String) async throws {
        guard transport != .amneziaWG else {
            throw VPNControllerError.amneziaNotReady
        }

        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = managers.first ?? NETunnelProviderManager()

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "app.lavender3512.currant6944.PacketTunnel"
        proto.serverAddress = VKTurnRuntimeConfig.host

        var providerConfiguration: [String: Any] = [
            "mode": modeIdentifier(for: transport),
            "mtu": 1280
        ]

        if transport == .vkTurn {
            let password = UserDefaults.standard.string(forKey: "vkTurnServerPassword") ?? ""
            let connections = UserDefaults.standard.integer(forKey: "vkTurnConnections")
            let runtime = VKTurnRuntimeConfig(
                callLink: vkCallLink,
                serverPassword: password,
                deviceID: VKTurnRuntimeConfig.persistentDeviceID(),
                connections: connections > 0 ? connections : 10
            )

            guard let proxyConfig = runtime.proxyConfigJSON, !proxyConfig.isEmpty else {
                throw VPNControllerError.invalidVKConfiguration
            }

            providerConfiguration["use_wrap_a"] = true
            providerConfiguration["wg_config"] = "wrap-a-provisioned"
            providerConfiguration["tunnel_address"] = "0.0.0.0/0"
            providerConfiguration["dns_servers"] = "1.1.1.1"
            providerConfiguration["vkCallLink"] = vkCallLink
            providerConfiguration["vkTurnHost"] = VKTurnRuntimeConfig.host
            providerConfiguration["vkTurnPort"] = VKTurnRuntimeConfig.port
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
    }

    func connect(transport: TransportKind, vkCallLink: String) async throws {
        try await prepare(transport: transport, vkCallLink: vkCallLink)
        guard let manager else { throw VPNControllerError.managerUnavailable }

        try manager.connection.startVPNTunnel()
        try await waitUntilConnected(manager: manager, timeout: 155)
    }

    func disconnect() {
        manager?.connection.stopVPNTunnel()
    }

    private func waitUntilConnected(
        manager: NETunnelProviderManager,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var observedStart = false

        while Date() < deadline {
            let current = manager.connection.status
            status = current

            switch current {
            case .connected:
                return
            case .connecting, .reasserting, .disconnecting:
                observedStart = true
            case .disconnected, .invalid:
                if observedStart {
                    throw VPNControllerError.tunnelStoppedBeforeReady
                }
            @unknown default:
                break
            }

            try await Task.sleep(for: .milliseconds(400))
        }

        manager.connection.stopVPNTunnel()
        throw VPNControllerError.connectionTimeout
    }

    private func modeIdentifier(for transport: TransportKind) -> String {
        switch transport {
        case .automatic:
            return "automatic"
        case .amneziaWG:
            return "amnezia"
        case .vkTurn:
            return "vk-turn-wrap-a"
        }
    }
}

private enum VPNControllerError: LocalizedError {
    case managerUnavailable
    case invalidVKConfiguration
    case tunnelStoppedBeforeReady
    case connectionTimeout
    case amneziaNotReady

    var errorDescription: String? {
        switch self {
        case .managerUnavailable:
            return "Системный VPN-профиль недоступен"
        case .invalidVKConfiguration:
            return "Не удалось сформировать настройки VK TURN"
        case .tunnelStoppedBeforeReady:
            return "VPN-движок остановился до готовности туннеля"
        case .connectionTimeout:
            return "Туннель не подключился за отведённое время"
        case .amneziaNotReady:
            return "AmneziaWG ещё не подключён к реальному движку. Для проверки выберите VK TURN"
        }
    }
}
