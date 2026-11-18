// Regression test (chen 2026-11-18): the glass confirm dialog's title and
// content must not show the framework's fallback text style (double
// yellow underline). Root cause: the dialog route has no Material
// ancestor, so Text fell back to the debug style (red monospace 48pt +
// double yellow underline); the dialog's own styles override colour /
// size / weight but not decoration, so the underline leaked through.
// Fix: showGlassDialog wraps its content in Material(transparency).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/widgets/glass_dialog.dart';

void main() {
  testWidgets('confirm dialog text has no fallback underline', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showGlassConfirmDialog(
              context,
              title: '删除歌单',
              content: '确定删除这个歌单吗？里面的歌也会一起删除。',
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    for (final label in <String>[
      '删除歌单',
      '确定删除这个歌单吗？里面的歌也会一起删除。',
    ]) {
      final rich = tester.widget<RichText>(
        find.descendant(
          of: find.text(label),
          matching: find.byType(RichText),
        ),
      );
      final decoration = rich.text.style?.decoration;
      expect(
        decoration?.contains(TextDecoration.underline),
        isNot(true),
        reason: '$label must not inherit the fallback underline',
      );
    }
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('确定'), findsOneWidget);
  });
}
