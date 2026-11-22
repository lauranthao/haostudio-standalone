// Song `···` action sheet (fix 15).
//
// Buttons, in order: 歌曲信息 (song info), 评论 (comments — opens the
// NetEase-style comments page: 精彩评论 on top, 最新评论 below, load
// more; chen 2026-11-17), 播放列表 (play list / queue),
// 播放模式 (cycles the five play modes — 顺序播放 / 列表循环 / 单曲循环 /
// 随机播放 / 单曲播放, M-P0-1), 睡眠定时 (M-P0-3), 下一首播放 (insert
// right after the current track, M-P0-4), 下载 (save to the device for
// offline playback, M-P0-5), 播放设置 (one tap deeper: 倍速 slider
// 0.5–2.0× + presets (M-P0-2, build 29: was 0.6–2.0; pitch stays
// correct — native TimeDomain algorithm), A-B 循环 / 歌词偏移 /
// 翻译显隐 / 淡入淡出 / Zap 开关 — the adjustments moved out because
// the sheet ran past one screen), 取消.
// There is NO 分享 (share) button in this sheet. Tapping 播放列表 closes
// the sheet and opens the floating queue panel above the player (Apple
// Music "Up Next" style).
//
// The sheet is opened from the player `···` AND from a long-press on a
// song row in the lists — see [openTrackMoreSheet], which shows the
// sheet and handles the chosen action in one call.

import '../../../core/theme/hao_radius.dart';
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../../core/theme/hao_themes.dart';
import '../../../core/theme/haptics.dart';
import '../../../core/theme/liquid_glass_theme.dart';
import '../../../widgets/glass_dialog.dart';
import '../../../widgets/native_switch.dart';
import '../../../services/music/bookmarks_store.dart';
import '../../../services/music/lyric_tools.dart';
import '../../../services/music/music_downloads.dart';
import '../../../services/music/music_models.dart';
import '../../../services/music/music_quality.dart';
import '../../../services/music/play_mode.dart';
import '../../../services/music/sleep_timer.dart';
import '../../../services/music/equalizer_store.dart';
import '../comments_page.dart';
import '../equalizer_page.dart';
import '../fm_service.dart';
import '../music_navigation.dart';
import '../music_player_controller.dart';
import '../player_expand_route.dart';
import 'sleep_timer_sheet.dart';
import 'music_image.dart';
import '../../../widgets/hao_sheet.dart';
import '../../../widgets/hao_slider.dart';

enum TrackMoreAction {
  info,
  comments,
  queue,
  playMode,
  sleepTimer,
  playNext,
  // Personal FM only: "不喜欢" (skip + never recommend again).
  dislike,
  download,
  // Bookmarks (1.1.6): saved positions in this song.
  bookmark,
  equalizer,
  cancel,
}

