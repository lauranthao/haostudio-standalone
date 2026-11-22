// Music source management — enable/disable per search platform +
// LX script sources (M-P0-6).
//
// Real sources only: the four search platforms in [kSearchPlatforms]
// (网易云 / QQ音乐 / 酷狗 / 酷我). 咪咕 is NOT a search source (it only
// appears in alt-platform lookup), so it is not listed. Toggles take
// effect on the next song search (SongSearchService reads
// [MusicSourcesStore]); at least one platform must stay enabled.
//
// Script sources: the bundled LX 歌一刀 scripts (溯音 / 杰翔 / fish
// / …) plus user-added custom scripts. Each script runs in its own JS
// runtime and is registered with ONLY the capabilities it declares
// (see LxScriptEngine). A toggle takes effect on the next play-URL
// resolve / search; scripts are additive, so turning them all off is
// harmless. Bundled scripts are NOT hardcoded: they live as files in
// the app documents directory (seeded from assets on first launch)
// and any script — bundled or custom — can be deleted here; a deleted
// bundled script is never re-seeded or loaded again. Custom scripts
// are added by URL or by uploading a .js file — the add flow
// validates the script (it must evaluate and send `inited`) and only
// saves it on success; a failed add shows the reason and saves
// nothing. The script list is draggable: the saved order decides
// which LX script is tried first when two scripts could serve the
// same song (script vs built-in is still by measured speed).
// There are no dead buttons on this page.

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../widgets/hao_toast.dart';
import '../../widgets/native_switch.dart';

import '../../core/theme/hao_themes.dart';
import '../../core/theme/haptics.dart';
import '../../widgets/glass_dialog.dart';
import '../../widgets/hao_inset_grouped.dart';
import '../../widgets/hao_glass_button.dart';
import '../../widgets/settings_ui.dart';
import '../../services/music/lx_script_engine.dart';
import '../../services/music/lx_script_store.dart';
import '../../services/music/music_models.dart';
import 'source_stores.dart';

class MusicSourcesPage extends StatefulWidget {
  const MusicSourcesPage({super.key});

  @override
  State<MusicSourcesPage> createState() => _MusicSourcesPageState();
}

class _MusicSourcesPageState extends State<MusicSourcesPage> {
  late List<MusicPlatform> _enabled;
  final _urlController = TextEditingController();
  bool _adding = false;
  bool _scriptsLoading = true;
  List<LxScriptInfo> _scriptInfos = [];
  List<LxCustomScript> _custom = [];

