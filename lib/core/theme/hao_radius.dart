// Unified corner-radius scale (P1-U3).
//
// Kumone's five steps, plus the sheet step. Every `BorderRadius.circular`
// in the app must use one of these — no ad-hoc numbers. Mapping from the
// old scattered values (fixed 2026-11-21, do not invent new steps):
// 2 -> badge, 4 -> badge, 6 -> small, 8 -> standard, 9 -> standard,
// 10 -> standard, 12 -> large, 16 -> large, 18 -> panel,
// 20 -> panel, 22 -> panel, 24 -> sheet, 28 -> sheet, 999 (pill) stays
// a literal 999 wherever it appears.

/// Corner radii for the whole app (logical pixels).
class HaoRadius {
  HaoRadius._();

  /// Badge / tiny chips.
  static const double badge = 4;

  /// Small controls, compact covers.
  static const double small = 6;

  /// Standard rows, buttons, small cards.
  static const double standard = 8;

  /// Large cards, list rows.
  static const double large = 12;

  /// Panels, cards, floating bars (also the `GlassCard` default).
  static const double panel = 20;

  /// Bottom sheets (D-7, 2026-11-22: unified top corner 14 — the iOS
  /// card-sheet radius, down from 24).
  static const double sheet = 14;
}
