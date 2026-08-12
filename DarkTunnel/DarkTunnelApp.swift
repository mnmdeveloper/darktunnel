import SwiftUI

@main
struct DarkTunnelApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = VPNViewModel()
    @StateObject private var activation = ActivationStore.shared
    @StateObject private var subscription = SubscriptionGuard.shared
    @StateObject private var subscriptionManagement = SubscriptionManagementStore.shared

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
            .onAppear { subscription.start() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await subscription.checkNow() } }
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
