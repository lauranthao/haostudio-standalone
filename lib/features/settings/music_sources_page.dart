// Music source management — enable/disable per search platform +
// LX script sources (M-P0-6).
//
// Real sources only: the four search platforms in [kSearchPlatforms]
// (网易云 / QQ音乐 / 酷狗 / 酷我). 咪咕 is NOT a search source (it only
// appears in alt-platform lookup), so it is not listed. Toggles take
// effect on the next song search (SongSearchService reads
// [MusicSourcesStore]); at least one platform must stay enabled.
//
// Script sources: the bundled LX 歌一刀 scripts (ikun / 新澜 / 溯音 /
// 落雪) plus user-added custom scripts. Each script runs in its own JS
// runtime and is registered with ONLY the capabilities it declares
// (see LxScriptEngine). A toggle takes effect on the next play-URL
// resolve / search; scripts are additive, so turning them all off is
// harmless. Bundled scripts are NOT hardcoded: they live as files in
// the app documents directory (seeded from assets on first launch)
// and any script — bundled or custom — can be deleted here; a deleted
// bundled script is never re-seeded or loaded again. Custom scripts
// are added by URL — the add flow downloads AND validates the script
// (it must evaluate and send `inited`) and only saves it on success;
// a failed add shows the reason and saves nothing. There are no dead
// buttons on this page.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/theme/hao_themes.dart';
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
      Get.snackbar('至少保留一个音源', '歌曲搜索至少需要一个开启的平台');
      return;
    }
    setState(() => _enabled = MusicSourcesStore.enabled());
  }

  Future<void> _toggleScript(String scriptId, bool value) async {
    await LxScriptSourcesStore.setEnabled(scriptId, value);
    setState(() {});
  }

  Future<void> _addCustom() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      Get.snackbar('请输入脚本链接', '粘贴 LX 音乐源脚本的 URL');
      return;
    }
    setState(() => _adding = true);
    try {
      final info = await LxScriptEngine.instance.addCustomScript(url);
      _urlController.clear();
      setState(() {
        _scriptInfos = LxScriptEngine.instance.scripts;
        _custom = LxScriptSourcesStore.customScripts();
      });
      Get.snackbar('已添加', '${info.name} · ${info.sources.length} 个音源');
    } on LxScriptException catch (e) {
      Get.snackbar('添加失败', e.message);
    } catch (e) {
      Get.snackbar('添加失败', e.toString());
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _removeScript(String id, String name) async {
    await LxScriptEngine.instance.removeScript(id);
    if (!mounted) return;
    setState(() {
      _scriptInfos = LxScriptEngine.instance.scripts;
      _custom = LxScriptSourcesStore.customScripts();
    });
    Get.snackbar('已删除', name);
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
    VoidCallback? onDelete,
  }) {
    final theme = HaoTheme.of(context);
    final on = LxScriptSourcesStore.isEnabled(id);
    return ListTile(
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
              icon: const Icon(Icons.delete_outline, size: 20),
              color: theme.textSecondary,
              tooltip: '删除',
              onPressed: onDelete,
            ),
          Switch(
            value: on,
            activeThumbColor: theme.accent,
            onChanged: (v) => _toggleScript(id, v),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackground,
      appBar: AppBar(title: const Text('音源管理')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '歌曲搜索仅查询已开启的平台；关闭后该平台的歌曲不再出现在搜索结果中。',
            style: TextStyle(color: theme.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 16),
          ...kSearchPlatforms.map((pf) {
            final on = _enabled.contains(pf);
            return SwitchListTile(
              title: Text(
                pf.displayName,
                style: TextStyle(color: theme.textPrimary),
              ),
              subtitle: Text(
                '搜索该平台的歌曲',
                style: TextStyle(color: theme.textSecondary),
              ),
              value: on,
              activeThumbColor: theme.accent,
              onChanged: (v) => _toggle(pf, v),
            );
          }),
          const SizedBox(height: 8),
          const Divider(),
          const SizedBox(height: 8),
          Text(
            '脚本音源 (LX 歌一刀)',
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '内置 LX 音乐源脚本，在播放解析与搜索时作为附加音源；关闭后该脚本不再参与解析。每个脚本只提供它自己声明的能力。点删除可移除脚本，删除后不再加载（可通过下方的链接重新添加）。',
            style: TextStyle(color: theme.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 8),
          if (_scriptsLoading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '脚本加载中…',
                style: TextStyle(color: theme.textSecondary, fontSize: 13),
              ),
            ),
          // Bundled tiles are driven by the loaded scripts, not the
          // static bundled list — a deleted script is gone from here.
          ..._scriptInfos.where((s) => !s.isCustom).map(
                (info) => _scriptTile(
                  id: info.id,
                  title: info.name,
                  subtitle:
                      '${_bundledBlurb(info.id)}\n${_statusLineFor(info)}',
                  onDelete: () => _removeScript(info.id, info.name),
                ),
              ),
          ..._custom.map(
            (s) => _scriptTile(
              id: s.id,
              title: s.name,
              subtitle:
                  '自定义脚本 · ${s.url}\n${_infoFor(s.id)?.loaded == true ? '已加载 · ${_infoFor(s.id)!.sources.map((e) => e.platform).join(' / ')}' : '未加载'}',
              onDelete: () => _removeScript(s.id, s.name),
            ),
          ),
          const SizedBox(height: 16),
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
            '粘贴 LX 音乐源脚本链接；添加时会下载并验证脚本，通过后才会保存。仅支持 LX 格式脚本。',
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
              hintStyle: TextStyle(color: theme.textSecondary),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _adding ? null : _addCustom,
            child: Text(_adding ? '验证中…' : '添加'),
          ),
        ],
      ),
    );
  }
}
