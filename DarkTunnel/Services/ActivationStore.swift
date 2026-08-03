import Foundation

struct LocalActivation: Codable, Equatable {
    let plan: String
    let expiresAt: Date
    let serverHost: String

    var isActive: Bool { expiresAt > Date() }
}

@MainActor
final class ActivationStore: ObservableObject {
    @Published private(set) var activation: LocalActivation

    init() {
        activation = LocalActivation(
            plan: "DarkTunnel Test",
            expiresAt: Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date(),
            serverHost: "31.77.148.80"
        )
    }

    var isActive: Bool { activation.isActive }
}
