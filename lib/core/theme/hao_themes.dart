// HAo Studio themes — 4 themes x light/dark = 8 combinations.
//
// Standing rules (chen 2026-11-16):
// - Every change must be theme-related: all UI uses theme variables, NEVER
//   hardcoded colours. All 4 themes change together and each is verified.
// - Every change works in BOTH light and dark mode, including follow-system.
// - NO purple anywhere in any theme (the rejected neon deep-purple/pink
//   theme is gone; its replacement is deep black + cyan/ice-blue).
// - Less red: red appears ONLY where it truly means something — the LIVE
//   badge and the recording dot. Buttons/active states use the theme's
//   sophisticated accent, never saturated red.
// - Higher transparency: frosted-glass backgrounds (cards, sheets, tab bar,
//   player, settings rows) use lower alpha in all four themes; text stays
//   readable by increasing backdrop blur, never by darkening the background.
//
// Theme switching takes effect immediately everywhere (ThemeController
// rebuilds the app root with the new ThemeData; no restart, no stale
// cached colours).

import 'package:flutter/material.dart';

/// The four HAo Studio themes. Visual style stays HAo Studio's own —
/// Pure Live's functionality is copied, never its look.
enum HaoThemeId {
  /// 苹果毛玻璃 — Apple frosted glass.
  appleGlass,

  /// 暗夜鎏金 — dark gold.
  darkGold,

  /// 清新薄荷 — fresh mint.
  freshMint,

  /// 极夜冰蓝 — polar-night ice blue.
  polarIce,
}

/// Frosted-glass + semantic colours for one theme/mode combination.
/// Read at call sites via `Theme.of(context).extension<HaoTheme>()!` or
/// `HaoTheme.of(context)`. Never hardcode a colour at a call site.
class HaoTheme extends ThemeExtension<HaoTheme> {
  const HaoTheme({
    required this.accent,
    required this.accentSoft,
    required this.surface,
    required this.surfaceStrong,
    required this.surfaceSolid,
    required this.hairline,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.liveRed,
    required this.glassBlurSigma,
    required this.scaffoldBackground,
  });

  /// Sophisticated theme accent for buttons / active states (never red).
  final Color accent;

  /// Low-alpha accent wash (selected rows, progress fill background).
  final Color accentSoft;

  /// Frosted-glass surface: LOW alpha + strong blur (see [glassBlurSigma]).
  final Color surface;

  /// Slightly less transparent glass (sheets, player).
  final Color surfaceStrong;

  /// Opaque surface for places glass cannot be used (menus that must be
  /// fully legible over arbitrary content).
  final Color surfaceSolid;

  /// Hairline divider / border colour.
  final Color hairline;

  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  /// The ONLY red in the app: LIVE badge + recording dot. Never used for
  /// buttons or active states.
  final Color liveRed;

  /// Backdrop blur sigma for frosted glass. Higher transparency is kept
  /// readable by raising blur, never by darkening the background.
  final double glassBlurSigma;

  final Color scaffoldBackground;

  static HaoTheme of(BuildContext context) =>
      Theme.of(context).extension<HaoTheme>()!;

  @override
  HaoTheme copyWith({
    Color? accent,
    Color? accentSoft,
    Color? surface,
    Color? surfaceStrong,
    Color? surfaceSolid,
    Color? hairline,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? liveRed,
    double? glassBlurSigma,
    Color? scaffoldBackground,
  }) {
    return HaoTheme(
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      surface: surface ?? this.surface,
      surfaceStrong: surfaceStrong ?? this.surfaceStrong,
      surfaceSolid: surfaceSolid ?? this.surfaceSolid,
      hairline: hairline ?? this.hairline,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      liveRed: liveRed ?? this.liveRed,
      glassBlurSigma: glassBlurSigma ?? this.glassBlurSigma,
      scaffoldBackground: scaffoldBackground ?? this.scaffoldBackground,
    );
  }

  @override
  HaoTheme lerp(ThemeExtension<HaoTheme>? other, double t) {
    if (other is! HaoTheme) return this;
    return HaoTheme(
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceStrong: Color.lerp(surfaceStrong, other.surfaceStrong, t)!,
      surfaceSolid: Color.lerp(surfaceSolid, other.surfaceSolid, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      liveRed: Color.lerp(liveRed, other.liveRed, t)!,
      glassBlurSigma:
          glassBlurSigma + (other.glassBlurSigma - glassBlurSigma) * t,
      scaffoldBackground:
          Color.lerp(scaffoldBackground, other.scaffoldBackground, t)!,
    );
  }
}

/// One theme's light + dark [ThemeData]. Built from a single accent so the
/// four themes stay coherent across both modes.
class HaoThemePair {
  const HaoThemePair({required this.light, required this.dark});