/// Compact long-press menu (Beans `SongCell` context menu pattern):
/// an anchored popup with the four most frequent actions — NOT the
/// full `···` sheet. Beans' menu is 下一首播放 / 添加到歌单 / 下载歌曲 /
/// 立即播放；we have no user-created playlists (the heart IS the
/// add-to-collection action), so the fourth slot is 收藏/取消收藏.
/// [rowContext] is the pressed row's context — the menu anchors to
/// the row, like the iOS context menu.
Future<void> openSongQuickMenu(BuildContext rowContext, Song song) async {
  final theme = HaoTheme.of(rowContext);
  final controller = MusicPlayerController.ensure();
  final box = rowContext.findRenderObject() as RenderBox?;
  final screen = MediaQuery.of(rowContext).size;
  final anchor = box == null
      ? const RelativeRect.fromLTRB(0, 200, 0, 200)
      : RelativeRect.fromRect(
          box.localToGlobal(Offset.zero) & box.size,
          Offset.zero & screen,
        );
  final isCurrent = controller.currentSong?.identityKey == song.identityKey;
  final isFav = controller.isFav(song);
  final picked = await showMenu<_QuickAction>(
    context: rowContext,
    position: anchor,
    color: theme.surfaceSolid,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(HaoRadius.large),
      side: BorderSide(color: theme.hairline),
    ),
    items: [
      PopupMenuItem(
        value: _QuickAction.playNext,
        child: _QuickRow(
          icon: Icons.queue_play_next,
          label: '下一首播放',
          theme: theme,
        ),
      ),
      PopupMenuItem(
        value: _QuickAction.download,
        child: _QuickRow(icon: Icons.download, label: '下载', theme: theme),
      ),
      if (!isCurrent)
        PopupMenuItem(
          value: _QuickAction.playNow,
          child: _QuickRow(icon: Icons.play_arrow, label: '立即播放', theme: theme),
        ),
      PopupMenuItem(
        value: _QuickAction.fav,
        child: _QuickRow(
          icon: isFav ? Icons.favorite : Icons.favorite_border,
          label: isFav ? '取消收藏' : '收藏',
          theme: theme,
        ),
      ),
    ],
  );
  if (picked == null || !rowContext.mounted) return;
  switch (picked) {
    case _QuickAction.playNext:
      await handleTrackMoreAction(rowContext, song, TrackMoreAction.playNext);
    case _QuickAction.download:
      await handleTrackMoreAction(rowContext, song, TrackMoreAction.download);
    case _QuickAction.playNow:
      // Queue-aware (Beans `SongCell` 立即播放): in the queue -> jump
      // to it; otherwise play the song on its own.
      final idx = controller.queue.indexWhere(
        (s) => s.identityKey == song.identityKey,
      );
      if (idx >= 0) {
        unawaited(controller.playIndex(idx));
      } else {
        unawaited(controller.playQueue([song], 0));
      }
      if (rowContext.mounted) {
        unawaited(openPlayerPage<void>(rowContext));
      }
    case _QuickAction.fav:
      await controller.toggleFav(song);
      if (rowContext.mounted) {
        ScaffoldMessenger.of(rowContext)
            .showSnackBar(SnackBar(content: Text(isFav ? '已取消收藏' : '已收藏')));
      }
  }
}

enum _QuickAction { playNext, download, playNow, fav }

/// One row of the quick menu: icon + label, Beans `Label` style.
class _QuickRow extends StatelessWidget {
  const _QuickRow({
    required this.icon,
    required this.label,
    required this.theme,
  });

  final IconData icon;
  final String label;
  final HaoTheme theme;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(shadows: HaoTheme.legibilityShadows(context), icon, color: theme.textPrimary, size: 20),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary, fontSize: 15)),
      ],
    );
  }
}

/// Show the `···` sheet for [song] and handle the chosen action.
///
/// [fromPlayer] is true when called from the player page: the 播放列表
/// action then just raises the floating queue panel. From a list page
/// it opens the player page first, so the panel has somewhere to float.
Future<void> openTrackMoreSheet(
  BuildContext context,
  Song song, {
  bool fromPlayer = false,
}) async {
  final action = await showTrackMoreSheet(context, song);
  if (action == null || !context.mounted) return;
  await handleTrackMoreAction(context, song, action, fromPlayer: fromPlayer);
}

