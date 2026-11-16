// Settings tab — foundation (real toggles where cheap, placeholders
// where the feature lands later).
//
// REAL in this foundation:
// - Theme picker: 4 themes (苹果毛玻璃 / 暗夜鎏金 / 清新薄荷 / 极夜冰蓝),
//   immediate switching, persisted. Light / dark / follow-system.
// - Preferred engine picker (MPV / IJK / AVPlayer): stored immediately;
//   the live session picks the new preferred engine up on next open.
// - Version row (1.0.4, build 5) + manual update check (shop server
//   first, GitHub raw fallback, numeric semver) + skip logic.
// - Live crash record row (fix 1): last breadcrumb stage, or 无记录.
// - Backup export/import (step 7): whole-box JSON shared via the
//   system share sheet (share_plus) / picked with the system file
//   picker (file_picker), validated before any write on import.
// - Source management (音源 / 影视源 / 直播源), danmaku settings and
//   cache clearing: separate sub-pages (Get.to), each wired to its
//   real store — see lib/features/settings/.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/consts.dart';
import '../../core/player/kernel/player_engine.dart';
import '../../core/storage/hive_store.dart';
import '../../core/theme/hao_themes.dart';
import '../../core/theme/theme_controller.dart';
import '../../widgets/settings_ui.dart';
import '../../services/backup_service.dart';
import '../../services/update_service.dart';
import '../live/live_breadcrumb.dart';
import '../video/video_history_store.dart';
import 'cache_settings_page.dart';
import 'danmaku_settings_page.dart';
import 'live_sources_page.dart';
import 'music_sources_page.dart';
import 'update_dialog.dart';
import 'video_sources_page.dart';

class SettingsTabPage extends StatefulWidget {
  const SettingsTabPage({super.key});

  @override
  State<SettingsTabPage> createState() => _SettingsTabPageState();
}

class _SettingsTabPageState extends State<SettingsTabPage> {
  late String _engineKey;
  late bool _engineExpanded;
  late bool _autoNext;
  final _updateService = UpdateService();

