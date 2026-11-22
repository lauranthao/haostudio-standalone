// Settings tab — Beans-style restyle (stage 1, task 5).
//
// Structure follows Beans `SettingsView` (ProfileView.swift:1129+):
// - left-aligned title "设置" (chen 2026-11-21, screenshot): a big
//   bold header at the top-left of the list (26 w800), like his
//   我的片库 screenshot — not a small top-bar title, and no AppBar.
// - big section titles (Beans `SectionHeader`: 21 bold)
// - every row its own glass card (Beans `GlassCard` radius 18,
//   row padding h14 v13; icon 14 in a 28-wide frame, title 15,
//   subtitle 11, chevron 11 semibold)
// - collapsible sections (build 29 B组, chen 2026-11-22 “设置里面要可以
//   收放啊”): six groups (外观 / 音乐播放 / 影视播放 / 源管理 / 数据 /
//   关于), each with a tappable header — Cupertino chevron_down that
//   rotates down (expanded) / right (collapsed) with a spring
//   (easeOutBack), body animated by AnimatedSize. Expanded state is
//   persisted per group in Hive (bool, default true = all expanded);
//   the old expandable 播放设置 / 播放器引擎 headers are gone; the
//   music panel keeps the Beans glass panel (radius 22, padding 16,
//   rows spaced 14, dividers muted 0.15)
// - quality chips (Beans `playbackQualitySection` / third-party
//   quality chips): height 31, h padding 12, font 12, selected fill
//   accent 0.14 + stroke accent 0.42 (0.8pt) + checkmark 9 bold,
//   unselected fill label 0.055 + stroke label 0.08
//
// Differences from Beans, with reasons:
// - NO "完成" capsule button top-right: Beans' SettingsView is a
//   pushed sheet with a dismiss target; this page is a root tab, so a
//   完成 button would have nowhere to go (a dead control).
// - NO third-party VIP notice row: removed per chen 2026-11-18
//   ("不提醒") — no switch, no notice logic, no entry point.
// - ONE quality row, not two: chen 2026-11-18 — all our songs are
//   resolved from third-party sources, so playback quality and
//   third-party quality are the same setting (MusicStore.quality,
//   5 tiers). Beans has two independent prefs (beans.audioQuality vs
//   beans.thirdPartyAudioQuality); ours is deliberately one.
// - Chevron glyphs are 16pt, not Beans' 11pt: a Material chevron at
//   11pt is unreadable. Icon/text sizes that do have a Beans source
//   are copied exactly.
// - Selected-tab accent is the theme accent (black after the
//   blue->black change), not Beans' amber — our themes own the accent.
// - The 版本 row opens the in-app 更新日志 page
//   (changelog_page.dart, bundled history, chen 2026-11-20) — the
//   row keeps its version/build subtitle and gains a chevron.
// - NO equalizer row: stage 3 added the engine (vendored just_audio
//   fork + MTAudioProcessingTap, see EqualizerStore), so the playback
//   panel now has a 均衡器 row showing 已开启/已关闭, opening the
//   10-band page — Beans `equalizerSection` (ProfileView.swift:2255).
// - The 120Hz row was deleted in build 28 (D2): it was display-only
//   with a checkmark, exactly like Beans, but 120Hz is pinned in
//   Info.plist + AppDelegate, so the row told the user nothing they
//   could act on.
//
// NOTHING else is deleted: theme, engine picker, backup export/import,
// source management (music/video/live), auto-next, danmaku, cache,
// version, update check and crash record are all still here — only
// the shell and structure changed. Every borrowed setting is wired
// to real behaviour (see the playback section).

import '../../core/theme/hao_radius.dart';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:glassy_ui_ios/glassy_ui_ios.dart' as glassy;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../widgets/hao_pressable.dart';
import '../../widgets/native_switch.dart';
import 'package:get/get.dart';
import '../../widgets/hao_toast.dart';
import '../../widgets/hao_inset_grouped.dart';
import '../../widgets/hao_segmented_control.dart';
import '../../widgets/settings_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/consts.dart';
import '../../core/logging/app_log.dart';
import '../../core/player/kernel/mpv_properties.dart';
import '../../core/player/kernel/player_engine.dart';
import '../../core/player/kernel/video_fit.dart';
import '../../core/player/vod_features.dart';
import '../../core/storage/hive_store.dart';
import '../../core/storage/local_paths.dart';
import '../../core/theme/appearance_store.dart';
import '../../core/theme/glass.dart';
import '../../core/theme/hao_themes.dart';
import '../../core/theme/haptics.dart';
import '../../core/theme/theme_controller.dart';
import '../../services/custom_font_service.dart';
import '../../services/music/lx_script_engine.dart';
import '../../services/music/lx_script_store.dart';
import '../../services/music/music_quality.dart';
import '../../services/music/music_store.dart';
import '../../services/backup_service.dart';
import '../../services/update_service.dart';
import 'accent_color_sheet.dart';
import 'app_log_page.dart';
import 'changelog_page.dart';
import '../music/av_music_player.dart';
import '../music/equalizer_page.dart';
import '../music/music_player_controller.dart';
import '../../services/music/equalizer_store.dart';
import '../video/video_history_store.dart';
import 'cache_settings_page.dart';
import 'danmaku_settings_page.dart';
import 'live_sources_page.dart';
import 'music_sources_page.dart';
import 'update_dialog.dart';
import 'video_categories_page.dart';
import 'video_sources_page.dart';
import 'wallpaper_page.dart';

class SettingsTabPage extends StatefulWidget {
  const SettingsTabPage({super.key});

  @override
  State<SettingsTabPage> createState() => _SettingsTabPageState();
}

/// No KeepAlive (P1-P3): a static settings list, no timers, streams
/// or polling. State re-reads Hive in initState on every tab switch.
class _SettingsTabPageState extends State<SettingsTabPage> {
  late String _engineKey;

  late bool _autoNext;
  // Good-projects P1 (PiliPlus/Kazumi): VOD picture fit + low-memory
  // mode. Cached like _autoNext; refreshed after every cycle tap.
  late VideoFitMode _videoFit;
  late LowMemoryMode _lowMemoryMode;
  late bool _mixWithOthers;
  late bool _autoResume;
  // Build 28: gates only the automatic update check at startup
  // (main.dart warm-up); the manual 检查更新 row is never gated.
  late bool _autoUpdateCheck;
  // Build 28 J: Anime4K super-resolution for VOD (default off).
  // Live playback never reads this flag.
  late bool _vodSuperResolution;
  // 1.1.6 VOD rows: skip-intro mode (String 'off' | 'manual' |
  // 'auto3s' | 'autoNow', default 'off'); frame interpolation,
  // SDR→HDR (both default off, MPV-only, mutually exclusive with
  // super-res in display only — stored values are never cleared);
  // DV Profile 8 downgrade-to-HDR (default ON, unlike the trio);
  // subtitle time offset in seconds (default 0.0, ±10s, 0.1s step).
  late String _vodSkipIntroMode;
  late bool _vodInterpolation;
  late bool _vodSdrToHdr;
  late bool _vodDvP8Downgrade;
  late double _vodSubtitleDelay;
  // 1.1.6 subtitle appearance tiers (String keys, defaults are the
  // mpv defaults — see vod_controls.dart): font size, colour,
  // position. Applied at the next open, same as the delay row.
  late String _vodSubtitleFontSize;
  late String _vodSubtitleColor;
  late String _vodSubtitlePosition;
  // I-影视 (build 29): one Hive key each, defaults all off/neutral
  // (see HiveKeys + vod_features.dart). Double-tap step (int,
  // default 10 s); dialogue boost (bool, default off — backend cap
  // pending K 组); spoiler hide-synopsis + blur-unwatched (bool,
  // default off); pure-audio default (bool, default off).
  late int _vodDoubleTapSeekSeconds;
  late bool _vodDialogueBoost;
  late bool _vodSpoilerHideSynopsis;
  late bool _vodSpoilerBlurUnwatched;
  late bool _vodAudioOnly;
  // 1.1.6 music row: loudness normalisation (default off).
  // Strength (0..2, default 1) is handled inside the player by
  // the music group — no row here.
  late bool _musicNormalizationEnabled;
  late bool _hapticsOn;
  late AudioQuality _quality;
  int? _sourceCount;
  // Appearance (stage 2 items 5-7): wallpaper on/off, background
  // colour on/off + hex, installed font display name. Refreshed
  // after every appearance action below.
  late bool _wallpaperOn;
  late bool _bgOn;
  late String _bgHex;
  late String _fontName;
  final _updateService = UpdateService();

