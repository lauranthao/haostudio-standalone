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

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../widgets/hao_toast.dart';

import '../../core/theme/hao_themes.dart';
import '../../services/video/emby_models.dart';
import '../../widgets/glass_dialog.dart';
import '../../widgets/native_switch.dart';
import '../../widgets/hao_inset_grouped.dart';
import '../../widgets/hao_glass_button.dart';
import '../../widgets/settings_ui.dart';
import '../video/cms_sources.dart';
import '../video/video_history_store.dart';
import '../video/video_home_service.dart';
import '../video/video_models.dart';
import 'emby_connect_page.dart';
import '../../widgets/hao_nav_bar.dart';

class VideoSourcesPage extends StatefulWidget {
  const VideoSourcesPage({super.key});

  @override
  State<VideoSourcesPage> createState() => _VideoSourcesPageState();
}

class _VideoSourcesPageState extends State<VideoSourcesPage> {
  late List<VideoSource> _sources;

  // Emby: one server, configured on the Emby connect page, stored
  // under its own Hive key (hao_emby_config). This page only shows
  // the entry row (name / status / enable switch) and opens the
  // connect page; the address / login / probe / user-pick logic
  // lives in emby_connect_page.dart. The key/token never leaves
  // EmbyConfigStore and EmbyClient — no logging, no toString, no
  // share text.
  EmbyServerConfig? _embyConfig;

  @override
  void initState() {
    super.initState();
    _sources = VideoSourcesStore.getAll();
    _embyConfig = EmbyConfigStore.load();
  }

  Future<void> _toggleEmbyEnabled(bool value) async {
    final prev = _embyConfig;
    if (prev == null) return;
    final config = prev.copyWith(enabled: value);
    _embyConfig = config;
    await EmbyConfigStore.save(config);
    if (mounted) setState(() {});
  }

  /// Open the Emby connect page; reload the entry row when it pops
  /// with a saved config.
  Future<void> _openEmbyConnect() async {
    final saved = await Navigator.of(context).push<bool>(
      CupertinoPageRoute<bool>(
        builder: (_) => EmbyConnectPage(initialConfig: _embyConfig),
      ),
    );
    if (saved == true && mounted) {
      setState(() => _embyConfig = EmbyConfigStore.load());
    }
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
      HaoToast.show('至少保留一个影视源', message:  '至少需要一个开启的影视源才能看视频');
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

  /// Re-scan ONE source (I-影视 item 11): only that source's home
  /// rows are re-fetched (VideoHomeService.rescanSource) — no other
  /// source is touched, and a failed row keeps its old items.
  /// A search-only source owns no home row: the service returns
  /// null and the toast says so instead of pretending it worked.
  Future<void> _rescan(VideoSource source) async {
    final updated = await VideoHomeService().rescanSource(source);
    if (!mounted) return;
    if (updated == null) {
      HaoToast.show('该源没有可重扫的分类', message: '仅搜索的源不参与首页');
      return;
    }
    HaoToast.show('已重扫「${source.name}」', message: '首页该源的分类已更新');
  }

  Future<void> _delete(VideoSource source) async {
    if (VideoSourcesStore.wouldLeaveNone(source)) {
      HaoToast.show('不能删除最后一个影视源', message:  '至少需要保留一个影视源');
      return;
    }
    if (source.enabled && _sources.where((s) => s.enabled).length <= 1) {
      HaoToast.show('不能删除最后一个开启的影视源', message:  '至少需要一个开启的影视源');
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
      HaoToast.show('添加失败', message:  '名称和接口地址都不能为空');
      return;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      HaoToast.show('添加失败', message:  '接口地址必须以 http:// 或 https:// 开头');
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

  /// Emby entry row: sits above the CMS list, independent of it.
  /// Tap the row to open the Emby connect page; the switch toggles
  /// the server on/off without leaving this page. The video tab's
  /// switching behaviour is unchanged (config.enabled + isConfigured
  /// still decide what the Emby tab shows).
  Widget _buildEmbyCard(HaoTheme theme) {
    final config = _embyConfig;
    final enabled = config?.enabled ?? true;
    final configured = config?.isConfigured ?? false;
    final String subtitle;
    if (!configured) {
      subtitle = '未配置，点击添加服务器';
    } else if (!enabled) {
      subtitle = '已停用';
    } else if (config!.serverName.isNotEmpty) {
      subtitle = '已连接：${config.serverName}'
          '${config.serverVersion.isNotEmpty ? '（${config.serverVersion}）' : ''}';
    } else {
      subtitle = '已配置';
    }
    return HaoInsetGroupedSection(
      margin: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: 0, right: 4),
        leading: EmbyLogo(size: 40),
        title: Text(
          config?.name ?? 'Emby',
          style: TextStyle(
            color: theme.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(color: theme.textSecondary, fontSize: 13),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            HaoNativeSwitch(
              value: configured && enabled,
              onChanged: configured ? _toggleEmbyEnabled : null,
              activeColor: theme.accent,
              semanticsLabel: 'Emby',
            ),
            const SizedBox(width: 4),
            const HaoChevron(),
          ],
        ),
        onTap: _openEmbyConnect,
      ),
    );
  }

  Future<void> _reset() async {
    final confirm = await showGlassConfirmDialog(
      context,
      title: '恢复默认影视源？',
      content: '将恢复 17 个预置源，删除自定义源，并清除开关与排序修改。',
      confirmLabel: '恢复',
    );
    if (confirm != true || !mounted) return;
    await VideoSourcesStore.resetToDefaults();
    setState(() => _sources = VideoSourcesStore.getAll());
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Scaffold(
      appBar: HaoNavBar(
        title: '影视源管理',
        actions: [HaoGlassIconButton(
            symbol: 'plus',
            fallbackIcon: Icons.add,
            tooltip: '添加影视源',
            onPressed: _addSource,
          ), HaoGlassIconButton(
            symbol: 'arrow.counterclockwise',
            fallbackIcon: Icons.restore,
            tooltip: '恢复默认',
            onPressed: _reset,
          )],
      ),
      body: Column(
        children: [
          _buildEmbyCard(theme),
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 16, 12, 12),
            child: HaoHint('长按拖动排序，搜索按顺序尝试；「仅搜索」的源只参与搜索，不提供播放地址。'),
          ),
          Expanded(
            child: HaoInsetGroupedSection(
              margin: const EdgeInsets.symmetric(horizontal: 8),
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
                          icon: Icon(Icons.refresh, shadows: HaoTheme.legibilityShadows(context),),
                          color: theme.textSecondary,
                          tooltip: '重新扫描',
                          onPressed: () => _rescan(source),
                        ),
                        IconButton(
                          icon: Icon(Icons.delete_outline, shadows: HaoTheme.legibilityShadows(context),),
                          color: theme.textSecondary,
                          tooltip: '删除',
                          onPressed: () => _delete(source),
                        ),
                        HaoNativeSwitch(
                          value: source.enabled,
                          onChanged: (v) => _toggle(source, v),
                          activeColor: theme.accent,
                          semanticsLabel: source.name,
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
