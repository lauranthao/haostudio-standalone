// N-15: HaoSearchField — centred placeholder while idle, left-aligned
// hint + 取消 button while focused, × clear button when text present.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/widgets/hao_search_field.dart';

void main() {
  testWidgets('placeholder centred when idle, cancel appears on focus',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    final changed = <String>[];
    String? submitted;
    var cancelled = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: Scaffold(
          body: HaoSearchField(
            controller: controller,
            focusNode: focusNode,
            hintText: '搜索歌曲 / 歌手…',
            onChanged: changed.add,
            onSubmitted: (v) => submitted = v,
            onCancel: () => cancelled = true,
          ),
        ),
      ),
    );

    // Idle: placeholder visible, no 取消, no clear button.
    expect(find.text('搜索歌曲 / 歌手…'), findsOneWidget);
    expect(find.text('取消'), findsNothing);
    expect(
      find.byIcon(CupertinoIcons.clear_circled_solid),
      findsNothing,
    );

    // Focus: 取消 slides in on the right.
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);
    expect(find.text('取消'), findsOneWidget);

    // Type: clear button appears, onChanged fires.
    await tester.enterText(find.byType(TextField), '周杰伦');
    await tester.pump();
    expect(changed, contains('周杰伦'));
    expect(
      find.byIcon(CupertinoIcons.clear_circled_solid),
      findsOneWidget,
    );

    // Submit via the keyboard search action.
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(submitted, '周杰伦');

    // × clears the text and notifies.
    await tester.tap(find.byIcon(CupertinoIcons.clear_circled_solid));
    await tester.pump();
    expect(controller.text, isEmpty);
    expect(changed.last, '');

    // 取消 clears, unfocuses and calls the caller's onCancel.
    await tester.enterText(find.byType(TextField), '林俊杰');
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(controller.text, isEmpty);
    expect(focusNode.hasFocus, isFalse);
    expect(find.text('取消'), findsNothing);
    expect(cancelled, isTrue);
    expect(changed.last, '');
  });
}
