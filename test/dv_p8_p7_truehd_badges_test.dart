// DV P8 downgrade switch / P7 base-layer / TrueHD PCM routing /
// Emby detail spec badges (1.1.6, task: HDR/DV/audio doable part).
//
// Kernel + facts side: hermetic (no network, no native player).
// Badge golden side: canned EmbyClient through the detail page's
// test-only `client` seam — same harness as emby_render_test.dart
// (Hive temp dir, CJK + Material icon fonts from the VM).
//
// Fixture apiKey is FAKE ('test-key-123'), never a real credential.

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/player/kernel/player_kernel.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/features/video/emby_detail_page.dart';
import 'package:standalone/services/video/emby_client.dart';
import 'package:standalone/services/video/emby_models.dart';

const _config = EmbyServerConfig(
  baseUrl: 'http://127.0.0.1:8096',
  apiKey: 'test-key-123',
  userId: 'user-1',
);

/// P8.1 MP4, HEVC, AAC — the switch-on case: AVPlayer may take it.
const _p8Mp4Url =
    'http://127.0.0.1:8096/emby/Videos/p8/stream?static=true'
    '&api_key=test-key-123'
    '&hao_container=mp4&hao_vcodec=hevc&hao_acodec=aac'
    '&hao_dv=1&hao_dvprofile=8.1&hao_width=3840&hao_height=2160';

/// P8.1 MKV: container still bars AVPlayer even with the switch on.
const _p8MkvUrl =
    'http://127.0.0.1:8096/emby/Videos/p8m/stream?static=true'
    '&api_key=test-key-123'
    '&hao_container=mkv&hao_vcodec=hevc&hao_acodec=aac'
    '&hao_dv=1&hao_dvprofile=8.1';

/// P7 MKV (Blu-ray remux): base layer only, never AVPlayer.
const _p7MkvUrl =
    'http://127.0.0.1:8096/emby/Videos/p7/stream?static=true'
    '&api_key=test-key-123'
    '&hao_container=mkv&hao_vcodec=hevc&hao_acodec=truehd'
    '&hao_dv=1&hao_dvprofile=7.1';

/// P7 in MP4: still never AVPlayer (dual-layer DV is not playable
/// by AVFoundation even in MP4).
const _p7Mp4Url =
    'http://127.0.0.1:8096/emby/Videos/p7m/stream?static=true'
    '&api_key=test-key-123'
    '&hao_container=mp4&hao_vcodec=hevc&hao_acodec=aac'
    '&hao_dv=1&hao_dvprofile=7.1';

