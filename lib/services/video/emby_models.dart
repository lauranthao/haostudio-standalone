// Emby server config + store (build 28).
//
// One Emby server, configured by the user in Settings → 影视源管理.
// Credentials live ONLY in the local Hive box `app_settings` under
// [HiveKeys.embyConfig] ('hao_emby_config') as a JSON string — never
// in logs, never in toString(), never in any share/report text.
// Resetting the CMS source list never touches this key (independent
// key, see VideoSourcesStore.resetToDefaults).
//
// Auth is API key only (X-Emby-Token header). Username/password token
// exchange (POST /Users/AuthenticateByName) is a documented fallback
// in emby_client.dart — no UI for it, no password is ever stored.

import 'dart:convert';

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

/// One Emby server, as the user typed it in Settings.
///
/// Field names ARE the Hive JSON key names — do not rename (persisted
/// data has no migration).
class EmbyServerConfig {
  const EmbyServerConfig({
    required this.baseUrl,
    required this.apiKey,
    this.userId = '',
    this.enabled = true,
    this.movieLibraryId,
    this.tvLibraryId,
  });

  factory EmbyServerConfig.fromJson(Map<String, dynamic> json) =>
      EmbyServerConfig(
        baseUrl: (json['baseUrl'] as String?) ?? '',
        apiKey: (json['apiKey'] as String?) ?? '',
        userId: (json['userId'] as String?) ?? '',
        enabled: json['enabled'] as bool? ?? true,
        movieLibraryId: json['movieLibraryId'] as String?,
        tvLibraryId: json['tvLibraryId'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'userId': userId,
        'enabled': enabled,
        'movieLibraryId': movieLibraryId,
        'tvLibraryId': tvLibraryId,
      };

  /// Server address as typed (trailing slash is stripped by the
  /// client when building URLs; the stored value is left alone).
  final String baseUrl;

  /// API key. Only ever read by [EmbyClient] (header / stream URL)
  /// and the Settings text-field controller. Never logged.
  final String apiKey;

  /// Emby user id. The user never types this: it is filled in by
  /// probe (GET /Users) — single user auto-taken, multi-user picked
  /// in Settings. Empty until the first successful probe.
  final String userId;

  /// Master switch: off = the Emby page shows the disabled empty
  /// state instead of loading.
  final bool enabled;

  /// Pinned libraries (optional): null = all libraries of that type.
  final String? movieLibraryId;
  final String? tvLibraryId;

  /// Both fields filled in. A config that fails this is "not
  /// configured" — the Emby tab shows the unconfigured empty state.
  bool get isConfigured =>
      baseUrl.trim().isNotEmpty && apiKey.trim().isNotEmpty;

  EmbyServerConfig copyWith({
    String? baseUrl,
    String? apiKey,
    String? userId,
    bool? enabled,
    String? movieLibraryId,
    String? tvLibraryId,
  }) =>
      EmbyServerConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        userId: userId ?? this.userId,
        enabled: enabled ?? this.enabled,
        movieLibraryId: movieLibraryId ?? this.movieLibraryId,
        tvLibraryId: tvLibraryId ?? this.tvLibraryId,
      );

  // Deliberately NO toString override: the default prints no fields,
  // so the key can never leak through a debug print of the config.
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
