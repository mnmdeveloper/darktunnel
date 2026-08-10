import ActivityKit
import Foundation

@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activity: Activity<DarkTunnelActivityAttributes>?

    func start(server: String, latency: Int, transport: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = makeState(server: server, latency: latency, transport: transport, status: "Подключено")

        // Reuse the existing activity when possible. This avoids creating a
        // second Dynamic Island after reconnecting or restoring system state.
        if let activity {
            Task { await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(10))) }
            return
        }

        // The app can be relaunched while an activity is still alive. Recover
        // that activity instead of leaving a stale one behind.
        if let existing = Activity<DarkTunnelActivityAttributes>.activities.first {
            activity = existing
            Task { await existing.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(10))) }
            return
        }

        let attributes = DarkTunnelActivityAttributes(sessionID: UUID().uuidString)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(10)),
                pushType: nil
            )
        } catch {
            print("Live Activity start failed: \(error)")
        }
    }

    func update(server: String, latency: Int, transport: String) {
        let state = makeState(server: server, latency: latency, transport: transport, status: "Подключено")
        let target = activity ?? Activity<DarkTunnelActivityAttributes>.activities.first
        guard let target else { return }
        activity = target
        Task {
            await target.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(10)))
        }
    }

    func end() {
        let activities = Activity<DarkTunnelActivityAttributes>.activities
        guard !activities.isEmpty || activity != nil else { return }

        let state = makeState(server: "—", latency: 0, transport: "—", status: "Отключено")
        Task { @MainActor in
            for item in activities {
                await item.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
            }
            self.activity = nil
        }
    }

    private func makeState(server: String, latency: Int, transport: String, status: String) -> DarkTunnelActivityAttributes.ContentState {
        DarkTunnelActivityAttributes.ContentState(
            status: status,
            server: server,
            latency: max(0, latency),
            transport: transport
        )
    }
}
