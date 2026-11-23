// HAo Studio 2.0 — source management pages (S5-B leg).
//
// Three pages, one per source family. Each page reads/writes
// the EXISTING collections — no new store is invented here:
// - LX scripts: LXScriptStore (`hao_lx_*` collections) +
//   LxBundledScript.allIDs + LXScriptFileStore (files).
// - CMS sources: VideoSourceStore (`hao_sa_video`).
// - Live platforms: LiveSourcePrefs (`hao_live_sources`) —
//   there was no Swift accessor in the baseline, so the
//   read/write lives on LiveSourcePrefs in SettingsLogic.swift,
//   over the existing Flutter-shaped collection.
// Every "keep at least one" list greys out the last enabled
// switch instead of letting the write happen and fail.

import SwiftUI
import CryptoKit

// MARK: - 音源管理

/// LX script list: bundled scripts (minus user-deleted) +
/// user-imported scripts, in saved order. Toggle = enable /
/// disable. Custom scripts can be deleted; bundled scripts can
/// be deleted (into `hao_lx_deleted_bundled`, never re-seeded).
/// "恢复默认" restores the shipped 13 bundled scripts, all
/// enabled, in seed order; user-imported scripts are kept
/// (they are user data, not defaults).
///
/// URL add stores ONLY the URL string: the record is saved to
/// `hao_lx_custom` with an empty file name, so the engine
/// ignores it until a future import step downloads the code.
/// Nothing is downloaded or executed here — execution belongs
/// to the resolver, not to settings.
struct LXSourceManagementView: View {
    @Environment(\.haoTheme) private var theme

    @State private var rows: [LXSourceRow] = []
    @State private var enabledIDs: Set<String> = []
    @State private var urlDraft = ""
    @State private var showingRestoreAlert = false
    @State private var showingInvalidURLAlert = false

    private let scriptStore = LXScriptStore()
    private let fileStore = LXScriptFileStore()

    var body: some View {
        List {
            Section {
                if rows.isEmpty {
                    Text("没有可用的音源脚本。")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.textMuted)
                } else {
                    ForEach(rows) { row in
                        lxRow(row)
                    }
                }
            } footer: {
                Text("捆绑脚本来自应用内置清单；自定义脚本由你导入。关掉的脚本不会参与搜歌和播放。")
            }
            Section("添加自定义脚本") {
                TextField("脚本地址（https://…/xxx.js）", text: $urlDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("添加") {
                    addURLScript()
                }
                .font(.system(size: 15))
                Text("只保存地址，不下载、不执行。导入下载由后续步骤完成。")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textMuted)
            }
            Section {
                Button("恢复默认") {
                    showingRestoreAlert = true
                }
                .font(.system(size: 15))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.scaffoldBackground)
        .navigationTitle("音源管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            reload()
        }
        .alert("恢复默认音源", isPresented: $showingRestoreAlert) {
            Button("取消", role: .cancel) {
            }
            Button("恢复", role: .destructive) {
                restoreDefaults()
            }
        } message: {
            Text("将恢复全部 13 个内置脚本并全部启用，顺序回到默认。你导入的自定义脚本会保留。")
        }
        .alert("地址无效", isPresented: $showingInvalidURLAlert) {
            Button("好", role: .cancel) {
            }
        } message: {
            Text("请输入一个有效的 http(s) 脚本地址。")
        }
    }