/// Handle one [TrackMoreAction] picked from the sheet.
Future<void> handleTrackMoreAction(
  BuildContext context,
  Song song,
  TrackMoreAction action, {
  bool fromPlayer = false,
}) async {
  final controller = MusicPlayerController.ensure();
  switch (action) {
    case TrackMoreAction.info:
      await showSongInfoDialog(context, song);
    case TrackMoreAction.comments:
      if (context.mounted) {
        unawaited(
          Navigator.of(context).push(
            CupertinoPageRoute<void>(
              settings: const RouteSettings(name: musicSubPageRouteName),
              builder: (_) => SongCommentsPage(song: song),
            ),
          ),
        );
      }
    case TrackMoreAction.queue:
      if (controller.queue.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('播放列表是空的')));
        }
        return;
      }
      controller.showQueuePanel.value = true;
      if (!fromPlayer && context.mounted) {
        // The panel floats above the player page — open it first.
        unawaited(openPlayerPage<void>(context));
      }
    case TrackMoreAction.playMode:
      await controller.cyclePlayMode();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(controller.mode.label)));
      }
    case TrackMoreAction.sleepTimer:
      final picked = await showSleepTimerSheet(context);
      if (picked != null && context.mounted) {
        controller.setSleepTimer(picked);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              picked == SleepTimerOption.off
                  ? '睡眠定时已关闭'
                  : '睡眠定时：${controller.sleepLabel}',
            ),
          ),
        );
      }
    case TrackMoreAction.playNext:
      final ok = await controller.playNext(song);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(ok ? '已加入下一首播放' : '这首歌正在播放')));
      }
    case TrackMoreAction.dislike:
      await FmService.ensure().dislike(song);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已记为不喜欢，以后不再推荐')),
        );
      }
    case TrackMoreAction.equalizer:
      // Stage 3: opens the 10-band EQ page (same destination as the
      // settings playback-panel row). The sheet is already popped by
      // openTrackMoreSheet, so this push lands on the player/list page.
      if (context.mounted) {
        unawaited(
          Navigator.of(context).push(
            CupertinoPageRoute<void>(
              builder: (_) => const EqualizerPage(),
            ),
          ),
        );
      }
    case TrackMoreAction.download:
      if (controller.downloads.statusFor(song) == DownloadStatus.downloaded) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('这首歌已经下载过了')));
        }
        return;
      }
      final ok = await controller.downloads.download(song);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ok ? '已下载，可离线播放' : '下载失败，换一首试试')),
        );
      }
    case TrackMoreAction.bookmark:
      // Bookmarks (1.1.6): list / add / jump / delete for this song.
      if (context.mounted) {
        await showBookmarksDialog(context, song);
      }
    case TrackMoreAction.cancel:
      break;
  }
}

/// Icon per play mode (the label comes from PlayModeX.label).
IconData playModeIcon(PlayMode mode) {
  switch (mode) {
    case PlayMode.sequential:
      return Icons.format_list_bulleted;
    case PlayMode.listLoop:
      return Icons.repeat;
    case PlayMode.singleLoop:
      return Icons.repeat_one;
    case PlayMode.shuffle:
      return Icons.shuffle;
    case PlayMode.single:
      return Icons.looks_one;
  }
}

