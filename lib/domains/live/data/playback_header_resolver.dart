// Playback HTTP headers — port of Pure Live 3.x
// lib/domains/live/data/playback_header_resolver.dart (huya + douyu
// cases; other platforms keep the room's own headers, same as PL's
// default branch).
//
// Root cause of "斗鱼虎牙只放几秒就放不了" (v1.0.6 phone report):
// our room opened EVERY live stream with NO headers at all, so mpv
// sent its default UA and no Referer/Origin. Huya's CDN treats a
// header-less request as a leecher and closes the FLV connection
// after a short burst — measured with ffmpeg on a real Huya URL:
// no headers -> ~6.5-7 s of video, then "Stream ends prematurely";
// with PL's headers (HYSDK UA + Origin + Referer) -> the SAME URL
// plays 25 s+ continuously, no cutoff. Douyu's CDN does not cut as
// fast, but PL sends the same header set there too, so we do as well.
// The previous round's fixes (Huya default 8M, auto-downgrade, mpv
// tuning) were built on a wrong diagnosis — "蓝光50M" is NOT 50 Mbps
// (ffprobe: 2560x1440 @ ~8.2 Mbps) — and never addressed this.
//
// Huya UA: PL uses `HuyaSite.playUserAgent ?? nativePlayUserAgent`;
// this app does not fetch play_config.json, so the fallback applies —
// the HYSDK UA (`hysdkUa`), verified working by the ffmpeg probe.
// Douyu cookie: the anonymous dy_did of the SAME device id that
// signed the stream URL (passed in by the room page from its site
// instance); PL sends it via its process-wide session device id.
import '../../../shared/platforms/douyu/douyu_utils.dart';
import '../../../shared/platforms/huya/huya_request_params.dart';
import '../../../shared/platforms/sites.dart';

class PlaybackHeaderResolver {
  const PlaybackHeaderResolver._();

  static Map<String, String> resolve({
    required String platform,
    String roomId = '',
    String douyuCookie = '',
  }) {
    final normalizedRoomId = Uri.encodeComponent(roomId.trim());
    switch (platform.trim().toLowerCase()) {
      case Sites.huyaSite:
        return <String, String>{
          'user-agent': HuyaRequestParams.hysdkUa,
          'origin': 'https://www.huya.com',
          'referer': normalizedRoomId.isEmpty
              ? 'https://www.huya.com/'
              : 'https://www.huya.com/$normalizedRoomId',
        };
      case Sites.douyuSite:
        return <String, String>{
          'origin': 'https://www.douyu.com',
          'referer': normalizedRoomId.isEmpty
              ? 'https://www.douyu.com/'
              : 'https://www.douyu.com/$normalizedRoomId',
          'user-agent': DouyuUtils.userAgent,
          if (douyuCookie.isNotEmpty) 'cookie': douyuCookie,
        };
      default:
        return const <String, String>{};
    }
  }
}
