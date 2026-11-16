// Danmaku settings — per-platform on/off, font size, opacity.
//
// HONEST STATUS: the live room renders danmaku as a plain scrolling
// list under the video and does NOT yet read these keys (that file
// belongs to the player work). Every control below DOES save to Hive
// immediately via [DanmakuSettings]; the live room only has to read
// it to honour them — the banner says so instead of pretending the
// toggles already change the room. Speed / area have no control:
// a list has no scroll speed and no overlay area to size, so they are
// explained as text, not fake sliders.

import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import '../../shared/platforms/sites.dart';
import 'source_stores.dart';

class DanmakuSettingsPage extends StatefulWidget {
  const DanmakuSettingsPage({super.key});

  @override
  State<DanmakuSettingsPage> createState() => _DanmakuSettingsPageState();
}

class _DanmakuSettingsPageState extends State<DanmakuSettingsPage> {
  late Map<String, bool> _enabled;
  late double _fontSize;
  late double _opacity;

  @override
  void initState() {
    super.initState();
    _enabled = DanmakuSettings.enabledMap();
    _fontSize = DanmakuSettings.fontSize();
    _opacity = DanmakuSettings.opacity();
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackground,
      appBar: AppBar(title: const Text('弹幕设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '设置已保存到本地；直播间弹幕列表接入后生效（直播间页面由播放器专项负责）。',
                style: TextStyle(color: theme.textSecondary, fontSize: 13),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle(title: '各平台弹幕开关', theme: theme),
          ...Sites.supportedSiteIds.map((id) {
            final site = Sites.of(id);
            final on = _enabled[id] ?? true;
            return SwitchListTile(
              title: Text(
                site.name,
                style: TextStyle(color: theme.textPrimary),
              ),
              subtitle: Text(
                on ? '该平台直播间显示弹幕' : '该平台直播间不显示弹幕',
                style: TextStyle(color: theme.textSecondary),
              ),
              value: on,
              activeThumbColor: theme.accent,
              onChanged: (v) async {
                await DanmakuSettings.setEnabled(id, v);
                setState(() => _enabled = DanmakuSettings.enabledMap());
              },
            );
          }),
          const SizedBox(height: 24),
          _SectionTitle(title: '弹幕字号', theme: theme),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: _fontSize,
                  min: DanmakuSettings.minFontSize,
                  max: DanmakuSettings.maxFontSize,
                  divisions: 8,
                  label: '${_fontSize.round()}',
                  activeColor: theme.accent,
                  onChanged: (v) => setState(() => _fontSize = v),
                  onChangeEnd: (v) => DanmakuSettings.setFontSize(v),
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  '${_fontSize.round()}',
                  style: TextStyle(color: theme.textPrimary),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _SectionTitle(title: '弹幕不透明度', theme: theme),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: _opacity,
                  min: DanmakuSettings.minOpacity,
                  max: DanmakuSettings.maxOpacity,
                  divisions: 7,
                  label: _opacity.toStringAsFixed(1),
                  activeColor: theme.accent,
                  onChanged: (v) => setState(() => _opacity = v),
                  onChangeEnd: (v) => DanmakuSettings.setOpacity(v),
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  _opacity.toStringAsFixed(1),
                  style: TextStyle(color: theme.textPrimary),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _SectionTitle(title: '暂无此设置', theme: theme),
          ListTile(
            title: Text('弹幕速度', style: TextStyle(color: theme.textPrimary)),
            subtitle: Text(
              '当前弹幕为直播间下方的列表形式，没有滚动速度可调',
              style: TextStyle(color: theme.textMuted),
            ),
          ),
          ListTile(
            title: Text('弹幕区域', style: TextStyle(color: theme.textPrimary)),
            subtitle: Text(
              '弹幕列表占直播间下方全部区域，暂无区域范围设置',
              style: TextStyle(color: theme.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.theme});

  final String title;
  final HaoTheme theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          color: theme.textMuted,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