Future<TrackMoreAction?> showTrackMoreSheet(BuildContext context, Song song) {
  final theme = HaoTheme.of(context);
  final controller = MusicPlayerController.ensure();
  // Section header (Beans menu grouping): small muted label above
  // each group of actions.
  Widget section(String label) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 2),
      child: Text(
        label,
        style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
          color: theme.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
  return showHaoSheet<TrackMoreAction>(
    context: context,
    builder: (ctx) => GlassContainer(
      shape: const LiquidVerticalRoundedSuperellipse(
        topRadius: HaoRadius.sheet,
        bottomRadius: 0,
      ),
      settings: HaoLiquidGlass.ios27Settings(ctx),
      quality: GlassQuality.standard,
      useOwnLayer: true,
      child: Material(
        color: Colors.transparent,
        child: SafeArea(
          child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(HaoRadius.standard),
                    child: song.cover.isEmpty
                        ? Container(
                            width: 40,
                            height: 40,
                            color: theme.accentSoft,
                            child: Icon(shadows: HaoTheme.legibilityShadows(context),
                              Icons.music_note,
                              color: theme.textMuted,
                            ),
                          )
                        : Image(
                            image: MusicImageProvider(song.cover),
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Container(
                              width: 40,
                              height: 40,
                              color: theme.accentSoft,
                              child: Icon(shadows: HaoTheme.legibilityShadows(context),
                                Icons.music_note,
                                color: theme.textMuted,
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                            color: theme.textPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                            color: theme.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            section('播放'),
            ListTile(
              dense: true,
              leading: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.queue_play_next, color: theme.textPrimary),
              title: Text('下一首播放', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary)),
              onTap: () => Navigator.of(ctx).pop(TrackMoreAction.playNext),
            ),
            if (FmService.ensure().isFM.value ||
                FmService.ensure().isHeartbeat.value)
              ListTile(
                dense: true,
                leading: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.thumb_down, color: theme.textPrimary),
                title: Text('不喜欢', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary)),
                onTap: () => Navigator.of(ctx).pop(TrackMoreAction.dislike),
              ),
            Obx(
              () => ListTile(
                dense: true,
                leading: Icon(shadows: HaoTheme.legibilityShadows(context),
                  playModeIcon(controller.mode),
                  color: theme.textPrimary,
                ),
                title: Text(
                  controller.mode.label,
                  style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary),
                ),
                onTap: () => Navigator.of(ctx).pop(TrackMoreAction.playMode),
              ),
            ),
            Obx(
              () => ListTile(
                dense: true,
                leading: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.tune, color: theme.textPrimary),
                title: Text('播放设置', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary)),
                trailing: Text(
                  '${controller.speed.value.toStringAsFixed(2)}×',
                  style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textSecondary, fontSize: 13),
                ),
                onTap: () => unawaited(showPlaybackSettingsSheet(ctx)),
              ),
            ),
            const Divider(height: 1),
            section('歌曲'),
            AnimatedBuilder(
              animation: EqualizerStore.ensure(),
              builder: (context, _) => ListTile(
                dense: true,
                leading: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.tune, color: theme.textPrimary),
                title: Text('均衡器', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary)),
                trailing: Text(
                  EqualizerStore.ensure().enabled ? '已开启' : '已关闭',
                  style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textSecondary, fontSize: 13),
                ),
                onTap: () => Navigator.of(ctx).pop(TrackMoreAction.equalizer),
              ),
            ),
            ListTile(
              dense: true,
              leading: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.info_outline, color: theme.textPrimary),
              title: Text('歌曲信息', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary)),
              onTap: () => Navigator.of(ctx).pop(TrackMoreAction.info),
            ),
            ListTile(
              dense: true,
              leading: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.comment_outlined, color: theme.textPrimary),
              title: Text('评论', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary)),
              onTap: () => Navigator.of(ctx).pop(TrackMoreAction.comments),
            ),
            ListTile(
              dense: true,
              leading: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.bookmark_outline, color: theme.textPrimary),
              title: Text('书签', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary)),
              trailing: Text(
                BookmarksStore.countFor(song.identityKey) == 0
                    ? '添加书签'
                    : '${BookmarksStore.countFor(song.identityKey)} 个',
                style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textSecondary, fontSize: 13),
              ),
              onTap: () => Navigator.of(ctx).pop(TrackMoreAction.bookmark),
            ),
            const Divider(height: 1),
            section('列表'),
            ListTile(
              dense: true,
              leading: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.queue_music, color: theme.textPrimary),
              title: Text('播放列表', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary)),
              onTap: () => Navigator.of(ctx).pop(TrackMoreAction.queue),
            ),
            Obx(() {
              final option = controller.sleepOption.value;
              final remaining = controller.sleepRemaining.value;
              final subtitle = option == SleepTimerOption.off
                  ? '未设置'
                  : option == SleepTimerOption.queueEnd
                  ? '到歌单结束'
                  : remaining != null
                  ? '剩余 ${SleepTimer.formatRemaining(remaining)}'
                  : option.label;
              return ListTile(
                dense: true,
                leading: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.timer, color: theme.textPrimary),
                title: Text('睡眠定时', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary)),
                trailing: Text(
                  subtitle,
                  style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textSecondary, fontSize: 13),
                ),
                onTap: () => Navigator.of(ctx).pop(TrackMoreAction.sleepTimer),
              );
            }),
            Obx(() {
              final st = controller.downloads.statusFor(song);
              final prog = controller.downloads.progress[song.identityKey];
              final subtitle = switch (st) {
                DownloadStatus.downloaded => '已下载',
                DownloadStatus.downloading =>
                  prog != null ? '下载中 ${(prog * 100).round()}%' : '下载中…',
                DownloadStatus.failed => '下载失败，点按重试',
                DownloadStatus.notDownloaded => '保存到本机，离线播放',
              };
              return ListTile(
                dense: true,
                leading: Icon(shadows: HaoTheme.legibilityShadows(context),
                  st == DownloadStatus.downloaded
                      ? Icons.download_done
                      : Icons.download,
                  color: theme.textPrimary,
                ),
                title: Text('下载', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary)),
                trailing: Text(
                  subtitle,
                  style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textSecondary, fontSize: 13),
                ),
                onTap: () => Navigator.of(ctx).pop(TrackMoreAction.download),
              );
            }),
            const Divider(height: 1),
            ListTile(
              dense: true,
              leading: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.close, color: theme.textPrimary),
              title: Text('取消', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary)),
              onTap: () => Navigator.of(ctx).pop(TrackMoreAction.cancel),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
    ),
    ),
  );
}

