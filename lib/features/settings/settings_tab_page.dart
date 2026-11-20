// Settings tab — Beans-style restyle (stage 1, task 5).
//
// Structure follows Beans `SettingsView` (ProfileView.swift:1129+):
// - centred title "设置" (AppBar, centerTitle from the theme)
// - big section titles (Beans `SectionHeader`: 21 bold)
// - every row its own glass card (Beans `GlassCard` radius 18,
//   row padding h14 v13; icon 14 in a 28-wide frame, title 15,
//   subtitle 11, chevron 11 semibold)
// - expandable sections (Beans `playbackSection`): a header card with
//   a ⌄/⌃ chevron, expanding into a glass panel (radius 22,
//   padding 16, rows spaced 14, dividers muted 0.15)
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
// - The 120Hz row is display-only with a checkmark, exactly like
//   Beans (ProfileView.swift: the row has no toggle and onAppear
//   forces the keeper on). Ours is pinned in Info.plist + AppDelegate,
//   so there is nothing to toggle at runtime — a switch here would
//   be a fake switch.
//
// NOTHING is deleted: theme, engine picker, backup export/import,
// source management (music/video/live), auto-next, danmaku, cache,
// version, update check and crash record are all still here — only
// the shell and structure changed. Every borrowed setting is wired
// to real behaviour (see the playback section).

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    hide GlassCard, GlassShadow;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/consts.dart';
import '../../core/logging/app_log.dart';
import '../../core/player/kernel/mpv_properties.dart';
import '../../core/player/kernel/player_engine.dart';
import '../../core/player/kernel/video_fit.dart';
import '../../core/storage/hive_store.dart';
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
import '../../widgets/settings_ui.dart';
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
import 'video_sources_page.dart';
import 'wallpaper_page.dart';

class SettingsTabPage extends StatefulWidget {
  const SettingsTabPage({super.key});

  @override
  State<SettingsTabPage> createState() => _SettingsTabPageState();
}

