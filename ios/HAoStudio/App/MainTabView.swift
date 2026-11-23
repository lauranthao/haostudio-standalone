// HAo Studio 2.0 — app shell: 5-tab navigation.
//
// Tabs: Home / Music / Movies / Live / My（首页/音乐/影视/直播/我的，
// chen 2026-11-23 定，按任务书顺序；脚手架原先是 Home/Movies/Live/
// Music/My，已在 S0 按任务书改过来）. My IS the settings page —
// there is no separate settings destination.
//
// The floating stack (mini player above the glass tab bar) lives in a
// bottom safe-area inset, so tab content is inset above it automatically:
// the bar and the mini player can never cover content, and they can
// never cover each other — the mini player is simply the first row of
// the same stack. No manual bottom padding is computed anywhere.
//
// No TabView is used: the built-in tab bar cannot be replaced by a
// floating capsule. The selected tab is plain @State; switching is a
// content swap (the player slice keeps this — the coordinator, not the
// tab view, owns what keeps playing across tabs).

import SwiftUI

enum HaoTab: String, CaseIterable, Identifiable {
    case home
    case music
    case movies
    case live
    case my

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "首页"
        case .music: return "音乐"
        case .movies: return "影视"
        case .live: return "直播"
        case .my: return "我的"
        }
    }

    /// SF Symbols icon (Apple-native; no custom tab art in the foundation).
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .music: return "music.note"
        case .movies: return "film.fill"
        case .live: return "antenna.radiowaves.left.and.right"
        case .my: return "person.fill"
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedTab: HaoTab = .home
    @State private var showingFullPlayer = false

    private var tabBarItems: [GlassTabBarItem] {
        HaoTab.allCases.map { GlassTabBarItem(tab: $0, title: $0.title, icon: $0.icon) }
    }

    var body: some View {
        // The palette is resolved from the EFFECTIVE scheme and pushed
        // into the environment here, so a theme/mode switch re-renders
        // every tab immediately with no restart.
        let palette = themeStore.palette(for: colorScheme)
        ZStack {
            palette.scaffoldBackground.ignoresSafeArea()
            tabContent
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: HaoLayout.floatingStackSpacing) {
                MiniPlayerBar(onTapFullPlayer: { showingFullPlayer = true })
                GlassTabBar(items: tabBarItems, selection: $selectedTab)
                    .padding(.horizontal, HaoLayout.tabBarHorizontalMargin)
            }
            .padding(.bottom, HaoLayout.tabBarBottomMargin)
        }
        .fullScreenCover(isPresented: $showingFullPlayer) {
            FullPlayerPlaceholderView()
        }
        .environment(\.haoTheme, palette)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .home: HomePlaceholderView()
        case .music: MusicPlaceholderView()
        case .movies: MoviesPlaceholderView()
        case .live: LivePlaceholderView()
        case .my: MyPlaceholderView()
        }
    }
}
