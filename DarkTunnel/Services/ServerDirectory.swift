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
    let amneziaConfig: String?

    enum CodingKeys: String, CodingKey {
        case id, name, city, latitude, longitude, host, port, mode, mtu, dns, online
        case countryCode = "country_code"
        case countryName = "country_name"
        case wrapAPassword = "wrap_a_password"
        case connectionsBalanced = "connections_balanced"
        case connectionsMaximum = "connections_maximum"
        case latencyMS = "latency_ms"
        case amneziaConfig = "amnezia_config"
    }

    var displayModel: VPNServer {
        let capital = CapitalCoordinates.forCountry(countryCode)
        return VPNServer(id: UUID(uuidString: id) ?? Self.stableUUID(for: host, port: port), name: name, country: countryName.isEmpty ? name : countryName, city: city.isEmpty ? name : city, flag: Self.flag(for: countryCode), latitude: capital?.latitude ?? latitude ?? 55.7558, longitude: capital?.longitude ?? longitude ?? 37.6173, latencyMilliseconds: latencyMS ?? 0)
    }

    var tunnelProfile: DarkTunnelServerProfile {
        DarkTunnelServerProfile(host: host, port: port, mode: mode, wrapAPassword: wrapAPassword, connectionsBalanced: connectionsBalanced, connectionsMaximum: connectionsMaximum, mtu: mtu, dns: dns, amneziaConfig: amneziaConfig)
    }

    static func provisioned(_ profile: DarkTunnelServerProfile) -> RemoteVPNServer {
        RemoteVPNServer(id: stableUUID(for: profile.host, port: profile.port).uuidString, name: "Основной сервер", countryCode: "", countryName: "", city: "Основной сервер", latitude: nil, longitude: nil, host: profile.host, port: profile.port, mode: profile.mode, wrapAPassword: profile.wrapAPassword, connectionsBalanced: profile.connectionsBalanced, connectionsMaximum: profile.connectionsMaximum, mtu: profile.mtu, dns: profile.dns, latencyMS: nil, online: true, amneziaConfig: profile.amneziaConfig)
    }

    private static func stableUUID(for host: String, port: Int) -> UUID {
        let source = Array("\(host):\(port)".utf8)
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, value) in source.enumerated() { bytes[index % 16] = bytes[index % 16] &+ value &+ UInt8(truncatingIfNeeded: index) }
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
private struct ActivatedServerEnvelope: Codable { let server: RemoteVPNServer }

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
    private static let account = "server-directory-v2"
    static func load() -> [RemoteVPNServer] {
        guard let value = KeychainStore.readString(account: account), let data = value.data(using: .utf8), let servers = try? JSONDecoder().decode([RemoteVPNServer].self, from: data) else { return [] }
        return servers
    }
    static func save(_ servers: [RemoteVPNServer]) {
        guard let data = try? JSONEncoder().encode(servers), let value = String(data: data, encoding: .utf8) else { return }
        try? KeychainStore.writeString(value, account: account)
    }
    static func merge(_ servers: [RemoteVPNServer], provisioned profile: DarkTunnelServerProfile?) -> [RemoteVPNServer] {
        var result = servers
        if let profile, !result.contains(where: { $0.host == profile.host && $0.port == profile.port }) { result.insert(.provisioned(profile), at: 0) }
        var seen = Set<String>()
        return result.filter { seen.insert("\($0.host):\($0.port)").inserted }
    }
    static func mergeSecure(_ secure: RemoteVPNServer, into servers: [RemoteVPNServer]) -> [RemoteVPNServer] {
        var result = servers
        if let index = result.firstIndex(where: { $0.id == secure.id || ($0.host == secure.host && $0.port == secure.port) }) { result[index] = secure }
        else { result.insert(secure, at: 0) }
        return result
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
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ServerDirectoryError.invalidResponse }
        let result = try JSONDecoder().decode(ServerListEnvelope.self, from: data)
        guard !result.servers.isEmpty else { throw ServerDirectoryError.noServers }
        return result.servers
    }

    func fetchActivatedPrimary() async throws -> RemoteVPNServer {
        guard let token = KeychainStore.readString(account: "activation-token"), !token.isEmpty else { throw ServerDirectoryError.invalidResponse }
        return try await fetchActivatedServer(path: "/v1/activation/server-profile")
    }

    func fetchActivatedServer(_ serverID: String) async throws -> RemoteVPNServer {
        guard UUID(uuidString: serverID) != nil else { throw ServerDirectoryError.invalidResponse }
        return try await fetchActivatedServer(path: "/v1/activation/server-profile/\(serverID)")
    }

    private func fetchActivatedServer(path: String) async throws -> RemoteVPNServer {
        guard let token = KeychainStore.readString(account: "activation-token"), !token.isEmpty else { throw ServerDirectoryError.invalidResponse }
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "token", value: token), URLQueryItem(name: "installation_id", value: DeviceIdentity.installationID)]
        guard let url = components.url else { throw ServerDirectoryError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ServerDirectoryError.invalidResponse }
        return try JSONDecoder().decode(ActivatedServerEnvelope.self, from: data).server
    }
}

enum CapitalCoordinates {
    private static let values: [String: (Double, Double)] = [
        "NL": (52.3676, 4.9041), "DE": (52.5200, 13.4050), "FR": (48.8566, 2.3522), "GB": (51.5074, -0.1278), "US": (38.9072, -77.0369), "CA": (45.4215, -75.6972), "FI": (60.1699, 24.9384), "SE": (59.3293, 18.0686), "NO": (59.9139, 10.7522), "DK": (55.6761, 12.5683), "PL": (52.2297, 21.0122), "CZ": (50.0755, 14.4378), "AT": (48.2082, 16.3738), "CH": (46.9480, 7.4474), "BE": (50.8503, 4.3517), "IE": (53.3498, -6.2603), "ES": (40.4168, -3.7038), "IT": (41.9028, 12.4964), "PT": (38.7223, -9.1393), "TR": (39.9334, 32.8597), "AE": (24.4539, 54.3773), "IL": (31.7683, 35.2137), "JP": (35.6762, 139.6503), "SG": (1.3521, 103.8198), "AU": (-35.2809, 149.1300), "BR": (-15.7975, -47.8919), "AR": (-34.6037, -58.3816), "KZ": (51.1694, 71.4491), "GE": (41.7151, 44.8271), "AM": (40.1872, 44.5152), "RU": (55.7558, 37.6173)
    ]
    static func `forCountry`(_ code: String) -> (latitude: Double, longitude: Double)? {
        guard let value = values[code.uppercased()] else { return nil }
        return (value.0, value.1)
    }
}
