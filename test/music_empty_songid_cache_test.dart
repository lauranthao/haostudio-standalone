// Empty-songId play-URL cache (2026-11-19).
//
// The cache key is `songId|platform|quality`, so two different songs
// with an empty songId would share the key '|platform|quality' and
// the second would play the first's URL. Code walk (2026-11-19):
// the live collision does NOT reproduce through the current call
// paths — resolvePlayUrl returns null before touching the cache for
// an empty songId, and the controller's prefetch read AND write are
// both guarded by `songId.isNotEmpty` — but the key construction
// itself was still written as if an empty id were cacheable. Fix
// (music_resolvers.dart _PlayUrlCache, option "don't cache empty
// songId results", matching the existing early-return convention):
// the cache itself refuses empty-id keys on get / put / evict, so
// the invariant holds at the layer named in the brief whatever a
// future caller passes in. Song.identityKey's title|artist|album
// fallback (music_models.dart) is the identity convention used
// elsewhere; the resolver entry keeps returning null for an empty
// id rather than burning 8 s asking id-based sources for it.
//
// - two different empty-id songs: both null, no request fired.
// - a normal songId still caches (second resolve: no new request).
// - evicting with an empty songId never drops a real cached URL.
// - two different real ids never share a cache entry.
//
// Run:
//   TMPDIR=$PWD/.tmp flutter test --concurrency=1
//   test/music_empty_songid_cache_test.dart

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/services/music/lx_script_engine.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';
import 'package:standalone/services/music/music_resolvers.dart';

import 'lx_fake_dio.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-empty-id-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
    final memBox = await Hive.openBox<dynamic>(
      'test_empty_id',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  setUp(() async {
    await HiveStore.put('hao_resolver_speed', '');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  /// zddyr answers a per-songmid URL; everything else is empty.
  /// [log] records every request so cache hits are observable
  /// (a cache hit fires no request at all).
  (MusicResolvers, List<String>) resolvers(List<String> log) {
    final dio = buildFakeDio(
      log: log,
      respond: (url) {
        final m = RegExp(r'songmid=([^&]+)').firstMatch(url);
        if (url.contains('yy.zddyr.top') && m != null) {
          return {
            'status': 200,
            'body':
                '{"code":200,"url":"https://example.com/${m.group(1)}.flac"}',
          };
        }
        return {'status': 404, 'body': '{}'};
      },
    );
    return (
      MusicResolvers(
        dio: dio,
        scriptEngine: LxScriptEngine(
          dio: dio,
          assetLoader: (_) async => throw StateError('no assets'),
        ),
      ),
      log,
    );
  }

  test('two different empty-id songs never share a cache entry', () async {
    final log = <String>[];
    final (r, _) = resolvers(log);
    final a = await r.resolvePlayUrl(
      '',
      MusicPlatform.wy,
      AudioQuality.hires,
      'Die For You',
    );
    final b = await r.resolvePlayUrl(
      '',
      MusicPlatform.wy,
      AudioQuality.hires,
      'Die For You (Remix)',
    );
    expect(a, isNull);
    expect(b, isNull);
    expect(log, isEmpty,
        reason: 'an empty songId must not even reach the sources');
  });

  test('a normal songId still caches (second resolve fires nothing)',
      () async {
    final log = <String>[];
    final (r, _) = resolvers(log);
    final first = await r.resolvePlayUrl(
      'empty-id-cache-1',
      MusicPlatform.wy,
      AudioQuality.hires,
      'Test',
    );
    expect(first, isNotNull);
    expect(first!.url, 'https://example.com/empty-id-cache-1.flac');
    final fired = log.length;
    expect(fired, greaterThan(0));
    final second = await r.resolvePlayUrl(
      'empty-id-cache-1',
      MusicPlatform.wy,
      AudioQuality.hires,
      'Test',
    );
    expect(second, isNotNull);
    expect(second!.url, first.url);
    expect(log.length, fired,
        reason: 'the second resolve must be served from cache');
  });

  test('evicting with an empty songId never drops a real cached URL',
      () async {
    final log = <String>[];
    final (r, _) = resolvers(log);
    final first = await r.resolvePlayUrl(
      'empty-id-cache-2',
      MusicPlatform.wy,
      AudioQuality.hires,
      'Test',
    );
    expect(first, isNotNull);
    final fired = log.length;
    r.evictPlayUrl('', MusicPlatform.wy, AudioQuality.hires);
    final second = await r.resolvePlayUrl(
      'empty-id-cache-2',
      MusicPlatform.wy,
      AudioQuality.hires,
      'Test',
    );
    expect(second, isNotNull);
    expect(second!.url, first!.url);
    expect(log.length, fired,
        reason: 'the empty-id evict must not touch the real entry');
  });

  test('two different real ids never share a cache entry', () async {
    final log = <String>[];
    final (r, _) = resolvers(log);
    final a = await r.resolvePlayUrl(
      'empty-id-cache-3a',
      MusicPlatform.wy,
      AudioQuality.hires,
      'Same Title',
    );
    final b = await r.resolvePlayUrl(
      'empty-id-cache-3b',
      MusicPlatform.wy,
      AudioQuality.hires,
      'Same Title',
    );
    expect(a!.url, 'https://example.com/empty-id-cache-3a.flac');
    expect(b!.url, 'https://example.com/empty-id-cache-3b.flac');
  });
}
