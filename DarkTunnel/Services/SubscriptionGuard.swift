import Foundation
import SwiftUI

@MainActor
final class SubscriptionGuard: ObservableObject {
    static let shared = SubscriptionGuard()

    @Published private(set) var isAuthorized = ActivationStore.shared.isActivated
    @Published private(set) var isChecking = false

    private var task: Task<Void, Never>?

    private init() {}

    deinit { task?.cancel() }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.checkNow()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.checkNow()
            }
        }
    }

    func checkNow() async {
        guard ActivationStore.shared.isActivated,
              let activationToken = KeychainStore.readString(account: "activation-token"),
              !activationToken.isEmpty else {
            isAuthorized = false
            return
        }

        isChecking = true
        defer { isChecking = false }

        guard let encodedInstallation = DeviceIdentity.installationID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.31-77-148-80.sslip.io/v1/subscription/status?installation_id=\(encodedInstallation)") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(activationToken, forHTTPHeaderField: "X-Activation-Token")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if (200..<300).contains(http.statusCode) {
                isAuthorized = true
            } else if http.statusCode == 401 || http.statusCode == 403 {
                isAuthorized = false
                VPNController.shared.disconnect()
                LiveActivityController.shared.end()
            }
        } catch {
            // A temporary backend/network outage must not destroy a valid local
            // session. Only an authoritative 401/403 revokes access in-app.
            AppLog.shared.warning("Subscription", "Проверка подписки недоступна: \(error.localizedDescription)")
        }
    }
}