void main() {
  group('EmbyStreamFacts: DV profile + size parsing', () {
    test('DoviProfile81 -> profile 8, compat 1, DV true', () {
      final facts = EmbyStreamFacts.fromMediaSources([
        {
          'Container': 'mp4',
          'MediaStreams': [
            {
              'Type': 'Video',
              'Codec': 'hevc',
              'Width': 3840,
              'Height': 2160,
              'VideoRange': 'DolbyVision',
              'ExtendedVideoType': 'DolbyVision',
              'ExtendedVideoSubType': 'DoviProfile81',
            },
            {'Type': 'Audio', 'Codec': 'aac', 'IsDefault': true},
          ],
        },
      ]);
      expect(facts.dolbyVision, isTrue);
      expect(facts.dvProfile, 8);
      expect(facts.dvCompatId, 1);
      expect(facts.width, 3840);
      expect(facts.height, 2160);
      expect(facts.toQueryParams(), {
        'hao_container': 'mp4',
        'hao_vcodec': 'hevc',
        'hao_acodec': 'aac',
        'hao_dv': '1',
        'hao_dvprofile': '8.1',
        'hao_width': '3840',
        'hao_height': '2160',
      });
    });

    test('DoviProfile71 -> profile 7 (P7 base layer)', () {
      final facts = EmbyStreamFacts.fromMediaSources([
        {
          'Container': 'mkv',
          'MediaStreams': [
            {
              'Type': 'Video',
              'Codec': 'hevc',
              'Width': 3840,
              'Height': 2160,
              'ExtendedVideoSubType': 'DoviProfile71',
            },
            {'Type': 'Audio', 'Codec': 'truehd', 'IsDefault': true},
          ],
        },
      ]);
      expect(facts.dolbyVision, isTrue);
      expect(facts.dvProfile, 7);
      expect(facts.dvCompatId, 1);
      expect(facts.toQueryParams()['hao_dvprofile'], '7.1');
    });

    test('ExtendedVideoType alone still detects DV (profile unknown)',
        () {
      final facts = EmbyStreamFacts.fromMediaSources([
        {
          'Container': 'mp4',
          'MediaStreams': [
            {
              'Type': 'Video',
              'Codec': 'hevc',
              'ExtendedVideoType': 'DolbyVision',
              'ExtendedVideoSubType': 'None',
            },
          ],
        },
      ]);
      expect(facts.dolbyVision, isTrue);
      expect(facts.dvProfile, isNull);
      expect(facts.toQueryParams(), isNot(contains('hao_dvprofile')));
    });

    test('VideoRangeType fallback still works (old servers / old tests)',
        () {
      final facts = EmbyStreamFacts.fromMediaSources([
        {
          'Container': 'mkv',
          'MediaStreams': [
            {
              'Type': 'Video',
              'Codec': 'hevc',
              'VideoRangeType': 'DOLBYVISION',
            },
            {'Type': 'Audio', 'Codec': 'truehd', 'IsDefault': true},
          ],
        },
      ]);
      expect(facts.dolbyVision, isTrue);
      expect(facts.dvProfile, isNull);
    });

    test('plain HDR10 file: no DV, size still parsed', () {
      final facts = EmbyStreamFacts.fromMediaSources([
        {
          'Container': 'mp4',
          'MediaStreams': [
            {
              'Type': 'Video',
              'Codec': 'hevc',
              'Width': 1920,
              'Height': 1080,
              'VideoRange': 'HDR',
              'ExtendedVideoType': 'None',
              'ExtendedVideoSubType': 'None',
            },
          ],
        },
      ]);
      expect(facts.dolbyVision, isFalse);
      expect(facts.dvProfile, isNull);
      expect(facts.width, 1920);
      expect(facts.height, 1080);
      expect(facts.toQueryParams(), {
        'hao_container': 'mp4',
        'hao_vcodec': 'hevc',
        'hao_width': '1920',
        'hao_height': '1080',
      });
    });
  });

  group('streamFactsOf / is4K', () {
    test('parses hao_dvprofile + size markers', () {
      final facts = streamFactsOf(_p8Mp4Url)!;
      expect(facts.dolbyVision, isTrue);
      expect(facts.dvProfile, 8);
      expect(facts.width, 3840);
      expect(facts.height, 2160);
      expect(facts.is4K, isTrue);
    });

    test('is4K boundaries', () {
      expect(
        const StreamFacts(width: 3840, height: 2160).is4K,
        isTrue,
      );
      // Scope crop: 3840 wide, height under 2160 — still 4K.
      expect(
        const StreamFacts(width: 3840, height: 1600).is4K,
        isTrue,
      );
      // 2160 tall on its own counts.
      expect(
        const StreamFacts(width: 1920, height: 2160).is4K,
        isTrue,
      );
      // DCI 4K width.
      expect(const StreamFacts(width: 4096, height: 1716).is4K, isTrue);
      expect(
        const StreamFacts(width: 1920, height: 1080).is4K,
        isFalse,
      );
      expect(const StreamFacts().is4K, isFalse);
    });

    test('garbage hao_dvprofile reads as unknown profile, not a crash',
        () {
      final facts = streamFactsOf(
        'https://x/stream?hao_dv=1&hao_dvprofile=banana',
      )!;
      expect(facts.dolbyVision, isTrue);
      expect(facts.dvProfile, isNull);
    });
  });

  group('P8 downgrade switch: key + default', () {
    test('key name is the hao_vod_* contract', () {
      expect(HiveKeys.vodDvP8Downgrade, 'hao_vod_dv_p8_downgrade');
    });

    test('unset reads as ON (the decided default)', () async {
      // HiveStore is initialised by the golden setUpAll below with
      // an empty test box in widget runs; in a pure unit run it is
      // uninitialised and the reader still returns the default.
      // Either way the answer must be ON unless stored otherwise.
      await HiveStore.delete(HiveKeys.vodDvP8Downgrade);
      expect(dvDowngradeToHdrSwitchOn(), isTrue);
    });

    test('stored false reads as false, stored true as true', () async {
      await HiveStore.put(HiveKeys.vodDvP8Downgrade, false);
      expect(dvDowngradeToHdrSwitchOn(), isFalse);
      await HiveStore.put(HiveKeys.vodDvP8Downgrade, true);
      expect(dvDowngradeToHdrSwitchOn(), isTrue);
      await HiveStore.delete(HiveKeys.vodDvP8Downgrade);
    });
  });

  group('engineCanPlayFacts: P8 / P7 routing', () {
    test('P8 MP4 + switch on: AVPlayer admitted', () {
      expect(
        engineCanPlayFacts(
          PlayerEngine.exo,
          const StreamFacts(
            container: 'mp4',
            videoCodec: 'hevc',
            audioCodec: 'aac',
            dolbyVision: true,
            dvProfile: 8,
          ),
          dvDowngradeToHdr: true,
        ),
        isTrue,
      );
    });

    test('P8 MP4 + switch off: AVPlayer excluded (old behaviour)', () {
      expect(
        engineCanPlayFacts(
          PlayerEngine.exo,
          const StreamFacts(
            container: 'mp4',
            videoCodec: 'hevc',
            audioCodec: 'aac',
            dolbyVision: true,
            dvProfile: 8,
          ),
          dvDowngradeToHdr: false,
        ),
        isFalse,
      );
    });

    test('P8 MKV + switch on: container still bars AVPlayer', () {
      expect(
        engineCanPlayFacts(
          PlayerEngine.exo,
          const StreamFacts(
            container: 'mkv',
            videoCodec: 'hevc',
            dolbyVision: true,
            dvProfile: 8,
          ),
          dvDowngradeToHdr: true,
        ),
        isFalse,
      );
    });

    test('P7 never reaches AVPlayer, switch on or off, MP4 or MKV',
        () {
      for (final container in ['mp4', 'mkv']) {
        for (final on in [true, false]) {
          expect(
            engineCanPlayFacts(
              PlayerEngine.exo,
              StreamFacts(
                container: container,
                videoCodec: 'hevc',
                dolbyVision: true,
                dvProfile: 7,
              ),
              dvDowngradeToHdr: on,
            ),
            isFalse,
            reason: 'P7 $container switch=$on must stay ffmpeg-only',
          );
        }
      }
    });

    test('P5 and unknown-profile DV stay ffmpeg-only', () {
      expect(
        engineCanPlayFacts(
          PlayerEngine.exo,
          const StreamFacts(
            container: 'mp4',
            dolbyVision: true,
            dvProfile: 5,
          ),
          dvDowngradeToHdr: true,
        ),
        isFalse,
      );
      expect(
        engineCanPlayFacts(
          PlayerEngine.exo,
          const StreamFacts(container: 'mp4', dolbyVision: true),
          dvDowngradeToHdr: true,
        ),
        isFalse,
      );
    });

    test('P8 admission does not leak past the TrueHD audio gate', () {
      // P8 MP4 with TrueHD default audio: AVPlayer is still out
      // (it cannot decode TrueHD) even with the switch on.
      expect(
        engineCanPlayFacts(
          PlayerEngine.exo,
          const StreamFacts(
            container: 'mp4',
            videoCodec: 'hevc',
            audioCodec: 'truehd',
            dolbyVision: true,
            dvProfile: 8,
          ),
          dvDowngradeToHdr: true,
        ),
        isFalse,
      );
    });

    test('ffmpeg kernels take everything, both switch states', () {
      for (final on in [true, false]) {
        for (final engine in [PlayerEngine.mediaKit, PlayerEngine.fijk]) {
          expect(
            engineCanPlayFacts(
              engine,
              const StreamFacts(
                container: 'mkv',
                audioCodec: 'truehd',
                dolbyVision: true,
                dvProfile: 7,
              ),
              dvDowngradeToHdr: on,
            ),
            isTrue,
          );
        }
      }
    });
  });

  group('candidatesFor: P8 / P7 / TrueHD', () {
    test('P8 MP4, switch on, preferred AVPlayer: AVPlayer first', () {
      final c = candidatesFor(
        url: _p8Mp4Url,
        isLive: false,
        preferred: PlayerEngine.exo,
        dvDowngradeToHdr: true,
      );
      expect(c.first, PlayerEngine.exo);
      expect(c, containsAll(
          [PlayerEngine.exo, PlayerEngine.mediaKit, PlayerEngine.fijk]));
    });

    test('P8 MP4, switch off: AVPlayer out, MPV then IJK', () {
      final c = candidatesFor(
        url: _p8Mp4Url,
        isLive: false,
        preferred: PlayerEngine.exo,
        dvDowngradeToHdr: false,
      );
      expect(c, [PlayerEngine.mediaKit, PlayerEngine.fijk]);
    });

    test('P8 MKV, switch on: container still bars AVPlayer', () {
      final c = candidatesFor(
        url: _p8MkvUrl,
        isLive: false,
        preferred: PlayerEngine.exo,
        dvDowngradeToHdr: true,
      );
      expect(c, [PlayerEngine.mediaKit, PlayerEngine.fijk]);
    });

    test('P7 MKV, switch on: MPV first, AVPlayer out', () {
      final c = candidatesFor(
        url: _p7MkvUrl,
        isLive: false,
        preferred: PlayerEngine.exo,
        dvDowngradeToHdr: true,
      );
      expect(c, [PlayerEngine.mediaKit, PlayerEngine.fijk]);
    });

    test('P7 MP4, switch on: AVPlayer still out', () {
      final c = candidatesFor(
        url: _p7Mp4Url,
        isLive: false,
        preferred: PlayerEngine.exo,
        dvDowngradeToHdr: true,
      );
      expect(c, [PlayerEngine.mediaKit, PlayerEngine.fijk]);
    });

    test('TrueHD MP4 routes to MPV (PCM fallback), AVPlayer out', () {
      const url =
          'http://127.0.0.1:8096/emby/Videos/t/stream?static=true'
          '&hao_container=mp4&hao_vcodec=hevc&hao_acodec=truehd';
      final c = candidatesFor(
        url: url,
        isLive: false,
        preferred: PlayerEngine.exo,
      );
      expect(c, [PlayerEngine.mediaKit, PlayerEngine.fijk]);
    });
  });

  group('EmbySpecBadges.labelsFor', () {
    test('DV + 4K, DV only, 4K only, none', () {
      expect(
        EmbySpecBadges.labelsFor(
          const StreamFacts(
            dolbyVision: true,
            width: 3840,
            height: 2160,
          ),
        ),
        ['DV', '4K'],
      );
      expect(
        EmbySpecBadges.labelsFor(
          const StreamFacts(dolbyVision: true, width: 1920, height: 1080),
        ),
        ['DV'],
      );
      expect(
        EmbySpecBadges.labelsFor(
          const StreamFacts(width: 3840, height: 2160),
        ),
        ['4K'],
      );
      expect(
        EmbySpecBadges.labelsFor(
          const StreamFacts(width: 1920, height: 1080),
        ),
        isEmpty,
      );
      expect(EmbySpecBadges.labelsFor(null), isEmpty);
    });
  });

  // -- Detail-page badges: widget + golden ---------------------------

  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-dv-badges-');
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
    await _loadCjkFont();
  });

  tearDownAll(() async {
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  setUp(() async {
    HaoHaptics.debugEnabledOverride = false;
    await HiveStore.delete(HiveKeys.embyConfig);
    await HiveStore.delete(HiveKeys.videoTabMode);
    await HiveStore.delete(HiveKeys.embyHomeCache);
    await HiveStore.delete(HiveKeys.videoHistory);
    await HiveStore.delete(HiveKeys.vodDvP8Downgrade);
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
  });

  void setPhoneSize(WidgetTester tester) {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> pumpUntilFound(
    WidgetTester tester,
    Finder finder,
  ) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('expected $finder to appear after the canned load');
  }

  /// Canned detail fetch: 'dv4k' is a P8.1 4K film (badges on),
  /// 'plain' has no MediaSources (badges off).
  Future<EmbyResponse> cannedFetcher(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 8),
    CancelToken? cancelToken,
  }) async {
    if (url.contains('/Items/dv4k')) {
      return EmbyResponse(statusCode: 200, json: {
        'Id': 'dv4k',
        'Name': '流浪地球2',
        'Type': 'Movie',
        'ProductionYear': 2023,
        'CommunityRating': 8.3,
        'Genres': ['科幻'],
        'Overview': '太阳即将毁灭，人类开启流浪地球计划，带着地球逃离太阳系。',
        'MediaSources': [
          {
            'Container': 'mp4',
            'MediaStreams': [
              {
                'Type': 'Video',
                'Codec': 'hevc',
                'Width': 3840,
                'Height': 2160,
                'VideoRange': 'DolbyVision',
                'ExtendedVideoType': 'DolbyVision',
                'ExtendedVideoSubType': 'DoviProfile81',
              },
              {'Type': 'Audio', 'Codec': 'truehd', 'IsDefault': true},
            ],
          },
        ],
      });
    }
    if (url.contains('/Items/plain')) {
      return const EmbyResponse(statusCode: 200, json: {
        'Id': 'plain',
        'Name': '奥本海默',
        'Type': 'Movie',
        'ProductionYear': 2023,
        'CommunityRating': 8.8,
        'Genres': ['剧情', '历史'],
      });
    }
    return const EmbyResponse(statusCode: 404, json: {});
  }

  EmbyClient cannedClient() =>
      EmbyClient(config: _config, fetcher: cannedFetcher);

  Future<void> pumpDetail(
    WidgetTester tester,
    ThemeData theme,
    String itemId,
  ) async {
    setPhoneSize(tester);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: EmbyDetailPage(
          itemId: itemId,
          client: cannedClient(),
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('正片'));
    // Fade-in (350 ms) must finish or the golden is blank.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
  }

  ThemeData light() =>
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).light);
  ThemeData dark() => _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).dark);

  testWidgets('detail page shows DV + 4K badges for a P8.1 4K film',
      (tester) async {
    await pumpDetail(tester, light(), 'dv4k');
    expect(find.text('DV'), findsOneWidget);
    expect(find.text('4K'), findsOneWidget);
    expect(find.text('流浪地球2'), findsWidgets);
  });

  testWidgets('detail page shows no badges without facts',
      (tester) async {
    await pumpDetail(tester, light(), 'plain');
    expect(find.text('DV'), findsNothing);
    expect(find.text('4K'), findsNothing);
    expect(find.text('奥本海默'), findsWidgets);
  });

  testWidgets('golden: detail badges light', (tester) async {
    await pumpDetail(tester, light(), 'dv4k');
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/emby_detail_badges_light.png'),
    );
  });

  testWidgets('golden: detail badges dark', (tester) async {
    await pumpDetail(tester, dark(), 'dv4k');
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/emby_detail_badges_dark.png'),
    );
  });
}