  // Build 29 B组: 每组收起/展开状态. Hive key 在本文件内定义——HiveKeys
  // 在 hive_store.dart, 本组不碰那个文件, 所以不用往 HiveKeys 里加 key.
  // bool, 默认 true(全部展开); 备份导入后也要重读(见 _importBackup).
  static const _sectionIds = [
    'appearance',
    'music',
    'video',
    'sources',
    'data',
    'about',
  ];
  static String _sectionExpandedKey(String id) =>
      'settingsSectionExpanded_$id';
  late Map<String, bool> _sectionExpanded;

  MusicPlayerController get _player => MusicPlayerController.ensure();

  @override
  void initState() {
    super.initState();
    _engineKey = HiveStore.getString(HiveKeys.videoPlayerKey, 'mpv');
    _autoNext = VideoPlaybackSettings.autoNext;
    _videoFit = VideoPlaybackSettings.videoFit;
    _lowMemoryMode = LowMemoryMode.current;
    _mixWithOthers = HiveStore.getBool(HiveKeys.audioMixWithOthers, false);
    _autoResume = HiveStore.getBool(HiveKeys.autoResumeLastPlayback, false);
    _autoUpdateCheck = HiveStore.getBool(HiveKeys.autoUpdateCheck, true);
    _vodSuperResolution =
        HiveStore.getBool(HiveKeys.vodSuperResolution, false);
    _vodSkipIntroMode =
        HiveStore.getString(HiveKeys.vodSkipIntroMode, 'off');
    _vodInterpolation = HiveStore.getBool(HiveKeys.vodInterpolation, false);
    _vodSdrToHdr = HiveStore.getBool(HiveKeys.vodSdrToHdr, false);
    _vodDvP8Downgrade = HiveStore.getBool(HiveKeys.vodDvP8Downgrade, true);
    _vodSubtitleDelay = HiveStore.getDouble(HiveKeys.vodSubtitleDelay, 0.0);
    _vodSubtitleFontSize =
        HiveStore.getString(HiveKeys.vodSubtitleFontSize, 'medium');
    if (!_subFontSizeOrder.contains(_vodSubtitleFontSize)) {
      _vodSubtitleFontSize = 'medium';
    }
    _vodSubtitleColor =
        HiveStore.getString(HiveKeys.vodSubtitleColor, 'white');
    if (!_subColorOrder.contains(_vodSubtitleColor)) {
      _vodSubtitleColor = 'white';
    }
    _vodSubtitlePosition =
        HiveStore.getString(HiveKeys.vodSubtitlePosition, 'bottom');
    if (!_subPositionOrder.contains(_vodSubtitlePosition)) {
      _vodSubtitlePosition = 'bottom';
    }
    _vodDoubleTapSeekSeconds = vodDoubleTapSeekSeconds();
    _vodDialogueBoost = vodDialogueBoostEnabled();
    _vodSpoilerHideSynopsis = vodSpoilerHideSynopsis();
    _vodSpoilerBlurUnwatched = vodSpoilerBlurUnwatched();
    _vodAudioOnly = vodAudioOnlyDefault();
    _musicNormalizationEnabled =
        HiveStore.getBool(HiveKeys.musicNormalizationEnabled, false);
    _hapticsOn = HaoHaptics.enabled;
    _quality = MusicStore.quality;
    _loadSourceCount();
    _loadAppearance();
    _sectionExpanded = {
      for (final id in _sectionIds)
        id: HiveStore.getBool(_sectionExpandedKey(id), true),
    };
  }

  /// Build 29 B组: 点组头收起/展开. 乐观翻 UI 再写 Hive, 和壁纸/背景色
  /// 开关同一写法: 写失败翻回旧值并 toast, 不留 UI 与持久值不一致.
  Future<void> _toggleSection(String id) async {
    HaoHaptics.select();
    final previous = _sectionExpanded[id] ?? true;
    final next = !previous;
    setState(() => _sectionExpanded[id] = next);
    try {
      await HiveStore.put(_sectionExpandedKey(id), next);
    } catch (_) {
      if (!mounted) return;
      setState(() => _sectionExpanded[id] = previous);
      HaoToast.show('设置失败', message: '展开状态保存失败，请重试');
    }
  }

  /// Read the appearance state (wallpaper / background colour /
  /// font) into the page's cached fields.
  void _loadAppearance() {
    final appearance = AppearanceController.ensure();
    _wallpaperOn = appearance.wallpaperEnabled.value;
    _bgOn = appearance.backgroundEnabled.value;
    _bgHex = appearance.backgroundHex.value;
    _fontName = CustomFontService().currentName;
  }

