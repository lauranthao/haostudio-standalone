// Music models — ported from the old web app (app.js record shapes).
//
// Song: {songId, title, artist, album, cover, platform, dur (seconds),
// vipOnly (0/1)}. Durations are ALWAYS seconds (audit P0-3: total minutes
// = totalSeconds / 60, never / 1000).
// Playlist (plaza/search): {platform, id, name, cover, creator, playCount,
// trackCount, desc, time?}. Artist: {platform, id, name, cover, musicSize,
// albumSize, alias}. No "会员歌" string anywhere (fix 10): vipOnly is kept
// as a flag for gating logic only and is never rendered as text.

import 'dart:convert';

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

/// Cover hi-res upgrade — directCoverHi (app.js:468).
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
    final m = RegExp(r'([?&])param=(\d+)y(\d+)(?=&|$)').firstMatch(s);
    if (m != null) {
      final w = int.tryParse(m.group(2) ?? '') ?? 0;
      final h = int.tryParse(m.group(3) ?? '') ?? 0;
      if (w <= 300 && h <= 300) {
        s = s.replaceAll(RegExp(r'([?&])param=\d+y\d+&'), r'$1');
        s = s.replaceAll(RegExp(r'([?&])param=\d+y\d+$'), '');
      }
    }
  }
  return s;
}

/// HTML-entity decode for QQ/Kuwo names (directDecodeEnt).
String decodeEntities(String? s) {
  var out = s ?? '';
  out = out.replaceAllMapped(
    RegExp(r'&#(\d+);'),
    (m) => String.fromCharCode(int.tryParse(m.group(1) ?? '') ?? 0),
  );
  return out.replaceAll('&amp;', '&');
}

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
    this.vipOnly = false,
    this.albumYear = 0,
    this.reasonKey = '',
    this.reasonArg = '',
  });

  factory Song.fromJson(Map<String, dynamic> j) {
    return Song(
      songId: j['songId']?.toString() ?? '',
      title: j['title']?.toString() ?? '',
      artist: j['artist']?.toString() ?? '',
      album: j['album']?.toString() ?? '',
      cover: j['cover']?.toString() ?? '',
      platform: MusicPlatformX.fromCode(j['platform']?.toString()),
      dur: (j['dur'] as num?)?.toInt() ?? 0,
      vipOnly: j['vipOnly'] == 1 || j['vipOnly'] == true,
      albumYear: (j['albumYear'] as num?)?.toInt() ?? 0,
      reasonKey: j['reasonKey']?.toString() ?? '',
      reasonArg: j['reasonArg']?.toString() ?? '',
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
        'vipOnly': vipOnly ? 1 : 0,
        'albumYear': albumYear,
        'reasonKey': reasonKey,
        'reasonArg': reasonArg,
      };

  /// Dedupe key for aggregated search (fix 12): platform + songId + title.
  String get dedupeKey => '${platform.code}|$songId|$title';

  /// Identity key for favourites / recent / listen log.
  String get identityKey => '${platform.code}|$songId';

  final String songId;
  final String title;
  final String artist;
  final String album;
  final String cover;
  final MusicPlatform platform;
  final int dur;

  /// VIP-only flag — kept for gating logic, NEVER rendered as text.
  final bool vipOnly;
  final int albumYear;

  /// Daily-picks reason (becauseListen / becauseArtist / hotPick).
  final String reasonKey;
  final String reasonArg;

  Song copyWith({String? reasonKey, String? reasonArg}) => Song(
        songId: songId,
        title: title,
        artist: artist,
        album: album,
        cover: cover,
        platform: platform,
        dur: dur,
        vipOnly: vipOnly,
        albumYear: albumYear,
        reasonKey: reasonKey ?? this.reasonKey,
        reasonArg: reasonArg ?? this.reasonArg,
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
      playCount: (j['playCount'] as num?)?.toInt() ?? 0,
      trackCount: (j['trackCount'] as num?)?.toInt() ?? 0,
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
    final raw = j['tracks'] as List<dynamic>? ?? [];
    return UserPlaylist(
      id: j['id']?.toString() ?? '',
      name: j['name']?.toString() ?? '',
      tracks: raw
          .whereType<Map<String, dynamic>>()
          .map(Song.fromJson)
          .toList(),
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
  });

  final String id;
  final String name;
  final String cover;
  final String artist;
  final int publishTime;
  final int songCount;

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
  })  : songs = songs ?? [],
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
  LyricLine({required this.t, required this.text});

  /// Time in seconds.
  final double t;
  final String text;
}

/// One listen event (hao_listen). `dur` is SECONDS; `at` is epoch ms.
class ListenEvent {
  ListenEvent({
    required this.songId,
    required this.title,
    this.artist = '',
    this.platform = MusicPlatform.wy,
    this.cover = '',
    this.dur = 0,
    required this.at,
  });

  factory ListenEvent.fromJson(Map<String, dynamic> j) {
    return ListenEvent(
      songId: j['songId']?.toString() ?? '',
      title: j['title']?.toString() ?? '',
      artist: j['artist']?.toString() ?? '',
      platform: MusicPlatformX.fromCode(j['platform']?.toString()),
      cover: j['cover']?.toString() ?? '',
      dur: (j['dur'] as num?)?.toInt() ?? 0,
      at: (j['at'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'songId': songId,
        'title': title,
        'artist': artist,
        'platform': platform.code,
        'cover': cover,
        'dur': dur,
        'at': at,
      };

  final String songId;
  final String title;
  final String artist;
  final MusicPlatform platform;
  final String cover;
  final int dur;
  final int at;
}

/// Greeting for the music home (greetMorning/Afternoon/Evening).
String greetingFor(DateTime now) {
  final h = now.hour;
  if (h < 12) return '早上好';
  if (h < 18) return '下午好';
  return '晚上好';
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

String jsonEncodeList(List<Map<String, dynamic>> items) =>
    jsonEncode(items);
