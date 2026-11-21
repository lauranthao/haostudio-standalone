// Haptics master switch + four entry points (Beans BeansHaptics port).
//
// The platform channel `flutter/platform` records every
// HapticFeedback call. With the switch on, each entry point fires
// exactly one vibrate call with the right type; with the switch off
// (via the test-only debugEnabledOverride, same path the settings
// toggle writes), no call reaches the platform at all.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/theme/haptics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // SystemChannels.platform is an OptionalMethodChannel with a
  // JSONMethodCodec — the mock must use the same codec or the incoming
  // bytes fail to decode and the handler never runs.
  const channel = MethodChannel('flutter/platform', JSONMethodCodec());
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  // _fire is unawaited fire-and-forget; flush the microtask queue.
  Future<void> flush() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  group('HaoHaptics', () {
    test('each entry point fires one platform call with its type', () async {
      HaoHaptics.debugEnabledOverride = true;

      HaoHaptics.tap();
      await flush();
      expect(calls, hasLength(1));
      expect(calls.single.method, 'HapticFeedback.vibrate');
      expect(calls.single.arguments, 'HapticFeedbackType.lightImpact');
      calls.clear();

      HaoHaptics.medium();
      await flush();
      expect(calls.single.arguments, 'HapticFeedbackType.mediumImpact');
      calls.clear();

      HaoHaptics.success();
      await flush();
      expect(calls.single.arguments, 'HapticFeedbackType.heavyImpact');
      calls.clear();

      HaoHaptics.select();
      await flush();
      expect(calls.single.arguments, 'HapticFeedbackType.selectionClick');
    });

    test('switch off: no entry point reaches the platform', () async {
      HaoHaptics.debugEnabledOverride = false;

      HaoHaptics.tap();
      HaoHaptics.medium();
      HaoHaptics.success();
      HaoHaptics.select();
      await flush();

      expect(calls, isEmpty);
    });

    test('enabled defaults to true when the override is null', () {
      HaoHaptics.debugEnabledOverride = null;
      // Hive is not initialised in this test; enabled falls back to
      // true (Hive read throws, caught in the getter).
      expect(HaoHaptics.enabled, isTrue);
    });

    test('sliderEnd: tap mid-range, selection click at either end',
        () async {
      HaoHaptics.debugEnabledOverride = true;

      HaoHaptics.sliderEnd(0.5, 0, 1);
      await flush();
      expect(calls, hasLength(1));
      expect(calls.single.arguments, 'HapticFeedbackType.lightImpact');

      calls.clear();
      HaoHaptics.sliderEnd(0, 0, 1);
      await flush();
      expect(calls.single.arguments, 'HapticFeedbackType.selectionClick');

      calls.clear();
      HaoHaptics.sliderEnd(1, 0, 1);
      await flush();
      expect(calls.single.arguments, 'HapticFeedbackType.selectionClick');
    });
  });
}
