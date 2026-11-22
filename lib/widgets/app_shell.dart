// App shell — 4 bottom tabs: 影视 / 直播 / 音乐 / 设置. No home page.
//
// Apple-native tab bar (build 29 adoption, chen 2026-11-22: “都要原生
// 效果”). The Kumone floating capsule is GONE — its rules are void:
// no icon-only bar, no solid tab-pill, no settle spring (322.273 /
// 29.441). The pill itself is gone, but the bar drag is NOT void:
// chen 2026-11-23 (“底栏菜单都不可以拖动了”) — dragging across the
// bar switches tabs, restored by [TabBarDragLayer] below (the native
// UITabBar is tap-only, so the drag lives in a transparent overlay).
// The bar is now glassy_ui_ios `GlassTabBar`: the real iOS tab bar
// (UITabBar) on iOS — labels under every icon, transparent tint pill
// on the selected tab, .bouncy animation — and the
// `_AppleTabBarFallback` below on other platforms / in tests, which
// renders the same layout in Flutter (labels, tint pill, bouncy
// slide, tap only). The fallback is also what the Linux test host
// sees: glassy returns `fallback` off-iOS.
//
// Geometry: the native bar is 64pt + the home-indicator safe area
// and sits on the bottom edge (not floating), so page content gets
// 64 + 12 gap + safe area of bottom padding. The mini player floats
// above the bar on the music home (its own 8pt margin); on music
// sub-pages the overlay sits at the safe area (no tab bar there).
//
// Swipe guard (fix 7): on every live page a horizontal swipe must never
// change the bottom tab. Implemented by disabling PageView swipe while the
// current tab IS live; the tab bar itself stays visible and tappable.
// Swiping INTO live from another tab still works, because the guard reads
// the CURRENT page. The live room is a pushed route (no tab bar at all
// while open — fix 17.3), separate from this guard.

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:glassy_ui_ios/glassy_ui_ios.dart' as glassy;

import '../core/theme/hao_themes.dart';
import '../core/theme/haptics.dart';
import 'hao_scroll_to_top.dart';

import '../domains/live/presentation/live_tab_page.dart';
import '../features/music/music_tab_page.dart';
import '../features/settings/settings_tab_page.dart';
import '../features/video/video_tab_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  /// Tab PageView physics (N-20): page snapping + iOS-style end
  /// bounce. Plain `PageScrollPhysics` stops dead at the first/last
  /// page; a `BouncingScrollPhysics` parent lets the edge overscroll
  /// with friction and spring back, like `UIPageViewController`. The
  /// parent is [_EdgeBouncingScrollPhysics], not stock
  /// `BouncingScrollPhysics`: stock doubles `minFlingVelocity`, which
  /// would make slow flicks stop switching tabs (D-2 keeps swipe tab
  /// switching). In-range paging is untouched — snapping still comes
  /// from the `PageScrollPhysics` branch.
  static const tabPagePhysics = PageScrollPhysics(
    parent: _EdgeBouncingScrollPhysics(),
  );

  @override
  State<AppShell> createState() => _AppShellState();
}

/// `BouncingScrollPhysics` with the stock fling threshold restored:
/// stock doubles `minFlingVelocity` (its ballistic simulation
/// decelerates more slowly), which would make slow flicks stop
/// switching tabs. Only the edge overscroll friction + spring-back
/// is wanted here, so the threshold stays at the platform default.
class _EdgeBouncingScrollPhysics extends BouncingScrollPhysics {
  const _EdgeBouncingScrollPhysics();

  @override
  double get minFlingVelocity => kMinFlingVelocity;
}

class _AppShellState extends State<AppShell> {
  static const int liveTabIndex = 1;

  final _pageController = PageController();
  int _currentIndex = 0;

