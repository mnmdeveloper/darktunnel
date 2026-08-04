import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DarkTunnelLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        DarkTunnelLiveActivity()
    }
}

struct DarkTunnelLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DarkTunnelActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.title2)
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.state.status).font(.headline)
                    Text("\(context.state.server) · \(context.state.transport)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(context.state.latency) мс")
                    .font(.caption.monospacedDigit())
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.82))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "shield.lefthalf.filled").foregroundStyle(.cyan)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.server).font(.headline)
                        Text(context.state.transport).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.latency) мс").font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Label(context.state.status, systemImage: "lock.fill")
                        .font(.caption.weight(.semibold))
                }
            } compactLeading: {
                Image(systemName: "shield.fill").foregroundStyle(.cyan)
            } compactTrailing: {
                Text("\(context.state.latency)").font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "shield.fill").foregroundStyle(.cyan)
            }
            .keylineTint(.cyan)
        }
    }
}
