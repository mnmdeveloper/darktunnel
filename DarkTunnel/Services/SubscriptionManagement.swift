import Foundation
import SwiftUI

struct SubscriptionDevice: Codable, Identifiable, Equatable {
    let id: String
    let installationID: String
    let appVersion: String
    let iosVersion: String
    let createdAt: Date
    let lastSeenAt: Date
    let revokedAt: Date?
    enum CodingKeys: String, CodingKey { case id; case installationID = "installation_id"; case appVersion = "app_version"; case iosVersion = "ios_version"; case createdAt = "created_at"; case lastSeenAt = "last_seen_at"; case revokedAt = "revoked_at" }
    var isCurrent: Bool { installationID == DeviceIdentity.installationID }
}

struct SubscriptionAccessResponse: Codable, Equatable {
    let userID: String
    let status: String
    let active: Bool
    let lifetime: Bool
    let subscriptionExpiresAt: Date?
    let telegramID: Int64?
    let note: String
    let devices: [SubscriptionDevice]
    enum CodingKeys: String, CodingKey { case userID = "user_id"; case status, active, lifetime; case subscriptionExpiresAt = "subscription_expires_at"; case telegramID = "telegram_id"; case note, devices }
}

private struct SubscriptionLinkResponse: Codable { let subscriptionLink: String; enum CodingKeys: String, CodingKey { case subscriptionLink = "subscription_link" } }
private struct SubscriptionAPIError: Codable { let detail: String? }

enum SubscriptionManagementError: LocalizedError {
    case unauthorized, invalidLink, server(String), invalidResponse
    var errorDescription: String? {
        switch self { case .unauthorized: return "Нет действующего доступа к подписке"; case .invalidLink: return "Неверная ссылка подписки"; case .server(let message): return message; case .invalidResponse: return "Backend вернул некорректный ответ" }
    }
}

actor SubscriptionManagementClient {
    static let shared = SubscriptionManagementClient()
    private let baseURL = URL(string: "https://api.31-77-148-80.sslip.io")!
    private func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    private func request(_ url: URL, method: String = "GET", headers: [String: String] = [:]) -> URLRequest { var r = URLRequest(url: url); r.httpMethod = method; r.timeoutInterval = 12; r.cachePolicy = .reloadIgnoringLocalCacheData; headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }; return r }
    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SubscriptionManagementError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { let detail = try? decoder().decode(SubscriptionAPIError.self, from: data).detail; if http.statusCode == 401 || http.statusCode == 403 { throw SubscriptionManagementError.unauthorized }; throw SubscriptionManagementError.server(detail ?? "Ошибка backend: HTTP \(http.statusCode)") }
        return data
    }
    func createLink() async throws -> String {
        guard let token = KeychainStore.readString(account: "refresh-token"), !token.isEmpty else { throw SubscriptionManagementError.unauthorized }
        var c = URLComponents(url: baseURL.appending(path: "/v1/subscription/access-link"), resolvingAgainstBaseURL: false)!; c.queryItems = [URLQueryItem(name: "installation_id", value: DeviceIdentity.installationID)]; guard let url = c.url else { throw SubscriptionManagementError.invalidResponse }
        let data = try await perform(request(url, method: "POST", headers: ["X-Device-Token": token, "Accept": "application/json"]))
        return try decoder().decode(SubscriptionLinkResponse.self, from: data).subscriptionLink
    }
    func load(token: String) async throws -> SubscriptionAccessResponse {
        guard !token.isEmpty else { throw SubscriptionManagementError.invalidLink }
        var c = URLComponents(url: baseURL.appending(path: "/v1/subscription/access"), resolvingAgainstBaseURL: false)!; c.queryItems = [URLQueryItem(name: "token", value: token)]; guard let url = c.url else { throw SubscriptionManagementError.invalidResponse }
        let data = try await perform(request(url)); return try decoder().decode(SubscriptionAccessResponse.self, from: data)
    }
    func revokeDevice(_ deviceID: String, token: String) async throws { guard let url = URL(string: "\(baseURL.absoluteString)/v1/subscription/access/devices/\(deviceID)") else { throw SubscriptionManagementError.invalidResponse }; _ = try await perform(request(url, method: "DELETE", headers: ["X-Subscription-Access-Token": token])) }
    func rotate(token: String) async throws -> String {
        var c = URLComponents(url: baseURL.appending(path: "/v1/subscription/access/rotate"), resolvingAgainstBaseURL: false)!; c.queryItems = [URLQueryItem(name: "token", value: token)]; guard let url = c.url else { throw SubscriptionManagementError.invalidResponse }
        let data = try await perform(request(url, method: "POST")); return try decoder().decode(SubscriptionLinkResponse.self, from: data).subscriptionLink
    }
}

