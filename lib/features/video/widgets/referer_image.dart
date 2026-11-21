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

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../../core/cache/disk_image_cache.dart';
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
    this.headers,
  });

  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;

  /// Shown while loading and on any failure (null → blank).
  final Widget? fallback;

  /// Extra request headers (Emby: `X-Emby-Token`). The URL itself
  /// stays credential-free, so it remains a safe cache key. The
  /// built-in Douban Referer / Accept headers are added alongside.
  final Map<String, String>? headers;

  @override
  State<RefererImage> createState() => _RefererImageState();
}

class _RefererImageState extends State<RefererImage> {
  Uint8List? _bytes;
  bool _failed = false;

  /// D-P2-1: one automatic retry, 2 s after the first failure.
  bool _retried = false;
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant RefererImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        !_headersEqual(oldWidget.headers, widget.headers)) {
      _bytes = null;
      _failed = false;
      _retried = false;
      _retryTimer?.cancel();
      _load();
    }
  }

  static bool _headersEqual(
    Map<String, String>? a,
    Map<String, String>? b,
  ) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return a == null && b == null;
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  /// First failure schedules one retry 2 s later (D-P2-1); the
  /// second failure is terminal. Scroll-back rebuilds already
  /// reload from scratch, so one retry is all this needs.
  void _failOnce() {
    if (!mounted || widget.url.isEmpty) return;
    if (!_retried) {
      _retried = true;
      final url = widget.url;
      _retryTimer = Timer(const Duration(seconds: 2), () {
        if (mounted && widget.url == url) _load();
      });
      return;
    }
    setState(() => _failed = true);
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
    // Disk cache (P1-P1): a poster fetched in a previous session
    // must not be re-downloaded on every cold start / scroll-back.
    final onDisk = await DiskImageCache.get(url);
    if (onDisk != null && onDisk.isNotEmpty) {
      final bytes = Uint8List.fromList(onDisk);
      _cacheVideoImageBytes(url, bytes);
      if (mounted && widget.url == url) setState(() => _bytes = bytes);
      return;
    }
    try {
      final isDouban =
          Uri.tryParse(url)?.host.contains('doubanio.com') ?? false;
      final res = await sharedDio().get<List<int>>(
        url,
        options: Options(
          headers: <String, String>{
            ...?widget.headers,
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
        _failOnce();
        return;
      }
      final bytes = Uint8List.fromList(data);
      _cacheVideoImageBytes(url, bytes);
      unawaited(DiskImageCache.put(url, bytes));
      setState(() => _bytes = bytes);
    } catch (_) {
      if (mounted && widget.url == url) _failOnce();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (_failed || bytes == null) {
      return widget.fallback ?? const SizedBox.shrink();
    }
    // G-P1-2: downsample from the LAYOUT size, not from an
    // opt-in widget.width/height — the five hottest call sites
    // (poster wall, live/follow/search cards, detail hero) never
    // passed one, so every poster decoded at full resolution.
    // LayoutBuilder reads the constraints the parent already gives
    // this image; an explicit widget size still wins, and an
    // unbounded layout falls back to no downsampling (as before).
    return LayoutBuilder(
      builder: (context, constraints) {
        final layoutWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : null;
        final layoutHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : null;
        final width = widget.width ?? layoutWidth;
        final height = widget.height ?? layoutHeight;
        return Image.memory(
          bytes,
          width: width,
          height: height,
          fit: widget.fit,
          // Downsample the decode to the displayed size (P1-P1): a grid
          // card never needs the full-resolution poster decoded.
          cacheWidth: _cacheDimension(width),
          cacheHeight: _cacheDimension(height),
        );
      },
    );
  }

  int? _cacheDimension(double? logical) {
    if (logical == null) return null;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final px = (logical * dpr).ceil();
    return px > 0 ? px : null;
  }
}
