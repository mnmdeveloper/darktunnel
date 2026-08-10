import Darwin
import Foundation
import Network
import NetworkExtension
import os

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "app.lavender3512.currant6944", category: "PacketTunnel")
    private var activeMode = "unknown"
    private var tunnelHandle: Int32 = -1
    private var amneziaHandle: Int32 = -1

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
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
            startAmnezia(configuration: configuration, completionHandler: completionHandler)
        default:
            completionHandler(TunnelError.unsupportedMode(activeMode))
        }
    }

    private func startVKTurnWrapA(configuration: [String: Any], completionHandler: @escaping (Error?) -> Void) {
        guard let proxyConfig = configuration["proxy_config"] as? String, !proxyConfig.isEmpty else {
            completionHandler(TunnelError.missingProxyConfiguration)
            return
        }

        logger.notice("Starting VK TURN SRTP-WRAP-A bootstrap")
        let handle = proxyConfig.withCString { wgStartVKBootstrap($0) }
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
                self.isValidIPv4TunnelAddress(address)
            else {
                wgTurnOff(handle)
                self.tunnelHandle = -1
                completionHandler(TunnelError.invalidProvision)
                return
            }

            let dns = (provision["dns"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "1.1.1.1"
            let mtu = provision["mtu"] as? Int ?? 1280
            let turnIP = self.readTURNServerIP(handle: handle)
            let settings = self.makeNetworkSettings(address: address, dns: dns, mtu: mtu, remoteAddress: turnIP.isEmpty ? "31.77.148.80" : turnIP)

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
                    let result = uapi.withCString { wgAttachWireGuard(handle, $0, descriptor) }
                    guard result > 0 else {
                        wgTurnOff(handle)
                        self.tunnelHandle = -1
                        completionHandler(TunnelError.backendFailed(result))
                        return
                    }
                    self.logger.notice("VK TURN tunnel is fully connected")
                    completionHandler(nil)
                }
            }
        }
    }

    private func startAmnezia(configuration: [String: Any], completionHandler: @escaping (Error?) -> Void) {
        guard let wgQuick = configuration["awg_config"] as? String, !wgQuick.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completionHandler(TunnelError.missingAmneziaConfiguration)
            return
        }

        do {
            let parsed = try AmneziaQuickConfig.parse(wgQuick)
            guard let resolved = resolveEndpoint(parsed.endpoint) else {
                completionHandler(TunnelError.endpointResolutionFailed(parsed.endpoint))
                return
            }

            let settings = makeNetworkSettings(address: parsed.address, dns: parsed.dns, mtu: parsed.mtu, remoteAddress: resolved.host)
            let resolvedUAPI = parsed.uapi.replacingOccurrences(of: "endpoint=\(parsed.endpoint)", with: "endpoint=\(resolved.endpoint)")

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.setTunnelNetworkSettings(settings) { error in
                    if let error {
                        completionHandler(error)
                        return
                    }
                    guard let descriptor = self.findTunFileDescriptor() else {
                        completionHandler(TunnelError.noTunDevice)
                        return
                    }

                    let handle = resolvedUAPI.withCString { awgTurnOn($0, descriptor) }
                    guard handle >= 0 else {
                        completionHandler(TunnelError.amneziaBackendFailed(handle))
                        return
                    }
                    self.amneziaHandle = handle
                    let versionPointer = awgVersion()
                    let version = versionPointer == nil ? "unknown" : String(cString: versionPointer!)
                    self.logger.notice("AmneziaWG backend started: \(version), endpoint \(resolved.host)")
                    awgDisableSomeRoamingForBrokenMobileSemantics(handle)
                    completionHandler(nil)
                }
            }
        } catch {
            completionHandler(error)
        }
    }

    private func resolveEndpoint(_ endpoint: String) -> (host: String, endpoint: String)? {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        let port: String

        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return nil }
            host = String(value[value.index(after: value.startIndex)..<close])
            let after = value.index(after: close)
            guard after < value.endIndex, value[after] == ":" else { return nil }
            port = String(value[value.index(after: after)...])
        } else {
            guard let colon = value.lastIndex(of: ":") else { return nil }
            host = String(value[..<colon])
            port = String(value[value.index(after: colon)...])
        }

        guard !host.isEmpty, Int(port) != nil else { return nil }

        if IPv4Address(host) != nil { return (host, "\(host):\(port)") }
        if let ipv6 = IPv6Address(host) { return ("\(ipv6)", "[\(ipv6)]:\(port)") }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, port, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }

        var numeric = [CChar](repeating: 0, count: 1025)
        guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &numeric, socklen_t(numeric.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        let resolvedHost = String(cString: numeric)
        if resolvedHost.contains(":") {
            return (resolvedHost, "[\(resolvedHost)]:\(port)")
        }
        return (resolvedHost, "\(resolvedHost):\(port)")
    }

    private func readTURNServerIP(handle: Int32) -> String {
        guard let pointer = wgGetTURNServerIP(handle) else { return "" }
        let value = String(cString: pointer)
        free(UnsafeMutableRawPointer(mutating: pointer))
        return value
    }

    private func makeNetworkSettings(address: String, dns: String, mtu: Int, remoteAddress: String) -> NEPacketTunnelNetworkSettings {
        let parts = address.split(separator: "/", maxSplits: 1).map(String.init)
        let ip = parts.first ?? address
        let prefix = parts.count > 1 ? Int(parts[1]) ?? 24 : 24
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)

        if ip.contains(":") {
            let ipv6 = NEIPv6Settings(addresses: [ip], networkPrefixLengths: [NSNumber(value: min(max(prefix, 0), 128))])
            ipv6.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6
        } else {
            let ipv4 = NEIPv4Settings(addresses: [ip], subnetMasks: [subnetMask(prefix: prefix)])
            ipv4.includedRoutes = [NEIPv4Route.default()]
            ipv4.excludedRoutes = []
            settings.ipv4Settings = ipv4
        }

        let dnsServers = dns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let dnsSettings = NEDNSSettings(servers: dnsServers.isEmpty ? ["1.1.1.1"] : dnsServers)
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings
        settings.mtu = NSNumber(value: min(max(mtu, 576), 1500))
        return settings
    }

    private func isValidIPv4TunnelAddress(_ address: String) -> Bool {
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
            let result = getsockopt(descriptor, 2, 2, &buffer, &length)
            if result == 0, String(cString: buffer).hasPrefix("utun") {
                return descriptor
            }
        }
        return nil
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        if tunnelHandle > 0 { wgTurnOff(tunnelHandle); tunnelHandle = -1 }
        if amneziaHandle >= 0 { awgTurnOff(amneziaHandle); amneziaHandle = -1 }
        logger.notice("Packet Tunnel stopped with reason \(reason.rawValue)")
        completionHandler()
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func wake() {
        if tunnelHandle > 0 { wgWakeHealthCheck(tunnelHandle) }
        if amneziaHandle >= 0 { awgBumpSockets(amneziaHandle) }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let message = String(data: messageData, encoding: .utf8) else { completionHandler?(nil); return }
        if message == "get_stats", tunnelHandle > 0, let pointer = wgGetStats(tunnelHandle) {
            let json = String(cString: pointer)
            free(UnsafeMutableRawPointer(mutating: pointer))
            completionHandler?(Data(json.utf8))
            return
        }
        if message == "amnezia_version", amneziaHandle >= 0 {
            let pointer = awgVersion()
            completionHandler?(Data((pointer == nil ? "unknown" : String(cString: pointer!)).utf8))
            return
        }
        completionHandler?(Data("DarkTunnel mode: \(activeMode)".utf8))
    }
}

