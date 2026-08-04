import Foundation
import Network

@MainActor
final class NetworkPolicy: ObservableObject {
    enum AccessPath: String {
        case wifi = "Wi‑Fi"
        case cellular = "LTE/5G"
        case unavailable = "Нет сети"
    }

    @Published private(set) var path: AccessPath = .unavailable
    @Published private(set) var recommendedTransport: TransportKind = .automatic

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "DarkTunnel.NetworkPolicy")

    init() {
        monitor.pathUpdateHandler = { [weak self] update in
            Task { @MainActor in
                guard let self else { return }
                if update.status != .satisfied {
                    self.path = .unavailable
                    self.recommendedTransport = .automatic
                } else if update.usesInterfaceType(.wifi) {
                    self.path = .wifi
                    self.recommendedTransport = .amneziaWG
                } else if update.usesInterfaceType(.cellular) {
                    self.path = .cellular
                    self.recommendedTransport = .automatic
                } else {
                    self.path = .wifi
                    self.recommendedTransport = .automatic
                }
            }
        }
        monitor.start(queue: queue)
    }
}