Future<void> _loadCjkFont() async {
  final loader = FontLoader('NotoSansSC');
  for (final path in const [
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc',
  ]) {
    final bytes = await File(path).readAsBytes();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
  final iconLoader = FontLoader('MaterialIcons');
  final iconBytes = await File(
    '/home/hatch/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ).readAsBytes();
  iconLoader.addFont(Future.value(ByteData.view(iconBytes.buffer)));
  await iconLoader.load();
}

ThemeData _cjkTheme(ThemeData base) {
  final text = base.textTheme.apply(fontFamily: 'NotoSansSC');
  final primary = base.primaryTextTheme.apply(fontFamily: 'NotoSansSC');
  ButtonStyle cjkButton(ButtonStyle? style) {
    final resolved = style?.textStyle?.resolve({});
    return (style ?? const ButtonStyle()).copyWith(
      textStyle: WidgetStatePropertyAll(
        (resolved ?? const TextStyle()).copyWith(fontFamily: 'NotoSansSC'),
      ),
    );
  }

  TextStyle cjkStyle(TextStyle? style) =>
      (style ?? const TextStyle()).copyWith(fontFamily: 'NotoSansSC');

  return base.copyWith(
    textTheme: text,
    primaryTextTheme: primary,
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: cjkStyle(base.appBarTheme.titleTextStyle),
    ),
    bottomNavigationBarTheme: base.bottomNavigationBarTheme.copyWith(
      selectedLabelStyle: cjkStyle(
        base.bottomNavigationBarTheme.selectedLabelStyle,
      ),
      unselectedLabelStyle: cjkStyle(
        base.bottomNavigationBarTheme.unselectedLabelStyle,
      ),
    ),
    listTileTheme: base.listTileTheme.copyWith(
      titleTextStyle: cjkStyle(base.listTileTheme.titleTextStyle),
      subtitleTextStyle: cjkStyle(base.listTileTheme.subtitleTextStyle),
    ),
    sliderTheme: base.sliderTheme.copyWith(
      valueIndicatorTextStyle: cjkStyle(
        base.sliderTheme.valueIndicatorTextStyle,
      ),
    ),
    segmentedButtonTheme: base.segmentedButtonTheme.copyWith(
      style: cjkButton(base.segmentedButtonTheme.style),
    ),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: cjkStyle(base.chipTheme.labelStyle),
    ),
    dialogTheme: base.dialogTheme.copyWith(
      titleTextStyle: cjkStyle(base.dialogTheme.titleTextStyle),
      contentTextStyle: cjkStyle(base.dialogTheme.contentTextStyle),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: cjkButton(base.filledButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: cjkButton(base.textButtonTheme.style),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      hintStyle: cjkStyle(base.inputDecorationTheme.hintStyle),
      labelStyle: cjkStyle(base.inputDecorationTheme.labelStyle),
    ),
  );
}
