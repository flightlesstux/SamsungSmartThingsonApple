import Foundation
import Security

struct TVDevice: Codable, Identifiable, Hashable {
    /// Stable identity: the TV's Wi-Fi MAC (falls back to its DUID), so a DHCP address change keeps tokens.
    let id: String
    var name: String
    var model: String
    var ip: String
    var mac: String

    var shortName: String { name.count <= 10 ? name : String(name.prefix(9)) + "…" }

    /// Samsung smart monitors use LS-prefixed model codes.
    var symbol: String { model.hasPrefix("LS") ? "display" : "tv" }
}

enum Settings {
    private static let devicesKey = "tv.devices"

    static var savedTVs: [TVDevice] {
        get {
            guard let data = UserDefaults.standard.data(forKey: devicesKey) else { return [] }
            return (try? JSONDecoder().decode([TVDevice].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: devicesKey) }
    }

    static func tvToken(_ id: String) -> String? {
        UserDefaults.standard.string(forKey: "token.\(id)")
    }

    static func setTVToken(_ token: String?, for id: String) {
        UserDefaults.standard.set(token, forKey: "token.\(id)")
    }

    static var smartThingsToken: String? {
        get { Keychain.get("smartthings-pat") }
        set { Keychain.set(newValue, for: "smartthings-pat") }
    }
}

enum Keychain {
    private static let service = "com.flightlesstux.SmartPanel"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
