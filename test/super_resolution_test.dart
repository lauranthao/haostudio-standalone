// Anime4K super-resolution (build 28, item J) — gate, chain,
// command and bundle tests.
//
// What this pins:
// - The gate is VOD-only AND MPV-only AND switch-on. Live, IJK and
//   AVPlayer all mount nothing; the switch defaults off.
// - A partial chain is NEVER mounted (missing one file -> null).
// - `glsl-shaders` goes through `change-list` with ONE colon-joined
//   argument — never a comma-joined string via setProperty (mpv
//   would take the whole value as a single shader filename).
// - All 7 efficiency-chain shaders are in the Flutter bundle and
//   unpack incrementally to disk.
// NOT covered here (needs chen's iPhone): whether the chain compiles
// under iOS GLES 3.0 and holds realtime on an iPhone Air.

import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/player/kernel/mpv_properties.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/player/super_resolution.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('gate (shouldApplySuperResolution)', () {
    test('VOD + MPV + switch on mounts', () {
      expect(
        shouldApplySuperResolution(
          isLive: false,
          engine: PlayerEngine.mediaKit,
          switchOn: true,
        ),
        isTrue,
      );
    });

    test('live never mounts, even with the switch on', () {
      expect(
        shouldApplySuperResolution(
          isLive: true,
          engine: PlayerEngine.mediaKit,
          switchOn: true,
        ),
        isFalse,
      );
    });

    test('IJK never mounts, even for VOD with the switch on', () {
      expect(
        shouldApplySuperResolution(
          isLive: false,
          engine: PlayerEngine.fijk,
          switchOn: true,
        ),
        isFalse,
      );
    });

    test('AVPlayer never mounts, even for VOD with the switch on', () {
      expect(
        shouldApplySuperResolution(
          isLive: false,
          engine: PlayerEngine.exo,
          switchOn: true,
        ),
        isFalse,
      );
    });

    test('switch off mounts nothing', () {
      expect(
        shouldApplySuperResolution(
          isLive: false,
          engine: PlayerEngine.mediaKit,
          switchOn: false,
        ),
        isFalse,
      );
    });
  });

  group('switch default', () {
    test('reads off when Hive is uninitialised (default off)', () {
      // HiveStore is never initialised in this file: any storage
      // failure must read as off, never as on.
      expect(superResolutionSwitchOn(), isFalse);
    });
  });

  group('efficiency chain constant', () {
    test('exactly the 7 efficiency files, in upstream mount order', () {
      expect(kAnime4kEfficiencyShaders, [
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Restore_CNN_M.glsl',
        'Anime4K_Restore_CNN_S.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
        'Anime4K_AutoDownscalePre_x2.glsl',
        'Anime4K_AutoDownscalePre_x4.glsl',
        'Anime4K_Upscale_CNN_x2_S.glsl',
      ]);
    });

    test('no quality-chain (VL) file ships', () {
      for (final name in kAnime4kEfficiencyShaders) {
        expect(name.contains('_VL'), isFalse);
      }
    });
  });

  group('chain resolution (resolveAnime4kChain)', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('anime4k_chain_');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('empty directory mounts nothing', () {
      expect(resolveAnime4kChain(dir), isNull);
    });

    test('one missing file mounts nothing (no partial chain)', () {
      for (final name in kAnime4kEfficiencyShaders.skip(1)) {
        File('${dir.path}${Platform.pathSeparator}$name')
            .writeAsStringSync('// stub');
      }
      expect(resolveAnime4kChain(dir), isNull);
    });

    test('complete chain resolves to 7 absolute paths, in order', () {
      for (final name in kAnime4kEfficiencyShaders) {
        File('${dir.path}${Platform.pathSeparator}$name')
            .writeAsStringSync('// stub');
      }
      final chain = resolveAnime4kChain(dir);
      expect(chain, isNotNull);
      expect(chain, hasLength(7));
      for (var i = 0; i < chain!.length; i++) {
        expect(chain[i], endsWith(kAnime4kEfficiencyShaders[i]));
        expect(chain[i].startsWith(dir.path), isTrue);
      }
    });
  });

  group('mpv command (glslShadersChangeListCommand)', () {
    test('change-list set with one colon-joined argument', () {
      final files = [
        '/support/anime_shaders/Anime4K_Clamp_Highlights.glsl',
        '/support/anime_shaders/Anime4K_Restore_CNN_M.glsl',
      ];
      expect(glslShadersChangeListCommand(files), [
        'change-list',
        'glsl-shaders',
        'set',
        '/support/anime_shaders/Anime4K_Clamp_Highlights.glsl'
            ':/support/anime_shaders/Anime4K_Restore_CNN_M.glsl',
      ]);
    });

    test('option name is the mpv list option, not a setProperty key', () {
      expect(kMpvGlslShadersOption, 'glsl-shaders');
      final command = glslShadersChangeListCommand(['/a.glsl']);
      // Exactly one argument carries the paths — no comma join.
      expect(command.last.contains(','), isFalse);
      expect(command, hasLength(4));
    });
  });

  group('bundle + unpack', () {
    test('all 7 shaders are in the Flutter bundle', () async {
      for (final name in kAnime4kEfficiencyShaders) {
        final data = await rootBundle.load('$kAnime4kAssetDir/$name');
        expect(data.lengthInBytes, greaterThan(0), reason: name);
      }
    });

    test('unpack writes the whole chain and is incremental', () async {
      final support =
          Directory.systemTemp.createTempSync('anime4k_unpack_');
      addTearDown(() {
        if (support.existsSync()) support.deleteSync(recursive: true);
      });

      final first = await unpackAnime4kShaders(supportDirectory: support);
      expect(first, isNotNull);
      expect(first, hasLength(7));
      final unpacked =
          Directory('${support.path}${Platform.pathSeparator}$kAnime4kUnpackDirName');
      expect(unpacked.existsSync(), isTrue);
      for (final name in kAnime4kEfficiencyShaders) {
        final file = File(
          '${unpacked.path}${Platform.pathSeparator}$name',
        );
        expect(file.existsSync(), isTrue, reason: name);
        expect(file.lengthSync(), greaterThan(0), reason: name);
      }

      // Second unpack leaves existing files alone (mtime unchanged).
      final mtimes = [
        for (final name in kAnime4kEfficiencyShaders)
          File('${unpacked.path}${Platform.pathSeparator}$name')
              .lastModifiedSync(),
      ];
      final second = await unpackAnime4kShaders(supportDirectory: support);
      expect(second, first);
      for (var i = 0; i < kAnime4kEfficiencyShaders.length; i++) {
        expect(
          File('${unpacked.path}${Platform.pathSeparator}'
                  '${kAnime4kEfficiencyShaders[i]}')
              .lastModifiedSync(),
          mtimes[i],
        );
      }
    });
  });
}
