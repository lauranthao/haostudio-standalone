import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/theme/hao_settle_spring.dart';
import 'music_navigation.dart';
import 'music_player_controller.dart';
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
///   more sheet): the same [PlayerExpandRoute] with a fallback rect —
///   a full-size rect starting just below the screen, so the page
///   slides in from the bottom instead of expanding from a bar.
///   There is no bar to expand from, so no expansion; but the page
///   still gets the route's own close paths (chevron / edge swipe /
///   top-bar swipe-down), so swipe-down close works from every
///   entry, not only from the mini bar (build 28).
///
/// At most ONE player page: if one is already open (or being opened),
/// this is a no-op returning null (see `claimPlayerPage` in
/// music_navigation.dart). Without the guard, the async card taps
/// (heartbeat / FM: search + first URL resolve before the push) stack
/// a second player page when the user taps again, or taps the mini
/// bar, during that window (chen 2026-11-20).
///
/// The route is pushed on the root Navigator. The context is resolved
/// through Get's navigator key first: the overlay bar lives ABOVE the
/// root Navigator (GetMaterialApp `builder`), so its context has no
/// Navigator ancestor and `Navigator.of` throws there ("Navigator
/// operation requested with a context that does not include a
/// Navigator"). Contexts below the Navigator (home bar) resolve the
/// same state through the key, so one path serves both.
Future<T?> openPlayerPage<T>(BuildContext context, {Rect? fromRect}) {
  if (!claimPlayerPage()) return Future<T?>.value(null);
  final state = Get.key.currentState ??
      Navigator.of(context, rootNavigator: true);
  Future<T?> pushed;
  try {
    if (fromRect != null) {
      pushed = state.push<T>(
        PlayerExpandRoute<T>(
          fromRect: fromRect,
          child: const MusicPlayerPage(),
        ),
      );
    } else {
      // No bar rect: same expand route, bottom slide-in fallback
      // (full-size rect starting just below the screen). Only when
      // there is no MediaQuery at all do we fall back to the plain
      // Cupertino slide (N-1: swipe-back, same as every other push).
      final size = MediaQuery.maybeSizeOf(context);
      if (size != null) {
        pushed = state.push<T>(
          PlayerExpandRoute<T>(
            fromRect: Rect.fromLTWH(0, size.height, size.width, size.height),
            child: const MusicPlayerPage(),
          ),
        );
      } else {
        pushed = state.push<T>(
          CupertinoPageRoute<T>(builder: (_) => const MusicPlayerPage()),
        );
      }
    }
  } catch (_) {
    // The push never started: release the claim so a later open works.
    releasePlayerPage();
    rethrow;
  }
  // The claim is held until the route leaves the stack (pop / remove):
  // the push future completes then, and only then may a new player
  // page open.
  unawaited(pushed.whenComplete(releasePlayerPage));
  return pushed;
}

