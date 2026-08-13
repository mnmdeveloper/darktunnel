import ActivityKit
import Foundation

@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activity: Activity<DarkTunnelActivityAttributes>?

    private let staleInterval: TimeInterval = 60 * 60

    func start(server: String, latency: Int, transport: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = makeState(server: server, latency: latency, transport: transport, status: "Подключено")

        if let activity {
            Task { await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleInterval))) }
            return
        }

        if let existing = Activity<DarkTunnelActivityAttributes>.activities.first {
            activity = existing
            Task { await existing.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleInterval))) }
            return
        }

        let attributes = DarkTunnelActivityAttributes(sessionID: UUID().uuidString)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleInterval)),
                pushType: nil
            )
        } catch {
            print("Live Activity start failed: \(error)
")
        }
    }

    func update(server: String, latency: Int, transport: String) {
        let state = makeState(server: server, latency: latency, transport: transport, status: "Подключено")
        let target = activity ?? Activity<DarkTunnelActivityAttributes>.activities.first
        guard let target else { return }
        activity = target
        Task {
            await target.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleInterval)))
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
