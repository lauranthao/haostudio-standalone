// GlassCard / GlassPressScale tests (Beans liquid-glass system,
// ported through the theme layer).
//
// GlassCard must derive everything from the active HaoTheme — fill
// from theme.surface, border from theme.hairline, blur sigma from
// theme.glassBlurSigma, shadow black alpha by brightness — never a
// hardcoded Beans colour. The blur itself is set in code from the
// theme value, so this test asserts the observable surface: the
// BackdropFilter exists, the border is the theme hairline, the
// radius is the requested one, and the top highlight gradient is
// present.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    hide GlassCard, GlassShadow;
import 'package:standalone/core/theme/glass.dart';
import 'package:standalone/core/theme/hao_themes.dart';

void main() {
  Future<void> pumpCard(
    WidgetTester tester, {
    double radius = 20,
    GlassShadow shadow = GlassShadow.card,
    GlassCardQuality quality = GlassCardQuality.frosted,
  }) async {
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: Scaffold(
          body: Center(
            child: GlassCard(
              radius: radius,
              shadow: shadow,
              quality: quality,
              child: const Text('glass'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('GlassCard', () {
    testWidgets('blur filter + hairline border + radius + highlight', (
      tester,
    ) async {
      await pumpCard(tester);
      final theme = HaoTheme.of(tester.element(find.text('glass')));

      // One BackdropFilter doing the frosted blur.
      expect(find.byType(BackdropFilter), findsOneWidget);

      // The glass container: theme surface fill, hairline border,
      // requested radius. (The outer shadow box is a separate
      // Container with only a boxShadow, and the top highlight is a
      // sibling DecoratedBox inside the Stack — so border + surface
      // picks the glass fill.)
      final containers = find.descendant(
        of: find.byType(GlassCard),
        matching: find.byWidgetPredicate((w) {
          if (w is Container) {
            final d = w.decoration;
            return d is BoxDecoration &&
                d.borderRadius == BorderRadius.circular(20) &&
                d.border != null &&
                d.color == theme.surface;
          }
          return false;
        }),
      );
      expect(containers, findsOneWidget);
      final deco =
          (tester.widget<Container>(containers).decoration as BoxDecoration);
      expect(deco.color, theme.surface);
      expect(deco.border, isA<Border>());
      final border = deco.border as Border;
      expect(border.top.color, theme.hairline);
      // Top highlight gradient lives in a sibling DecoratedBox.
      final highlights = find.descendant(
        of: find.byType(GlassCard),
        matching: find.byWidgetPredicate((w) {
          if (w is DecoratedBox) {
            final d = w.decoration;
            return d is BoxDecoration && d.gradient != null;
          }
          return false;
        }),
      );
      expect(highlights, findsOneWidget);
    });

    testWidgets('panel shadow is stronger than card shadow', (tester) async {
      // Two DecoratedBoxes live under a GlassCard (the outer shadow
      // box + the glass Container's own); the outer one comes first.
      DecoratedBox outerShadow() => tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(GlassCard),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      await pumpCard(tester, shadow: GlassShadow.card);
      final cardBlur =
          ((outerShadow().decoration as BoxDecoration).boxShadow!.single)
              .blurRadius;

      await pumpCard(tester, shadow: GlassShadow.panel);
      final panelBlur =
          ((outerShadow().decoration as BoxDecoration).boxShadow!.single)
              .blurRadius;
      expect(panelBlur, greaterThan(cardBlur));
    });

    testWidgets('no shadow means no DecoratedBox shadow', (tester) async {
      await pumpCard(tester, shadow: GlassShadow.none);
      final decorated = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(GlassCard),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect((decorated.decoration as BoxDecoration).boxShadow, isNull);
    });

    testWidgets('standard renders library glass, no BackdropFilter', (
      tester,
    ) async {
      await pumpCard(tester, quality: GlassCardQuality.standard);
      // Library branch: a GlassContainer (ios27 preset, own layer),
      // and no hand-rolled BackdropFilter anywhere under the card.
      expect(find.byType(GlassContainer), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
      // Same Beans card shadow as the frosted branch.
      expect(tester.takeException(), isNull);
    });

    testWidgets('premium renders library glass with premium floor', (
      tester,
    ) async {
      await pumpCard(tester, quality: GlassCardQuality.premium);
      expect(find.byType(GlassContainer), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byType(GlassAdaptiveScope), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('frosted is the default (no quality arg)', (tester) async {
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: const Scaffold(
            body: Center(
              child: GlassCard(child: Text('glass')),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(find.byType(GlassContainer), findsNothing);
    });
  });

  group('GlassPressScale', () {
    testWidgets('press scales to 0.97, release returns to 1.0', (tester) async {
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: const Scaffold(
            body: Center(
              child: GlassPressScale(
                child: SizedBox(width: 100, height: 40, child: Text('tap')),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
        1.0,
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('tap')),
      );
      await tester.pump();
      expect(
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
        0.97,
      );
      await gesture.up();
      await tester.pump();
      expect(
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
        1.0,
      );
    });
  });
}
