// Music image provider — drop-in replacement for NetworkImage.
//
// Why this exists (v1.0.5 phone bug): every music cover/avatar loaded via
// Image.network / NetworkImage failed on chen's phone — player cover stuck
// on the note placeholder, search artist avatars all empty blue circles —
// even though the URLs are valid (NetEase API returns real picUrl) and the
// CDNs serve the bytes to curl with any UA. The music APIs themselves work
// on the phone (they go through Dio), so images go through the same stack:
// sharedDio with a browser UA + per-host Referer, bytes cached in memory,
// decoded via MemoryImage path. One retry on failure; on total failure the
// load throws so the caller's errorBuilder / placeholder shows.
//
// Per-host Referer (hotlink protection on some CDN edges):
// - music.126.net (NetEase) -> https://music.163.com/
// - y.gtimg.cn (QQ) -> https://y.qq.com/
// - *.kuwo.cn (Kuwo) -> https://www.kuwo.cn/
// - anything else -> no Referer, UA only.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../../core/cache/disk_image_cache.dart';
import '../../../core/network/http_client.dart';

final Map<String, Uint8List> _musicImageBytesCache = <String, Uint8List>{};

/// In-memory cover cache cap (2026-11-17): the cache had NO eviction —
/// with full-res covers it could hold hundreds of MB. Evict oldest
/// first (Dart maps keep insertion order) once past 80 entries.
const int _kMusicImageCacheMax = 80;

void _cacheMusicImageBytes(String url, Uint8List bytes) {
  while (_musicImageBytesCache.length >= _kMusicImageCacheMax) {
    _musicImageBytesCache.remove(_musicImageBytesCache.keys.first);
  }
  _musicImageBytesCache[url] = bytes;
}

String musicImageReferer(String url) {
  if (url.contains('music.126.net')) return 'https://music.163.com/';
  if (url.contains('y.gtimg.cn')) return 'https://y.qq.com/';
  if (url.contains('kuwo.cn')) return 'https://www.kuwo.cn/';
  return '';
}

/// Fetch cover bytes: memory cache -> disk cache (P1-P1) -> network.
/// A network hit is written to the disk cache (fire-and-forget) so the
/// next cold start does not re-download it.
Future<Uint8List> fetchMusicImageBytes(String url) async {
  final cached = _musicImageBytesCache[url];
  if (cached != null) return cached;
  final onDisk = await DiskImageCache.get(url);
  if (onDisk != null && onDisk.isNotEmpty) {
    final bytes = Uint8List.fromList(onDisk);
    _cacheMusicImageBytes(url, bytes);
    return bytes;
  }
  final dio = sharedDio();
  final referer = musicImageReferer(url);
  DioException? lastError;
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final res = await dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          // Explicit: sharedDio defaults to 8 s, but a cover fetch
          // must never hang past it (a stalled cover used to hold the
          // row on the placeholder indefinitely).
          receiveTimeout: const Duration(seconds: 8),
          headers: <String, String>{
            'User-Agent': kBrowserUserAgent,
            'Accept': 'image/*,*/*',
            if (referer.isNotEmpty) 'Referer': referer,
          },
        ),
      );
      final code = res.statusCode ?? 0;
      final data = res.data;
      if (code >= 200 && code < 300 && data != null && data.isNotEmpty) {
        final bytes = Uint8List.fromList(data);
        _cacheMusicImageBytes(url, bytes);
        unawaited(DiskImageCache.put(url, bytes));
        return bytes;
      }
      lastError = DioException(
        requestOptions: res.requestOptions,
        response: res,
        type: DioExceptionType.badResponse,
      );
    } on DioException catch (e) {
      lastError = e;
    }
  }
  throw lastError ?? StateError('music image fetch failed: $url');
}

