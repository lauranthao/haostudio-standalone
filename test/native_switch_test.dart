// build 29, E group: HaoNativeSwitch — the app's only switch.
//
// What flutter test CAN prove here, honestly:
//  - Fallback branch (tests run on the Linux host, so
//    defaultTargetPlatform is Android): the CupertinoSwitch renders
//    with the theme accent as its active track, tap flips it, the
//    value prop stays the single source of truth, and row taps
//    toggle exactly once. The goldens are the thumb-visibility
//    evidence: ON = black track + white knob, OFF = grey track +
//    white knob, in light and dark, at glass 0% and 100% (the
//    switch paints no glass, so intensity must not change it).
//  - iOS branch (debugDefaultTargetPlatformOverride = iOS): the
//    UiKitView is created with the right view type and
//    creationParams (id / value / onTintColor / enabled /
//    semanticsLabel); a simulated native `onChanged` event reaches
//    onChanged; a parent-side value change pushes exactly one
//    `setValue` to the command channel and a native flip echoes
//    nothing back; tint / enabled changes push their commands.
// What flutter test CANNOT prove: that the real UISwitch renders
// correctly on a phone. In tests UiKitView is a placeholder box —
// the golden for it would enshrine a test artifact, so there is
// none. The true visual verdict is chen's phone (see the report).
// The Swift side cannot be compiled on this Linux VM at all (no
// Xcode): its syntax was checked by reading only, and it must be
// verified by the Codemagic build.

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/widgets/native_switch.dart';

/// Stateful holder: the value lives here (the "store"), the switch
/// only mirrors it — the single-source-of-truth shape every call
/// site uses.
class _Holder extends StatefulWidget {
  const _Holder({
    required this.notifier,
    this.activeColor,
    this.enabled = true,
    this.semanticsLabel,
    this.onChanged,
  });

  final ValueNotifier<bool> notifier;
  final Color? activeColor;
  final bool enabled;
  final String? semanticsLabel;
  final void Function(bool)? onChanged;

  @override
  State<_Holder> createState() => _HolderState();
}

class _HolderState extends State<_Holder> {
  @override
  void initState() {
    super.initState();
    widget.notifier.addListener(_rebuild);
  }

  @override
  void dispose() {
    widget.notifier.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return HaoNativeSwitch(
      value: widget.notifier.value,
      activeColor: widget.activeColor,
      enabled: widget.enabled,
      semanticsLabel: widget.semanticsLabel,
      onChanged: (v) {
        widget.onChanged?.call(v);
        widget.notifier.value = v;
      },
    );
  }
}

/// Stateful holder for [HaoSwitchRow] (same single-source shape as
/// [_Holder], for the row-tap tests).
class _RowHolder extends StatefulWidget {
  const _RowHolder({required this.notifier, this.onChanged});

  final ValueNotifier<bool> notifier;
  final void Function(bool)? onChanged;

  @override
  State<_RowHolder> createState() => _RowHolderState();
}

class _RowHolderState extends State<_RowHolder> {
  @override
  void initState() {
    super.initState();
    widget.notifier.addListener(_rebuild);
  }

