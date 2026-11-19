// App shell — 4 bottom tabs: 影视 / 直播 / 音乐 / 设置. No home page.
//
// Floating glass capsule tab bar — reference is now Kumone
// (`~/workspace/research/kumone/`, LGPL-3.0, read-only):
// `Sources/Kumone/Features/GlassTabBar.swift` (its iOS 16–25 fallback
// bar; the iOS 26 native bar is the same capsule in real liquid
// glass). Numbers are Kumone's (see below); only the tab set, icons
// and accent colour are ours (our 4 tabs, Material icons, theme
// accent — Kumone's red #EC4949 accent is NOT copied, our themes own
// the accent, and blue accents are now black per chen 2026-11-18).
//
// Kumone values copied (GlassTabBar.swift + Theme.swift FloatingChrome):
// - Capsule, 56pt content + 4pt inset = 64pt total; horizontal
//   padding 12; bottom margin 6; content clearance 82
//   (tabBarClearance = 64 + 6 + 12)
// - white stroke 0.22 light / 0.08 dark, 0.5pt + shadow black 0.10
//   light / 0.28 dark, radius 12, y 4
// - selection pill: white 0.10 dark / black 0.075 light, width
//   cellW - 8, height = content height (Telegram faint tint, not a
//   bright chip — chen: grey glass pill, not coloured)
// - item: icon 23 semibold + label 10 semibold, VStack spacing 3;
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

