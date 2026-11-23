// LXUserKeyStore.swift
// User keys for imported LX scripts.
//
// A user script may need a key of its own (the bundled scripts ship
// de-keyed). The key lives ONLY in the Keychain, via the generic
// `KeychainStore` save/load — never in UserDefaults, never in a JSON
// collection, never in a backup export. Account prefix:
// `lx-script-key:<scriptID>:<keyName>`; the script id and the key
// name are identifiers the user chose, not secrets themselves.
// The engine injects the script's keys into its JSContext as
// `globalThis.__haoLxUserKeys` before the script body evaluates
// (custom scripts only — bundled scripts never receive keys).

import Foundation

enum LXUserKeyStore {
    /// Account prefix for script keys in the Keychain.
    static let accountPrefix = "lx-script-key:"

    static func account(scriptID: String, keyName: String) -> String {
        "\(accountPrefix)\(scriptID):\(keyName)"
    }

    @discardableResult
    static func saveKey(_ value: String, scriptID: String, keyName: String) -> Bool {
        KeychainStore.save(value, account: account(scriptID: scriptID, keyName: keyName))
    }

    static func loadKey(scriptID: String, keyName: String) -> String? {
        KeychainStore.load(account: account(scriptID: scriptID, keyName: keyName))
    }

    @discardableResult
    static func deleteKey(scriptID: String, keyName: String) -> Bool {
        KeychainStore.delete(account: account(scriptID: scriptID, keyName: keyName))
    }

    /// All keys stored for one script as a plain dictionary, for
    /// injection into the script's JSContext. Key names come from
    /// the script's own `@`-tags (`@tx_cookie`, `@wy_cookie`,
    /// `@wanfeng_key`, `@yunmge_token`, `@apizero_key` and any
    /// future ones); callers pass the names the script declares.
    static func keysDictionary(scriptID: String, keyNames: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for name in keyNames {
            if let value = loadKey(scriptID: scriptID, keyName: name) {
                out[name] = value
            }
        }
        return out
    }
}
