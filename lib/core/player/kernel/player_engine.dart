// Player engines (Pure Live 3.x kernel mechanism, study §1).
//
// MPV = media_kit (libmpv) — default on every platform.
// IJK = flv_lzc fork of fijkplayer.
// AVPlayer = BetterPlayer on iOS (better_player_plus; Android ExoPlayer).
// All three register on iOS (mobileOnlyEnginesAvailable = Android OR iOS);
// mpv-only is the 4.x rewrite, not 3.x.
// Windows: ONLY MPV has native code (media_kit ships a Windows
// libmpv); IJK and AVPlayer have no Windows implementation, so on
// Windows they must never be constructed or offered — see
// [PlayerEngineX.isAvailableOnPlatform] and [candidatesFor].

import 'dart:io';

enum PlayerEngine {
  /// media_kit / libmpv. Priority 100. Default.
  mediaKit,

  /// fijk / flv_lzc. Priority 90.
  fijk,

  /// BetterPlayer — AVPlayer on iOS. Priority 80. CANNOT play FLV.
  exo,
}

extension PlayerEngineX on PlayerEngine {
  /// Hive `videoPlayerKey` value (Pure Live player_consts.dart).
  String get key {
    switch (this) {
      case PlayerEngine.mediaKit:
        return 'mpv';
      case PlayerEngine.fijk:
        return 'ijk';
      case PlayerEngine.exo:
        return 'exo';
    }
  }

  String get displayName {
    switch (this) {
      case PlayerEngine.mediaKit:
        return 'MPV';
      case PlayerEngine.fijk:
        return 'IJK';
      case PlayerEngine.exo:
        return 'AVPlayer';
    }
  }

  /// Whether this engine has a native implementation on the current
  /// platform. Windows only has MPV: flv_lzc (IJK) and
  /// better_player_plus (AVPlayer) ship no Windows native code, so
  /// constructing them on Windows would fail at open time. The
  /// candidate list ([candidatesFor]) and the settings picker both
  /// filter on this; the session also clamps its preferred engine.
  bool get isAvailableOnPlatform {
    if (Platform.isWindows) return this == PlayerEngine.mediaKit;
    return true;
  }

  /// Registration priority (media_core player_adapter_selector.dart).
  int get priority {
    switch (this) {
      case PlayerEngine.mediaKit:
        return 100;
      case PlayerEngine.fijk:
        return 90;
      case PlayerEngine.exo:
        return 80;
    }
  }

  static PlayerEngine fromKey(String? key) {
    switch (key) {
      case 'ijk':
        return PlayerEngine.fijk;
      case 'exo':
        return PlayerEngine.exo;
      case 'mpv':
      default:
        return PlayerEngine.mediaKit;
    }
  }
}
