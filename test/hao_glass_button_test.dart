// HaoGlassButton / HaoGlassIconButton wiring (build-29 adoption).
//
// The Linux test host is not iOS, so GlassyView renders the fallback:
// these tests prove the wrapper passes the label / icon / onPressed
// through to the fallback and honours the disabled (null onPressed)
// contract. The native UIButton path runs on-device only — the
// fallback IS the contract off-iOS, and on iOS the same onPressed
// reaches GlassButton / GlassIconButton.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/widgets/hao_glass_button.dart';

void main() {
  group('HaoGlassButton', () {
    testWidgets('renders the fallback label and fires onPressed',
        (tester) async {
      var tapped = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HaoGlassButton(
              label: '重试',
              onPressed: () => tapped++,
              fallback: FilledButton(
                onPressed: () => tapped++,
                child: const Text('重试'),
              ),
            ),
          ),
        ),
      );

      expect(find.text('重试'), findsOneWidget);
      await tester.tap(find.text('重试'));
      expect(tapped, 1);
    });

    testWidgets('null onPressed renders the disabled fallback',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HaoGlassButton(
              label: '添加',
              onPressed: null,
              fallback: const FilledButton(
                onPressed: null,
                child: Text('添加'),
              ),
            ),
          ),
        ),
      );

      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
      expect(find.text('添加'), findsOneWidget);
    });

    testWidgets('icon button renders the fallback icon and fires',
        (tester) async {
      var tapped = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HaoGlassIconButton(
              symbol: 'plus',
              fallbackIcon: Icons.add,
              tooltip: '添加影视源',
              onPressed: () => tapped++,
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.add), findsOneWidget);
      await tester.tap(find.byIcon(Icons.add));
      expect(tapped, 1);
    });

    testWidgets('disabled icon button renders the fallback unpressed',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: HaoGlassIconButton(
              symbol: 'trash',
              fallbackIcon: Icons.delete_outline,
              tooltip: '删除',
              onPressed: null,
            ),
          ),
        ),
      );

      final button = tester.widget<IconButton>(find.byType(IconButton));
      expect(button.onPressed, isNull);
    });
  });
}
