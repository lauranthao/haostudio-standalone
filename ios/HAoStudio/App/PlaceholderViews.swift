// HAo Studio 2.0 — placeholder tab pages (foundation slice).
//
// Each tab is an explicit placeholder: a title + "占位" label, themed
// background, and NOTHING else. Placeholder pages must not have dead
// buttons, so the only controls in this file are the ones that already
// work: the theme picker + appearance picker on the My (settings) tab,
// which are bound to the ThemeStore and switch the whole app immediately.
//
// Rule 5 (no login): there is no login interface in this app, so no
// login-gated feature appears anywhere here — comments are read-only
// and likes are stored locally only, when those slices land.

import SwiftUI

/// Shared placeholder scaffold: title + explicit "占位" label, nothing else.
private struct PlaceholderPage: View {
    let title: String
    let note: String

    @Environment(\.haoTheme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(theme.textPrimary)
            Text(note)
                .font(.system(size: 14))
                .foregroundStyle(theme.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.scaffoldBackground)
    }
}

struct HomePlaceholderView: View {
    var body: some View {
        PlaceholderPage(title: "首页", note: "占位页 — 内容由后续 slice 填入。")
    }
}

struct MoviesPlaceholderView: View {
    var body: some View {
        PlaceholderPage(title: "影视", note: "占位页 — 内容由后续 slice 填入。")
    }
}

struct LivePlaceholderView: View {
    var body: some View {
        PlaceholderPage(title: "直播", note: "占位页 — 内容由后续 slice 填入。")
    }
}

struct MusicPlaceholderView: View {
    var body: some View {
        PlaceholderPage(title: "音乐", note: "占位页 — 内容由后续 slice 填入。")
    }
}

/// My tab = the settings page. The theme + appearance pickers are real
/// and functional in the foundation slice (they drive the ThemeStore);
/// everything else on this page is a labelled placeholder.
struct MyPlaceholderView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.haoTheme) private var theme

    /// S1: shown when the 1.1.6 snapshot migration never completed,
    /// so the user knows their old data was not found and a backup
    /// file can still be imported. Text only: the backup import
    /// itself lands in S6, so there is no button that leads nowhere.
    /// The dismiss button is real: it hides this section for good.
    @State private var showMigrationNotice = MigrationStore.migrationNoticeNeeded()

    /// Bundle version (Info.plist CFBundleShortVersionString / build).
    /// version.json is aligned with the bundle in S0 (1.0.3 / build 4,
    /// minOs 17.0); the 2.0.0 label is NOT written until RC (plan §十).
    /// The number shown here is the app's own bundle version, not the
    /// updater's.
    private var bundleVersion: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (build \(build))"
    }

    var body: some View {
        // NavigationStack: the deployment target is iOS 17.0 (S0), so
        // the iOS 16+ navigation API is available. (The foundation
        // used NavigationView while the target was iOS 15.)
        NavigationStack {
            List {
                if showMigrationNotice {
                    Section("旧版数据") {
                        Text("未找到旧版数据，可从备份文件导入。")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.textSecondary)
                        Button("不再提示") {
                            MigrationStore.dismissMigrationNotice()
                            showMigrationNotice = false
                        }
                        .font(.system(size: 14))
                    }
                }
                Section("主题") {
                    Picker("主题", selection: $themeStore.themeID) {
                        ForEach(HaoThemeID.allCases) { id in
                            Text(id.displayName).tag(id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("外观") {
                    Picker("外观", selection: $themeStore.appearance) {
                        ForEach(HaoAppearance.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(bundleVersion)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Text("设置页其余内容为占位，由后续 slice 填入。")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.textMuted)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.scaffoldBackground)
            .navigationTitle("我的")
        }
    }
}
