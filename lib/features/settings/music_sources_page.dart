// Music source management — enable/disable per search platform.
//
// Real sources only: the four search platforms in [kSearchPlatforms]
// (网易云 / QQ音乐 / 酷狗 / 酷我). 咪咕 is NOT a search source (it only
// appears in alt-platform lookup), so it is not listed. Toggles take
// effect on the next song search (SongSearchService reads
// [MusicSourcesStore]); at least one platform must stay enabled.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/theme/hao_themes.dart';
import '../../services/music/music_models.dart';
import 'source_stores.dart';

class MusicSourcesPage extends StatefulWidget {
  const MusicSourcesPage({super.key});

  @override
  State<MusicSourcesPage> createState() => _MusicSourcesPageState();
}

class _MusicSourcesPageState extends State<MusicSourcesPage> {
  late List<MusicPlatform> _enabled;

  @override
  void initState() {
    super.initState();
    _enabled = MusicSourcesStore.enabled();
  }

  Future<void> _toggle(MusicPlatform pf, bool value) async {
    final ok = await MusicSourcesStore.setEnabled(pf, value);
    if (!ok) {
      Get.snackbar('至少保留一个音源', '歌曲搜索至少需要一个开启的平台');
      return;
    }
    setState(() => _enabled = MusicSourcesStore.enabled());
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
        ],
      ),
    );
  }
}
