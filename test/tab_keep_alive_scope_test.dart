// P1-P3 scope guard: only the music tab keeps KeepAlive.
//
// The four tab pages used to ALL carry AutomaticKeepAliveClientMixin
// and sit resident in memory after one tour of the tabs. Only the
// music page may keep it (playback state); video / live / settings
// rebuild from the Hive cache on every switch. This is a source-text
// guard — the video/live/settings pages have no injection point for
// a widget-level keep-alive test (VideoTabPage builds its own
// VideoHomeService, which would hit the real network), so the scope
// is locked here and the behaviour (cache-first render, state
// intact) is verified by the tab-switch regression run.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only the music tab page keeps KeepAlive (P1-P3)', () {
    final lib = Directory('lib');
    final keepAlive = <String, bool>{};
    for (final entry in {
      'music': 'features/music/music_tab_page.dart',
      'video': 'features/video/video_tab_page.dart',
      'live': 'domains/live/presentation/live_tab_page.dart',
      'settings': 'features/settings/settings_tab_page.dart',
    }.entries) {
      final src = File('${lib.path}/${entry.value}').readAsStringSync();
      keepAlive[entry.key] =
          src.contains('AutomaticKeepAliveClientMixin') ||
          src.contains('wantKeepAlive');
    }
    expect(
      keepAlive,
      {
        'music': true,
        'video': false,
        'live': false,
        'settings': false,
      },
      reason:
          'only music keeps KeepAlive; video/live/settings rebuild from cache',
    );
  });
}
