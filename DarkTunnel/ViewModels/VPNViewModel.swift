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
    @Published var showsAnnouncement = true

    let servers = VPNServer.samples

    var networkName: String { "Wi‑Fi · домашняя сеть" }

    var activeTransport: TransportKind {
        switch preferredTransport {
        case .automatic:
            return networkName.contains("Wi") ? .amneziaWG : .wdtt
        case .amneziaWG:
            return .amneziaWG
        case .wdtt:
            return .wdtt
        }
    }

    var statusDetail: String {
        switch state {
        case .disconnected:
            "Трафик идёт напрямую"
        case .connecting:
            "Проверяем сеть и выбираем протокол"
        case .connected:
            "\(activeTransport.rawValue) · \(selectedServer.latencyMilliseconds) мс"
        case .reconnecting:
            "Ищем доступный сервер"
        }
    }

    func toggleConnection() {
        switch state {
        case .disconnected:
            connect()
        case .connecting, .reconnecting, .connected:
            disconnect()
        }
    }

    func connect() {
        state = .connecting
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard state == .connecting else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                state = .connected
            }
        }
    }

    func disconnect() {
        withAnimation(.easeInOut(duration: 0.3)) {
            state = .disconnected
        }
    }

    func select(_ server: VPNServer) {
        selectedServer = server
        if state == .connected {
            state = .reconnecting
            Task {
                try? await Task.sleep(for: .milliseconds(650))
                guard state == .reconnecting else { return }
                state = .connected
            }
        }
    }

    func dismissAnnouncement() {
        withAnimation(.easeInOut) {
            showsAnnouncement = false
        }
    }
}
