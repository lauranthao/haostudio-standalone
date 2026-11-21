// App shell — 4 bottom tabs: 影视 / 直播 / 音乐 / 设置. No home page.
//
// Floating glass capsule tab bar — Kumone, restored 2026-11-21
// (chen: “Kumone那种，不要文字，不要有影子了”). The Muse-app bar
// (build 23, icon-only matte pill + magnifying lens) is gone:
// reference is Kumone again (`~/workspace/research/kumone/`,
// LGPL-3.0, read-only): `Sources/Kumone/Features/GlassTabBar.swift`
// (its iOS 16–25 fallback bar; the iOS 26 native bar is the same
// capsule in real liquid glass). Numbers are Kumone's (see below);
// only the tab set, icons and accent colour are ours (our 4 tabs,
// Material icons, theme accent — Kumone's red #EC4949 accent is NOT
// copied, our themes own the accent, and blue accents are now black
// per chen 2026-11-18).
//
// Kumone values copied (GlassTabBar.swift + Theme.swift FloatingChrome):
// - Capsule, 56pt content + 4pt inset = 64pt total; horizontal
//   padding 12; bottom margin 6; content clearance 82
//   (tabBarClearance = 64 + 6 + 12)
// - white stroke 0.22 light / 0.08 dark, 0.5pt. NO shadow —
//   chen 2026-11-21: 不要有影子了 (the Kumone shadow values are
//   NOT applied; glassTabBarShadow / glassMiniPlayerShadow are
//   deleted from lib/core/theme/glass.dart).
// - selection pill: faint tint, white 0.10 dark / black 0.075 light,
//   width cellW - 8, height = content height (Telegram faint tint,
//   not a bright chip — chen: grey glass pill, not coloured). The
//   pill slides as ONE piece on the settle spring: no lens, no
//   stretch, no magnification of icons or page content.
// - item: icon 23 only, NO label (chen 2026-11-21: 不要文字）;
//   unselected = primary 0.8; selected = accent (ours: theme accent)
// - drag: DragGesture(minimumDistance: 0); <8pt horizontal movement
//   does not start a drag; while dragging the pill follows the finger
//   (clamped to the bar), crossing a cell switches the tab
//   (HaoHaptics.select() on every switch); on release the pill
//   settles with spring(0.35, 0.82)
// - tap still switches (HaoHaptics.select() on switch); tap on the
//   already-selected tab calls onReselect (Kumone) — ours is a no-op
//   (no reselect action exists)
//
// The glass itself is `liquid_glass_widgets` (ios27 preset — the
// demo's `GlassTabBar.bottom` passes no settings, so it renders the
// ambient ios27 defaults — premium, own layer). It is NOT the
// library's `GlassTabBar.bottom`:
// that widget has no drag API and its indicator only follows
// selectedIndex through its internal spring, so using it would
// replace the finger-tracking pill with a cell-chasing one and its
// pill geometry (tabPadding / indicatorExpansion) cannot reproduce
// Kumone's cellW-8 x 56 pill exactly. The bar shell is library glass;
// the pill, items and drag layer stay ours, untouched.
//
// Differences from Kumone, with reasons:
// - Settle animation: a REAL spring, not an ease. Kumone
//   `Animation.spring(response: 0.35, dampingFraction: 0.82)`
//   (GlassTabBar.swift:36) maps to Flutter's SpringSimulation with
//   mass 1, stiffness ω² and damping 2·ζ·ω where ω = 2π/0.35
//   (stiffness ≈ 322.273, damping ≈ 29.441) — see
//   `GlassTabBarState.settleSpring`. Tap and release both drive it
//   (`_springTo`); while dragging the pill follows the finger
//   directly with no animation, exactly like Kumone's `pillX`.
// - No long-press action (Kumone/Beans have none on the tab bar
//   either — Beans' long-press was on discover to open a sort sheet;
//   we have no equivalent sheet, so no long-press is added).
// - The bar floats: it does not sit on the bottom edge, and the
//   PageView gets bottom padding (Kumone tabBarClearance 82 + safe
//   area) so page content never slides underneath it.
//
// Swipe guard (fix 7): on every live page a horizontal swipe must never
// change the bottom tab. Implemented by disabling PageView swipe while the
// current tab IS live; the tab bar itself stays visible and tappable.
// Swiping INTO live from another tab still works, because the guard reads
// the CURRENT page. The live room is a pushed route (no tab bar at all
// while open — fix 17.3), separate from this guard.

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:get/get.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/theme/hao_themes.dart';
import '../core/theme/haptics.dart';
import '../core/theme/liquid_glass_theme.dart';

