// Music player page (fix 16 + design reference).
//
// Look (chen 2026-11-16 ~08:24 reference screenshot): deep blue
// cover-tinted gradient background, large square cover centred with
// rounded corners, title (bold white) + artist (lighter) left-aligned
// below the cover with star + `···` on the right, thin progress bar with
// elapsed time left + remaining time right, three big white triangle
// controls (prev/play/next, no background circles), volume slider with
// speaker icons, bottom row of 3 pure icons only (lyrics, AirPlay,
// queue), no text labels. The Hi-Res badge sits BELOW the cover,
// centred. The whole player fits one screen — no page scroll; lyrics
// sit below in their own scrollable area.
//
// Behaviour (fix 16): swipe LEFT on the Now Playing area = next song,
// swipe RIGHT = previous song. Threshold: horizontal distance ≥ 60 px
// AND |dx| > 1.2 × |dy|. The swipe must NOT switch to a lyrics view —
// lyrics already sit below on the same page. Vertical lyrics scroll
// keeps working (the gesture detector covers only the cover/title area).
//
// The gradient is tinted from the active theme's accent so the player
// follows all 4 themes × light/dark; the reference deep-blue look is
// what appleGlass/polarIce produce.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/theme/hao_themes.dart';
import '../../../services/music/music_models.dart';
import '../../../services/music/music_quality.dart';
import 'music_player_controller.dart';
import 'widgets/play_queue_panel.dart';
import 'widgets/quality_sheet.dart';
import 'widgets/track_more_sheet.dart';

class MusicPlayerPage extends StatefulWidget {
  const MusicPlayerPage({super.key});

  @override
  State<MusicPlayerPage> createState() => _MusicPlayerPageState();
}

class _MusicPlayerPageState extends State<MusicPlayerPage> {
  final _lyricScroll = ScrollController();
  var _lastLyricIdx = -1;
  double _panDx = 0;
  double _panDy = 0;

  MusicPlayerController get _c => MusicPlayerController.ensure();

  @override
  void dispose() {
    _lyricScroll.dispose();
    super.dispose();
  }

  void _onPanStart(DragStartDetails _) {
    _panDx = 0;
    _panDy = 0;
  }

  void _onPanUpdate(DragUpdateDetails d) {
    _panDx += d.delta.dx;
    _panDy += d.delta.dy;
  }

  void _onPanEnd(DragEndDetails _) {
    if (_panDx.abs() >= 60 && _panDx.abs() > _panDy.abs() * 1.2) {
      if (_panDx < 0) {
        _c.next();
      } else {
        _c.prev();
      }
    }
    _panDx = 0;
    _panDy = 0;
  }

