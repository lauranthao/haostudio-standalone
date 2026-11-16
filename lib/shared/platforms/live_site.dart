// LiveSite contract — Pure Live 3.x lib/shared/platforms/live_site.dart.
//
// The base class carries default implementations returning empty, so an
// adapter only implements what its platform supports. Scope is ONLY the
// Big-5 (Bilibili, Douyu, Huya, Douyin, Kuaishou); the other 29 Pure Live
// platforms are NOT added.
//
// Key rules carried by the models:
// - getPlayUrls returns an ORDERED URL list = CDN lines for that quality;
//   index = line. Line buttons show only "线路 N", never CDN names.
// - LivePlayUrlResolution carries appliedQualityData (what the server
//   ACTUALLY applied — anonymous requests get silently downgraded),
//   qualityUnconfirmed, refreshAt (~100 s after issue, Huya) and invalidAt
//   (~125 s, Huya), plus streamFacts (format/codec) so the player decides
//   direct/remux/probe from facts, never by platform if-branches.
// - Lines are identified by URL (CDN + path + credential family), NOT by
//   index — a refresh can turn a TX FLV line into TX HLS.

import '../../core/models/live_models.dart';

/// Per-URL stream facts (LivePlayStreamFacts).
class LiveStreamFacts {
  const LiveStreamFacts({
    required this.format,
    this.codec,
  });

  /// flv | hls | other (declared format — wins over URL suffix).
  final String format;

  /// avc | hevc, when known.
  final String? codec;
}

/// Resolved play URLs for one quality (LivePlayUrlResolution).
class LivePlayUrlResolution {
  const LivePlayUrlResolution({
    required this.urls,
    this.appliedQualityData,
    this.qualityUnconfirmed = false,
    this.issuedAt,
    this.refreshAt,
    this.invalidAt,
    this.streamFacts = const [],
  });

  /// Ordered URL list = CDN lines for this quality; index = line.
  final List<String> urls;

  /// What the server actually applied (may differ from the request).
  final dynamic appliedQualityData;

  /// Server did not confirm the quality.
  final bool qualityUnconfirmed;

  /// When this resolution was issued (for refresh/invalid math).
  final DateTime? issuedAt;

  /// Proactive refresh deadline (~100 s after issue, Huya).
  final DateTime? refreshAt;

  /// Hard expiry (~125 s after issue, Huya).
  final DateTime? invalidAt;

  /// One fact entry per URL, same order as [urls].
  final List<LiveStreamFacts> streamFacts;

  bool get isEmpty => urls.isEmpty;

  /// The facts for one URL, by index (falls back to unknown facts).
  LiveStreamFacts factsFor(int index) {
    if (index >= 0 && index < streamFacts.length) return streamFacts[index];
    return const LiveStreamFacts(format: 'other');
  }
}

/// Danmaku transport contract (live_danmaku.dart).
abstract class LiveDanmaku {
  void Function(LiveMessage message)? onMessage;
  void Function()? onReconnect;
  void Function()? onClose;
  void Function()? onReady;

  bool get isConnected;

  Future<void> heartbeat();
  Future<void> start(Map<String, dynamic> args);
  Future<void> stop();
}

/// Null-object danmaku for platforms without a transport.
class EmptyDanmaku extends LiveDanmaku {
  @override
  bool get isConnected => false;

  @override
  Future<void> heartbeat() async {}

  @override
  Future<void> start(Map<String, dynamic> args) async {}

  @override
  Future<void> stop() async {}
}

/// The platform adapter contract (LiveSite, 3.x shape).
abstract class LiveSite {
  String get id;
  String get name;

  LiveDanmaku getDanmaku() => EmptyDanmaku();

  Future<List<LiveArea>> getCategories({int page = 1, int pageSize = 30}) async => [];

  Future<List<LiveRoom>> searchRooms(
    String keyword, {
    int page = 1,
    int pageSize = 30,
  }) async =>
      [];

  Future<List<LiveRoom>> searchAnchors(
    String keyword, {
    int page = 1,
    int pageSize = 30,
  }) async =>
      [];

  Future<List<LiveRoom>> getCategoryRooms(
    LiveArea area, {
    int page = 1,
    int pageSize = 30,
  }) async =>
      [];

  Future<List<LiveRoom>> getRecommendRooms({
    int page = 1,
    int pageSize = 30,
  }) async =>
      [];

  /// Full metadata + play/danmaku descriptors in LiveRoom.data/danmakuData.
  Future<LiveRoom> getRoomDetail(LiveRoom room) async => room;

  Future<List<LivePlayQuality>> getPlayQualities({
    required LiveRoom liveRoom,
  }) async =>
      [];

  /// Ordered URL list = CDN lines for that quality; index = line.
  Future<List<String>> getPlayUrls({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async =>
      [];

  /// Full resolution (with applied-quality ack + lease times). Falls back
  /// to getPlayUrls when the adapter does not implement the resolver.
  Future<LivePlayUrlResolution> resolvePlayUrls({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    final urls = await getPlayUrls(liveRoom: liveRoom, quality: quality);
    return LivePlayUrlResolution(urls: urls, issuedAt: DateTime.now());
  }

  /// Recovery resolution — MUST re-fetch all identity/token/room fields;
  /// returning cached URLs is a no-op. Falls back to resolvePlayUrls.
  Future<LivePlayUrlResolution> resolvePlayUrlsForRecovery({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async =>
      resolvePlayUrls(liveRoom: liveRoom, quality: quality);

  /// Proactive refresh deadline for one URL (Huya implements; default
  /// null = no proactive refresh).
  DateTime? getPlayUrlRefreshAt(String url) => null;

  /// Hard expiry for one URL (Huya implements; default null).
  DateTime? getPlayUrlInvalidAt(String url) => null;

  Future<List<LiveMessage>> getSuperChatMessage({
    required LiveRoom liveRoom,
  }) async =>
      [];
}
