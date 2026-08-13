import SwiftUI

@main
struct DarkTunnelApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @StateObject private var viewModel = VPNViewModel()
    @StateObject private var activation = ActivationStore.shared
    @StateObject private var subscription = SubscriptionGuard.shared
    @StateObject private var subscriptionManagement = SubscriptionManagementStore.shared
    @StateObject private var appUpdates = AppUpdateService.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if activation.isActivated && subscription.isAuthorized {
                    HomeView().environmentObject(viewModel)
                } else {
                    BackendActivationView().environmentObject(activation)
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                subscription.start()
                Task { await appUpdates.check() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task {
                        await subscription.checkNow()
                        await appUpdates.check()
                    }
                }
            }
            .alert("Доступно обновление", isPresented: Binding(
                get: { appUpdates.update != nil },
                set: { if !$0 { appUpdates.update = nil } }
            ), presenting: appUpdates.update) { update in
                Button("Обновить") {
                    openURL(update.storeURL)
                    appUpdates.update = nil
                }
                Button("Позже", role: .cancel) {
                    appUpdates.update = nil
                }
            } message: { update in
                Text("DarkTunnel \(update.version) уже доступен в App Store. Обновление содержит исправления и улучшения.")
            }
            .onOpenURL { url in
                if url.scheme?.lowercased() == "darktunnel", url.host?.lowercased() == "activate" {
                    activation.handle(url: url)
                    Task { await subscription.checkNow() }
                } else if url.scheme?.lowercased() == "darktunnel", url.host?.lowercased() == "subscription" {
                    subscriptionManagement.open(url: url)
                } else {
                    viewModel.handleDeepLink(url)
                }
            }
            .sheet(isPresented: $subscriptionManagement.isPresented) {
                SubscriptionManagementView()
            }
        }
    }
}
