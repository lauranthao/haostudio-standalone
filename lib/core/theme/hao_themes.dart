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
// - EXCEPTION (P1-U4): the home feature cards (搜歌 / 歌单广场 / 排行榜 /
//   听歌报告) are Kumone-style coloured artwork, not theme surfaces —
//   their colours are fixed artwork and deliberately do NOT follow the
//   theme. Everything else follows the rules above; do not "fix" the
//   cards to match the theme.
//
// Theme switching takes effect immediately everywhere (ThemeController
// rebuilds the app root with the new ThemeData; no restart, no stale
// cached colours).

import 'dart:ui';

import 'hao_radius.dart';
import 'package:flutter/cupertino.dart';
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

/// Cupertino text theme with [fontFamily] applied to every text
/// slot (body, nav title, large title, tab label, action). Cupertino
/// styles do NOT inherit from each other — setting only `textStyle`
/// leaves the nav title in .SF Pro Text — so each slot is set
/// explicitly, derived from the framework default so size, weight
/// and colour are untouched. Used by the app theme (custom Beans
/// font) and by golden tests (NotoSansSC, whose glyphs the Linux
/// test env can render; .SF Pro Text has no CJK there).
CupertinoThemeData haoCupertinoThemeWithFont(String fontFamily) {
  final defaults = const CupertinoThemeData().textTheme;
  return CupertinoThemeData(
    textTheme: CupertinoTextThemeData(
      textStyle: defaults.textStyle.copyWith(fontFamily: fontFamily),
      navTitleTextStyle:
          defaults.navTitleTextStyle.copyWith(fontFamily: fontFamily),
      navLargeTitleTextStyle: defaults.navLargeTitleTextStyle
          .copyWith(fontFamily: fontFamily),
      tabLabelTextStyle:
          defaults.tabLabelTextStyle.copyWith(fontFamily: fontFamily),
      actionTextStyle:
          defaults.actionTextStyle.copyWith(fontFamily: fontFamily),
    ),
  );
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
    required this.glassIntensity,
    required this.scaffoldBackground,
    required this.tabPill,
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

  /// Liquid-glass intensity (chen 2026-11-21, Settings → 外观 slider):
  /// 1.0 = today's full glass, 0.0 = no glass at all (clear surfaces,
  /// no blur/frost). Scales blur sigma, surface alphas and the library
  /// optics (see HaoLiquidGlass) — never the layout.
  final double glassIntensity;

  final Color scaffoldBackground;

  /// Solid matte colour of the tab-bar resting pill (Muse app bar,
  /// chen 2026-11-20 "一模一样"): light #E4E4E4 measured off the
  /// reference frames (pill 228 on bar 249), dark #3A3A3C, clearly
  /// lighter than every dark scaffold (0–13). Opaque on purpose —
  /// the old colorBurn painter rendered nearly invisible in Skia,
  /// and a matte fill is deterministic in both renderers. Never
  /// black, never faint.
  final Color tabPill;

  static HaoTheme of(BuildContext context) =>
      Theme.of(context).extension<HaoTheme>()!;

  /// Non-throwing read (G-P2-4): the ambient extension when the
  /// ThemeData carries one, else the appleGlass light defaults, so a
  /// widget renders instead of throwing under a bare ThemeData (e.g.
  /// a test harness). Production always carries the extension, so
  /// this path never changes the real look.
  static HaoTheme ofOrDefault(BuildContext context) =>
      Theme.of(context).extension<HaoTheme>() ??
      HaoThemes.of(HaoThemeId.appleGlass).light.extension<HaoTheme>()!;

  /// b28 legibility shadows (build 28 audit §3 scheme A): the
  /// readability treatment for text/icons sitting on glass or bare
  /// wallpaper once the glass intensity fades. The shadow strength is
  /// `(1 - glassIntensity)` — at 100% this returns `[]`, so today's
  /// look is byte-identical; at 0% it is at full strength. Only the
  /// brightness decides the colour (light mode: white halo around
  /// dark text; dark mode: black shadow under light text), never the
  /// theme — the same halo/shadow works for all 4 themes.
  ///
  /// Precedents copied, not estimated: dark shadow black 0.45, offset
  /// (0,1) from the lyric shadow (`music_player_sheet.dart:714`,
  /// blur 8 there; 5 here so small text does not smear — the small
  /// white-on-artwork title at `music_tab_page.dart:1321` uses black
  /// 0.4 blur 2); light halo white 0.55–0.65, blur 4–6, offset 0
  /// (audit §3). Apply with `TextStyle(shadows: ...)` for text and
  /// with `Icon(..., shadows: ...)` for icons — `Icon` takes shadows
  /// natively (Flutter `icon.dart`: `shadows` reaches the same
  /// TextStyle the glyph is drawn with), so no glyph-as-Text widget
  /// and no blurred-ghost layer are needed (T4 probe verdict).
  static List<Shadow> legibilityShadows(
    BuildContext context, {
    double blurRadius = 5.0,
  }) {
    final theme = ofOrDefault(context);
    return legibilityShadowsFor(
      isDark: Theme.of(context).brightness == Brightness.dark,
      intensity: theme.glassIntensity,
      blurRadius: blurRadius,
    );
  }

  /// Pure form of [legibilityShadows] (no [BuildContext]): the
  /// machine-testable core — mode + intensity in, shadows out.
  static List<Shadow> legibilityShadowsFor({
    required bool isDark,
    required double intensity,
    double blurRadius = 5.0,
  }) {
    final strength = 1.0 - intensity.clamp(0.0, 1.0);
    if (strength <= 0.0) return const [];
    return [
      Shadow(
        color: isDark
            ? Colors.black.withValues(alpha: 0.45 * strength)
            : Colors.white.withValues(alpha: 0.60 * strength),
        offset: isDark ? const Offset(0, 1) : Offset.zero,
        blurRadius: blurRadius,
      ),
    ];
  }

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
    double? glassIntensity,
    Color? scaffoldBackground,
    Color? tabPill,
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
      glassIntensity: glassIntensity ?? this.glassIntensity,
      scaffoldBackground: scaffoldBackground ?? this.scaffoldBackground,
      tabPill: tabPill ?? this.tabPill,
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
      glassIntensity:
          glassIntensity + (other.glassIntensity - glassIntensity) * t,
      scaffoldBackground: Color.lerp(
        scaffoldBackground,
        other.scaffoldBackground,
        t,
      )!,
      tabPill: Color.lerp(tabPill, other.tabPill, t)!,
    );
  }
}

