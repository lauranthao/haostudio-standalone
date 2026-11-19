// Video (CMS) source management — the 17 shipped Apple CMS sources
// plus any user-added ones.
//
// Toggle: enable/disable per source; takes effect on the next video
// home/search load (CmsClient reads [VideoSourcesStore.getEnabled]).
// Reorder: drag to change priority (search tries sources in order).
// Delete / add: custom sources allowed; at least one source (and at
// least one enabled source) must remain. Reset restores the 17
// shipped defaults. `kind: search` sources are search-only — their
// play URLs are not trusted — and are labelled as such.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/theme/glass.dart';
import '../../core/theme/hao_themes.dart';
import '../../widgets/glass_dialog.dart';
import '../../widgets/settings_ui.dart';
import '../video/cms_sources.dart';
import '../video/video_history_store.dart';
import '../video/video_models.dart';

class VideoSourcesPage extends StatefulWidget {
  const VideoSourcesPage({super.key});

  @override
  State<VideoSourcesPage> createState() => _VideoSourcesPageState();
}

class _VideoSourcesPageState extends State<VideoSourcesPage> {
  late List<VideoSource> _sources;

  @override
  void initState() {
    super.initState();
    _sources = VideoSourcesStore.getAll();
  }

  Future<void> _save() async {
    await VideoSourcesStore.save(_sources);
    // _toggle/_reorder/_delete all await this after user input; the
    // page may have been popped mid-save — setState after dispose throws.
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _toggle(VideoSource source, bool value) async {
    if (!value &&
        _sources.where((s) => s.enabled).length <= 1 &&
        source.enabled) {
      Get.snackbar('至少保留一个影视源', '至少需要一个开启的影视源才能看视频');
      return;
    }
    _sources = _sources
        .map((s) => s.idKey == source.idKey ? s.copyWith(enabled: value) : s)
        .toList();
    await _save();
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    // onReorderItem already adjusts newIndex for the removed item.
    final item = _sources.removeAt(oldIndex);
    _sources.insert(newIndex, item);
    // Renumber sort in display order (ascending = priority).
    _sources = [
      for (var i = 0; i < _sources.length; i++) _sources[i].copyWith(sort: i),
    ];
    await _save();
  }

  Future<void> _delete(VideoSource source) async {
    if (VideoSourcesStore.wouldLeaveNone(source)) {
      Get.snackbar('不能删除最后一个影视源', '至少需要保留一个影视源');
      return;
    }
    if (source.enabled && _sources.where((s) => s.enabled).length <= 1) {
      Get.snackbar('不能删除最后一个开启的影视源', '至少需要一个开启的影视源');
      return;
    }
    // Glass confirm, like every other destructive confirm in the app
    // (playlist delete, video history clear): same shell, same button
    // order (cancel left, confirm right), red confirm for destructive.
    final confirm = await showGlassConfirmDialog(
      context,
      title: '删除「${source.name}」？',
      content: '删除后该源不再参与搜索与播放，可通过「恢复默认」找回预置源。',
      confirmLabel: '删除',
      confirmColor: HaoTheme.of(context).liveRed,
    );
    if (confirm != true || !mounted) return;
    _sources = _sources.where((s) => s.idKey != source.idKey).toList();
    await _save();
  }

  Future<void> _addSource() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    // Glass dialog, like every other dialog in the app (glass_dialog
    // rule): same shell, title 17 w700, actions right-aligned.
    final added = await showGlassDialog<bool>(
      context,
      builder: (ctx) {
        final theme = HaoTheme.of(ctx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '添加影视源',
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(
                labelText: '采集接口地址',
                hintText: 'https://…/api.php/provide/vod',
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(
                    '取消',
                    style: TextStyle(color: theme.textSecondary),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text('添加', style: TextStyle(color: theme.accent)),
                ),
              ],
            ),
          ],
        );
      },
    );
    if (added != true || !mounted) return;
    final name = nameController.text.trim();
    final url = urlController.text.trim();
    if (name.isEmpty || url.isEmpty) {
      Get.snackbar('添加失败', '名称和接口地址都不能为空');
      return;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      Get.snackbar('添加失败', '接口地址必须以 http:// 或 https:// 开头');
      return;
    }
    if (isPlainHttpVideoSourceUrl(url)) {
      // Plain-http custom source: warn clearly (requests go in the
      // clear), but do NOT block — the user's own sources are their
      // call. Same glass confirm shell as delete / reset.
      final keep = await showGlassConfirmDialog(
        context,
        title: '该接口使用明文 http',
        content:
            '“$name”的接口地址是 http://，搜索与播放请求将以明文传输，同一网络下可能被窃听或篡改。建议改用支持 https 的接口地址。',
        confirmLabel: '仍要添加',
      );
      if (!keep || !mounted) return;
    }
    final maxSort = _sources.fold<int>(0, (m, s) => s.sort > m ? s.sort : m);
    _sources = [
      ..._sources,
      VideoSource(
        id: 'custom-${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        apiUrl: url,
        kind: 'play',
        enabled: true,
        sort: maxSort + 1,
      ),
    ];
    await _save();
  }

  Future<void> _reset() async {
    final confirm = await showGlassConfirmDialog(
      context,
      title: '恢复默认影视源？',
      content: '将恢复 17 个预置源，删除自定义源，并清除开关与排序修改。',
      confirmLabel: '恢复',
      confirmColor: HaoTheme.of(context).liveRed,
    );
    if (confirm != true || !mounted) return;
    await VideoSourcesStore.resetToDefaults();
    setState(() => _sources = VideoSourcesStore.getAll());
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackground,
      appBar: AppBar(
        title: const Text('影视源管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加影视源',
            onPressed: _addSource,
          ),
          IconButton(
            icon: const Icon(Icons.restore),
            tooltip: '恢复默认',
            onPressed: _reset,
          ),
        ],
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 16, 12, 12),
            child: HaoHint('长按拖动排序，搜索按顺序尝试；「仅搜索」的源只参与搜索，不提供播放地址。'),
          ),
          Expanded(
            child: HaoGlassCard(
              margin: const EdgeInsets.symmetric(horizontal: 8),
              quality: GlassCardQuality.standard,
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: ReorderableListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                itemCount: _sources.length,
                onReorderItem: _reorder,
                itemBuilder: (context, i) {
                  final source = _sources[i];
                  return ListTile(
                    key: ValueKey(source.idKey),
                    title: Text(
                      source.name,
                      style: TextStyle(color: theme.textPrimary),
                    ),
                    subtitle: Text(
                      source.isPlay ? source.apiUrl : '仅搜索 · ${source.apiUrl}',
                      style: TextStyle(color: theme.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          color: theme.textSecondary,
                          tooltip: '删除',
                          onPressed: () => _delete(source),
                        ),
                        Switch(
                          value: source.enabled,
                          activeThumbColor: theme.accent,
                          onChanged: (v) => _toggle(source, v),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
