// Live source management — enable/disable per live platform.
//
// Real platforms only: the Big-5 in [Sites.supportedSiteIds]
// (哔哩哔哩 / 斗鱼 / 虎牙 / 抖音 / 快手). Toggles take effect the next
// time the live tab opens (it reads [LiveSourcesStore]); at least one
// platform must stay enabled.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/theme/hao_themes.dart';
import '../../widgets/settings_ui.dart';
import '../../shared/platforms/sites.dart';
import 'source_stores.dart';

class LiveSourcesPage extends StatefulWidget {
  const LiveSourcesPage({super.key});

  @override
  State<LiveSourcesPage> createState() => _LiveSourcesPageState();
}

class _LiveSourcesPageState extends State<LiveSourcesPage> {
  late List<String> _enabled;

  @override
  void initState() {
    super.initState();
    _enabled = LiveSourcesStore.enabledIds();
  }

  Future<void> _toggle(String siteId, bool value) async {
    final ok = await LiveSourcesStore.setEnabled(siteId, value);
    if (!ok) {
      Get.snackbar('至少保留一个直播源', '直播页至少需要一个开启的平台');
      return;
    }
    if (!mounted) return;
    setState(() => _enabled = LiveSourcesStore.enabledIds());
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('直播源管理')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SettingsGroup(
            children: [
              ...Sites.supportedSiteIds.map((id) {
                final site = Sites.of(id);
                final on = _enabled.contains(id);
                return SwitchListTile(
                  title: Text(
                    site.name,
                    style: TextStyle(color: theme.textPrimary),
                  ),
                  subtitle: Text(
                    id,
                    style: TextStyle(color: theme.textSecondary),
                  ),
                  value: on,
                  activeThumbColor: theme.accent,
                  onChanged: (v) => _toggle(id, v),
                );
              }),
            ],
          ),
        ],
      ),
    );
  }
}
