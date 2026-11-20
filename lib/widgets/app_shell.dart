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
//
// Pill crossfade (fix for the doubling, chen 2026-11-20, bug 6): the
// lens is ONLY visible while the pill moves (Opacity = thickness);
// at rest the pill is a SOLID faint-tint capsule (Kumone's white
// 0.10 dark / black 0.075 light) with the selected icon+label at
// normal scale — a single copy, like NetEase at rest. See
// GlassTabBarState._thicknessController for the mechanism and the
// library citation.

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

  /// Key for the resting pill (the solid faint-tint capsule shown at
  /// rest, see below) and for the two Opacity wrappers that crossfade
  /// it against the lens. Tests assert the crossfade state.
  static const restPillKey = ValueKey('glassTabBarRestPill');
  static const restPillOpacityKey = ValueKey('glassTabBarRestPillOpacity');
  static const pillOpacityKey = ValueKey('glassTabBarPillOpacity');

  /// Pill "thickness" — the motion value that crossfades the resting
  /// pill against the lens, following the library's own
  /// AnimatedGlassIndicator (liquid_glass_widgets 1.17.5,
  /// lib/widgets/shared/animated_glass_indicator.dart):
  /// `backgroundOpacity = 1 - thickness / 0.15` (solid pill at rest)
  /// and the glass lens crossfades in with `visibility = fade`
  /// (`fade = thickness`, glass only when fade > 0.05). The library
  /// also wraps the lens in `Opacity(opacity: fade, ...)`.
  ///
  /// 0 = at rest (solid resting pill, NO lens — NetEase frames
  /// netease_pill_anim frame_001/021: the pill at rest is a solid
  /// dark oval with the selected icon+label at NORMAL size, red,
  /// single copy); 1 = in motion (lens fully visible, refracting
  /// the whole tab item — icon + label — magnified/warped, NetEase
  /// frames 005/011). Driven by _thicknessController (180ms): it
  /// forwards when a drag engages or a settle spring starts, and
  /// reverses when both springs have settled and the finger is off.
  late final AnimationController _thicknessController;

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
      ..addListener(() => setState(() => _pillLeft = _leftController.value))
      ..addStatusListener((_) => _maybeReverseThickness());
    _rightController = AnimationController.unbounded(vsync: this)
      ..addListener(
        () => setState(() => _pillRight = _rightController.value),
      )
      ..addStatusListener((_) => _maybeReverseThickness());
    // The crossfade driver (see _thicknessController): its own
    // listener rebuilds the bar during the 180ms fade, when the
    // springs are idle and would not otherwise trigger a rebuild.
    _thicknessController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    )..addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _leftController.dispose();
    _rightController.dispose();
    _thicknessController.dispose();
    super.dispose();
  }

  /// Reverse the thickness crossfade (lens out, resting pill in)
  /// once the pill has settled. Called from both springs' status
  /// listeners, so the staggered trailing edge (which starts 60ms
  /// late) keeps the lens up until it too has settled.
  ///
  /// The settle test is the springs' STATUS (completed/dismissed),
  /// not isAnimating: a status listener fires synchronously inside
  /// animateWith, and at that instant the other edge (not yet
  /// started — the trailing edge lags 60ms) still reads idle, so an
  /// isAnimating check would reverse the thickness at the very start
  /// of every move and the lens would never come up.
  void _maybeReverseThickness() {
    if (_isDragging) return;
    const settled = [
      AnimationStatus.completed,
      AnimationStatus.dismissed,
    ];
    if (!settled.contains(_leftController.status)) return;
    if (!settled.contains(_rightController.status)) return;
    if (_thicknessController.value > 0) {
      _thicknessController.reverse();
    }
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
    // The pill is about to move (tap settle or drag release): bring
    // the lens up (resting pill fades out with it). It reverses via
    // _maybeReverseThickness once both springs have settled.
    _thicknessController.forward();
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
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Full bar width minus the shell's 4pt inset on each side:
            // the pill math below runs in this content space, and
            // gesture x is shifted by the inset (see _contentX).
            final width = constraints.maxWidth - _innerInset * 2;
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
            // Gesture x arrives in full-bar space (the detector wraps
            // the whole 64pt bar); shift it into content space.
            double contentX(double dx) => dx - _innerInset;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) {
                _select(_indexForX(contentX(details.localPosition.dx), cellW));
              },
              onHorizontalDragStart: (details) {
                // Drag starts on finger down (Beans minimumDistance 0);
                // _isDragging only engages after 8pt of total movement
                // from the start point, like Beans' translation check.
                _dragStartX = contentX(details.localPosition.dx);
              },
              onHorizontalDragUpdate: (details) {
                final startX = _dragStartX;
                if (startX == null) return;
                final dx = contentX(details.localPosition.dx);
                if (!_isDragging && (dx - startX).abs() < 8) {
                  return;
                }
                setState(() {
                  _isDragging = true;
                  _dragX = dx;
                  // The lens comes up (resting pill fades out). It
                  // reverses once the release spring has settled.
                  _thicknessController.forward();
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
                _select(_indexForX(dx, cellW));
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
                height: _contentHeight + _innerInset * 2,
                child: Stack(
                  children: [
                    // Bar shell: glass only (no child content). Its
                    // backdrop is the page behind the bar; the icons
                    // paint above it, the pill above them.
                    Positioned.fill(
                      child: GlassContainer(
                        shape: const LiquidRoundedSuperellipse(
                          borderRadius: 999,
                        ),
                        // Unified page (chen 2026-11-19): the chrome
                        // shares the page's own background colour
                        // instead of the demo's 53%-white ios27 tint,
                        // so the bar reads as part of the page, not a
                        // separate slab (see
                        // HaoLiquidGlass.chromeSettings). Optics are
                        // still the ios27 preset underneath.
                        // (useOwnLayer: true — per-widget settings
                        // are ignored in grouped mode without it).
                        // Premium: floating chrome (SKILL.md Rule 5).
                        settings: HaoLiquidGlass.chromeSettings(context),
                        useOwnLayer: true,
                        quality: GlassQuality.premium,
                        child: const SizedBox.expand(),
                      ),
                    ),
                    // Icons + pill, inset like the old shell padding.
                    // Clip the pill to the bar's capsule: the settle
                    // spring overshoots ~1-2%, so at an edge tab the
                    // leading edge can briefly pass the bar's end.
                    Positioned(
                      left: _innerInset,
                      top: _innerInset,
                      right: _innerInset,
                      height: _contentHeight,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: Stack(
                          children: [
                            SizedBox(
                              height: _contentHeight,
                              child: Row(
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
                            ),
                            // Resting pill (doubling fix, chen
                            // 2026-11-20): a SOLID faint-tint capsule
                            // at the pill's current edges, crossfaded
                            // against the lens by _thicknessController
                            // (opacity 1 - thickness). At rest the
                            // lens is fully faded out (Opacity 0
                            // skips painting it entirely) and only
                            // this pill shows, with the selected
                            // icon+label drawn directly on it at
                            // normal scale — a single copy, exactly
                            // like NetEase at rest (frame_001/021:
                            // solid dark oval, normal-size red
                            // icon+label). During motion it fades out
                            // as the lens fades in, at the same edges,
                            // so the swap is a clean morph. Tint is
                            // Kumone's (see header): white 0.10 dark
                            // / black 0.075 light — a faint grey,
                            // never black (chen).
                            Positioned(
                              left: pillLeft,
                              top: 0,
                              child: Opacity(
                                key: GlassTabBarState.restPillOpacityKey,
                                opacity: 1 - _thicknessController.value,
                                child: DecoratedBox(
                                  key: GlassTabBarState.restPillKey,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(999),
                                    color: isDark
                                        ? Colors.white.withValues(alpha: 0.10)
                                        : Colors.black.withValues(
                                            alpha: 0.075,
                                          ),
                                  ),
                                  child: SizedBox(
                                    width: pillRight - pillLeft,
                                    height: _contentHeight,
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              // Pill edges are owned by the two springs
                              // (see _springTo) or, while dragging, by
                              // the finger directly — never an ease
                              // curve. The lens is its OWN layer
                              // (useOwnLayer: true, indicator preset —
                              // see HaoLiquidGlass.pillLensSettings)
                              // sitting ABOVE the icon row, so its
                              // shader samples the icons + labels and
                              // magnifies / distorts them like
                              // NetEase's lens (chen 2026-11-20:
                              // "要做到和这样一样的动画"; reference
                              // frames netease_pill_anim). A grouped
                              // pill inside the shell's child can only
                              // refract the page behind the bar — the
                              // icons paint above the glass there —
                              // which is why the old lens never
                              // magnified them. The pill is a
                              // transparent lens — no fill, no colour
                              // (chen: 不要胶囊黑色); the selection
                              // reads through the icon/label colour
                              // below, which follows the pill. The
                              // pill is a sibling of the shell, not
                              // nested inside another glass container,
                              // so the two layers are not nested
                              // refractive glass.
                              //
                              // Doubling fix (chen 2026-11-20, bug 6):
                              // the old pill was this lens permanently
                              // ON, even at rest, sitting over the
                              // directly-drawn icon row. On the phone
                              // (Impeller premium) the see-through
                              // lens body does not hide the direct
                              // copy — the library's own shader says
                              // it verbatim (liquid_glass_render.frag,
                              // passthrough comment): "the icon layer
                              // is also drawn directly, so a
                              // see-through body reveals the crisp copy
                              // next to the refracted one, i.e. doubled
                              // labels" — so the direct (normal-scale)
                              // icon+label showed through next to the
                              // refracted (magnified) copy, the icon
                              // pushed up and the label pushed down,
                              // both clipped at the pill edges. The
                              // fix follows the library's
                              // AnimatedGlassIndicator and NetEase:
                              // the lens is ONLY visible while the pill
                              // moves (Opacity = thickness, 0 at rest,
                              // 1 in motion). At rest it is not
                              // painted at all and the solid resting
                              // pill above shows instead — one copy,
                              // normal scale. In motion it refracts the
                              // WHOLE tab item (icon + label together,
                              // chen 2026-11-20: the lens magnifies
                              // the entire tab item, not just the icon)
                              // — a single magnified/warped copy,
                              // turning red as the pill covers it,
                              // NetEase frames 005/011. The lens
                              // settings are unchanged (RI 1.35,
                              // thickness 36): the magnification is
                              // NOT weakened to hide the doubling.
                              left: pillLeft,
                              top: 0,
                              child: Opacity(
                                key: GlassTabBarState.pillOpacityKey,
                                opacity: _thicknessController.value,
                                child: GlassContainer(
                                  key: GlassTabBarState.pillKey,
                                  shape: const LiquidRoundedSuperellipse(
                                    borderRadius: 999,
                                  ),
                                  settings:
                                      HaoLiquidGlass.pillLensSettings(context),
                                  useOwnLayer: true,
                                  quality: GlassQuality.premium,
                                  child: SizedBox(
                                    width: pillRight - pillLeft,
                                    height: _contentHeight,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Kumone stroke overlay (GlassTabBar.swift:
                    // .overlay strokeBorder white 0.22 light / 0.08
                    // dark, 0.5pt) — drawn above the shader glass,
                    // below nothing interactive (IgnorePointer).
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
          },
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
  /// NetEase red) — so the colour follows the pill as it slides.
  /// The direct icon/label never move (drawn at normal scale); the
  /// magnification happens in the LENS, which refracts the whole tab
  /// item — icon + label together (chen 2026-11-20; NetEase frames
  /// 005/011: the label magnifies with the icon inside the lens,
  /// turning red as the pill covers it). At rest the label is normal
  /// size (NetEase frames 001/021) — the "labels magnify" is a
  /// motion effect, not a rest state.
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
