// Downloads page (M-P0-5) — offline songs.
//
// Entry: the 已下载 card on the music home (inside 我的歌单).
// Lists downloaded songs (newest first) plus in-flight / failed
// downloads. Each row shows its download status icon: downloading
// with progress, downloaded ✓, failed with a retry tap. Tapping a
// downloaded row plays it from the local file; the delete button
// removes the file and its index entry. Filter chips: 全部 / 已下载 /
// 下载中. Empty state is honest: "还没有下载的歌曲".

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/theme/hao_themes.dart';
import '../../services/music/music_downloads.dart';
import '../../services/music/music_models.dart';
import '../../widgets/glass_dialog.dart';
import '../settings/cache_service.dart';
import 'music_player_controller.dart';
import 'music_player_sheet.dart';
import 'widgets/music_image.dart';

enum _DownloadFilter { all, done, downloading }

extension on _DownloadFilter {
  String get label {
    switch (this) {
      case _DownloadFilter.all:
        return '全部';
      case _DownloadFilter.done:
        return '已下载';
      case _DownloadFilter.downloading:
        return '下载中';
    }
  }
}

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  var _filter = _DownloadFilter.all;
  var _totalBytes = 0;

  MusicPlayerController get _player => MusicPlayerController.ensure();
  MusicDownloadService get _service => _player.downloads;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    await _service.refresh();
    final total = await _service.totalBytes();
    if (!mounted) return;
    setState(() => _totalBytes = total);
  }

  void _playSong(Song song, List<Song> songs) {
    final idx = songs.indexWhere((s) => s.identityKey == song.identityKey);
    unawaited(
      _player.playQueue(songs, idx < 0 ? 0 : idx, label: '已下载'),
    );
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const MusicPlayerPage()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackground,
      appBar: AppBar(title: const Text('已下载')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Obx(
                  () => Text(
                    '共 ${_service.downloaded.length} 首 · '
                    '${CacheService.formatBytes(_totalBytes)}',
                    style: TextStyle(
                      color: theme.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ),
                const Spacer(),
                for (final f in _DownloadFilter.values)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: ChoiceChip(
                      label: Text(f.label),
                      selected: _filter == f,
                      onSelected: (_) =>
                          setState(() => _filter = f),
                      selectedColor: theme.accentSoft,
                      side: BorderSide(color: theme.hairline),
                      labelStyle: TextStyle(
                        color: _filter == f
                            ? theme.accent
                            : theme.textSecondary,
                        fontSize: 13,
                        fontWeight: _filter == f
                            ? FontWeight.w700
                            : FontWeight.w400,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Obx(() {
              // Merge: downloaded entries + in-flight / failed rows.
              final rows = <_DownloadRow>[];
              for (final e in _service.downloaded) {
                rows.add(
                  _DownloadRow(
                    song: e.song,
                    status: DownloadStatus.downloaded,
                    progress: null,
                  ),
                );
              }
              for (final entry in _service.activeSongs.entries) {
                final key = entry.key;
                if (_service.downloaded
                    .any((e) => e.key == key)) {
                  continue;
                }
                final st = _service.status[key] ??
                    DownloadStatus.notDownloaded;
                if (st == DownloadStatus.downloaded) continue;
                rows.add(
                  _DownloadRow(
                    song: entry.value,
                    status: st,
                    progress: _service.progress[key],
                  ),
                );
              }
              final filtered = rows.where((r) {
                switch (_filter) {
                  case _DownloadFilter.all:
                    return true;
                  case _DownloadFilter.done:
                    return r.status == DownloadStatus.downloaded;
                  case _DownloadFilter.downloading:
                    return r.status == DownloadStatus.downloading ||
                        r.status == DownloadStatus.failed;
                }
              }).toList();
              if (filtered.isEmpty) {
                return Center(
                  child: Text(
                    _filter == _DownloadFilter.all
                        ? '还没有下载的歌曲\n在播放器 ··· 菜单里点「下载」'
                        : '这里没有歌曲',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: theme.textMuted,
                      fontSize: 15,
                    ),
                  ),
                );
              }
              return ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (ctx, i) {
                  final row = filtered[i];
                  return _buildRow(theme, row);
                },
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(HaoTheme theme, _DownloadRow row) {
    final song = row.song;
    final isDone = row.status == DownloadStatus.downloaded;
    return InkWell(
      onTap: isDone
          ? () => _playSong(
                song,
                _service.downloaded.map((e) => e.song).toList(),
              )
          : row.status == DownloadStatus.failed
              ? () async {
                  await _service.download(song);
                  await _refresh();
                }
              : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: song.cover.isEmpty
                  ? Container(
                      width: 48,
                      height: 48,
                      color: theme.accentSoft,
                      child: Icon(
                        Icons.music_note,
                        color: theme.textMuted,
                      ),
                    )
                  : Image(
                      image: MusicImageProvider(song.cover),
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        width: 48,
                        height: 48,
                        color: theme.accentSoft,
                        child: Icon(
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
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: theme.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  if (row.status == DownloadStatus.downloading)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: row.progress,
                          backgroundColor: theme.accentSoft,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            theme.accent,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _statusIcon(theme, row),
            if (isDone)
              IconButton(
                icon: Icon(
                  Icons.delete_outline,
                  color: theme.textMuted,
                  size: 20,
                ),
                tooltip: '删除下载',
                onPressed: () async {
                  // Same glass confirm as every other destructive
                  // delete: the downloaded file itself is removed.
                  final ok = await showGlassConfirmDialog(
                    context,
                    title: '删除下载',
                    content: '将删除「${song.title}」的下载文件，之后需要重新下载才能离线播放。',
                    confirmLabel: '删除',
                    confirmColor: theme.liveRed,
                  );
                  if (ok != true || !mounted) return;
                  await _service.delete(song);
                  await _refresh();
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _statusIcon(HaoTheme theme, _DownloadRow row) {
    switch (row.status) {
      case DownloadStatus.downloaded:
        return Icon(Icons.check_circle, color: theme.accent, size: 22);
      case DownloadStatus.downloading:
        return SizedBox(
          width: 44,
          child: Text(
            row.progress != null
                ? '${(row.progress! * 100).round()}%'
                : '…',
            textAlign: TextAlign.right,
            style: TextStyle(color: theme.textSecondary, fontSize: 12),
          ),
        );
      case DownloadStatus.failed:
        return Icon(
          Icons.error_outline,
          color: theme.textSecondary,
          size: 22,
        );
      case DownloadStatus.notDownloaded:
        return Icon(
          Icons.download,
          color: theme.textMuted,
          size: 22,
        );
    }
  }
}

class _DownloadRow {
  _DownloadRow({
    required this.song,
    required this.status,
    required this.progress,
  });

  final Song song;
  final DownloadStatus status;
  final double? progress;
}