  static const List<Widget> _pages = [
    VideoTabPage(),
    LiveTabPage(),
    MusicTabPage(),
    SettingsTabPage(),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onTabTapped(int index) {
    // Same-tab tap scrolls the tab's list to the top (iOS); a drag
    // never lands on the same tab (_selectForDrag only fires on a
    // change), so this cannot fire from a drag.
    if (index == _currentIndex) {
      HaoScrollToTop.scrollToTop(HaoScrollToTop.tabKeys[index]);
      return;
    }
    HaoHaptics.select();
    _dismissOverlays();
    setState(() => _currentIndex = index);
    _pageController.jumpToPage(index);
  }

  /// Audit P1-6: an open sheet/dialog/snackbar must never float over the
  /// new tab after a tab switch. Dismiss all overlays before changing
  /// pages (both tap and swipe paths go through here — onPageChanged
  /// also calls it, because a swipe can land while a sheet is open).
  void _dismissOverlays() {
    if (Get.isDialogOpen == true) Get.back();
    if (Get.isBottomSheetOpen == true) Get.back();
    Get.closeAllSnackbars();
  }

  @override
  Widget build(BuildContext context) {
    final isLiveTab = _currentIndex == liveTabIndex;
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    return Scaffold(
      body: Stack(
        children: [
          Padding(
            // Native bar: 64pt bar + 12pt gap + the system safe area,
            // so page content never slides under it.
            padding: EdgeInsets.only(bottom: 64 + 12 + bottomPadding),
            child: PageView(
              controller: _pageController,
              // Swipe guard (fix 7): no swipe navigation while on the
              // live tab.
              physics: isLiveTab
                  ? const NeverScrollableScrollPhysics()
                  : AppShell.tabPagePhysics,
              onPageChanged: (index) {
                _dismissOverlays();
                setState(() => _currentIndex = index);
              },
              children: _pages,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: TabBarDragLayer(
              currentIndex: _currentIndex,
              onSelect: _onTabTapped,
              child: GlassTabBar(
                currentIndex: _currentIndex,
                onTap: _onTabTapped,
              ),
            ),
          ),
          // Status-bar tap = scroll to top (iOS). The strip covers
          // only the system status-bar band, so no page content
          // sits under it (tab pages draw below the safe area);
          // a drag starting here still reaches the list below —
          // the zone has a tap recogniser only, which loses the
          // arena to a drag. Pushed routes cover this whole Stack,
          // so the zone never fires while a detail page is open.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: MediaQuery.of(context).padding.top,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => HaoScrollToTop.scrollToTop(
                HaoScrollToTop.tabKeys[_currentIndex],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Drag-to-switch layer over the native tab bar (b30, chen
/// 2026-11-23: “底栏菜单都不可以拖动了”).
///
/// Root cause: build 26's Kumone bar was one big `GestureDetector` —
/// dragging across it moved the pill with the finger and switched
/// tabs live (`_select(_indexForX(x, cellW))`, 8pt dead zone). Build
/// 29 replaced the bar with the real `UITabBar` and deleted that
/// drag layer with it; `UITabBar` is tap-only, so dragging the bar
/// did nothing at all. The content-area PageView swipe was never
/// removed (it is still there, `tabPagePhysics`), but the bar
/// itself lost its drag.
///
/// This restores the drag as a transparent overlay on top of the
/// native bar: a horizontal drag switches tabs as the finger crosses
/// each cell (`HaoHaptics.select()` on each change), taps fall
/// through to the native bar untouched. The Kumone pill and settle
/// spring stay void — the native bar draws its own selection.
///
/// `HitTestBehavior.translucent` is load-bearing: an opaque detector
/// would swallow the tap and the native bar below would never see
/// it. With translucent + drag-only handlers, taps reach the
/// platform view underneath and only horizontal drags are claimed
/// here.
class TabBarDragLayer extends StatefulWidget {
  const TabBarDragLayer({
    super.key,
    required this.currentIndex,
    required this.onSelect,
    required this.child,
  });

  final int currentIndex;
  final ValueChanged<int> onSelect;
  final Widget child;

  @override
  State<TabBarDragLayer> createState() => _TabBarDragLayerState();
}

class _TabBarDragLayerState extends State<TabBarDragLayer> {
  double? _dragStartX;

  /// Bar width, cached from the last layout (drives cell width).
  double _barWidth = 0;

  int _indexForX(double x) {
    final cellW = _barWidth / GlassTabBar._items.length;
    if (cellW <= 0) return widget.currentIndex;
    return (x / cellW).floor().clamp(0, GlassTabBar._items.length - 1);
  }

  void _selectForDrag(double x) {
    final index = _indexForX(x);
    if (index != widget.currentIndex) {
      HaoHaptics.select();
      widget.onSelect(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (details) {
        _dragStartX = details.localPosition.dx;
      },
      onHorizontalDragUpdate: (details) {
        final startX = _dragStartX;
        if (startX == null) return;
        // 8pt dead zone (old Kumone rule): a tap's wobble must never
        // start a drag.
        if ((details.localPosition.dx - startX).abs() < 8) return;
        _selectForDrag(details.localPosition.dx);
      },
      onHorizontalDragEnd: (_) => _dragStartX = null,
      onHorizontalDragCancel: () => _dragStartX = null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _barWidth = constraints.maxWidth;
          return widget.child;
        },
      ),
    );
  }
}

/// Apple-native bottom tab bar (build-29 adoption).
///
/// iOS: glassy_ui_ios `GlassTabBar` — the real `UITabBar` with liquid
/// glass on iOS 26+ / classic styling on iOS 17–18. Labels on every
/// tab, transparent tint pill, .bouncy selection animation. The bar
/// itself is tap-only (UITabBar has no drag); the drag-to-switch
/// gesture lives in [TabBarDragLayer], which AppShell wraps around
/// this bar — dragging across the bar switches tabs, like the old
/// Kumone pill drag (chen 2026-11-23: the bar must stay draggable).
/// Other platforms / tests: [_AppleTabBarFallback] renders the same
/// layout in Flutter.
class GlassTabBar extends StatelessWidget {
  const GlassTabBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;

  /// Key for the sliding pill (tests assert its settled position).
  /// The pill lives in the fallback on this host; on iOS the native
  /// bar draws its own.
  static const pillKey = ValueKey('glassTabBarPill');

  static const List<(IconData, String, String)> _items = [
    // (Flutter icon, label, SF Symbol for the native bar).
    (CupertinoIcons.film, '影视', 'film.fill'),
    (CupertinoIcons.tv, '直播', 'tv.fill'),
    (CupertinoIcons.music_note, '音乐', 'music.note'),
    (CupertinoIcons.settings, '设置', 'gearshape.fill'),
  ];

  @override
  Widget build(BuildContext context) {
    // G-P2-4: non-throwing read — the bar must render under a bare
    // ThemeData (e.g. a test harness) instead of throwing.
    final theme = HaoTheme.ofOrDefault(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return glassy.GlassTabBar(
      items: [
        for (final item in _items)
          glassy.NativeItem.symbol(item.$2, item.$3),
      ],
      selectedIndex: currentIndex,
      onChanged: onTap,
      // The native bar follows the app's light/dark mode, not the
      // system one (the app's theme can differ from the system).
      style: glassy.NativeStyle(
        tintColor: theme.accent,
        colorScheme: isDark
            ? glassy.NativeColorScheme.dark
            : glassy.NativeColorScheme.light,
      ),
      fallback: _AppleTabBarFallback(
        currentIndex: currentIndex,
        onTap: onTap,
      ),
    );
  }
}

/// Flutter rendering of the Apple-native tab bar (off-iOS fallback):
/// full-width bar, 64pt, hairline top border, icon + 10pt label per
/// tab, transparent tint pill (theme accent at 14%) behind the
/// selected tab. The pill slides as ONE piece on a bouncy curve —
/// no stretch, no magnification, no drag. Selected icon = theme
/// accent, unselected = primary 0.8.
///
/// The bounce is `Curves.elasticOut` (Apple `.bouncy` approximation,
/// 600ms) — deliberately NOT the void Kumone settle spring.
class _AppleTabBarFallback extends StatelessWidget {
  const _AppleTabBarFallback({
    required this.currentIndex,
    required this.onTap,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;

  static const double _barHeight = 64;
  static const double _pillHeight = 56;

  static const List<(IconData, String)> _items = [
    (CupertinoIcons.film, '影视'),
    (CupertinoIcons.tv, '直播'),
    (CupertinoIcons.music_note, '音乐'),
    (CupertinoIcons.settings, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.ofOrDefault(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.surface,
        border: Border(top: BorderSide(color: theme.hairline, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: _barHeight,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final cellW = width / _items.length;
              return Stack(
                children: [
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.elasticOut,
                    left: currentIndex * cellW + 4,
                    top: (_barHeight - _pillHeight) / 2,
                    width: cellW - 8,
                    height: _pillHeight,
                    child: Container(
                      key: GlassTabBar.pillKey,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        color: theme.accentSoft,
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      for (var i = 0; i < _items.length; i++)
                        Expanded(
                          child: _TabItem(
                            icon: _items[i].$1,
                            label: _items[i].$2,
                            selected: i == currentIndex,
                            theme: theme,
                            onTap: () => onTap(i),
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// One tab item: icon (23pt) + visible 10pt label below it (Apple
/// tab bar — chen 2026-11-22: 有字）. Selected = accent, unselected
/// = primary at 0.8. Tap only; no drag.
class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.theme,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final HaoTheme theme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? theme.accent
        : theme.textPrimary.withValues(alpha: 0.8);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 23, color: color, semanticLabel: label),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w500,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}
