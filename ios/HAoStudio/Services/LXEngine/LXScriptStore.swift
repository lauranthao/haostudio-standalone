// LXScriptStore.swift
// LX script registry: enabled/disabled, order, custom scripts and
// deleted-bundled ids.
//
// Persistence keys are the S1 storage-mapping contract
// (`docs/storage-mapping.md`) and are never renamed:
//   - `hao_lx_disabled` — ids the user switched off.
//   - `hao_lx_explicit_enabled` — ids the user switched on explicitly
//     (a script is enabled by default unless disabled; an explicitly
//     enabled id stays enabled even when its default flips).
//   - `hao_lx_custom` — user-imported script records.
//   - `hao_lx_deleted_bundled` — bundled ids the user deleted
//     (never re-seeded).
//   - `hao_lx_order` — user-arranged script order (ids).
//
// Each collection is one JSON file `Documents/<key>.json`, written
// atomically, loaded fail-soft (corrupt file -> default), mirroring
// `LocalStore`'s semantics. `LocalStore` itself has no injectable
// directory (S1 contract), so this store takes a `documentsDirectory`
// parameter for tests instead of going through `LocalStore` directly.
// Production callers pass nothing and get the real Documents dir.

import Foundation

final class LXScriptStore {
    // MARK: - Collection keys (contract — never rename)

    static let disabledKey = "hao_lx_disabled"
    static let explicitEnabledKey = "hao_lx_explicit_enabled"
    static let customKey = "hao_lx_custom"
    static let deletedBundledKey = "hao_lx_deleted_bundled"
    static let orderKey = "hao_lx_order"

    private let documentsDirectory: URL

    init(documentsDirectory: URL? = nil) {
        self.documentsDirectory = documentsDirectory ?? LocalStore.documentsDirectory()
    }

    // MARK: - Low-level JSON file IO (LocalStore semantics)

    private func load<T: Decodable>(_ type: T.Type, named name: String, default defaultValue: T) -> T {
        let url = documentsDirectory.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(T.self, from: data)
        else { return defaultValue }
        return decoded
    }

    private func save<T: Encodable>(_ value: T, named name: String) {
        let url = documentsDirectory.appendingPathComponent("\(name).json")
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    // MARK: - Enabled / disabled

    func isEnabled(_ id: String) -> Bool {
        let disabled: [String] = load([String].self, named: Self.disabledKey, default: [])
        return !disabled.contains(id)
    }

    func setEnabled(_ id: String, enabled: Bool) {
        var disabled: [String] = load([String].self, named: Self.disabledKey, default: [])
        var explicit: [String] = load([String].self, named: Self.explicitEnabledKey, default: [])
        if enabled {
            disabled.removeAll { $0 == id }
            if !explicit.contains(id) { explicit.append(id) }
        } else {
            if !disabled.contains(id) { disabled.append(id) }
            explicit.removeAll { $0 == id }
        }
        save(disabled, named: Self.disabledKey)
        save(explicit, named: Self.explicitEnabledKey)
    }

    // MARK: - Custom scripts

    func customScripts() -> [LxCustomScriptRecord] {
        load([LxCustomScriptRecord].self, named: Self.customKey, default: [])
    }

    func saveCustomScript(_ record: LxCustomScriptRecord) {
        var list = customScripts()
        list.removeAll { $0.id == record.id }
        list.append(record)
        save(list, named: Self.customKey)
    }

    func removeCustomScript(_ id: String) {
        var list = customScripts()
        list.removeAll { $0.id == id }
        save(list, named: Self.customKey)
    }

    // MARK: - Deleted bundled ids

    func deletedBundledIds() -> [String] {
        load([String].self, named: Self.deletedBundledKey, default: [])
    }

    func markBundledDeleted(_ id: String) {
        var list = deletedBundledIds()
        if !list.contains(id) { list.append(id) }
        save(list, named: Self.deletedBundledKey)
    }

    func unmarkBundledDeleted(_ id: String) {
        var list = deletedBundledIds()
        list.removeAll { $0 == id }
        save(list, named: Self.deletedBundledKey)
    }

    // MARK: - Order

    func scriptOrder() -> [String] {
        load([String].self, named: Self.orderKey, default: [])
    }

    func saveScriptOrder(_ ids: [String]) {
        save(ids, named: Self.orderKey)
    }
}
