import Foundation

struct VKTurnRuntimeConfig {
    static let host = "31.77.148.80"
    static let port = 56000

    let callLink: String
    let serverPassword: String
    let deviceID: String
    let connections: Int

    static func persistentDeviceID() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "vkTurnDeviceID"), !existing.isEmpty {
            return existing
        }

        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: "vkTurnDeviceID")
        return value
    }

    var isComplete: Bool {
        !callLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !serverPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !deviceID.isEmpty
    }

    var proxyConfigJSON: String? {
        guard isComplete else { return nil }

        // Exact ProxyConfig coding keys from anton48/vk-turn-proxy-ios.
        // WRAP-A is its own mode and must not be combined with DTLS/SRTP flags.
        let object: [String: Any] = [
            "vk_link": callLink.trimmingCharacters(in: .whitespacesAndNewlines),
            "peer_addr": "\(Self.host):\(Self.port)",
            "use_dtls": false,
            "use_udp": false,
            "use_wrap": false,
            "use_srtp": false,
            "use_wrap_a": true,
            "wrap_a_password": serverPassword.trimmingCharacters(in: .whitespacesAndNewlines),
            "device_id": deviceID,
            "num_conns": max(1, min(connections, 50))
        ]

        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }
}
