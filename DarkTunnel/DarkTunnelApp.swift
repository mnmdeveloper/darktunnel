import SwiftUI

@main
struct DarkTunnelApp: App {
    @StateObject private var viewModel = VPNViewModel()
    @StateObject private var activation = ActivationStore.shared
    @StateObject private var subscription = SubscriptionGuard.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if activation.isActivated && subscription.isAuthorized {
                    HomeView()
                        .environmentObject(viewModel)
                } else {
                    BackendActivationView()
                        .environmentObject(activation)
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                subscription.start()
            }
            .onOpenURL { url in
                if url.scheme?.lowercased() == "darktunnel",
                   url.host?.lowercased() == "activate" {
                    activation.handle(url: url)
                    Task { await subscription.checkNow() }
                } else {
                    viewModel.handleDeepLink(url)
                }
            }
        }
    }
}
