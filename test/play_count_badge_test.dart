// PlayCountBadge tests (Kumone P2).
//
// Coverage per the brief:
// - formatter: zh + non-zh branches, boundary values, big numbers
//   (Kumone Formatters.playCount, Models.swift:486-513).
// - widget: 4 themes x light/dark, three cases — with data, no data
//   (count 0 renders nothing), big-number abbreviation.
// - legibility: WCAG contrast of the white text over the badge scrim
//   composited on the lightest scaffold of each theme (>= 4.5:1).
//   This locks the 0.65 scrim (see play_count_badge.dart header:
//   Kumone's 0.35 over a light scaffold is ~2.4:1, unreadable).
//
// No golden harness for this widget: the repo's golden tests
// (test/render_*_test.dart + test/goldens/) are page-level render
// shots for chen to look at, not widget regressions — so this file
// is widget tests only, asserting structure + values instead of
// pixels.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/widgets/play_count_badge.dart';

void main() {
  group('PlayCountBadge.format', () {
    test('zh: raw below 1万', () {
      expect(PlayCountBadge.format(0, useChineseUnits: true), '0');
      expect(PlayCountBadge.format(999, useChineseUnits: true), '999');
      expect(PlayCountBadge.format(9999, useChineseUnits: true), '9999');
    });

    test('zh: 万 boundary + abbreviation', () {
      // Kumone switch: 10_000... -> "%.1f万".
      expect(PlayCountBadge.format(10000, useChineseUnits: true), '1.0万');
      expect(PlayCountBadge.format(123456, useChineseUnits: true), '12.3万');
      expect(PlayCountBadge.format(99999999, useChineseUnits: true), '10000.0万');
    });

    test('zh: 亿 boundary + abbreviation', () {
      // Kumone switch: 100_000_000... -> "%.1f亿".
      expect(
        PlayCountBadge.format(100000000, useChineseUnits: true),
        '1.0亿',
      );
      expect(
        PlayCountBadge.format(123456789, useChineseUnits: true),
        '1.2亿',
      );
      expect(
        PlayCountBadge.format(250000000, useChineseUnits: true),
        '2.5亿',
      );
    });

    test('non-zh: K/M/B thresholds', () {
      expect(PlayCountBadge.format(9999, useChineseUnits: false), '9999');
      expect(PlayCountBadge.format(10000, useChineseUnits: false), '10.0K');
      expect(
        PlayCountBadge.format(1234567, useChineseUnits: false),
        '1.2M',
      );
      expect(
        PlayCountBadge.format(2500000000, useChineseUnits: false),
        '2.5B',
      );
    });
  });

  group('PlayCountBadge widget', () {
    Future<void> pumpBadge(
      WidgetTester tester, {
      required int count,
      required ThemeData theme,
      Locale locale = const Locale('zh', 'CN'),
    }) async {
      // Plain MaterialApp: the badge has no Get dependency.
      //
      // Locale is driven by the DEVICE locale (PlatformDispatcher),
      // not by the app widget's locale: the app has no
      // flutter_localizations / supportedLocales wiring, so
      // Localizations.localeOf would resolve to en_US even on a
      // Chinese phone. The test fakes the device locale with
      // localeTestValue and clears it afterwards.
      tester.platformDispatcher.localeTestValue = locale;
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Center(child: PlayCountBadge(count: count)),
          ),
        ),
      );
      await tester.pump();
    }

    // 4 themes x light/dark, three cases each.
    for (final id in HaoThemeId.values) {
      for (final mode in const ['light', 'dark']) {
        final pair = HaoThemes.of(id);
        final theme = mode == 'light' ? pair.light : pair.dark;
        group('${HaoThemes.names[id]} $mode', () {
          testWidgets('with data: renders icon + abbreviated count', (
            tester,
          ) async {
            await pumpBadge(tester, count: 123456, theme: theme);
            expect(find.text('12.3万'), findsOneWidget);
            expect(find.byIcon(Icons.play_arrow), findsOneWidget);
            // Kumone's ultraThinMaterial layer -> DarkGlass blur.
            expect(find.byType(BackdropFilter), findsOneWidget);
            // Kumone values: text 10 semibold white, icon 8.
            final text = tester.widget<Text>(find.text('12.3万'));
            expect(text.style?.fontSize, 10);
            expect(text.style?.fontWeight, FontWeight.w600);
            expect(text.style?.color, Colors.white);
            final icon = tester.widget<Icon>(find.byIcon(Icons.play_arrow));
            expect(icon.size, 8);
            expect(icon.color, Colors.white);
            expect(tester.takeException(), isNull);
          });

          testWidgets('no data: count 0 renders nothing', (tester) async {
            await pumpBadge(tester, count: 0, theme: theme);
            expect(find.byType(Text), findsNothing);
            expect(find.byIcon(Icons.play_arrow), findsNothing);
            expect(find.byType(BackdropFilter), findsNothing);
            expect(tester.takeException(), isNull);
          });

          testWidgets('big number: 亿 abbreviation', (tester) async {
            await pumpBadge(tester, count: 123456789, theme: theme);
            expect(find.text('1.2亿'), findsOneWidget);
            expect(tester.takeException(), isNull);
          });
        });
      }
    }

    testWidgets('non-zh locale uses K/M/B units', (tester) async {
      await pumpBadge(
        tester,
        count: 1234567,
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        locale: const Locale('en', 'US'),
      );
      expect(find.text('1.2M'), findsOneWidget);
    });
  });

  group('PlayCountBadge legibility', () {
    // WCAG relative luminance + contrast ratio, computed in-test so
    // the 0.65 scrim is pinned by a number, not by eyeballing.
    double luminance(Color c) {
      double channel(double v) {
        v /= 255;
        return v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
      }

      final r = channel(c.r * 255);
      final g = channel(c.g * 255);
      final b = channel(c.b * 255);
      return 0.2126 * r + 0.7152 * g + 0.0722 * b;
    }

    double contrast(Color a, Color b) {
      final l1 = luminance(a);
      final l2 = luminance(b);
      final hi = math.max(l1, l2);
      final lo = math.min(l1, l2);
      return (hi + 0.05) / (lo + 0.05);
    }

    // Black scrim composited over a background colour.
    Color composite(Color scrim, Color bg) {
      final a = scrim.a;
      int mix(double s, double b) =>
          ((s * a + b * (1 - a)) * 255).round();
      return Color.fromARGB(
        255,
        mix(scrim.r, bg.r),
        mix(scrim.g, bg.g),
        mix(scrim.b, bg.b),
      );
    }

    test('white text on scrim >= 4.5:1 over every light scaffold', () {
      // The badge's scrim, as built by the widget.
      const scrim = Color.fromRGBO(0, 0, 0, 0.65);
      // Lightest scaffold of each theme (hao_themes.dart) + pure
      // white as the absolute worst case.
      const backgrounds = [
        Color(0xFFF2F2F7), // appleGlass light
        Color(0xFFFAF6EC), // darkGold light
        Color(0xFFEFFAF6), // freshMint light
        Color(0xFFEEF6FB), // polarIce light
        Color(0xFFFFFFFF), // worst case
      ];
      for (final bg in backgrounds) {
        final ratio = contrast(Colors.white, composite(scrim, bg));
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason: 'white on 0.65 scrim over $bg: $ratio',
        );
      }
    });

    test('Kumone 0.35 scrim would FAIL on a light scaffold (why 0.65)', () {
      const scrim035 = Color.fromRGBO(0, 0, 0, 0.35);
      final ratio = contrast(
        Colors.white,
        composite(scrim035, const Color(0xFFF2F2F7)),
      );
      // Documents the deviation: 0.35 is ~2.4:1, below AA.
      expect(ratio, lessThan(4.5));
    });
  });
}
