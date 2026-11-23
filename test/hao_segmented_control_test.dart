// N-9 / N-13: HaoSegmentedControl — sliding pill + select haptic.
// - Tapping a segment calls onChanged with its value (and only when
//   the value actually changes).
// - The selected label is accent; the others are secondary.
// - A selectionClick haptic fires on change (mocked platform channel).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/widgets/hao_segmented_control.dart';

void main() {
  testWidgets('tap changes selection, pill follows, haptic fires',
      (tester) async {
    final hapticCalls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      hapticCalls.add('${call.method}:${call.arguments}');
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    HaoHaptics.debugEnabledOverride = true;
    addTearDown(() => HaoHaptics.debugEnabledOverride = null);

    String selected = 'a';
    late StateSetter setState;
    await tester.pumpWidget(
      MaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setter) {
              setState = setter;
              return HaoSegmentedControl<String>(
                segments: const [
                  HaoSegment(value: 'a', label: '甲'),
                  HaoSegment(value: 'b', label: '乙'),
                  HaoSegment(value: 'c', label: '丙'),
                ],
                value: selected,
                onChanged: (v) => setState(() => selected = v),
              );
            },
          ),
        ),
      ),
    );

    // Initially 甲 is selected (textPrimary, not accent: F1 — the
    // selected label must stay readable in dark mode, where accent is
    // darker than the text), 乙/丙 are secondary.
    final theme = HaoThemes.of(HaoThemeId.appleGlass).light.extension<HaoTheme>()!;
    Text textOf(String label) => tester.widget<Text>(find.text(label));
    expect(textOf('甲').style?.color, theme.textPrimary);
    expect(textOf('乙').style?.color, theme.textSecondary);

    await tester.tap(find.text('乙'));
    await tester.pumpAndSettle();
    expect(selected, 'b');
    expect(textOf('乙').style?.color, theme.textPrimary);
    expect(textOf('甲').style?.color, theme.textSecondary);
    // One selectionClick for the change.
    expect(
      hapticCalls.where((c) => c.contains('selectionClick')).length,
      1,
    );

    // Tapping the already-selected segment fires nothing.
    await tester.tap(find.text('乙'));
    await tester.pump();
    expect(selected, 'b');
    expect(
      hapticCalls.where((c) => c.contains('selectionClick')).length,
      1,
    );
  });
}