/// Frosted-glass strip for sub-page AppBars (N-7, 1.1.6 原生感).
///
/// `AppBarTheme` cannot carry a blur, so sub-page AppBars take this as
/// `flexibleSpace`. It blurs whatever sits behind the bar (the
/// wallpaper while the background is on — the AppBar is transparent
/// then) with the theme's own blur sigma x glass intensity, the same
/// optics as the sheet glass background; it paints no colour of its own,
/// so with the background off (solid-surface AppBar) it is invisible.
/// Title stays 17 w700 (D-1 is about the big title only). All 4 themes
/// x light/dark read the same token, so all 8 combinations get it.
class HaoAppBarGlass extends StatelessWidget {
  const HaoAppBarGlass({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.ofOrDefault(context);
    final intensity = theme.glassIntensity.clamp(0.0, 1.0);
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: theme.glassBlurSigma * intensity,
          sigmaY: theme.glassBlurSigma * intensity,
        ),
        child: const SizedBox.expand(),
      ),
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
  required Color onAccent,
  required Color scaffoldBackground,
  required Color surface,
  required Color surfaceStrong,
  required Color surfaceSolid,
  required Color hairline,
  required Color textPrimary,
  required Color textSecondary,
  required Color textMuted,
  required double glassBlurSigma,
  required double glassIntensity,
  required Color tabPill,
  // True while a custom background (wallpaper / background colour)
  // is active (chen 2026-11-21: 壁纸要到全局）: the scaffold and the
  // app bar go transparent so the app-root background layer shows
  // through on EVERY page, not just the tab roots.
  required bool backgroundActive,
  // Custom font family (stage 2, Beans `FontManager`): null = system
  // default. Passed to the ThemeData constructor so it lands in the
  // default text themes (ThemeData.copyWith has NO fontFamily
  // parameter — a copyWith would silently drop it).
  String? fontFamily,
}) {
  // Red is reserved for the LIVE badge / recording dot only.
  const liveRed = Color(0xFFE5484D);
  // b29-A legibility: text on glass or bare wallpaper loses its
  // backing as glassIntensity fades (the glass fill / blur / border /
  // shadow all scale to zero). Every theme text style therefore
  // carries the same intensity-scaled shadow as
  // HaoTheme.legibilityShadows: [] at 1.0 (today's look
  // byte-identical), full strength at 0%. Explicit call-site
  // TextStyles merge over the ambient DefaultTextStyle (Text.build:
  // defaultTextStyle.style.merge(style)), so the shadow survives
  // unless the call site sets shadows itself. Only brightness
  // decides the colour (light: white halo; dark: black shadow),
  // never the theme.
  final legibility = HaoTheme.legibilityShadowsFor(
    isDark: brightness == Brightness.dark,
    intensity: glassIntensity,
  );
  final colorScheme = ColorScheme(
    brightness: brightness,
    primary: accent,
    onPrimary: onAccent,
    secondary: accent,
    onSecondary: onAccent,
    error: liveRed,
    onError: Colors.white,
    surface: surfaceSolid,
    onSurface: textPrimary,
  );
  return ThemeData(
    brightness: brightness,
    fontFamily: fontFamily,
    // Cupertino surfaces (nav-bar titles, sheet buttons, dialogs)
    // read CupertinoTheme, not the Material text theme — without
    // this a custom Beans font never reaches them (b30: the iOS
    // batch moved 38 AppBars + all sheets to Cupertino, so nav
    // titles stayed in .SF Pro Text while everything else followed
    // the app font; in the Linux test env .SF Pro has no CJK and
    // renders tofu). Null font = no override: device behaviour
    // unchanged, SF Pro + PingFang fallback as before.
    cupertinoOverrideTheme: fontFamily == null
        ? null
        : haoCupertinoThemeWithFont(fontFamily),
    colorScheme: colorScheme,
    scaffoldBackgroundColor:
        backgroundActive ? Colors.transparent : scaffoldBackground,
    primaryColor: accent,
    appBarTheme: AppBarTheme(
      backgroundColor: backgroundActive ? Colors.transparent : surface,
      foregroundColor: textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w700,
        color: textPrimary,
        shadows: legibility,
      ),
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HaoRadius.panel),
        side: BorderSide(color: hairline),
      ),
    ),
    dividerColor: hairline,
    dividerTheme: DividerThemeData(color: hairline, thickness: 1, space: 1),
    // N-16: no Material ripple anywhere (iOS presses dim instead of
    // spreading a wave). NoSplash kills the splash on InkWell /
    // ListTile / buttons app-wide; the press highlight that remains
    // is the dim. HaoPressable (GestureDetector + opacity) is the
    // explicit form for rows that need it; this is the uniform
    // backstop for every ListTile and button.
    splashFactory: NoSplash.splashFactory,
    // Generic list-row typography (settings rows and every other tab's
    // rows share it): title 17/w600 primary, subtitle 13 secondary
    // (N-11 type table: row title 17, footnote 13). Per-row styles
    // that only set a colour inherit size/weight/height from here,
    // so the hierarchy holds in all 8 combinations.
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: textPrimary,
        height: 1.35,
        shadows: legibility,
      ),
      subtitleTextStyle: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: textSecondary,
        height: 1.45,
        shadows: legibility,
      ),
      iconColor: textSecondary,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? colorScheme.onPrimary
            : Colors.white,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? accent
            : textMuted.withValues(alpha: 0.35),
      ),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: accent,
      inactiveTrackColor: textMuted.withValues(alpha: 0.30),
      thumbColor: accent,
      overlayColor: accent.withValues(alpha: 0.14),
      valueIndicatorColor: accent,
      valueIndicatorTextStyle: TextStyle(
        color: colorScheme.onPrimary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        shadows: legibility,
      ),
      trackHeight: 4,
      // N-12: iOS thumb is 28pt across (radius 14); the old 20pt
      // thumb was hard to grab. Shape stays Material (N-12 decision:
      // keep the theme colours, do not switch to CupertinoSlider).
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 14),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: surface,
      selectedColor: accent.withValues(alpha: 0.14),
      checkmarkColor: accent,
      labelStyle: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: textSecondary,
        shadows: legibility,
      ),
      side: BorderSide(color: hairline),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HaoRadius.large)),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      elevation: 0,
      pressElevation: 0,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surfaceSolid,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HaoRadius.sheet)),
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w700,
        color: textPrimary,
        shadows: legibility,
      ),
      contentTextStyle: TextStyle(
        fontSize: 14,
        color: textSecondary,
        height: 1.55,
        shadows: legibility,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              // b29-A buttons: the old disabled fill (textMuted 0.25
              // over the scaffold) is 1.4-1.5:1 against the onPrimary
              // label in 6 of 8 combos — the label vanishes (e.g. the
              // 音源管理 '验证中…' button while a source validates).
              // Opaque composite of textPrimary 0.55 over the
              // scaffold: 3.5-5.9:1 in all 8 combos, and opaque so a
              // bright wallpaper behind it cannot wash it out either.
              // The label colour itself is untouched (still onPrimary).
              ? Color.alphaBlend(
                  textPrimary.withValues(alpha: 0.55),
                  scaffoldBackground,
                )
              : accent,
        ),
        foregroundColor: WidgetStateProperty.all(colorScheme.onPrimary),
        padding: WidgetStateProperty.all(
          const EdgeInsets.symmetric(vertical: 13, horizontal: 20),
        ),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(HaoRadius.large)),
        ),
        textStyle: WidgetStateProperty.all(
          TextStyle(
            fontFamily: fontFamily,
            fontSize: 16,
            fontWeight: FontWeight.w600,
            shadows: legibility,
          ),
        ),
      ),
    ),
    // Build 30: the app had no outlinedButtonTheme, so every
    // OutlinedButton fell back to the M3 default (stadium pill) and
    // each call site restated its own side/radius/padding — the
    // load-more buttons were pills while FilledButtons were radius
    // 12. One outlined system now: hairline side, accent label,
    // radius 12, 14 w600. Sites that only restated these values drop
    // their styleFrom; the two that need a primary-colour label keep
    // a one-prop foregroundColor override.
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        side: WidgetStateProperty.all(BorderSide(color: hairline)),
        foregroundColor: WidgetStateProperty.all(accent),
        padding: WidgetStateProperty.all(
          const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
        ),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(HaoRadius.large)),
        ),
        textStyle: WidgetStateProperty.all(
          TextStyle(
            fontFamily: fontFamily,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            shadows: legibility,
          ),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.all(accent),
        textStyle: WidgetStateProperty.all(
          TextStyle(
            fontFamily: fontFamily,
            fontSize: 15,
            fontWeight: FontWeight.w600,
            shadows: legibility,
          ),
        ),
        padding: WidgetStateProperty.all(
          const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(HaoRadius.large),
        borderSide: BorderSide(color: hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(HaoRadius.large),
        borderSide: BorderSide(color: hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(HaoRadius.large),
        borderSide: BorderSide(color: accent, width: 1.5),
      ),
      hintStyle: TextStyle(
        fontFamily: fontFamily,
        color: textMuted,
        fontSize: 14,
        shadows: legibility,
      ),
      labelStyle: TextStyle(
        fontFamily: fontFamily,
        color: textSecondary,
        fontSize: 14,
        shadows: legibility,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? accent : textMuted,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: accent),
    textTheme: TextTheme(
      bodyLarge: TextStyle(color: textPrimary, shadows: legibility),
      bodyMedium: TextStyle(color: textPrimary, shadows: legibility),
      bodySmall: TextStyle(color: textSecondary, shadows: legibility),
      titleLarge: TextStyle(color: textPrimary, shadows: legibility),
      titleMedium: TextStyle(color: textPrimary, shadows: legibility),
      titleSmall: TextStyle(color: textSecondary, shadows: legibility),
      labelLarge: TextStyle(color: textPrimary, shadows: legibility),
      labelMedium: TextStyle(color: textSecondary, shadows: legibility),
      labelSmall: TextStyle(color: textMuted, shadows: legibility),
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
        glassIntensity: glassIntensity,
        scaffoldBackground: scaffoldBackground,
        tabPill: tabPill,
      ),
    ],
  );
}

