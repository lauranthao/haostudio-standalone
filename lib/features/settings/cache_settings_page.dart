// Cache settings — per-section size + real clear.
//
// Only caches are listed (video home, Douban, daily picks, images).
// History, favourites, resume positions, playlists and listen records
// are the user's DATA and are never touched here — see [CacheService].

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/theme/hao_themes.dart';
import '../../widgets/settings_ui.dart';
import '../../services/music/music_downloads.dart';
import 'cache_service.dart';

class CacheSettingsPage extends StatefulWidget {
  const CacheSettingsPage({super.key});

  @override
  State<CacheSettingsPage> createState() => _CacheSettingsPageState();
}

class _CacheSettingsPageState extends State<CacheSettingsPage> {
  final Map<CacheSection, int> _sizes = {};
  var _loading = true;
  var _downloadBytes = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
    _refreshDownloads();
  }

  void _refresh() {
    setState(() {
      _loading = true;
      for (final s in CacheSection.values) {
        _sizes[s] = CacheService.sizeOf(s);
      }
      _loading = false;
    });
  }

  Future<void> _refreshDownloads() async {
    final bytes = await MusicDownloadService().totalBytes();
    if (!mounted) return;
    setState(() => _downloadBytes = bytes);
  }

  int get _total => _sizes.values.fold(0, (a, b) => a + b);

  Future<void> _clear(CacheSection section) async {
    final freed = await CacheService.clearSection(section);
    if (!mounted) return;
    _refresh();
    Get.snackbar(
      '已清除',
      '${section.title}已清除，释放 ${CacheService.formatBytes(freed)}',
    );
  }

  Future<void> _clearDownloads() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除全部下载？'),
        content: const Text('已下载的歌曲文件都会删除，之后需要重新下载才能离线播放。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final freed = await MusicDownloadService().clearAll();
    if (!mounted) return;
    await _refreshDownloads();
    Get.snackbar('已清除', '音乐下载已清除，释放 ${CacheService.formatBytes(freed)}');
  }

  Future<void> _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除全部缓存？'),
        content: const Text('视频首页、豆瓣、每日推荐与图片缓存都会清除，下次打开时重新加载。历史记录、收藏与歌单不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final freed = await CacheService.clearAll();
    if (!mounted) return;
    _refresh();
    Get.snackbar('已清除', '全部缓存已清除，释放 ${CacheService.formatBytes(freed)}');
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackground,
      appBar: AppBar(title: const Text('缓存管理')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else ...[
            SettingsGroup(
              children: [
                ListTile(
                  title: Text(
                    '缓存总计',
                    style: TextStyle(color: theme.textPrimary),
                  ),
                  subtitle: Text(
                    '历史记录、收藏与歌单不受影响',
                    style: TextStyle(color: theme.textSecondary),
                  ),
                  trailing: Text(
                    CacheService.formatBytes(_total),
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SettingsGroup(
              children: [
                ...CacheSection.values.map((section) {
                  return ListTile(
                    title: Text(
                      section.title,
                      style: TextStyle(color: theme.textPrimary),
                    ),
                    subtitle: Text(
                      section.subtitle,
                      style: TextStyle(color: theme.textSecondary),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          CacheService.formatBytes(_sizes[section] ?? 0),
                          style: TextStyle(color: theme.textSecondary),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () => _clear(section),
                          child: const Text('清除'),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
            const SizedBox(height: 12),
            // Music downloads (M-P0-5) are user files, not cache: they
            // are never touched by 清除全部缓存, only by their own clear.
            SettingsGroup(
              children: [
                ListTile(
                  title: Text(
                    '音乐下载',
                    style: TextStyle(color: theme.textPrimary),
                  ),
                  subtitle: Text(
                    '已下载的歌曲文件，可离线播放',
                    style: TextStyle(color: theme.textSecondary),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        CacheService.formatBytes(_downloadBytes),
                        style: TextStyle(color: theme.textSecondary),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: _clearDownloads,
                        child: const Text('清除'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _clearAll, child: const Text('清除全部缓存')),
          ],
        ],
      ),
    );
  }
}
