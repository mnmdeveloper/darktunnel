import Foundation
import Security
import SwiftUI
import UIKit

struct DarkTunnelServerProfile: Codable, Equatable {
    let host: String
    let port: Int
    let mode: String
    let wrapAPassword: String
    let connectionsBalanced: Int
    let connectionsMaximum: Int
    let mtu: Int
    let dns: String

    enum CodingKeys: String, CodingKey {
        case host, port, mode, mtu, dns
        case wrapAPassword = "wrap_a_password"
        case connectionsBalanced = "connections_balanced"
        case connectionsMaximum = "connections_maximum"
    }
}

struct DarkTunnelActivationResponse: Codable {
    let userID: String
    let deviceID: String
    let subscriptionExpiresAt: Date
    let refreshToken: String
    let server: DarkTunnelServerProfile

    enum CodingKeys: String, CodingKey {
        case server
        case userID = "user_id"
        case deviceID = "device_id"
        case subscriptionExpiresAt = "subscription_expires_at"
        case refreshToken = "refresh_token"
    }
}

private struct ActivationRequest: Encodable {
    let token: String
    let installationID: String
    let publicKey: String
    let appVersion: String
    let iosVersion: String

    enum CodingKeys: String, CodingKey {
        case token
        case installationID = "installation_id"
        case publicKey = "public_key"
        case appVersion = "app_version"
        case iosVersion = "ios_version"
    }
}

private struct APIErrorResponse: Decodable { let detail: String? }

enum ActivationClientError: LocalizedError {
    case invalidLink
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidLink: return "Неверная ссылка активации"
        case .invalidResponse: return "Backend вернул некорректный ответ"
        case .server(let message): return message
        }
    }
}

actor DarkTunnelActivationClient {
    static let shared = DarkTunnelActivationClient()
    private let endpoint = URL(string: "https://api.31-77-148-80.sslip.io/v1/activation/redeem")!

    func redeem(token: String) async throws -> DarkTunnelActivationResponse {
        let requestBody = ActivationRequest(
            token: token,
            installationID: DeviceIdentity.installationID,
            publicKey: DeviceIdentity.activationPublicKey,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            iosVersion: UIDevice.current.systemVersion
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ActivationClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? JSONDecoder().decode(APIErrorResponse.self, from: data).detail
            throw ActivationClientError.server(detail ?? "Ошибка активации: HTTP \(http.statusCode)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let result = try? decoder.decode(DarkTunnelActivationResponse.self, from: data) else {
            throw ActivationClientError.invalidResponse
        }
        return result
    }
}

enum DeviceIdentity {
    private static let installationKey = "darktunnel.installation-id"
    private static let publicKeyKey = "darktunnel.activation-public-key"

    static var installationID: String {
        if let existing = UserDefaults.standard.string(forKey: installationKey) { return existing }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: installationKey)
        return value
    }

    static var activationPublicKey: String {
        if let existing = KeychainStore.readString(account: publicKeyKey) { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let value = status == errSecSuccess ? Data(bytes).base64EncodedString() : UUID().uuidString + UUID().uuidString
        try? KeychainStore.writeString(value, account: publicKeyKey)
        return value
    }
}

enum KeychainStore {
    private static let service = "app.lavender3512.currant6944.activation"

    static func writeString(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func readString(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class ActivationStore: ObservableObject {
    static let shared = ActivationStore()

    @Published private(set) var isActivated = UserDefaults.standard.bool(forKey: "hasCompletedActivation")
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var subscriptionExpiresAt: Date?
    @Published private(set) var serverProfile: DarkTunnelServerProfile?

    private let profileAccount = "server-profile"
    private let expirationKey = "darktunnel.subscription-expiration"
    private let refreshTokenAccount = "refresh-token"

    init() { restoreLocalState() }

    func handle(url: URL) {
        guard url.scheme?.lowercased() == "darktunnel", url.host?.lowercased() == "activate",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "d" })?.value, !token.isEmpty else {
            errorMessage = ActivationClientError.invalidLink.localizedDescription
            AppLog.shared.warning("Activation", "Получена неверная ссылка активации")
            return
        }
        AppLog.shared.info("Activation", "Получена ссылка активации")
        Task { await activate(token: token) }
    }

    func activate(token: String) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            AppLog.shared.info("Activation", "Запрос к backend начат")
            let result = try await DarkTunnelActivationClient.shared.redeem(token: token)
            try persist(result)
            subscriptionExpiresAt = result.subscriptionExpiresAt
            serverProfile = result.server
            isActivated = true
            UserDefaults.standard.set(true, forKey: "hasCompletedActivation")
            AppLog.shared.info("Activation", "Активация успешна; сервер \(result.server.host):\(result.server.port)")
        } catch {
            errorMessage = error.localizedDescription
            AppLog.shared.error("Activation", error.localizedDescription)
        }
    }

    func reset() {
        UserDefaults.standard.set(false, forKey: "hasCompletedActivation")
        UserDefaults.standard.removeObject(forKey: expirationKey)
        KeychainStore.delete(account: profileAccount)
        KeychainStore.delete(account: refreshTokenAccount)
        isActivated = false
        subscriptionExpiresAt = nil
        serverProfile = nil
        AppLog.shared.info("Activation", "Локальная активация сброшена")
    }

    private func persist(_ result: DarkTunnelActivationResponse) throws {
        try KeychainStore.writeString(result.refreshToken, account: refreshTokenAccount)
        let profileData = try JSONEncoder().encode(result.server)
        guard let profileString = String(data: profileData, encoding: .utf8) else { throw ActivationClientError.invalidResponse }
        try KeychainStore.writeString(profileString, account: profileAccount)
        UserDefaults.standard.set(result.subscriptionExpiresAt, forKey: expirationKey)
    }

    private func restoreLocalState() {
        subscriptionExpiresAt = UserDefaults.standard.object(forKey: expirationKey) as? Date
        if let profileString = KeychainStore.readString(account: profileAccount), let data = profileString.data(using: .utf8) {
            serverProfile = try? JSONDecoder().decode(DarkTunnelServerProfile.self, from: data)
        }
        if let expiration = subscriptionExpiresAt, expiration <= Date() {
            isActivated = false
            UserDefaults.standard.set(false, forKey: "hasCompletedActivation")
        } else if serverProfile == nil {
            isActivated = false
            UserDefaults.standard.set(false, forKey: "hasCompletedActivation")
        }
    }
}

struct BackendActivationView: View {
    @EnvironmentObject private var activation: ActivationStore
    @State private var pastedLink = ""

    var body: some View {
        ZStack {
            LinearGradient(colors: [.black, Color(red: 0.05, green: 0.08, blue: 0.13)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer()
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 72, weight: .semibold)).foregroundStyle(.white)
                Text("DarkTunnel").font(.largeTitle.bold())
                Text("Откройте ссылку доступа из Telegram или вставьте её ниже").foregroundStyle(.secondary).multilineTextAlignment(.center)
                TextField("darktunnel://activate?d=…", text: $pastedLink)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).padding(14)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                Button {
                    guard let url = URL(string: pastedLink.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        activation.errorMessage = ActivationClientError.invalidLink.localizedDescription
                        return
                    }
                    activation.handle(url: url)
                } label: {
                    HStack {
                        if activation.isLoading { ProgressView().tint(.black) }
                        Text(activation.isLoading ? "Активация…" : "Активировать").fontWeight(.semibold)
                    }.frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                .disabled(activation.isLoading || pastedLink.isEmpty)
                if let error = activation.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Spacer()
            }.padding(24)
        }.preferredColorScheme(.dark)
    }
}
