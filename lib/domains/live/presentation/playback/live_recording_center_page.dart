// Recording center — item 13 (build 29, I group).
//
// Lists the local recordings (`live_recordings/` under the app
// documents dir): name / size / date, newest first. Delete (with
// confirm) and share (system share sheet) per file. No playback
// here — .flv / .ts are raw stream captures, played in the user's
// own player via the share sheet. Empty state is honest ("还没有录制").
// Files are local-only, never uploaded.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/theme/hao_themes.dart';
import '../../../../widgets/glass_dialog.dart';
import '../../live_recorder.dart';

/// The recordings directory (app documents `live_recordings/`).
Future<Directory> liveRecordingsDir() async {
  final docs = await getApplicationDocumentsDirectory();
  return Directory('${docs.path}/live_recordings');
}

class LiveRecordingCenterPage extends StatefulWidget {
  const LiveRecordingCenterPage({super.key, this.directory});

  /// Injected for tests; defaults to [liveRecordingsDir].
  final Directory? directory;

  @override
  State<LiveRecordingCenterPage> createState() =>
      _LiveRecordingCenterPageState();
}

class _LiveRecordingCenterPageState extends State<LiveRecordingCenterPage> {
  List<LiveRecording> _recordings = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Directory> _dir() async =>
      widget.directory ?? liveRecordingsDir();

  Future<void> _load() async {
    final dir = await _dir();
    final list = await listRecordings(dir);
    if (mounted) {
      setState(() {
        _recordings = list;
        _loading = false;
      });
    }
  }

  Future<void> _delete(LiveRecording recording) async {
    final confirmed = await showGlassConfirmDialog(
      context,
      title: '删除这段录制？',
      content: '${recording.name}（${_formatSize(recording.size)}）将被删除，此操作无法恢复。',
      confirmLabel: '删除',
    );
    if (confirmed != true) return;
    try {
      await recording.file.delete();
    } catch (_) {}
    await _load();
  }

  Future<void> _share(LiveRecording recording) async {
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(recording.file.path)],
          text: recording.name,
        ),
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '录制中心',
          style: TextStyle(shadows: HaoTheme.legibilityShadows(context)),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _recordings.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        shadows: HaoTheme.legibilityShadows(context),
                        Icons.videocam_off_outlined,
                        size: 48,
                        color: theme.textMuted,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '还没有录制',
                        style: TextStyle(
                          shadows: HaoTheme.legibilityShadows(context),
                          color: theme.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '在直播间工具里开始录制，文件会保存在本地',
                        style: TextStyle(
                          shadows: HaoTheme.legibilityShadows(context),
                          color: theme.textMuted,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(14),
                  itemCount: _recordings.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final r = _recordings[i];
                    return ListTile(
                      leading: Icon(
                        shadows: HaoTheme.legibilityShadows(context),
                        Icons.videocam_outlined,
                        color: theme.accent,
                      ),
                      title: Text(
                        r.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          shadows: HaoTheme.legibilityShadows(context),
                          color: theme.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        '${_formatSize(r.size)} · ${_formatDate(r.created)}',
                        style: TextStyle(
                          shadows: HaoTheme.legibilityShadows(context),
                          color: theme.textMuted,
                          fontSize: 12,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.share_outlined),
                            tooltip: '分享',
                            onPressed: () => _share(r),
                          ),
                          IconButton(
                            icon: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.delete_outline),
                            tooltip: '删除',
                            onPressed: () => _delete(r),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}

String _formatSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

String _formatDate(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}';
}
