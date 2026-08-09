import Foundation

struct DarkTunnelAnnouncement: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let body: String
    let placement: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, body, placement
        case createdAt = "created_at"
    }
}

@MainActor
final class AnnouncementStore: ObservableObject {
    static let shared = AnnouncementStore()

    @Published private(set) var announcements: [DarkTunnelAnnouncement] = []
    @Published private(set) var isLoading = false

    private let endpoint = URL(string: "https://api.31-77-148-80.sslip.io/v1/announcements")!

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 5
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            announcements = envelope.announcements
        } catch {
            AppLog.shared.warning("Announcements", error.localizedDescription)
        }
    }

    var home: [DarkTunnelAnnouncement] { announcements.filter { $0.placement == "home" || $0.placement == "both" } }
    var servers: [DarkTunnelAnnouncement] { announcements.filter { $0.placement == "servers" || $0.placement == "both" } }

    private struct Envelope: Codable {
        let announcements: [DarkTunnelAnnouncement]
    }
}