/// Text/icon colour on top of a custom accent: white on dark
/// accents, near-black on light ones (same split the gold and
/// mint dark-mode pairs already use for their light accents).
Color _onAccentFor(Color accent) =>
    ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
        ? Colors.white
        : const Color(0xFF0B0B0F);

/// All four themes, each with light + dark. No purple anywhere.
/// Blue -> black (chen 2026-11-18): the two blue/cyan accents
/// (appleGlass, polarIce) are black in light mode and dark grey
/// #76767A in dark mode (black-on-black would be invisible; white
/// text on the grey is ~4.6:1). Gold and mint accents are not blue
/// and are unchanged.
class HaoThemes {
  HaoThemes._();

  static const Map<HaoThemeId, String> names = {
    HaoThemeId.appleGlass: '苹果毛玻璃',
    HaoThemeId.darkGold: '暗夜鎏金',
    HaoThemeId.freshMint: '清新薄荷',
    HaoThemeId.polarIce: '极夜冰蓝',
  };

  /// The user's custom accent (settings -> 自定义强调色) replaces the
  /// per-theme accent in BOTH modes when set; null keeps the
  /// per-theme defaults. Only accent-role usages move: liveRed,
  /// text colours and surfaces are separate slots and never change.
  static HaoThemePair of(
    HaoThemeId id, {
    String? fontFamily,
    Color? accentOverride,
    // Liquid-glass intensity (chen 2026-11-21): 1.0 = today's glass.
    double glassIntensity = 1.0,
    // Custom background active (wallpaper / background colour):
    // scaffolds + app bars go transparent (see _buildThemeData).
    bool backgroundActive = false,
  }) {
    final overrideOnAccent = accentOverride == null
        ? null
        : _onAccentFor(accentOverride);
    switch (id) {
      case HaoThemeId.appleGlass:
        return HaoThemePair(
          light: _buildThemeData(
            brightness: Brightness.light,
            fontFamily: fontFamily,
            accent: accentOverride ?? const Color(0xFF000000),
            onAccent: overrideOnAccent ?? Colors.white,
            scaffoldBackground: const Color(0xFFF2F2F7),
            surface: Colors.white.withValues(alpha: 0.55),
            surfaceStrong: Colors.white.withValues(alpha: 0.68),
            surfaceSolid: Colors.white,
            hairline: Colors.black.withValues(alpha: 0.08),
            textPrimary: const Color(0xFF1C1C1E),
            textSecondary: const Color(0xFF3A3A3C),
            // Light-mode contrast (WCAG, on scaffold #F2F2F7): 4.75:1
            // (was 2.92:1 — below even the 3:1 large-text bar). Dark
            // mode is untouched (7.31:1 already).
            textMuted: const Color(0xFF6B6B70),
            glassBlurSigma: 24,
            glassIntensity: glassIntensity,
            backgroundActive: backgroundActive,
            tabPill: const Color(0xFFE4E4E4),
          ),
          dark: _buildThemeData(
            brightness: Brightness.dark,
            fontFamily: fontFamily,
            accent: accentOverride ?? const Color(0xFF76767A),
            onAccent: overrideOnAccent ?? Colors.white,
            scaffoldBackground: const Color(0xFF000000),
            surface: Colors.white.withValues(alpha: 0.10),
            surfaceStrong: Colors.white.withValues(alpha: 0.16),
            surfaceSolid: const Color(0xFF1C1C1E),
            hairline: Colors.white.withValues(alpha: 0.12),
            textPrimary: const Color(0xFFF5F5F7),
            textSecondary: const Color(0xFFD1D1D6),
            textMuted: const Color(0xFF98989D),
            glassBlurSigma: 24,
            glassIntensity: glassIntensity,
            backgroundActive: backgroundActive,
            tabPill: const Color(0xFF3A3A3C),
          ),
        );
      case HaoThemeId.darkGold:
        return HaoThemePair(
          light: _buildThemeData(
            brightness: Brightness.light,
            fontFamily: fontFamily,
            accent: accentOverride ?? const Color(0xFF9A7B1E),
            onAccent: overrideOnAccent ?? Colors.white,
            scaffoldBackground: const Color(0xFFFAF6EC),
            surface: Colors.white.withValues(alpha: 0.55),
            surfaceStrong: Colors.white.withValues(alpha: 0.68),
            surfaceSolid: const Color(0xFFFFFDF5),
            hairline: const Color(0xFF9A7B1E).withValues(alpha: 0.18),
            textPrimary: const Color(0xFF2A2113),
            textSecondary: const Color(0xFF5C4F33),
            // Light-mode contrast (WCAG, on scaffold #FAF6EC): 4.77:1
            // (was 3.10:1). Same warm-tan hue, only darker. Dark mode
            // untouched (5.88:1 already).
            textMuted: const Color(0xFF7A6C4E),
            glassBlurSigma: 24,
            glassIntensity: glassIntensity,
            backgroundActive: backgroundActive,
            tabPill: const Color(0xFFE4E4E4),
          ),
          dark: _buildThemeData(
            brightness: Brightness.dark,
            fontFamily: fontFamily,
            accent: accentOverride ?? const Color(0xFFD4AF37),
            onAccent: overrideOnAccent ?? const Color(0xFF0B0B0F),
            scaffoldBackground: const Color(0xFF0D0B08),
            surface: Colors.white.withValues(alpha: 0.08),
            surfaceStrong: Colors.white.withValues(alpha: 0.14),
            surfaceSolid: const Color(0xFF1D1A14),
            hairline: const Color(0xFFD4AF37).withValues(alpha: 0.22),
            textPrimary: const Color(0xFFF5EDD6),
            textSecondary: const Color(0xFFD8C9A3),
            textMuted: const Color(0xFF9A8B6B),
            glassBlurSigma: 24,
            glassIntensity: glassIntensity,
            backgroundActive: backgroundActive,
            tabPill: const Color(0xFF3A3A3C),
          ),
        );
      case HaoThemeId.freshMint:
        return HaoThemePair(
          light: _buildThemeData(
            brightness: Brightness.light,
            fontFamily: fontFamily,
            accent: accentOverride ?? const Color(0xFF00897B),
            onAccent: overrideOnAccent ?? Colors.white,
            scaffoldBackground: const Color(0xFFEFFAF6),
            surface: Colors.white.withValues(alpha: 0.55),
            surfaceStrong: Colors.white.withValues(alpha: 0.68),
            surfaceSolid: Colors.white,
            hairline: const Color(0xFF00897B).withValues(alpha: 0.14),
            textPrimary: const Color(0xFF122E29),
            textSecondary: const Color(0xFF3D5A54),
            // Light-mode contrast (WCAG, on scaffold #EFFAF6): 4.76:1
            // (was 2.58:1). Same muted-teal hue, only darker. Dark
            // mode untouched (6.95:1 already).
            textMuted: const Color(0xFF58746D),
            glassBlurSigma: 24,
            glassIntensity: glassIntensity,
            backgroundActive: backgroundActive,
            tabPill: const Color(0xFFE4E4E4),
          ),
          dark: _buildThemeData(
            brightness: Brightness.dark,
            fontFamily: fontFamily,
            accent: accentOverride ?? const Color(0xFF4DD0C4),
            onAccent: overrideOnAccent ?? const Color(0xFF0B0B0F),
            scaffoldBackground: const Color(0xFF07110F),
            surface: Colors.white.withValues(alpha: 0.09),
            surfaceStrong: Colors.white.withValues(alpha: 0.15),
            surfaceSolid: const Color(0xFF122622),
            hairline: Colors.white.withValues(alpha: 0.12),
            textPrimary: const Color(0xFFE6F7F3),
            textSecondary: const Color(0xFFB9D9D2),
            textMuted: const Color(0xFF7FA39B),
            glassBlurSigma: 24,
            glassIntensity: glassIntensity,
            backgroundActive: backgroundActive,
            tabPill: const Color(0xFF3A3A3C),
          ),
        );
      case HaoThemeId.polarIce:
        return HaoThemePair(
          light: _buildThemeData(
            brightness: Brightness.light,
            fontFamily: fontFamily,
            accent: accentOverride ?? const Color(0xFF000000),
            onAccent: overrideOnAccent ?? Colors.white,
            scaffoldBackground: const Color(0xFFEEF6FB),
            surface: Colors.white.withValues(alpha: 0.55),
            surfaceStrong: Colors.white.withValues(alpha: 0.68),
            surfaceSolid: Colors.white,
            hairline: Colors.black.withValues(alpha: 0.14),
            textPrimary: const Color(0xFF0F2436),
            textSecondary: const Color(0xFF3A5568),
            // Light-mode contrast (WCAG, on scaffold #EEF6FB): 4.93:1
            // (was 2.67:1). Same steel-blue hue, only darker. Dark
            // mode untouched (6.76:1 already).
            textMuted: const Color(0xFF4F6E84),
            glassBlurSigma: 24,
            glassIntensity: glassIntensity,
            backgroundActive: backgroundActive,
            tabPill: const Color(0xFFE4E4E4),
          ),
          dark: _buildThemeData(
            brightness: Brightness.dark,
            fontFamily: fontFamily,
            accent: accentOverride ?? const Color(0xFF76767A),
            onAccent: overrideOnAccent ?? Colors.white,
            scaffoldBackground: const Color(0xFF050B12),
            surface: Colors.white.withValues(alpha: 0.08),
            surfaceStrong: Colors.white.withValues(alpha: 0.14),
            surfaceSolid: const Color(0xFF0E1E2E),
            hairline: Colors.white.withValues(alpha: 0.20),
            textPrimary: const Color(0xFFE8F4FC),
            textSecondary: const Color(0xFFB4D2E6),
            textMuted: const Color(0xFF7D9BB0),
            glassBlurSigma: 24,
            glassIntensity: glassIntensity,
            backgroundActive: backgroundActive,
            tabPill: const Color(0xFF3A3A3C),
          ),
        );
    }
  }
}