  @override
  void initState() {
    super.initState();
    _enabled = MusicSourcesStore.enabled();
    _custom = LxScriptSourcesStore.customScripts();
    _loadScripts();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _loadScripts() async {
    try {
      await LxScriptEngine.instance.ensureInitialized();
    } catch (_) {
      // Per-script failures are recorded on the script info; the page
      // shows them instead of failing to open.
    }
    if (!mounted) return;
    setState(() {
      _scriptsLoading = false;
      _scriptInfos = LxScriptEngine.instance.scripts;
      _custom = LxScriptSourcesStore.customScripts();
    });
  }

  Future<void> _toggle(MusicPlatform pf, bool value) async {
    final ok = await MusicSourcesStore.setEnabled(pf, value);
    if (!ok) {
      HaoToast.show('至少保留一个音源', message:  '歌曲搜索至少需要一个开启的平台');
      return;
    }
    if (!mounted) return;
    setState(() => _enabled = MusicSourcesStore.enabled());
  }

  Future<void> _toggleScript(String scriptId, bool value) async {
    await LxScriptSourcesStore.setEnabled(scriptId, value);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _addCustom() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      HaoToast.show('请输入脚本链接', message:  '粘贴 LX 音乐源脚本的 URL');
      return;
    }
    setState(() => _adding = true);
    try {
      final info = await LxScriptEngine.instance.addCustomScript(url);
      if (!mounted) return;
      _urlController.clear();
      setState(() {
        _scriptInfos = LxScriptEngine.instance.scripts;
        _custom = LxScriptSourcesStore.customScripts();
      });
      HaoToast.show('已添加', message:  '${info.name} · ${info.sources.length} 个音源');
    } on LxScriptException catch (e) {
      HaoToast.show('添加失败', message:  e.message);
    } catch (e) {
      HaoToast.show('添加失败', message:  e.toString());
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _addCustomFromFile() async {
    HaoHaptics.tap();
    final picked = await FilePicker.pickFiles(
      dialogTitle: '选择 LX 脚本文件',
      type: FileType.custom,
      allowedExtensions: ['js'],
    );
    if (picked.isEmpty) return; // user cancelled
    final file = picked.first;
    String? code;
    try {
      // file_picker 13 has no withData flag: path is set for local
      // files; otherwise read the bytes via the XFile-backed handle.
      final path = file.path;
      if (path != null) {
        code = await File(path).readAsString();
      } else {
        code = utf8.decode(await file.readAsBytes(), allowMalformed: true);
      }
    } catch (_) {
      code = null;
    }
    if (code == null || code.isEmpty) {
      HaoToast.show('读取失败', message:  '无法读取该文件');
      return;
    }
    setState(() => _adding = true);
    try {
      final info = await LxScriptEngine.instance.addCustomScriptFromFile(
        fileName: file.name,
        code: code,
      );
      if (!mounted) return;
      setState(() {
        _scriptInfos = LxScriptEngine.instance.scripts;
        _custom = LxScriptSourcesStore.customScripts();
      });
      HaoToast.show('已添加', message:  '${info.name} · ${info.sources.length} 个音源');
    } on LxScriptException catch (e) {
      HaoToast.show('添加失败', message:  e.message);
    } catch (e) {
      HaoToast.show('添加失败', message:  e.toString());
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _removeScript(String id, String name) async {
    // Same glass confirm as every other destructive delete in the
    // app — a custom script is user-added work, not a toggle.
    final ok = await showGlassConfirmDialog(
      context,
      title: '删除音源脚本',
      content: '将删除「$name」，该脚本的音源不再参与搜索与播放。',
      confirmLabel: '删除',
    );
    if (ok != true || !mounted) return;
    await LxScriptEngine.instance.removeScript(id);
    if (!mounted) return;
    setState(() {
      _scriptInfos = LxScriptEngine.instance.scripts;
      _custom = LxScriptSourcesStore.customScripts();
    });
    // Prune the deleted id from the saved manual order so a stale
    // id never lingers (readers ignore it anyway).
    final remaining = _scriptInfos.map((s) => s.id).toSet();
    final order = LxScriptSourcesStore.scriptOrder();
    final pruned = order.where(remaining.contains).toList();
    if (pruned.length != order.length) {
      await LxScriptSourcesStore.saveScriptOrder(pruned);
    }
    HaoToast.show('已删除', message:  name);
  }

  /// Scripts in the user's manual order: saved ids first, then any
  /// id not in the saved list (newly added scripts) last, keeping
  /// engine order. Deleted ids in the saved list are ignored.
  List<LxScriptInfo> _orderedScriptInfos() {
    final saved = LxScriptSourcesStore.scriptOrder();
    final byId = {for (final s in _scriptInfos) s.id: s};
    final out = <LxScriptInfo>[];
    for (final id in saved) {
      final s = byId.remove(id);
      if (s != null) out.add(s);
    }
    out.addAll(byId.values);
    return out;
  }

  Future<void> _reorderScripts(int oldIndex, int newIndex) async {
    // onReorderItem already adjusts newIndex for the removed item.
    final ordered = _orderedScriptInfos();
    final moved = ordered.removeAt(oldIndex);
    ordered.insert(newIndex, moved);
    await LxScriptSourcesStore.saveScriptOrder(
      ordered.map((s) => s.id).toList(),
    );
    HaoHaptics.select();
    if (!mounted) return;
    setState(() {});
  }

  LxScriptInfo? _infoFor(String id) {
    for (final s in _scriptInfos) {
      if (s.id == id) return s;
    }
    return null;
  }

  String _bundledBlurb(String id) {
    for (final spec in kBundledLxScripts) {
      if (spec.id == id) return spec.blurb;
    }
    return '';
  }

  String _statusLineFor(LxScriptInfo info) {
    if (!info.loaded) {
      final err = (info.error ?? '加载失败').replaceAll('\n', ' ');
      return '加载失败：${err.length > 60 ? '${err.substring(0, 60)}…' : err}';
    }
    if (info.sources.isEmpty) return '已加载 · 未声明可用音源';
    final plats = info.sources.map((s) => s.platform).join(' / ');
    final acts = info.sources.any((s) => s.supportsSearch)
        ? '播放链接 + 搜索'
        : '播放链接';
    return '已加载 · $plats · $acts';
  }

  Widget _scriptTile({
    required String id,
    required String title,
    required String subtitle,
    required int dragIndex,
    VoidCallback? onDelete,
  }) {
    final theme = HaoTheme.of(context);
    final on = LxScriptSourcesStore.isEnabled(id);
    return ListTile(
      leading: ReorderableDragStartListener(
        index: dragIndex,
        child: Icon(
          Icons.drag_handle, shadows: HaoTheme.legibilityShadows(context), 
          size: 20,
          color: theme.textSecondary,
        ),
      ),
      title: Text(title, style: TextStyle(color: theme.textPrimary)),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: theme.textSecondary, fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onDelete != null)
            IconButton(
              icon: Icon(Icons.delete_outline, shadows: HaoTheme.legibilityShadows(context),  size: 20),
              color: theme.textSecondary,
              tooltip: '删除',
              onPressed: onDelete,
            ),
          HaoNativeSwitch(
            value: on,
            onChanged: (v) => _toggleScript(id, v),
            activeColor: theme.accent,
            semanticsLabel: title,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('音源管理')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SettingsGroup(
            children: [
              ...kSearchPlatforms.map((pf) {
                final on = _enabled.contains(pf);
                return HaoSwitchRow(
                  title: pf.displayName,
                  subtitle: '搜索该平台的歌曲',
                  value: on,
                  onChanged: (v) => _toggle(pf, v),
                );
              }),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            '脚本音源 (LX 歌一刀)',
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          if (_scriptsLoading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '脚本加载中…',
                style: TextStyle(color: theme.textSecondary, fontSize: 13),
              ),
            ),
          // Tiles are driven by the loaded scripts, not the static
          // bundled list — a deleted script is gone from here. One
          // draggable list (bundled + custom together) in the user's
          // saved manual order.
          _scriptList(),
          const SizedBox(height: 20),
          Text(
            '添加自定义脚本',
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '粘贴 LX 音乐源脚本链接，或直接上传 .js 文件。',
            style: TextStyle(color: theme.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _addCustom(),
            decoration: InputDecoration(
              hintText: 'https://…/xxx.js',
              hintStyle: TextStyle(
                shadows: HaoTheme.legibilityShadows(context),
                color: theme.textSecondary,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
          ),
          const SizedBox(height: 10),
          HaoGlassButton(
            label: _adding ? '验证中…' : '添加',
            onPressed: _adding ? null : _addCustom,
            fallback: FilledButton(
              onPressed: _adding ? null : _addCustom,
              child: Text(_adding ? '验证中…' : '添加'),
            ),
          ),
          const SizedBox(height: 10),
          HaoGlassButton(
            label: _adding ? '验证中…' : '上传 .js 文件',
            iconSymbol: 'square.and.arrow.up',
            onPressed: _adding ? null : _addCustomFromFile,
            fallback: FilledButton.icon(
              onPressed: _adding ? null : _addCustomFromFile,
              icon: Icon(Icons.upload_file, shadows: HaoTheme.legibilityShadows(context),  size: 20),
              label: Text(_adding ? '验证中…' : '上传 .js 文件'),
            ),
          ),
        ],
      ),
    );
  }

  /// The draggable script list: bundled + custom in the user's saved
  /// manual order, in the same glass card as the old SettingsGroup.
  Widget _scriptList() {
    final ordered = _orderedScriptInfos();
    return HaoInsetGroupedSection(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: ReorderableListView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        onReorderItem: _reorderScripts,
        children: [
          for (var i = 0; i < ordered.length; i++)
            _scriptRow(ordered[i], i, i == ordered.length - 1),
        ],
      ),
    );
  }

  Widget _scriptRow(LxScriptInfo info, int index, bool isLast) {
    return Column(
      key: ValueKey(info.id),
      mainAxisSize: MainAxisSize.min,
      children: [
        _tileFor(info, index),
        if (!isLast) const Divider(height: 1, indent: 16, endIndent: 16),
      ],
    );
  }

  Widget _tileFor(LxScriptInfo info, int index) {
    if (info.isCustom) {
      final saved = _customFor(info.id);
      final loadedInfo = _infoFor(info.id);
      return _scriptTile(
        id: info.id,
        title: info.name,
        subtitle:
            '自定义脚本 · ${saved?.url ?? info.origin}\n${loadedInfo?.loaded == true ? '已加载 · ${loadedInfo!.sources.map((e) => e.platform).join(' / ')}' : '未加载'}',
        dragIndex: index,
        onDelete: () => _removeScript(info.id, info.name),
      );
    }
    return _scriptTile(
      id: info.id,
      title: info.name,
      subtitle: '${_bundledBlurb(info.id)}\n${_statusLineFor(info)}',
      dragIndex: index,
      onDelete: () => _removeScript(info.id, info.name),
    );
  }

  LxCustomScript? _customFor(String id) {
    for (final s in _custom) {
      if (s.id == id) return s;
    }
    return null;
  }
}
