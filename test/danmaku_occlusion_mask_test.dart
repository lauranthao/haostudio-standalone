// Danmaku occlusion mask widget (1.1.6) — widget tests.
//
// The widget wraps the danmaku layer in a ShaderMask (dstOut)
// exactly when the controller holds a mask, and returns the child
// untouched otherwise.
//
// No pixel test here on purpose: reading pixels back
// (RepaintBoundary.toImage / toByteData, and
// decodeImageFromPixels) never completes in this VM's test engine
// — the first pixel test timed out after 10 minutes, and the
// PictureRecorder variant did not complete in 60 s either, under a
// load average of 6-15 from parallel groups. The matrix direction
// itself is covered by the pure-math tests in
// danmaku_occlusion_test.dart (maskShaderMatrix maps the video
// rect's corners onto the mask image's corners, per Skia's
// local-matrix semantic "sample at M * point"); true pixel proof
// belongs to the on-device list (black-bar alignment, VOD/live).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/danmaku/danmaku_occlusion.dart';
import 'package:standalone/core/danmaku/danmaku_occlusion_mask.dart';
import 'package:standalone/core/native/person_segmentation.dart';

const MethodChannel _channel =
    MethodChannel(personSegmentationChannelName);

Map<String, Object> _maskReply() {
  return <String, Object>{
    'mask': Uint8List.fromList([0, 255, 255, 0, 0, 255, 0, 0]),
    'width': 4,
    'height': 2,
    'frameWidth': 1920,
    'frameHeight': 1080,
    'hasPerson': true,
    'thermalState': 0,
  };
}

/// Start the controller loop and wait (real time) until it
/// installs a mask. The whole wait runs inside runAsync: the loop's
/// Timers AND its engine image decode never resolve under the test's
/// fake clock, so update() must also be called inside runAsync —
/// a Timer created in the fake zone would never fire in real time.
Future<void> _startAndWaitForMask(
  WidgetTester tester,
  DanmakuOcclusionController controller,
) async {
  await tester.runAsync(() async {
    controller.update(danmakuVisible: true, playing: true);
    final until = DateTime.now().add(const Duration(seconds: 5));
    while (!controller.hasMask) {
      if (DateTime.now().isAfter(until)) {
        fail('mask not installed within 5 s');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  });
}

void main() {
  group('DanmakuOcclusionMask', () {
    late TestDefaultBinaryMessenger messenger;

    setUp(() {
      messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(_channel, null);
    });

    DanmakuOcclusionController buildController() {
      return DanmakuOcclusionController(
        segmentation: PersonSegmentation(),
        frameSource: () async => Uint8List.fromList([1, 2, 3]),
        isFrameCapable: () => true,
        switchReader: () => true,
        activeInterval: const Duration(milliseconds: 30),
        patrolInterval: const Duration(milliseconds: 60),
        maskMaxAge: const Duration(seconds: 10),
      );
    }

    Future<void> pumpMasked(
      WidgetTester tester,
      DanmakuOcclusionController controller,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 100,
              child: DanmakuOcclusionMask(
                controller: controller,
                fit: BoxFit.contain,
                child: Container(
                  key: const ValueKey('danmaku-layer'),
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('ShaderMask wraps the danmaku layer while a mask is held',
        (tester) async {
      messenger.setMockMethodCallHandler(
        _channel,
        (call) async => _maskReply(),
      );
      final controller = buildController();
      addTearDown(controller.dispose);
      await _startAndWaitForMask(tester, controller);
      await pumpMasked(tester, controller);
      final shaderMask =
          tester.widget<ShaderMask>(find.byType(ShaderMask));
      expect(shaderMask.blendMode, BlendMode.dstOut);
      // The danmaku layer is the ShaderMask's child.
      expect(
        find.descendant(
          of: find.byType(ShaderMask),
          matching: find.byKey(const ValueKey('danmaku-layer')),
        ),
        findsOneWidget,
      );
    });

    testWidgets('no mask means no ShaderMask at all', (tester) async {
      messenger.setMockMethodCallHandler(
        _channel,
        (call) async => _maskReply(),
      );
      final controller = buildController();
      addTearDown(controller.dispose);
      // Never started: no mask, plain child.
      await pumpMasked(tester, controller);
      expect(find.byType(ShaderMask), findsNothing);
      expect(
        find.byKey(const ValueKey('danmaku-layer')),
        findsOneWidget,
      );
    });

    testWidgets('invalidating the mask removes the ShaderMask',
        (tester) async {
      messenger.setMockMethodCallHandler(
        _channel,
        (call) async => _maskReply(),
      );
      final controller = buildController();
      addTearDown(controller.dispose);
      await _startAndWaitForMask(tester, controller);
      await pumpMasked(tester, controller);
      expect(find.byType(ShaderMask), findsOneWidget);
      controller.invalidateMask();
      await tester.pump();
      expect(find.byType(ShaderMask), findsNothing);
    });
  });
}
