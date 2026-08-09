import Foundation
import Network

struct ConnectivitySnapshot: Equatable {
    enum ServiceState: String {
        case reachable
        case blocked
        case unknown
    }

    enum NetworkKind: String {
        case wifi = "Wi‑Fi"
        case cellular = "Мобильная сеть"
        case wired = "Проводная сеть"
        case other = "Сеть"
        case unavailable = "Нет сети"
    }

    let hasNetworkPath: Bool
    let networkKind: NetworkKind
    let vk: ServiceState
    let google: ServiceState
    let checkedAt: Date

    var recommendedTransport: TransportKind {
        guard hasNetworkPath else { return .automatic }

        switch networkKind {
        case .wifi, .wired:
            return .amneziaWG
        case .cellular:
            switch (google, vk) {
            case (.blocked, .reachable):
                return .vkTurn
            case (.reachable, .reachable):
                return .amneziaWG
            case (.reachable, .blocked):
                return .amneziaWG
            case (.blocked, .blocked):
                return .vkTurn
            default:
                return .amneziaWG
            }
        case .other, .unavailable:
            return .amneziaWG
        }
    }

    var summary: String {
        guard hasNetworkPath else { return "Нет доступа к сети" }

        switch networkKind {
        case .wifi, .wired:
            return "\(networkKind.rawValue) · используем AmneziaWG"
        case .cellular:
            switch (google, vk) {
            case (.blocked, .reachable):
                return "Google недоступен, VK доступен · используем VK обход"
            case (.reachable, .reachable):
                return "Google и VK доступны · используем AmneziaWG"
            case (.reachable, .blocked):
                return "Google доступен, VK ограничен · используем AmneziaWG"
            case (.blocked, .blocked):
                return "Google и VK недоступны · пробуем VK обход"
            default:
                return "Проверяем доступность Google и VK"
            }
        case .other, .unavailable:
            return "Проверяем доступность сети"
        }
    }
}

actor ConnectivityDiagnostics {
    static let shared = ConnectivityDiagnostics()

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 5
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: configuration)
    }

    func run() async -> ConnectivitySnapshot {
        let path = await currentPath()
        guard path.status == .satisfied else {
            return ConnectivitySnapshot(
                hasNetworkPath: false,
                networkKind: .unavailable,
                vk: .unknown,
                google: .unknown,
                checkedAt: Date()
            )
        }

        async let vkState = probe(url: URL(string: "https://vk.com/favicon.ico")!)
        async let googleState = probe(url: URL(string: "https://www.google.com/generate_204")!)
        let (vk, google) = await (vkState, googleState)

        return ConnectivitySnapshot(
            hasNetworkPath: true,
            networkKind: networkKind(for: path),
            vk: vk,
            google: google,
            checkedAt: Date()
        )
    }

    private func probe(url: URL) async -> ConnectivitySnapshot.ServiceState {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unknown }
            return (200..<500).contains(http.statusCode) ? .reachable : .blocked
        } catch {
            return .blocked
        }
    }

    private func currentPath() async -> NWPath {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "DarkTunnel.ConnectivityDiagnostics.Path")
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                continuation.resume(returning: path)
            }
            monitor.start(queue: queue)
        }
    }

    private func networkKind(for path: NWPath) -> ConnectivitySnapshot.NetworkKind {
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return .other
    }
}