  /// Third-party (LX script) source count for the playback section
  /// (Beans `customSourceCount`): bundled engine scripts + user-added
  /// custom scripts. Null while loading — the row shows "…" until
  /// then, never a guessed number.
  Future<void> _loadSourceCount() async {
    try {
      await LxScriptEngine.instance.ensureInitialized();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _sourceCount =
          LxScriptEngine.instance.scripts.length +
          LxScriptSourcesStore.customScripts().length;
    });
  }

  /// Subtitle appearance tiers, in cycle order (stored value -> label).
  static const _subFontSizeOrder = ['small', 'medium', 'large'];
  static const _subFontSizeLabels = {
    'small': '小',
    'medium': '标准',
    'large': '大',
  };
  static const _subColorOrder = ['white', 'yellow', 'cyan'];
  static const _subColorLabels = {
    'white': '白色',
    'yellow': '黄色',
    'cyan': '青色',
  };
  static const _subPositionOrder = ['bottom', 'middle', 'top'];
  static const _subPositionLabels = {
    'bottom': '底部',
    'middle': '中间',
    'top': '顶部',
  };

  /// Skip-intro modes, in cycle order (stored value -> label).
  static const _skipIntroOrder = ['off', 'manual', 'auto3s', 'autoNow'];
  static const _skipIntroLabels = {
    'off': '关',
    'manual': '手动',
    'auto3s': '自动延时 3 秒',
    'autoNow': '自动立即',
  };

  /// 1.1.6 trio display lock (super-res / interpolation /
  /// SDR→HDR): when one is on, the other two are greyed
  /// (Opacity 0.4 + IgnorePointer, the D5 pattern) — display
  /// only, the stored value is never touched; the gate layer
  /// runs only the first passing branch.
  Widget _mpvFxRow({required bool locked, required Widget child}) {
    if (!locked) return child;
    return Opacity(
      opacity: 0.4,
      child: IgnorePointer(ignoring: true, child: child),
    );
  }

  /// Subtitle delay display: 0 -> '0s', positive -> '+0.5s',
  /// negative -> '−1.0s' (U+2212 minus).
  String _formatSubtitleDelay(double v) {
    final rounded = double.parse(v.toStringAsFixed(1));
    if (rounded == 0) return '0s';
    final s = rounded.abs().toStringAsFixed(1);
    return rounded > 0 ? '+${s}s' : '−${s}s';
  }

  @override
  Widget build(BuildContext context) {
    // No themeController here (build 29 B组): the rows moved into
    // _appearanceRows/_videoRows, which re-derive theme + controller
    // themselves; build() only needs `theme` for the 设置 title.
    final theme = HaoTheme.of(context);
    return Obx(() => Scaffold(
      // No AppBar (chen 2026-11-21, screenshot): the title is a big
      // bold header at the top-left of the list, like his 我的片库
      // screenshot — not a small top-bar title. Apple Large Title:
      // 34 bold (build-29 typography, was 26 w800 — 26 is not an
      // Apple text style). The title carries the status-bar inset
      // itself (MediaQuery), so the page needs no AppBar and no
      // SafeArea.
      body: ListView(
        // Bottom padding 34, not 40 (build 29 B组): the last section
        // carries 6px breathing room inside its clip (see
        // HaoCollapsibleSection), so 34 + 6 keeps the total page height
        // — and every scroll offset — exactly as before.
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 34),
        children: [
          Padding(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 8,
              bottom: 12,
            ),
            child: Text(
              '设置',
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 34,
                fontWeight: FontWeight.w700,
                shadows: HaoTheme.legibilityShadows(context),
              ),
            ),
          ),
          HaoCollapsibleSection(
            title: '外观',
            expanded: _sectionExpanded['appearance'] ?? true,
            onToggle: () => _toggleSection('appearance'),
            children: _appearanceRows(context),
          ),
          const SizedBox(height: 14),
          HaoCollapsibleSection(
            title: '音乐播放',
            expanded: _sectionExpanded['music'] ?? true,
            onToggle: () => _toggleSection('music'),
            children: _musicRows(context),
          ),
          const SizedBox(height: 14),
          HaoCollapsibleSection(
            title: '影视播放',
            expanded: _sectionExpanded['video'] ?? true,
            onToggle: () => _toggleSection('video'),
            children: _videoRows(context),
          ),
          const SizedBox(height: 14),
          HaoCollapsibleSection(
            title: '源管理',
            expanded: _sectionExpanded['sources'] ?? true,
            onToggle: () => _toggleSection('sources'),
            children: _sourcesRows(context),
          ),
          const SizedBox(height: 14),
          HaoCollapsibleSection(
            title: '数据',
            expanded: _sectionExpanded['data'] ?? true,
            onToggle: () => _toggleSection('data'),
            children: _dataRows(context),
          ),
          const SizedBox(height: 14),
          HaoCollapsibleSection(
            title: '关于',
            expanded: _sectionExpanded['about'] ?? true,
            onToggle: () => _toggleSection('about'),
            children: _aboutRows(context),
          ),
        ],
      ),
    ));
  }

  /// Build 29 B组: “外观”组的行(原 build() 平铺内容, 一字未改;
  /// 组内 12px 间隔由 HaoCollapsibleSection 统一加).
  List<Widget> _appearanceRows(BuildContext context) {
    final theme = HaoTheme.of(context);
    final themeController = Get.find<ThemeController>();
    return [
      HaoInsetGroupedSection(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // G-设置 (build 29 Wave 2): iOS 原生分段选择
            // (CupertinoSlidingSegmentedControl) — the old
            // Material ChoiceChip row is gone. Same Hive key
            // (ThemeController.setTheme), same four themes; the
            // thumb is the accent wash, like HaoSegmentedControl
            // below (ThemeMode).
            Obx(
              () => CupertinoSlidingSegmentedControl<HaoThemeId>(
                groupValue: themeController.themeId.value,
                backgroundColor:
                    theme.textMuted.withValues(alpha: 0.18),
                thumbColor: theme.accentSoft,
                onValueChanged: (id) {
                  if (id == null) return;
                  HaoHaptics.select();
                  themeController.setTheme(id, box: HiveStore.box);
                },
                children: {
                  for (final id in HaoThemeId.values)
                    id: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 6,
                      ),
                      child: Text(
                        HaoThemes.names[id]!,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color:
                              themeController.themeId.value == id
                                  ? theme.accent
                                  : theme.textSecondary,
                          shadows:
                              HaoTheme.legibilityShadows(context),
                        ),
                      ),
                    ),
                },
              ),
            ),
            const SizedBox(height: 12),
            Obx(
              () => HaoSegmentedControl<ThemeMode>(
                segments: const [
                  HaoSegment(value: ThemeMode.light, label: '浅色'),
                  HaoSegment(value: ThemeMode.dark, label: '深色'),
                  HaoSegment(value: ThemeMode.system, label: '跟随系统'),
                ],
                value: themeController.themeMode.value,
                // No explicit HaoHaptics.select() here: the control
                // fires it on every segment tap (N-13).
                onChanged: (mode) =>
                    themeController.setMode(mode, box: HiveStore.box),
              ),
            ),
          ],
        ),
      ),
      _BeansSwitchRow(
        icon: Icons.wallpaper,
        title: '壁纸',
        value: _wallpaperOn,
        onChanged: (value) async {
          HaoHaptics.select();
          // G-P2-2: optimistic flip — the thumb moves on this
          // frame; the Hive write lands in the background. The
          // store swallows write errors (AppearanceStore catches
          // them), so a failed write surfaces as "the value
          // didn't stick": _loadAppearance() re-reads the
          // persisted value and flips the thumb back, and we
          // tell the user. The catch only covers errors thrown
          // outside the store.
          final previous = _wallpaperOn;
          setState(() => _wallpaperOn = value);
          try {
            await AppearanceController.ensure().setWallpaperEnabled(value);
            if (!mounted) return;
            setState(() => _loadAppearance());
            if (_wallpaperOn != value) {
              HaoToast.show('设置失败', message:  '壁纸开关保存失败，请重试');
            }
          } catch (_) {
            if (!mounted) return;
            setState(() => _wallpaperOn = previous);
            HaoToast.show('设置失败', message:  '壁纸开关保存失败，请重试');
          }
        },
      ),
      _BeansRow(
        icon: Icons.photo_library,
        title: '壁纸管理',
        onTap: () async {
          await Get.to(() => const WallpaperPage());
          setState(() => _loadAppearance());
        },
      ),
      // Tab-bar selected colour (icon + label): the ring shows
      // the current colour live; tapping opens the colour sheet.
      // The colour controls only the tab-bar selected state.
      _BeansRow(
        icon: Icons.colorize,
        title: '自定义强调色',
        trailing: const AccentRingButton(),
        onTap: () => showAccentColorSheet(context),
      ),
      _BeansSwitchRow(
        icon: Icons.format_paint,
        title: '背景色',
        value: _bgOn,
        onChanged: (value) async {
          HaoHaptics.select();
          // G-P2-2: optimistic flip, same as the wallpaper
          // switch above — thumb first, Hive write behind it;
          // a write that didn't stick (the store swallows the
          // error) flips the thumb back via _loadAppearance()
          // and gets a snackbar.
          final previous = _bgOn;
          setState(() => _bgOn = value);
          try {
            await AppearanceController.ensure().setBackgroundEnabled(value);
            if (!mounted) return;
            setState(() => _loadAppearance());
            if (_bgOn != value) {
              HaoToast.show('设置失败', message:  '背景色开关保存失败，请重试');
            }
          } catch (_) {
            if (!mounted) return;
            setState(() => _bgOn = previous);
            HaoToast.show('设置失败', message:  '背景色开关保存失败，请重试');
          }
        },
      ),
      // Background swatches stay mounted (build 28 D5): when the
      // background switch is off the card is greyed out and
      // untappable instead of disappearing, so toggling the
      // switch never jumps the layout height. Same treatment
      // while wallpaper is on — wallpaper beats the background
      // colour, shown by disabling, not by a sentence (clean
      // pass 2026-11-19).
      Opacity(
        opacity: (!_bgOn || _wallpaperOn) ? 0.4 : 1,
        child: IgnorePointer(
          ignoring: !_bgOn || _wallpaperOn,
          child: _BackgroundSwatches(
            selectedHex: _bgHex,
            onSelect: (hex) async {
              HaoHaptics.select();
              await AppearanceController.ensure().setBackgroundColor(hex);
              setState(() => _loadAppearance());
            },
            onReset: () async {
              HaoHaptics.select();
              await AppearanceController.ensure().clearBackgroundColor();
              setState(() => _loadAppearance());
            },
          ),
        ),
      ),
      // Liquid-glass intensity (chen 2026-11-21): whole-app
      // frosted-glass strength, 0% = clear, 100% = today's
      // glass. The slider previews live — the theme rebuilds
      // on every tick (ThemeController.glassIntensity); Hive is
      // written once when the drag ends, not per tick (G-P2-3).
      HaoInsetGroupedSection(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Icon(
                    Icons.blur_on,
                    size: 14,
                    color: theme.accent,
                    shadows: HaoTheme.legibilityShadows(context),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '液态玻璃强度',
                    style: TextStyle(
                      fontSize: 15,
                      shadows: HaoTheme.legibilityShadows(context),
                    ),
                  ),
                ),
                Text(
                  '${(themeController.glassIntensity.value * 100).round()}%',
                  style: TextStyle(
                    color: theme.textSecondary,
                    fontSize: 14,
                    shadows: HaoTheme.legibilityShadows(context),
                  ),
                ),
              ],
            ),
            // build-29 adoption: the real iOS UISlider via glassy
            // (GlassSlider) — same wiring as the CupertinoSlider
            // below it, which stays as the off-iOS fallback.
            // G-设置 (build 29 Wave 2): drag previews in memory,
            // Hive is written once on release; thumb stays iOS
            // white, track is the theme accent (N-12's 28pt iOS
            // thumb, kept). Full-width SizedBox: a CupertinoSlider
            // in a start-aligned Column sizes to its 176px
            // intrinsic width (the Material Slider stretched) — on
            // a phone that reads as a narrow stub, not a slider.
            SizedBox(
              width: double.infinity,
              child: glassy.GlassSlider(
                value: themeController.glassIntensity.value,
                style: glassy.NativeStyle(tintColor: theme.accent),
                // G-P2-3: dragging only previews in memory (the
                // theme rebuilds live per tick); Hive is written
                // once when the drag ends, so a drag no longer
                // pays a Hive put per tick.
                onChanged: (v) =>
                    themeController.setGlassIntensityPreview(v),
                onChangeEnd: (v) {
                  themeController.setGlassIntensity(
                    v,
                    box: HiveStore.box,
                  );
                  // N-13: light tap on release, click at either end.
                  HaoHaptics.sliderEnd(v, 0, 1);
                },
                fallback: CupertinoSlider(
                  value: themeController.glassIntensity.value,
                  activeColor: theme.accent,
                  onChanged: (v) =>
                      themeController.setGlassIntensityPreview(v),
                  onChangeEnd: (v) {
                    themeController.setGlassIntensity(
                      v,
                      box: HiveStore.box,
                    );
                    HaoHaptics.sliderEnd(v, 0, 1);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      _BeansRow(
        icon: Icons.font_download,
        title: '自定义字体',
        subtitle: _fontName.isEmpty ? '未安装' : '已安装：$_fontName',
        onTap: () => _importFont(context),
      ),
      if (_fontName.isNotEmpty) ...[
        _BeansRow(
          icon: Icons.restore,
          title: '恢复默认字体',
          onTap: () => _resetFont(context),
        ),
      ],
    ];
  }

  /// Build 29 B组: “音乐播放”组的行(原 build() 平铺内容, 一字未改;
  /// 组内 12px 间隔由 HaoCollapsibleSection 统一加).
  List<Widget> _musicRows(BuildContext context) {
    return [
      AnimatedBuilder(
        animation: EqualizerStore.ensure(),
        builder: (context, _) => _PlaybackPanel(
          mixWithOthers: _mixWithOthers,
          onMixChanged: (value) async {
            HaoHaptics.select();
            await HiveStore.put(HiveKeys.audioMixWithOthers, value);
            setState(() => _mixWithOthers = value);
            await AvMusicPlayer.applyMixWithOthers(value);
          },
          autoResume: _autoResume,
          onAutoResumeChanged: (value) async {
            HaoHaptics.select();
            await HiveStore.put(HiveKeys.autoResumeLastPlayback, value);
            setState(() => _autoResume = value);
          },
          quality: _quality,
          onQualityChanged: (q) async {
            HaoHaptics.select();
            await MusicStore.setQuality(q);
            _player.userQuality.value = q;
            setState(() => _quality = q);
          },
          hapticsOn: _hapticsOn,
          onHapticsChanged: (value) async {
            await HaoHaptics.setEnabled(value);
            setState(() => _hapticsOn = value);
            if (value) HaoHaptics.tap();
          },
          sourceCount: _sourceCount,
          equalizerEnabled: EqualizerStore.ensure().enabled,
          onOpenEqualizer: () async {
            HaoHaptics.tap();
            await Get.to(() => const EqualizerPage());
          },
        ),
      ),
      // 1.1.6: loudness normalisation (default off). The loudness
      // is measured by the EQ tap, so with EQ off there is
      // nothing to measure — the switch alone does nothing until
      // EQ is on. The toggle is pushed to the live controller
      // (it only reads Hive in onInit, so a Hive-only write
      // would not take effect until restart).
      _BeansSwitchRow(
        icon: Icons.volume_up,
        title: '音量归一化',
        subtitle: '需开启均衡器才能测量响度',
        value: _musicNormalizationEnabled,
        onChanged: (value) async {
          HaoHaptics.select();
          await HiveStore.put(HiveKeys.musicNormalizationEnabled, value);
          setState(() => _musicNormalizationEnabled = value);
          try {
            await _player.setNormalizationEnabled(value);
          } catch (_) {}
        },
      ),
    ];
  }

  /// Build 29 B组: “影视播放”组的行(原 build() 平铺内容, 一字未改;
  /// 组内 12px 间隔由 HaoCollapsibleSection 统一加).
  List<Widget> _videoRows(BuildContext context) {
    final theme = HaoTheme.of(context);
    return [
      // G-设置 (build 29 Wave 2): iOS 设置式单选 — plain rows
      // with a trailing checkmark (CupertinoIcons.checkmark) instead
      // of Material RadioListTile. Same Hive key (videoPlayerKey),
      // same tap-to-persist wiring.
      HaoInsetGroupedSection(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: PlayerEngine.values.map((engine) {
            final selected = _engineKey == engine.key;
            return HaoPressable(
              onTap: () async {
                if (selected) return;
                HaoHaptics.select();
                await HiveStore.put(HiveKeys.videoPlayerKey, engine.key);
                if (mounted) setState(() => _engineKey = engine.key);
              },
              borderRadius: BorderRadius.circular(HaoRadius.large),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 13,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            engine.displayName,
                            style: TextStyle(
                              color: theme.textPrimary,
                              fontSize: 15,
                              shadows:
                                  HaoTheme.legibilityShadows(context),
                            ),
                          ),
                          if (engine == PlayerEngine.exo) ...[
                            const SizedBox(height: 2),
                            Text(
                              'AVPlayer 不能播 FLV，失败时自动换内核',
                              style: TextStyle(
                                color: theme.textSecondary,
                                fontSize: 12,
                                shadows: HaoTheme.legibilityShadows(
                                    context),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (selected)
                      Icon(
                        CupertinoIcons.checkmark,
                        color: theme.accent,
                        size: 20,
                        shadows: HaoTheme.legibilityShadows(context),
                      ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ),
      _BeansSwitchRow(
        icon: Icons.skip_next,
        title: '自动连播下一集',
        value: _autoNext,
        onChanged: (value) async {
          HaoHaptics.select();
          await VideoPlaybackSettings.setAutoNext(value);
          setState(() => _autoNext = value);
        },
      ),
      // I-影视 item 1: double-tap seek step (VOD only — live has
      // no seek). Tap cycles 5 → 10 → 15 → 30 → 60 s; default 10 s.
      // The rate itself is already remembered (vodPlaybackRate);
      // this row only owns the step.
      _BeansRow(
        icon: Icons.touch_app,
        title: '双击快进秒数',
        subtitle: '当前：$_vodDoubleTapSeekSeconds 秒',
        onTap: () async {
          HaoHaptics.select();
          final next = nextDoubleTapSeekSeconds(_vodDoubleTapSeekSeconds);
          await HiveStore.put(HiveKeys.vodDoubleTapSeekSeconds, next);
          setState(() => _vodDoubleTapSeekSeconds = next);
        },
      ),
      // I-影视 item 3: dialogue boost — volume up to 300% +
      // centre-channel enhancement. Backend landed (K 组, build 29):
      // MpvBackend sets volume-max=300 + the centre fold-in
      // (stereo passes through unchanged — verified with ffmpeg;
      // coefficients 待真机验证).
      _BeansSwitchRow(
        icon: Icons.record_voice_over,
        title: '对白增强',
        subtitle: '音量最高 300%、中置声道 · 仅 MPV',
        value: _vodDialogueBoost,
        onChanged: (value) async {
          HaoHaptics.select();
          await HiveStore.put(HiveKeys.vodDialogueBoost, value);
          setState(() => _vodDialogueBoost = value);
        },
      ),
      // I-影视 item 5: spoiler protection on the detail page.
      // Both default off — the synopsis/poster stay visible until
      // the user opts in.
      _BeansSwitchRow(
        icon: Icons.visibility_off,
        title: '防剧透：隐藏简介',
        subtitle: '详情页简介默认隐藏，点按查看',
        value: _vodSpoilerHideSynopsis,
        onChanged: (value) async {
          HaoHaptics.select();
          await HiveStore.put(HiveKeys.vodSpoilerHideSynopsis, value);
          setState(() => _vodSpoilerHideSynopsis = value);
        },
      ),
      _BeansSwitchRow(
        icon: Icons.blur_on,
        title: '防剧透：模糊未看海报',
        subtitle: '未看过的影片海报模糊显示，点按查看',
        value: _vodSpoilerBlurUnwatched,
        onChanged: (value) async {
          HaoHaptics.select();
          await HiveStore.put(HiveKeys.vodSpoilerBlurUnwatched, value);
          setState(() => _vodSpoilerBlurUnwatched = value);
        },
      ),
      // I-影视 item 9: pure-audio default (same key the player
      // toggle writes — one key, two writers, no second state).
      _BeansSwitchRow(
        icon: Icons.headphones,
        title: '纯音频后台播放',
        subtitle: '只听声音，后台继续播',
        value: _vodAudioOnly,
        onChanged: (value) async {
          HaoHaptics.select();
          await HiveStore.put(HiveKeys.vodAudioOnly, value);
          setState(() => _vodAudioOnly = value);
        },
      ),
      // I-影视 item 10: category show/hide/reorder editor.
      _BeansRow(
        icon: Icons.sort,
        title: '影视分类排序',
        subtitle: '显示 / 隐藏 / 拖动排序',
        onTap: () => Get.to(() => const VideoCategoriesPage()),
      ),
      // VOD picture fit (PiliPlus VideoFitType + Kazumi
      // PlayerAspectRatio): tap cycles 自动 -> 拉伸 -> 裁剪.
      // VOD only — live always renders contain.
      _BeansRow(
        icon: Icons.aspect_ratio,
        title: '视频画面比例',
        subtitle: '当前：${_videoFit.label}',
        onTap: () async {
          HaoHaptics.select();
          final next = _videoFit.next;
          await VideoPlaybackSettings.setVideoFit(next);
          setState(() => _videoFit = next);
        },
      ),
      // Anime4K super-resolution (build 28 J): VOD only — the
      // switch gates the VOD path; live playback never reads it.
      // Effective only on the MPV engine, from the next open
      // (next episode / line or engine switch re-opens the
      // player); toggling mid-playback does nothing until then.
      // 1.1.6 trio: mutually exclusive with interpolation and
      // SDR→HDR in display only (see _mpvFxRow) — the stored
      // value of a greyed-out row is never cleared.
      _mpvFxRow(
        locked: _vodInterpolation || _vodSdrToHdr,
        child: _BeansSwitchRow(
          icon: Icons.auto_awesome,
          title: 'Anime4K 超分',
          subtitle: '仅 MPV，下次播放生效',
          value: _vodSuperResolution,
          onChanged: (value) async {
            HaoHaptics.select();
            await HiveStore.put(HiveKeys.vodSuperResolution, value);
            setState(() => _vodSuperResolution = value);
          },
        ),
      ),
      // 1.1.6: VOD frame interpolation (MPV only, next open).
      _mpvFxRow(
        locked: _vodSuperResolution || _vodSdrToHdr,
        child: _BeansSwitchRow(
          icon: Icons.animation,
          title: '插帧',
          subtitle: '仅 MPV，下次播放生效',
          value: _vodInterpolation,
          onChanged: (value) async {
            HaoHaptics.select();
            await HiveStore.put(HiveKeys.vodInterpolation, value);
            setState(() => _vodInterpolation = value);
          },
        ),
      ),
      // 1.1.6: VOD SDR→HDR (MPV only, next open).
      _mpvFxRow(
        locked: _vodSuperResolution || _vodInterpolation,
        child: _BeansSwitchRow(
          icon: Icons.hdr_on,
          title: 'SDR 转 HDR',
          subtitle: '仅 MPV，下次播放生效',
          value: _vodSdrToHdr,
          onChanged: (value) async {
            HaoHaptics.select();
            await HiveStore.put(HiveKeys.vodSdrToHdr, value);
            setState(() => _vodSdrToHdr = value);
          },
        ),
      ),
      // 1.1.6: DV Profile 8 downgrade-to-HDR. Default ON —
      // unlike the trio above. Not part of the exclusion.
      _BeansSwitchRow(
        icon: Icons.high_quality,
        title: '杜比视界 Profile 8 降级 HDR',
        value: _vodDvP8Downgrade,
        onChanged: (value) async {
          HaoHaptics.select();
          await HiveStore.put(HiveKeys.vodDvP8Downgrade, value);
          setState(() => _vodDvP8Downgrade = value);
        },
      ),
      // 1.1.6: skip intro/outro — tap cycles 关 -> 手动 ->
      // 自动延时 3 秒 -> 自动立即 (same cycle-row pattern as
      // 视频画面比例 / 低内存模式 above).
      _BeansRow(
        icon: Icons.fast_forward,
        title: '跳过片头片尾',
        subtitle: '当前：${_skipIntroLabels[_vodSkipIntroMode] ?? '关'}',
        onTap: () async {
          HaoHaptics.select();
          final i = _skipIntroOrder.indexOf(_vodSkipIntroMode);
          final next =
              _skipIntroOrder[(i < 0 ? 0 : i + 1) % _skipIntroOrder.length];
          await HiveStore.put(HiveKeys.vodSkipIntroMode, next);
          setState(() => _vodSkipIntroMode = next);
        },
      ),
      // 1.1.6: VOD subtitle time offset (±10s, 0.1s step).
      // Same card shape as the 液态玻璃强度 slider above:
      // drag previews in memory, Hive is written on release.
      HaoInsetGroupedSection(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Icon(
                    Icons.subtitles,
                    size: 14,
                    color: theme.accent,
                    shadows: HaoTheme.legibilityShadows(context),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '字幕时间偏移',
                    style: TextStyle(
                      fontSize: 15,
                      shadows: HaoTheme.legibilityShadows(context),
                    ),
                  ),
                ),
                Text(
                  _formatSubtitleDelay(_vodSubtitleDelay),
                  style: TextStyle(
                    color: theme.textSecondary,
                    fontSize: 14,
                    shadows: HaoTheme.legibilityShadows(context),
                  ),
                ),
              ],
            ),
            // build-29 adoption: the real iOS UISlider via glassy
            // (GlassSlider) — same wiring as the CupertinoSlider
            // below it, which stays as the off-iOS fallback.
            // G-设置 (build 29 Wave 2): drag previews in memory
            // (0.1s steps), Hive is written once on release.
            // Full-width SizedBox: see the glass slider above — a
            // bare CupertinoSlider in this Column is 176px wide.
            SizedBox(
              width: double.infinity,
              child: glassy.GlassSlider(
                value: _vodSubtitleDelay.clamp(-10.0, 10.0),
                min: -10,
                max: 10,
                divisions: 200,
                style: glassy.NativeStyle(tintColor: theme.accent),
                onChanged: (v) => setState(
                  () => _vodSubtitleDelay =
                      double.parse(v.toStringAsFixed(1)),
                ),
                onChangeEnd: (v) async {
                  final rounded = double.parse(v.toStringAsFixed(1));
                  await HiveStore.put(HiveKeys.vodSubtitleDelay, rounded);
                  if (mounted) {
                    setState(() => _vodSubtitleDelay = rounded);
                  }
                  // N-13: light tap on release, click at either end.
                  HaoHaptics.sliderEnd(v, -10, 10);
                },
                fallback: CupertinoSlider(
                  value: _vodSubtitleDelay.clamp(-10.0, 10.0),
                  min: -10,
                  max: 10,
                  divisions: 200,
                  activeColor: theme.accent,
                  onChanged: (v) => setState(
                    () => _vodSubtitleDelay =
                        double.parse(v.toStringAsFixed(1)),
                  ),
                  onChangeEnd: (v) async {
                    final rounded = double.parse(v.toStringAsFixed(1));
                    await HiveStore.put(HiveKeys.vodSubtitleDelay, rounded);
                    if (mounted) {
                      setState(() => _vodSubtitleDelay = rounded);
                    }
                    HaoHaptics.sliderEnd(v, -10, 10);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      // 1.1.6: VOD subtitle appearance (MPV only, three tiers
      // each). Tap cycles to the next tier; applies at the next
      // open, same as the subtitle delay row above (the player
      // reads the persisted tiers once at open).
      _BeansRow(
        icon: Icons.format_size,
        title: '字幕字号',
        subtitle:
            '当前：${_subFontSizeLabels[_vodSubtitleFontSize] ?? '标准'}',
        onTap: () async {
          HaoHaptics.select();
          final i = _subFontSizeOrder.indexOf(_vodSubtitleFontSize);
          final next = _subFontSizeOrder[
              (i < 0 ? 0 : i + 1) % _subFontSizeOrder.length];
          await HiveStore.put(HiveKeys.vodSubtitleFontSize, next);
          if (mounted) setState(() => _vodSubtitleFontSize = next);
          HaoToast.show('提示', message: '下次打开生效');
        },
      ),
      _BeansRow(
        icon: Icons.palette_outlined,
        title: '字幕颜色',
        subtitle: '当前：${_subColorLabels[_vodSubtitleColor] ?? '白色'}',
        onTap: () async {
          HaoHaptics.select();
          final i = _subColorOrder.indexOf(_vodSubtitleColor);
          final next =
              _subColorOrder[(i < 0 ? 0 : i + 1) % _subColorOrder.length];
          await HiveStore.put(HiveKeys.vodSubtitleColor, next);
          if (mounted) setState(() => _vodSubtitleColor = next);
          HaoToast.show('提示', message: '下次打开生效');
        },
      ),
      _BeansRow(
        icon: Icons.vertical_align_center,
        title: '字幕位置',
        subtitle:
            '当前：${_subPositionLabels[_vodSubtitlePosition] ?? '底部'}',
        onTap: () async {
          HaoHaptics.select();
          final i = _subPositionOrder.indexOf(_vodSubtitlePosition);
          final next = _subPositionOrder[
              (i < 0 ? 0 : i + 1) % _subPositionOrder.length];
          await HiveStore.put(HiveKeys.vodSubtitlePosition, next);
          if (mounted) setState(() => _vodSubtitlePosition = next);
          HaoToast.show('提示', message: '下次打开生效');
        },
      ),
      // Low-memory mode (Kazumi): tap cycles 自动 -> 始终开启 ->
      // 始终关闭. Applies at the next open (mpv properties are set
      // in open()); the subtitle states the effective state now,
      // and the toast below says so once, at the moment the user
      // changes it (build 28 D9 — no permanent hint row).
      _BeansRow(
        icon: Icons.data_saver_on,
        title: '低内存模式',
        subtitle: _lowMemoryMode.statusDescription(),
        onTap: () async {
          HaoHaptics.select();
          final next = _lowMemoryMode.next;
          await LowMemoryMode.save(next);
          setState(() => _lowMemoryMode = next);
          HaoToast.show('提示', message:  '下次打开生效');
        },
      ),
      _BeansRow(
        icon: Icons.chat_bubble_outline,
        title: '弹幕设置',
        onTap: () => Get.to(() => const DanmakuSettingsPage()),
      ),
    ];
  }

  /// Build 29 B组: “源管理”组的行(原 build() 平铺内容, 一字未改;
  /// 组内 12px 间隔由 HaoCollapsibleSection 统一加).
  List<Widget> _sourcesRows(BuildContext context) {
    return [
      _BeansRow(
        icon: Icons.music_note,
        title: '音源管理',
        onTap: () => Get.to(() => const MusicSourcesPage()),
      ),
      _BeansRow(
        icon: Icons.movie,
        title: '影视源管理',
        onTap: () => Get.to(() => const VideoSourcesPage()),
      ),
      _BeansRow(
        icon: Icons.live_tv,
        title: '直播源管理',
        onTap: () => Get.to(() => const LiveSourcesPage()),
      ),
    ];
  }

  /// Build 29 B组: “数据”组的行(原 build() 平铺内容, 一字未改;
  /// 组内 12px 间隔由 HaoCollapsibleSection 统一加).
  List<Widget> _dataRows(BuildContext context) {
    return [
      _BeansRow(
        icon: Icons.upload,
        title: '导出备份',
        onTap: () => _exportBackup(context),
      ),
      _BeansRow(
        icon: Icons.download,
        title: '导入备份',
        onTap: () => _importBackup(context),
      ),
      _BeansRow(
        icon: Icons.cleaning_services,
        title: '缓存管理',
        onTap: () => Get.to(() => const CacheSettingsPage()),
      ),
      _BeansRow(
        icon: Icons.article_outlined,
        title: '日志',
        onTap: () => Get.to(() => const AppLogPage()),
      ),
    ];
  }

  /// Build 29 B组: “关于”组的行(原 build() 平铺内容, 一字未改;
  /// 组内 12px 间隔由 HaoCollapsibleSection 统一加).
  List<Widget> _aboutRows(BuildContext context) {
    return [
      _BeansRow(
        icon: Icons.info_outline,
        title: '版本',
        subtitle: '$kAppVersion (build $kAppBuild)',
        onTap: () => Get.to(() => const ChangelogPage()),
      ),
      _BeansRow(
        icon: Icons.system_update,
        title: '检查更新',
        onTap: () => _checkUpdate(context),
      ),
      // Build 28: gates only the automatic check at startup;
      // the manual 检查更新 row above is never gated.
      _BeansSwitchRow(
        icon: Icons.autorenew,
        title: '启动时自动检查更新',
        value: _autoUpdateCheck,
        onChanged: (value) async {
          HaoHaptics.select();
          await HiveStore.put(HiveKeys.autoUpdateCheck, value);
          setState(() => _autoUpdateCheck = value);
        },
      ),
    ];
  }

  /// Import a custom font (stage 2 item 7, Beans `FontManager`):
  /// pick a ttf/otf/ttc file, install it (copied to app documents +
  /// registered with FontLoader), apply it immediately via the theme
  /// controller. A failed install leaves the current font untouched.
  Future<void> _importFont(BuildContext context) async {
    try {
      final picked = await FilePicker.pickFiles(
        dialogTitle: '选择字体文件',
        type: FileType.custom,
        allowedExtensions: CustomFontService.kFontExtensions.toList(),
      );
      if (picked.isEmpty) return; // user cancelled
      final path = picked.first.path;
      if (path == null) return;
      final installed = await CustomFontService().install(File(path));
      if (!context.mounted) return;
      if (installed == null) {
        HaoToast.show('导入失败', message:  '只支持 ttf / otf / ttc 字体文件');
        return;
      }
      Get.find<ThemeController>().setCustomFontFamily(
        installed,
        box: HiveStore.box,
      );
      setState(() => _loadAppearance());
      HaoToast.show('已安装字体', message:  _fontName);
    } catch (_) {
      if (!context.mounted) return;
      HaoToast.show('导入失败', message:  '读取字体文件失败，请重试');
    }
  }

  /// Restore the system default font (delete the installed font +
  /// clear the family). Works even when no font is installed (then
  /// it is a no-op with a "已是系统默认字体" note, not a dead row).
  Future<void> _resetFont(BuildContext context) async {
    await CustomFontService().clear();
    Get.find<ThemeController>().setCustomFontFamily('', box: HiveStore.box);
    setState(() => _loadAppearance());
    if (!context.mounted) return;
    HaoToast.show('已恢复', message:  '已恢复系统默认字体');
  }

  Future<void> _checkUpdate(BuildContext context) async {
    final (result, info) = await _updateService.checkManual();
    if (!context.mounted) return;
    switch (result) {
      case UpdateCheckResult.newerAvailable:
        AppLog.info(
          '发现新版本 v${info!.version} (build ${info.build})',
        );
        await showUpdateDialog(context, info, service: _updateService);
      case UpdateCheckResult.skipped:
        AppLog.debug('更新检查：已跳过该版本');
        HaoToast.show('提示', message:  '已跳过该版本');
      case UpdateCheckResult.upToDate:
        AppLog.debug('更新检查：已是最新版本');
        HaoToast.show('提示', message:  '已是最新版本');
      case UpdateCheckResult.unavailable:
        AppLog.warn('更新检查失败');
        HaoToast.show('提示', message:  _updateFailureMessage());
    }
  }

  /// Error message for a failed manual update check, by failure kind.
  /// Timeout → retry hint; HTTP → status code; bad manifest → data error;
  /// network/other → the generic network hint.
  String _updateFailureMessage() {
    switch (_updateService.lastFetchError) {
      case UpdateFetchError.timeout:
        return '连接超时，请重试';
      case UpdateFetchError.http:
        final status = _updateService.lastHttpStatus;
        return status != null ? '服务器返回错误（HTTP $status），请稍后重试' : '服务器返回错误，请稍后重试';
      case UpdateFetchError.parse:
        return '版本信息异常';
      case UpdateFetchError.network:
      case null:
        return '检查失败，请检查网络后重试';
    }
  }

  /// Export: write the whole backup (Hive JSON + downloaded music,
  /// local music, wallpapers, fonts — P1-L3 zip) to a temp file and
  /// open the system share sheet (share_plus) so the user can save
  /// it to Files, send it, or AirDrop it. No cloud, no fixed
  /// directory.
  Future<void> _exportBackup(BuildContext context) async {
    try {
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final file = File('${dir.path}/hao-backup-$stamp.zip');
      final docs = Directory(await LocalPaths.ensureDocumentsPath());
      final zip = await BackupService(
        box: HiveStore.box,
      ).exportZip(documentsDir: docs);
      await file.writeAsBytes(zip);
      if (!context.mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: 'HAo Studio 备份',
          text: 'HAo Studio 备份（全部本地数据，含音乐/壁纸文件）',
        ),
      );
    } catch (_) {
      if (!context.mounted) return;
      HaoToast.show('导出失败', message:  '备份文件写入失败，请重试');
    }
  }

  /// Import: pick a *.zip (new) or *.json (legacy) backup with the
  /// system file picker, then restore it. Validation happens inside
  /// BackupService before any write, so an invalid file changes
  /// nothing.
  Future<void> _importBackup(BuildContext context) async {
    try {
      final picked = await FilePicker.pickFiles(
        dialogTitle: '选择备份文件',
        type: FileType.custom,
        allowedExtensions: ['zip', 'json'],
      );
      if (picked.isEmpty) return; // user cancelled
      final file = picked.first;
      final isZip = (file.name.toLowerCase().endsWith('.zip')) ||
          (file.path != null &&
              file.path!.toLowerCase().endsWith('.zip'));
      final docs = Directory(await LocalPaths.ensureDocumentsPath());
      final service = BackupService(box: HiveStore.box);
      final BackupImportResult result;
      final int count;
      var files = 0;
      if (isZip) {
        final List<int> bytes;
        if (file.path != null) {
          bytes = await File(file.path!).readAsBytes();
        } else {
          bytes = await file.xFile.readAsBytes();
        }
        final r = await service.importZip(bytes, documentsDir: docs);
        result = r.$1;
        count = r.$2;
        files = r.$3;
      } else {
        final String json;
        if (file.path != null) {
          json = await File(file.path!).readAsString();
        } else {
          json = await file.xFile.readAsString();
        }
        final r = await service.importJson(json);
        result = r.$1;
        count = r.$2;
      }
      if (!context.mounted) return;
      switch (result) {
        case BackupImportResult.ok:
          HaoToast.show('恢复成功', message: 
            files > 0 ? '已恢复 $count 项数据，$files 个文件' : '已恢复 $count 项数据',
          );
          // The import rewrote the whole box — every piece of state
          // this page caches from Hive is stale, not just the engine
          // key: reload the theme (its Obx rows follow the Rx values)
          // and re-read the local toggles.
          Get.find<ThemeController>().loadFromBox(HiveStore.box);
          setState(() {
            _sectionExpanded = {
              for (final id in _sectionIds)
                id: HiveStore.getBool(_sectionExpandedKey(id), true),
            };
            _engineKey = HiveStore.getString(HiveKeys.videoPlayerKey, 'mpv');
            _autoNext = VideoPlaybackSettings.autoNext;
            _mixWithOthers =
                HiveStore.getBool(HiveKeys.audioMixWithOthers, false);
            _autoResume =
                HiveStore.getBool(HiveKeys.autoResumeLastPlayback, false);
            _hapticsOn = HaoHaptics.enabled;
            _quality = MusicStore.quality;
          });
        case BackupImportResult.invalidJson:
          HaoToast.show('恢复失败', message:  '文件不是有效的备份文件');
        case BackupImportResult.wrongSchema:
          HaoToast.show('恢复失败', message:  '备份版本不受支持');
        case BackupImportResult.emptyData:
          HaoToast.show('恢复失败', message:  '备份文件没有数据');
        case BackupImportResult.writeFailed:
          HaoToast.show('恢复失败', message:  '导入中断，已恢复原数据');
      }
    } catch (_) {
      if (!context.mounted) return;
      HaoToast.show('恢复失败', message:  '读取备份文件失败，请重试');
    }
  }
}

/// Background-colour swatches (stage 2 item 6): preset colours + a
/// 恢复默认 button. Presets are neutrals and theme-tinted pastels
/// only — no blue, no purple, no saturated red (standing rules).
/// Selecting a swatch stores the colour AND turns the background
/// switch on (AppearanceStore.setBackgroundColor); 恢复默认 clears
/// the colour and turns the switch off.
class _BackgroundSwatches extends StatelessWidget {
  const _BackgroundSwatches({
    required this.selectedHex,
    required this.onSelect,
    required this.onReset,
  });

  final String selectedHex;
  final ValueChanged<String> onSelect;
  final VoidCallback onReset;

  static const List<String> presets = [
    '#FFFFFF',
    '#F2F2F7',
    '#000000',
    '#1C1C1E',
    '#FAF6EC',
    '#EFFAF6',
    '#0D0B08',
    '#07110F',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GlassPressScale(
      pressedScale: 0.98,
      child: GlassCard(
        radius: 18,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Spacer(),
                TextButton(
                  onPressed: onReset,
                  child: Text(
                    '恢复默认',
                    style: TextStyle(
                      shadows: HaoTheme.legibilityShadows(context),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: presets.map((hex) {
                final color = AppearanceStore.parseHex(hex)!;
                final selected =
                    selectedHex.toUpperCase() == hex.toUpperCase();
                return GestureDetector(
                  onTap: () => onSelect(hex),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: color,
                      border: Border.all(
                        color: selected ? theme.accent : theme.hairline,
                        width: selected ? 2 : 1,
                      ),
                    ),
                    child: selected
                        ? Icon(
                            Icons.check,
                            size: 16,
                            color: hex == '#FFFFFF' || hex == '#F2F2F7'
                                ? Colors.black
                                : Colors.white,
                            shadows: HaoTheme.legibilityShadows(context),
                          )
                        : null,
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Collapsible groups + big group titles live in
/// widgets/settings_ui.dart ([HaoCollapsibleSection] /
/// [HaoGroupTitle]) — shared with the Emby connect page.
/// One Beans settings row: its own glass card, radius 18, padding
/// h14 v13; icon 14 in a 28-wide frame (accent), title 15, subtitle
/// 11, trailing chevron (or a custom trailing widget). Tap opens a
/// sub-page (>) or runs an action; rows without onTap are display rows.
/// (Chevron glyph 16pt, not Beans' 11pt — a Material chevron at 11pt
/// is unreadable; see the file header.)
class _BeansRow extends StatelessWidget {
  const _BeansRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GlassPressScale(
      pressedScale: 0.98,
      child: GlassCard(
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Material(
          color: Colors.transparent,
          child: HaoPressable(
            onTap: onTap == null
                ? null
                : () {
                    HaoHaptics.tap();
                    onTap!();
                  },
            borderRadius: BorderRadius.circular(HaoRadius.panel),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Icon(
                    icon,
                    size: 14,
                    color: theme.accent,
                    shadows: HaoTheme.legibilityShadows(context),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: theme.textPrimary,
                          fontSize: 15,
                          shadows: HaoTheme.legibilityShadows(context),
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: TextStyle(
                            color: theme.textSecondary,
                            fontSize: 11,
                            shadows: HaoTheme.legibilityShadows(context),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                trailing ??
                    (onTap == null
                        ? const SizedBox.shrink()
                        : Icon(
                            Icons.chevron_right,
                            size: 16,
                            color: theme.textMuted.withValues(alpha: 0.6),
                            shadows: HaoTheme.legibilityShadows(context),
                          )),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A Beans settings switch row: same card as [_BeansRow] with a
/// [HaoNativeSwitch] trailing (Beans `.toggleStyle(.switch).tint(accent)`
/// — the real iOS UISwitch, build 29 E group; the old library
/// GlassSwitch is gone, so there is exactly one switch component
/// app-wide and its thumb can never again be the track colour).
class _BeansSwitchRow extends StatelessWidget {
  const _BeansSwitchRow({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return _BeansRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: HaoNativeSwitch(
        value: value,
        onChanged: onChanged,
        activeColor: HaoTheme.of(context).accent,
        semanticsLabel: title,
      ),
    );
  }
}

/// The expanded playback panel (Beans `playbackSection` expanded body,
/// ProfileView.swift: glass radius 22, padding 16, rows spaced 14,
/// dividers muted 0.15). Rows, in Beans' order:
/// 与其他音频同时播放 / 启动时自动播放上次歌曲 /
/// 播放音质 (chips) / 触感反馈 / 均衡器 (Beans `equalizerSection`,
/// ProfileView.swift:2255: row + 已开启/已关闭 trailing, opens the
/// 10-band page) / 第三方音源 (count display only — management lives
/// in 源管理 → 音源管理， the single entry; no second button here).
/// No VIP-notice row (chen: 不提醒) and a single quality row (chen:
/// 全是第三方源，只留一个音质设置).
class _PlaybackPanel extends StatelessWidget {
  const _PlaybackPanel({
    required this.mixWithOthers,
    required this.onMixChanged,
    required this.autoResume,
    required this.onAutoResumeChanged,
    required this.quality,
    required this.onQualityChanged,
    required this.hapticsOn,
    required this.onHapticsChanged,
    required this.sourceCount,
    required this.equalizerEnabled,
    required this.onOpenEqualizer,
  });

  final bool mixWithOthers;
  final ValueChanged<bool> onMixChanged;
  final bool autoResume;
  final ValueChanged<bool> onAutoResumeChanged;
  final AudioQuality quality;
  final ValueChanged<AudioQuality> onQualityChanged;
  final bool hapticsOn;
  final ValueChanged<bool> onHapticsChanged;
  final int? sourceCount;
  final bool equalizerEnabled;
  final VoidCallback onOpenEqualizer;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GlassCard(
      radius: 22,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PanelSwitch(
            icon: Icons.speaker,
            title: '与其他音频同时播放',
            value: mixWithOthers,
            onChanged: onMixChanged,
          ),
          const _PanelDivider(),
          _PanelSwitch(
            icon: Icons.play_circle_outline,
            title: '启动时自动播放上次歌曲',
            value: autoResume,
            onChanged: onAutoResumeChanged,
          ),
          const _PanelDivider(),
          _QualityChips(
            title: '播放音质',
            selected: quality,
            onSelected: onQualityChanged,
          ),
          const _PanelDivider(),
          _PanelSwitch(
            icon: Icons.vibration,
            title: '触感反馈',
            value: hapticsOn,
            onChanged: onHapticsChanged,
          ),
          const _PanelDivider(),
          // Equalizer (stage 3): Beans `equalizerSection` row — icon
          // slider.horizontal.3, title + subtitle, trailing real
          // state (已开启/已关闭) + chevron; tap opens the 10-band
          // page. The state comes from EqualizerStore (AnimatedBuilder
          // above), so it follows the page's toggle live.
          // Hidden on Android only (1.1.6): the equalizer is the
          // vendored just_audio fork + MTAudioProcessingTap, iOS-only
          // — Android has no equalizer engine, so the row (and its
          // divider) is hidden there instead of opening a dead page.
          // `!isAndroid` (not `isIOS`) keeps the Linux test env green.
          if (!Platform.isAndroid) ...[
              Material(
                color: Colors.transparent,
                child: HaoPressable(
                  onTap: onOpenEqualizer,
                  borderRadius: BorderRadius.circular(HaoRadius.large),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 28,
                        child: Icon(
                          Icons.tune,
                          size: 14,
                          color: theme.accent,
                          shadows: HaoTheme.legibilityShadows(context),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '均衡器',
                              style: TextStyle(
                                fontSize: 15,
                                shadows: HaoTheme.legibilityShadows(context),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        equalizerEnabled ? '已开启' : '已关闭',
                        style: TextStyle(
                          color: equalizerEnabled
                              ? theme.accent
                              : theme.textSecondary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          shadows: HaoTheme.legibilityShadows(context),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: theme.textMuted.withValues(alpha: 0.6),
                        shadows: HaoTheme.legibilityShadows(context),
                      ),
                    ],
                  ),
                ),
              ),
              const _PanelDivider(),
          ],
          Row(
            children: [
              SizedBox(
                width: 28,
                child: Icon(
                  Icons.inventory_2,
                  size: 14,
                  color: theme.accent,
                  shadows: HaoTheme.legibilityShadows(context),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '第三方音源',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    shadows: HaoTheme.legibilityShadows(context),
                  ),
                ),
              ),
              Text(
                sourceCount == null ? '…' : '$sourceCount 个',
                style: TextStyle(
                  color: theme.textSecondary,
                  fontSize: 13,
                  shadows: HaoTheme.legibilityShadows(context),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PanelDivider extends StatelessWidget {
  const _PanelDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Divider(
        height: 1,
        color: HaoTheme.of(context).textSecondary.withValues(alpha: 0.15),
      ),
    );
  }
}

class _PanelSwitch extends StatelessWidget {
  const _PanelSwitch({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 28,
          child: Icon(
            icon,
            size: 14,
            color: theme.accent,
            shadows: HaoTheme.legibilityShadows(context),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 15,
              shadows: HaoTheme.legibilityShadows(context),
            ),
          ),
        ),
        HaoNativeSwitch(
          value: value,
          onChanged: onChanged,
          activeColor: theme.accent,
          semanticsLabel: title,
        ),
      ],
    );
  }
}

/// Beans quality chips (ProfileView.swift `playbackQualitySection` and
/// the third-party quality chips): title 14 semibold, chips
/// height 31, h padding 12, font 12, spacing 8; selected fill accent
/// 0.14 + stroke accent 0.42 (0.8pt) + checkmark 9 bold; unselected
/// fill label 0.055 + stroke label 0.08. Single row (chen: one quality
/// setting for all sources).
class _QualityChips extends StatelessWidget {
  const _QualityChips({
    required this.title,
    required this.selected,
    required this.onSelected,
  });

  final String title;
  final AudioQuality selected;
  final ValueChanged<AudioQuality> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 22,
              child: Icon(
                Icons.graphic_eq,
                size: 13,
                color: theme.accent,
                shadows: HaoTheme.legibilityShadows(context),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      shadows: HaoTheme.legibilityShadows(context),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final q in AudioQuality.values) ...[
                _QualityChip(
                  quality: q,
                  selected: q == selected,
                  onTap: () => onSelected(q),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _QualityChip extends StatelessWidget {
  const _QualityChip({
    required this.quality,
    required this.selected,
    required this.onTap,
  });

  final AudioQuality quality;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GlassPressScale(
      pressedScale: 0.97,
      child: Material(
        color: Colors.transparent,
        child: HaoPressable(
          onTap: () {
            HaoHaptics.select();
            onTap();
          },
          borderRadius: BorderRadius.circular(999),
          child: Container(
            height: 31,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: selected
                  ? theme.accent.withValues(alpha: 0.14)
                  : theme.textPrimary.withValues(alpha: 0.055),
              border: Border.all(
                color: selected
                    ? theme.accent.withValues(alpha: 0.42)
                    : theme.textPrimary.withValues(alpha: 0.08),
                width: 0.8,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  quality.label,
                  style: TextStyle(
                    color: selected ? theme.accent : theme.textPrimary,
                    fontSize: 13,
                    fontWeight: selected
                        ? FontWeight.w600
                        : FontWeight.w500,
                    shadows: HaoTheme.legibilityShadows(context),
                  ),
                ),
                if (selected) ...[
                  const SizedBox(width: 5),
                  Icon(
                    Icons.check,
                    size: 9,
                    color: theme.accent,
                    shadows: HaoTheme.legibilityShadows(context),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