    private func lxRow(_ row: LXSourceRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textPrimary)
                if row.isCustom {
                    Text("自定义")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textMuted)
                }
            }
            Spacer()
            Toggle(
                "启用",
                isOn: Binding<Bool>(
                    get: { enabledIDs.contains(row.id) },
                    set: { newValue in
                        scriptStore.setEnabled(row.id, enabled: newValue)
                        reload()
                    }
                )
            )
            .labelsHidden()
            Button(role: .destructive) {
                deleteScript(row)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
        }
    }

    private func reload() {
        rows = LXSourceListOrdering.orderedRows(
            bundledIDs: LxBundledScript.allIDs,
            customRecords: scriptStore.customScripts(),
            deletedBundledIDs: scriptStore.deletedBundledIds(),
            savedOrder: scriptStore.scriptOrder()
        )
        enabledIDs = Set(rows.map { $0.id }.filter { scriptStore.isEnabled($0) })
    }

    private func deleteScript(_ row: LXSourceRow) {
        if row.isCustom {
            let record = scriptStore.customScripts().first(where: { $0.id == row.id })
            scriptStore.removeCustomScript(row.id)
            if let fileName = record?.fileName, !fileName.isEmpty {
                _ = fileStore.deleteFile(named: fileName)
            }
        } else {
            scriptStore.markBundledDeleted(row.id)
            _ = fileStore.delete(id: row.id)
        }
        reload()
    }

    /// Restore the shipped set: clear disabled / explicit /
    /// deleted-bundled / order collections (the contract keys on
    /// LXScriptStore). Custom scripts are untouched.
    private func restoreDefaults() {
        LocalStore.saveCollection(named: LXScriptStore.disabledKey, value: [String]())
        LocalStore.saveCollection(named: LXScriptStore.explicitEnabledKey, value: [String]())
        LocalStore.saveCollection(named: LXScriptStore.deletedBundledKey, value: [String]())
        LocalStore.saveCollection(named: LXScriptStore.orderKey, value: [String]())
        reload()
    }

    private func addURLScript() {
        let trimmed = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else {
            showingInvalidURLAlert = true
            return
        }
        let digest = Insecure.SHA1.hash(data: Data(trimmed.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let record = LxCustomScriptRecord(
            id: "custom:url:\(hex.prefix(12))",
            name: url.host ?? trimmed,
            url: trimmed,
            fileName: "",
            addedAt: Date()
        )
        scriptStore.saveCustomScript(record)
        urlDraft = ""
        reload()
    }
}

// MARK: - 影视源管理

/// CMS source list from VideoSourceStore. Toggle = enable /
/// disable (the last enabled source cannot be switched off);
/// drag = reorder (sort is renumbered so the stored order is
/// the effective order); 恢复默认 = shipped 18 sources.
struct CmsSourceManagementView: View {
    @Environment(\.haoTheme) private var theme

    @State private var sources: [VideoSource] = []
    @State private var showingRestoreAlert = false

    var body: some View {
        List {
            Section {
                if sources.isEmpty {
                    Text("没有可用的影视源。")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.textMuted)
                } else {
                    ForEach(sources) { source in
                        cmsRow(source)
                    }
                    .onMove(perform: moveSources)
                }
            } footer: {
                Text("至少保留一个启用源；拖动可调整顺序，改完立即生效。")
            }
            Section {
                Button("恢复默认") {
                    showingRestoreAlert = true
                }
                .font(.system(size: 15))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.scaffoldBackground)
        .navigationTitle("影视源管理")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
        .onAppear {
            reload()
        }
        .alert("恢复默认影视源", isPresented: $showingRestoreAlert) {
            Button("取消", role: .cancel) {
            }
            Button("恢复", role: .destructive) {
                VideoSourceStore.resetToDefaults()
                reload()
            }
        } message: {
            Text("将恢复 18 个内置影视源及默认开关状态。")
        }
    }

    private func cmsRow(_ source: VideoSource) -> some View {
        let isLastEnabled = source.enabled && sources.filter { $0.enabled }.count == 1
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textPrimary)
                Text(source.apiUrl)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            Toggle(
                "启用",
                isOn: Binding<Bool>(
                    get: { source.enabled },
                    set: { newValue in
                        setEnabled(source, enabled: newValue)
                    }
                )
            )
            .labelsHidden()
            .disabled(isLastEnabled)
        }
    }

    private func reload() {
        sources = VideoSourceStore.load()
    }

    private func save(_ updated: [VideoSource]) {
        sources = updated
        VideoSourceStore.save(updated)
    }

    private func setEnabled(_ source: VideoSource, enabled: Bool) {
        if !enabled && !SourceKeepOneGuard.canDisable(
            enabledCount: sources.filter { $0.enabled }.count
        ) {
            return
        }
        let updated = sources.map { item in
            if item.id == source.id {
                return VideoSource(
                    id: item.id, name: item.name, apiUrl: item.apiUrl,
                    kind: item.kind, enabled: enabled, sort: item.sort
                )
            }
            return item
        }
        save(updated)
    }

    private func moveSources(from source: IndexSet, to destination: Int) {
        var updated = sources
        updated.move(fromOffsets: source, toOffset: destination)
        updated = updated.enumerated().map { index, item in
            VideoSource(
                id: item.id, name: item.name, apiUrl: item.apiUrl,
                kind: item.kind, enabled: item.enabled, sort: (index + 1) * 10
            )
        }
        save(updated)
    }
}

// MARK: - 直播源管理

/// The 5 live platforms, backed by the `hao_live_sources`
/// collection (LiveSourcePrefs — Flutter LiveSourcesStore
/// shape). At least one platform stays on; the last enabled
/// switch is greyed out.
struct LiveSourceManagementView: View {
    @Environment(\.haoTheme) private var theme

    @State private var enabledIDs: [String] = LiveSourcePrefs.allIDs

    var body: some View {
        List {
            Section {
                ForEach(LivePlatform.allCases) { platform in
                    liveRow(platform)
                }
            } footer: {
                Text("至少保留一个开启的平台；关掉的平台不会在直播首页出现。")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.scaffoldBackground)
        .navigationTitle("直播源管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            enabledIDs = LiveSourcePrefs.load()
        }
    }

    private func liveRow(_ platform: LivePlatform) -> some View {
        let siteId = platform.flutterSiteId
        let isEnabled = enabledIDs.contains(siteId)
        let isLastEnabled = isEnabled && enabledIDs.count == 1
        return HStack {
            Text(platform.displayName)
                .font(.system(size: 15))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Toggle(
                "启用",
                isOn: Binding<Bool>(
                    get: { isEnabled },
                    set: { newValue in
                        setEnabled(siteId, value: newValue)
                    }
                )
            )
            .labelsHidden()
            .disabled(isLastEnabled)
        }
    }

    private func setEnabled(_ siteId: String, value: Bool) {
        guard let next = LiveSourcePrefs.settingEnabled(
            enabledIDs, siteId: siteId, value: value
        ) else {
            return
        }
        enabledIDs = next
        LiveSourcePrefs.save(next)
    }
}
