import SwiftUI

@main
struct DarkTunnelApp: App {
    @StateObject private var viewModel = VPNViewModel()
    @AppStorage("hasCompletedActivation") private var hasCompletedActivation = false

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedActivation {
                    HomeView()
                        .environmentObject(viewModel)
                } else {
                    ActivationView()
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}
