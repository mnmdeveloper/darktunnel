import Foundation

struct VKTurnRuntimeConfig {
    let host: String
    let port: Int
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
        !host.isEmpty && port > 0 &&
        !callLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !serverPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !deviceID.isEmpty
    }

    var proxyConfigJSON: String? {
        guard isComplete else { return nil }
        let object: [String: Any] = [
            "vk_link": callLink.trimmingCharacters(in: .whitespacesAndNewlines),
            "peer_addr": "\(host):\(port)",
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
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }
}
