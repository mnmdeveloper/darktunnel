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
        proto.serverAddress = "31.77.148.80"
        proto.providerConfiguration = [
            "mode": modeIdentifier(for: transport),
            "amneziaHost": "31.77.148.80",
            "wdttHost": "31.77.148.80",
            "wdttPort": 56000,
            "vkCallLink": vkCallLink,
            "mtu": 1280
        ]

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
            return "vk-turn-wireguard"
        case .wdtt:
            return "wdtt-wireguard"
        }
    }
}
