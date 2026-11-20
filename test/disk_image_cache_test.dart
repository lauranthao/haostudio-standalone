// P1-P1: disk image cache round-trip + MusicImageProvider downsample key.
//
// The disk cache is keyed by URL (SHA-256 file name) and is best-effort:
// a miss returns null and the caller falls through to the network.

import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/cache/disk_image_cache.dart';
import 'package:standalone/features/music/widgets/music_image.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('hao-disk-image-cache-');
    DiskImageCache.setDirectoryForTest(tmp);
  });

  tearDown(() async {
    DiskImageCache.resetForTest();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('miss returns null, put/get round-trips bytes', () async {
    expect(await DiskImageCache.get('https://example.com/a.jpg'), isNull);
    final bytes = [0, 1, 2, 3, 255];
    await DiskImageCache.put('https://example.com/a.jpg', bytes);
    expect(await DiskImageCache.get('https://example.com/a.jpg'), bytes);
    // A different URL is a different entry.
    expect(await DiskImageCache.get('https://example.com/b.jpg'), isNull);
  });

  test('put overwrites the same URL', () async {
    await DiskImageCache.put('https://example.com/a.jpg', [1, 2]);
    await DiskImageCache.put('https://example.com/a.jpg', [3, 4, 5]);
    expect(await DiskImageCache.get('https://example.com/a.jpg'), [3, 4, 5]);
  });

  test('provider obtainKey derives the downsample size from layout', () async {
    const provider = MusicImageProvider('https://example.com/cover.jpg');
    final key = await provider.obtainKey(
      const ImageConfiguration(size: Size(100, 50), devicePixelRatio: 2.0),
    );
    expect(key.cacheWidth, 200);
    expect(key.cacheHeight, 100);
    // No layout size: no downsampling.
    final fullKey = await provider.obtainKey(const ImageConfiguration());
    expect(fullKey.cacheWidth, isNull);
    expect(fullKey.cacheHeight, isNull);
  });
}
