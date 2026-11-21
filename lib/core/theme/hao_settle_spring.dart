// Kumone settle spring as a shared curve (N-14, 1.1.6 原生感).
//
// GlassTabBar.swift:36 — `Animation.spring(response: 0.35,
// dampingFraction: 0.82)`; the same numbers as
// `GlassTabBarState.settleSpring` in app_shell.dart and the former
// private `_SettleSpringCurve` in player_expand_route.dart (moved
// here so the player close animation AND the bottom sheets share the
// one spring instead of each inventing its own).
// ω = 2π / 0.35, stiffness = ω², damping = 2 · 0.82 · ω, mass 1.
// Underdamped (ζ = 0.82 < 1): fast ease-out with a ~1% overshoot,
// then it settles instead of stopping dead.
//
// The curve is normalised by the spring's value at 0.4s (the player
// route's forward duration), so transform(1) is exactly 1: a sheet
// or page driven by this curve lands exactly at rest with no hairline
// of the page below showing at the edges. The 0.4s normalisation is
// only a shape constant — the curve works at any real duration.

import 'package:flutter/animation.dart';
import 'package:flutter/physics.dart';

/// Kumone settle spring (response 0.35, dampingFraction 0.82).
class HaoSettleSpringCurve extends Curve {
  const HaoSettleSpringCurve();

  static final _sim = SpringSimulation(
    const SpringDescription(mass: 1.0, stiffness: 322.273, damping: 29.441),
    0.0,
    1.0,
    0.0,
  );

  /// The spring at 0.4s (the route's forward duration). The raw
  /// simulation does not land on exactly 1.0 there, so the curve is
  /// normalised by it — transform(1) is exactly 1.
  static final double _end = _sim.x(0.4);

  @override
  double transform(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    return (_sim.x(t * 0.4) / _end).clamp(0.0, 1.0);
  }
}
