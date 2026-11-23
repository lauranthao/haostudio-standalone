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
        PlaceholderPage(title: "首页", note: "首页正在准备中。")
    }
}

/// Music tab is real since S2-C (MusicHomeView); its placeholder was
/// removed with the replacement, not left as dead code.
