// Emby server config + store (build 28; account auth + connect-page
// fields added build 29, C group).
//
// One Emby server, configured by the user in Settings → 影视源管理 →
// Emby 连接页. Credentials live ONLY in the local Hive box
// `app_settings` under [HiveKeys.embyConfig] ('hao_emby_config') as a
// JSON string — never in logs, never in toString(), never in any
// share/report text. Resetting the CMS source list never touches
// this key (independent key, see VideoSourcesStore.resetToDefaults).
//
// Auth, two modes (build 29):
// - Username + password (primary): POST /Users/AuthenticateByName
//   exchanges the password for an AccessToken + User Id; the token
//   is stored, the PASSWORD IS NEVER STORED.
// - API key (fallback, in 高级设置): the old X-Emby-Token key.
// Whichever credential is present is sent as `X-Emby-Token` on API
// calls and as `api_key` on the stream URL (Emby accepts a user
// token in both places, same as an API key). A config is
// "configured" when it has an address AND either credential.

import 'dart:convert';
import 'dart:math' as math;

import '../../core/storage/hive_store.dart';

/// Video tab mode (build 28): which page of the video tab was last
/// selected. Persisted under [HiveKeys.videoTabMode] ('cms' | 'emby',
/// default 'cms'; any other stored value reads back as 'cms').
enum VideoTabMode {
  cms,
  emby;

  String get code => name;

  static VideoTabMode fromString(String? raw) =>
      raw == 'emby' ? VideoTabMode.emby : VideoTabMode.cms;
}

/// One Emby server, as the user typed it in the Emby connect page.
///
/// Field names ARE the Hive JSON key names — do not rename (persisted
/// data has no migration). Build-29 fields default when an old
/// (build-28) JSON has no such key: a legacy `baseUrl` + `apiKey`
/// config loads unchanged and the connect page splits its baseUrl
/// into host / port / path / scheme for editing (see
/// [EmbyServerAddress.parse]).
class EmbyServerConfig {
  const EmbyServerConfig({
    required this.baseUrl,
    required this.apiKey,
    this.userId = '',
    this.enabled = true,
    this.movieLibraryId,
    this.tvLibraryId,
    this.name = 'Emby',
    this.note = '',
    this.username = '',
    this.accessToken = '',
    this.deviceId = '',
    this.serverName = '',
    this.serverVersion = '',
    this.reportProgress = true,
    this.strmDirect = false,
    this.fallbackUrls = const [],
    this.reminderDays = 0,
    this.lastPlayedAtMs,
  });