import '../domains/live/presentation/live_tab_page.dart';
import '../features/music/music_tab_page.dart';
import '../features/settings/settings_tab_page.dart';
import '../features/video/video_tab_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
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
    if (index == _currentIndex) return;
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
            // Kumone FloatingChrome.tabBarClearance = 64 + 6 + 12 = 82,
            // plus the system safe area, so page content never slides
            // under the capsule.
            padding: EdgeInsets.only(bottom: 82 + bottomPadding),
            child: PageView(
              controller: _pageController,
              // Swipe guard (fix 7): no swipe navigation while on the
              // live tab.
              physics: isLiveTab
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
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
            // Kumone FloatingChrome.bottomMargin = 6.
            bottom: 6 + bottomPadding,
            // Quality floor: the adaptive scope may demote the app to
            // standard/minimal (minimal is literally frosted
            // BackdropFilter glass); the bar is a small capsule and
            // must stay premium so it never reads as frosted glass
            // on a busy phone.
            child: GlassAdaptiveScope(
              minQuality: GlassQuality.premium,
              child: GlassTabBar(
                currentIndex: _currentIndex,
                onTap: _onTabTapped,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Floating glass capsule tab bar (Beans `KumoneGlassTabBar`).
class GlassTabBar extends StatefulWidget {
  const GlassTabBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  State<GlassTabBar> createState() => GlassTabBarState();
}

class GlassTabBarState extends State<GlassTabBar>
    with SingleTickerProviderStateMixin {
  // Beans constants (RootView.swift): innerInset 4, contentHeight 56.
  static const double _innerInset = 4;
  static const double _contentHeight = 56;

  /// Kumone settle spring (GlassTabBar.swift:36):
  /// `Animation.spring(response: 0.35, dampingFraction: 0.82)`.
  /// Flutter equivalent: ω = 2π / response, stiffness = ω²,
  /// damping = 2 · dampingFraction · ω, mass 1 — an underdamped
  /// spring (ζ = 0.82 < 1), so the pill overshoots slightly and
  /// settles, instead of easing to a stop.
  static const settleSpring = SpringDescription(
    mass: 1.0,
    stiffness: 322.273,
    damping: 29.441,
  );

  /// Key for the sliding pill (tests assert its settled position).
  static const pillKey = ValueKey('glassTabBarPill');

  late final AnimationController _springController;

  /// Current pill left edge (content space). Null until the first
  /// layout, when it is placed at the rest position with no animation.
  double? _pillLeft;

  /// Rest position the spring is currently driving towards; null
  /// while the finger owns the pill. Guards against restarting the
  /// spring on every rebuild mid-flight.
  double? _springTarget;

  @override
  void initState() {
    super.initState();
    _springController = AnimationController.unbounded(vsync: this)
      ..addListener(() {
        setState(() => _pillLeft = _springController.value);
      });
  }

  @override
  void dispose() {
    _springController.dispose();
    super.dispose();
  }

  /// Drive the pill to [target] with the Kumone settle spring,
  /// starting from its current position and velocity — so a tap
  /// mid-settle or a release after a drag never jumps.
  void _springTo(double target) {
    _springTarget = target;
    _springController.animateWith(
      SpringSimulation(
        settleSpring,
        _pillLeft ?? _springController.value,
        target,
        _springController.velocity,
      ),
    );
  }

  static const List<(IconData, String)> _items = [
    (Icons.movie, '影视'),
    (Icons.live_tv, '直播'),
    (Icons.music_note, '音乐'),
    (Icons.settings, '设置'),
  ];

  double? _dragX;
  double? _dragStartX;
  bool _isDragging = false;

  int _indexForX(double x, double cellW) =>
      (x / cellW).floor().clamp(0, _items.length - 1);

  void _select(int index) {
    if (index == widget.currentIndex) return;
    HaoHaptics.select();
    widget.onTap(index);
  }

  @override
  Widget build(BuildContext context) {
    // G-P2-4: non-throwing read — the bar must render under a bare
    // ThemeData (e.g. a test harness) instead of throwing.
    final theme = HaoTheme.ofOrDefault(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      // NO shadow (chen 2026-11-21: 不要有影子了) — the bar is glass
      // only; the stroke + blur carry the floating read.
      child: Stack(
        children: [
          GlassContainer(
            // Capsule: radius far above half the height.
            shape: const LiquidRoundedSuperellipse(borderRadius: 999),
            padding: const EdgeInsets.all(_innerInset),
            // Unified page (chen 2026-11-19): the chrome shares the
            // page's own background colour instead of the demo's
            // 53%-white ios27 tint, so the bar reads as part of the
            // page, not a separate slab (see
            // HaoLiquidGlass.chromeSettings). Optics are still the
            // ios27 preset underneath.
            // (useOwnLayer: true — per-widget settings are ignored
            // in grouped mode without it). Premium: floating chrome.
            settings: HaoLiquidGlass.chromeSettings(context),
            useOwnLayer: true,
            quality: GlassQuality.premium,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final count = _items.length;
                final cellW = width / count;
                // Rest position: centre of the selected cell. While
                // dragging the pill follows the finger (clamped so it
                // never leaves the bar) — _pillLeft is written
                // directly by the drag callbacks, with no animation.
                // At rest the pill is driven to the selected cell by
                // the settle spring (tap and release both go through
                // here). The spring is started in a post-frame
                // callback, never during build (starting it would
                // notify the listener, i.e. setState during build).
                final restX = cellW * (widget.currentIndex + 0.5);
                final double pillLeft;
                if (_isDragging && _dragX != null) {
                  pillLeft = _pillLeft ?? restX - (cellW - 8) / 2;
                } else {
                  final target = restX - (cellW - 8) / 2;
                  if (_pillLeft == null) {
                    _pillLeft = target;
                    _springTarget = target;
                  } else if (_springTarget != target) {
                    _springTarget = target;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted || _isDragging) return;
                      if (_springTarget != target) return;
                      _springTo(target);
                    });
                  }
                  pillLeft = _pillLeft!;
                }
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) {
                    _select(_indexForX(details.localPosition.dx, cellW));
                  },
                  onHorizontalDragStart: (details) {
                    // Drag starts on finger down (Beans minimumDistance 0);
                    // _isDragging only engages after 8pt of total movement
                    // from the start point, like Beans' translation check.
                    _dragStartX = details.localPosition.dx;
                    _dragX = null;
                  },
                  onHorizontalDragUpdate: (details) {
                    final startX = _dragStartX;
                    if (startX == null) return;
                    if (!_isDragging &&
                        (details.localPosition.dx - startX).abs() < 8) {
                      return;
                    }
                    setState(() {
                      _isDragging = true;
                      _dragX = details.localPosition.dx;
                      // Finger owns the pill now: stop any settle spring
                      // and track the finger directly (Kumone: pillX =
                      // dragX while dragging). Clearing _springTarget
                      // forces a fresh spring on release.
                      _springController.stop();
                      _pillLeft = _dragX!
                              .clamp(cellW / 2, width - cellW / 2) -
                          (cellW - 8) / 2;
                      _springTarget = null;
                    });
                    _select(_indexForX(details.localPosition.dx, cellW));
                  },
                  onHorizontalDragEnd: (_) {
                    if (_dragX != null) {
                      _select(_indexForX(_dragX!, cellW));
                    }
                    setState(() {
                      _isDragging = false;
                      _dragX = null;
                      _dragStartX = null;
                    });
                  },
                  onHorizontalDragCancel: () {
                    setState(() {
                      _isDragging = false;
                      _dragX = null;
                      _dragStartX = null;
                    });
                  },
                  child: SizedBox(
                    height: _contentHeight,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: Stack(
                        children: [
                          Positioned(
                            // Pill position is owned by the settle spring
                            // (see _springTo) or, while dragging, by
                            // the finger directly — never an ease curve.
                            left: pillLeft,
                            top: 0,
                            child: Container(
                              key: GlassTabBarState.pillKey,
                              width: cellW - 8,
                              height: _contentHeight,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(999),
                                color: isDark
                                    ? Colors.white.withValues(alpha: 0.10)
                                    : Colors.black.withValues(alpha: 0.075),
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
                                    selected: i == widget.currentIndex,
                                    theme: theme,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          // Kumone stroke overlay (GlassTabBar.swift: .overlay
          // strokeBorder white 0.22 light / 0.08 dark, 0.5pt) —
          // drawn above the shader glass, below nothing
          // interactive (IgnorePointer).
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: Colors.white.withValues(
                      alpha: isDark ? 0.08 : 0.22,
                    ),
                    width: 0.5,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One tab item: icon ONLY, no label (chen 2026-11-21: Kumone那种，
/// 不要文字）. Kumone: selected = accent (ours: theme accent),
/// unselected = primary at 0.8. [label] is kept as the semantic
/// label (screen readers) and is never drawn.
class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.theme,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final HaoTheme theme;

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? theme.accent
        : theme.textPrimary.withValues(alpha: 0.8);
    return Center(
      child: Icon(icon, size: 23, color: color, semanticLabel: label),
    );
  }
}
