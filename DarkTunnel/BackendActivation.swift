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
    let amneziaConfig: String?

    enum CodingKeys: String, CodingKey {
        case host, port, mode, mtu, dns
        case wrapAPassword = "wrap_a_password"
        case connectionsBalanced = "connections_balanced"
        case connectionsMaximum = "connections_maximum"
        case amneziaConfig = "amnezia_config"
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
        case .invalidLink: return "Неверная ссылка или код активации"
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
        guard !result.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ActivationClientError.invalidResponse
        }
        return result
    }
}

enum DeviceIdentity {
    private static let installationKey = "darktunnel.installation-id"
    private static let publicKeyKey = "darktunnel.activation-public-key"

    static var installationID: String {
        if let existing = UserDefaults.standard.string(forKey: installationKey), !existing.isEmpty { return existing }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: installationKey)
        return value
    }

    static var activationPublicKey: String {
        if let existing = KeychainStore.readString(account: publicKeyKey), !existing.isEmpty { return existing }
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
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
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
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
    private let activationTokenAccount = "activation-token"

    init() { restoreLocalState() }

    /// Handles an app deep link such as darktunnel://activate?d=TOKEN.
    /// The actual parser is shared with manual entry so both paths behave identically.
    func handle(url: URL) {
        activateInput(url.absoluteString)
    }

    /// Accepts a raw activation code, a DarkTunnel deep link, an HTTPS link,
    /// or a Telegram message containing one of those links.
    func activateInput(_ rawInput: String) {
        guard let token = Self.normalizeActivationToken(rawInput) else {
            errorMessage = ActivationClientError.invalidLink.localizedDescription
            AppLog.shared.warning("Activation", "Не удалось распознать ссылку или код активации")
            return
        }
        AppLog.shared.info("Activation", "Получен код активации")
        Task { await activate(token: token) }
    }

    func activate(token: String) async {
        guard !isLoading else { return }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            errorMessage = ActivationClientError.invalidLink.localizedDescription
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            AppLog.shared.info("Activation", "Запрос к backend начат")
            let result = try await DarkTunnelActivationClient.shared.redeem(token: token)
            try persist(result, token: token)
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
        KeychainStore.delete(account: activationTokenAccount)
        isActivated = false
        subscriptionExpiresAt = nil
        serverProfile = nil
        AppLog.shared.info("Activation", "Локальная активация сброшена")
    }

    private func persist(_ result: DarkTunnelActivationResponse, token: String) throws {
        try KeychainStore.writeString(result.refreshToken, account: refreshTokenAccount)
        try KeychainStore.writeString(token, account: activationTokenAccount)
        let profileData = try JSONEncoder().encode(result.server)
        guard let profileString = String(data: profileData, encoding: .utf8) else { throw ActivationClientError.invalidResponse }
        try KeychainStore.writeString(profileString, account: profileAccount)
        UserDefaults.standard.set(result.subscriptionExpiresAt, forKey: expirationKey)
    }

    private func restoreLocalState() {
        subscriptionExpiresAt = UserDefaults.standard.object(forKey: expirationKey) as? Date
        if let profileString = KeychainStore.readString(account: profileAccount),
           let data = profileString.data(using: .utf8) {
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

    private static func normalizeActivationToken(_ rawInput: String) -> String? {
        var value = rawInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'`"))

        guard !value.isEmpty else { return nil }

        // Telegram/browser paste can include a sentence around the actual link.
        if let range = value.range(of: "darktunnel://activate", options: [.caseInsensitive, .diacriticInsensitive]) {
            value = String(value[range.lowerBound...])
                .split(whereSeparator: { $0.isWhitespace || $0.isNewline || $0 == "<" || $0 == ">" })
                .first
                .map(String.init) ?? value
        }

        if let url = URL(string: value) {
            let scheme = url.scheme?.lowercased()
            let host = url.host?.lowercased()
            if scheme == "darktunnel", host == "activate" || host == nil {
                let token = url.queryItemsValue(named: ["d", "token", "code"])
                if let token, !token.isEmpty { return token }
            }
            if scheme == "http" || scheme == "https" {
                if let token = url.queryItemsValue(named: ["d", "token", "code"]), !token.isEmpty {
                    return token
                }
            }
        }

        // Some Telegram clients percent-encode the pasted deep link.
        if let decoded = value.removingPercentEncoding, decoded != value {
            if let token = normalizeActivationToken(decoded), !token.isEmpty { return token }
        }

        // Raw activation codes are valid backend tokens. Do not require URL syntax.
        let compact = value.replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.isEmpty ? nil : compact
    }
}

private extension URL {
    func queryItemsValue(named names: [String]) -> String? {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        for name in names {
            if let value = components.queryItems?.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value,
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

struct BackendActivationView: View {
    @EnvironmentObject private var activation: ActivationStore
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    private let accent = Color(red: 0.43, green: 0.78, blue: 0.68)
    private let panel = Color(red: 0.075, green: 0.09, blue: 0.12)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.015, green: 0.02, blue: 0.028), Color(red: 0.035, green: 0.055, blue: 0.07), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(accent.opacity(0.12))
                .frame(width: 280, height: 280)
                .blur(radius: 80)
                .offset(x: 120, y: -260)
                .allowsHitTesting(false)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 54)

                    ZStack {
                        Circle()
                            .fill(.white.opacity(0.055))
                            .frame(width: 96, height: 96)
                            .overlay(Circle().stroke(.white.opacity(0.10), lineWidth: 1))
                        Circle()
                            .fill(accent.opacity(0.12))
                            .frame(width: 72, height: 72)
                        Image(systemName: "shield.checkered")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(accent)
                    }

                    VStack(spacing: 8) {
                        Text("DarkTunnel")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("Безопасный доступ к вашим VPN-серверам")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 20)

                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("АКТИВАЦИЯ")
                                .font(.caption.weight(.bold))
                                .tracking(1.4)
                                .foregroundStyle(accent)
                            Text("Вставьте код или ссылку из Telegram")
                                .font(.title3.weight(.semibold))
                            Text("Подойдут и darktunnel:// ссылки, и обычный код.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: "key.horizontal")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(accent)

                            TextField("Код или ссылка активации", text: $input)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .focused($inputFocused)
                                .submitLabel(.go)
                                .onSubmit { submit() }

                            if !input.isEmpty {
                                Button { input = "" } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 15)
                        .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .stroke(inputFocused ? accent.opacity(0.65) : .white.opacity(0.10), lineWidth: 1)
                        }

                        HStack(spacing: 10) {
                            Button {
                                input = UIPasteboard.general.string ?? ""
                                inputFocused = true
                            } label: {
                                Label("Вставить", systemImage: "doc.on.clipboard")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.bordered)
                            .tint(.white.opacity(0.82))

                            Button(action: submit) {
                                HStack(spacing: 8) {
                                    if activation.isLoading { ProgressView().tint(.black) }
                                    Image(systemName: activation.isLoading ? "" : "arrow.right")
                                    Text(activation.isLoading ? "Проверяем…" : "Активировать")
                                }
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(activation.isLoading || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .opacity(activation.isLoading || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
                        }

                        if let error = activation.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red.opacity(0.95))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(20)
                    .background(panel.opacity(0.94), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(.white.opacity(0.10), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
                    .padding(.top, 34)

                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                        Text("Токен привязывается к этому устройству")
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 18)

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 20)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { inputFocused = true }
    }

    private func submit() {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !activation.isLoading else { return }
        inputFocused = false
        activation.activateInput(value)
    }
}
