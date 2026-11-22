// build-29 adoption — glassy_ui_ios 0.3.1 verification (ported from
// the glassy spike, test/spike_glassy_test.dart, 2026-11-22).
// Verifies the Dart side of the plugin on this Linux VM (no Xcode
// here, so the Swift side cannot compile here — that waits for
// Codemagic / a real device).
//
// On the Linux test host defaultTargetPlatform is Linux, so the widgets
// render their Material fallback path. The iOS branch is exercised by
// overriding debugDefaultTargetPlatformOverride to iOS, where UiKitView
// renders as a placeholder box in tests and must still build without
// throwing.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glassy_ui_ios/glassy_ui_ios.dart';

void main() {
  group('glassy_ui_ios spike', () {
    testWidgets('GlassSwitch renders Material fallback off-iOS',
        (tester) async {
      var value = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GlassSwitch(
              label: 'Wi-Fi',
              value: value,
              onChanged: (v) => value = v,
            ),
          ),
        ),
      );
      expect(find.byType(Switch), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(value, isTrue);
    });

    testWidgets('GlassSegmentedControl renders Material fallback off-iOS',
        (tester) async {
      var selected = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GlassSegmentedControl(
              items: const [
                NativeItem(title: 'Day'),
                NativeItem(title: 'Week'),
              ],
              selectedIndex: selected,
              onChanged: (i) => selected = i,
            ),
          ),
        ),
      );
      expect(find.byType(SegmentedButton<int>), findsOneWidget);
      await tester.tap(find.text('Week'));
      await tester.pump();
      expect(selected, 1);
    });

    testWidgets('GlassButton renders Material fallback off-iOS',
        (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GlassButton(
              label: 'Continue',
              onPressed: () => tapped = true,
            ),
          ),
        ),
      );
      expect(find.text('Continue'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pump();
      expect(tapped, isTrue);
    });

    testWidgets('GlassTabBar is invisible off-iOS without a fallback',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            bottomNavigationBar: GlassTabBar(
              items: const [
                NativeItem.symbol('Home', 'house.fill'),
                NativeItem.symbol('Profile', 'person.crop.circle.fill'),
              ],
              selectedIndex: 0,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      // navigation.dart:66 — fallback ?? SizedBox.shrink().
      expect(find.byType(SizedBox), findsWidgets);
      expect(find.byType(UiKitView), findsNothing);
    });

    testWidgets('GlassIconButton without fallback is invisible off-iOS',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GlassIconButton(
              icon: const NativeImage.symbol('person.crop.circle'),
              onPressed: () {},
            ),
          ),
        ),
      );
      // GlassIconButton builds via GlassyView (glassy_view.dart:59):
      // off-iOS with no fallback -> SizedBox.shrink(), NOT the
      // NativeComponent placeholder text (that text is only reachable
      // via raw NativeComponent without a fallback).
      expect(find.byType(UiKitView), findsNothing);
      expect(
        find.text('Native components are available on iOS only.'),
        findsNothing,
      );
    });

    testWidgets('GlassIconButton with fallback renders the fallback',
        (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GlassIconButton(
              icon: const NativeImage.symbol('person.crop.circle'),
              onPressed: () => tapped = true,
              fallback: IconButton(
                icon: const Icon(Icons.person),
                onPressed: () => tapped = true,
              ),
            ),
          ),
        ),
      );
      expect(find.byType(IconButton), findsOneWidget);
      await tester.tap(find.byType(IconButton));
      await tester.pump();
      expect(tapped, isTrue);
    });

    testWidgets('iOS branch builds UiKitView without throwing',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GlassSwitch(
              label: 'Wi-Fi',
              value: true,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      expect(find.byType(UiKitView), findsOneWidget);
      // Reset inside the body: the framework verifies foundation
      // debug vars before tearDown callbacks run.
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