@MainActor
final class SubscriptionManagementStore: ObservableObject {
    static let shared = SubscriptionManagementStore()
    @Published private(set) var summary: SubscriptionAccessResponse?
    @Published private(set) var accessLink: String?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var isPresented = false
    private var accessToken = ""
    private init() {}
    func present() { isPresented = true; if summary == nil { Task { await prepare() } } }
    func open(url: URL) {
        guard url.scheme?.lowercased() == "darktunnel", url.host?.lowercased() == "subscription", let c = URLComponents(url: url, resolvingAgainstBaseURL: false), let token = c.queryItems?.first(where: { $0.name == "t" })?.value, !token.isEmpty else { errorMessage = SubscriptionManagementError.invalidLink.localizedDescription; return }
        accessToken = token; accessLink = url.absoluteString; isPresented = true; Task { await load() }
    }
    func prepare() async {
        if !accessToken.isEmpty { await load(); return }
        isLoading = true; errorMessage = nil; defer { isLoading = false }
        do { let link = try await SubscriptionManagementClient.shared.createLink(); accessLink = link; accessToken = Self.token(from: link) ?? ""; try await reload() } catch { errorMessage = error.localizedDescription }
    }
    func load() async { guard !accessToken.isEmpty else { await prepare(); return }; isLoading = true; errorMessage = nil; defer { isLoading = false }; do { try await reload() } catch { errorMessage = error.localizedDescription } }
    func revoke(_ device: SubscriptionDevice) async { guard !accessToken.isEmpty else { return }; isLoading = true; defer { isLoading = false }; do { try await SubscriptionManagementClient.shared.revokeDevice(device.id, token: accessToken); try await reload() } catch { errorMessage = error.localizedDescription } }
    func rotateLink() async { guard !accessToken.isEmpty else { return }; isLoading = true; defer { isLoading = false }; do { let link = try await SubscriptionManagementClient.shared.rotate(token: accessToken); accessLink = link; accessToken = Self.token(from: link) ?? ""; try await reload() } catch { errorMessage = error.localizedDescription } }
    private func reload() async throws { summary = try await SubscriptionManagementClient.shared.load(token: accessToken); if accessLink == nil { accessLink = "darktunnel://subscription?t=\(accessToken)" } }
    private static func token(from link: String) -> String? { guard let url = URL(string: link), url.host?.lowercased() == "subscription", let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }; return c.queryItems?.first(where: { $0.name == "t" })?.value }
}

struct SubscriptionManagementView: View {
    @ObservedObject private var store = SubscriptionManagementStore.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack { Color.black.ignoresSafeArea(); ScrollView { VStack(spacing: 16) { subscriptionCard; linkCard; devicesCard; if let error = store.errorMessage { Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) } }.padding(16) }; if store.isLoading { ProgressView().tint(.white) } }
            .navigationTitle("Моя подписка").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(.secondary) } } }
            .task { await store.prepare() }
        }.preferredColorScheme(.dark)
    }
    private var subscriptionCard: some View { VStack(alignment: .leading, spacing: 10) { Label("Подписка", systemImage: "checkmark.shield.fill").font(.headline); if let s = store.summary { Text(s.lifetime ? "Бессрочная" : (s.subscriptionExpiresAt.map(Self.dateText) ?? "—")).font(.title2.bold()); Text(s.active ? "Активна" : "Недоступна").font(.caption.weight(.semibold)).foregroundStyle(s.active ? .green : .red); Text("Устройств: \(s.devices.filter { $0.revokedAt == nil }.count)").font(.caption).foregroundStyle(.secondary) } else { Text("Загрузка…").foregroundStyle(.secondary) } }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22)).overlay { RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.08)) } }
    private var linkCard: some View { VStack(alignment: .leading, spacing: 10) { Text("Ссылка подписки").font(.headline); Text("Сохраните её или передайте на другое своё устройство.").font(.caption).foregroundStyle(.secondary); if let link = store.accessLink { Text(link).font(.caption2.monospaced()).textSelection(.enabled).lineLimit(3); HStack { ShareLink(item: link) { Label("Поделиться", systemImage: "square.and.arrow.up") }; Spacer(); Button("Обновить") { Task { await store.rotateLink() } } }.font(.subheadline.weight(.semibold)) } }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22)).overlay { RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.08)) } }
    private var devicesCard: some View { VStack(alignment: .leading, spacing: 8) { Text("Устройства").font(.headline); if let devices = store.summary?.devices, !devices.isEmpty { ForEach(devices) { d in HStack(spacing: 10) { Image(systemName: d.isCurrent ? "iphone.gen3" : "iphone").frame(width: 28); VStack(alignment: .leading, spacing: 2) { Text(d.isCurrent ? "Это устройство" : "Устройство \(d.installationID.suffix(8))").font(.subheadline.weight(.semibold)); Text("iOS \(d.iosVersion.isEmpty ? "—" : d.iosVersion) · \(Self.dateText(d.lastSeenAt))").font(.caption2).foregroundStyle(.secondary) }; Spacer(); if d.revokedAt == nil { Button(role: .destructive) { Task { await store.revoke(d) } } label: { Image(systemName: "trash") }.buttonStyle(.borderless) } }.padding(.vertical, 7); if d.id != devices.last?.id { Divider().overlay(.white.opacity(0.07)) } } } else { Text("Устройств пока нет").font(.caption).foregroundStyle(.secondary) } }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22)).overlay { RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.08)) } }
    private static func dateText(_ date: Date) -> String { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f.string(from: date) }
}
