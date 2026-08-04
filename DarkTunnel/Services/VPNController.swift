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
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = managers.first ?? NETunnelProviderManager()

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "app.lavender3512.currant6944.PacketTunnel"
        proto.serverAddress = transport == .vkTurn ? VKTurnRuntimeConfig.host : "31.77.148.80"

        var providerConfiguration: [String: Any] = [
            "mode": modeIdentifier(for: transport),
            "amneziaHost": "31.77.148.80",
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

            providerConfiguration["use_wrap_a"] = true
            providerConfiguration["wg_config"] = "wrap-a-provisioned"
            providerConfiguration["tunnel_address"] = "0.0.0.0/0"
            providerConfiguration["dns_servers"] = "1.1.1.1"
            providerConfiguration["vkCallLink"] = vkCallLink
            providerConfiguration["vkTurnHost"] = VKTurnRuntimeConfig.host
            providerConfiguration["vkTurnPort"] = VKTurnRuntimeConfig.port
            providerConfiguration["device_id"] = runtime.deviceID
            providerConfiguration["proxy_config"] = runtime.proxyConfigJSON ?? ""
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
        try manager?.connection.startVPNTunnel()
    }

    func disconnect() {
        manager?.connection.stopVPNTunnel()
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
