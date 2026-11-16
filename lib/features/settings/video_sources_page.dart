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

import '../../core/theme/hao_themes.dart';
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
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${source.name}」？'),
        content: const Text('删除后该源不再参与搜索与播放，可通过「恢复默认」找回预置源。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    _sources = _sources.where((s) => s.idKey != source.idKey).toList();
    await _save();
  }

  Future<void> _addSource() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加影视源'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('添加'),
          ),
        ],
      ),
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
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复默认影视源？'),
        content: const Text('将恢复 17 个预置源，删除自定义源，并清除开关与排序修改。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              '长按拖动排序，搜索按顺序尝试；「仅搜索」的源只参与搜索，不提供播放地址。',
              style: TextStyle(color: theme.textSecondary, fontSize: 13),
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 8),
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
        ],
      ),
    );
  }
}