/// The settle spring lives in core/theme/hao_settle_spring.dart now
/// (N-14: the player close animation and the bottom sheets share the
/// one spring). This file uses [HaoSettleSpringCurve] directly.

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
///   left as it goes. 350ms, Kumone settle spring — the same spring
///   as open (N-14), so the close settles with a slight overshoot
///   instead of braking dead like easeOutCubic did. The mini player
///   fades back in via `MiniPlayerOverlay`'s AnimatedSwitcher.
/// - CLOSE (top-bar swipe-down, build 28): same 350ms settle spring,
///   but the page slides DOWN and off instead of right — the finger
///   was moving down, so the close must follow it, not cut across
///   it. The drag offset is carried into the close frame exactly
///   like the edge swipe's `_dragDx` (see below), so there is no
///   snap on release. Pure translation, no scale / corner / fade.
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

  /// Top-bar swipe-down drag offset (px down). 0 unless the user is
  /// dragging the page down from the top bar (build 28). Same pattern
  /// as [_dragDx]: follow the finger, pop past the threshold, spring
  /// back below it. Pure translation — no scale / corner / fade.
  double _dragDy = 0;

  /// True while this close is a swipe-down: the closing branch slides
  /// the page down instead of right. Set just before the pop, so the
  /// reverse animation picks the matching direction from its first
  /// frame; every other close path leaves it false.
  bool _closingDown = false;

  /// Finger position at the start of a top-bar swipe-down, for the
  /// main-direction ruling (|dy| > |dx| * 1.2, same 1.2 coefficient
  /// as the cover's swipe-to-switch in music_player_sheet.dart).
  Offset _dragStartPos = Offset.zero;

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

  /// Same 200ms easeOut return as [_animateDragBack], for [_dragDy].
  void _animateDragDyBack() {
    final start = _dragDy;
    if (start <= 0) return;
    _returnController.reset();
    final anim = Tween<double>(begin: start, end: 0).animate(
      CurvedAnimation(parent: _returnController, curve: Curves.easeOut),
    );
    anim.addListener(() {
      if (mounted) setState(() => _dragDy = anim.value);
    });
    unawaited(_returnController.forward());
  }

  /// Top-bar swipe-down ended: past the edge-swipe thresholds
  /// (100px or 600px/s) the page closes downward; below them it
  /// springs back. Queue first, same priority as the page's
  /// `PopScope` (canPop: !showQueuePanel): a closing swipe with the
  /// queue open closes the queue and springs the page back — the
  /// player itself only closes on the next swipe.
  ///
  /// The queue is read synchronously (not via `maybePop`): the async
  /// pop handshake deferred the spring-back past the test's pump
  /// budget and left the page stranded mid-drag (266.7px in T7).
  /// A sub-threshold drag springs back and leaves the queue alone.
  void _onTopSwipeDownEnd(Velocity velocity) {
    final speed = velocity.pixelsPerSecond.dy;
    if (_dragDy > 100 || speed > 600) {
      final controller = MusicPlayerController.ensure();
      if (controller.showQueuePanel.value) {
        controller.showQueuePanel.value = false;
        _animateDragDyBack();
        return;
      }
      setState(() => _closingDown = true);
      Navigator.of(context).pop();
    } else {
      _animateDragDyBack();
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final fullRect = Offset.zero & size;
    final animation = widget.animation;
    final isClosing = animation.status == AnimationStatus.reverse;

    // Slide on close (0 in every other state). The drag offset is
    // added on top so a finger-released pop starts exactly where the
    // finger left the page — no snap back to full-screen first.
    // Right for chevron / system back / edge swipe, down for a
    // top-bar swipe-down (see [_closingDown]).
    final closeT = isClosing
        ? const HaoSettleSpringCurve().transform(
            (1 - animation.value).clamp(0.0, 1.0),
          )
        : 0.0;
    final slide = _closingDown ? 0.0 : closeT * size.width;
    final slideDown = _closingDown ? closeT * size.height : 0.0;

    Widget content;
    if (isClosing) {
      content = widget.child;
    } else {
      // Expand: spring drives the rect, linear time drives the fades.
      final t = const HaoSettleSpringCurve()
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
          // Top-bar swipe-down close (build 28): SafeArea top →
          // cover top, i.e. the top bar (76pt: 20 + 36 + 20) plus the
          // first flexible gap below it (capped at 24pt). The only
          // clean swipe-down zone — no scroll, no pan, no horizontal
          // drag lives here (the lyrics ListView, the cover pan and
          // the progress scrub each own their own area below it).
          // Taps still reach the chevron / tune buttons: a tap never
          // becomes a drag, so the tap recogniser wins the arena.
          // Only live once the open animation has settled, same gate
          // as the edge strip.
          if (animation.status == AnimationStatus.completed)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: MediaQuery.of(context).padding.top + 76 + 24,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragStart: (details) {
                  _returnController.stop();
                  _dragStartPos = details.globalPosition;
                },
                onVerticalDragUpdate: (details) {
                  final totalDx =
                      (details.globalPosition.dx - _dragStartPos.dx).abs();
                  final totalDy =
                      details.globalPosition.dy - _dragStartPos.dy;
                  // Down only, and only when down is the main
                  // direction (|dy| > |dx| * 1.2) — a sideways or
                  // diagonal drag is not a swipe-down.
                  if (totalDy <= 0 || totalDy <= totalDx * 1.2) return;
                  setState(() {
                    _dragDy = totalDy.clamp(0.0, size.height);
                  });
                },
                onVerticalDragEnd: (details) =>
                    _onTopSwipeDownEnd(details.velocity),
                onVerticalDragCancel: _animateDragDyBack,
              ),
            ),
        ],
      );
    }

    return Transform.translate(
      offset: Offset(_dragDx + slide, _dragDy + slideDown),
      child: content,
    );
  }
}
