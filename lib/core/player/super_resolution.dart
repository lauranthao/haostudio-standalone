// Anime4K real-time super-resolution — VOD only, MPV only (build 28).
//
// mpv mounts GLSL shaders through the list-valued `glsl-shaders`
// option; the files must exist on disk, so the bundled assets are
// unpacked to the app support directory once and reused from there
// (upstream pattern: Pure Live `lib/core/player/super_resolution.dart`,
// borrowed from Kazumi's player).
//
// Scope, decided by chen (2026-11-21):
// - VOD only, never live. The gate is `!isLive && switch on &&
//   engine == MPV`; the wiring lives entirely in MpvBackend.open(),
//   so a user on IJK/AVPlayer or a recovery-ladder fallback to a
//   non-MPV backend simply plays without super-resolution.
// - One bool switch, one tier: the efficiency chain only (7 files).
//   The quality chain (VL models, heaviest) is NOT bundled and no
//   dead quality files ship.
// - Default off. Applies at open() from the Hive switch; a LATER
//   toggle goes through MpvBackend.setSuperResolution() on the
//   running player instead (b30: 马上生效, no reopen).
// - A partial chain is NEVER mounted: mpv would run the shaders it
//   got and the picture would go soft in a way no setting explains,
//   while each missing file's open failure reaches the kernel as a
//   playback error for the source that happens to be live — the
//   recovery ladder would then burn every line over a rendering
//   decoration.
//
// Effect risk (upstream's own words, super_resolution.dart:16):
// "Desktop GPUs only — a phone GPU cannot run the CNN chain in
// realtime." Pure Live's own gate is
// `superResolutionAvailable => Platform.isWindows`. iOS/Android never
// walked this path upstream, so whether the efficiency chain compiles
// under iOS GLES 3.0 and holds realtime on an iPhone Air is
// UNVERIFIED here — it is chen's phone that decides. That is why the
// switch defaults off and every failure below degrades to plain
// playback instead of an error.
//
// Shaders: Anime4K by bloc97, MIT. Files keep their upstream license
// headers; the full text ships as assets/anime4k/LICENSE-Anime4K.

import 'dart:io';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:path_provider/path_provider.dart';

import '../storage/hive_store.dart';
import 'kernel/mpv_properties.dart';
import 'kernel/player_engine.dart';

/// Flutter-asset directory holding the bundled Anime4K shaders.
const String kAnime4kAssetDir = 'assets/anime4k';

/// Subdirectory of the app support directory the shaders unpack to.
const String kAnime4kUnpackDirName = 'anime_shaders';

/// Efficiency-chain shader set, in mount order (Kazumi's
/// `mpvAnime4KShadersLite`, via Pure Live `super_resolution.dart`).
/// Single tier for the single bool switch — there is no quality chain.
const List<String> kAnime4kEfficiencyShaders = [
  'Anime4K_Clamp_Highlights.glsl',
  'Anime4K_Restore_CNN_M.glsl',
  'Anime4K_Restore_CNN_S.glsl',
  'Anime4K_Upscale_CNN_x2_M.glsl',
  'Anime4K_AutoDownscalePre_x2.glsl',
  'Anime4K_AutoDownscalePre_x4.glsl',
  'Anime4K_Upscale_CNN_x2_S.glsl',
];

/// The persisted switch (HiveKeys.vodSuperResolution, default off).
/// Any storage failure reads as off — super-resolution must never
/// turn itself on because Hive is uninitialised or corrupt.
bool superResolutionSwitchOn() {
  try {
    return HiveStore.getBool(HiveKeys.vodSuperResolution, false);
  } catch (_) {
    return false;
  }
}

/// The whole gate in one place: VOD only, switch on, MPV only.
/// Live, IJK and AVPlayer all answer false — the caller then mounts
/// nothing and playback proceeds exactly as before.
bool shouldApplySuperResolution({
  required bool isLive,
  required PlayerEngine engine,
  required bool switchOn,
}) =>
    !isLive && switchOn && engine == PlayerEngine.mediaKit;

/// Absolute paths of the efficiency chain inside [shaderDirectory],
/// in mount order — or null when the directory does not hold the
/// WHOLE chain. A partial chain is not mounted on purpose (see the
/// file header). Pure and synchronous, so tests can pin it exactly.
List<String>? resolveAnime4kChain(Directory shaderDirectory) {
  final files = [
    for (final name in kAnime4kEfficiencyShaders)
      '${shaderDirectory.path}${Platform.pathSeparator}$name',
  ];
  return files.every((file) => File(file).existsSync()) ? files : null;
}

/// Unpacks the bundled shaders to `<support>/anime_shaders` and
/// returns the mountable chain, or null when the chain cannot be
/// completed.
///
/// Incremental: files that already exist are left alone, so the cost
/// is paid once per app install. A single unreadable/missing asset
/// does not throw — it leaves the chain incomplete and this returns
/// null, so the caller mounts nothing instead of a partial chain.
///
/// [supportDirectory] / [bundle] are test seams; production passes
/// neither (support dir from path_provider, assets from rootBundle).
Future<List<String>?> unpackAnime4kShaders({
  Directory? supportDirectory,
  AssetBundle? bundle,
}) async {
  final support = supportDirectory ?? await getApplicationSupportDirectory();
  final directory = Directory(
    '${support.path}${Platform.pathSeparator}$kAnime4kUnpackDirName',
  );
  if (!directory.existsSync()) {
    directory.createSync(recursive: true);
  }
  final assets = bundle ?? rootBundle;
  for (final name in kAnime4kEfficiencyShaders) {
    final target = File(
      '${directory.path}${Platform.pathSeparator}$name',
    );
    if (target.existsSync()) continue;
    try {
      final data = await assets.load('$kAnime4kAssetDir/$name');
      target.writeAsBytesSync(data.buffer.asUint8List(), flush: true);
    } catch (_) {
      // Leave the file absent: resolveAnime4kChain below then
      // returns null and nothing is mounted.
    }
  }
  return resolveAnime4kChain(directory);
}

/// The mpv command that mounts a resolved chain.
///
/// `glsl-shaders` is a LIST option — it must go through `command`
/// as `change-list ... set <colon-joined absolute paths>`. It must
/// NEVER go through `setProperty` with a joined string: mpv's string
/// property write takes the whole value as ONE entry and mpv then
/// tries to open a single shader literally named
/// "a.glsl:b.glsl:...". iOS absolute paths contain no ':', so the
/// colon join is unambiguous.
List<String> glslShadersChangeListCommand(List<String> shaderFiles) =>
    ['change-list', kMpvGlslShadersOption, 'set', shaderFiles.join(':')];

/// The mpv command that unmounts the chain again (b30: turning
/// super-resolution off mid-playback). `clr` clears the whole
/// `glsl-shaders` list — the app mounts nothing else into it, so
/// clearing is exactly "no super-resolution", never a partial chain.
List<String> glslShadersClearCommand() =>
    ['change-list', kMpvGlslShadersOption, 'clr'];
