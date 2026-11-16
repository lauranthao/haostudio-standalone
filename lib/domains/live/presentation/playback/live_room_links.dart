// Open-in-platform-App deep links + share (L05).
//
// Pure Live's `RoomExternalOpener` + per-site `externalRoomTarget`
// (liuchuancong/pure_live 3.x), translated to this app's [LiveRoom]:
//
// | platform | native deep link | web fallback |
// |---|---|---|
// | bilibili | `bilibili://live/{id}` | `https://live.bilibili.com/{id}` |
// | douyin | `snssdk1128://webcast_room?room_id={roomId}` (numeric room id from danmakuData) | `https://live.douyin.com/{webRid}` |
// | huya | `yykiwi://...` with `subSid` from danmakuData | `https://www.huya.com/{id}` |
// | douyu | `douyulink://?type=90001&schemeUrl=douyuapp%3A%2F%2Froom%3FliveType%3D0%26rid%3D{id}` | `https://www.douyu.com/{id}` |
// | kuaishou | `kwai://liveaggregatesquare?liveStreamId={link}&...` (link = liveStreamId) | `https://live.kuaishou.com/u/{id}` |
//
// Behaviour (same as Pure Live): try the native link first; when the
// app is not installed (launch fails) fall back to the web URL. A
// platform with no usable native link goes straight to the web URL.
// Deep links need a real-device test per platform — the schemes are
// copied from Pure Live, not verified on chen's phone yet.

import 'package:url_launcher/url_launcher.dart';

import '../../../../core/models/live_models.dart';

/// Native deep link + web URL for one room. Either may be null when
/// the room carries nothing to build it from — never a fake link.
class RoomExternalTarget {
  const RoomExternalTarget({this.native, this.web});

  final String? native;
  final String? web;
}

/// Resolve the external target for [room]. The room id is sanitized
/// (alphanumerics + `_`/`-` only); anything else yields no target
/// rather than an injected URL.
RoomExternalTarget? externalTargetFor(LiveRoom room) {
  final id = _sanitizedRoomId(room.roomId);
  if (id == null) return null;
  switch (room.platform) {
    case 'bilibili':
      return RoomExternalTarget(
        native: 'bilibili://live/$id',
        web: 'https://live.bilibili.com/$id',
      );
    case 'douyin':
      final data = room.danmakuData;
      final numericId = data?['roomId']?.toString();
      final webRid = data?['webRid']?.toString() ?? id;
      return RoomExternalTarget(
        native: numericId != null && numericId.isNotEmpty
            ? 'snssdk1128://webcast_room?room_id=${Uri.encodeComponent(numericId)}'
            : null,
        web: 'https://live.douyin.com/${Uri.encodeComponent(webRid)}',
      );
    case 'huya':
      final subSid = room.danmakuData?['subSid'];
      final sub = subSid is num
          ? subSid.toInt()
          : int.tryParse(subSid?.toString() ?? '');
      return RoomExternalTarget(
        native: sub != null && sub > 0
            ? 'yykiwi://homepage/index.html?banneraction=https%3A%2F%2Fdiy-front.cdn.huya.com%2Fzt%2Ffrontpage%2Fcc%2Fupdate.html%3Fhyaction%3Dlive%26channelid%3D$sub%26subid%3D$sub%26liveuid%3D$sub%26screentype%3D1%26sourcetype%3D0%26fromapp%3Dhuya_wap%252Fclick%252Fopen_app_guide%26&fromapp=huya_wap/click/open_app_guide'
            : null,
        web: 'https://www.huya.com/$id',
      );
    case 'douyu':
      return RoomExternalTarget(
        native:
            'douyulink://?type=90001&schemeUrl=douyuapp%3A%2F%2Froom%3FliveType%3D0%26rid%3D$id',
        web: 'https://www.douyu.com/$id',
      );
    case 'kuaishou':
      final stream = room.link.trim();
      final encoded = Uri.encodeQueryComponent(stream);
      return RoomExternalTarget(
        native: stream.isEmpty
            ? null
            : 'kwai://liveaggregatesquare?liveStreamId=$encoded&recoStreamId=$encoded&recoLiveStreamId=$encoded&liveSquareSource=28&path=/rest/n/live/feed/sharePage/slide/more&mt_product=H5_OUTSIDE_CLIENT_SHARE',
        web: 'https://live.kuaishou.com/u/$id',
      );
    default:
      return null;
  }
}

/// Web URL for sharing. Falls back to [room.link] when the platform
/// has no web target, and to '' when there is nothing shareable.
String shareUrlFor(LiveRoom room) {
  final target = externalTargetFor(room);
  if (target?.web != null && target!.web!.isNotEmpty) return target.web!;
  return room.link;
}

/// Share text: title + anchor + web URL (the URL is what makes the
/// share openable; no fake text when the URL is missing).
String shareTextFor(LiveRoom room) {
  final url = shareUrlFor(room);
  final title = room.title.isEmpty ? room.nick : room.title;
  if (url.isEmpty) return title;
  if (title.isEmpty) return url;
  return '$title\n$url';
}

enum RoomExternalOpenResult { opened, unavailable, failed }

/// Open [room] in its platform App (native deep link first, web
/// fallback), mirroring Pure Live's `RoomExternalOpener.open`.
/// [launch] is a test seam; production passes none and uses
/// url_launcher with external-application mode.
Future<RoomExternalOpenResult> openInPlatformApp(
  LiveRoom room, {
  Future<bool> Function(String url)? launch,
}) async {
  final target = externalTargetFor(room);
  if (target == null) return RoomExternalOpenResult.unavailable;
  Future<bool> attempt(String url) async {
    try {
      if (launch != null) return await launch(url);
      return await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }

  final native = target.native;
  if (native != null && native != target.web) {
    if (await attempt(native)) return RoomExternalOpenResult.opened;
    // Native failed (app not installed) — fall through to web.
  }
  final web = target.web;
  if (web == null) return RoomExternalOpenResult.failed;
  return await attempt(web)
      ? RoomExternalOpenResult.opened
      : RoomExternalOpenResult.failed;
}

/// Room ids are platform ids / numeric ids; anything with a slash,
/// space, query or fragment is not a room id — refuse it rather than
/// building an injected URL.
String? _sanitizedRoomId(String roomId) {
  final id = roomId.trim();
  if (id.isEmpty) return null;
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) return null;
  return id;
}
