// Music models — ported from the old web app (app.js record shapes).
//
// Song: {songId, title, artist, album, cover, platform, dur (seconds)}.
// Durations are ALWAYS seconds (audit P0-3: total minutes
// = totalSeconds / 60, never / 1000).
// Playlist (plaza/search): {platform, id, name, cover, creator, playCount,
// trackCount, desc, time?}. Artist: {platform, id, name, cover, musicSize,
// albumSize, alias}. No "会员歌" string anywhere (fix 10).

import 'dart:convert';
import '../../core/storage/safe_json.dart';

/// Music platforms. `mg` (Migu) is resolver-only: no mg search exists.
enum MusicPlatform { wy, tx, kg, kw, mg }

extension MusicPlatformX on MusicPlatform {
  String get code => name;

  static MusicPlatform fromCode(String? code) {
    switch (code) {
      case 'tx':
        return MusicPlatform.tx;
      case 'kg':
        return MusicPlatform.kg;
      case 'kw':
        return MusicPlatform.kw;
      case 'mg':
        return MusicPlatform.mg;
      case 'wy':
      default:
        return MusicPlatform.wy;
    }
  }

  /// Short badge shown on song rows (fix 12: each result tagged).
  String get badgeName {
    switch (this) {
      case MusicPlatform.wy:
        return '网易';
      case MusicPlatform.tx:
        return 'QQ';
      case MusicPlatform.kg:
        return '酷狗';
      case MusicPlatform.kw:
        return '酷我';
      case MusicPlatform.mg:
        return '咪咕';
    }
  }

  String get displayName {
    switch (this) {
      case MusicPlatform.wy:
        return '网易云';
      case MusicPlatform.tx:
        return 'QQ音乐';
      case MusicPlatform.kg:
        return '酷狗音乐';
      case MusicPlatform.kw:
        return '酷我';
      case MusicPlatform.mg:
        return '咪咕';
    }
  }
}

/// All four search platforms, in merge order wy/tx/kg/kw (fix 12).
const List<MusicPlatform> kSearchPlatforms = [
  MusicPlatform.wy,
  MusicPlatform.tx,
  MusicPlatform.kg,
  MusicPlatform.kw,
];

/// Plaza platforms, in offered order wy/tx/kw/kg (fix 9).
const List<MusicPlatform> kPlazaPlatforms = [
  MusicPlatform.wy,
  MusicPlatform.tx,
  MusicPlatform.kw,
  MusicPlatform.kg,
];

String toHttps(String? url) {
  if (url == null || url.isEmpty) return '';
  if (url.startsWith('http://')) return 'https://${url.substring(7)}';
  return url;
}

