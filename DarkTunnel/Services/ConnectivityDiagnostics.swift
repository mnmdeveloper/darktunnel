import Foundation
import Network

struct ConnectivitySnapshot: Equatable {
    enum ServiceState: String {
        case reachable
        case blocked
        case unknown
    }

    let hasNetworkPath: Bool
    let vk: ServiceState
    let google: ServiceState
    let checkedAt: Date

    var recommendedTransport: TransportKind {
        guard hasNetworkPath else { return .automatic }

        switch (vk, google) {
        case (.reachable, .blocked):
            return .vkTurn
        case (.reachable, .reachable), (.blocked, .reachable):
            return .amneziaWG
        case (.blocked, .blocked), (.unknown, .unknown):
            return .vkTurn
        default:
            return .amneziaWG
        }
    }

    var summary: String {
        guard hasNetworkPath else { return "Нет доступа к сети" }

        switch (vk, google) {
        case (.reachable, .reachable):
            return "VK и внешний интернет доступны"
        case (.reachable, .blocked):
            return "VK доступен, внешний интернет ограничен — нужен режим VK TURN"
        case (.blocked, .reachable):
            return "Внешний интернет доступен, VK недоступен"
        case (.blocked, .blocked):
            return "Сервисы недоступны — проверим режим VK TURN"
        default:
            return "Доступность сервисов определяется"
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
        let hasPath = await hasSatisfiedPath()
        guard hasPath else {
            return ConnectivitySnapshot(hasNetworkPath: false, vk: .unknown, google: .unknown, checkedAt: Date())
        }

        async let vkState = probe(url: URL(string: "https://vk.com/favicon.ico")!)
        async let googleState = probe(url: URL(string: "https://www.gstatic.com/generate_204")!)

        return await ConnectivitySnapshot(hasNetworkPath: true, vk: vkState, google: googleState, checkedAt: Date())
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

    private func hasSatisfiedPath() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "DarkTunnel.ConnectivityDiagnostics.Path")
            var resumed = false

            monitor.pathUpdateHandler = { path in
                guard !resumed else { return }
                resumed = true
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }

            monitor.start(queue: queue)
        }
    }
}
