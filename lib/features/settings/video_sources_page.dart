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

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../../widgets/hao_toast.dart';

import '../../core/theme/glass.dart';
import '../../core/theme/hao_themes.dart';
import '../../core/theme/haptics.dart';
import '../../core/theme/liquid_glass_theme.dart';
import '../../services/video/emby_client.dart';
import '../../services/video/emby_models.dart';
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

  // Emby: one server, configured here, stored under its own Hive key
  // (hao_emby_config). The key never leaves this card's controllers
  // and EmbyClient — no logging, no toString, no share text.
  EmbyServerConfig? _embyConfig;
  late final TextEditingController _embyBaseController;
  late final TextEditingController _embyKeyController;
  bool _embyProbing = false;
  String _embyProbeStatus = '';
  bool _embyProbeOk = false;
  List<EmbyUser> _embyUsers = const [];
  String? _embySelectedUserId;
  bool _embyHttpWarned = false;
  CancelToken? _embyProbeToken;

  @override
  void initState() {
    super.initState();
    _sources = VideoSourcesStore.getAll();
    _embyConfig = EmbyConfigStore.load();
    _embyBaseController =
        TextEditingController(text: _embyConfig?.baseUrl ?? '');
    _embyKeyController =
        TextEditingController(text: _embyConfig?.apiKey ?? '');
    _embySelectedUserId = _embyConfig?.userId.isNotEmpty == true
        ? _embyConfig!.userId
        : null;
  }

  @override
  void dispose() {
    _embyProbeToken?.cancel();
    _embyBaseController.dispose();
    _embyKeyController.dispose();
    super.dispose();
  }

  EmbyServerConfig _embyFromFields({bool? enabled, String? userId}) {
    final prev = _embyConfig;
    return EmbyServerConfig(
      baseUrl: _embyBaseController.text.trim(),
      apiKey: _embyKeyController.text.trim(),
      userId: userId ?? prev?.userId ?? '',
      enabled: enabled ?? prev?.enabled ?? true,
      movieLibraryId: prev?.movieLibraryId,
      tvLibraryId: prev?.tvLibraryId,
    );
  }

  Future<void> _saveEmby({bool? enabled, String? userId}) async {
    final config = _embyFromFields(enabled: enabled, userId: userId);
    _embyConfig = config;
    await EmbyConfigStore.save(config);
  }

  Future<void> _toggleEmbyEnabled(bool value) async {
    await _saveEmby(enabled: value);
    if (mounted) setState(() {});
  }

  Future<void> _probeEmby() async {
    final baseUrl = _embyBaseController.text.trim();
    final apiKey = _embyKeyController.text.trim();
    if (baseUrl.isEmpty || apiKey.isEmpty) {
      setState(() {
        _embyProbeOk = false;
        _embyProbeStatus = '请先填写服务器地址和 API 密钥';
      });
      return;
    }
    if (!baseUrl.startsWith('http://') &&
        !baseUrl.startsWith('https://')) {
      setState(() {
        _embyProbeOk = false;
        _embyProbeStatus = '服务器地址必须以 http:// 或 https:// 开头';
      });
      return;
    }
    if (isPlainHttpVideoSourceUrl(baseUrl) && !_embyHttpWarned) {
      // Plain-http server: warn clearly (requests go in the clear),
      // but do NOT block — a LAN http address is a legal setup.
      // Same glass confirm shell as the CMS add-source warning.
      final keep = await showGlassConfirmDialog(
        context,
        title: '该地址使用明文 http',
        content:
            'Emby 服务器地址是 http://，请求将以明文传输，同一网络下可能被窃听或篡改。建议改用支持 https 的地址。',
        confirmLabel: '仍要连接',
      );
      if (keep != true || !mounted) return;
      _embyHttpWarned = true;
    }
    await _saveEmby();
    setState(() {
      _embyProbing = true;
      _embyProbeStatus = '正在连接…';
    });
    _embyProbeToken?.cancel();
    final token = _embyProbeToken = CancelToken();
    final result = await EmbyClient(config: _embyConfig!)
        .probe(cancelToken: token);
    if (!mounted) return;
    if (token.isCancelled) return;
    if (result.ok) {
      if (result.users.length == 1) {
        await _saveEmby(userId: result.users.first.id);
        _embySelectedUserId = result.users.first.id;
        _embyUsers = const [];
      } else {
        _embyUsers = result.users;
        if (_embyUsers.isNotEmpty &&
            (_embySelectedUserId == null ||
                !_embyUsers.any((u) => u.id == _embySelectedUserId))) {
          _embySelectedUserId = null;
        }
      }
      setState(() {
        _embyProbing = false;
        _embyProbeOk = true;
        _embyProbeStatus = result.serverName.isNotEmpty
            ? '已连接：${result.serverName}'
                '${result.version.isNotEmpty ? '（${result.version}）' : ''}'
            : '已连接';
      });
    } else {
      setState(() {
        _embyProbing = false;
        _embyProbeOk = false;
        _embyProbeStatus = result.errorMessage;
      });
    }
  }

  Future<void> _onEmbyUserSelected(String? userId) async {
    if (userId == null) return;
    await _saveEmby(userId: userId);
    if (mounted) {
      setState(() => _embySelectedUserId = userId);
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

  /// Emby config card: sits above the CMS list, independent of it.
  /// Fields: server address + API key + probe + enable switch. No
  /// extra hint text. The user id is never typed here — probe fills
  /// it in (single user), or the picker below appears (multi-user).
  Widget _buildEmbyCard(HaoTheme theme) {
    final enabled = _embyConfig?.enabled ?? true;
    return HaoGlassCard(
      margin: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      quality: GlassCardQuality.standard,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Emby',
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              GlassSwitch(
                value: enabled,
                // N-8: iOS size 51x31 (was Material Switch).
                width: 51,
                height: 31,
                activeColor: theme.accent,
                settings: HaoLiquidGlass.ios27Settings(context),
                enableHaptics: HaoHaptics.enabled,
                onChanged: _toggleEmbyEnabled,
              ),
            ],
          ),
          TextField(
            controller: _embyBaseController,
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: 'http://192.168.1.10:8096',
            ),
            keyboardType: TextInputType.url,
            onChanged: (_) => _saveEmby(),
          ),
          TextField(
            controller: _embyKeyController,
            decoration: const InputDecoration(labelText: 'API 密钥'),
            obscureText: true,
            onChanged: (_) => _saveEmby(),
          ),
          if (_embyUsers.length > 1) ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _embySelectedUserId,
              decoration: const InputDecoration(labelText: '用户'),
              items: _embyUsers
                  .map(
                    (u) => DropdownMenuItem<String>(
                      value: u.id,
                      child: Text(u.name),
                    ),
                  )
                  .toList(),
              onChanged: _onEmbyUserSelected,
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton(
                onPressed: _embyProbing ? null : _probeEmby,
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: theme.hairline),
                  foregroundColor: theme.accent,
                ),
                child: Text(_embyProbing ? '连接中…' : '测连通'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _embyProbeStatus,
                  style: TextStyle(
                    color: _embyProbeOk
                        ? theme.accent
                        : theme.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ],
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
          _buildEmbyCard(theme),
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
                        GlassSwitch(
                          value: source.enabled,
                          // N-8: iOS size 51x31 (was Material Switch).
                          width: 51,
                          height: 31,
                          activeColor: theme.accent,
                          settings: HaoLiquidGlass.ios27Settings(context),
                          enableHaptics: HaoHaptics.enabled,
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