import '../core/theme/appearance_store.dart';
import '../core/theme/glass.dart';
import '../core/theme/hao_themes.dart';
import '../core/theme/haptics.dart';
import '../core/theme/liquid_glass_theme.dart';
import '../core/theme/tab_bar_accent.dart';

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
          // Custom background layer (stage 2 items 5-6): wallpaper or
          // background colour, behind the tab pages. Tab-root
          // Scaffolds are transparent exactly when this layer paints.
          const AppearanceBackgroundLayer(),
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
    with TickerProviderStateMixin {
  // Beans constants (RootView.swift): innerInset 4, contentHeight 56.
  static const double _innerInset = 4;
  static const double _contentHeight = 56;

  /// Rest width of the pill: 1.5 cells (NetEase frames
  /// netease_pill_rest / netease_sw_p2 — the pill at rest is centred
  /// on the selected cell and spans it plus half of each neighbour).
  /// Clamped to the bar's content bounds, so on the first/last tab
  /// the pill sits against the bar's edge instead of sticking out.
  static const double _restWidthCells = 1.5;

  /// Kumone settle spring (GlassTabBar.swift:36):
  /// `Animation.spring(response: 0.35, dampingFraction: 0.82)`.
  /// Flutter equivalent: ω = 2π / response, stiffness = ω²,
  /// damping = 2 · dampingFraction · ω, mass 1 — an underdamped
  /// spring (ζ = 0.82 < 1), so the pill overshoots slightly and
  /// settles, instead of easing to a stop. Drives the pill's
  /// LEADING edge (see _springTo).
  static const settleSpring = SpringDescription(
    mass: 1.0,
    stiffness: 322.273,
    damping: 29.441,
  );

  /// Trailing-edge stagger: the trailing edge starts this much
  /// later than the leading edge, on the same settle spring. The
  /// leading edge moves alone first, so the pill stretches
  /// mid-flight (NetEase frames: ~1.7+ cells spanning from→to) and
  /// the trailing edge catches up — both settle in ~0.35 + 0.06s,
  /// instead of the trailing edge lagging on a slower spring (which
  /// would stretch less and settle slower).
  static const _trailDelay = Duration(milliseconds: 60);

  /// Generation counter for the staggered trailing-edge start:
  /// incremented on every _springTo and on drag-start, so a delayed
  /// start from a superseded move never fires.
  int _springGeneration = 0;

  /// Key for the sliding pill (tests assert its settled position).
  static const pillKey = ValueKey('glassTabBarPill');

  /// One controller per pill edge; each drives a fixed edge (left →
  /// _pillLeft, right → _pillRight). Which spring each gets depends
  /// on the direction of the move (see _springTo) — the leading
  /// edge gets the settle spring, the trailing edge the slower
  /// trail spring.
  late final AnimationController _leftController;
  late final AnimationController _rightController;

  /// Current pill edges (content space). Null until the first
  /// layout, when they are placed at the rest position with no
  /// animation.
  double? _pillLeft;
  double? _pillRight;

  /// Rest position the springs are currently driving towards; null
  /// while the finger owns the pill. Guards against restarting the
  /// springs on every rebuild mid-flight.
  double? _leftTarget;
  double? _rightTarget;

  @override
  void initState() {
    super.initState();
    _leftController = AnimationController.unbounded(vsync: this)
      ..addListener(() => setState(() => _pillLeft = _leftController.value));
    _rightController = AnimationController.unbounded(vsync: this)
      ..addListener(
        () => setState(() => _pillRight = _rightController.value),
      );
  }

  @override
  void dispose() {
    _leftController.dispose();
    _rightController.dispose();
    super.dispose();
  }

  /// Drive both pill edges to [targetLeft]/[targetRight]. The edge
  /// moving towards the target (leading) starts now on the Kumone
  /// settle spring; the other (trailing) starts [_trailDelay] later
  /// on the same spring — staggered, so the pill stretches
  /// mid-flight and the trailing edge catches up, shrinking it back
  /// to 1.5 cells at rest. Both start from their current position
  /// and velocity, so a tap mid-settle or a release after a drag
  /// never jumps. The delayed start is generation-guarded: a newer
  /// move, a drag, or disposal cancels it.
  void _springTo(
    double targetLeft,
    double targetRight, {
    required bool leadingRight,
  }) {
    _leftTarget = targetLeft;
    _rightTarget = targetRight;
    final generation = ++_springGeneration;
    void startEdge(bool isLeft) {
      final controller = isLeft ? _leftController : _rightController;
      final target = isLeft ? targetLeft : targetRight;
      final current = isLeft ? _pillLeft : _pillRight;
      controller.animateWith(
        SpringSimulation(
          settleSpring,
          current ?? controller.value,
          target,
          controller.velocity,
        ),
      );
    }

    if (leadingRight) {
      startEdge(false);
      Future.delayed(_trailDelay, () {
        if (!mounted || _isDragging) return;
        if (generation != _springGeneration) return;
        if (_leftTarget != targetLeft || _rightTarget != targetRight) {
          return;
        }
        startEdge(true);
      });
    } else {
      startEdge(true);
      Future.delayed(_trailDelay, () {
        if (!mounted || _isDragging) return;
        if (generation != _springGeneration) return;
        if (_leftTarget != targetLeft || _rightTarget != targetRight) {
          return;
        }
        startEdge(false);
      });
    }
  }

  /// How selected cell [i] reads, from the pill centre's distance
  /// to the cell centre (in cells): 1 inside a 0.25-cell dead zone,
  /// fading to 0 at 0.75 cells. The dead zone absorbs the 0.25-cell
  /// clamp offset at the first/last tab, so the selected tab is
  /// fully coloured at rest and both neighbours read 0 — while
  /// mid-slide both adjacent tabs read ~0.5 (NetEase frames: the
  /// colour follows the pill, the cell the leading edge covers
  /// turns red as the pill arrives).
  static double selectednessFor(int i, double pillCenter, double cellW) {
    final d = (pillCenter - cellW * (i + 0.5)).abs() / cellW;
    return (1 - (d - 0.25) / 0.5).clamp(0.0, 1.0);
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
    final theme = HaoTheme.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Container(
        // Kumone shadow (glassTabBarShadow: black 0.10 light / 0.28
        // dark, radius 12, y 4). The library glass draws no outer
        // shadow of its own (allowElevation is false), so the shadow
        // stays ours, on a fill-less container.
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          boxShadow: glassTabBarShadow(context),
        ),
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
              // ios27 preset underneath. (useOwnLayer: true —
              // per-widget settings are ignored in grouped mode
              // without it). Premium: floating chrome (SKILL.md
              // Rule 5).
              settings: HaoLiquidGlass.chromeSettings(context),
              useOwnLayer: true,
              quality: GlassQuality.premium,
              child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final count = _items.length;
            final cellW = width / count;
            final restWidth = cellW * _restWidthCells;
            // Rest rect: 1.5 cells centred on the selected cell,
            // clamped to the bar's content bounds (first/last tab).
            final restCenter = cellW * (widget.currentIndex + 0.5);
            final restLeft =
                (restCenter - restWidth / 2).clamp(0.0, width - restWidth);
            final restRight = restLeft + restWidth;
            // Pill edges: while dragging the pill follows the finger
            // (clamped so it never leaves the bar) — both edges are
            // written directly by the drag callbacks, with no
            // animation. At rest the edges are driven to the selected
            // cell by the springs (tap and release both go through
            // here). The springs are started in a post-frame
            // callback, never during build (starting one would
            // notify its listener, i.e. setState during build).
            final double pillLeft;
            final double pillRight;
            if (_isDragging && _dragX != null) {
              pillLeft = _pillLeft ?? restLeft;
              pillRight = _pillRight ?? restRight;
            } else {
              if (_pillLeft == null || _pillRight == null) {
                _pillLeft = restLeft;
                _pillRight = restRight;
                _leftTarget = restLeft;
                _rightTarget = restRight;
              } else if (_leftTarget != restLeft ||
                  _rightTarget != restRight) {
                final targetLeft = restLeft;
                final targetRight = restRight;
                _leftTarget = targetLeft;
                _rightTarget = targetRight;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted || _isDragging) return;
                  if (_leftTarget != targetLeft ||
                      _rightTarget != targetRight) {
                    return;
                  }
                  final center = (_pillLeft! + _pillRight!) / 2;
                  _springTo(
                    targetLeft,
                    targetRight,
                    leadingRight: (targetLeft + targetRight) / 2 > center,
                  );
                });
              }
              pillLeft = _pillLeft!;
              pillRight = _pillRight!;
            }
            final pillCenter = (pillLeft + pillRight) / 2;
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
                  // Finger owns the pill now: stop both springs and
                  // track the finger directly (Kumone: pillX =
                  // dragX while dragging), at rest width — no stretch
                  // while dragging. Clearing the targets forces a
                  // fresh spring on release; bumping the generation
                  // cancels any pending staggered trailing start.
                  _leftController.stop();
                  _rightController.stop();
                  _springGeneration++;
                  _pillLeft = _dragX!
                          .clamp(restWidth / 2, width - restWidth / 2) -
                      restWidth / 2;
                  _pillRight = _pillLeft! + restWidth;
                  _leftTarget = null;
                  _rightTarget = null;
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
                // Clip the pill to the bar's capsule: the settle
                // spring overshoots ~1-2%, so at an edge tab the
                // leading edge can briefly pass the bar's end.
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: Stack(
                    children: [
                      Positioned(
                        // Pill edges are owned by the two springs
                        // (see _springTo) or, while dragging, by the
                        // finger directly — never an ease curve.
                        // The lens is a GROUPED GlassContainer
                        // (useOwnLayer false, the default): it joins
                        // the bar's own layer, so the bar + pill are
                        // ONE refraction pass — never two nested
                        // layers (standing rule). No settings: grouped
                        // children inherit the bar's ios27 preset +
                        // premium quality. The pill is a transparent
                        // lens — no fill, no colour (chen: 不要胶囊
                        // 黑色); the selection reads through the
                        // icon/label colour below, which follows the
                        // pill. The icons paint above the lens, so
                        // the lens refracts the page behind the bar,
                        // not the icons themselves (the icons must
                        // stay above the glass to stay sharp — the
                        // per-pixel magnification inside the lens is
                        // not reproduced; see the report).
                        left: pillLeft,
                        top: 0,
                        child: GlassContainer(
                          key: GlassTabBarState.pillKey,
                          shape: const LiquidRoundedSuperellipse(
                            borderRadius: 999,
                          ),
                          quality: GlassQuality.premium,
                          child: SizedBox(
                            width: pillRight - pillLeft,
                            height: _contentHeight,
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
                                selectedness: selectednessFor(
                                  i,
                                  pillCenter,
                                  cellW,
                                ),
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
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.icon,
    required this.label,
    required this.selectedness,
    required this.theme,
  });

  final IconData icon;
  final String label;

  /// 0..1, from the pill centre's distance to this cell's centre
  /// (GlassTabBarState.selectednessFor): 1 = fully selected, 0 =
  /// unselected. The icon + label colour is the lerp between the
  /// unselected colour and the tab-bar accent (user-chosen, default
  /// NetEase red) — so the colour follows the pill as it slides,
  /// and the icon/label never move (chen: 字不动只变色).
  final double selectedness;
  final HaoTheme theme;

  @override
  Widget build(BuildContext context) {
    final accent = TabBarAccentController.ensure();
    return Obx(() {
      final color = Color.lerp(
        theme.textPrimary.withValues(alpha: 0.8),
        accent.color.value,
        selectedness,
      )!;
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 23, color: color),
          const SizedBox(height: 3),
          Text(
            label,
            maxLines: 1,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      );
    });
  }
}
