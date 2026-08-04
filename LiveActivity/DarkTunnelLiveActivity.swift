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
    private let blueGray = Color(red: 0.37, green: 0.47, blue: 0.58)
    private let disconnectURL = URL(string: "darktunnel://disconnect")!

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DarkTunnelActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(blueGray.opacity(0.18))
                        Image(systemName: "shield.lefthalf.filled")
                            .foregroundStyle(blueGray)
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.status).font(.headline)
                        Text("\(context.state.server) · \(context.state.transport)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("\(context.state.latency) мс")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(blueGray.opacity(0.16), in: Capsule())
                }

                Link(destination: disconnectURL) {
                    Label("Отключить VPN", systemImage: "power")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding()
            .activityBackgroundTint(Color(red: 0.05, green: 0.06, blue: 0.08))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "shield.fill")
                        .foregroundStyle(blueGray)
                        .font(.title3)
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.server).font(.headline)
                        Text(context.state.transport)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(context.state.latency)")
                            .font(.headline.monospacedDigit())
                        Text("мс").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    Link(destination: disconnectURL) {
                        Label("Отключить", systemImage: "power")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            } compactLeading: {
                Image(systemName: "shield.fill").foregroundStyle(blueGray)
            } compactTrailing: {
                Text("\(context.state.latency)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
            } minimal: {
                Image(systemName: "shield.fill").foregroundStyle(blueGray)
            }
            .keylineTint(blueGray)
        }
    }
}