  @override
  void dispose() {
    widget.notifier.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return HaoSwitchRow(
      title: '影视弹幕',
      value: widget.notifier.value,
      onChanged: (v) {
        widget.onChanged?.call(v);
        widget.notifier.value = v;
      },
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child, {ThemeData? theme}) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme ?? HaoThemes.of(HaoThemeId.appleGlass).light,
      home: Scaffold(body: Center(child: child)),
    );
  }

  Future<void> setSurface(WidgetTester tester, {Size size = const Size(400, 200)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  /// Mock the command channel and record every call.
  List<MethodCall> mockCommands() {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(nativeSwitchCommandChannel),
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(nativeSwitchCommandChannel),
        null,
      );
    });
    return calls;
  }

  /// Deliver a native `onChanged` event the way the Swift side
  /// sends it (events channel, StandardMethodCodec).
  Future<void> sendNativeChanged(int id, bool value) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    await messenger.handlePlatformMessage(
      nativeSwitchEventChannel,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onChanged', {'id': id, 'value': value}),
      ),
      (_) {},
    );
  }

  group('fallback (non-iOS): CupertinoSwitch', () {
    testWidgets('ON renders accent track, tap flips, value is the source of truth',
        (tester) async {
      final value = ValueNotifier<bool>(true);
      final seen = <bool>[];
      await tester.pumpWidget(
        wrap(_Holder(notifier: value, onChanged: seen.add)),
      );
      await tester.pumpAndSettle();

      final sw = tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch));
      expect(sw.value, isTrue);
      // The old bug was thumb == track == accent (black on black).
      // CupertinoSwitch pins the thumb white by construction; the
      // track is the accent — asserted here, shown in the goldens.
      expect(sw.activeTrackColor, const Color(0xFF000000));

      await tester.tap(find.byType(HaoNativeSwitch));
      await tester.pumpAndSettle();
      expect(seen, [false]);
      expect(value.value, isFalse);
      expect(
        tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch)).value,
        isFalse,
      );
    });

    testWidgets('OFF renders grey track, tap turns it on', (tester) async {
      final value = ValueNotifier<bool>(false);
      await tester.pumpWidget(wrap(_Holder(notifier: value)));
      await tester.pumpAndSettle();
      expect(
        tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch)).value,
        isFalse,
      );
      await tester.tap(find.byType(HaoNativeSwitch));
      await tester.pumpAndSettle();
      expect(value.value, isTrue);
    });

    testWidgets('disabled switch does not toggle', (tester) async {
      final value = ValueNotifier<bool>(false);
      await tester.pumpWidget(
        wrap(
          HaoNativeSwitch(
            value: value.value,
            onChanged: null,
            enabled: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final sw = tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch));
      expect(sw.onChanged, isNull);
      await tester.tap(find.byType(HaoNativeSwitch));
      await tester.pumpAndSettle();
      expect(value.value, isFalse);
    });

    testWidgets('fallback sends no native commands', (tester) async {
      final calls = mockCommands();
      final value = ValueNotifier<bool>(true);
      await tester.pumpWidget(wrap(_Holder(notifier: value)));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(HaoNativeSwitch));
      await tester.pumpAndSettle();
      value.value = true;
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
    });

    testWidgets('row tap toggles exactly once', (tester) async {
      final seen = <bool>[];
      final value = ValueNotifier<bool>(false);
      await tester.pumpWidget(
        wrap(
          _RowHolder(notifier: value, onChanged: seen.add),
        ),
      );
      await tester.pumpAndSettle();
      // Tapping the title (the SwitchListTile row-tap behaviour).
      await tester.tap(find.text('影视弹幕'));
      await tester.pumpAndSettle();
      expect(seen, [true]);
      expect(value.value, isTrue);
      // Tapping the switch itself must also fire exactly once —
      // ListTile onTap + switch tap must not double-toggle.
      await tester.tap(find.byType(HaoNativeSwitch));
      await tester.pumpAndSettle();
      expect(seen, [true, false]);
      expect(value.value, isFalse);
    });

    testWidgets('golden: light ON', (tester) async {
      await setSurface(tester);
      await tester.pumpWidget(wrap(_Holder(notifier: ValueNotifier(true))));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/native_switch_fallback_light_on.png'),
      );
    });

    testWidgets('golden: light OFF', (tester) async {
      await setSurface(tester);
      await tester.pumpWidget(wrap(_Holder(notifier: ValueNotifier(false))));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/native_switch_fallback_light_off.png'),
      );
    });

    testWidgets('golden: dark ON', (tester) async {
      await setSurface(tester);
      await tester.pumpWidget(
        wrap(
          _Holder(notifier: ValueNotifier(true)),
          theme: HaoThemes.of(HaoThemeId.appleGlass).dark,
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/native_switch_fallback_dark_on.png'),
      );
    });

    testWidgets('golden: dark OFF', (tester) async {
      await setSurface(tester);
      await tester.pumpWidget(
        wrap(
          _Holder(notifier: ValueNotifier(false)),
          theme: HaoThemes.of(HaoThemeId.appleGlass).dark,
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/native_switch_fallback_dark_off.png'),
      );
    });

    testWidgets('golden: glass 0% ON reads the same as 100%', (tester) async {
      // The switch paints no glass: at 0% the knob/track must be
      // identical to the 100% golden (compare with
      // native_switch_fallback_light_on.png by eye / pixel diff).
      await setSurface(tester);
      await tester.pumpWidget(
        wrap(
          _Holder(notifier: ValueNotifier(true)),
          theme: HaoThemes.of(
            HaoThemeId.appleGlass,
            glassIntensity: 0.0,
          ).light,
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/native_switch_fallback_light_on_glass0.png'),
      );
    });
  });

  group('iOS branch: UiKitView bridge', () {
    // The binding verifies foundation debug variables BEFORE
    // addTearDown/tearDown run, so the override must be reset
    // inside the test body (try/finally), not in a tearDown.
    void testWidgetsIOS(
      String description,
      Future<void> Function(WidgetTester tester) body,
    ) {
      testWidgets(description, (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          await body(tester);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    Map<String, Object?> creationParams(WidgetTester tester) {
      final view = tester.widget<UiKitView>(find.byType(UiKitView));
      expect(view.viewType, nativeSwitchViewType);
      final params = view.creationParams! as Map<String, Object?>;
      return params;
    }

    testWidgetsIOS('creates UiKitView with value, tint, enabled, label',
        (tester) async {
      final value = ValueNotifier<bool>(true);
      await tester.pumpWidget(
        wrap(
          _Holder(
            notifier: value,
            semanticsLabel: '影视弹幕',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UiKitView), findsOneWidget);
      expect(find.byType(CupertinoSwitch), findsNothing);
      final params = creationParams(tester);
      expect(params['value'], isTrue);
      // Default appleGlass light accent is pure black; it goes to
      // the native side as the ON tint — the thumb stays white
      // there (thumbTintColor = .white in Swift), so black tint
      // can no longer hide the knob.
      expect(params['onTintColor'], const Color(0xFF000000).toARGB32());
      expect(params['enabled'], isTrue);
      expect(params['semanticsLabel'], '影视弹幕');
      expect(params['id'], isA<int>());
    });

    testWidgetsIOS('native flip reaches onChanged and echoes nothing back',
        (tester) async {
      final calls = mockCommands();
      final value = ValueNotifier<bool>(true);
      final seen = <bool>[];
      await tester.pumpWidget(
        wrap(_Holder(notifier: value, onChanged: seen.add)),
      );
      await tester.pumpAndSettle();
      final id = creationParams(tester)['id'] as int;

      await sendNativeChanged(id, false);
      await tester.pumpAndSettle();
      expect(seen, [false]);
      expect(value.value, isFalse);
      // The parent rebuild carried value=false, which equals the
      // native value now — so no setValue echo may be sent.
      expect(
        calls.where((c) => c.method == 'setValue'),
        isEmpty,
      );
    });

    testWidgetsIOS('parent-side value change pushes one setValue',
        (tester) async {
      final calls = mockCommands();
      final value = ValueNotifier<bool>(true);
      await tester.pumpWidget(wrap(_Holder(notifier: value)));
      await tester.pumpAndSettle();
      final id = creationParams(tester)['id'] as int;

      value.value = false;
      await tester.pumpAndSettle();
      final setValues =
          calls.where((c) => c.method == 'setValue').toList();
      expect(setValues, hasLength(1));
      expect(setValues.single.arguments, {
        'id': id,
        'value': false,
        'animated': true,
      });
    });

    testWidgetsIOS('tint and enabled changes push their commands',
        (tester) async {
      final calls = mockCommands();
      final value = ValueNotifier<bool>(true);
      const gold = Color(0xFF9A7B1E);
      await tester.pumpWidget(
        wrap(_Holder(notifier: value, activeColor: gold)),
      );
      await tester.pumpAndSettle();
      final id = creationParams(tester)['id'] as int;

      // Same tint again: no push.
      await tester.pumpWidget(
        wrap(_Holder(notifier: value, activeColor: gold)),
      );
      await tester.pumpAndSettle();
      expect(
        calls.where((c) => c.method == 'setOnTintColor'),
        isEmpty,
      );

      await tester.pumpWidget(
        wrap(_Holder(notifier: value, activeColor: const Color(0xFF00897B))),
      );
      await tester.pumpAndSettle();
      final tints =
          calls.where((c) => c.method == 'setOnTintColor').toList();
      expect(tints, hasLength(1));
      expect(tints.single.arguments, {
        'id': id,
        'color': const Color(0xFF00897B).toARGB32(),
      });

      await tester.pumpWidget(
        wrap(
          _Holder(
            notifier: value,
            activeColor: const Color(0xFF00897B),
            enabled: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final enabledCalls =
          calls.where((c) => c.method == 'setEnabled').toList();
      expect(enabledCalls, hasLength(1));
      expect(enabledCalls.single.arguments, {'id': id, 'enabled': false});
    });

    testWidgetsIOS('events for an unknown id are ignored', (tester) async {
      final seen = <bool>[];
      final value = ValueNotifier<bool>(true);
      await tester.pumpWidget(
        wrap(_Holder(notifier: value, onChanged: seen.add)),
      );
      await tester.pumpAndSettle();
      await sendNativeChanged(999999, false);
      await tester.pumpAndSettle();
      expect(seen, isEmpty);
      expect(value.value, isTrue);
      expect(tester.takeException(), isNull);
    });
  });
}
