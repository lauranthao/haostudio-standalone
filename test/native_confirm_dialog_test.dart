// showGlassConfirmDialog now routes through NativeDialog.alert
// (build-29 adoption): a real UIAlertController on iOS.
//
// The Linux test host is not iOS, so NativeDialog falls back to a
// Material AlertDialog with the same two actions — these tests prove
// the bool contract (confirm -> true, cancel -> false, custom labels
// pass through) on that fallback. The native alert path runs
// on-device only.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/widgets/glass_dialog.dart';

void main() {
  group('showGlassConfirmDialog', () {
    Future<Completer<bool>> openDialog(
      WidgetTester tester, {
      String confirmLabel = '确定',
      String cancelLabel = '取消',
    }) async {
      final completer = Completer<bool>();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  final result = await showGlassConfirmDialog(
                    context,
                    title: '清除缓存',
                    content: '确定要清除全部缓存吗？',
                    confirmLabel: confirmLabel,
                    cancelLabel: cancelLabel,
                  );
                  completer.complete(result);
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      return completer;
    }

    testWidgets('confirm returns true', (tester) async {
      final completer = await openDialog(tester);
      expect(find.text('清除缓存'), findsOneWidget);
      expect(find.text('确定'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(await completer.future, isTrue);
    });

    testWidgets('cancel returns false', (tester) async {
      final completer = await openDialog(tester);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await completer.future, isFalse);
    });

    testWidgets('custom labels pass through', (tester) async {
      final completer = await openDialog(
        tester,
        confirmLabel: '删除',
        cancelLabel: '算了',
      );
      expect(find.text('删除'), findsOneWidget);
      expect(find.text('算了'), findsOneWidget);
      await tester.tap(find.text('算了'));
      await tester.pumpAndSettle();
      expect(await completer.future, isFalse);
    });
  });
}
