import SwiftUI

@main
struct DarkTunnelApp: App {
    @StateObject private var viewModel = VPNViewModel()
    @StateObject private var activation = ActivationStore.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if activation.isActivated {
                    HomeView()
                        .environmentObject(viewModel)
                } else {
                    BackendActivationView()
                        .environmentObject(activation)
                }
            }
            .preferredColorScheme(.dark)
            .onOpenURL { url in
                if url.scheme?.lowercased() == "darktunnel",
                   url.host?.lowercased() == "activate" {
                    activation.handle(url: url)
                } else {
                    viewModel.handleDeepLink(url)
                }
            }
        }
    }
}