  factory EmbyServerConfig.fromJson(Map<String, dynamic> json) =>
      EmbyServerConfig(
        baseUrl: (json['baseUrl'] as String?) ?? '',
        apiKey: (json['apiKey'] as String?) ?? '',
        userId: (json['userId'] as String?) ?? '',
        enabled: json['enabled'] as bool? ?? true,
        movieLibraryId: json['movieLibraryId'] as String?,
        tvLibraryId: json['tvLibraryId'] as String?,
        name: (json['name'] as String?) ?? 'Emby',
        note: (json['note'] as String?) ?? '',
        username: (json['username'] as String?) ?? '',
        accessToken: (json['accessToken'] as String?) ?? '',
        deviceId: (json['deviceId'] as String?) ?? '',
        serverName: (json['serverName'] as String?) ?? '',
        serverVersion: (json['serverVersion'] as String?) ?? '',
        reportProgress: json['reportProgress'] as bool? ?? true,
        strmDirect: json['strmDirect'] as bool? ?? false,
        fallbackUrls: (json['fallbackUrls'] as List<dynamic>?)
                ?.map((u) => u.toString())
                .where((u) => u.trim().isNotEmpty)
                .toList() ??
            const [],
        reminderDays: (json['reminderDays'] as num?)?.toInt() ?? 0,
        lastPlayedAtMs: (json['lastPlayedAtMs'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'userId': userId,
        'enabled': enabled,
        'movieLibraryId': movieLibraryId,
        'tvLibraryId': tvLibraryId,
        'name': name,
        'note': note,
        'username': username,
        'accessToken': accessToken,
        'deviceId': deviceId,
        'serverName': serverName,
        'serverVersion': serverVersion,
        'reportProgress': reportProgress,
        'strmDirect': strmDirect,
        'fallbackUrls': fallbackUrls,
        'reminderDays': reminderDays,
        'lastPlayedAtMs': lastPlayedAtMs,
      };

  /// Server address as typed (trailing slash is stripped by the
  /// client when building URLs; the stored value is left alone).
  /// The connect page builds this from host / port / path / scheme
  /// ([EmbyServerAddress.compose]); a legacy value is parsed back
  /// by [EmbyServerAddress.parse] for editing.
  final String baseUrl;

  /// API key (fallback credential, 高级设置). Only ever read by
  /// [EmbyClient] (header / stream URL) and the connect page's
  /// text-field controller. Never logged.
  final String apiKey;

  /// Emby user id. The user never types this: it is filled in by
  /// probe (GET /Users, key mode — single user auto-taken,
  /// multi-user picked on the connect page) or by account login
  /// (POST /Users/AuthenticateByName). Empty until the first
  /// successful probe / login.
  final String userId;

  /// Master switch: off = the Emby page shows the disabled empty
  /// state instead of loading.
  final bool enabled;

  /// Pinned libraries (optional): null = all libraries of that type.
  final String? movieLibraryId;
  final String? tvLibraryId;

  /// Display name for this server (connect page 名称， default
  /// 'Emby'). Shown on the video-sources entry row.
  final String name;

  /// Free note (connect page 备注， e.g. expiry / whose account).
  /// Display only — never sent to the server.
  final String note;

  /// Emby account name for password login. Stored (it is the
  /// login name, not a secret); the PASSWORD is never stored —
  /// only the [accessToken] it was exchanged for.
  final String username;

  /// User token from POST /Users/AuthenticateByName. Empty when
  /// the server was connected with an API key instead. Never
  /// logged, never in toString() (no toString override on this
  /// class, on purpose).
  final String accessToken;

  /// Stable per-install device id sent as DeviceId on
  /// AuthenticateByName, so each login does not register a new
  /// device on the server. Random hex, generated once by the
  /// connect page ([EmbyServerConfig.newDeviceId]) and then kept.
  final String deviceId;

  /// Server identity from the last successful probe / login
  /// (System/Info). Display only — shown on the entry row.
  final String serverName;
  final String serverVersion;

  /// 数据上报 (default on): sync playback progress / played state
  /// to the server for 继续观看 and 已看标记. When off,
  /// [EmbyClient] skips every automatic playback report
  /// (start / progress / stopped / mark played) — no request is
  /// sent. Explicit user actions (favorite / like) are NOT gated:
  /// tapping them is the user asking the server to record it.
  final bool reportProgress;

  /// STRM 直连 (default off): when on, an item whose MediaSource
  /// path is a remote http(s) URL (a .strm target) plays from
  /// that URL directly; when off — or when the path is a local
  /// server path — playback always goes through the server's
  /// stream endpoint, which works on nearly every server.
  final bool strmDirect;

  /// 备用线路: alternate server addresses (full base URLs),
  /// added by hand on the connect page. The probe tries them in
  /// order when the main address fails, and reports which one
  /// answered ([EmbyProbeResult.workingBaseUrl]). Data calls
  /// still use [baseUrl] — automatic failover during browsing is
  /// NOT wired in this version (needs the tab page, out of scope
  /// for the connect-page group).
  final List<String> fallbackUrls;

  /// 未播放提醒 threshold in days (0 = 关闭； 3 / 7 / 14 / 30).
  /// Only the threshold is stored here — see [EmbyReminder]:
  /// firing a reminder needs a notification channel + an
  /// app-start check, neither of which exists in this version.
  final int reminderDays;

  /// Last time anything was played on this server (epoch ms).
  /// Written by whoever reports playback; read by
  /// [EmbyReminder.shouldRemind]. Null = never recorded.
  final int? lastPlayedAtMs;

  /// The credential actually sent on API calls and the stream URL:
  /// the account token when logged in, else the API key.
  String get authToken => accessToken.isNotEmpty ? accessToken : apiKey;

  /// True when the login came from username + password (a user
  /// token is stored), as opposed to an API key. Decides the 401
  /// wording ("用户名或密码不对" vs "密钥不对").
  bool get usesPasswordAuth => accessToken.isNotEmpty;

  /// Stable random device id (32 hex chars from a secure RNG).
  /// No uuid dependency — dart:math is enough for an opaque id.
  static String newDeviceId() {
    final rand = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
    final buf = StringBuffer();
    for (final b in bytes) {
      buf.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }

  /// Configured = an address AND at least one credential (account
  /// token or API key). A legacy key-only config still qualifies;
  /// an address with neither does not.
  bool get isConfigured =>
      baseUrl.trim().isNotEmpty &&
      (accessToken.trim().isNotEmpty || apiKey.trim().isNotEmpty);

  EmbyServerConfig copyWith({
    String? baseUrl,
    String? apiKey,
    String? userId,
    bool? enabled,
    String? movieLibraryId,
    String? tvLibraryId,
    String? name,
    String? note,
    String? username,
    String? accessToken,
    String? deviceId,
    String? serverName,
    String? serverVersion,
    bool? reportProgress,
    bool? strmDirect,
    List<String>? fallbackUrls,
    int? reminderDays,
    int? lastPlayedAtMs,
  }) =>
      EmbyServerConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        userId: userId ?? this.userId,
        enabled: enabled ?? this.enabled,
        movieLibraryId: movieLibraryId ?? this.movieLibraryId,
        tvLibraryId: tvLibraryId ?? this.tvLibraryId,
        name: name ?? this.name,
        note: note ?? this.note,
        username: username ?? this.username,
        accessToken: accessToken ?? this.accessToken,
        deviceId: deviceId ?? this.deviceId,
        serverName: serverName ?? this.serverName,
        serverVersion: serverVersion ?? this.serverVersion,
        reportProgress: reportProgress ?? this.reportProgress,
        strmDirect: strmDirect ?? this.strmDirect,
        fallbackUrls: fallbackUrls ?? this.fallbackUrls,
        reminderDays: reminderDays ?? this.reminderDays,
        lastPlayedAtMs: lastPlayedAtMs ?? this.lastPlayedAtMs,
      );

  // Deliberately NO toString override: the default prints no fields,
  // so the key can never leak through a debug print of the config.
}

/// Server address split into the connect page's fields.
///
/// [parse] accepts a full URL (`https://host:8096/emby`), a bare
/// host (`192.168.1.10`), or host + port (`host:8096`) — the legacy
/// `baseUrl` and anything the user pastes. [compose] builds the
/// stored `baseUrl` back (port always explicit, so the stored shape
/// stays `scheme://host:port[/path]`, like build 28).
class EmbyServerAddress {
  const EmbyServerAddress({
    required this.useHttps,
    required this.host,
    required this.port,
    required this.path,
  });

  factory EmbyServerAddress.parse(String raw) {
    var text = raw.trim();
    // Tolerate a pasted URL with a trailing slash / whitespace.
    while (text.endsWith('/')) {
      text = text.substring(0, text.length - 1);
    }
    if (text.isEmpty) {
      return const EmbyServerAddress(
        useHttps: false,
        host: '',
        port: 8096,
        path: '',
      );
    }
    if (text.contains('://')) {
      final uri = Uri.tryParse(text);
      if (uri != null && uri.host.isNotEmpty) {
        final https = uri.scheme == 'https';
        var path = uri.path;
        while (path.endsWith('/')) {
          path = path.substring(0, path.length - 1);
        }
        return EmbyServerAddress(
          useHttps: https,
          host: uri.host,
          port: uri.hasPort ? uri.port : (https ? 443 : 8096),
          path: path == '/' ? '' : path,
        );
      }
      // Unparseable despite a scheme: treat the whole thing as a
      // host so nothing the user typed is silently dropped.
      return EmbyServerAddress(
        useHttps: text.startsWith('https://'),
        host: text,
        port: 8096,
        path: '',
      );
    }
    // Bare host, optionally host:port and /path.
    var path = '';
    var hostPort = text;
    final slash = text.indexOf('/');
    if (slash >= 0) {
      hostPort = text.substring(0, slash);
      path = text.substring(slash);
      while (path.endsWith('/')) {
        path = path.substring(0, path.length - 1);
      }
    }
    var host = hostPort;
    var port = 8096;
    final colon = hostPort.lastIndexOf(':');
    if (colon > 0) {
      final parsed = int.tryParse(hostPort.substring(colon + 1));
      if (parsed != null && parsed > 0 && parsed <= 65535) {
        host = hostPort.substring(0, colon);
        port = parsed;
      }
    }
    return EmbyServerAddress(
      useHttps: false,
      host: host,
      port: port,
      path: path,
    );
  }

  /// Build `scheme://host:port[/path]`. Empty host => '' (the page
  /// treats that as "not filled in" and keeps the button disabled).
  static String compose({
    required bool useHttps,
    required String host,
    required int port,
    required String path,
  }) {
    final h = host.trim();
    if (h.isEmpty) return '';
    var p = path.trim();
    while (p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    if (p.isNotEmpty && !p.startsWith('/')) p = '/$p';
    return '${useHttps ? 'https' : 'http'}://$h:$port$p';
  }

  final bool useHttps;
  final String host;

  /// 1..65535; 8096 when the user left it blank or typed junk.
  final int port;

  /// '' or '/emby' (leading slash, no trailing slash).
  final String path;

  String get baseUrl =>
      compose(useHttps: useHttps, host: host, port: port, path: path);
}

/// Outcome of [EmbyClient.authenticateByName]: ok + the token and
/// user id to store, or a human-readable failure (same tiers as the
/// probe — the connect page shows [errorMessage] as-is).
class EmbyAuthResult {
  const EmbyAuthResult({
    required this.ok,
    this.accessToken = '',
    this.userId = '',
    this.userName = '',
    this.errorKind,
    this.errorMessage = '',
  });

  final bool ok;

  /// User token to store (never the password — the password is
  /// only ever sent in the AuthenticateByName body, once).
  final String accessToken;
  final String userId;
  final String userName;
  final EmbyErrorKind? errorKind;

  /// Human message for the failure tier ('' when ok).
  final String errorMessage;
}

/// 未播放提醒: pure threshold check. The threshold ([EmbyServerConfig.
/// reminderDays], 0 = off) and the last-played stamp are stored in
/// the config; this only decides "is it due". FIRING a reminder is
/// deliberately not here: the app has no notification channel and
/// no app-start check that could fire one, so a due reminder has
/// nowhere to go in this version — the connect page stores the
/// threshold and the decision is testable, but nothing notifies
/// yet (see the C-group report).
class EmbyReminder {
  EmbyReminder._();

  static const List<int> options = <int>[0, 3, 7, 14, 30];

  static String label(int days) => days <= 0 ? '关闭' : '$days 天';

  static bool shouldRemind({
    required int? lastPlayedAtMs,
    required int thresholdDays,
    required DateTime now,
  }) {
    if (thresholdDays <= 0) return false;
    if (lastPlayedAtMs == null) return false;
    final last =
        DateTime.fromMillisecondsSinceEpoch(lastPlayedAtMs);
    return now.difference(last).inDays >= thresholdDays;
  }
}

/// Fault-tolerant read/write of the Emby config (same pattern as
/// VideoSourcesStore.getAll: Hive uninitialised / bad JSON = "not
/// configured", never a throw into the UI).
class EmbyConfigStore {
  EmbyConfigStore._();

  static EmbyServerConfig? load() {
    try {
      final raw = HiveStore.box.get(HiveKeys.embyConfig);
      if (raw is! String || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return EmbyServerConfig.fromJson(decoded);
      }
    } catch (_) {}
    return null;
  }

  /// Returns false when the write failed (caller keeps the in-memory
  /// value; the UI never throws for a storage failure).
  static Future<bool> save(EmbyServerConfig config) async {
    try {
      await HiveStore.put(HiveKeys.embyConfig, jsonEncode(config.toJson()));
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> clear() async {
    try {
      await HiveStore.delete(HiveKeys.embyConfig);
    } catch (_) {}
  }
}

/// Container / codec facts for one Emby file, parsed from its
/// `MediaSources[0]` (detail requests ask for `MediaSources`).
///
/// Feeds the kernel's engine gate: the facts ride the stream URL as
/// `hao_*` query markers (see [EmbyClient.streamUrl]) because the
/// URL itself has no suffix for the kernel to read. Only the DEFAULT
/// audio track's codec is kept — an optional TrueHD track next to an
/// AAC default still plays on every engine.
class EmbyStreamFacts {
  const EmbyStreamFacts({
    this.container,
    this.videoCodec,
    this.audioCodec,
    this.dolbyVision = false,
    this.dvProfile,
    this.dvCompatId,
    this.width,
    this.height,
    this.bitRate,
    this.size,
    this.sourcePath,
  });

  /// Parse the first media source of an item detail document.
  /// Missing / malformed MediaSources => empty facts (the old
  /// unknown-format behaviour: every engine is tried).
  ///
  /// Dolby Vision detection (HB-3): the key names below are the ones
  /// a real Emby 4.8.4 server returns in MediaStreams (captured
  /// server JSON, Emby community 2024-04-21: `"VideoRange":
  /// "DolbyVision"`, `"ExtendedVideoType": "DolbyVision"`,
  /// `"ExtendedVideoSubType": "DoviProfile81"`). Emby's own API docs
  /// do not document these fields, so the mapping is still
  /// 待真服验证 against chen's server — if his server returns
  /// different keys, only this factory changes. The old
  /// `VideoRangeType` read is kept as a fallback (Jellyfin's enum
  /// uses it: DOVI / DOVIWithHDR10 / DOVIWithEL; some servers may
  /// still emit it) — never the only signal.
  factory EmbyStreamFacts.fromMediaSources(dynamic mediaSources) {
    if (mediaSources is! List || mediaSources.isEmpty) {
      return const EmbyStreamFacts();
    }
    Map<String, dynamic>? source;
    for (final s in mediaSources) {
      if (s is Map<String, dynamic>) {
        source = s;
        break;
      }
    }
    if (source == null) return const EmbyStreamFacts();
    final container = (source['Container'] as String?)?.toLowerCase();
    final streams = (source['MediaStreams'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    Map<String, dynamic>? video;
    for (final s in streams) {
      if ((s['Type'] as String?) == 'Video') {
        video = s;
        break;
      }
    }
    final audioStreams = streams
        .where((s) => (s['Type'] as String?) == 'Audio')
        .toList();
    Map<String, dynamic>? audio;
    for (final s in audioStreams) {
      if (s['IsDefault'] == true) {
        audio = s;
        break;
      }
    }
    audio ??= audioStreams.isNotEmpty ? audioStreams.first : null;
    // DV profile comes ONLY from ExtendedVideoSubType
    // ('DoviProfile81' -> 8.1, 'DoviProfile71' -> 7.1, 'DoviProfile50'
    // -> 5.0; a bare 'DoviProfile8' has no compat id). Emby gives no
    // MEL/FEL signal — never guessed.
    int? dvProfile;
    int? dvCompatId;
    final subType =
        (video?['ExtendedVideoSubType'] as String?)?.toLowerCase();
    if (subType != null) {
      final m = RegExp(r'doviprofile(\d)(\d)?').firstMatch(subType);
      if (m != null) {
        dvProfile = int.tryParse(m.group(1)!);
        final compat = m.group(2);
        dvCompatId = compat == null ? null : int.tryParse(compat);
      }
    }
    bool isDv(String? value) {
      if (value == null) return false;
      final v = value.toLowerCase();
      return v.contains('dolbyvision') || v.contains('dovi');
    }

    final dolbyVision = dvProfile != null ||
        isDv(video?['ExtendedVideoType'] as String?) ||
        isDv(video?['VideoRange'] as String?) ||
        isDv(video?['VideoRangeType'] as String?);
    return EmbyStreamFacts(
      container: container,
      videoCodec: (video?['Codec'] as String?)?.toLowerCase(),
      audioCodec: (audio?['Codec'] as String?)?.toLowerCase(),
      dolbyVision: dolbyVision,
      dvProfile: dvProfile,
      dvCompatId: dvCompatId,
      width: (video?['Width'] as num?)?.toInt(),
      height: (video?['Height'] as num?)?.toInt(),
      // 1.1.6 (browse A3 §3): bitrate + file size, Emby only. Both
      // are raw server values — BitRate is bits/second on the VIDEO
      // stream, Size is bytes on the MediaSource. Null when the
      // server does not report them (U3-1: field presence on chen's
      // server is still unverified — never a guessed default).
      bitRate: (video?['BitRate'] as num?)?.toInt(),
      size: (source['Size'] as num?)?.toInt(),
      // Build 29 (STRM 直连): the MediaSource's own path. For a
      // .strm item this is usually a local server path
      // ('/media/movie.strm') — the client only ever plays it
      // directly when it is a remote http(s) URL (see
      // EmbyClient.streamUrl); anything else falls back to the
      // server stream endpoint.
      sourcePath: source['Path'] as String?,
    );
  }

  final String? container;
  final String? videoCodec;
  final String? audioCodec;
  final bool dolbyVision;

  /// Dolby Vision bitstream profile (5 / 7 / 8 / ...), from
  /// ExtendedVideoSubType. Null when the server says DV without a
  /// profile (or when there is no DV at all) — the kernel then falls
  /// back to the old behaviour (all DV to the ffmpeg kernels).
  final int? dvProfile;

  /// Dolby Vision cross-compatibility id (the second digit of
  /// 'DoviProfile81' -> 1). Carried for honesty, never used to gate:
  /// 8.1 (HDR10 base) and 8.4 (HLG base) both play natively on
  /// AVPlayer in MP4.
  final int? dvCompatId;

  /// Frame size in pixels, from the video stream's Width / Height.
  /// Feeds the 4K badge only — never the kernel gate (there is no
  /// resolution cap anywhere in the kernel).
  final int? width;
  final int? height;

  /// Video-stream bitrate in bits/second (Emby `MediaStreams[].BitRate`).
  /// Display only (see `formatEmbyBitrate`); never a kernel signal.
  final int? bitRate;

  /// File size in bytes (Emby `MediaSources[].Size`). Display only.
  final int? size;

  /// The MediaSource's own path (`MediaSources[].Path`), e.g. a
  /// local server path or, for a .strm item served from a remote
  /// URL, that URL. Read by [EmbyClient.streamUrl] for STRM 直连
  /// only — never a kernel signal, never logged.
  final String? sourcePath;

  bool get isEmpty =>
      container == null &&
      videoCodec == null &&
      audioCodec == null &&
      !dolbyVision &&
      dvProfile == null &&
      width == null &&
      height == null &&
      bitRate == null &&
      size == null;

  /// `hao_*` query markers for the stream URL. Empty when there is
  /// nothing to say (the URL stays exactly as before).
  Map<String, String> toQueryParams() {
    if (isEmpty) return const {};
    return <String, String>{
      if (container != null && container!.isNotEmpty)
        'hao_container': container!,
      if (videoCodec != null && videoCodec!.isNotEmpty)
        'hao_vcodec': videoCodec!,
      if (audioCodec != null && audioCodec!.isNotEmpty)
        'hao_acodec': audioCodec!,
      if (dolbyVision) 'hao_dv': '1',
      if (dolbyVision && dvProfile != null)
        'hao_dvprofile':
            dvCompatId != null ? '$dvProfile.$dvCompatId' : '$dvProfile',
      if (width != null) 'hao_width': '$width',
      if (height != null) 'hao_height': '$height',
      // 1.1.6: carried for the detail page to read back (see
      // EmbySpecLine); `streamFactsOf` parses them. Emby ignores
      // unknown params.
      if (bitRate != null) 'hao_bitrate': '$bitRate',
      if (size != null) 'hao_size': '$size',
    };
  }
}

/// One Emby library (View): only `movies` / `tvshows` are kept.
class EmbyLibrary {
  const EmbyLibrary({
    required this.id,
    required this.name,
    required this.collectionType,
  });

  factory EmbyLibrary.fromJson(Map<String, dynamic> json) => EmbyLibrary(
        id: (json['Id'] as String?) ?? '',
        name: (json['Name'] as String?) ?? '',
        collectionType: (json['CollectionType'] as String?) ?? '',
      );

  final String id;
  final String name;
  final String collectionType;

  bool get isMovieLibrary => collectionType == 'movies';
  bool get isTvLibrary => collectionType == 'tvshows';
}

/// One Emby user, as returned by GET /Users.
class EmbyUser {
  const EmbyUser({required this.id, required this.name});

  factory EmbyUser.fromJson(Map<String, dynamic> json) => EmbyUser(
        id: (json['Id'] as String?) ?? '',
        name: (json['Name'] as String?) ?? '',
      );

  final String id;
  final String name;
}

/// Outcome of [EmbyClient.probe]: ok + server identity + users, or a
/// human-readable failure (three tiers, never the CMS wording).
class EmbyProbeResult {
  const EmbyProbeResult({
    required this.ok,
    this.serverName = '',
    this.version = '',
    this.users = const [],
    this.errorKind,
    this.errorMessage = '',
    this.workingBaseUrl = '',
  });

  final bool ok;
  final String serverName;
  final String version;

  /// Users returned by GET /Users. Single user = auto-take;
  /// multiple = Settings shows the picker; none = config error.
  final List<EmbyUser> users;

  final EmbyErrorKind? errorKind;

  /// Human message for the failure tier ('' when ok).
  final String errorMessage;

  /// The base URL that actually answered (main address or one of
  /// the 备用线路). '' when nothing answered. Lets the connect page
  /// tell the user "主线路不通，备用线路 X 可连通" and offer to
  /// switch the main address to it.
  final String workingBaseUrl;
}

/// Failure tiers for Emby requests. The message wording is fixed here
/// so probe / list / detail can never drift apart — and so the CMS
/// wording ("视频源暂时无法访问") is never reused for Emby.
enum EmbyErrorKind {
  /// Connection refused / DNS / timeout: address wrong or server down.
  unreachable,

  /// HTTP 401: the key is wrong.
  unauthorized,

  /// HTTP 404: the addressed item/library is gone.
  notFound,

  /// Anything else (5xx, bad JSON, unknown item type).
  other,
}
