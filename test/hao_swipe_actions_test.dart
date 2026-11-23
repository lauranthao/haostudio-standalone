// HaoSwipeActions (b30) — the grey/red bleed-through fix (b31).
//
// The action buttons sit behind the row; at rest they must NOT be
// mounted at all, because the row is glass (translucent) and the
// grey 更多 + red 删除 buttons bled through the right edge of EVERY
// row in a playlist. Dragging left mounts them; releasing past
// halfway settles open; a full swipe fires the last (destructive)
// action; tapping an action fires it and closes the row.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/widgets/hao_swipe_actions.dart';

void main() {
  Widget pumpRow({required VoidCallback onMore, required VoidCallback onDelete}) {
    return MaterialApp(
      home: Scaffold(
        body: HaoSwipeActions(
          actions: [
            HaoSwipeAction(
              label: '更多',
              color: const Color(0xFF8E8E93),
              onTap: onMore,
            ),
            HaoSwipeAction(
              label: '删除',
              color: const Color(0xFFFF3B30),
              onTap: onDelete,
            ),
          ],
          child: Container(
            height: 64,
            color: Colors.white,
            alignment: Alignment.centerLeft,
            child: const Text('row'),
          ),
        ),
      ),
    );
  }

  testWidgets('at rest the action buttons are not mounted', (tester) async {
    var more = 0;
    var del = 0;
    await tester.pumpWidget(
      pumpRow(onMore: () => more++, onDelete: () => del++),
    );
    await tester.pump();
    expect(find.text('row'), findsOneWidget);
    expect(find.text('更多'), findsNothing);
    expect(find.text('删除'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dragging left mounts the actions and settles open', (
    tester,
  ) async {
    var more = 0;
    var del = 0;
    await tester.pumpWidget(
      pumpRow(onMore: () => more++, onDelete: () => del++),
    );
    await tester.drag(find.text('row'), const Offset(-100, 0));
    await tester.pumpAndSettle();
    expect(find.text('更多'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(more, 0);
    expect(del, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping an action fires it and closes the row', (
    tester,
  ) async {
    var more = 0;
    var del = 0;
    await tester.pumpWidget(
      pumpRow(onMore: () => more++, onDelete: () => del++),
    );
    await tester.drag(find.text('row'), const Offset(-100, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    expect(more, 1);
    expect(del, 0);
    expect(find.text('更多'), findsNothing);
    expect(find.text('删除'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a full swipe fires the last (destructive) action', (
    tester,
  ) async {
    var more = 0;
    var del = 0;
    await tester.pumpWidget(
      pumpRow(onMore: () => more++, onDelete: () => del++),
    );
    await tester.drag(find.text('row'), const Offset(-220, 0));
    await tester.pumpAndSettle();
    expect(del, 1);
    expect(more, 0);
    expect(find.text('删除'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a short drag snaps back closed', (tester) async {
    var more = 0;
    var del = 0;
    await tester.pumpWidget(
      pumpRow(onMore: () => more++, onDelete: () => del++),
    );
    await tester.drag(find.text('row'), const Offset(-30, 0));
    await tester.pumpAndSettle();
    expect(find.text('更多'), findsNothing);
    expect(find.text('删除'), findsNothing);
    expect(more, 0);
    expect(del, 0);
    expect(tester.takeException(), isNull);
  });
}