/// Stutter fix (chen 2026-11-20): keep-alive, see LiveTabPage.
/// Safe here: a static settings list, no timers, streams or polling.
class _SettingsTabPageState extends State<SettingsTabPage>
    with AutomaticKeepAliveClientMixin {
  late String _engineKey;

  @override
  bool get wantKeepAlive => true;
  late bool _engineExpanded;
  late bool _playbackExpanded;
  late bool _autoNext;
  // Good-projects P1 (PiliPlus/Kazumi): VOD picture fit + low-memory
  // mode. Cached like _autoNext; refreshed after every cycle tap.
  late VideoFitMode _videoFit;
  late LowMemoryMode _lowMemoryMode;
  late bool _mixWithOthers;
  late bool _autoResume;
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

  MusicPlayerController get _player => MusicPlayerController.ensure();

  @override
  void initState() {
    super.initState();
    _engineKey = HiveStore.getString(HiveKeys.videoPlayerKey, 'mpv');
    // Windows only has the MPV engine: a stored IJK/AVPlayer choice
    // (e.g. restored from a mobile backup) is clamped so the picker
    // below — which only offers MPV on Windows — always has a
    // matching selection.
    if (Platform.isWindows && _engineKey != PlayerEngine.mediaKit.key) {
      _engineKey = PlayerEngine.mediaKit.key;
    }
    // Engine section starts collapsed; the toggle state persists.
    _engineExpanded = HiveStore.getBool(HiveKeys.engineSectionExpanded, false);
    _playbackExpanded =
        HiveStore.getBool(HiveKeys.playbackSectionExpanded, false);
    _autoNext = VideoPlaybackSettings.autoNext;
    _videoFit = VideoPlaybackSettings.videoFit;
    _lowMemoryMode = LowMemoryMode.current;
    _mixWithOthers = HiveStore.getBool(HiveKeys.audioMixWithOthers, false);
    _autoResume = HiveStore.getBool(HiveKeys.autoResumeLastPlayback, false);
    _hapticsOn = HaoHaptics.enabled;
    _quality = MusicStore.quality;
    _loadSourceCount();
    _loadAppearance();
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

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    final theme = HaoTheme.of(context);
    final themeController = Get.find<ThemeController>();
    return Obx(() => Scaffold(
      backgroundColor: tabScaffoldBackground(context),
      // Unified page (chen 2026-11-19): the top bar IS the page
      // background, not a separate surface-coloured slab — see the
      // live tab AppBar for the reasoning.
      appBar: AppBar(
        title: const Text('设置'),
        backgroundColor: tabScaffoldBackground(context),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          const _SectionTitle('主题'),
          HaoGlassCard(
            quality: GlassCardQuality.standard,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Obx(
                  () => Wrap(
                    spacing: 8,
                    children: HaoThemeId.values.map((id) {
                      final selected = themeController.themeId.value == id;
                      return ChoiceChip(
                        label: Text(HaoThemes.names[id]!),
                        selected: selected,
                        selectedColor: theme.accentSoft,
                        labelStyle: TextStyle(
                          color: selected ? theme.accent : theme.textSecondary,
                        ),
                        onSelected: (_) {
                          HaoHaptics.select();
                          themeController.setTheme(id, box: HiveStore.box);
                        },
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 12),
                Obx(
                  () => SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                      ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text('跟随系统'),
                      ),
                    ],
                    selected: {themeController.themeMode.value},
                    onSelectionChanged: (modes) {
                      HaoHaptics.select();
                      themeController.setMode(modes.first, box: HiveStore.box);
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const _SectionTitle('外观'),
          _BeansSwitchRow(
            icon: Icons.wallpaper,
            title: '壁纸',
            value: _wallpaperOn,
            onChanged: (value) async {
              HaoHaptics.select();
              await AppearanceController.ensure().setWallpaperEnabled(value);
              setState(() => _loadAppearance());
            },
          ),
          const SizedBox(height: 12),
          _BeansRow(
            icon: Icons.photo_library,
            title: '壁纸管理',
            onTap: () async {
              await Get.to(() => const WallpaperPage());
              setState(() => _loadAppearance());
            },
          ),
          const SizedBox(height: 12),
          // Tab-bar selected colour (icon + label): the ring shows
          // the current colour live; tapping opens the colour sheet.
          // The colour controls only the tab-bar selected state.
          _BeansRow(
            icon: Icons.colorize,
            title: '自定义强调色',
            trailing: const AccentRingButton(),
            onTap: () => showAccentColorSheet(context),
          ),
          const SizedBox(height: 12),
          _BeansSwitchRow(
            icon: Icons.format_paint,
            title: '背景色',
            subtitle: _bgOn ? '已开启自定义背景色' : '关闭后回到主题默认背景',
            value: _bgOn,
            onChanged: (value) async {
              HaoHaptics.select();
              await AppearanceController.ensure().setBackgroundEnabled(value);
              setState(() => _loadAppearance());
            },
          ),
          if (_bgOn) ...[
            const SizedBox(height: 12),
            // Wallpaper beats the background colour — shown by
            // disabling, not by a sentence (clean pass 2026-11-19):
            // while wallpaper is on, the swatch row is greyed out
            // and untappable.
            Opacity(
              opacity: _wallpaperOn ? 0.4 : 1,
              child: IgnorePointer(
                ignoring: _wallpaperOn,
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
          ],
          const SizedBox(height: 12),
          _BeansRow(
            icon: Icons.font_download,
            title: '自定义字体',
            subtitle: _fontName.isEmpty ? '未安装' : '已安装：$_fontName',
            onTap: () => _importFont(context),
          ),
          const SizedBox(height: 12),
          _BeansRow(
            icon: Icons.restore,
            title: '恢复默认字体',
            onTap: () => _resetFont(context),
          ),
          const SizedBox(height: 20),
          _ExpandableHeader(
            icon: Icons.play_circle_fill,
            title: '播放设置',
            expanded: _playbackExpanded,
            onTap: () async {
              HaoHaptics.select();
              final next = !_playbackExpanded;
              await HiveStore.put(HiveKeys.playbackSectionExpanded, next);
              setState(() => _playbackExpanded = next);
            },
          ),
          if (_playbackExpanded) ...[
            const SizedBox(height: 12),
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
          ],
          const SizedBox(height: 20),
          _ExpandableHeader(
            icon: Icons.movie_filter,
            title: '播放器引擎',
            value: _engineExpanded
                ? null
                : PlayerEngineX.fromKey(_engineKey).displayName,
            expanded: _engineExpanded,
            onTap: () async {
              HaoHaptics.select();
              final next = !_engineExpanded;
              await HiveStore.put(HiveKeys.engineSectionExpanded, next);
              setState(() => _engineExpanded = next);
            },
          ),
          if (_engineExpanded) ...[
            const SizedBox(height: 12),
            HaoGlassCard(
              quality: GlassCardQuality.standard,
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: RadioGroup<String>(
                groupValue: _engineKey,
                onChanged: (value) async {
                  if (value == null) return;
                  HaoHaptics.select();
                  await HiveStore.put(HiveKeys.videoPlayerKey, value);
                  setState(() => _engineKey = value);
                },
                child: Column(
                // Windows only offers MPV (IJK/AVPlayer have no
                // Windows native code — see
                // PlayerEngineX.isAvailableOnPlatform).
                children: PlayerEngine.values
                    .where((e) =>
                        !Platform.isWindows ||
                        e == PlayerEngine.mediaKit)
                    .map((engine) {
                    return RadioListTile<String>(
                      title: Text(
                        engine.displayName,
                        style: TextStyle(color: theme.textPrimary),
                      ),
                      subtitle: engine == PlayerEngine.exo
                          ? const Text('AVPlayer 不能播 FLV，失败时自动换内核')
                          : null,
                      value: engine.key,
                      activeColor: theme.accent,
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          const _SectionTitle('备份与数据'),
          _BeansRow(
            icon: Icons.upload,
            title: '导出备份',
            subtitle: '导出全部本地数据',
            onTap: () => _exportBackup(context),
          ),
          const SizedBox(height: 12),
          _BeansRow(
            icon: Icons.download,
            title: '导入备份',
            subtitle: '选择备份文件恢复',
            onTap: () => _importBackup(context),
          ),
          const SizedBox(height: 20),
          const _SectionTitle('源管理'),
          _BeansRow(
            icon: Icons.music_note,
            title: '音源管理',
            onTap: () => Get.to(() => const MusicSourcesPage()),
          ),
          const SizedBox(height: 12),
          _BeansRow(
            icon: Icons.movie,
            title: '影视源管理',
            onTap: () => Get.to(() => const VideoSourcesPage()),
          ),
          const SizedBox(height: 12),
          _BeansRow(
            icon: Icons.live_tv,
            title: '直播源管理',
            onTap: () => Get.to(() => const LiveSourcesPage()),
          ),
          const SizedBox(height: 20),
          const _SectionTitle('播放与缓存'),
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
          const SizedBox(height: 12),
          // VOD picture fit (PiliPlus VideoFitType + Kazumi
          // PlayerAspectRatio): tap cycles 自动 -> 拉伸 -> 裁剪.
          // VOD only — live always renders contain.
          _BeansRow(
            icon: Icons.aspect_ratio,
            title: '视频画面比例',
            subtitle: '当前：${_videoFit.label}（仅影视播放）',
            onTap: () async {
              HaoHaptics.select();
              final next = _videoFit.next;
              await VideoPlaybackSettings.setVideoFit(next);
              setState(() => _videoFit = next);
            },
          ),
          const SizedBox(height: 12),
          // Low-memory mode (Kazumi): tap cycles 自动 -> 始终开启 ->
          // 始终关闭. Applies at the next open (mpv properties are set
          // in open()); the subtitle states the effective state now.
          _BeansRow(
            icon: Icons.data_saver_on,
            title: '低内存模式',
            subtitle:
                '${_lowMemoryMode.statusDescription()}（下次打开生效）',
            onTap: () async {
              HaoHaptics.select();
              final next = _lowMemoryMode.next;
              await LowMemoryMode.save(next);
              setState(() => _lowMemoryMode = next);
            },
          ),
          const SizedBox(height: 12),
          _BeansRow(
            icon: Icons.chat_bubble_outline,
            title: '弹幕设置',
            onTap: () => Get.to(() => const DanmakuSettingsPage()),
          ),
          const SizedBox(height: 12),
          _BeansRow(
            icon: Icons.cleaning_services,
            title: '缓存管理',
            onTap: () => Get.to(() => const CacheSettingsPage()),
          ),
          const SizedBox(height: 20),
          const _SectionTitle('关于'),
          _BeansRow(
            icon: Icons.info_outline,
            title: '版本',
            subtitle: '$kAppVersion (build $kAppBuild)',
            onTap: () => Get.to(() => const ChangelogPage()),
          ),
          const SizedBox(height: 12),
          _BeansRow(
            icon: Icons.system_update,
            title: '检查更新',
            onTap: () => _checkUpdate(context),
          ),
          const SizedBox(height: 12),
          _BeansRow(
            icon: Icons.article_outlined,
            title: '日志',
            onTap: () => Get.to(() => const AppLogPage()),
          ),
        ],
      ),
    ));
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
        Get.snackbar('导入失败', '只支持 ttf / otf / ttc 字体文件');
        return;
      }
      Get.find<ThemeController>().setCustomFontFamily(
        installed,
        box: HiveStore.box,
      );
      setState(() => _loadAppearance());
      Get.snackbar('已安装字体', _fontName);
    } catch (_) {
      if (!context.mounted) return;
      Get.snackbar('导入失败', '读取字体文件失败，请重试');
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
    Get.snackbar('已恢复', '已恢复系统默认字体');
  }

  Future<void> _checkUpdate(BuildContext context) async {
    final (result, info) = await _updateService.checkManual();
    if (!context.mounted) return;
    switch (result) {
      case UpdateCheckResult.newerAvailable:
        AppLog.info(
          '发现新版本 v${info!.version} (build ${info.build})',
        );
        await _updateService.recordKnownUpdate(info.version);
        if (!context.mounted) return;
        await showUpdateDialog(context, info, service: _updateService);
      case UpdateCheckResult.skipped:
        AppLog.debug('更新检查：已跳过该版本');
        Get.snackbar('提示', '已跳过该版本');
      case UpdateCheckResult.upToDate:
        AppLog.debug('更新检查：已是最新版本');
        await _updateService.clearKnownUpdate();
        Get.snackbar('提示', '已是最新版本');
      case UpdateCheckResult.unavailable:
        AppLog.warn('更新检查失败');
        Get.snackbar('提示', _updateFailureMessage());
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

  /// Export: write the whole-box JSON to a temp file and open the
  /// system share sheet (share_plus) so the user can save it to Files,
  /// send it, or AirDrop it. No cloud, no fixed directory.
  Future<void> _exportBackup(BuildContext context) async {
    try {
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final file = File('${dir.path}/hao-backup-$stamp.json');
      final json = BackupService(box: HiveStore.box).exportJson();
      await file.writeAsString(json);
      if (!context.mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: 'HAo Studio 备份',
          text: 'HAo Studio 备份（全部本地数据）',
        ),
      );
    } catch (_) {
      if (!context.mounted) return;
      Get.snackbar('导出失败', '备份文件写入失败，请重试');
    }
  }

  /// Import: pick a *.json file with the system file picker, then
  /// restore it. Validation happens inside BackupService before any
  /// write, so an invalid file changes nothing.
  Future<void> _importBackup(BuildContext context) async {
    try {
      final picked = await FilePicker.pickFiles(
        dialogTitle: '选择备份文件',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (picked.isEmpty) return; // user cancelled
      final file = picked.first;
      final String json;
      if (file.path != null) {
        json = await File(file.path!).readAsString();
      } else {
        json = await file.xFile.readAsString();
      }
      final (result, count) = BackupService(box: HiveStore.box)
          .importJson(json);
      if (!context.mounted) return;
      switch (result) {
        case BackupImportResult.ok:
          Get.snackbar('恢复成功', '已恢复 $count 项数据');
          // The import rewrote the whole box — every piece of state
          // this page caches from Hive is stale, not just the engine
          // key: reload the theme (its Obx rows follow the Rx values)
          // and re-read the local toggles.
          Get.find<ThemeController>().loadFromBox(HiveStore.box);
          setState(() {
            _engineKey = HiveStore.getString(HiveKeys.videoPlayerKey, 'mpv');
            // Same Windows clamp as initState (a restored backup may
            // carry an IJK/AVPlayer choice).
            if (Platform.isWindows &&
                _engineKey != PlayerEngine.mediaKit.key) {
              _engineKey = PlayerEngine.mediaKit.key;
            }
            _engineExpanded =
                HiveStore.getBool(HiveKeys.engineSectionExpanded, false);
            _playbackExpanded =
                HiveStore.getBool(HiveKeys.playbackSectionExpanded, false);
            _autoNext = VideoPlaybackSettings.autoNext;
            _mixWithOthers =
                HiveStore.getBool(HiveKeys.audioMixWithOthers, false);
            _autoResume =
                HiveStore.getBool(HiveKeys.autoResumeLastPlayback, false);
            _hapticsOn = HaoHaptics.enabled;
            _quality = MusicStore.quality;
          });
        case BackupImportResult.invalidJson:
          Get.snackbar('恢复失败', '文件不是有效的备份 JSON');
        case BackupImportResult.wrongSchema:
          Get.snackbar('恢复失败', '备份版本不受支持');
        case BackupImportResult.emptyData:
          Get.snackbar('恢复失败', '备份文件没有数据');
      }
    } catch (_) {
      if (!context.mounted) return;
      Get.snackbar('恢复失败', '读取备份文件失败，请重试');
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
        quality: GlassCardQuality.standard,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '背景色',
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: onReset,
                  child: const Text('恢复默认'),
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

/// Big section title (Beans `SectionHeader`, Components.swift:649:
/// title 21 bold). "大标题分段" — one per settings group.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Text(
        title,
        style: TextStyle(
          color: HaoTheme.of(context).textPrimary,
          fontSize: 21,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

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
          child: InkWell(
            onTap: onTap == null
                ? null
                : () {
                    HaoHaptics.tap();
                    onTap!();
                  },
            borderRadius: BorderRadius.circular(18),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Icon(icon, size: 14, color: theme.accent),
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
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: TextStyle(
                            color: theme.textSecondary,
                            fontSize: 11,
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
/// GlassSwitch trailing (Beans `.toggleStyle(.switch).tint(accent)` —
/// the theme switch already tints with the accent).
///
/// SKILL.md Rule 2 note: GlassSwitch's glass is transient (only the
/// thumb turns to glass while it is touched/dragged; at rest it looks
/// flat), so it is the library's sanctioned switch inside cards. The
/// rule prefers it in `solid` cards and outside `glass` cards, but
/// ours are glass cards (stage-1 Beans rows) and the nesting is
/// momentary, not a persistent double-refraction surface.
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
      trailing: GlassSwitch(
        value: value,
        onChanged: onChanged,
        activeColor: HaoTheme.of(context).accent,
        enableHaptics: HaoHaptics.enabled,
      ),
    );
  }
}

/// Expandable-section header card (Beans `playbackSection` header,
/// ProfileView.swift: header button with icon + title + ⌄/⌃ chevron,
/// glass radius 18, padding h14 v13, press scale 0.98). [value] is the
/// collapsed-state summary shown on the right (engine picker).
class _ExpandableHeader extends StatelessWidget {
  const _ExpandableHeader({
    required this.icon,
    required this.title,
    this.value,
    required this.expanded,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? value;
  final bool expanded;
  final VoidCallback onTap;

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
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(18),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Icon(icon, size: 14, color: theme.accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: 15,
                    ),
                  ),
                ),
                if (value != null)
                  Text(
                    value!,
                    style: TextStyle(
                      color: theme.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                const SizedBox(width: 4),
                Icon(
                  expanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 16,
                  color: theme.textMuted.withValues(alpha: 0.6),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The expanded playback panel (Beans `playbackSection` expanded body,
/// ProfileView.swift: glass radius 22, padding 16, rows spaced 14,
/// dividers muted 0.15). Rows, in Beans' order:
/// 与其他音频同时播放 / 120Hz 高刷新 (display) / 启动时自动播放上次歌曲 /
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
          // 120Hz: display-only row with a checkmark, exactly like
          // Beans (no toggle; onAppear forces the keeper on). Ours is
          // pinned in Info.plist + AppDelegate, so the checkmark is
          // always on — a switch here would be fake.
          Row(
            children: [
              SizedBox(
                width: 28,
                child: Icon(Icons.speed, size: 14, color: theme.accent),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('120Hz 高刷新', style: TextStyle(fontSize: 15)),
              ),
              Icon(Icons.check_circle, size: 17, color: theme.accent),
            ],
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
            hint: '无法使用时会由平台自动降级。',
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
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onOpenEqualizer,
              borderRadius: BorderRadius.circular(12),
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: Icon(Icons.tune, size: 14, color: theme.accent),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('均衡器', style: TextStyle(fontSize: 15)),
                      ],
                    ),
                  ),
                  Text(
                    equalizerEnabled ? '已开启' : '已关闭',
                    style: TextStyle(
                      color: equalizerEnabled
                          ? theme.accent
                          : theme.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: theme.textMuted.withValues(alpha: 0.6),
                  ),
                ],
              ),
            ),
          ),
          const _PanelDivider(),
          Row(
            children: [
              SizedBox(
                width: 28,
                child: Icon(
                  Icons.inventory_2,
                  size: 14,
                  color: theme.accent,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  '第三方音源',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                sourceCount == null ? '…' : '$sourceCount 个',
                style: TextStyle(color: theme.textSecondary, fontSize: 12),
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
          child: Icon(icon, size: 14, color: theme.accent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(title, style: const TextStyle(fontSize: 15)),
        ),
        GlassSwitch(
          value: value,
          onChanged: onChanged,
          activeColor: theme.accent,
          enableHaptics: HaoHaptics.enabled,
        ),
      ],
    );
  }
}

/// Beans quality chips (ProfileView.swift `playbackQualitySection` and
/// the third-party quality chips): title 14 semibold, hint 10, chips
/// height 31, h padding 12, font 12, spacing 8; selected fill accent
/// 0.14 + stroke accent 0.42 (0.8pt) + checkmark 9 bold; unselected
/// fill label 0.055 + stroke label 0.08. Single row (chen: one quality
/// setting for all sources).
class _QualityChips extends StatelessWidget {
  const _QualityChips({
    required this.title,
    required this.hint,
    required this.selected,
    required this.onSelected,
  });

  final String title;
  final String hint;
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
              child: Icon(Icons.graphic_eq, size: 13, color: theme.accent),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: theme.textSecondary,
                      fontSize: 10,
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
        child: InkWell(
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
                    fontSize: 12,
                    fontWeight: selected
                        ? FontWeight.w600
                        : FontWeight.w500,
                  ),
                ),
                if (selected) ...[
                  const SizedBox(width: 5),
                  Icon(Icons.check, size: 9, color: theme.accent),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
