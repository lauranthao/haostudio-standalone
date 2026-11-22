// build 30 崩溃猎杀回归测试。
//
// 每项断言对应一个已修的崩溃点；失败 = 该修法已退化。
// - C1 Hive box 损坏后 main() 在 runApp 前抛，app 每次启动都闪退：
//   HiveStore.init 必须删盘重建，而不是把异常抛回 main。
// - C2 死掉的 CMS 源回 HTML 200：jsonDecode 的 FormatException 必须
//   变成 callers 已处理的 CmsException，而不是未捕获错误。
// - C3 CMS detail 的 list 首元素不是 Map：`as Map` 的 TypeError 必须
//   变成 null（找不到这部影片），而不是抛错。
// - C4 播放器收到空 lines / 空 episodes：initState 的 clamp(0, -1)
//   抛 ArgumentError、_episode 抛 RangeError；必须出失败卡片。
// - C5 0 宽/0 高封面：`targetWidth ~/ aspectRatio` 在 aspectRatio 为
//   0 时抛 IntegerDivisionByZeroException；必须回 unconstrained。

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/music/widgets/music_image.dart';
import 'package:standalone/features/video/video_models.dart';
import 'package:standalone/services/video/cms_client.dart';

// ---------------------------------------------------------------------------
// C1: Hive corruption recovery
// ---------------------------------------------------------------------------

void main() {
  group('C1 HiveStore.init recovers from a corrupted box', () {
    test('corrupt box file -> init rebuilds an empty box, no throw',
        () async {
      final dir =
          await Directory.systemTemp.createTemp('hao-hive-crash-');
      addTearDown(() async {
        try {
          await Hive.close();
        } catch (_) {}
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      await HiveStore.init(path: dir.path);
      await HiveStore.put('k', 'v');
      expect(HiveStore.getString('k', ''), 'v');
      await HiveStore.box.close();
      // Simulate a kill mid-write: trash the box file bytes.
      final boxFile = File('${dir.path}/app_settings.hive');
      expect(await boxFile.exists(), isTrue);
      await boxFile.writeAsBytes(List<int>.filled(64, 0xFF));
      // Reopen must recover (fresh empty box), not throw.
      await HiveStore.init(path: dir.path);
      expect(HiveStore.getString('k', 'dflt'), 'dflt');
      await HiveStore.put('k2', 'v2');
      expect(HiveStore.getString('k2', ''), 'v2');
    });
  });

  // -------------------------------------------------------------------------
  // C2/C3: CMS fetch + detail parsing on malformed data
  // -------------------------------------------------------------------------

  group('C2/C3 CMS malformed responses', () {
    const source = VideoSource(
      id: 99,
      name: 'test',
      apiUrl: 'https://example.com/api.php/provide/vod',
      kind: 'play',
      enabled: true,
      sort: 99,
    );

    test('C2: HTML body -> CmsException, not FormatException', () {
      expect(
        () => parseCmsResponseBody(
          '<!DOCTYPE html><html><body>404 Not Found</body></html>',
          'https://example.com/api.php/provide/vod',
        ),
        throwsA(isA<CmsException>()),
      );
      expect(
        () => parseCmsResponseBody('', 'https://example.com/x'),
        throwsA(isA<CmsException>()),
      );
      expect(
        () => parseCmsResponseBody('[1, 2]', 'https://example.com/x'),
        throwsA(isA<CmsException>()),
      );
    });

    test('C2: valid JSON string / map passes through', () {
      expect(
        parseCmsResponseBody('{"list": []}', 'https://example.com/x'),
        {'list': []},
      );
      final map = <String, dynamic>{'list': []};
      expect(parseCmsResponseBody(map, 'https://example.com/x'), same(map));
    });

    test('C3: detail list with a non-map first element -> null', () {
      expect(parseCmsDetail(source, '1', {'list': ['not-a-map']}), isNull);
      expect(parseCmsDetail(source, '1', {'list': [null]}), isNull);
      expect(parseCmsDetail(source, '1', {'list': []}), isNull);
      expect(parseCmsDetail(source, '1', {'list': [42]}), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // C5: degenerate image target size
  // -------------------------------------------------------------------------

  group('C5 MusicImageProvider.targetSizeFor', () {
    test('0-width / 0-height intrinsic -> unconstrained, no throw', () {
      expect(
        MusicImageProvider.targetSizeFor(0, 100, 100, 100),
        const ui.TargetImageSize(),
      );
      expect(
        MusicImageProvider.targetSizeFor(100, 0, 100, 100),
        const ui.TargetImageSize(),
      );
      expect(
        MusicImageProvider.targetSizeFor(0, 0, 100, 100),
        const ui.TargetImageSize(),
      );
    });

    test('normal downsample math unchanged', () {
      final a = MusicImageProvider.targetSizeFor(400, 200, 100, 100);
      expect(a.width, 100);
      expect(a.height, 50);
      final b = MusicImageProvider.targetSizeFor(100, 400, 100, 100);
      expect(b.width, 25);
      expect(b.height, 100);
    });

    test('no cache size -> unconstrained', () {
      expect(
        MusicImageProvider.targetSizeFor(400, 200, null, null),
        const ui.TargetImageSize(),
      );
    });
  });
}
