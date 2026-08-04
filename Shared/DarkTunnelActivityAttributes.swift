import ActivityKit
import Foundation

struct DarkTunnelActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var server: String
        var latency: Int
        var transport: String
    }

    var sessionID: String
}
