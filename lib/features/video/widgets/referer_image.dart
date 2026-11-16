// Image loader for video posters (home / history / detail).
//
// Why plain Image.network is NOT used here (v1.0.5 phone bug): posters
// loaded via Image.network show as black tiles on chen's phone — the
// same failure mode as the v1.0.5 music covers — even though the URLs
// are valid and the CDNs serve the bytes to curl with any UA
// (verified: image.jinyingimage.com + fffgood.com return 200 with the
// Dart UA too). The Dio stack (browser UA via sharedDio) loads them
// fine on the phone, so all video posters go through here.
// Douban's image CDN (img*.doubanio.com) additionally answers 418 to
// requests without a Douban Referer, so that header is added for
// doubanio hosts. History pics can BE Douban posters: Douban
// enrichment replaces meta.pic with the Douban poster, and the player
// records that pic into history.
//
// Non-Douban URLs are fetched without a Referer (the header would be
// meaningless — and possibly harmful — for other hosts).

import 'dart:collection';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../../core/network/http_client.dart';

/// In-memory bytes cache: home/history lists rebuild + dispose cards on
/// scroll, so without this every scroll-back re-fetches every poster.
/// Bounded (100 entries, oldest evicted) so it can't grow without limit.
final LinkedHashMap<String, Uint8List> _videoImageBytesCache =
    LinkedHashMap<String, Uint8List>();

void _cacheVideoImageBytes(String url, Uint8List bytes) {
  _videoImageBytesCache[url] = bytes;
  while (_videoImageBytesCache.length > 100) {
    _videoImageBytesCache.remove(_videoImageBytesCache.keys.first);
  }
}

class RefererImage extends StatefulWidget {
  const RefererImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.fallback,
  });

  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;

  /// Shown while loading and on any failure (null → blank).
  final Widget? fallback;

  @override
  State<RefererImage> createState() => _RefererImageState();
}

class _RefererImageState extends State<RefererImage> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant RefererImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    final url = widget.url;
    if (url.isEmpty) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    final cached = _videoImageBytesCache[url];
    if (cached != null) {
      if (mounted) setState(() => _bytes = cached);
      return;
    }
    try {
      final isDouban =
          Uri.tryParse(url)?.host.contains('doubanio.com') ?? false;
      final res = await sharedDio().get<List<int>>(
        url,
        options: Options(
          headers: <String, String>{
            if (isDouban) 'Referer': 'https://movie.douban.com/',
            'Accept': 'image/*',
          },
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
        ),
      );
      // The card may have been recycled for another poster while the
      // fetch was in flight (grid rebuild on scroll): never deliver
      // stale bytes — or a stale failure — into the new URL.
      if (!mounted || widget.url != url) return;
      final data = res.data;
      if (res.statusCode != 200 || data == null || data.isEmpty) {
        setState(() => _failed = true);
        return;
      }
      final bytes = Uint8List.fromList(data);
      _cacheVideoImageBytes(url, bytes);
      setState(() => _bytes = bytes);
    } catch (_) {
      if (mounted && widget.url == url) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (_failed || bytes == null) {
      return widget.fallback ?? const SizedBox.shrink();
    }
    return Image.memory(
      bytes,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
    );
  }
}