private struct AmneziaQuickConfig {
    struct Peer {
        var publicKey = ""
        var presharedKey: String?
        var endpoint = ""
        var keepalive = 0
        var allowedIPs: [String] = []
    }

    let address: String
    let dns: String
    let mtu: Int
    let endpoint: String
    let uapi: String

    static func parse(_ text: String) throws -> AmneziaQuickConfig {
        var section = ""
        var interface: [String: String] = [:]
        var peers: [Peer] = []
        var currentPeer: Peer?

        func finishPeer() {
            if let currentPeer, !currentPeer.publicKey.isEmpty { peers.append(currentPeer) }
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let lineWithoutComment = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let line = lineWithoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let normalized = line.lowercased()
            if normalized == "[interface]" {
                finishPeer(); currentPeer = nil; section = "interface"; continue
            }
            if normalized == "[peer]" {
                finishPeer(); currentPeer = Peer(); section = "peer"; continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)

            if section == "interface" {
                interface[key] = String(value)
            } else if section == "peer", var peer = currentPeer {
                switch key {
                case "publickey": peer.publicKey = String(value)
                case "presharedkey": peer.presharedKey = String(value)
                case "endpoint": peer.endpoint = String(value)
                case "persistentkeepalive": peer.keepalive = Int(value) ?? 0
                case "allowedips": peer.allowedIPs = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                default: break
                }
                currentPeer = peer
            }
        }
        finishPeer()

        guard let address = interface["address"]?.split(separator: ",").first.map(String.init), !address.isEmpty else {
            throw TunnelError.invalidAmneziaConfiguration("В конфиге AmneziaWG нет Address")
        }
        guard let privateKey = interface["privatekey"], !privateKey.isEmpty else {
            throw TunnelError.invalidAmneziaConfiguration("В конфиге AmneziaWG нет PrivateKey")
        }
        guard !peers.isEmpty else {
            throw TunnelError.invalidAmneziaConfiguration("В конфиге AmneziaWG нет Peer")
        }
        guard let endpoint = peers.first?.endpoint, !endpoint.isEmpty else {
            throw TunnelError.invalidAmneziaConfiguration("В конфиге AmneziaWG нет Endpoint")
        }

        var lines: [String] = [
            "private_key=\(try hexKey(privateKey))",
            "listen_port=\(interface["listenport"] ?? "0")",
            "fwmark=0",
            "replace_peers=true"
        ]

        let supportedDeviceKeys = [
            "jc", "jmin", "jmax", "s1", "s2", "s3", "s4",
            "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5",
            "headerprotectionkey", "contentpaddingaddition", "rekeyaftertime",
            "rekeytimeout", "rejectaftertime", "keepalivetimeout", "maxhandshakeattempts"
        ]

        for key in supportedDeviceKeys {
            guard let value = interface[key], !value.isEmpty else { continue }
            switch key {
            case "headerprotectionkey": lines.append("header_protection_key=\(try hexKey(value))")
            case "contentpaddingaddition": lines.append("content_padding_addition=\(value)")
            case "rekeyaftertime": lines.append("rekey_after_time=\(value)")
            case "rekeytimeout": lines.append("rekey_timeout=\(value)")
            case "rejectaftertime": lines.append("reject_after_time=\(value)")
            case "keepalivetimeout": lines.append("keepalive_timeout=\(value)")
            case "maxhandshakeattempts": lines.append("max_handshake_attempts=\(value)")
            default: lines.append("\(key)=\(value)")
            }
        }

        for peer in peers {
            lines.append("public_key=\(try hexKey(peer.publicKey))")
            if let presharedKey = peer.presharedKey, !presharedKey.isEmpty { lines.append("preshared_key=\(try hexKey(presharedKey))") }
            lines.append("replace_allowed_ips=true")
            for allowedIP in peer.allowedIPs where !allowedIP.isEmpty { lines.append("allowed_ip=\(allowedIP)") }
            lines.append("endpoint=\(peer.endpoint)")
            lines.append("persistent_keepalive_interval=\(peer.keepalive)")
        }

        return AmneziaQuickConfig(
            address: address,
            dns: interface["dns"] ?? "1.1.1.1",
            mtu: Int(interface["mtu"] ?? "1280") ?? 1280,
            endpoint: endpoint,
            uapi: lines.joined(separator: "\n") + "\n"
        )
    }

