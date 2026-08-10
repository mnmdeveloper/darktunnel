import Darwin
import Network
import NetworkExtension
import os

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "app.lavender3512.currant6944", category: "PacketTunnel")
    private var activeMode = "unknown"
    private var tunnelHandle: Int32 = -1

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration else {
            completionHandler(TunnelError.missingConfiguration)
            return
        }

        activeMode = configuration["mode"] as? String ?? "automatic"
        wgSetTimezoneOffset(Int32(TimeZone.current.secondsFromGMT()))

        switch activeMode {
        case "vk-turn-wrap-a":
            startVKTurnWrapA(configuration: configuration, completionHandler: completionHandler)
        case "amnezia":
            startAmneziaScaffold(configuration: configuration, completionHandler: completionHandler)
        default:
            completionHandler(TunnelError.unsupportedMode(activeMode))
        }
    }

    private func startVKTurnWrapA(
        configuration: [String: Any],
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let proxyConfig = configuration["proxy_config"] as? String, !proxyConfig.isEmpty else {
            completionHandler(TunnelError.missingProxyConfiguration)
            return
        }

        logger.notice("Starting VK TURN SRTP-WRAP-A bootstrap")

        let handle = proxyConfig.withCString { pointer in
            wgStartVKBootstrap(pointer)
        }
        guard handle > 0 else {
            completionHandler(TunnelError.backendFailed(handle))
            return
        }

        tunnelHandle = handle

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let ready = wgWaitBootstrapReady(handle, 120_000)
            guard ready == 1 else {
                wgTurnOff(handle)
                self.tunnelHandle = -1
                completionHandler(ready == 0 ? TunnelError.bootstrapTimeout : TunnelError.backendFailed(ready))
                return
            }

            guard let provisionPointer = wgWaitWrapAProvision(handle, 30_000) else {
                wgTurnOff(handle)
                self.tunnelHandle = -1
                completionHandler(TunnelError.provisionFailed)
                return
            }

            let provisionJSON = String(cString: provisionPointer)
            free(UnsafeMutableRawPointer(mutating: provisionPointer))

            guard
                let data = provisionJSON.data(using: .utf8),
                let provision = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let uapi = provision["uapi"] as? String,
                !uapi.isEmpty,
                let address = provision["address"] as? String,
                self.isValidTunnelAddress(address)
            else {
                wgTurnOff(handle)
                self.tunnelHandle = -1
                completionHandler(TunnelError.invalidProvision)
                return
            }

            let dns = (provision["dns"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "1.1.1.1"
            let mtu = provision["mtu"] as? Int ?? 1280
            let turnIP = self.readTURNServerIP(handle: handle)
            let settings = self.makeFullTunnelSettings(
                address: address,
                dns: dns,
                mtu: mtu,
                remoteAddress: turnIP.isEmpty ? "31.77.148.80" : turnIP
            )

            DispatchQueue.main.async {
                self.setTunnelNetworkSettings(settings) { error in
                    if let error {
                        wgTurnOff(handle)
                        self.tunnelHandle = -1
                        completionHandler(error)
                        return
                    }

                    guard let descriptor = self.findTunFileDescriptor() else {
                        wgTurnOff(handle)
                        self.tunnelHandle = -1
                        completionHandler(TunnelError.noTunDevice)
                        return
                    }

                    let result = uapi.withCString { pointer in
                        wgAttachWireGuard(handle, pointer, descriptor)
                    }
                    guard result > 0 else {
                        wgTurnOff(handle)
                        self.tunnelHandle = -1
                        completionHandler(TunnelError.backendFailed(result))
                        return
                    }

                    self.logger.notice("VK TURN SRTP-WRAP-A tunnel is fully connected")
                    completionHandler(nil)
                }
            }
        }
    }

    private func startAmneziaScaffold(
        configuration: [String: Any],
        completionHandler: @escaping (Error?) -> Void
    ) {
        let remoteAddress = configuration["amneziaHost"] as? String ?? "31.77.148.80"
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)
        let ipv4 = NEIPv4Settings(addresses: ["10.8.1.3"], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = []
        settings.ipv4Settings = ipv4
        settings.mtu = 1280

        setTunnelNetworkSettings(settings) { [weak self] error in
            if error == nil {
                self?.logger.notice("Amnezia scaffold started; AmneziaWG engine is not integrated yet")
            }
            completionHandler(error)
        }
    }

    private func readTURNServerIP(handle: Int32) -> String {
        guard let pointer = wgGetTURNServerIP(handle) else { return "" }
        let value = String(cString: pointer)
        free(UnsafeMutableRawPointer(mutating: pointer))
        return value
    }

    private func makeFullTunnelSettings(
        address: String,
        dns: String,
        mtu: Int,
        remoteAddress: String
    ) -> NEPacketTunnelNetworkSettings {
        let parts = address.split(separator: "/", maxSplits: 1).map(String.init)
        let ip = parts[0]
        let prefix = parts.count > 1 ? Int(parts[1]) ?? 24 : 24

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)
        let ipv4 = NEIPv4Settings(addresses: [ip], subnetMasks: [subnetMask(prefix: prefix)])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = []
        settings.ipv4Settings = ipv4

        let dnsServers = dns
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        settings.dnsSettings = NEDNSSettings(servers: dnsServers.isEmpty ? ["1.1.1.1"] : dnsServers)
        settings.mtu = NSNumber(value: min(max(mtu, 576), 1500))
        return settings
    }

    private func isValidTunnelAddress(_ address: String) -> Bool {
        let parts = address.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let host = parts.first, !host.isEmpty else { return false }
        return IPv4Address(String(host)) != nil
    }

    private func subnetMask(prefix: Int) -> String {
        let safePrefix = min(max(prefix, 0), 32)
        let mask: UInt32 = safePrefix == 0 ? 0 : UInt32.max << (32 - safePrefix)
        return "\((mask >> 24) & 255).\((mask >> 16) & 255).\((mask >> 8) & 255).\(mask & 255)"
    }

    private func findTunFileDescriptor() -> Int32? {
        var buffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        for descriptor: Int32 in 0...1024 {
            var length = socklen_t(buffer.count)
            let result = getsockopt(
                descriptor,
                2,
                2,
                &buffer,
                &length
            )
            if result == 0, String(cString: buffer).hasPrefix("utun") {
                return descriptor
            }
        }
        return nil
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        if tunnelHandle > 0 {
            wgTurnOff(tunnelHandle)
            tunnelHandle = -1
        }
        logger.notice("Packet Tunnel stopped with reason \(reason.rawValue)")
        completionHandler()
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func wake() {
        if tunnelHandle > 0 {
            wgWakeHealthCheck(tunnelHandle)
        }
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        guard let message = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }

        if message == "get_stats", tunnelHandle > 0, let pointer = wgGetStats(tunnelHandle) {
            let json = String(cString: pointer)
            free(UnsafeMutableRawPointer(mutating: pointer))
            completionHandler?(Data(json.utf8))
            return
        }

        completionHandler?(Data("DarkTunnel mode: \(activeMode)".utf8))
    }
}

private enum TunnelError: LocalizedError {
    case missingConfiguration
    case missingProxyConfiguration
    case unsupportedMode(String)
    case backendFailed(Int32)
    case bootstrapTimeout
    case provisionFailed
    case invalidProvision
    case noTunDevice

    var errorDescription: String? {
        switch self {
        case .missingConfiguration: return "Отсутствует конфигурация VPN"
        case .missingProxyConfiguration: return "Отсутствуют настройки VK TURN"
        case .unsupportedMode(let mode): return "Неизвестный режим VPN: \(mode)"
        case .backendFailed(let code): return "Ошибка VPN-движка: \(code)"
        case .bootstrapTimeout: return "VK TURN не подключился за 120 секунд"
        case .provisionFailed: return "Сервер не передал настройки туннеля"
        case .invalidProvision: return "Сервер передал некорректные настройки WireGuard"
        case .noTunDevice: return "Не удалось получить системный TUN-интерфейс"
        }
    }
}