/// Playback settings sub-sheet (build 29): the adjustment controls
/// that used to live inline in the `···` sheet — speed slider +
/// presets, A-B loop, lyric offset, translation, fade, Zap. With
/// them inline the `···` sheet ran past one screen on chen's phone
/// (sleep timer + cancel below the fold), so adjustments live one
/// tap deeper here; the `···` sheet keeps only actions and fits
/// first screen. Opened stacked on top of the `···` sheet (no pop),
/// so closing it returns to the sheet.
Future<void> showPlaybackSettingsSheet(BuildContext context) async {
  final theme = HaoTheme.of(context);
  final controller = MusicPlayerController.ensure();
  await showHaoSheet<void>(
    context: context,
    builder: (ctx) => GlassContainer(
      shape: const LiquidVerticalRoundedSuperellipse(
        topRadius: HaoRadius.sheet,
        bottomRadius: 0,
      ),
      settings: HaoLiquidGlass.ios27Settings(ctx),
      quality: GlassQuality.standard,
      useOwnLayer: true,
      child: Material(
        color: Colors.transparent,
        child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                  child: Center(
                    child: Text(
                      '播放设置',
                      style: TextStyle(
                        shadows: HaoTheme.legibilityShadows(context),
                        color: theme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            Obx(() {
              final speed = controller.speed.value;
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(shadows: HaoTheme.legibilityShadows(context), Icons.speed, color: theme.textPrimary),
                        const SizedBox(width: 16),
                        Text('倍速', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary)),
                        const Spacer(),
                        Text(
                          '${speed.toStringAsFixed(2)}×',
                          style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                            color: theme.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    SliderTheme(
                      data: SliderTheme.of(ctx).copyWith(
                        trackHeight: 4,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 7,
                        ),
                        activeTrackColor: theme.accent,
                        inactiveTrackColor: theme.accentSoft,
                        thumbColor: theme.accent,
                        overlayColor: theme.accentSoft,
                      ),
                      child: HaoSlider(
                        value: speed,
                        min: 0.5,
                        max: 2.0,
                        divisions: 30,
                        label: '${speed.toStringAsFixed(2)}×',
                        activeColor: theme.accent,
                        onChanged: (v) => unawaited(controller.setSpeed(v)),
                        onChangeEnd: (v) =>
                            HaoHaptics.sliderEnd(v, 0.5, 2.0),
                      ),
                    ),
                    Row(
                      spacing: 6,
                      children: [
                        for (final preset
                            in MusicPlayerController.speedPresets)
                          Expanded(
                            child: GestureDetector(
                              onTap: () =>
                                  unawaited(controller.setSpeed(preset)),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 5,
                                ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(999),
                                color: speed == preset
                                    ? theme.accent.withValues(alpha: 0.14)
                                    : theme.textPrimary.withValues(
                                        alpha: 0.035,
                                      ),
                                border: Border.all(
                                  color: speed == preset
                                      ? theme.accent.withValues(alpha: 0.42)
                                      : theme.textPrimary.withValues(
                                          alpha: 0.06,
                                        ),
                                  width: 0.8,
                                ),
                              ),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  '$preset×',
                                  style: TextStyle(
                                    shadows: HaoTheme.legibilityShadows(context),
                                    color: speed == preset
                                        ? theme.accent
                                        : theme.textPrimary,
                                    fontSize: 12,
                                    fontWeight: speed == preset
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
            Obx(() {
              controller.abLoopVersion.value;
              final loop = controller.abLoop;
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(shadows: HaoTheme.legibilityShadows(context), Icons.repeat, color: theme.textPrimary),
                        const SizedBox(width: 16),
                        Text('A-B 循环', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary)),
                        const Spacer(),
                        Text(
                          loop.label.isEmpty ? '未设置' : loop.label,
                          style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                            color: theme.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _AbButton(
                          label: '设 A 点',
                          theme: theme,
                          active: loop.hasA,
                          onTap: controller.setAbPointA,
                        ),
                        const SizedBox(width: 8),
                        _AbButton(
                          label: '设 B 点',
                          theme: theme,
                          active: loop.isActive,
                          onTap: controller.setAbPointB,
                        ),
                        const SizedBox(width: 8),
                        _AbButton(
                          label: '清除',
                          theme: theme,
                          active: false,
                          onTap: controller.clearAbLoop,
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
            Obx(() {
              final offset = controller.lyricOffsetMs.value;
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(shadows: HaoTheme.legibilityShadows(context), Icons.lyrics_outlined, color: theme.textPrimary),
                        const SizedBox(width: 16),
                        Text('歌词偏移', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary)),
                        const Spacer(),
                        Text(
                          LyricDisplay.offsetLabel(offset),
                          style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                            color: theme.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    SliderTheme(
                      data: SliderTheme.of(ctx).copyWith(
                        trackHeight: 4,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 7,
                        ),
                        activeTrackColor: theme.accent,
                        inactiveTrackColor: theme.accentSoft,
                        thumbColor: theme.accent,
                        overlayColor: theme.accentSoft,
                      ),
                      child: HaoSlider(
                        value: offset.toDouble(),
                        min: -5000,
                        max: 5000,
                        divisions: 100,
                        label: LyricDisplay.offsetLabel(offset),
                        activeColor: theme.accent,
                        onChanged: (v) => unawaited(
                          controller.setLyricOffsetMs(v.round()),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
            Obx(
              () => ListTile(
                leading: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.translate, color: theme.textPrimary),
                title: Text('歌词翻译', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary)),
                trailing: HaoNativeSwitch(
                  value: controller.showLyricTranslation.value,
                  onChanged: (v) =>
                      unawaited(controller.setShowLyricTranslation(v)),
                  activeColor: theme.accent,
                  semanticsLabel: '歌词翻译',
                ),
              ),
            ),
            Obx(
              () => ListTile(
                leading: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.blur_on, color: theme.textPrimary),
                title: Text('淡入淡出', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary)),
                subtitle: Text(
                  '暂停 / 恢复 / 切歌时渐变音量',
                  style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textSecondary, fontSize: 12),
                ),
                trailing: HaoNativeSwitch(
                  value: controller.fadeEnabled.value,
                  onChanged: (v) =>
                      unawaited(controller.setFadeEnabled(v)),
                  activeColor: theme.accent,
                  semanticsLabel: '淡入淡出',
                ),
              ),
            ),
            Obx(
              () => ListTile(
                leading: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.bolt, color: theme.textPrimary),
                title: Text('Zap 快速发现', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary)),
                subtitle: Text(
                  '每首播 5 秒试听，快速扫歌',
                  style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textSecondary, fontSize: 12),
                ),
                trailing: HaoNativeSwitch(
                  value: controller.zapActive.value,
                  onChanged: (v) async {
                    if (v) {
                      await controller.startZapFromLibrary();
                    } else {
                      controller.stopZap();
                    }
                  },
                  activeColor: theme.accent,
                  semanticsLabel: 'Zap 快速发现',
                ),
              ),
            ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.close, color: theme.textPrimary),
                  title: Text('取消', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary)),
                  onTap: () => Navigator.of(ctx).pop(),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Small pill button for the A-B loop row (build 29).
class _AbButton extends StatelessWidget {
  const _AbButton({
    required this.label,
    required this.theme,
    required this.active,
    required this.onTap,
  });

  final String label;
  final HaoTheme theme;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: active
                ? theme.accent.withValues(alpha: 0.14)
                : theme.textPrimary.withValues(alpha: 0.035),
            border: Border.all(
              color: active
                  ? theme.accent.withValues(alpha: 0.42)
                  : theme.textPrimary.withValues(alpha: 0.06),
              width: 0.8,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              shadows: HaoTheme.legibilityShadows(context),
              color: active ? theme.accent : theme.textPrimary,
              fontSize: 13,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

/// Bookmarks dialog (1.1.6): this song's saved positions.
///
/// Tap a row to jump there (loads the song first when it is not
/// playing), × deletes that bookmark. 添加书签 saves the current
/// position — it only shows for the song now playing, because any
/// other song has no position to save. Bookmarks are never cleared
/// by finishing the track (unlike the automatic resume position).
Future<void> showBookmarksDialog(BuildContext context, Song song) async {
  final theme = HaoTheme.of(context);
  final controller = MusicPlayerController.ensure();
  await showGlassDialog<void>(
    context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final marks = controller.bookmarksFor(song);
        final isCurrent =
            controller.currentSong?.identityKey == song.identityKey;
        final pos = controller.position.value.inSeconds;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '书签',
              style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                color: theme.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                color: theme.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 8),
            if (isCurrent && pos > 0)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.bookmark_add_outlined, color: theme.textPrimary),
                title: Text(
                  '添加书签（${BookmarksStore.formatLabel(pos)}）',
                  style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary),
                ),
                onTap: () async {
                  await controller.addBookmark(song);
                  setState(() {});
                },
              ),
            if (marks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  '暂无书签',
                  style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textSecondary),
                ),
              ),
            for (final mark in marks)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.bookmark, color: theme.textPrimary),
                title: Text(
                  mark.label,
                  style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary),
                ),
                trailing: IconButton(
                  icon: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.close, color: theme.textSecondary, size: 20),
                  onPressed: () async {
                    await controller.deleteBookmark(song, mark);
                    setState(() {});
                  },
                ),
                onTap: () async {
                  if (ctx.mounted) Navigator.of(ctx).pop();
                  await controller.jumpToBookmark(song, mark.position);
                },
              ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text('关闭', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.accent)),
                ),
              ],
            ),
          ],
        );
      },
    ),
  );
}