    private static func hexKey(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 64, trimmed.allSatisfy({ $0.isHexDigit }) { return trimmed.lowercased() }
        guard let data = Data(base64Encoded: trimmed), data.count == 32 else {
            throw TunnelError.invalidAmneziaConfiguration("Некорректный ключ AmneziaWG")
        }
        return data.map { String(format: "%02x", $0) }.joined()
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
    case missingAmneziaConfiguration
    case amneziaBackendFailed(Int32)
    case endpointResolutionFailed(String)
    case invalidAmneziaConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration: return "Отсутствует конфигурация VPN"
        case .missingProxyConfiguration: return "Отсутствуют настройки VK обхода"
        case .unsupportedMode(let mode): return "Неизвестный режим VPN: \(mode)"
        case .backendFailed(let code): return "Ошибка VPN-движка: \(code)"
        case .bootstrapTimeout: return "VK обход не подключился за 120 секунд"
        case .provisionFailed: return "Сервер не передал настройки туннеля"
        case .invalidProvision: return "Сервер передал некорректные настройки WireGuard"
        case .noTunDevice: return "Не удалось получить системный TUN-интерфейс"
        case .missingAmneziaConfiguration: return "Отсутствует конфигурация AmneziaWG"
        case .amneziaBackendFailed(let code): return "Ошибка AmneziaWG: \(code)"
        case .endpointResolutionFailed(let endpoint): return "Не удалось определить IP AmneziaWG endpoint: \(endpoint)"
        case .invalidAmneziaConfiguration(let message): return message
        }
    }
}
