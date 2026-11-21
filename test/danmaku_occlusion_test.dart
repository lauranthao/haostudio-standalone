// Danmaku occlusion avoidance (1.1.6) — unit tests.
//
// Covers the pure logic (degradation ladder, mask expiry, RGBA
// expansion, display-rect geometry, shader matrix) and the
// controller loop with a mocked Vision channel + fake frame source.
// No real player, no native plugin, no Hive box: the switch reader,
// frame source and clock are all injected.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/danmaku/danmaku_occlusion.dart';
import 'package:standalone/core/native/person_segmentation.dart';

const MethodChannel _channel =
    MethodChannel(personSegmentationChannelName);

/// Canned Vision reply: a 4x2 mask, [frameWidth] x [frameHeight]
/// source frame.
Map<String, Object> _maskReply({
  required List<int> mask,
  bool hasPerson = true,
  int thermalState = 0,
  int frameWidth = 1920,
  int frameHeight = 1080,
}) {
  return <String, Object>{
    'mask': Uint8List.fromList(mask),
    'width': 4,
    'height': 2,
    'frameWidth': frameWidth,
    'frameHeight': frameHeight,
    'hasPerson': hasPerson,
    'thermalState': thermalState,
  };
}

/// Poll [check] until true or [timeout] elapses. Real-time waits:
/// the controller group runs as plain test() (not testWidgets), so
/// its Timers are real timers and the engine image decode completes
/// in real time. (Under testWidgets the fake clock stalls both:
/// Future.delayed never advances and decodeImageFromPixels never
/// resolves.)
Future<void> _waitFor(
  bool Function() check, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final until = DateTime.now().add(timeout);
  while (!check()) {
    if (DateTime.now().isAfter(until)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  // Plain test() below needs the engine binding for the mocked
  // MethodChannel and the ui.Image decode.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OcclusionLadder', () {
    test('starts at the active interval', () {
      final ladder = OcclusionLadder(
        activeInterval: const Duration(milliseconds: 30),
        patrolInterval: const Duration(milliseconds: 60),
      );
      expect(ladder.interval, const Duration(milliseconds: 30));
      expect(ladder.patrolling, isFalse);
      expect(ladder.stopped, isFalse);
    });

    test('3 consecutive empty frames drop to patrol', () {
      final ladder = OcclusionLadder(
        activeInterval: const Duration(milliseconds: 30),
        patrolInterval: const Duration(milliseconds: 60),
      );
      ladder.onFrame(success: true, hasPerson: false);
      ladder.onFrame(success: true, hasPerson: false);
      expect(ladder.interval, const Duration(milliseconds: 30));
      ladder.onFrame(success: true, hasPerson: false);
      expect(ladder.interval, const Duration(milliseconds: 60));
      expect(ladder.patrolling, isTrue);
    });

    test('failures count as empty for patrol', () {
      final ladder = OcclusionLadder(
        activeInterval: const Duration(milliseconds: 30),
        patrolInterval: const Duration(milliseconds: 60),
      );
      ladder.onFrame(success: false, hasPerson: false);
      ladder.onFrame(success: false, hasPerson: false);
      ladder.onFrame(success: true, hasPerson: false);
      expect(ladder.patrolling, isTrue);
    });

    test('one frame with a person restores the active interval', () {
      final ladder = OcclusionLadder(
        activeInterval: const Duration(milliseconds: 30),
        patrolInterval: const Duration(milliseconds: 60),
      );
      for (var i = 0; i < 3; i++) {
        ladder.onFrame(success: true, hasPerson: false);
      }
      expect(ladder.patrolling, isTrue);
      ladder.onFrame(success: true, hasPerson: true);
      expect(ladder.interval, const Duration(milliseconds: 30));
      expect(ladder.patrolling, isFalse);
    });

    test('thermal fair drops to patrol, nominal restores', () {
      final ladder = OcclusionLadder(
        activeInterval: const Duration(milliseconds: 30),
        patrolInterval: const Duration(milliseconds: 60),
      );
      ladder.onThermal(1);
      expect(ladder.interval, const Duration(milliseconds: 60));
      ladder.onThermal(0);
      expect(ladder.interval, const Duration(milliseconds: 30));
    });

    test('thermal serious stops the loop and reset keeps the latch', () {
      final ladder = OcclusionLadder(
        activeInterval: const Duration(milliseconds: 30),
        patrolInterval: const Duration(milliseconds: 60),
      );
      ladder.onThermal(2);
      expect(ladder.interval, isNull);
      expect(ladder.stopped, isTrue);
      ladder.reset();
      expect(ladder.interval, isNull);
      expect(ladder.stopped, isTrue);
    });

    test('thermal critical also stops the loop', () {
      final ladder = OcclusionLadder();
      ladder.onThermal(3);
      expect(ladder.stopped, isTrue);
    });
  });

  group('isMaskExpired', () {
    test('fresh mask is not expired, 500 ms is the boundary', () {
      final at = DateTime(2026, 11, 22, 12, 0, 0);
      expect(
        isMaskExpired(receivedAt: at, now: at.add(const Duration(milliseconds: 499))),
        isFalse,
      );
      expect(
        isMaskExpired(receivedAt: at, now: at.add(const Duration(milliseconds: 500))),
        isFalse,
      );
      expect(
        isMaskExpired(receivedAt: at, now: at.add(const Duration(milliseconds: 501))),
        isTrue,
      );
    });
  });

  group('expandMaskToRgba', () {
    test('white RGB, alpha = mask value', () {
      final out = expandMaskToRgba(Uint8List.fromList([0, 127, 255]));
      expect(
        out,
        Uint8List.fromList([
          255, 255, 255, 0,
          255, 255, 255, 127,
          255, 255, 255, 255,
        ]),
      );
    });
  });

  group('videoDisplayRect', () {
    test('contain letterboxes a wide video in a square container', () {
      final rect = videoDisplayRect(
        container: const Size(100, 100),
        video: const Size(1920, 1080),
        fit: BoxFit.contain,
      );
      expect(rect.left, 0);
      expect(rect.width, 100);
      expect(rect.height, closeTo(56.25, 0.01));
      expect(rect.top, closeTo(21.875, 0.01));
    });

    test('contain pillarboxes a tall video in a wide container', () {
      final rect = videoDisplayRect(
        container: const Size(200, 100),
        video: const Size(1080, 1920),
        fit: BoxFit.contain,
      );
      expect(rect.top, 0);
      expect(rect.height, 100);
      expect(rect.width, closeTo(56.25, 0.01));
      expect(rect.left, closeTo(71.875, 0.01));
    });

    test('fill covers the whole container', () {
      final rect = videoDisplayRect(
        container: const Size(100, 80),
        video: const Size(1920, 1080),
        fit: BoxFit.fill,
      );
      expect(rect, const Rect.fromLTWH(0, 0, 100, 80));
    });

    test('cover overflows the container, centred', () {
      final rect = videoDisplayRect(
        container: const Size(100, 100),
        video: const Size(1920, 1080),
        fit: BoxFit.cover,
      );
      expect(rect.width, closeTo(177.78, 0.01));
      expect(rect.height, 100);
      expect(rect.left, closeTo(-38.89, 0.01));
      expect(rect.top, 0);
    });

    test('fitWidth / fitHeight / none / scaleDown', () {
      final fitWidth = videoDisplayRect(
        container: const Size(100, 100),
        video: const Size(200, 100),
        fit: BoxFit.fitWidth,
      );
      expect(fitWidth, const Rect.fromLTWH(0, 25, 100, 50));

      final fitHeight = videoDisplayRect(
        container: const Size(100, 100),
        video: const Size(100, 200),
        fit: BoxFit.fitHeight,
      );
      expect(fitHeight, const Rect.fromLTWH(25, 0, 50, 100));

      final none = videoDisplayRect(
        container: const Size(100, 100),
        video: const Size(40, 30),
        fit: BoxFit.none,
      );
      expect(none, const Rect.fromLTWH(30, 35, 40, 30));

      final scaleDown = videoDisplayRect(
        container: const Size(100, 100),
        video: const Size(40, 30),
        fit: BoxFit.scaleDown,
      );
      // Smaller than the container: never upscaled.
      expect(scaleDown, const Rect.fromLTWH(30, 35, 40, 30));
    });

    test('empty container or video falls back to the container', () {
      expect(
        videoDisplayRect(
          container: Size.zero,
          video: const Size(1920, 1080),
          fit: BoxFit.contain,
        ),
        Rect.fromLTWH(0, 0, 0, 0),
      );
    });
  });

  group('maskShaderMatrix', () {
    test('maps the video rect onto the mask pixels', () {
      final matrix = maskShaderMatrix(
        videoRect: const Rect.fromLTWH(10, 20, 100, 50),
        maskSize: const Size(4, 2),
      );
      // Apply the matrix by hand from its column-major storage
      // (no vector_math import: it is not a direct dependency):
      // x' = e00*x + e01*y + e03, y' = e10*x + e11*y + e13.
      List<double> at(double x, double y) {
        final s = matrix.storage;
        return [
          x * s[0] + y * s[4] + s[12],
          x * s[1] + y * s[5] + s[13],
        ];
      }

      final origin = at(10, 20);
      expect(origin[0], closeTo(0, 0.001));
      expect(origin[1], closeTo(0, 0.001));
      final far = at(110, 70);
      expect(far[0], closeTo(4, 0.001));
      expect(far[1], closeTo(2, 0.001));
      final mid = at(60, 45);
      expect(mid[0], closeTo(2, 0.001));
      expect(mid[1], closeTo(1, 0.001));
    });

    test('degenerate rect returns identity', () {
      final matrix = maskShaderMatrix(
        videoRect: Rect.zero,
        maskSize: const Size(4, 2),
      );
      expect(matrix.storage, Matrix4.identity().storage);
    });
  });

  group('danmakuOcclusionAvoidanceSwitchOn', () {
    test('uninitialised Hive reads as off, never throws', () {
      expect(danmakuOcclusionAvoidanceSwitchOn(), isFalse);
    });
  });

  group('PersonSegmentation channel', () {
    late TestDefaultBinaryMessenger messenger;

    setUp(() {
      messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(_channel, null);
    });

    testWidgets('parses a good reply', (tester) async {
      messenger.setMockMethodCallHandler(_channel, (call) async {
        expect(call.method, 'segmentFrame');
        return _maskReply(mask: [0, 255, 255, 0, 0, 255, 0, 0]);
      });
      final mask = await PersonSegmentation()
          .segmentFrame(Uint8List.fromList([1, 2, 3]));
      expect(mask, isNotNull);
      expect(mask!.width, 4);
      expect(mask.height, 2);
      expect(mask.frameWidth, 1920);
      expect(mask.frameHeight, 1080);
      expect(mask.hasPerson, isTrue);
      expect(mask.thermalState, 0);
      expect(mask.bytes, Uint8List.fromList([0, 255, 255, 0, 0, 255, 0, 0]));
    });

    testWidgets('null reply means no mask', (tester) async {
      messenger.setMockMethodCallHandler(_channel, (call) async => null);
      final mask = await PersonSegmentation()
          .segmentFrame(Uint8List.fromList([1, 2, 3]));
      expect(mask, isNull);
    });

    testWidgets('malformed reply means no mask', (tester) async {
      messenger.setMockMethodCallHandler(_channel, (call) async {
        return <String, Object>{
          'mask': Uint8List.fromList([0, 255]),
          'width': 4,
          'height': 2,
          'frameWidth': 1920,
          'frameHeight': 1080,
          'hasPerson': true,
          'thermalState': 0,
        };
      });
      final mask = await PersonSegmentation()
          .segmentFrame(Uint8List.fromList([1, 2, 3]));
      expect(mask, isNull);
    });

    testWidgets('channel error means no mask, never throws', (tester) async {
      messenger.setMockMethodCallHandler(_channel, (call) async {
        throw PlatformException(code: 'boom');
      });
      final mask = await PersonSegmentation()
          .segmentFrame(Uint8List.fromList([1, 2, 3]));
      expect(mask, isNull);
    });
  });

  group('DanmakuOcclusionController', () {
    late TestDefaultBinaryMessenger messenger;

    setUp(() {
      messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(_channel, null);
    });

    DanmakuOcclusionController buildController({
      bool Function()? switchReader,
      bool Function()? isFrameCapable,
    }) {
      return DanmakuOcclusionController(
        segmentation: PersonSegmentation(),
        frameSource: () async => Uint8List.fromList([1, 2, 3]),
        isFrameCapable: isFrameCapable ?? () => true,
        switchReader: switchReader ?? () => true,
        activeInterval: const Duration(milliseconds: 30),
        patrolInterval: const Duration(milliseconds: 60),
        maskMaxAge: const Duration(milliseconds: 150),
      );
    }

    test('switch off never starts the loop', () async {
      messenger.setMockMethodCallHandler(_channel, (call) async {
        fail('must not segment while the switch is off');
      });
      final controller = buildController(switchReader: () => false);
      addTearDown(controller.dispose);
      controller.update(danmakuVisible: true, playing: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(controller.running, isFalse);
      expect(controller.hasMask, isFalse);
    });

    test('non-MPV never starts the loop', () async {
      messenger.setMockMethodCallHandler(_channel, (call) async {
        fail('must not segment on a non-MPV engine');
      });
      final controller = buildController(isFrameCapable: () => false);
      addTearDown(controller.dispose);
      controller.update(danmakuVisible: true, playing: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(controller.running, isFalse);
    });

    test('danmaku hidden or paused never starts the loop',
        () async {
      messenger.setMockMethodCallHandler(_channel, (call) async {
        fail('must not segment while danmaku is hidden or paused');
      });
      final controller = buildController();
      addTearDown(controller.dispose);
      controller.update(danmakuVisible: false, playing: true);
      controller.update(danmakuVisible: true, playing: false);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(controller.running, isFalse);
    });

    test('happy path installs a mask with the frame size',
        () async {
      messenger.setMockMethodCallHandler(
        _channel,
        (call) async => _maskReply(mask: [0, 255, 255, 0, 0, 255, 0, 0]),
      );
      final controller = buildController();
      addTearDown(controller.dispose);
      controller.update(danmakuVisible: true, playing: true);
      await _waitFor(() => controller.hasMask);
      expect(controller.running, isTrue);
      expect(controller.frameSize, const Size(1920, 1080));
      expect(controller.maskImage, isNotNull);
      expect(
        controller.currentInterval,
        const Duration(milliseconds: 30),
      );
    });

    test('3 empty frames drop to patrol, a person restores 5 Hz',
        () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls++;
        // First 4 replies: no person. Then a person appears.
        if (calls <= 4) {
          return _maskReply(
            mask: [0, 0, 0, 0, 0, 0, 0, 0],
            hasPerson: false,
          );
        }
        return _maskReply(mask: [0, 255, 255, 0, 0, 255, 0, 0]);
      });
      final controller = buildController();
      addTearDown(controller.dispose);
      controller.update(danmakuVisible: true, playing: true);
      await _waitFor(
        () =>
            controller.currentInterval ==
            const Duration(milliseconds: 60),
      );
      expect(controller.hasMask, isFalse);
      await _waitFor(() => controller.hasMask);
      expect(
        controller.currentInterval,
        const Duration(milliseconds: 30),
      );
    });

    test('stale mask expires when frames keep failing',
        () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls++;
        if (calls <= 2) {
          return _maskReply(mask: [0, 255, 255, 0, 0, 255, 0, 0]);
        }
        return null;
      });
      final controller = buildController();
      addTearDown(controller.dispose);
      controller.update(danmakuVisible: true, playing: true);
      await _waitFor(() => controller.hasMask);
      // Failures keep the old mask only until the 150 ms max age.
      await _waitFor(() => !controller.hasMask);
      expect(controller.running, isTrue);
    });

    test('thermal serious stops the loop and latches',
        () async {
      messenger.setMockMethodCallHandler(
        _channel,
        (call) async => _maskReply(
          mask: [0, 255, 255, 0, 0, 255, 0, 0],
          thermalState: 2,
        ),
      );
      final controller = buildController();
      addTearDown(controller.dispose);
      controller.update(danmakuVisible: true, playing: true);
      await _waitFor(() => !controller.running);
      expect(controller.hasMask, isFalse);
      // A later gate refresh must NOT restart past the latch.
      controller.update(danmakuVisible: true, playing: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(controller.running, isFalse);
    });

    test('invalidateMask drops the mask at once, loop keeps running',
        () async {
      messenger.setMockMethodCallHandler(
        _channel,
        (call) async => _maskReply(mask: [0, 255, 255, 0, 0, 255, 0, 0]),
      );
      final controller = buildController();
      addTearDown(controller.dispose);
      controller.update(danmakuVisible: true, playing: true);
      await _waitFor(() => controller.hasMask);
      controller.invalidateMask();
      expect(controller.hasMask, isFalse);
      expect(controller.running, isTrue);
      // The next tick re-installs a fresh mask.
      await _waitFor(() => controller.hasMask);
    });

    test('stopLoop stops and clears; update restarts',
        () async {
      messenger.setMockMethodCallHandler(
        _channel,
        (call) async => _maskReply(mask: [0, 255, 255, 0, 0, 255, 0, 0]),
      );
      final controller = buildController();
      addTearDown(controller.dispose);
      controller.update(danmakuVisible: true, playing: true);
      await _waitFor(() => controller.hasMask);
      controller.stopLoop();
      expect(controller.running, isFalse);
      expect(controller.hasMask, isFalse);
      controller.update(danmakuVisible: true, playing: true);
      await _waitFor(() => controller.hasMask);
      expect(controller.running, isTrue);
    });
  });
}
