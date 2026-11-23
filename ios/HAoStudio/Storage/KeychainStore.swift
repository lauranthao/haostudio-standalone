// HAo Studio 2.0 — keychain store (S1).
//
// Credentials live here and nowhere else: never in UserDefaults,
// never in a JSON collection file, never in a backup export, never
// in a log line. Today the only credential is the Emby API key; the
// generic save/load/delete below is the single place a future
// credential goes through.
//
// Synchronous, Security framework only. A failed write returns
// false instead of throwing so the migration caller can roll back.

import Foundation
import Security

enum KeychainStore {
    /// Keychain service for every item this app stores.
    static let service = "com.haostudio.standalone"

    /// Fixed account for the Emby API key. The server address and
    /// user id are not secrets and live with the rest of the Emby
    /// config in hao_emby_config.json; only the key itself is here.
    static let embyApiKeyAccount = "emby-api-key"

    // MARK: - Generic item

    /// Saves a string under an account, updating the item when it
    /// already exists. Returns false when the OS refuses the write.
    static func save(_ value: String, account: String) -> Bool {
        guard let valueData = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var attributes: [String: Any] = query
        attributes[kSecValueData as String] = valueData
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return true
        }
        if addStatus == errSecDuplicateItem {
            let update: [String: Any] = [
                kSecValueData as String: valueData,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            return SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess
        }
        return false
    }

    /// Loads the string stored under an account, or nil when there
    /// is no such item or the OS refuses the read.
    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let valueData = result as? Data,
              let value = String(data: valueData, encoding: .utf8)
        else { return nil }
        return value
    }

    /// Deletes the item under an account. True when the item is gone
    /// afterwards, including when it never existed.
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Emby credential

    /// Saves the Emby API key. The key is the only Emby field that
    /// comes here; baseUrl, userId, library ids and the enabled flag
    /// stay in hao_emby_config.json with the token removed.
    static func saveEmbyApiKey(_ apiKey: String) -> Bool {
        save(apiKey, account: embyApiKeyAccount)
    }

    static func loadEmbyApiKey() -> String? {
        load(account: embyApiKeyAccount)
    }

    static func deleteEmbyApiKey() -> Bool {
        delete(account: embyApiKeyAccount)
    }
}
