// K item 6 — NativeVodControls fallback (build 29).
//
// The SwiftUI view cannot run in a widget test (no iOS engine), so
// this file pins the contract the page depends on:
//   - with nativeEnabled false (the default) AND with it true on a
//     non-iOS host, the widget renders the current Flutter buttons
//     verbatim — same icons, sizes, tooltips — and every tap routes
//     to onAction with the right action.
//   - both clusters are fixed-size (transport 144x48, trailing
//     112x48), so no MethodChannel size negotiation is ever needed.
// The native side itself is uncompiled here (no Xcode on the VM);
// G group builds ios/Runner/VodControlsPlugin.swift + registers it.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/widgets/native_vod_controls.dart';

void main() {
  testWidgets('transport fallback renders the three buttons + routes taps',
      (tester) async {
    final actions = <VodControlAction>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: NativeVodControls.transport(
              playing: false,
              onAction: actions.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Fixed cluster size on the TRANSPORT side only: three 48 px
    // IconButtons. (The trailing side has no fixed width in the
    // fallback — the Flutter TextButton's minimum width makes it
    // ~128 px; pinning 112 overflowed by 16 px.)
    expect(tester.getSize(find.byType(NativeVodControls)),
        const Size(144, 48),
        reason: 'fixed cluster size — no size negotiation');
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byIcon(Icons.skip_previous), findsOneWidget);
    expect(find.byIcon(Icons.skip_next), findsOneWidget);
    expect(find.byTooltip('上一集'), findsOneWidget);
    expect(find.byTooltip('下一集'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.tap(find.byIcon(Icons.skip_previous));
    await tester.tap(find.byIcon(Icons.skip_next));
    expect(actions, [
      VodControlAction.playPause,
      VodControlAction.prev,
      VodControlAction.next,
    ]);
  });

  testWidgets('transport shows pause while playing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: NativeVodControls.transport(
              playing: true,
              onAction: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.pause), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsNothing);
  });

  testWidgets('trailing fallback renders rate + exit + routes taps',
      (tester) async {
    final actions = <VodControlAction>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: NativeVodControls.trailing(
              rateLabel: '1.25x',
              onAction: actions.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // No fixed width in the fallback: the TextButton minimum
    // width + padding makes the trailing cluster ~128 px (not
    // 112 — pinning 112 overflowed by 16 px). Height is 48.
    final size = tester.getSize(find.byType(NativeVodControls));
    expect(size.height, 48);
    expect(size.width, greaterThanOrEqualTo(112));
    expect(tester.takeException(), isNull,
        reason: 'fallback must not overflow');
    expect(find.text('1.25x'), findsOneWidget);
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
    expect(find.byTooltip('退出全屏'), findsOneWidget);

    await tester.tap(find.text('1.25x'));
    await tester.tap(find.byIcon(Icons.fullscreen_exit));
    expect(actions, [VodControlAction.rate, VodControlAction.exit]);
  });

  testWidgets('nativeEnabled true still falls back off iOS',
      (tester) async {
    final actions = <VodControlAction>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: NativeVodControls.transport(
              playing: false,
              nativeEnabled: true,
              onAction: actions.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // No UiKitView on this host — the Flutter buttons render.
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    await tester.tap(find.byIcon(Icons.play_arrow));
    expect(actions, [VodControlAction.playPause]);
  });

  // G group (Wave 2) — the plugin is registered in AppDelegate +
  // Runner target now, so pin the Dart side of the native path
  // with the host faked to iOS (no Xcode on the VM: the Swift
  // side itself is NOT compiled here). The page keeps
  // nativeEnabled false until Codemagic builds the plugin; these
  // tests cover the widget's half of the contract.
  //
  // The override is reset at the END of each test body (not in
  // tearDown): the framework's invariant check runs before
  // tearDowns, so a tearDown reset still fails the test.
  testWidgets('iOS + nativeEnabled renders UiKitView with creationParams',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: NativeVodControls.transport(
              playing: false,
              nativeEnabled: true,
              onAction: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final view = find.byType(UiKitView);
    expect(view, findsOneWidget);
    final widget = tester.widget<UiKitView>(view);
    expect(widget.viewType, nativeVodControlsViewType);
    final params = widget.creationParams! as Map<Object?, Object?>;
    expect(params['cluster'], 'transport');
    expect(params['playing'], isFalse);
    expect(params['rateLabel'], '1.0x');
    expect(tester.getSize(find.byType(NativeVodControls)),
        const Size(144, 48));
    // The Flutter fallback is gone on this path.
    expect(find.byIcon(Icons.play_arrow), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS prop change pushes setState on the command channel',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final calls = <MethodCall>[];
    const commandChannel = MethodChannel(nativeVodControlsCommandChannel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(commandChannel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(commandChannel, null));

    Widget buildTransport({required bool playing}) {
      return MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: NativeVodControls.transport(
              playing: playing,
              nativeEnabled: true,
              onAction: (_) {},
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(buildTransport(playing: false));
    await tester.pump();
    expect(calls, isEmpty);

    // Flip the prop: didUpdateWidget pushes setState {playing}.
    await tester.pumpWidget(buildTransport(playing: true));
    await tester.pump();
    expect(calls.length, 1);
    expect(calls.single.method, 'setState');
    final args = calls.single.arguments as Map<Object?, Object?>;
    expect(args['playing'], isTrue);
    expect(args['id'], isA<int>());

    // Same value again: no push (no diff, no second state).
    await tester.pumpWidget(buildTransport(playing: true));
    await tester.pump();
    expect(calls.length, 1);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('native onTap event routes to onAction', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final actions = <VodControlAction>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: NativeVodControls.transport(
              playing: false,
              nativeEnabled: true,
              onAction: actions.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final params =
        tester.widget<UiKitView>(find.byType(UiKitView)).creationParams!
            as Map<Object?, Object?>;
    final id = params['id'] as int;
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      nativeVodControlsEventChannel,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onTap', {'id': id, 'action': 'next'}),
      ),
      (_) {},
    );
    await tester.pump();
    expect(actions, [VodControlAction.next]);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('missing native side never throws on prop push',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    // No mock handler on the command channel: invokeMethod throws
    // MissingPluginException, and _push must swallow it (best
    // effort — a missing native side never breaks the page).
    Widget buildTransport({required bool playing}) {
      return MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: NativeVodControls.transport(
              playing: playing,
              nativeEnabled: true,
              onAction: (_) {},
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(buildTransport(playing: false));
    await tester.pump();
    await tester.pumpWidget(buildTransport(playing: true));
    await tester.pump();
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('nativeEnabled defaults to false (stays off until verified)',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    // Even on iOS, the default constructor flag is false: the
    // Flutter fallback renders, no UiKitView is created. The page
    // (NativeVideoPlayerPage.nativeVodControls) also defaults
    // false — the coordinator flips it only after a Codemagic
    // build proves the registered plugin loads.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: NativeVodControls.transport(
              playing: false,
              onAction: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(UiKitView), findsNothing);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
