import ActivityKit
import Foundation

@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activity: Activity<DarkTunnelActivityAttributes>?

    func start(server: String, latency: Int, transport: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = DarkTunnelActivityAttributes(sessionID: UUID().uuidString)
        let state = DarkTunnelActivityAttributes.ContentState(
            status: "Подключено",
            server: server,
            latency: latency,
            transport: transport
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            print("Live Activity start failed: \(error)")
        }
    }

    func update(server: String, latency: Int, transport: String) {
        guard let activity else { return }
        let state = DarkTunnelActivityAttributes.ContentState(
            status: "Подключено",
            server: server,
            latency: latency,
            transport: transport
        )
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    func end() {
        guard let activity else { return }
        let state = DarkTunnelActivityAttributes.ContentState(
            status: "Отключено",
            server: "—",
            latency: 0,
            transport: "—"
        )
        Task {
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
            self.activity = nil
        }
    }
}
