// Real brand logos for the music platforms (chen 2026-11-18:
// "平台的logo用真实logo啊"). The generic ♪ note is NOT a platform
// identity — the picker sheet and the search capsule used it for
// every platform, so the user could not tell them apart at a glance.
//
// Source: the official App Store app icons (512px, Apple CDN
// is*-ssl.mzstatic.com, verified against bundle id + seller):
//   wy 网易云音乐 com.netease.cloudmusic (杭州网易云音乐)
//   tx QQ音乐 com.tencent.QQMusic (Tencent)
//   kg 酷狗音乐 com.kugou.kugou1002 (Guangzhou KuGou)
//   kw 酷我音乐 com.yeelion.kwplayer (Kuwo Tianjin)
// Bundled as assets so they work offline and look identical in all
// four themes, light and dark — brand artwork is never re-tinted.
// The artwork is a full square, so it is always clipped with the
// iOS app-icon corner ratio (≈22%) to read as an app icon and never
// show a white square corner in dark mode.

import 'package:flutter/material.dart';

import '../services/music/music_models.dart';

/// Square brand logo for [platform], clipped to app-icon corners.
class PlatformLogo extends StatelessWidget {
  const PlatformLogo({
    super.key,
    required this.platform,
    required this.size,
    this.radius,
  });

  final MusicPlatform platform;
  final double size;

  /// Corner radius. Null = iOS app-icon ratio (22% of [size]).
  final double? radius;

  /// Bundled asset for [platform], or null when there is no brand
  /// logo for it (咪咕 has no picker/capsule presence; callers fall
  /// back to a generic note).
  static String? assetFor(MusicPlatform platform) {
    switch (platform) {
      case MusicPlatform.wy:
      case MusicPlatform.tx:
      case MusicPlatform.kg:
      case MusicPlatform.kw:
        return 'assets/logos/${platform.code}.jpg';
      case MusicPlatform.mg:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final asset = assetFor(platform);
    if (asset == null) {
      return SizedBox(
        width: size,
        height: size,
        child: Icon(Icons.music_note, size: size * 0.7),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius ?? size * 0.22),
      child: Image.asset(
        asset,
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );
  }
}
