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

    var proxyConfigJSON: String? {
        let object: [String: Any] = [
            "vk_link": callLink,
            "peer_address": "\(Self.host):\(Self.port)",
            "use_dtls": true,
            "use_srtp": true,
            "use_wrap": false,
            "use_wrap_a": true,
            "wrap_a_password": serverPassword,
            "device_id": deviceID,
            "num_connections": connections,
            "use_udp": false
        ]

        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }
}