  final ThemeData light;
  final ThemeData dark;
}

ThemeData _buildThemeData({
  required Brightness brightness,
  required Color accent,
  required Color scaffoldBackground,
  required Color surface,
  required Color surfaceStrong,
  required Color surfaceSolid,
  required Color hairline,
  required Color textPrimary,
  required Color textSecondary,
  required Color textMuted,
  required double glassBlurSigma,
}) {
  final isDark = brightness == Brightness.dark;
  // Red is reserved for the LIVE badge / recording dot only.
  const liveRed = Color(0xFFE5484D);
  final colorScheme = ColorScheme(
    brightness: brightness,
    primary: accent,
    onPrimary: isDark ? const Color(0xFF0B0B0F) : Colors.white,
    secondary: accent,
    onSecondary: isDark ? const Color(0xFF0B0B0F) : Colors.white,
    error: liveRed,
    onError: Colors.white,
    surface: surfaceSolid,
    onSurface: textPrimary,
  );
  return ThemeData(
    brightness: brightness,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: scaffoldBackground,
    primaryColor: accent,
    appBarTheme: AppBarTheme(
      backgroundColor: surface,
      foregroundColor: textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: surface,
      selectedItemColor: accent,
      unselectedItemColor: textMuted,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: hairline),
      ),
    ),
    dividerColor: hairline,
    textTheme: TextTheme(
      bodyLarge: TextStyle(color: textPrimary),
      bodyMedium: TextStyle(color: textPrimary),
      bodySmall: TextStyle(color: textSecondary),
      titleLarge: TextStyle(color: textPrimary),
      titleMedium: TextStyle(color: textPrimary),
      titleSmall: TextStyle(color: textSecondary),
      labelLarge: TextStyle(color: textPrimary),
      labelMedium: TextStyle(color: textSecondary),
      labelSmall: TextStyle(color: textMuted),
    ),
    iconTheme: IconThemeData(color: textPrimary),
    extensions: <ThemeExtension<dynamic>>[
      HaoTheme(
        accent: accent,
        accentSoft: accent.withValues(alpha: 0.14),
        surface: surface,
        surfaceStrong: surfaceStrong,
        surfaceSolid: surfaceSolid,
        hairline: hairline,
        textPrimary: textPrimary,
        textSecondary: textSecondary,
        textMuted: textMuted,
        liveRed: liveRed,
        glassBlurSigma: glassBlurSigma,
        scaffoldBackground: scaffoldBackground,
      ),
    ],
  );
}

/// All four themes, each with light + dark. No purple anywhere.
class HaoThemes {
  HaoThemes._();

  static const Map<HaoThemeId, String> names = {
    HaoThemeId.appleGlass: '苹果毛玻璃',
    HaoThemeId.darkGold: '暗夜鎏金',
    HaoThemeId.freshMint: '清新薄荷',
    HaoThemeId.polarIce: '极夜冰蓝',
  };

