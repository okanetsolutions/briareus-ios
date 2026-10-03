import Foundation
import Security

enum Keychain {
    /// The device token, one per server origin.
    static let device = "com.okanetsolutions.briareus.device"
    /// The OpenAI API key the voice mode connects with, under the account "openai".
    static let voice = "com.okanetsolutions.briareus.voice"

    private static func query(_ origin: String, _ service: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: origin,
         kSecAttrSynchronizable as String: false]
        // A Mac keeps the token in the keychain the phone uses, where device-only protection holds, not in the login keychain.
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
    /// A car is driven with the phone locked in a pocket, so the token is readable from the first unlock after
    /// a restart onwards. It still never leaves the device. A Mac has no car and keeps it to an unlocked session.
    private static var accessible: CFString {
        #if os(iOS)
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #else
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #endif
    }
    static func read(_ origin: String, service: String = device) throws -> String? {
        var q = query(origin, service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { throw failure(status) }
        // A token saved before the app ran in a car is moved to the protection the car needs.
        SecItemUpdate(query(origin, service) as CFDictionary, [kSecAttrAccessible as String: accessible] as CFDictionary)
        return token
    }
    static func save(_ token: String, origin: String, service: String = device) throws {
        let q = query(origin, service)
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: accessible]
        let status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(q.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    static func remove(_ origin: String, service: String = device) throws {
        let status = SecItemDelete(query(origin, service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    private static func failure(_ status: OSStatus) -> NSError {
        NSError(domain: "Keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey:
            "Could not access the device token in Keychain (\(status)). Unlock the device and try again."])
    }
}
