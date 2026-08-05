import Foundation
import CoreLocation

enum VPNConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting

    var title: String {
        switch self {
        case .disconnected: "VPN выключен"
        case .connecting: "Подключение…"
        case .connected: "Защищено"
        case .reconnecting: "Переподключение…"
        }
    }

    var buttonTitle: String {
        switch self {
        case .disconnected: "Подключиться"
        case .connecting, .reconnecting: "Отмена"
        case .connected: "Отключиться"
        }
    }
}

enum TransportKind: String, Identifiable {
    case automatic = "Автоматически"
    case amneziaWG = "AmneziaWG 2.0"
    case vkTurn = "VK TURN"

    static let allCases: [TransportKind] = [.automatic, .vkTurn]

    var id: String { rawValue }

    var description: String {
        switch self {
        case .automatic:
            return "Подключаться через VK TURN и сохранённую конфигурацию сервера"
        case .amneziaWG:
            return "Недоступно в этой сборке"
        case .vkTurn:
            return "Сначала VK TURN, затем WDTT и встроенный WireGuard"
        }
    }
}

enum SpeedMode: Int, CaseIterable, Identifiable {
    case balanced = 3
    case maximum = 10

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .balanced: "Баланс"
        case .maximum: "Максимум"
        }
    }
}

struct VPNServer: Identifiable, Hashable {
    let id: UUID
    let name: String
    let country: String
    let city: String
    let flag: String
    let latitude: Double
    let longitude: Double
    let latencyMilliseconds: Int

    init(
        id: UUID = UUID(),
        name: String,
        country: String,
        city: String,
        flag: String,
        latitude: Double,
        longitude: Double,
        latencyMilliseconds: Int
    ) {
        self.id = id
        self.name = name
        self.country = country
        self.city = city
        self.flag = flag
        self.latitude = latitude
        self.longitude = longitude
        self.latencyMilliseconds = latencyMilliseconds
    }

    var coordinate: CLLocationCoordinate2D {
        .init(latitude: latitude, longitude: longitude)
    }
}
