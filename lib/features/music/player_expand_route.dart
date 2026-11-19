import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:get/get.dart';

import 'music_player_sheet.dart';
import 'widgets/mini_player_bar.dart';

/// Open the full player page.
///
/// - From a mini player bar ([fromRect] = the bar's global rect): the
///   player page EXPANDS from the bar — NetEase's expand animation
///   (see `PlayerExpandRoute`). The bar is the thing that grows, so
///   the rect must be the bar's own capsule rect, captured at tap
///   time (see `MiniPlayerBar.onOpenPlayer`).
/// - From anywhere else ([fromRect] null: song rows, FM cards, the
///   more sheet): the plain slide, exactly as before. There is no bar
///   to expand from, so no expansion.
///
/// The route is pushed on the root Navigator. The context is resolved
/// through Get's navigator key first: the overlay bar lives ABOVE the
/// root Navigator (GetMaterialApp `builder`), so its context has no
/// Navigator ancestor and `Navigator.of` throws there ("Navigator
/// operation requested with a context that does not include a
/// Navigator"). Contexts below the Navigator (home bar) resolve the
/// same state through the key, so one path serves both.
Future<T?> openPlayerPage<T>(BuildContext context, {Rect? fromRect}) {
  final state = Get.key.currentState ??
      Navigator.of(context, rootNavigator: true);
  if (fromRect != null) {
    return state.push<T>(
      PlayerExpandRoute<T>(
        fromRect: fromRect,
        child: const MusicPlayerPage(),
      ),
    );
  }
  return state.push<T>(
    MaterialPageRoute<T>(builder: (_) => const MusicPlayerPage()),
  );
}

/// Kumone settle spring (GlassTabBar.swift:36 —
/// `Animation.spring(response: 0.35, dampingFraction: 0.82)`; the
/// same numbers as `GlassTabBarState.settleSpring`, restated here so
/// this file does not import the app shell and create a cycle).
/// ω = 2π / 0.35, stiffness = ω², damping = 2 · 0.82 · ω, mass 1.
/// Underdamped (ζ = 0.82 < 1): fast ease-out with a ~1% overshoot,
/// then it settles instead of stopping dead.
class _SettleSpringCurve extends Curve {
  const _SettleSpringCurve();

  static final _sim = SpringSimulation(
    const SpringDescription(mass: 1.0, stiffness: 322.273, damping: 29.441),
    0.0,
    1.0,
    0.0,
  );

  /// The spring at 0.4s (the route's forward duration). The raw
  /// simulation does not land on exactly 1.0 there, so the curve is
  /// normalised by it — transform(1) is exactly 1, so the sheet
  /// lands exactly full-screen with no hairline of home showing at
  /// the edges.
  static final double _end = _sim.x(0.4);

  @override
  double transform(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    return (_sim.x(t * 0.4) / _end).clamp(0.0, 1.0);
  }
}

/// The player page as a sheet that EXPANDS from the mini player's
/// rect (NetEase, video frames `netease_seq_010` ~4.5s opening and
/// `netease_seq_016` ~7.5s closing):
///
/// - OPEN: a rounded-rect sheet grows upward from the bar's rect to
///   fill the screen. The sheet is the player page itself, laid out
///   inside the growing rect (top-anchored: the header sits at the
///   sheet's top, the lyrics below — the page's own layout compresses
///   because its gaps shrink to 0 and its scroll view clips, so there
///   is no overflow at any sheet height). The sheet starts
///   semi-transparent with the home visible around it and becomes
///   opaque as it fills; its corners go capsule (999, rendered as
///   half the 52pt bar height) → ~60 mid-flight → 0 at rest. The tab
///   bar stays visible underneath until the sheet covers it. The bar
///   itself is rendered once more inside the route at the start rect
///   and fades out over the first 35% — without it the overlay bar
///   would pop out the instant the route pushes (the observer hides
///   it) while the sheet is still transparent. 400ms, Kumone settle
///   spring.
/// - CLOSE (chevron / system back / edge swipe): the page slides to
///   the right and off, iOS swipe-back style — it does NOT shrink
///   back into the bar. The home (and the tab bar) is revealed on the
///   left as it goes. 350ms, easeOutCubic. The mini player fades back
///   in via `MiniPlayerOverlay`'s AnimatedSwitcher.
///
/// The player page itself is untouched — only this transition.
class PlayerExpandRoute<T> extends PageRouteBuilder<T> {
  PlayerExpandRoute({required this.fromRect, required Widget child})
      : super(
          pageBuilder: (_, _, _) => child,
          transitionDuration: const Duration(milliseconds: 400),
          reverseTransitionDuration: const Duration(milliseconds: 350),
          opaque: false,
          barrierColor: Colors.transparent,
          transitionsBuilder: (context, animation, secondaryAnimation, child) =>
              _PlayerExpandTransition(
            animation: animation,
            fromRect: fromRect,
            child: child,
          ),
        );