  void _scrollToLyric(int idx) {
    if (idx < 0 || !_lyricScroll.hasClients) return;
    if (idx == _lastLyricIdx) return;
    _lastLyricIdx = idx;
    final target = math.max(0.0, idx * 30.0 - 90.0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_lyricScroll.hasClients) return;
      _lyricScroll.animateTo(
        target.clamp(0.0, _lyricScroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  /// Deep gradient tinted from the theme accent (deep blue on the
  /// reference; follows the other themes' accents elsewhere).
  List<Color> _gradient(HaoTheme theme) {
    final hsl = HSLColor.fromColor(theme.accent);
    final top = hsl.withLightness(0.28).toColor();
    final mid = hsl.withLightness(0.16).toColor();
    final bottom = hsl.withLightness(0.07).toColor();
    return [top, mid, bottom];
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final grad = _gradient(theme);
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: grad,
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              Obx(() {
                final song = _c.currentSong;
                if (song == null) {
                  return const Center(
                    child: Text(
                      '还没有选歌',
                      style: TextStyle(color: Colors.white70, fontSize: 16),
                    ),
                  );
                }
                final lyricIdx = _c.lyricIndexFor(_c.position.value);
                _scrollToLyric(lyricIdx);
                return Column(
                  children: [
                    _topBar(),
                    Expanded(
                      child: GestureDetector(
                        onPanStart: _onPanStart,
                        onPanUpdate: _onPanUpdate,
                        onPanEnd: _onPanEnd,
                        behavior: HitTestBehavior.opaque,
                        child: SingleChildScrollView(
                          physics: const NeverScrollableScrollPhysics(),
                          child: Column(
                            children: [
                              _cover(song),
                              const SizedBox(height: 14),
                              _qualityBadge(),
                              const SizedBox(height: 18),
                              _titleRow(song),
                              const SizedBox(height: 16),
                              _progressBar(),
                              const SizedBox(height: 20),
                              _transportRow(),
                              const SizedBox(height: 10),
                              _volumeRow(),
                              const SizedBox(height: 8),
                              _bottomIconRow(),
                            ],
                          ),
                        ),
                      ),
                    ),
                    _lyricsArea(lyricIdx),
                  ],
                );
              }),
              Obx(
                () => _c.showQueuePanel.value
                    ? PlayQueuePanel(
                        onClose: () => _c.showQueuePanel.value = false,
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white, size: 30),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const Expanded(
            child: Text(
              '正在播放',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white70,
                fontSize: 13,
                letterSpacing: 2,
              ),
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _cover(Song song) {
    final size = math.min(MediaQuery.of(context).size.width * 0.68, 300.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: song.cover.isEmpty
          ? Container(
              width: size,
              height: size,
              color: Colors.white.withValues(alpha: 0.15),
              child: const Icon(Icons.music_note, color: Colors.white54, size: 72),
            )
          : Image.network(
              song.cover,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                width: size,
                height: size,
                color: Colors.white.withValues(alpha: 0.15),
                child: const Icon(
                  Icons.music_note,
                  color: Colors.white54,
                  size: 72,
                ),
              ),
            ),
    );
  }

  /// Quality badge BELOW the cover, centred (fix: badge under cover).
  Widget _qualityBadge() {
    return GestureDetector(
      onTap: () async {
        final picked = await showQualitySheet(context, _c.userQuality.value);
        if (picked != null) {
          final ok = await _c.setQuality(picked);
          if (!ok && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('这首歌播不了，换一首试试')),
            );
          }
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.35),
          ),
        ),
        child: Obx(
          () => Text(
            _c.actualQuality.value.badgeLabel,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _titleRow(Song song) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 15),
                ),
              ],
            ),
          ),
          Obx(
            () => IconButton(
              icon: Icon(
                _c.isFav(song) ? Icons.star : Icons.star_border,
                color: Colors.white,
                size: 26,
              ),
              onPressed: () async {
                await _c.toggleFav(song);
                setState(() {});
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.more_horiz, color: Colors.white, size: 26),
            onPressed: () => _openTrackMore(song),
          ),
        ],
      ),
    );
  }

  Future<void> _openTrackMore(Song song) async {
    await openTrackMoreSheet(context, song, fromPlayer: true);
  }

  /// Thin 4 px progress bar (fix 6): a 24 px hit area paints only a 4 px
  /// line; elapsed portion white, remaining track low-alpha white.
  Widget _progressBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Obx(() {
            final pos = _c.position.value;
            final total = _c.duration.value;
            final frac = total.inMilliseconds > 0
                ? (pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
                : 0.0;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _seekByFractionTap(d, total),
              onHorizontalDragUpdate: (d) => _seekByFraction(d, total),
              child: SizedBox(
                height: 24,
                child: Center(
                  child: SizedBox(
                    height: 4,
                    child: LayoutBuilder(
                      builder: (ctx, constraints) {
                        final w = constraints.maxWidth;
                        return Stack(
                          children: [
                            Container(
                              width: w,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.25),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            Container(
                              width: w * frac,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            );
          }),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Obx(
                () => Text(
                  formatDuration(_c.position.value.inSeconds),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
              Obx(
                () {
                  final total = _c.duration.value;
                  final remain = total - _c.position.value;
                  final text = total.inSeconds <= 0
                      ? '-0:00'
                      : '-${formatDuration(remain.inSeconds < 0 ? 0 : remain.inSeconds)}';
                  return Text(
                    text,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _seekByFraction(DragUpdateDetails d, Duration total) {
    if (total.inMilliseconds <= 0) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    // Fraction from the bar's own width: the bar spans the padded area.
    final width = MediaQuery.of(context).size.width - 48;
    final x = (d.globalPosition.dx - 24).clamp(0.0, width);
    _c.seek(Duration(milliseconds: (total.inMilliseconds * (x / width)).round()));
  }

  void _seekByFractionTap(TapDownDetails d, Duration total) {
    if (total.inMilliseconds <= 0) return;
    final width = MediaQuery.of(context).size.width - 48;
    final x = (d.globalPosition.dx - 24).clamp(0.0, width);
    _c.seek(Duration(milliseconds: (total.inMilliseconds * (x / width)).round()));
  }

  Widget _transportRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.skip_previous, color: Colors.white, size: 54),
          onPressed: () => _c.prev(),
        ),
        const SizedBox(width: 20),
        Obx(
          () => IconButton(
            icon: Icon(
              _c.isPlaying.value ? Icons.pause : Icons.play_arrow,
              color: Colors.white,
              size: 64,
            ),
            onPressed: () => _c.togglePlayPause(),
          ),
        ),
        const SizedBox(width: 20),
        IconButton(
          icon: const Icon(Icons.skip_next, color: Colors.white, size: 54),
          onPressed: () => _c.next(),
        ),
      ],
    );
  }

  Widget _volumeRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          const Icon(Icons.volume_down, color: Colors.white70, size: 20),
          Expanded(
            child: Obx(
              () => SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
                  thumbColor: Colors.white,
                  overlayColor: Colors.white.withValues(alpha: 0.1),
                ),
                child: Slider(
                  value: _c.volume.value,
                  onChanged: (v) => _c.setVolume(v),
                ),
              ),
            ),
          ),
          const Icon(Icons.volume_up, color: Colors.white70, size: 20),
        ],
      ),
    );
  }

  /// Bottom row: 3 pure icons only — lyrics, AirPlay, queue. No labels.
  Widget _bottomIconRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.article_outlined, color: Colors.white, size: 26),
            onPressed: () {
              final idx = _c.lyricIndexFor(_c.position.value);
              _lastLyricIdx = -1;
              _scrollToLyric(idx);
            },
          ),
          IconButton(
            icon: const Icon(Icons.airplay, color: Colors.white, size: 26),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('当前设备不支持隔空播放')),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.queue_music, color: Colors.white, size: 26),
            onPressed: () => _c.showQueuePanel.value = true,
          ),
        ],
      ),
    );
  }

  Widget _lyricsArea(int lyricIdx) {
    return SizedBox(
      height: 150,
      child: Obx(() {
        final lines = _c.lyrics;
        if (lines.isEmpty) {
          return Center(
            child: Text(
              _c.lyricsFailed.value ? '暂无歌词' : '歌词加载中…',
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          );
        }
        return ListView.builder(
          controller: _lyricScroll,
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
          itemCount: lines.length,
          itemBuilder: (ctx, i) {
            final current = i == lyricIdx;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                lines[i].text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: current ? Colors.white : Colors.white54,
                  fontSize: current ? 16 : 14,
                  fontWeight: current ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            );
          },
        );
      }),
    );
  }
}
