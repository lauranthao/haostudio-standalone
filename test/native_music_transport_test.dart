// Adoption — NativeMusicTransport fallback (build 29).
//
// The SwiftUI view cannot run in a widget test (no iOS engine), so
// this file pins the contract the player page depends on:
//   - with nativeEnabled false (the default) AND with it true on a
//     non-iOS host, the widget renders the [fallback] row verbatim
//     and every native tap action routes to onAction.
//   - the native view is full-width, 64pt tall (the play slot's
//     height), so no MethodChannel size negotiation is ever needed.
// The native side itself is uncompiled here (no Xcode on the VM);
// Codemagic must build ios/Runner/MusicTransportPlugin.swift +
// the AppDelegate registration before the page flips the flag.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/widgets/native_music_transport.dart';

void main() {
  Widget fallbackRow(ValueChanged<MusicTransportAction> onAction) {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.skip_previous),
          onPressed: () => onAction(MusicTransportAction.prev),
        ),
        IconButton(
          icon: const Icon(Icons.play_arrow),
          onPressed: () => onAction(MusicTransportAction.playPause),
        ),
        IconButton(
          icon: const Icon(Icons.skip_next),
          onPressed: () => onAction(MusicTransportAction.next),
        ),
      ],
    );
  }

  testWidgets('fallback renders the three triangles + routes taps',
      (tester) async {
    final actions = <MusicTransportAction>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: NativeMusicTransport(
              playing: false,
              onAction: actions.add,
              fallback: fallbackRow(actions.add),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byIcon(Icons.skip_previous), findsOneWidget);
    expect(find.byIcon(Icons.skip_next), findsOneWidget);

    await tester.tap(find.byIcon(Icons.skip_previous));
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.tap(find.byIcon(Icons.skip_next));
    expect(actions, [
      MusicTransportAction.prev,
      MusicTransportAction.playPause,
      MusicTransportAction.next,
    ]);
  });

  testWidgets('nativeEnabled true on a non-iOS host still renders fallback',
      (tester) async {
    final actions = <MusicTransportAction>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: NativeMusicTransport(
              playing: true,
              nativeEnabled: true,
              onAction: actions.add,
              fallback: fallbackRow(actions.add),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // No UiKitView off-iOS: the fallback row renders instead.
    expect(find.byType(UiKitView), findsNothing);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    await tester.tap(find.byIcon(Icons.play_arrow));
    expect(actions, [MusicTransportAction.playPause]);
  });
}