/// Song info dialog (歌曲信息): title/artist/album/duration/source/quality.
Future<void> showSongInfoDialog(BuildContext context, Song song) async {
  final theme = HaoTheme.of(context);
  final controller = MusicPlayerController.ensure();
  final dur = song.dur > 0
      ? formatDuration(song.dur)
      : formatDuration(controller.duration.value.inSeconds);
  final rows = <(String, String)>[
    ('专辑', song.album.isEmpty ? '—' : song.album),
    ('时长', dur),
    ('音源', '${song.platform.displayName}音乐'),
    ('音质', controller.actualQuality.value.label),
    ('发行', '—'),
  ];
  await showGlassDialog<void>(
    context,
    builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(HaoRadius.large),
                child: song.cover.isEmpty
                    ? Container(
                        width: 64,
                        height: 64,
                        color: theme.accentSoft,
                        child: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.music_note, color: theme.textMuted),
                      )
                    : Image(
                        image: MusicImageProvider(song.cover),
                        width: 64,
                        height: 64,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          width: 64,
                          height: 64,
                          color: theme.accentSoft,
                          child: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.music_note, color: theme.textMuted),
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      song.title,
                      style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                        color: theme.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      song.artist,
                      style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(label, style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textMuted)),
                  Flexible(
                    child: Text(
                      value,
                      style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                        color: theme.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text('关闭', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.accent)),
              ),
            ],
          ),
        ],
      ),
  );
}
