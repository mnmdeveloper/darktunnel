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
        logger.notice("Starting VK bypass SRTP-WRAP-A bootstrap")

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
            let settings = self.makeFullTunnelSettings(address: address, dns: dns, mtu: mtu, remoteAddress: turnIP.isEmpty ? "31.77.148.80" : turnIP)

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
                    self.logger.notice("VK bypass tunnel is fully connected")
                    completionHandler(nil)
                }
            }
        }
    }

    private func startAmnezia(configuration: [String: Any], completionHandler: @escaping (Error?) -> Void) {
        guard let wgQuick = configuration["awg_config"] as? String, !wgQuick.isEmpty else {
            completionHandler(TunnelError.missingAmneziaConfiguration)
            return
        }

        do {
            let parsed = try AmneziaQuickConfig.parse(wgQuick)
            let settings = makeFullTunnelSettings(address: parsed.address, dns: parsed.dns, mtu: parsed.mtu, remoteAddress: parsed.remoteHost)
            setTunnelNetworkSettings(settings) { [weak self] error in
                guard let self else { return }
                if let error {
                    completionHandler(error)
                    return
                }
                guard let descriptor = self.findTunFileDescriptor() else {
                    completionHandler(TunnelError.noTunDevice)
                    return
                }
                let handle = parsed.uapi.withCString { awgTurnOn($0, descriptor) }
                guard handle > 0 else {
                    completionHandler(TunnelError.amneziaBackendFailed(handle))
                    return
                }
                self.amneziaHandle = handle
                self.logger.notice("AmneziaWG tunnel is fully connected")
                completionHandler(nil)
            }
        } catch {
            completionHandler(error)
        }
    }

    private func readTURNServerIP(handle: Int32) -> String {
        guard let pointer = wgGetTURNServerIP(handle) else { return "" }
        let value = String(cString: pointer)
        free(UnsafeMutableRawPointer(mutating: pointer))
        return value
    }

    private func makeFullTunnelSettings(address: String, dns: String, mtu: Int, remoteAddress: String) -> NEPacketTunnelNetworkSettings {
        let addressParts = address.split(separator: "/", maxSplits: 1).map(String.init)
        let ip = addressParts[0]
        let prefix = addressParts.count > 1 ? Int(addressParts[1]) ?? 24 : 24
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
        var ctlInfo = ctl_info()
        withUnsafeMutablePointer(to: &ctlInfo.ctl_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0.pointee)) { pointer in
                _ = strcpy(pointer, "com.apple.net.utun_control")
            }
        }
        for fd: Int32 in 0...1024 {
            var addr = sockaddr_ctl()
            var result: Int32 = -1
            var length = socklen_t(MemoryLayout.size(ofValue: addr))
            withUnsafeMutablePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    result = getpeername(fd, sockaddrPointer, &length)
                }
            }
            if result != 0 || addr.sc_family != AF_SYSTEM { continue }
            if ctlInfo.ctl_id == 0 {
                result = ioctl(fd, CTLIOCGINFO, &ctlInfo)
                if result != 0 { continue }
            }
            if addr.sc_id == ctlInfo.ctl_id { return fd }
        }
        return nil
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        if tunnelHandle > 0 { wgTurnOff(tunnelHandle); tunnelHandle = -1 }
        if amneziaHandle > 0 { awgTurnOff(amneziaHandle); amneziaHandle = -1 }
        logger.notice("Packet Tunnel stopped with reason \(reason.rawValue)")
        completionHandler()
    }

    override func sleep(completionHandler: @escaping () -> Void) { completionHandler() }

    override func wake() {
        if tunnelHandle > 0 { wgWakeHealthCheck(tunnelHandle) }
        if amneziaHandle > 0 { awgBumpSockets(amneziaHandle) }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let message = String(data: messageData, encoding: .utf8) else { completionHandler?(nil); return }
        if message == "get_stats", tunnelHandle > 0, let pointer = wgGetStats(tunnelHandle) {
            let json = String(cString: pointer)
            free(UnsafeMutableRawPointer(mutating: pointer))
            completionHandler?(Data(json.utf8))
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
    let remoteHost: String
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
            if line.lowercased() == "[interface]" { finishPeer(); currentPeer = nil; section = "interface"; continue }
            if line.lowercased() == "[peer]" { finishPeer(); currentPeer = Peer(); section = "peer"; continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if section == "interface" {
                interface[key] = value
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
        guard !peers.isEmpty else { throw TunnelError.invalidAmneziaConfiguration("В конфиге AmneziaWG нет Peer") }
        guard let endpoint = peers.first?.endpoint, !endpoint.isEmpty else { throw TunnelError.invalidAmneziaConfiguration("В конфиге AmneziaWG нет Endpoint") }
        guard let privateKey = interface["privatekey"], !privateKey.isEmpty else { throw TunnelError.invalidAmneziaConfiguration("В конфиге AmneziaWG нет PrivateKey") }

        var lines = ["private_key=\(try hexKey(privateKey))", "listen_port=\(interface["listenport"] ?? "0")", "fwmark=0", "replace_peers=true"]
        for peer in peers {
            lines.append("public_key=\(try hexKey(peer.publicKey))")
            if let presharedKey = peer.presharedKey, !presharedKey.isEmpty { lines.append("preshared_key=\(try hexKey(presharedKey))") }
            lines.append("replace_allowed_ips=true")
            lines.append(contentsOf: peer.allowedIPs.map { "allowed_ip=\($0)" })
            lines.append("endpoint=\(peer.endpoint)")
            lines.append("persistent_keepalive_interval=\(peer.keepalive)")
        }

        let awgKeys = ["jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5", "itvl", "ph1", "ph2", "ph3", "ph4", "s5", "i6"]
        for key in awgKeys where interface[key] != nil { lines.append("\(key)=\(interface[key]!)") }

        return AmneziaQuickConfig(address: address, dns: interface["dns"] ?? "1.1.1.1", mtu: Int(interface["mtu"] ?? "1280") ?? 1280, remoteHost: endpointHost(endpoint), uapi: lines.joined(separator: "\n") + "\n")
    }

    private static func hexKey(_ value: String) throws -> String {
        if value.count == 64, value.allSatisfy({ $0.isHexDigit }) { return value.lowercased() }
        guard let data = Data(base64Encoded: value), data.count == 32 else { throw TunnelError.invalidAmneziaConfiguration("Некорректный ключ AmneziaWG") }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func endpointHost(_ endpoint: String) -> String {
        if endpoint.hasPrefix("[") { return endpoint.split(separator: "]", maxSplits: 1).first.map { String($0.dropFirst()) } ?? endpoint }
        return endpoint.split(separator: ":", maxSplits: 1).first.map(String.init) ?? endpoint
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
        case .amneziaBackendFailed(let code): return "Ошибка движка AmneziaWG: \(code)"
        case .invalidAmneziaConfiguration(let message): return message
        }
    }
}