  @override
  void initState() {
    super.initState();
    _engineKey = HiveStore.getString(HiveKeys.videoPlayerKey, 'mpv');
    // Engine section starts collapsed; the toggle state persists.
    _engineExpanded = HiveStore.getBool(HiveKeys.engineSectionExpanded, false);
    _autoNext = VideoPlaybackSettings.autoNext;
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final themeController = Get.find<ThemeController>();
    return Scaffold(
      backgroundColor: theme.scaffoldBackground,
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const HaoSectionTitle('主题'),
          HaoGlassCard(
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
                        onSelected: (_) =>
                            themeController.setTheme(id, box: HiveStore.box),
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
                    onSelectionChanged: (modes) => themeController.setMode(
                      modes.first,
                      box: HiveStore.box,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          InkWell(
            onTap: () async {
              final next = !_engineExpanded;
              await HiveStore.put(HiveKeys.engineSectionExpanded, next);
              setState(() => _engineExpanded = next);
            },
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Text(
                    '播放器引擎',
                    style: TextStyle(
                      color: theme.textMuted,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const Spacer(),
                  if (!_engineExpanded)
                    Text(
                      PlayerEngineX.fromKey(_engineKey).displayName,
                      style: TextStyle(
                        color: theme.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  const SizedBox(width: 4),
                  Icon(
                    _engineExpanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    color: theme.textMuted,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
          if (_engineExpanded)
            HaoGlassCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: RadioGroup<String>(
                groupValue: _engineKey,
                onChanged: (value) async {
                  if (value == null) return;
                  await HiveStore.put(HiveKeys.videoPlayerKey, value);
                  setState(() => _engineKey = value);
                },
                child: Column(
                  children: PlayerEngine.values.map((engine) {
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
          const SizedBox(height: 20),
          const HaoSectionTitle('备份与数据'),
          SettingsGroup(
            children: [
              ListTile(
                title: Text('导出备份', style: TextStyle(color: theme.textPrimary)),
                subtitle: Text(
                  '导出全部本地数据为 JSON 文件，用系统分享发送',
                  style: TextStyle(color: theme.textSecondary),
                ),
                trailing: const HaoChevron(),
                onTap: () => _exportBackup(context),
              ),
              ListTile(
                title: Text('导入备份', style: TextStyle(color: theme.textPrimary)),
                subtitle: Text(
                  '选择备份 JSON 文件恢复（先校验，无效文件不写入）',
                  style: TextStyle(color: theme.textSecondary),
                ),
                trailing: const HaoChevron(),
                onTap: () => _importBackup(context),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const HaoSectionTitle('源管理'),
          SettingsGroup(
            children: [
              ListTile(
                title: Text('音源管理', style: TextStyle(color: theme.textPrimary)),
                subtitle: Text(
                  '歌曲搜索平台开关',
                  style: TextStyle(color: theme.textSecondary),
                ),
                trailing: const HaoChevron(),
                onTap: () => Get.to(() => const MusicSourcesPage()),
              ),
              ListTile(
                title: Text(
                  '影视源管理',
                  style: TextStyle(color: theme.textPrimary),
                ),
                subtitle: Text(
                  '影视采集源开关、排序、添加与删除',
                  style: TextStyle(color: theme.textSecondary),
                ),
                trailing: const HaoChevron(),
                onTap: () => Get.to(() => const VideoSourcesPage()),
              ),
              ListTile(
                title: Text(
                  '直播源管理',
                  style: TextStyle(color: theme.textPrimary),
                ),
                subtitle: Text(
                  '直播平台开关',
                  style: TextStyle(color: theme.textSecondary),
                ),
                trailing: const HaoChevron(),
                onTap: () => Get.to(() => const LiveSourcesPage()),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const HaoSectionTitle('播放与缓存'),
          SettingsGroup(
            children: [
              SwitchListTile(
                title: Text(
                  '自动连播下一集',
                  style: TextStyle(color: theme.textPrimary),
                ),
                subtitle: Text(
                  '播完一集后自动播放下一集；关闭则播完停在片尾',
                  style: TextStyle(color: theme.textSecondary),
                ),
                value: _autoNext,
                activeThumbColor: theme.accent,
                onChanged: (value) async {
                  await VideoPlaybackSettings.setAutoNext(value);
                  setState(() => _autoNext = value);
                },
              ),
              ListTile(
                title: Text('弹幕设置', style: TextStyle(color: theme.textPrimary)),
                subtitle: Text(
                  '各平台弹幕开关、字号与不透明度',
                  style: TextStyle(color: theme.textSecondary),
                ),
                trailing: const HaoChevron(),
                onTap: () => Get.to(() => const DanmakuSettingsPage()),
              ),
              ListTile(
                title: Text('缓存管理', style: TextStyle(color: theme.textPrimary)),
                subtitle: Text(
                  '查看各缓存大小并清除',
                  style: TextStyle(color: theme.textSecondary),
                ),
                trailing: const HaoChevron(),
                onTap: () => Get.to(() => const CacheSettingsPage()),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const HaoSectionTitle('关于'),
          SettingsGroup(
            children: [
              ListTile(
                title: Text('版本', style: TextStyle(color: theme.textPrimary)),
                subtitle: Text(
                  '$kAppVersion (build $kAppBuild)',
                  style: TextStyle(color: theme.textSecondary),
                ),
              ),
              ListTile(
                title: Text('检查更新', style: TextStyle(color: theme.textPrimary)),
                subtitle: Text(
                  'GitHub raw version.json，数字版本号比较',
                  style: TextStyle(color: theme.textSecondary),
                ),
                trailing: const HaoChevron(),
                onTap: () => _checkUpdate(context),
              ),
              ListTile(
                title: Text(
                  '直播崩溃记录',
                  style: TextStyle(color: theme.textPrimary),
                ),
                subtitle: Text(
                  LiveBreadcrumb.current.isEmpty
                      ? '无记录'
                      : LiveBreadcrumb.current,
                  style: TextStyle(color: theme.textSecondary),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _checkUpdate(BuildContext context) async {
    final (result, info) = await _updateService.checkManual();
    if (!context.mounted) return;
    switch (result) {
      case UpdateCheckResult.newerAvailable:
        await _updateService.recordKnownUpdate(info!.version);
        if (!context.mounted) return;
        await showUpdateDialog(context, info, service: _updateService);
      case UpdateCheckResult.skipped:
        Get.snackbar('提示', '已跳过该版本');
      case UpdateCheckResult.upToDate:
        await _updateService.clearKnownUpdate();
        Get.snackbar('提示', '已是最新版本');
      case UpdateCheckResult.unavailable:
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
  /// system share sheet (share_plus) so the user can save it to
  /// Files, send it, or AirDrop it. No cloud, no fixed directory.
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
            _engineExpanded =
                HiveStore.getBool(HiveKeys.engineSectionExpanded, false);
            _autoNext = VideoPlaybackSettings.autoNext;
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
