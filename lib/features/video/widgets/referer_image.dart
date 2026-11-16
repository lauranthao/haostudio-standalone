// Image loader for Douban-hosted images.
//
// Douban's image CDN (img*.doubanio.com) answers 418 to requests
// without a Douban Referer, so plain Image.network shows nothing.
// This widget fetches the bytes with Dio (Referer:
// https://movie.douban.com/ for doubanio hosts) and renders a
// MemoryImage, falling back to [fallback] while loading and on any
// failure.
//
// Non-Douban URLs are fetched without a Referer (the header would be
// meaningless — and possibly harmful — for other hosts).

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../../core/network/http_client.dart';

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
      if (!mounted) return;
      final data = res.data;
      if (res.statusCode != 200 || data == null || data.isEmpty) {
        setState(() => _failed = true);
        return;
      }
      setState(() => _bytes = Uint8List.fromList(data));
    } catch (_) {
      if (mounted) setState(() => _failed = true);
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
