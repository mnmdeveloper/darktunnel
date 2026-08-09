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
        case .connected: "Подключено"
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

enum TransportKind: String, CaseIterable, Identifiable {
    case automatic = "Автоматически"
    case amneziaWG = "AmneziaWG"
    case vkTurn = "VK обход"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .automatic:
            return "Wi‑Fi → AmneziaWG · мобильная сеть → проверка Google и VK"
        case .amneziaWG:
            return "Прямое подключение через AmneziaWG 2.0"
        case .vkTurn:
            return "Обход через VK-звонок"
        }
    }
}

enum SpeedMode: Int, CaseIterable, Identifiable {
    case balanced = 5
    case maximum = 10

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .balanced: "Стандарт"
        case .maximum: "Максимум"
        }
    }

    var subtitle: String {
        switch self {
        case .balanced: "5 соединений — режим по умолчанию"
        case .maximum: "10 соединений — ручной максимум"
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
