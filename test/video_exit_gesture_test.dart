import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reproduce the VOD player page's exact gesture structure:
/// GestureDetector (opaque, onTap + horizontal/vertical drag handlers)
/// wrapping a Stack whose top bar holds an IconButton back button.
/// Question: does tapping the IconButton fire its onPressed, or does
/// the parent GestureDetector's onTap swallow the tap?
void main() {
  testWidgets('back IconButton inside surface GestureDetector',
      (tester) async {
    var parentTaps = 0;
    var backTaps = 0;
    var dragStarts = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => parentTaps++,
            onHorizontalDragStart: (_) => dragStarts++,
            onHorizontalDragUpdate: (_) {},
            onHorizontalDragEnd: (_) {},
            onHorizontalDragCancel: () {},
            onVerticalDragStart: (_) => dragStarts++,
            onVerticalDragUpdate: (_) {},
            onVerticalDragEnd: (_) {},
            onVerticalDragCancel: () {},
            child: Stack(
              fit: StackFit.expand,
              children: [
                const SizedBox.expand(child: ColoredBox(color: Colors.black)),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(8, 32, 16, 24),
                    child: Row(
                      children: [
                        IconButton(
                          key: const Key('back'),
                          icon: const Icon(Icons.arrow_back),
                          onPressed: () => backTaps++,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('back')));
    await tester.pump();
    // ignore: avoid_print
    print('parentTaps=$parentTaps backTaps=$backTaps dragStarts=$dragStarts');
    expect(backTaps, 1, reason: 'back button onPressed must fire');
  });

  testWidgets('tap on empty video area fires parent onTap only',
      (tester) async {
    var parentTaps = 0;
    var backTaps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => parentTaps++,
            onHorizontalDragStart: (_) {},
            onHorizontalDragUpdate: (_) {},
            onHorizontalDragEnd: (_) {},
            onHorizontalDragCancel: () {},
            onVerticalDragStart: (_) {},
            onVerticalDragUpdate: (_) {},
            onVerticalDragEnd: (_) {},
            onVerticalDragCancel: () {},
            child: Stack(
              fit: StackFit.expand,
              children: [
                const SizedBox.expand(child: ColoredBox(color: Colors.black)),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(8, 32, 16, 24),
                    child: Row(
                      children: [
                        IconButton(
                          key: const Key('back'),
                          icon: const Icon(Icons.arrow_back),
                          onPressed: () => backTaps++,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // Tap the middle of the screen (video area, not the back button).
    await tester.tapAt(const Offset(200, 400));
    await tester.pump();
    // ignore: avoid_print
    print('area: parentTaps=$parentTaps backTaps=$backTaps');
    expect(parentTaps, 1);
    expect(backTaps, 0);
  });
}
