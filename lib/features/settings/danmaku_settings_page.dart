// Danmaku settings — per-platform on/off, font size, opacity, area.
//
// Every control below saves to Hive immediately via [DanmakuSettings]
// and the live room honours it (live_room_page.dart): the per-platform
// switch gates the transport, font size / opacity style the list, the
// area caps the fullscreen floating danmaku (BarrageConfig.area), and
// changes apply while a room is open, no restart. Speed has no control:
// a list has no scroll speed, so it is explained as text, not a fake
// slider. The area does NOT move the portrait list — that list is a
// chat list below the video, not an overlay; it only limits the
// fullscreen flying danmaku, and the UI says so.

import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import '../../widgets/settings_ui.dart';
import '../../domains/live/presentation/playback/danmaku_block_store.dart';
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
  late String _area;

  // S2 chat-list style.
  late String _listStyle;
  late String _listSpacing;
  late bool _showUsernames;

  // S3 content filtering.
  late bool _similarityEnabled;
  late int _similarityThreshold;
  late bool _blockEmoteOnly;
  late bool _blockLong;
  late int _blockLongLength;
  late bool _douyuBotFilter;

  // Keyword + username block list (S3/S4).
  late List<DanmakuBlockEntry> _blocks;
  final _blockInput = TextEditingController();
  String _blockKind = 'word';

  @override
  void initState() {
    super.initState();
    _enabled = DanmakuSettings.enabledMap();
    _fontSize = DanmakuSettings.fontSize();
    _opacity = DanmakuSettings.opacity();
    _area = DanmakuSettings.area();
    _listStyle = DanmakuSettings.listStyle();
    _listSpacing = DanmakuSettings.listSpacing();
    _showUsernames = DanmakuSettings.showUsernames();
    _similarityEnabled = DanmakuSettings.similarityEnabled();
    _similarityThreshold = DanmakuSettings.similarityThreshold();
    _blockEmoteOnly = DanmakuSettings.blockEmoteOnly();
    _blockLong = DanmakuSettings.blockLong();
    _blockLongLength = DanmakuSettings.blockLongLength();
    _douyuBotFilter = DanmakuSettings.douyuBotFilter();
    _blocks = DanmakuBlockStore.getAll();
  }

  @override
  void dispose() {
    _blockInput.dispose();
    super.dispose();
  }

  Future<void> _addBlock() async {
    final added = await DanmakuBlockStore.add(_blockInput.text, _blockKind);
    if (!mounted) return;
    if (added) {
      _blockInput.clear();
      setState(() => _blocks = DanmakuBlockStore.getAll());
    }
  }

  Future<void> _removeBlock(String id) async {
    await DanmakuBlockStore.remove(id);
    if (!mounted) return;
    setState(() => _blocks = DanmakuBlockStore.getAll());
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
              padding: const EdgeInsets.all(16),
              child: Text(
                '设置立即生效：直播间打开时读取，直播中修改也会实时更新。',
                style: TextStyle(color: theme.textSecondary, fontSize: 13),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const HaoSectionTitle('各平台弹幕开关'),
          SettingsGroup(
            children: [
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
                    if (!mounted) return;
                    setState(() => _enabled = DanmakuSettings.enabledMap());
                  },
                );
              }),
            ],
          ),
          const SizedBox(height: 20),
          const HaoSectionTitle('弹幕字号'),
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
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const HaoSectionTitle('弹幕不透明度'),
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
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const HaoSectionTitle('弹幕区域'),
          SettingsGroup(
            children: [
              ListTile(
                title: Text('弹幕区域', style: TextStyle(color: theme.textPrimary)),
                subtitle: Text(
                  '仅全屏时生效：弹幕在视频上覆盖的区域。竖屏时弹幕是下方列表，不受影响',
                  style: TextStyle(color: theme.textSecondary),
                ),
                trailing: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'full', label: Text('全屏')),
                    ButtonSegment(value: 'half', label: Text('上半屏')),
                    ButtonSegment(value: 'third', label: Text('上 1/3')),
                  ],
                  selected: {_area},
                  onSelectionChanged: (selected) async {
                    final v = selected.first;
                    await DanmakuSettings.setArea(v);
                    if (!mounted) return;
                    setState(() => _area = v);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const HaoSectionTitle('弹幕列表'),
          SettingsGroup(
            children: [
              ListTile(
                title: Text('列表样式', style: TextStyle(color: theme.textPrimary)),
                subtitle: Text(
                  '紧凑：一行一条；卡片：每条一张卡片',
                  style: TextStyle(color: theme.textSecondary),
                ),
                trailing: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'compact', label: Text('紧凑')),
                    ButtonSegment(value: 'card', label: Text('卡片')),
                  ],
                  selected: {_listStyle},
                  onSelectionChanged: (selected) async {
                    final v = selected.first;
                    await DanmakuSettings.setListStyle(v);
                    if (!mounted) return;
                    setState(() => _listStyle = v);
                  },
                ),
              ),
              ListTile(
                title: Text('行间距', style: TextStyle(color: theme.textPrimary)),
                subtitle: Text(
                  '紧密 / 标准 / 宽松',
                  style: TextStyle(color: theme.textSecondary),
                ),
                trailing: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'compact', label: Text('紧密')),
                    ButtonSegment(value: 'standard', label: Text('标准')),
                    ButtonSegment(value: 'loose', label: Text('宽松')),
                  ],
                  selected: {_listSpacing},
                  onSelectionChanged: (selected) async {
                    final v = selected.first;
                    await DanmakuSettings.setListSpacing(v);
                    if (!mounted) return;
                    setState(() => _listSpacing = v);
                  },
                ),
              ),
              SwitchListTile(
                title: Text(
                  '显示用户名',
                  style: TextStyle(color: theme.textPrimary),
                ),
                subtitle: Text(
                  '关闭后列表只显示弹幕内容',
                  style: TextStyle(color: theme.textSecondary),
                ),
                value: _showUsernames,
                activeThumbColor: theme.accent,
                onChanged: (v) async {
                  await DanmakuSettings.setShowUsernames(v);
                  if (!mounted) return;
                  setState(() => _showUsernames = v);
                },
              ),
            ],
          ),
          const SizedBox(height: 20),
          const HaoSectionTitle('内容过滤'),
          SettingsGroup(
            children: [
              SwitchListTile(
                title: Text(
                  '过滤相似弹幕',
                  style: TextStyle(color: theme.textPrimary),
                ),
                subtitle: Text(
                  '与刚显示过的弹幕相似（如加标点、数字变体）时隐藏',
                  style: TextStyle(color: theme.textSecondary),
                ),
                value: _similarityEnabled,
                activeThumbColor: theme.accent,
                onChanged: (v) async {
                  await DanmakuSettings.setSimilarityEnabled(v);
                  if (!mounted) return;
                  setState(() => _similarityEnabled = v);
                },
              ),
              ListTile(
                title: Text(
                  '相似度阈值',
                  style: TextStyle(color: theme.textPrimary),
                ),
                subtitle: Text(
                  '越高越严格（只挡更像的）；当前 $_similarityThreshold',
                  style: TextStyle(color: theme.textSecondary),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _similarityThreshold.toDouble(),
                      min: DanmakuSettings.minSimilarityThreshold.toDouble(),
                      max: DanmakuSettings.maxSimilarityThreshold.toDouble(),
                      divisions: 20,
                      label: '$_similarityThreshold',
                      activeColor: theme.accent,
                      onChanged: _similarityEnabled
                          ? (v) =>
                                setState(() => _similarityThreshold = v.round())
                          : null,
                      onChangeEnd: (v) =>
                          DanmakuSettings.setSimilarityThreshold(v.round()),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '$_similarityThreshold',
                      style: TextStyle(
                        color: theme.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
              SwitchListTile(
                title: Text(
                  '屏蔽纯表情弹幕',
                  style: TextStyle(color: theme.textPrimary),
                ),
                subtitle: Text(
                  '只由表情（或 [表情]）组成的弹幕不显示',
                  style: TextStyle(color: theme.textSecondary),
                ),
                value: _blockEmoteOnly,
                activeThumbColor: theme.accent,
                onChanged: (v) async {
                  await DanmakuSettings.setBlockEmoteOnly(v);
                  if (!mounted) return;
                  setState(() => _blockEmoteOnly = v);
                },
              ),
              SwitchListTile(
                title: Text(
                  '屏蔽超长弹幕',
                  style: TextStyle(color: theme.textPrimary),
                ),
                subtitle: Text(
                  '超过设定字数的弹幕不显示；当前上限 $_blockLongLength 字',
                  style: TextStyle(color: theme.textSecondary),
                ),
                value: _blockLong,
                activeThumbColor: theme.accent,
                onChanged: (v) async {
                  await DanmakuSettings.setBlockLong(v);
                  if (!mounted) return;
                  setState(() => _blockLong = v);
                },
              ),
              if (_blockLong)
                Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: _blockLongLength.toDouble(),
                        min: DanmakuSettings.minBlockLongLength.toDouble(),
                        max: DanmakuSettings.maxBlockLongLength.toDouble(),
                        divisions: 18,
                        label: '$_blockLongLength 字',
                        activeColor: theme.accent,
                        onChanged: (v) =>
                            setState(() => _blockLongLength = v.round()),
                        onChangeEnd: (v) =>
                            DanmakuSettings.setBlockLongLength(v.round()),
                      ),
                    ),
                    SizedBox(
                      width: 44,
                      child: Text(
                        '$_blockLongLength',
                        style: TextStyle(
                          color: theme.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              SwitchListTile(
                title: Text(
                  '斗鱼疑似机器人过滤',
                  style: TextStyle(color: theme.textPrimary),
                ),
                subtitle: Text(
                  '仅斗鱼：隐藏平台标记为疑似自动发送的弹幕',
                  style: TextStyle(color: theme.textSecondary),
                ),
                value: _douyuBotFilter,
                activeThumbColor: theme.accent,
                onChanged: (v) async {
                  await DanmakuSettings.setDouyuBotFilter(v);
                  if (!mounted) return;
                  setState(() => _douyuBotFilter = v);
                },
              ),
            ],
          ),
          const SizedBox(height: 20),
          const HaoSectionTitle('屏蔽管理'),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _blockInput,
                  decoration: InputDecoration(
                    hintText: '输入要屏蔽的词或用户名',
                    hintStyle: TextStyle(color: theme.textMuted),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  style: TextStyle(color: theme.textPrimary),
                  onSubmitted: (_) => _addBlock(),
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: _blockKind,
                items: const [
                  DropdownMenuItem(value: 'word', child: Text('关键词')),
                  DropdownMenuItem(value: 'user', child: Text('用户名')),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _blockKind = v);
                },
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _addBlock,
                style: FilledButton.styleFrom(backgroundColor: theme.accent),
                child: const Text('添加'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_blocks.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 4),
              child: Text('暂无屏蔽词', style: TextStyle(color: theme.textMuted)),
            )
          else
            SettingsGroup(
              children: [
                for (final entry in _blocks)
                  ListTile(
                    dense: true,
                    title: Text(
                      entry.text,
                      style: TextStyle(color: theme.textPrimary),
                    ),
                    subtitle: Text(
                      entry.isUser ? '用户名' : '关键词',
                      style: TextStyle(color: theme.textSecondary),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      color: theme.textSecondary,
                      tooltip: '删除',
                      onPressed: () => _removeBlock(entry.id),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 20),
          const HaoSectionTitle('暂无此设置'),
          SettingsGroup(
            children: [
              ListTile(
                title: Text('弹幕速度', style: TextStyle(color: theme.textPrimary)),
                subtitle: Text(
                  '当前弹幕为直播间下方的列表形式，没有滚动速度可调',
                  style: TextStyle(color: theme.textMuted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