/// True when [url] can be handed to AVPlayer (just_audio) without
/// killing the process.
///
/// Root cause of the v1.0.7 music crash: just_audio 0.10.6's iOS layer
/// (`UriAudioSource.m createPlayerItem:`) passes the URL string
/// straight to `[NSURL URLWithString:]` and then to
/// `[AVURLAsset URLAssetWithURL:]` with NO nil check. A URL string
/// NSURL rejects (nil) raises NSInvalidArgumentException and the app
/// dies instantly — no error event, no FlutterError, nothing the
/// controller can catch. media_kit/MPV used to turn the same URL into
/// a plain load error, so this only surfaced with the AVPlayer switch.
///
/// Dart's `Uri.parse` already percent-encodes most illegal characters,
/// so the holes left are a missing/empty host (e.g. `https://`), a
/// host Dart encoded but NSURL still rejects (space inside the host
/// becomes `%20`, which NSURL refuses), and a file URL with no real
/// path. Every one of those must be refused here — at the resolver
/// (try the next source) and at the player (never call native).
bool isPlayableUrl(String? url) {
  if (url == null || url.isEmpty) return false;
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  if (uri.scheme == 'file') {
    // The native file branch strips 'file://' and builds a path from
    // the rest: it needs a real path, not just '/'.
    return uri.path.length > 1;
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  final host = uri.host;
  if (host.isEmpty) return false;
  // A host never contains '%' in a real music URL (IPv6 zone ids
  // excepted — not our case). Dart encodes a space inside the host
  // as %20, and NSURL rejects such a host outright (nil).
  if (host.contains('%')) return false;
  // Belt and braces: characters NSURL URLWithString: rejects outright.
  // Dart's Uri.parse percent-encodes these, so a surviving one means
  // the string was hand-built — refuse it rather than crash.
  const hostile = [' ', '"', '<', '>', '\\', '^', '`', '{', '}', '|'];
  final s = uri.toString();
  for (final c in hostile) {
    if (s.contains(c)) return false;
  }
  if (s.codeUnits.any((c) => c < 0x20 || c == 0x7f)) return false;
  return true;
}

/// Trial/preview clip detector (chen 2026-11-17, v1.0.8 phone: 网易云
/// 很多歌只能放十五秒).
///
/// NetEase serves VIP-only songs as a ~15 s (sometimes ~30 s) preview
/// clip when the resolving source has no VIP rights. The preview URL
/// looks exactly like a full-song URL — same CDN, same format — and it
/// plays without any error, so the player treats the 15 s ending as a
/// normal track end and auto-advances. Nothing in the resolve chain
/// can tell a preview from a full song: the relay APIs return just a
/// URL string, no trial flag (verified live 2026-11-17: 11 songs x
/// every testable built-in resolver and LX script returned full files
/// — the preview only shows up for songs / sources the relays lack
/// rights to, or when a relay is degraded; unreachable relays
/// could not be probed).
///
/// The reliable signal is the player's real duration vs the metadata
/// duration from search (`Song.dur`, seconds): a real file of 15 s
/// for a 4-minute song is a preview. Guards against false positives:
/// - metadata unknown (`metaDurSec <= 0`) → never a trial;
/// - genuinely short songs (`metaDurSec < 60`) → never a trial;
/// - the real file must be short (<= 35 s, covers 15 s and 30 s
///   previews) AND less than half the metadata duration, so a
///   different-version file (live cut, radio edit) never trips it.
bool isTrialClip({required int metaDurSec, required Duration actual}) {
  if (metaDurSec < 60) return false;
  final actualSec = actual.inSeconds;
  if (actualSec <= 0 || actualSec > 35) return false;
  return actualSec * 2 < metaDurSec;
}

/// Cover hi-res upgrade — directCoverHi (app.js:468).
///
/// 2026-11-17 fix (v1.0.6 phone bug: "很多歌曲都没封面" + 搜歌/播放慢):
/// NetEase picUrls from search carry NO size param, i.e. the ORIGINAL
/// full-resolution image — measured 8.0 MB / 4.7 s for one cover
/// (p1.music.126.net, same pic). A search page with 20 wy results
/// fired up to ~160 MB of cover downloads on the shared Dio, starving
/// the search/resolve requests and blowing the 8 s image timeout, so
/// covers stayed on the placeholder. NEVER serve full-res: cap
/// music.126.net at param=800y800 (measured 1.45 MB, 2.5 s worst case
/// through the VM proxy; typically 200–600 KB). List thumbs should use
/// [coverThumb] (200y200, measured 115 KB) instead.
String coverHi(String? url) {
  var s = toHttps(url);
  if (s.isEmpty) return s;
  if (s.contains('y.gtimg.cn/music/photo_new/T00')) {
    s = s.replaceAllMapped(
      RegExp(r'T00([12])R300x300M000'),
      (m) => 'T00${m[1]}R800x800M000',
    );
  }
  if (s.contains('music.126.net')) {
    // Normalise to a bounded size: replace any existing param, or
    // append one when the URL has none (the search-API shape).
    final hasParam = RegExp(r'([?&])param=\d+y\d+').hasMatch(s);
    if (hasParam) {
      // NOTE: replaceAll does NOT interpolate $1 — the replacement is
      // literal (a sibling agent's replaceAll + r'$1...' left a literal
      // "$1" in the URL). Use replaceAllMapped for the group.
      s = s.replaceAllMapped(
        RegExp(r'([?&])param=\d+y\d+'),
        (m) => '${m[1]}param=800y800',
      );
    } else {
      s = s.contains('?') ? '$s&param=800y800' : '$s?param=800y800';
    }
  }
  return s;
}

/// Small list-thumb variant of a cover URL: 200y200 for music.126.net
/// (measured 115 KB vs 8.0 MB full-res), everything else unchanged
/// (gtimg 300px and kuwo covers are already small). Use in dense
/// lists (song rows); the player cover keeps [coverHi].
String coverThumb(String? url) {
  var s = toHttps(url);
  if (s.isEmpty) return s;
  if (s.contains('music.126.net')) {
    final hasParam = RegExp(r'([?&])param=\d+y\d+').hasMatch(s);
    if (hasParam) {
      s = s.replaceAllMapped(
        RegExp(r'([?&])param=\d+y\d+'),
        (m) => '${m[1]}param=200y200',
      );
    } else {
      s = s.contains('?') ? '$s&param=200y200' : '$s?param=200y200';
    }
  }
  return s;
}

/// HTML-entity decode for QQ/Kuwo names (directDecodeEnt).
///
/// Kuwo's pseudo-JSON double-escapes `\uXXXX` (raw `\\u0026`) so it
/// survives jsonDecode as literal text, and leaves HTML entities raw
/// (`&nbsp;` in NAME, `&amp;` in ARTIST) — measured 2026-11-17 on a
/// real Kuwo search response ("张学友"):
/// ARTIST `梅艳芳\\u0026张学友...` displayed literally, NAME
/// `明天会更好-1985&nbsp;TVB...`. All of those must decode here;
/// `&amp;` goes last so `&amp;nbsp;` stays literal.
String decodeEntities(String? s) {
  var out = s ?? '';
  out = out.replaceAllMapped(
    RegExp(r'\\+u([0-9a-fA-F]{4})'),
    (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
  );
  out = out.replaceAllMapped(
    RegExp(r'&#x([0-9a-fA-F]+);'),
    (m) => String.fromCharCode(int.tryParse(m.group(1) ?? '', radix: 16) ?? 0),
  );
  out = out.replaceAllMapped(
    RegExp(r'&#(\d+);'),
    (m) => String.fromCharCode(int.tryParse(m.group(1) ?? '') ?? 0),
  );
  out = out
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&apos;', "'");
  return out.replaceAll('&amp;', '&');
}

/// Base title, display form: cut the version suffix after the first
/// of `(`, `（`, `[`, `【`, `-`, `－`, `~`, `～` — live/DJ/cantonese
/// version notes ("吻别 (DJ萧子枫版)", "明天会更好-1985 TVB...").
/// The bare song name is what NetEase is queried/matched on; the
/// suffix only describes the recording.
String baseTitleRaw(String? s) {
  final t = (s ?? '').trim();
  final cut = t.indexOf(RegExp(r'''[\(（\[【\-－~～]'''));
  return (cut < 0 ? t : t.substring(0, cut)).trim();
}

/// Normalised [baseTitleRaw] — the key used to match a cover-lookup
/// candidate against the target song.
String baseSongTitle(String? s) => normalizeName(baseTitleRaw(s));

/// Normalise for title/artist matching: strip whitespace, brackets, dots,
/// dashes; lowercase (app.js §1.1.2 / dailyNorm).
String normalizeName(String? s) {
  return (s ?? '')
      .replaceAll(RegExp(r'''[\s\(\)（）\[\]·\-'"“”]'''), '')
      .toLowerCase();
}

String firstArtist(String? artist) {
  final parts = (artist ?? '').split(RegExp(r'[/、，,；;]'));
  return parts.isEmpty ? '' : parts.first.trim();
}

/// `mm:ss` duration. Input is seconds.
String formatDuration(num seconds) {
  final s = seconds.isFinite ? seconds.floor() : 0;
  final safe = s < 0 ? 0 : s;
  return '${safe ~/ 60}:${(safe % 60).toString().padLeft(2, '0')}';
}

class Song {
  Song({
    required this.songId,
    required this.title,
    this.artist = '',
    this.album = '',
    this.cover = '',
    this.platform = MusicPlatform.wy,
    this.dur = 0,
    this.albumYear = 0,
    this.reasonKey = '',
    this.reasonArg = '',
    this.localPath = '',
  });

  factory Song.fromJson(Map<String, dynamic> j) {
    return Song(
      songId: j['songId']?.toString() ?? '',
      title: j['title']?.toString() ?? '',
      artist: j['artist']?.toString() ?? '',
      album: j['album']?.toString() ?? '',
      cover: j['cover']?.toString() ?? '',
      platform: MusicPlatformX.fromCode(j['platform']?.toString()),
      dur: jIntN(j['dur']) ?? 0,
      albumYear: jIntN(j['albumYear']) ?? 0,
      reasonKey: j['reasonKey']?.toString() ?? '',
      reasonArg: j['reasonArg']?.toString() ?? '',
      localPath: j['localPath']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'songId': songId,
    'title': title,
    'artist': artist,
    'album': album,
    'cover': cover,
    'platform': platform.code,
    'dur': dur,
    'albumYear': albumYear,
    'reasonKey': reasonKey,
    'reasonArg': reasonArg,
    // Empty for every remote song; only local-file songs carry a path.
    if (localPath.isNotEmpty) 'localPath': localPath,
  };

  /// Dedupe key for aggregated search (fix 12): platform + songId.
  /// The title is deliberately NOT part of the key (M-P2-7): the same
  /// recording listed as "Song" and "Song (Live)" is one result, not
  /// two. An empty songId still falls back to title+artist (same
  /// rule as [identityKey]): a bare 'platform|' key would collapse
  /// every id-less song on the platform into one.
  String get dedupeKey => songId.isNotEmpty
      ? '${platform.code}|$songId'
      : '${platform.code}||$title|$artist';

  /// Identity key for favourites / recent / listen log.
  /// Identity for queue / favourites / history / resume keys.
  ///
  /// A song with an empty songId MUST NOT share a key with every
  /// other empty-id song on the same platform (the old
  /// `'platform|'` key did exactly that: tapping a second empty-id
  /// song was treated as "the first song already loaded" and resumed
  /// the previous song). Empty ids fall back to title+artist+album,
  /// which is stable for the same song and distinct across songs.
  /// Non-empty ids keep the exact old key, so every persisted key
  /// (favourites, history, resume map) stays valid.
  String get identityKey => songId.isNotEmpty
      ? '${platform.code}|$songId'
      : '${platform.code}|$title|$artist|$album';

  final String songId;
  final String title;
  final String artist;
  final String album;
  final String cover;
  final MusicPlatform platform;
  final int dur;

  final int albumYear;

  /// Absolute path of the local audio file (stage 2 local import).
  /// Empty for every remote song. The player opens this file directly
  /// (AVPlayer via just_audio, file:// URL) instead of resolving a
  /// remote URL — no new playback chain.
  final String localPath;

  /// True for an imported local file (songId starts with 'local:'
  /// AND a path is stored — both must hold, so a stale entry with a
  /// deleted file never claims to be local).
  bool get isLocal => localPath.isNotEmpty && songId.startsWith('local:');

  /// Daily-picks reason (becauseListen / becauseArtist / hotPick).
  final String reasonKey;
  final String reasonArg;

  Song copyWith({
    String? reasonKey,
    String? reasonArg,
    String? cover,
    String? localPath,
  }) => Song(
    songId: songId,
    title: title,
    artist: artist,
    album: album,
    cover: cover ?? this.cover,
    platform: platform,
    dur: dur,
    albumYear: albumYear,
    reasonKey: reasonKey ?? this.reasonKey,
    reasonArg: reasonArg ?? this.reasonArg,
    localPath: localPath ?? this.localPath,
  );
}

class PlaylistSummary {
  PlaylistSummary({
    required this.id,
    required this.name,
    this.cover = '',
    this.creator = '',
    this.playCount = 0,
    this.trackCount = 0,
    this.desc = '',
    this.time = '',
    this.platform = MusicPlatform.wy,
  });

  factory PlaylistSummary.fromJson(Map<String, dynamic> j) {
    return PlaylistSummary(
      id: j['id']?.toString() ?? '',
      name: j['name']?.toString() ?? '',
      cover: j['cover']?.toString() ?? '',
      creator: j['creator']?.toString() ?? '',
      playCount: jIntN(j['playCount']) ?? 0,
      trackCount: jIntN(j['trackCount']) ?? 0,
      desc: j['desc']?.toString() ?? '',
      time: j['time']?.toString() ?? '',
      platform: MusicPlatformX.fromCode(j['platform']?.toString()),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'cover': cover,
    'creator': creator,
    'playCount': playCount,
    'trackCount': trackCount,
    'desc': desc,
    'time': time,
    'platform': platform.code,
  };

  final String id;
  final String name;
  final String cover;
  final String creator;
  final int playCount;
  final int trackCount;
  final String desc;
  final String time;
  final MusicPlatform platform;
}

/// A user playlist stored locally (hao_lists). The card count is ALWAYS
/// `tracks.length` (audit P0-1) — never a stored count field.
class UserPlaylist {
  UserPlaylist({required this.id, required this.name, List<Song>? tracks})
    : tracks = tracks ?? [];

  factory UserPlaylist.fromJson(Map<String, dynamic> j) {
    final raw = jListN(j['tracks']) ?? [];
    return UserPlaylist(
      id: j['id']?.toString() ?? '',
      name: j['name']?.toString() ?? '',
      tracks: raw.whereType<Map<String, dynamic>>().map(Song.fromJson).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'tracks': tracks.map((s) => s.toJson()).toList(),
  };

  /// Audit P0-1: count is derived from the track list on every render.
  int get trackCount => tracks.length;

  String get cover => tracks.isEmpty ? '' : tracks.first.cover;

  final String id;
  String name;
  final List<Song> tracks;
}

class ArtistSummary {
  ArtistSummary({
    required this.id,
    required this.name,
    this.cover = '',
    this.musicSize = 0,
    this.albumSize = 0,
    this.platform = MusicPlatform.wy,
    this.alias = '',
  });

  final String id;
  final String name;
  final String cover;
  final int musicSize;
  final int albumSize;
  final MusicPlatform platform;
  final String alias;
}

class AlbumSummary {
  AlbumSummary({
    required this.id,
    required this.name,
    this.cover = '',
    this.artist = '',
    this.publishTime = 0,
    this.songCount = 0,
    this.platform = MusicPlatform.wy,
  });

  final String id;
  final String name;
  final String cover;
  final String artist;
  final int publishTime;
  final int songCount;

  /// Which platform the album came from (stage 2 album search).
  /// Defaults to wy so existing callers (artist detail) compile
  /// unchanged; album-search callers always set it explicitly.
  final MusicPlatform platform;

  int get year {
    if (publishTime <= 0) return 0;
    return DateTime.fromMillisecondsSinceEpoch(publishTime).year;
  }
}

class ArtistDetail {
  ArtistDetail({
    required this.name,
    this.pic = '',
    this.musicSize = 0,
    this.albumSize = 0,
    List<Song>? songs,
    List<AlbumSummary>? albums,
  }) : songs = songs ?? [],
       albums = albums ?? [];

  final String name;
  final String pic;
  final int musicSize;
  final int albumSize;
  final List<Song> songs;
  final List<AlbumSummary> albums;
}

class AlbumDetail {
  AlbumDetail({
    required this.name,
    this.pic = '',
    this.artist = '',
    this.publishTime = 0,
    List<Song>? songs,
  }) : songs = songs ?? [];

  final String name;
  final String pic;
  final String artist;
  final int publishTime;
  final List<Song> songs;

  int get year {
    if (publishTime <= 0) return 0;
    return DateTime.fromMillisecondsSinceEpoch(publishTime).year;
  }
}

class CommentItem {
  CommentItem({
    required this.nick,
    this.avatar = '',
    this.content = '',
    this.likes = 0,
    this.time = 0,
    this.platform = MusicPlatform.wy,
  });

  final String nick;
  final String avatar;
  final String content;
  final int likes;
  final int time;
  final MusicPlatform platform;
}

class LyricLine {
  LyricLine({required this.t, required this.text, this.translation});

  /// Time in seconds.
  final double t;
  final String text;

  /// Translation line (NetEase `tlyric`, Beans shows it under the
  /// focused line when present). Null when the source has none.
  final String? translation;

  Map<String, dynamic> toJson() => {
        't': t,
        'text': text,
        if (translation != null) 'translation': translation,
      };

  factory LyricLine.fromJson(Map<String, dynamic> j) => LyricLine(
        t: jDoubleN(j['t']) ?? 0,
        text: j['text']?.toString() ?? '',
        translation: j['translation']?.toString(),
      );
}

/// One listen event (hao_listen). `dur` is the seconds actually
/// heard; `totalDur` is the full song length in seconds (0 = unknown,
/// events written before v1.0.9 did not carry it); `at` is epoch ms.
class ListenEvent {
  ListenEvent({
    required this.songId,
    required this.title,
    this.artist = '',
    this.platform = MusicPlatform.wy,
    this.cover = '',
    this.dur = 0,
    this.totalDur = 0,
    required this.at,
  });

  factory ListenEvent.fromJson(Map<String, dynamic> j) {
    return ListenEvent(
      songId: j['songId']?.toString() ?? '',
      title: j['title']?.toString() ?? '',
      artist: j['artist']?.toString() ?? '',
      platform: MusicPlatformX.fromCode(j['platform']?.toString()),
      cover: j['cover']?.toString() ?? '',
      dur: jIntN(j['dur']) ?? 0,
      totalDur: jIntN(j['totalDur']) ?? 0,
      at: jIntN(j['at']) ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'songId': songId,
    'title': title,
    'artist': artist,
    'platform': platform.code,
    'cover': cover,
    'dur': dur,
    'totalDur': totalDur,
    'at': at,
  };

  final String songId;
  final String title;
  final String artist;
  final MusicPlatform platform;
  final String cover;
  final int dur;

  /// Full song length, seconds. The report shows this as the
  /// top-song duration; `dur` is only how long the song was heard.
  final int totalDur;
  final int at;
}

/// `M月d日 星期X` date line for the music home.
String homeDateText(DateTime now) {
  const weekdays = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
  final wd = weekdays[(now.weekday - 1) % 7];
  return '${now.month}月${now.day}日 $wd';
}

String dayKeyOf(DateTime now) =>
    '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

/// FNV-1a + mulberry32, ported exactly from dailySeeded (app.js:3317).
/// Same day string always yields the same sequence — do NOT use Random().
class SeededRandom {
  SeededRandom(String seed) {
    var h = 2166136261;
    for (var i = 0; i < seed.length; i++) {
      h ^= seed.codeUnitAt(i);
      h = _imul(h, 16777619);
    }
    _state = h;
  }

  int _state = 0;

  static int _imul(int a, int b) {
    return ((a & 0xFFFFFFFF) * (b & 0xFFFFFFFF)) & 0xFFFFFFFF;
  }

  double nextDouble() {
    _state = (_state + 0x6D2B79F5) & 0xFFFFFFFF;
    var x = _state;
    x = _imul(x ^ (x >>> 15), x | 1);
    x ^= (x + _imul(x ^ (x >>> 7), x | 61)) & 0xFFFFFFFF;
    x &= 0xFFFFFFFF;
    return ((x ^ (x >>> 14)) & 0xFFFFFFFF) / 4294967296;
  }

  /// Fisher–Yates with the seeded PRNG (dailyShuffle, app.js:3318).
  List<T> shuffle<T>(List<T> input) {
    final a = List<T>.of(input);
    for (var i = a.length - 1; i > 0; i--) {
      final j = (nextDouble() * (i + 1)).floor();
      final tmp = a[i];
      a[i] = a[j];
      a[j] = tmp;
    }
    return a;
  }
}

String jsonEncodeList(List<Map<String, dynamic>> items) => jsonEncode(items);
