import Foundation
import SwiftUI

struct DarkTunnelRemoteAnnouncement: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let body: String
    let placement: String
    let colorHex: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, body, placement
        case colorHex = "color_hex"
        case createdAt = "created_at"
    }

    var normalizedPlacement: String {
        placement.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isHome: Bool {
        let value = normalizedPlacement
        return value == "home" || value == "both"
    }

    var isServer: Bool {
        let value = normalizedPlacement
        return value == "server" || value == "servers" || value == "both"
    }

    var accentColor: Color { Color(hex: colorHex) }
}

@MainActor
final class AnnouncementFeed: ObservableObject {
    static let shared = AnnouncementFeed()

    @Published private(set) var home: [DarkTunnelRemoteAnnouncement] = []
    @Published private(set) var server: [DarkTunnelRemoteAnnouncement] = []
    @Published private(set) var lastRefresh: Date?

    private init() {}

    func refresh() async {
        guard let url = URL(string: "https://api.31-77-148-80.sslip.io/v1/announcements") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            struct Envelope: Decodable { let announcements: [DarkTunnelRemoteAnnouncement] }
            let payload = try JSONDecoder().decode(Envelope.self, from: data)
            home = payload.announcements.filter(\.isHome)
            server = payload.announcements.filter(\.isServer)
            lastRefresh = Date()
        } catch {
            AppLog.shared.warning("Announcements", "Не удалось обновить объявления: \(error.localizedDescription)")
        }
    }
}

private extension Color {
    init(hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
