import Foundation
import SwiftUI

struct AppStoreUpdateInfo: Equatable {
    let version: String
    let releaseNotes: String?
    let storeURL: URL
}

@MainActor
final class AppUpdateService: ObservableObject {
    static let shared = AppUpdateService()

    @Published private(set) var update: AppStoreUpdateInfo?
    @Published private(set) var isChecking = false

    private let bundleID = "app.lavender3512.currant6944"

    private init() {}

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        guard let encoded = bundleID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(encoded)&country=us") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData

        struct Response: Decodable {
            struct Result: Decodable {
                let version: String
                let releaseNotes: String?
                let trackViewUrl: String?
            }
            let resultCount: Int
            let results: [Result]
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard decoded.resultCount > 0, let result = decoded.results.first,
                  let storeURL = result.trackViewUrl.flatMap(URL.init(string:)) else { return }
            guard Self.compare(result.version, Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") > 0 else {
                update = nil
                return
            }
            update = AppStoreUpdateInfo(version: result.version, releaseNotes: result.releaseNotes, storeURL: storeURL)
        } catch {
            AppLog.shared.warning("Updates", "Проверка App Store недоступна: \(error.localizedDescription)")
        }
    }

    private static func compare(_ lhs: String, _ rhs: String) -> Int {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av < bv ? -1 : 1 }
        }
        return 0
    }
}
