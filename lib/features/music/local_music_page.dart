// Local files page (stage 2 item 4) — imported audio files.
//
// Entry: the 本地文件 card on the music home (next to 已下载).
// Lists imported files (newest first). Tapping a row plays it from
// the local file through the existing music controller (AVPlayer);
// the delete button removes the file AND its index entry. Import
// uses file_picker (mp3/m4a/flac/wav/ogg/aac, multiple). Empty state
// is honest: "还没有导入本地音频".

import '../../core/theme/hao_radius.dart';
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../widgets/hao_toast.dart';

import '../../core/theme/glass.dart';
import '../../core/theme/hao_themes.dart';
import '../../core/theme/haptics.dart';
import '../../services/music/local_music_store.dart';
import '../../services/music/music_models.dart';
import '../../widgets/glass_dialog.dart';
import 'music_player_controller.dart';
import 'player_expand_route.dart';
import 'widgets/mini_player_bar.dart';
import '../../widgets/hao_nav_bar.dart';

class LocalMusicPage extends StatefulWidget {
  const LocalMusicPage({super.key});

  @override
  State<LocalMusicPage> createState() => _LocalMusicPageState();
}

class _LocalMusicPageState extends State<LocalMusicPage> {
  final _store = LocalMusicStore();
  var _songs = <Song>[];
  var _loading = true;

  MusicPlayerController get _player => MusicPlayerController.ensure();

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final songs = await _store.list();
    if (!mounted) return;
    setState(() {
      _songs = songs;
      _loading = false;
    });
  }

  Future<void> _import() async {
    HaoHaptics.tap();
    final picked = await FilePicker.pickFiles(
      dialogTitle: '选择本地音频',
      type: FileType.custom,
      allowedExtensions: kLocalAudioExtensions.toList(),
    );
    if (picked.isEmpty) return; // user cancelled
    var added = 0;
    for (final f in picked) {
      final path = f.path;
      if (path == null) continue;
      if (await _store.importFile(File(path)) != null) added++;
    }
    if (!mounted) return;
    if (added > 0) {
      HaoToast.show('已导入', message:  '已导入 $added 首本地音频');
      unawaited(_refresh());
    } else {
      HaoToast.show('未导入', message:  '没有可导入的音频文件');
    }
  }

  void _playSong(Song song) {
    final idx = _songs.indexWhere((s) => s.identityKey == song.identityKey);
    unawaited(_player.playQueue(_songs, idx < 0 ? 0 : idx, label: '本地文件'));
    unawaited(openPlayerPage<void>(context));
  }

  Future<void> _delete(Song song) async {
    HaoHaptics.tap();
    // Deleting a local file removes the file itself, not just a list
    // entry — it gets the same glass confirm as every other
    // destructive delete in the app (playlist / history clear).
    final ok = await showGlassConfirmDialog(
      context,
      title: '删除本地文件',
      content: '将删除「${song.title}」的音频文件，此操作无法恢复。',
      confirmLabel: '删除',
    );
    if (ok != true || !mounted) return;
    await _store.remove(song);
    if (!mounted) return;
    HaoToast.show('已删除', message:  '已删除 ${song.title}');
    unawaited(_refresh());
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Scaffold(
      appBar: HaoNavBar(
        title: '本地文件',
        actions: [HaoNavBarButton( onPressed: _import,child: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.add))],
      ),
      body: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : _songs.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(shadows: HaoTheme.legibilityShadows(context), Icons.audio_file, size: 48, color: theme.textMuted),
                  const SizedBox(height: 12),
                  Text(
                    '还没有导入本地音频',
                    style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textSecondary, fontSize: 15),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _import,
                    icon: Icon(Icons.add, shadows: HaoTheme.legibilityShadows(context),  size: 18),
                    label: const Text('导入音频文件'),
                  ),
                ],
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    '共 ${_songs.length} 首 · 保存在应用内',
                    style: TextStyle(
                      shadows: HaoTheme.legibilityShadows(context),
                      color: theme.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: EdgeInsets.only(
                      bottom: MiniPlayerBar.bottomClearanceFor(context),
                    ),
                    itemCount: _songs.length,
                    itemBuilder: (ctx, i) {
                      final song = _songs[i];
                      return GlassCard(
                        radius: 16,
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                        child: Material(
                          color: Colors.transparent,
                          child: ListTile(
                            leading: Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: theme.accentSoft,
                                borderRadius: BorderRadius.circular(HaoRadius.standard),
                              ),
                              child: Icon(
                                shadows: HaoTheme.legibilityShadows(ctx),
                                Icons.audio_file,
                                color: theme.textMuted,
                              ),
                            ),
                            title: Text(
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                shadows: HaoTheme.legibilityShadows(ctx),
                                color: theme.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              song.artist.isEmpty ? '本地文件' : song.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                shadows: HaoTheme.legibilityShadows(ctx),
                                color: theme.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                            trailing: IconButton(
                              icon: Icon(
                                shadows: HaoTheme.legibilityShadows(ctx),
                                Icons.delete_outline,
                                color: theme.textSecondary,
                                size: 20,
                              ),
                              tooltip: '删除',
                              onPressed: () => unawaited(_delete(song)),
                            ),
                            onTap: () {
                              HaoHaptics.tap();
                              _playSong(song);
                            },
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
