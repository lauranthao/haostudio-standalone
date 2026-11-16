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

import '../../../core/network/http_client.dart';

final Map<String, Uint8List> _musicImageBytesCache = <String, Uint8List>{};

String musicImageReferer(String url) {
  if (url.contains('music.126.net')) return 'https://music.163.com/';
  if (url.contains('y.gtimg.cn')) return 'https://y.qq.com/';
  if (url.contains('kuwo.cn')) return 'https://www.kuwo.cn/';
  return '';
}

Future<Uint8List> fetchMusicImageBytes(String url) async {
  final cached = _musicImageBytesCache[url];
  if (cached != null) return cached;
  final dio = sharedDio();
  final referer = musicImageReferer(url);
  DioException? lastError;
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final res = await dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
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
        _musicImageBytesCache[url] = bytes;
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
Future<Color?> dominantCoverColor(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
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

class MusicImageProvider extends ImageProvider<MusicImageProvider> {
  const MusicImageProvider(this.url);

  final String url;

  @override
  Future<MusicImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<MusicImageProvider>(this);
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
    assert(key == this);
    final bytes = await fetchMusicImageBytes(key.url);
    if (bytes.lengthInBytes == 0) {
      throw StateError('music image empty: ${key.url}');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is MusicImageProvider && other.url == url;
  }

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'MusicImageProvider("$url")';
}
