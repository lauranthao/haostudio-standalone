// Danmaku settings — per-platform on/off, font size, opacity, area.
//
// Every control below saves to Hive immediately via [DanmakuSettings]
// and the live room honours it (live_room_page.dart): the per-platform
// switch gates the transport, font size / opacity style the list, the
// area caps the fullscreen floating danmaku (BarrageConfig.area), and
// changes apply while a room is open, no restart. Speed / stroke /
// colour / max count live in the 全屏飞弹幕 section below (stroke /
// speed apply ONLY to the fullscreen flying danmaku; max count caps
// the portrait list too, and colour mode also styles the list text)
// and each row says so next to it, like area does.
// The area does NOT move the portrait list — that list is a chat
// list below the video, not an overlay; it only limits the
// fullscreen flying danmaku, and the UI says so.

import 'package:flutter/material.dart';

import '../../core/storage/hive_store.dart';
import '../../core/theme/hao_themes.dart';
import '../../core/theme/haptics.dart';
import '../../widgets/hao_segmented_control.dart';
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

  // S1b fullscreen flying danmaku.
  late bool _stroke;
  late double _strokeWidth;
  late double _speed;
  late int _maxCount;
  late String _colorMode;

  // Occlusion avoidance (MPV only, default off) — the key lives in
  // HiveKeys (hive_store.dart); no DanmakuSettings wrapper exists,
  // so this page reads/writes it via HiveStore directly.
  late bool _occlusionAvoidance;

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
    _stroke = DanmakuSettings.stroke();
    _strokeWidth = DanmakuSettings.strokeWidth();
    _speed = DanmakuSettings.speed();
    _maxCount = DanmakuSettings.maxCount();
    _colorMode = DanmakuSettings.colorMode();
    _occlusionAvoidance = HiveStore.getBool(
      HiveKeys.danmakuOcclusionAvoidance,
      false,
    );
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
      appBar: AppBar(title: const Text('弹幕设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const HaoSectionTitle('弹幕开关'),
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
                  value: on,
                  activeThumbColor: theme.accent,
                  onChanged: (v) async {
                    await DanmakuSettings.setEnabled(id, v);
                    if (!mounted) return;
                    setState(() => _enabled = DanmakuSettings.enabledMap());
                  },
                );
              }),
              // VOD ("影视弹幕") — same Hive map, its own key, default
              // OFF. Not a live platform, so it is not in
              // Sites.supportedSiteIds and gets its own row.
              SwitchListTile(
                title: Text(
                  '影视弹幕',
                  style: TextStyle(color: theme.textPrimary),
                ),
                value: _enabled[DanmakuSettings.vodSiteId] ?? false,
                activeThumbColor: theme.accent,
                onChanged: (v) async {
                  await DanmakuSettings.setEnabled(
                    DanmakuSettings.vodSiteId,
                    v,
                  );
                  if (!mounted) return;
                  setState(() => _enabled = DanmakuSettings.enabledMap());
                },
              ),
              // 弹幕防遮挡 (1.1.6, MPV only, VOD + live): HiveKeys
              // key, default off — see the comment on the key in
              // hive_store.dart. No DanmakuSettings wrapper, so the
              // switch reads/writes HiveStore directly.
              SwitchListTile(
                title: Text(
                  '弹幕防遮挡',
                  style: TextStyle(color: theme.textPrimary),
                ),
                subtitle: Text(
                  '仅 MPV 生效（点播 + 直播）；人物快速移动时约 100–200ms 残影',
                  style: TextStyle(color: theme.textSecondary),
                ),
                value: _occlusionAvoidance,
                activeThumbColor: theme.accent,
                onChanged: (v) async {
                  await HiveStore.put(
                    HiveKeys.danmakuOcclusionAvoidance,
                    v,
                  );
                  if (!mounted) return;
                  setState(() => _occlusionAvoidance = v);
                },
              ),
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
                  onChangeEnd: (v) {
                    DanmakuSettings.setFontSize(v);
                    HaoHaptics.sliderEnd(
                      v,
                      DanmakuSettings.minFontSize,
                      DanmakuSettings.maxFontSize,
                    );
                  },
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
                  onChangeEnd: (v) {
                    DanmakuSettings.setOpacity(v);
                    HaoHaptics.sliderEnd(
                      v,
                      DanmakuSettings.minOpacity,
                      DanmakuSettings.maxOpacity,
                    );
                  },
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
                  '仅全屏时生效',
                  style: TextStyle(color: theme.textSecondary),
                ),
              ),
              // Four segments no longer fit as a ListTile trailing
              // (the button consumed the whole tile width and Flutter
              // asserts). Its own full-width row below the title.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: HaoSegmentedControl<String>(
                  segments: const [
                    HaoSegment(value: 'full', label: '全屏'),
                    HaoSegment(value: 'half', label: '上半屏'),
                    HaoSegment(value: 'third', label: '上 1/3'),
                    HaoSegment(value: 'fifth', label: '上 1/5'),
                  ],
                  value: _area,
                  onChanged: (v) async {
                    await DanmakuSettings.setArea(v);
                    if (!mounted) return;
                    setState(() => _area = v);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const HaoSectionTitle('全屏飞弹幕'),
          SettingsGroup(
            children: [
              SwitchListTile(
                title: Text(
                  '描边',
                  style: TextStyle(color: theme.textPrimary),
                ),
                subtitle: Text(
                  '仅全屏飞弹幕生效',
                  style: TextStyle(color: theme.textSecondary),
                ),
                value: _stroke,
                activeThumbColor: theme.accent,
                onChanged: (v) async {
                  await DanmakuSettings.setStroke(v);
                  if (!mounted) return;
                  setState(() => _stroke = v);
                },
              ),
              ListTile(
                title: Text(
                  '描边宽度',
                  style: TextStyle(color: theme.textPrimary),
                ),
                subtitle: Text(
                  '仅全屏飞弹幕生效；描边关闭时不可调',
                  style: TextStyle(color: theme.textSecondary),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _strokeWidth,
                      min: DanmakuSettings.minStrokeWidth,
                      max: DanmakuSettings.maxStrokeWidth,
                      divisions: 15,
                      label: _strokeWidth.toStringAsFixed(1),
                      activeColor: theme.accent,
                      onChanged: _stroke
                          ? (v) => setState(() => _strokeWidth = v)
                          : null,
                      onChangeEnd: (v) {
                        DanmakuSettings.setStrokeWidth(v);
                        HaoHaptics.sliderEnd(
                          v,
                          DanmakuSettings.minStrokeWidth,
                          DanmakuSettings.maxStrokeWidth,
                        );
                      },
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      _strokeWidth.toStringAsFixed(1),
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
              ListTile(
                title: Text(
                  '弹幕速度',
                  style: TextStyle(color: theme.textPrimary),
                ),
                subtitle: Text(
                  '仅全屏飞弹幕生效；不是播放速度',
                  style: TextStyle(color: theme.textSecondary),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _speed,
                      min: DanmakuSettings.minSpeed,
                      max: DanmakuSettings.maxSpeed,
                      divisions: 15,
                      label: '×${_speed.toStringAsFixed(1)}',
                      activeColor: theme.accent,
                      onChanged: (v) => setState(() => _speed = v),
                      onChangeEnd: (v) {
                        DanmakuSettings.setSpeed(v);
                        HaoHaptics.sliderEnd(
                          v,
                          DanmakuSettings.minSpeed,
                          DanmakuSettings.maxSpeed,
                        );
                      },
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '×${_speed.toStringAsFixed(1)}',
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
              ListTile(
                title: Text(
                  '最大数量',
                  style: TextStyle(color: theme.textPrimary),
                ),
                subtitle: Text(
                  '竖屏列表与全屏飞弹幕共用上限（飞弹幕最多 ${DanmakuSettings.enginePoolMaxSize} 条）',
                  style: TextStyle(color: theme.textSecondary),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _maxCount.toDouble(),
                      min: DanmakuSettings.minMaxCount.toDouble(),
                      max: DanmakuSettings.maxMaxCount.toDouble(),
                      divisions: 18,
                      label: '$_maxCount',
                      activeColor: theme.accent,
                      onChanged: (v) =>
                          setState(() => _maxCount = v.round()),
                      onChangeEnd: (v) {
                        DanmakuSettings.setMaxCount(v.round());
                        HaoHaptics.sliderEnd(
                          v,
                          DanmakuSettings.minMaxCount.toDouble(),
                          DanmakuSettings.maxMaxCount.toDouble(),
                        );
                      },
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '$_maxCount',
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
              ListTile(
                title: Text(
                  '颜色模式',
                  style: TextStyle(color: theme.textPrimary),
                ),
                subtitle: Text(
                  '仅全屏飞弹幕与列表正文生效，用户名保持主题色',
                  style: TextStyle(color: theme.textSecondary),
                ),
              ),
              // Full-width row below the title: the segmented control
              // does not fit as a ListTile trailing (Flutter asserts
              // it consumes the whole tile width) — same as 弹幕区域 above.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: HaoSegmentedControl<String>(
                  segments: const [
                    HaoSegment(
                      value: DanmakuSettings.colorModeUniform,
                      label: '统一色',
                    ),
                    HaoSegment(
                      value: DanmakuSettings.colorModePlatform,
                      label: '平台原色',
                    ),
                  ],
                  value: _colorMode,
                  onChanged: (v) async {
                    await DanmakuSettings.setColorMode(v);
                    if (!mounted) return;
                    setState(() => _colorMode = v);
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
              ),
              // Full-width row below the title: the segmented control
              // does not fit as a ListTile trailing (Flutter asserts
              // it consumes the whole tile width) — same as 弹幕区域 above.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: HaoSegmentedControl<String>(
                  segments: const [
                    HaoSegment(value: 'compact', label: '一行一条'),
                    HaoSegment(value: 'card', label: '每条一卡'),
                  ],
                  value: _listStyle,
                  onChanged: (v) async {
                    await DanmakuSettings.setListStyle(v);
                    if (!mounted) return;
                    setState(() => _listStyle = v);
                  },
                ),
              ),
              ListTile(
                title: Text('行间距', style: TextStyle(color: theme.textPrimary)),
              ),
              // Full-width row below the title — same trailing-width
              // reason as 列表样式 above.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: HaoSegmentedControl<String>(
                  segments: const [
                    HaoSegment(value: 'compact', label: '紧密'),
                    HaoSegment(value: 'standard', label: '标准'),
                    HaoSegment(value: 'loose', label: '宽松'),
                  ],
                  value: _listSpacing,
                  onChanged: (v) async {
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
                  '越高越严格（只挡更像的）',
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
                      onChangeEnd: (v) {
                        DanmakuSettings.setSimilarityThreshold(v.round());
                        HaoHaptics.sliderEnd(
                          v,
                          DanmakuSettings.minSimilarityThreshold.toDouble(),
                          DanmakuSettings.maxSimilarityThreshold.toDouble(),
                        );
                      },
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
                  '超过设定字数的弹幕不显示',
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
                        onChangeEnd: (v) {
                          DanmakuSettings.setBlockLongLength(v.round());
                          HaoHaptics.sliderEnd(
                            v,
                            DanmakuSettings.minBlockLongLength.toDouble(),
                            DanmakuSettings.maxBlockLongLength.toDouble(),
                          );
                        },
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
        ],
      ),
    );
  }
}
