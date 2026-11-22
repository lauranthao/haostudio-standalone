// build-29 adoption — design tokens (ported from the glassy spike,
// test/spike_tokens_test.dart, 2026-11-22). Verifies the Style
// Dictionary generated tokens (lib/generated/hao_tokens.dart, built
// by `node tokens/build.mjs` from tokens/hao.tokens.json) match the
// live theme source (lib/core/theme/hao_themes.dart etc.).
//
// Deliberate difference from the spike test: the spike asserted the
// Kumone bottom-bar values (motionSettleSpring* 322.273/29.441 and
// the tab-bar spacing geometry). Those values are VOID since chen
// 2026-11-22 — the Kumone bar is replaced by the Apple-native
// GlassTabBar — so they are NOT asserted as live app values here.
// They still exist in the generated file as frozen history (see the
// VOID note in tokens/hao.tokens.json); the guard test below pins
// that nothing in the tab bar wires them in.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/generated/hao_tokens.dart';

void main() {
  group('design tokens (HaoTokens)', () {
    test('generated colors match the theme source (light + dark)', () {
      final appleLight =
          HaoThemes.of(HaoThemeId.appleGlass).light.extension<HaoTheme>()!;
      final appleDark =
          HaoThemes.of(HaoThemeId.appleGlass).dark.extension<HaoTheme>()!;
      expect(HaoTokens.appleGlassAccent, appleLight.accent);
      expect(HaoTokens.appleGlassAccentDark, appleDark.accent);
      expect(HaoTokens.appleGlassScaffold, appleLight.scaffoldBackground);
      expect(HaoTokens.appleGlassScaffoldDark, appleDark.scaffoldBackground);
      // Alpha-bearing surfaces: the source stores alpha as a double
      // (0.55), DTCG hex quantizes it to 8 bits (0x8C = 140/255 =
      // 0.5490). Max error 0.5/255 — invisible — so compare the 8-bit
      // values, not the doubles.
      expect(
        HaoTokens.appleGlassSurface.toARGB32(),
        appleLight.surface.toARGB32(),
      );
      expect(
        HaoTokens.appleGlassSurfaceDark.toARGB32(),
        appleDark.surface.toARGB32(),
      );
      expect(HaoTokens.appleGlassTextPrimary, appleLight.textPrimary);
      expect(HaoTokens.appleGlassTextPrimaryDark, appleDark.textPrimary);

      final goldDark =
          HaoThemes.of(HaoThemeId.darkGold).dark.extension<HaoTheme>()!;
      expect(HaoTokens.darkGoldAccentDark, goldDark.accent);
      final mintLight =
          HaoThemes.of(HaoThemeId.freshMint).light.extension<HaoTheme>()!;
      expect(HaoTokens.freshMintAccent, mintLight.accent);
      final iceDark =
          HaoThemes.of(HaoThemeId.polarIce).dark.extension<HaoTheme>()!;
      expect(HaoTokens.polarIceScaffoldDark, iceDark.scaffoldBackground);
    });

    test('liveRed, blur, radii and type match the Apple text styles', () {
      expect(HaoTokens.liveRed, const Color(0xFFE5484D));
      expect(HaoTokens.blurGlassBlurSigma, 24.0);
      expect(HaoTokens.radiusBadge, 4.0);
      expect(HaoTokens.radiusSmall, 6.0);
      expect(HaoTokens.radiusStandard, 8.0);
      expect(HaoTokens.radiusLarge, 12.0);
      expect(HaoTokens.radiusPanel, 20.0);
      expect(HaoTokens.radiusSheet, 14.0);
      // Apple HIG text styles (SF, iOS 17): Headline 17/22 semibold,
      // Subheadline 15/20, Footnote 13/18, Large Title 34/41 bold,
      // Title 3 20/25 semibold. Line height = leading / size.
      expect(HaoTokens.fontAppBarTitleSize, 17.0);
      expect(HaoTokens.fontAppBarTitleWeight, 600);
      expect(HaoTokens.fontAppBarTitleLineHeight, 1.29);
      expect(HaoTokens.fontListTileTitleSize, 17.0);
      expect(HaoTokens.fontListTileTitleLineHeight, 1.29);
      expect(HaoTokens.fontListTileSubtitleSize, 13.0);
      expect(HaoTokens.fontListTileSubtitleLineHeight, 1.38);
      expect(HaoTokens.fontDialogTitleWeight, 600);
      expect(HaoTokens.fontDialogContentSize, 15.0);
      expect(HaoTokens.fontDialogContentLineHeight, 1.33);
      expect(HaoTokens.fontSectionTitleSize, 13.0);
      expect(HaoTokens.fontSectionTitleWeight, 400);
      expect(HaoTokens.fontLargeTitleSize, 34.0);
      expect(HaoTokens.fontLargeTitleWeight, 700);
      expect(HaoTokens.fontLargeTitleLineHeight, 1.21);
      expect(HaoTokens.fontTitle3Size, 20.0);
      expect(HaoTokens.fontTitle3Weight, 600);
      expect(HaoTokens.fontTitle3LineHeight, 1.25);
      expect(HaoTokens.sliderTrackHeight, 4.0);
      expect(HaoTokens.sliderThumbRadius, 14.0);
    });

    test('void Kumone tab values are never wired into the tab bar', () {
      // The generated file keeps *TabPill / motionSettleSpring* as
      // frozen history; the tab bar must not reference them (chen
      // 2026-11-22: Kumone bar rules void — Apple-native bar instead).
      // Full-line // comments are stripped first: the header
      // documents the removed numbers (322.273 / 29.441) as history,
      // and that documentation must not trip the guard — only code
      // may not reference them.
      final shell = File('lib/widgets/app_shell.dart').readAsStringSync();
      final code = shell
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      expect(code.contains('TabPill'), isFalse);
      expect(code.contains('SettleSpring'), isFalse);
      expect(code.contains('settleSpring'), isFalse);
      expect(code.contains('322.273'), isFalse);
      expect(code.contains('29.441'), isFalse);
    });
  });
}
