// Player engines (Pure Live 3.x kernel mechanism, study §1).
//
// MPV = media_kit (libmpv) — default on every platform.
// IJK = flv_lzc fork of fijkplayer.
// AVPlayer = BetterPlayer on iOS (better_player_plus; Android ExoPlayer).
// All three register on iOS (mobileOnlyEnginesAvailable = Android OR iOS);
// mpv-only is the 4.x rewrite, not 3.x.

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
