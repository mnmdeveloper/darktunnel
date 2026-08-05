import Foundation

struct RemoteVPNServer: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let countryCode: String
    let countryName: String
    let city: String
    let latitude: Double?
    let longitude: Double?
    let host: String
    let port: Int
    let mode: String
    let wrapAPassword: String
    let connectionsBalanced: Int
    let connectionsMaximum: Int
    let mtu: Int
    let dns: String
    let latencyMS: Int?
    let online: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, city, latitude, longitude, host, port, mode, mtu, dns, online
        case countryCode = "country_code"
        case countryName = "country_name"
        case wrapAPassword = "wrap_a_password"
        case connectionsBalanced = "connections_balanced"
        case connectionsMaximum = "connections_maximum"
        case latencyMS = "latency_ms"
    }

    var displayModel: VPNServer {
        VPNServer(
            id: UUID(uuidString: id) ?? Self.stableUUID(for: host, port: port),
            name: name,
            country: countryName.isEmpty ? name : countryName,
            city: city.isEmpty ? name : city,
            flag: Self.flag(for: countryCode),
            latitude: latitude ?? 55.7558,
            longitude: longitude ?? 37.6173,
            latencyMilliseconds: latencyMS ?? 0
        )
    }

    var tunnelProfile: DarkTunnelServerProfile {
        DarkTunnelServerProfile(
            host: host,
            port: port,
            mode: mode,
            wrapAPassword: wrapAPassword,
            connectionsBalanced: connectionsBalanced,
            connectionsMaximum: connectionsMaximum,
            mtu: mtu,
            dns: dns
        )
    }

    static func provisioned(_ profile: DarkTunnelServerProfile) -> RemoteVPNServer {
        RemoteVPNServer(
            id: stableUUID(for: profile.host, port: profile.port).uuidString,
            name: "Основной сервер",
            countryCode: "",
            countryName: "",
            city: "Основной сервер",
            latitude: nil,
            longitude: nil,
            host: profile.host,
            port: profile.port,
            mode: profile.mode,
            wrapAPassword: profile.wrapAPassword,
            connectionsBalanced: profile.connectionsBalanced,
            connectionsMaximum: profile.connectionsMaximum,
            mtu: profile.mtu,
            dns: profile.dns,
            latencyMS: nil,
            online: true
        )
    }

    private static func stableUUID(for host: String, port: Int) -> UUID {
        let source = Array("\(host):\(port)".utf8)
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, value) in source.enumerated() {
            bytes[index % 16] = bytes[index % 16] &+ value &+ UInt8(truncatingIfNeeded: index)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func flag(for code: String) -> String {
        let upper = code.uppercased()
        guard upper.count == 2 else { return "🌐" }
        let scalars = upper.unicodeScalars.compactMap { UnicodeScalar(127397 + Int($0.value)) }
        return String(String.UnicodeScalarView(scalars))
    }
}

private struct ServerListEnvelope: Codable { let servers: [RemoteVPNServer] }

enum ServerDirectoryError: LocalizedError {
    case invalidResponse
    case noServers

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Backend вернул некорректный список серверов"
        case .noServers: return "Нет доступных серверов"
        }
    }
}

enum ServerDirectoryCache {
    private static let account = "server-directory-v1"

    static func load() -> [RemoteVPNServer] {
        guard let value = KeychainStore.readString(account: account),
              let data = value.data(using: .utf8),
              let servers = try? JSONDecoder().decode([RemoteVPNServer].self, from: data) else {
            return []
        }
        return servers
    }

    static func save(_ servers: [RemoteVPNServer]) {
        guard let data = try? JSONEncoder().encode(servers),
              let value = String(data: data, encoding: .utf8) else { return }
        try? KeychainStore.writeString(value, account: account)
    }

    static func merge(_ servers: [RemoteVPNServer], provisioned profile: DarkTunnelServerProfile?) -> [RemoteVPNServer] {
        var result = servers
        if let profile, !result.contains(where: { $0.host == profile.host && $0.port == profile.port }) {
            result.insert(.provisioned(profile), at: 0)
        }
        var seen = Set<String>()
        return result.filter { seen.insert("\($0.host):\($0.port)").inserted }
    }
}

actor ServerDirectoryClient {
    static let shared = ServerDirectoryClient()
    private let baseURL = URL(string: "https://api.31-77-148-80.sslip.io")!

    func fetchServers() async throws -> [RemoteVPNServer] {
        let url = baseURL.appending(path: "/v1/servers")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServerDirectoryError.invalidResponse
        }
        let result = try JSONDecoder().decode(ServerListEnvelope.self, from: data)
        guard !result.servers.isEmpty else { throw ServerDirectoryError.noServers }
        return result.servers
    }
}
