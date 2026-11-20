// In-app update log page (chen 2026-11-20, Beans screenshot).
//
// Structure copied from the equalizer page (the app's other pushed
// sub-page): Scaffold + centred AppBar title + 完成 dismiss button
// (accent text, Beans .confirmationAction Done), ListView padding
// h16 / top 12 / bottom 32, cards spaced 14, every card glass
// radius 18, padding 14. One card per version, newest first.
// Version number and section headers use the theme accent (never a
// hardcoded gold); the + bullets are Icons.add_circle in accent, so
// the plus is knocked out of the disc and stays readable in all
// 4 themes x light/dark. Data is bundled (lib/app/changelog.dart),
// so the page works offline. Chinese only — the app has no i18n.

import 'package:flutter/material.dart';

import '../../app/changelog.dart';
import '../../core/theme/appearance_store.dart';
import '../../core/theme/glass.dart';
import '../../core/theme/hao_themes.dart';

class ChangelogPage extends StatelessWidget {
  const ChangelogPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Scaffold(
      backgroundColor: tabScaffoldBackground(context),
      appBar: AppBar(
        title: const Text('更新日志'),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('完成', style: TextStyle(color: theme.accent)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          for (var i = 0; i < kChangelog.length; i++) ...[
            if (i > 0) const SizedBox(height: 14),
            _VersionCard(entry: kChangelog[i]),
          ],
        ],
      ),
    );
  }
}

class _VersionCard extends StatelessWidget {
  const _VersionCard({required this.entry});

  final ChangelogEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GlassCard(
      radius: 18,
      quality: GlassCardQuality.standard,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.version,
            style: TextStyle(
              color: theme.accent,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            entry.title,
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (entry.features.isNotEmpty) ...[
            const SizedBox(height: 12),
            _Section(items: entry.features, title: '新增功能'),
          ],
          if (entry.fixes.isNotEmpty) ...[
            if (entry.features.isNotEmpty) ...[
              const SizedBox(height: 12),
              Divider(color: theme.hairline, height: 1),
              const SizedBox(height: 12),
            ] else
              const SizedBox(height: 12),
            _Section(items: entry.fixes, title: '问题修复'),
          ],
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.items, required this.title});

  final List<String> items;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: theme.accent,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.add_circle,
                  size: 18,
                  color: theme.accent,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  items[i],
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: 15,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
