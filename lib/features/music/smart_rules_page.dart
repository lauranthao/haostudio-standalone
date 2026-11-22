// Smart Rules page (build 29, music) — 按规则自动生成队列/歌单.
//
// Each rule builds its queue from local data only (favourites,
// 最近播放, listen log — see SmartRules.build): no network, no
// login, no server. Tapping a rule plays its queue and opens the
// player. An empty rule (e.g. no favourites yet) shows its count
// as 0 and is disabled, so the page never offers a dead tap.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import '../../services/music/multi_queue_store.dart';
import '../../services/music/music_models.dart';
import '../../services/music/music_store.dart';
import '../../services/music/smart_rules.dart';
import 'music_player_controller.dart';
import 'player_expand_route.dart';
import 'widgets/mini_player_bar.dart';
import '../../widgets/hao_nav_bar.dart';

class SmartRulesPage extends StatefulWidget {
  const SmartRulesPage({super.key});

  @override
  State<SmartRulesPage> createState() => _SmartRulesPageState();
}

class _SmartRulesPageState extends State<SmartRulesPage> {
  MusicPlayerController get _player => MusicPlayerController.ensure();

  List<Song> _queueFor(SmartRule rule) => SmartRules.build(
        rule,
        favourites: MusicStore.getFavSongs(),
        recent: MusicStore.getRecent(),
        listenLog: MusicStore.getListenLog(),
      );

  Future<void> _playRule(SmartRule rule) async {
    final songs = _queueFor(rule);
    if (songs.isEmpty) return;
    await _player.playQueue(
      songs,
      0,
      label: '智能歌单 · ${rule.title}',
      sourceKey: QueueSource.smartRule,
    );
    if (!mounted) return;
    unawaited(openPlayerPage<void>(context));
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Scaffold(
      appBar: HaoNavBar(
        title: '智能歌单',
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MiniPlayerBar.bottomClearanceFor(context),
        ),
        children: [
          Text(
            '按规则从你的收藏和听歌记录里自动拼歌单，全部本地生成，不联网。',
            style: TextStyle(color: theme.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 16),
          for (final rule in SmartRule.values) ...[
            _RuleRow(
              rule: rule,
              count: _queueFor(rule).length,
              onTap: () => unawaited(_playRule(rule)),
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

class _RuleRow extends StatelessWidget {
  const _RuleRow({
    required this.rule,
    required this.count,
    required this.onTap,
  });

  final SmartRule rule;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final enabled = count > 0;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: theme.textPrimary.withValues(alpha: 0.04),
            border: Border.all(
              color: theme.hairline,
              width: 0.8,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rule.title,
                      style: TextStyle(
                        shadows: HaoTheme.legibilityShadows(context),
                        color: enabled
                            ? theme.textPrimary
                            : theme.textMuted,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      rule.subtitle,
                      style: TextStyle(
                        color: theme.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '$count 首',
                style: TextStyle(
                  shadows: HaoTheme.legibilityShadows(context),
                  color: enabled ? theme.accent : theme.textMuted,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right,
                shadows: HaoTheme.legibilityShadows(context),
                color: theme.textMuted,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
