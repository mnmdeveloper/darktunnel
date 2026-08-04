import NetworkExtension
import os

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "app.lavender3512.currant6944", category: "PacketTunnel")
    private var activeMode = "unknown"

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        activeMode = configuration["mode"] as? String ?? "automatic"

        switch activeMode {
        case "amnezia":
            startAmneziaScaffold(configuration: configuration, completionHandler: completionHandler)
        case "vk-turn-wireguard":
            startVKTurnWireGuardScaffold(configuration: configuration, completionHandler: completionHandler)
        default:
            startAmneziaScaffold(configuration: configuration, completionHandler: completionHandler)
        }
    }

    private func startAmneziaScaffold(
        configuration: [String: Any],
        completionHandler: @escaping (Error?) -> Void
    ) {
        logger.notice("Starting Amnezia mode scaffold")
        applyScaffoldSettings(
            remoteAddress: configuration["amneziaHost"] as? String ?? "31.77.148.80",
            clientAddress: "10.8.1.3",
            completionHandler: completionHandler
        )
    }

    private func startVKTurnWireGuardScaffold(
        configuration: [String: Any],
        completionHandler: @escaping (Error?) -> Void
    ) {
        let host = configuration["wdttHost"] as? String ?? "31.77.148.80"
        let port = configuration["wdttPort"] as? Int ?? 56000
        let hasVKLink = !(configuration["vkCallLink"] as? String ?? "").isEmpty

        logger.notice(
            "Starting VK TURN + WireGuard scaffold at \(host, privacy: .public):\(port, privacy: .public), VK link present: \(hasVKLink, privacy: .public)"
        )

        applyScaffoldSettings(
            remoteAddress: host,
            clientAddress: "10.66.66.2",
            completionHandler: completionHandler
        )
    }

    private func applyScaffoldSettings(
        remoteAddress: String,
        clientAddress: String,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)
        let ipv4 = NEIPv4Settings(
            addresses: [clientAddress],
            subnetMasks: ["255.255.255.255"]
        )

        // Пока движки не подключены, не перехватываем маршруты, чтобы не ломать интернет.
        ipv4.includedRoutes = []
        settings.ipv4Settings = ipv4
        settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "1.0.0.1"])
        settings.mtu = 1280

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                self?.logger.error("Failed to apply tunnel settings: \(error.localizedDescription, privacy: .public)")
                completionHandler(error)
                return
            }

            self?.logger.notice(
                "Packet Tunnel mode \(self?.activeMode ?? "unknown", privacy: .public) started. Engine integration is the next step."
            )
            completionHandler(nil)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        logger.notice("Packet Tunnel stopped with reason \(reason.rawValue), mode \(activeMode, privacy: .public)")
        completionHandler()
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        completionHandler?(Data("DarkTunnel mode: \(activeMode)".utf8))
    }
}
