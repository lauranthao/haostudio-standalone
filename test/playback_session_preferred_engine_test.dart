// Regression tests: the settings engine picker must actually take
// effect.
//
// Was: `PlaybackSession` always defaulted its preferred engine to MPV
// and nothing ever read the stored `videoPlayerKey` on open — the
// settings picker wrote a key no session honoured, so picking IJK /
// AVPlayer changed nothing on the next open (orphan control).

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/player/playback_session.dart';

void main() {
  late Box<dynamic> box;

  setUp(() async {
    Hive.init('test/.hive-session-engine-test');
    box = await Hive.openBox<dynamic>('session_engine_test');
    await box.clear();
    HiveStore.setTestBox(box);
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk('session_engine_test');
  });

  test('reads the stored engine choice by default', () async {
    await box.put(HiveKeys.videoPlayerKey, 'ijk');
    expect(PlaybackSession().preferredEngine, PlayerEngine.fijk);
    await box.put(HiveKeys.videoPlayerKey, 'exo');
    expect(PlaybackSession().preferredEngine, PlayerEngine.exo);
    await box.put(HiveKeys.videoPlayerKey, 'mpv');
    expect(PlaybackSession().preferredEngine, PlayerEngine.mediaKit);
  });

  test('unknown stored value falls back to MPV, never throws', () async {
    await box.put(HiveKeys.videoPlayerKey, 'nope');
    expect(PlaybackSession().preferredEngine, PlayerEngine.mediaKit);
  });

  test('explicit preferred wins over the stored value', () async {
    await box.put(HiveKeys.videoPlayerKey, 'ijk');
    expect(
      PlaybackSession(preferred: PlayerEngine.exo).preferredEngine,
      PlayerEngine.exo,
    );
  });
}
