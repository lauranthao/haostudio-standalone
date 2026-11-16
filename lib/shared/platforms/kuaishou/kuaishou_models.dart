// Kuaishou play-descriptor models.
//
// Kuaishou room detail / recommend cards carry `playUrls`: a list of
// descriptors, each with `adaptationSet.representation[]` (one entry per
// quality, each with a signed URL). `LiveRoom.data` holds the raw value
// under the `playUrls` key so qualities can be re-parsed without another
// network round-trip; `LivePlayQuality.data` holds the resolved URL list
// for one quality plus one [LiveStreamFacts] entry per URL.

import '../live_site.dart';
import '../../../core/models/live_models.dart';

/// The resolved lines for one Kuaishou quality: ordered URLs (index =
/// line) plus the declared format/codec for each URL, in the same order.
class KuaishouQualityData {
  const KuaishouQualityData({
    required this.urls,
    required this.facts,
  });

  final List<String> urls;

  /// One fact entry per URL, same order as [urls].
  final List<LiveStreamFacts> facts;

  static const String keyUrls = 'urls';
  static const String keyFormats = 'formats';
  static const String keyCodecs = 'codecs';

  Map<String, dynamic> toDataMap() => <String, dynamic>{
        keyUrls: List<String>.unmodifiable(urls),
        keyFormats: List<String>.unmodifiable(
          facts.map((f) => f.format),
        ),
        keyCodecs: List<String?>.unmodifiable(
          facts.map((f) => f.codec),
        ),
      };

  static KuaishouQualityData? fromDataMap(dynamic data) {
    if (data is! Map) return null;
    final urls = data[keyUrls];
    if (urls is! List) return null;
    final urlList = urls.map((u) => u.toString()).toList(growable: false);
    if (urlList.isEmpty) return null;
    final formats = data[keyFormats];
    final codecs = data[keyCodecs];
    final facts = <LiveStreamFacts>[];
    for (var i = 0; i < urlList.length; i++) {
      final format = formats is List && i < formats.length
          ? formats[i]?.toString() ?? 'other'
          : kuaishouStreamFormat(urlList[i]);
      final codec = codecs is List && i < codecs.length
          ? codecs[i]?.toString()
          : null;
      facts.add(LiveStreamFacts(format: format, codec: codec));
    }
    return KuaishouQualityData(urls: urlList, facts: facts);
  }
}

/// Declared stream format for one Kuaishou play URL, from its path
/// suffix (the server signs the transport into the URL itself — no
/// re-signing, no format field on the representation). Unknown suffixes
/// report `other` so the player probes instead of assuming.
String kuaishouStreamFormat(String url) {
  final path = url.split('?').first.toLowerCase();
  if (path.endsWith('.m3u8')) return 'hls';
  if (path.endsWith('.flv')) return 'flv';
  return 'other';
}

/// The room's raw Kuaishou `playUrls` descriptor value, if it has one.
/// Stored under `playUrls` in `LiveRoom.data` by getRoomDetail and by
/// the recommend/search list parsers.
dynamic kuaishouPlayUrlsOf(LiveRoom room) => room.data?['playUrls'];
