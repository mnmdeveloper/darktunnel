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
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            country: countryName.isEmpty ? "Сервер" : countryName,
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

actor ServerDirectoryClient {
    static let shared = ServerDirectoryClient()
    private let baseURL = URL(string: "https://api.31-77-148-80.sslip.io")!

    func fetchServers() async throws -> [RemoteVPNServer] {
        let url = baseURL.appending(path: "/v1/servers")
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadRevalidatingCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServerDirectoryError.invalidResponse
        }
        let result = try JSONDecoder().decode(ServerListEnvelope.self, from: data)
        guard !result.servers.isEmpty else { throw ServerDirectoryError.noServers }
        return result.servers.filter(\.online)
    }

    func fetchRecommended() async throws -> RemoteVPNServer {
        let url = baseURL.appending(path: "/v1/servers/recommended")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServerDirectoryError.invalidResponse
        }
        return try JSONDecoder().decode(RemoteVPNServer.self, from: data)
    }
}