  static HaoThemePair of(HaoThemeId id) {
    switch (id) {
      case HaoThemeId.appleGlass:
        return HaoThemePair(
          light: _buildThemeData(
            brightness: Brightness.light,
            accent: const Color(0xFF0A84FF),
            scaffoldBackground: const Color(0xFFF2F2F7),
            surface: Colors.white.withValues(alpha: 0.55),
            surfaceStrong: Colors.white.withValues(alpha: 0.68),
            surfaceSolid: Colors.white,
            hairline: Colors.black.withValues(alpha: 0.08),
            textPrimary: const Color(0xFF1C1C1E),
            textSecondary: const Color(0xFF3A3A3C),
            textMuted: const Color(0xFF8E8E93),
            glassBlurSigma: 24,
          ),
          dark: _buildThemeData(
            brightness: Brightness.dark,
            accent: const Color(0xFF0A84FF),
            scaffoldBackground: const Color(0xFF000000),
            surface: Colors.white.withValues(alpha: 0.10),
            surfaceStrong: Colors.white.withValues(alpha: 0.16),
            surfaceSolid: const Color(0xFF1C1C1E),
            hairline: Colors.white.withValues(alpha: 0.12),
            textPrimary: const Color(0xFFF5F5F7),
            textSecondary: const Color(0xFFD1D1D6),
            textMuted: const Color(0xFF98989D),
            glassBlurSigma: 24,
          ),
        );
      case HaoThemeId.darkGold:
        return HaoThemePair(
          light: _buildThemeData(
            brightness: Brightness.light,
            accent: const Color(0xFF9A7B1E),
            scaffoldBackground: const Color(0xFFFAF6EC),
            surface: Colors.white.withValues(alpha: 0.55),
            surfaceStrong: Colors.white.withValues(alpha: 0.68),
            surfaceSolid: const Color(0xFFFFFDF5),
            hairline: const Color(0xFF9A7B1E).withValues(alpha: 0.18),
            textPrimary: const Color(0xFF2A2113),
            textSecondary: const Color(0xFF5C4F33),
            textMuted: const Color(0xFF9A8B6B),
            glassBlurSigma: 24,
          ),
          dark: _buildThemeData(
            brightness: Brightness.dark,
            accent: const Color(0xFFD4AF37),
            scaffoldBackground: const Color(0xFF0D0B08),
            surface: Colors.white.withValues(alpha: 0.08),
            surfaceStrong: Colors.white.withValues(alpha: 0.14),
            surfaceSolid: const Color(0xFF1D1A14),
            hairline: const Color(0xFFD4AF37).withValues(alpha: 0.22),
            textPrimary: const Color(0xFFF5EDD6),
            textSecondary: const Color(0xFFD8C9A3),
            textMuted: const Color(0xFF9A8B6B),
            glassBlurSigma: 24,
          ),
        );
      case HaoThemeId.freshMint:
        return HaoThemePair(
          light: _buildThemeData(
            brightness: Brightness.light,
            accent: const Color(0xFF00897B),
            scaffoldBackground: const Color(0xFFEFFAF6),
            surface: Colors.white.withValues(alpha: 0.55),
            surfaceStrong: Colors.white.withValues(alpha: 0.68),
            surfaceSolid: Colors.white,
            hairline: const Color(0xFF00897B).withValues(alpha: 0.14),
            textPrimary: const Color(0xFF122E29),
            textSecondary: const Color(0xFF3D5A54),
            textMuted: const Color(0xFF7FA39B),
            glassBlurSigma: 24,
          ),
          dark: _buildThemeData(
            brightness: Brightness.dark,
            accent: const Color(0xFF4DD0C4),
            scaffoldBackground: const Color(0xFF07110F),
            surface: Colors.white.withValues(alpha: 0.09),
            surfaceStrong: Colors.white.withValues(alpha: 0.15),
            surfaceSolid: const Color(0xFF122622),
            hairline: Colors.white.withValues(alpha: 0.12),
            textPrimary: const Color(0xFFE6F7F3),
            textSecondary: const Color(0xFFB9D9D2),
            textMuted: const Color(0xFF7FA39B),
            glassBlurSigma: 24,
          ),
        );
      case HaoThemeId.polarIce:
        return HaoThemePair(
          light: _buildThemeData(
            brightness: Brightness.light,
            accent: const Color(0xFF0284C7),
            scaffoldBackground: const Color(0xFFEEF6FB),
            surface: Colors.white.withValues(alpha: 0.55),
            surfaceStrong: Colors.white.withValues(alpha: 0.68),
            surfaceSolid: Colors.white,
            hairline: const Color(0xFF0284C7).withValues(alpha: 0.14),
            textPrimary: const Color(0xFF0F2436),
            textSecondary: const Color(0xFF3A5568),
            textMuted: const Color(0xFF7D9BB0),
            glassBlurSigma: 24,
          ),
          dark: _buildThemeData(
            brightness: Brightness.dark,
            accent: const Color(0xFF38BDF8),
            scaffoldBackground: const Color(0xFF050B12),
            surface: Colors.white.withValues(alpha: 0.08),
            surfaceStrong: Colors.white.withValues(alpha: 0.14),
            surfaceSolid: const Color(0xFF0E1E2E),
            hairline: const Color(0xFF38BDF8).withValues(alpha: 0.20),
            textPrimary: const Color(0xFFE8F4FC),
            textSecondary: const Color(0xFFB4D2E6),
            textMuted: const Color(0xFF7D9BB0),
            glassBlurSigma: 24,
          ),
        );
    }
  }
}
