// The device token lives in the keychain, scoped by canonical server origin; only the origin is saved in the defaults.
import Foundation
import Security

enum Keychain {
    private static func query(_ origin: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.okanetsolutions.briareus.client",
         kSecAttrAccount as String: origin,
         kSecAttrSynchronizable as String: false,
         // This Mac only: the data protection keychain, where device-only protection holds, not the login keychain.
         kSecUseDataProtectionKeychain as String: true]
    }
    static func read(_ origin: String) throws -> String? {
        var q = query(origin)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else { throw failure(status) }
        return token
    }
    static func save(_ token: String, origin: String) throws {
        let q = query(origin)
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(q.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    @discardableResult
    static func remove(_ origin: String) -> Bool {
        let status = SecItemDelete(query(origin) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    static let failureText = "Could not access the device token in the keychain. Unlock this Mac and try again."
    private static func failure(_ status: OSStatus) -> NSError {
        NSError(domain: "Keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(failureText) (\(status))"])
    }
}
