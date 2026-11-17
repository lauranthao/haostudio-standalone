// PROBE ONLY (temporary, not part of the suite): v1.0.8 regression —
// chen reports NO song plays at all on device. Run the real music
// chain with real network and print where it breaks:
//   resolvePlayUrl (real Dio, no LX scripts) -> isPlayableUrl -> open.
// Also runs isPlayableUrl over the exact real URLs curl fetched
// 2026-11-17 (zddyr + gd, song 66285).

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/network/http_client.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/services/music/lx_script_engine.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';
import 'package:standalone/services/music/music_resolvers.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-probe108-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
    final memBox = await Hive.openBox<dynamic>(
      'test_settings',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  test('PROBE isPlayableUrl on real fetched URLs', () {
    // Exact strings curl returned 2026-11-17 for song 66285.
    const zddyrRaw =
        'http://m701.music.126.net/20261117180358/f0f0196f239fa7311cede70990c32466/jdymusic/obj/wo3DlMOGwrbDjj7DisKw/32367562377/31a5/332a/b6bb/626c1cbe621f9733ad86c0765963e385.mp3?vuutv=801zZkVYyHuK4eRn40+6SAb/0f6GDgctmIjRZ3vKSGBBIBK7zZrM6memK2oTXc5Ks8/vjiyhp/qkmiwix92LfZrBP4EwR+2sF7Hg+X8CWck=';
    const gdRaw =
        'https://m701.music.126.net/20261117181532/ff52fe2e1345ad13ce8efa3e844cec00/jdymusic/obj/wo3DlMOGwrbDjj7DisKw/32367560092/4f77/affc/003f/df45ad0eb418607a7453fa5380ab1a9f.flac';
    for (final entry in {
      'zddyr raw (http)': zddyrRaw,
      'zddyr after toHttps': toHttps(zddyrRaw),
      'gd raw (https)': gdRaw,
      'plain m801 mp3': 'https://m801.music.126.net/20261117/abc/test.mp3',
      'plain m701 flac': 'https://m701.music.126.net/20261117/abc/test.flac',
    }.entries) {
      // ignore: avoid_print
      print(
          'PROBE isPlayableUrl ${entry.key}: ${isPlayableUrl(entry.value)}');
    }
    // Show what Dart's Uri does to the zddyr token query — the
    // suspect: toString() re-encoding.
    final u = Uri.tryParse(toHttps(zddyrRaw));
    // ignore: avoid_print
    print('PROBE zddyr parsed host: ${u?.host}');
    // ignore: avoid_print
    print('PROBE zddyr toString == input: ${u?.toString() == toHttps(zddyrRaw)}');
    // ignore: avoid_print
    print('PROBE zddyr toString: ${u?.toString()}');
  });

  test('PROBE resolvePlayUrl real network (no scripts)', () async {
    final dio = sharedDio();
    final resolvers = MusicResolvers(
      dio: dio,
      scriptEngine: LxScriptEngine(
        dio: dio,
        assetLoader: (_) async => throw StateError('no assets'),
      ),
    );
    final r = await resolvers.resolvePlayUrl(
      '66285',
      MusicPlatform.wy,
      AudioQuality.hires,
      'test',
    );
    // ignore: avoid_print
    print('PROBE resolve result: ${r == null ? 'NULL' : r.url}');
    // ignore: avoid_print
    print('PROBE resolve via: ${r?.via} quality: ${r?.quality}');
    if (r != null) {
      // ignore: avoid_print
      print('PROBE isPlayableUrl(resolved): ${isPlayableUrl(r.url)}');
      // ignore: avoid_print
      print('PROBE candidates: ${r.candidates}');
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