  /// The mini player's global rect at tap time (its capsule, without
  /// margins — see `MiniPlayerBar`).
  final Rect fromRect;
}

class _PlayerExpandTransition extends StatefulWidget {
  const _PlayerExpandTransition({
    required this.animation,
    required this.fromRect,
    required this.child,
  });

  final Animation<double> animation;
  final Rect fromRect;
  final Widget child;

  @override
  State<_PlayerExpandTransition> createState() =>
      _PlayerExpandTransitionState();
}

class _PlayerExpandTransitionState extends State<_PlayerExpandTransition>
    with SingleTickerProviderStateMixin {
  /// Edge-swipe drag offset (px right). 0 unless the user is dragging
  /// the page right from the left edge.
  double _dragDx = 0;

  /// Returns a cancelled drag to 0.
  late final AnimationController _returnController;

  @override
  void initState() {
    super.initState();
    _returnController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
  }

  @override
  void dispose() {
    _returnController.dispose();
    super.dispose();
  }

  void _animateDragBack() {
    final start = _dragDx;
    if (start <= 0) return;
    _returnController.reset();
    final anim = Tween<double>(begin: start, end: 0).animate(
      CurvedAnimation(parent: _returnController, curve: Curves.easeOut),
    );
    anim.addListener(() {
      if (mounted) setState(() => _dragDx = anim.value);
    });
    unawaited(_returnController.forward());
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final fullRect = Offset.zero & size;
    final animation = widget.animation;
    final isClosing = animation.status == AnimationStatus.reverse;

    // Slide-right on close (0 in every other state). The drag offset
    // is added on top so a finger-released pop starts exactly where
    // the finger left the page — no snap back to full-screen first.
    final slide = isClosing
        ? Curves.easeOutCubic.transform(
            (1 - animation.value).clamp(0.0, 1.0),
          ) *
            size.width
        : 0.0;

    Widget content;
    if (isClosing) {
      content = widget.child;
    } else {
      // Expand: spring drives the rect, linear time drives the fades.
      final t = const _SettleSpringCurve()
          .transform(animation.value.clamp(0.0, 1.0));
      final rect = Rect.lerp(widget.fromRect, fullRect, t)!;
      // Capsule (999, rendered as half the bar height) → ~60
      // mid-flight → 0 at rest. (1-t)^4 falls off fast enough that
      // the mid-flight sheet reads as a rounded rect, not a capsule
      // (video frame 010: ~60px corners on a ~625px sheet).
      final oneMinusT = 1 - t;
      final radius = 999 * oneMinusT * oneMinusT * oneMinusT * oneMinusT;
      final childOpacity = const Interval(
        0.15,
        0.75,
        curve: Curves.easeOut,
      ).transform(animation.value.clamp(0.0, 1.0));
      final barOpacity = 1.0 -
          const Interval(
            0.0,
            0.35,
            curve: Curves.easeOut,
          ).transform(animation.value.clamp(0.0, 1.0));

      content = Stack(
        fit: StackFit.expand,
        children: [
          // The expanding sheet: the player page laid out inside the
          // growing rect (top-anchored), clipped to its rounded rect.
          Positioned.fromRect(
            rect: rect,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: Opacity(opacity: childOpacity, child: widget.child),
            ),
          ),
          // The bar itself, fading out as the sheet takes over.
          // Margin zero: the copy is positioned exactly on the bar's
          // rect, so its own margins must not inset it again.
          if (barOpacity > 0)
            Positioned.fromRect(
              rect: widget.fromRect,
              child: Opacity(
                opacity: barOpacity,
                child: MiniPlayerBar(
                  margin: EdgeInsets.zero,
                  onOpenPlayer: (_) {},
                ),
              ),
            ),
          // iOS edge swipe-back: left edge, top 65% only. The
          // progress bar lives in the bottom third and scrubs
          // horizontally — the strip must never own a drag that
          // starts on it. Only live once the open animation has
          // settled; a drag mid-flight would fight the spring.
          if (animation.status == AnimationStatus.completed)
            Positioned(
              left: 0,
              top: 0,
              width: 24,
              height: size.height * 0.65,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragStart: (_) => _returnController.stop(),
                onHorizontalDragUpdate: (details) {
                  setState(() {
                    _dragDx =
                        (_dragDx + details.delta.dx).clamp(0.0, size.width);
                  });
                },
                onHorizontalDragEnd: (details) {
                  final velocity = details.velocity.pixelsPerSecond.dx;
                  if (_dragDx > 100 || velocity > 600) {
                    Navigator.of(context).pop();
                  } else {
                    _animateDragBack();
                  }
                },
                onHorizontalDragCancel: _animateDragBack,
              ),
            ),
        ],
      );
    }

    return Transform.translate(
      offset: Offset(_dragDx + slide, 0),
      child: content,
    );
  }
}
