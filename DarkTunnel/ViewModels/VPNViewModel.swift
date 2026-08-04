import Foundation
import SwiftUI

@MainActor
final class VPNViewModel: ObservableObject {
    @Published var state: VPNConnectionState = .disconnected
    @Published var selectedServer: VPNServer = VPNServer.samples[0]
    @Published var speedMode: SpeedMode = .maximum
    @Published var preferredTransport: TransportKind = .automatic
    @Published var disconnectOnSleep = false
    @Published var reconnectAfterWake = true
    @Published var routeAPNsThroughVPN = false
    @Published var vkCallLink = UserDefaults.standard.string(forKey: "vkCallLink") ?? ""

    let servers = VPNServer.samples

    var networkName: String { "Wi‑Fi · домашняя сеть" }

    var activeTransport: TransportKind {
        switch preferredTransport {
        case .automatic: return networkName.contains("Wi") ? .amneziaWG : .wdtt
        case .amneziaWG: return .amneziaWG
        case .wdtt: return .wdtt
        }
    }

    var statusDetail: String {
        switch state {
        case .disconnected: return "Трафик идёт напрямую"
        case .connecting: return "Подготавливаем защищённый канал"
        case .connected: return "\(activeTransport.rawValue) · \(selectedServer.latencyMilliseconds) мс"
        case .reconnecting: return "Переключаем сервер"
        }
    }

    var hasValidVKLink: Bool {
        guard let url = URL(string: vkCallLink), let host = url.host else { return false }
        return host.contains("vk.me") || host.contains("vk.com")
    }

    func saveVKLink() {
        UserDefaults.standard.set(vkCallLink.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "vkCallLink")
    }

    func toggleConnection() {
        switch state {
        case .disconnected: connect()
        case .connecting, .reconnecting, .connected: disconnect()
        }
    }

    func connect() {
        state = .connecting
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard state == .connecting else { return }
            withAnimation(.snappy(duration: 0.35)) { state = .connected }
            LiveActivityController.shared.start(
                server: selectedServer.city,
                latency: selectedServer.latencyMilliseconds,
                transport: activeTransport.rawValue
            )
        }
    }

    func disconnect() {
        withAnimation(.snappy(duration: 0.3)) { state = .disconnected }
        LiveActivityController.shared.end()
    }

    func select(_ server: VPNServer) {
        selectedServer = server
        guard state == .connected else { return }
        state = .reconnecting
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard state == .reconnecting else { return }
            state = .connected
            LiveActivityController.shared.update(
                server: selectedServer.city,
                latency: selectedServer.latencyMilliseconds,
                transport: activeTransport.rawValue
            )
        }
    }
}
