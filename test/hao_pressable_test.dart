import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/widgets/hao_pressable.dart';

void main() {
  testWidgets('tap fires onTap', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HaoPressable(
            onTap: () => tapped++,
            child: const Text('row'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('row'));
    await tester.pump();
    expect(tapped, 1);
  });

  testWidgets('long-press fires onLongPress, not onTap', (tester) async {
    var tapped = 0;
    var longPressed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HaoPressable(
            onTap: () => tapped++,
            onLongPress: () => longPressed++,
            child: const Text('row'),
          ),
        ),
      ),
    );
    await tester.longPress(find.text('row'));
    await tester.pump();
    expect(longPressed, 1);
    expect(tapped, 0);
  });

  testWidgets('press dims the child and releases back', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HaoPressable(
            onTap: () {},
            child: const Text('row'),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(tester.getCenter(find.text('row')));
    await tester.pump(const Duration(milliseconds: 150));
    final pressed = tester.widget<AnimatedOpacity>(
      find.byType(AnimatedOpacity),
    );
    expect(pressed.opacity, 0.6);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 150));
    final released = tester.widget<AnimatedOpacity>(
      find.byType(AnimatedOpacity),
    );
    expect(released.opacity, 1.0);
  });
}