/// Saturation-weighted average color of an image (cheap dominant-color
/// estimate, no new dependency). Skips near-black / near-white /
/// transparent pixels so the tint reads as the cover's color. Returns null
/// when the bytes cannot be decoded or no pixel qualifies.
///
/// P1-P2: the decode is downsampled to [targetWidth] (200 px) first —
/// a tint needs no more than that, and decoding the full 800x800 cover
/// on the UI thread on every track change was the hot path.
Future<Color?> dominantCoverColor(
  Uint8List bytes, {
  int targetWidth = 200,
}) async {
  try {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: targetWidth,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    final pixels = data.buffer.asUint8List();
    final total = image.width * image.height;
    final step = (total / 2000).ceil().clamp(1, 64);
    var rSum = 0.0;
    var gSum = 0.0;
    var bSum = 0.0;
    var wSum = 0.0;
    for (var i = 0; i + 3 < pixels.length; i += 4 * step) {
      final r = pixels[i];
      final g = pixels[i + 1];
      final b = pixels[i + 2];
      final a = pixels[i + 3];
      if (a < 128) continue;
      final mx = math.max(r, math.max(g, b));
      final mn = math.min(r, math.min(g, b));
      if (mx == 0) continue;
      final sat = (mx - mn) / mx;
      final light = (mx + mn) / 2 / 255;
      if (light < 0.08 || light > 0.92) continue;
      final wgt = sat + 0.15;
      rSum += r * wgt;
      gSum += g * wgt;
      bSum += b * wgt;
      wSum += wgt;
    }
    if (wSum <= 0) return null;
    return Color.fromRGBO(
      (rSum / wSum).round(),
      (gSum / wSum).round(),
      (bSum / wSum).round(),
      1,
    );
  } catch (_) {
    return null;
  }
}

/// Tint cache, keyed by cover URL (P1-P2): switching back to a song
/// reuses its tint instead of re-decoding the cover. Only successful
/// tints are cached — a failed fetch must retry next time.
final Map<String, Color> _coverTintCache = <String, Color>{};
const int _kCoverTintCacheMax = 80;

/// Dominant color for a cover URL: bytes come from the shared image
/// cache (no second download), the decode is downsampled to 200 px
/// wide, and the result is cached by URL. Returns null on any failure.
Future<Color?> coverTintForUrl(String url) async {
  final cached = _coverTintCache[url];
  if (cached != null) return cached;
  Color? tint;
  try {
    final bytes = await fetchMusicImageBytes(url);
    tint = await dominantCoverColor(bytes);
  } catch (_) {
    tint = null;
  }
  if (tint != null) {
    while (_coverTintCache.length >= _kCoverTintCacheMax) {
      _coverTintCache.remove(_coverTintCache.keys.first);
    }
    _coverTintCache[url] = tint;
  }
  return tint;
}

class MusicImageProvider extends ImageProvider<MusicImageProvider> {
  const MusicImageProvider(this.url, {this.cacheWidth, this.cacheHeight});

  final String url;

  /// Downsample target in physical pixels (P1-P1): set from the
  /// layout size in [obtainKey], so a 48 px avatar never decodes the
  /// full 800 px cover. Null = decode at full resolution.
  final int? cacheWidth;
  final int? cacheHeight;

  @override
  Future<MusicImageProvider> obtainKey(ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null) return SynchronousFuture<MusicImageProvider>(this);
    final dpr = configuration.devicePixelRatio ?? 1.0;
    return SynchronousFuture<MusicImageProvider>(
      MusicImageProvider(
        url,
        cacheWidth: (size.width * dpr).ceil(),
        cacheHeight: (size.height * dpr).ceil(),
      ),
    );
  }

  @override
  ImageStreamCompleter loadImage(
    MusicImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
      debugLabel: key.url,
    );
  }

  Future<ui.Codec> _loadAsync(
    MusicImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await fetchMusicImageBytes(key.url);
    if (bytes.lengthInBytes == 0) {
      throw StateError('music image empty: ${key.url}');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    // Downsample to the layout size (P1-P1): this Flutter's decode
    // callback takes a getTargetSize, not cacheWidth/cacheHeight
    // (same contract as ResizeImage). Fit inside the layout box,
    // preserving aspect, never upscale.
    return decode(
      buffer,
      getTargetSize: (intrinsicWidth, intrinsicHeight) {
        final cw = key.cacheWidth;
        final ch = key.cacheHeight;
        if (cw == null && ch == null) {
          return const ui.TargetImageSize();
        }
        final aspectRatio = intrinsicWidth / intrinsicHeight;
        final maxWidth = cw ?? intrinsicWidth;
        final maxHeight = ch ?? intrinsicHeight;
        var targetWidth = intrinsicWidth;
        var targetHeight = intrinsicHeight;
        if (targetWidth > maxWidth) {
          targetWidth = maxWidth;
          targetHeight = targetWidth ~/ aspectRatio;
        }
        if (targetHeight > maxHeight) {
          targetHeight = maxHeight;
          targetWidth = (targetHeight * aspectRatio).floor();
        }
        return ui.TargetImageSize(
          width: targetWidth,
          height: targetHeight,
        );
      },
    );
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is MusicImageProvider &&
        other.url == url &&
        other.cacheWidth == cacheWidth &&
        other.cacheHeight == cacheHeight;
  }

  @override
  int get hashCode => Object.hash(url, cacheWidth, cacheHeight);

  @override
  String toString() => 'MusicImageProvider("$url")';
}
