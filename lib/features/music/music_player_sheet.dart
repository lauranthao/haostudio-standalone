// Music player page (fix 16 + design reference).
//
// Look (chen 2026-11-16 ~08:24 reference screenshot + Apple Music rule
// 2026-11-16 ~23:53): the BACKGROUND follows the cover, Apple Music
// style — the cover is scaled up + heavily blurred to fill the page, with
// a dominant-color gradient wash on top (tint up top, near-black at the
// bottom so text stays readable); the whole page changes color with the
// cover. No cover yet / cover failed => the theme-accent gradient below
// (never a grey block). On top of the background: large square cover
// centred with rounded corners, title (bold white) + artist (lighter)
// left-aligned below the cover with star + `···` on the right, thin
// progress bar with elapsed time left + remaining time right, three big
// white triangle controls (prev/play/next, no background circles), volume
// slider with speaker icons, bottom row of 3 pure icons only (lyrics,
// AirPlay, queue), no text labels. The Hi-Res badge sits BELOW the cover,
// centred. The whole player fits one screen — no page scroll; lyrics
// live BEHIND the cover (chen 2026-11-17): the cover box is two-sided
// — front = cover image, back = lyrics in the same square, simple
// cross-fade between the two. Tap the cover flips to lyrics, tap
// lyrics blank flips back, tap a lyric line seeks (stays on lyrics);
// the bottom lyrics icon flips too. Swipe-to-switch-songs (chen
// 2026-11-17): ONLY on the cover — left/right on the cover switches
// songs; title / progress / lyrics / blank areas do not.
//
// Behaviour (fix 16): swipe LEFT on the cover = next song,
// swipe RIGHT = previous song. Threshold: horizontal distance ≥ 60 px
// AND |dx| > 1.2 × |dy|. Tap vs swipe are disambiguated by the gesture
// arena (quick tap flips to lyrics, drag switches songs). On the lyrics
// side, swipe scrolls the lyrics and never switches songs — the switch
// detector wraps the cover side only. The cover/lyrics state is the
// user's last choice and survives song changes; the lyrics themselves
// follow the new song.
//
// The gradient is tinted from the active theme's accent so the player
// follows all 4 themes × light/dark; the reference deep-blue look is
// what appleGlass/polarIce produce.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/theme/hao_themes.dart';
import '../../../services/music/music_models.dart';
import '../../../services/music/music_quality.dart';
import 'music_player_controller.dart';
import 'widgets/music_image.dart';
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

  // Apple Music-style cover background: blurred cover + dominant-color
  // gradient. Updated when the song changes (currentIndex listener);
  // _bgSongId guards duplicate work, _bgCoverUrl/_coverTint drive the
  // background. Null tint / empty url => theme-accent gradient fallback.
  StreamSubscription<int>? _songSub;
  String _bgSongId = '';
  String _bgCoverUrl = '';
  Color? _coverTint;

  @override
  void initState() {
    super.initState();
    _songSub = _c.currentIndex.listen((_) {
      // New song: its lyrics must scroll to the current line even if the
      // line index happens to equal the old song's (the scroll cache key).
      _lastLyricIdx = -1;
      final song = _c.currentSong;
      if (song != null) unawaited(_updateCoverBackground(song));
    });
    final song = _c.currentSong;
    if (song != null) unawaited(_updateCoverBackground(song));
  }

  @override
  void dispose() {
    _songSub?.cancel();
    _lyricScroll.dispose();
    super.dispose();
  }

  /// Fetch the cover (shared cache with the cover widget, so no second
  /// download), extract its dominant color, and switch the background to
  /// the blurred-cover + tint gradient. Any failure leaves the theme
  /// gradient in place — never a grey block.
  Future<void> _updateCoverBackground(Song song) async {
    if (song.songId == _bgSongId) return;
    _bgSongId = song.songId;
    if (song.cover.isEmpty) {
      if (!mounted) return;
      setState(() {
        _bgCoverUrl = '';
        _coverTint = null;
      });
      return;
    }
    Color? tint;
    try {
      final bytes = await fetchMusicImageBytes(song.cover);
      tint = await dominantCoverColor(bytes);
    } catch (_) {
      tint = null;
    }
    if (!mounted || _bgSongId != song.songId) return;
    setState(() {
      _bgCoverUrl = song.cover;
      _coverTint = tint;
    });
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

  /// Apple Music-style background: the current cover, scaled up + heavily
  /// blurred to fill the page, with a dominant-color gradient wash on top
  /// (tint up top, fading to near-black at the bottom so lyrics and
  /// controls stay readable). The whole page follows the cover. When the
  /// cover has not loaded (or failed), the theme-accent gradient above is
  /// the fallback — never a grey block.
  Widget _background(HaoTheme theme) {
    final tint = _coverTint;
    final coverUrl = _bgCoverUrl;
    if (tint == null || coverUrl.isEmpty) {
      final grad = _gradient(theme);
      return Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: grad,
          ),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        // Blurred cover, scaled up so the blur has no visible edge.
        Transform.scale(
          scale: 1.25,
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 32, sigmaY: 32),
            child: Image(
              image: MusicImageProvider(coverUrl),
              fit: BoxFit.cover,
            ),
          ),
        ),
        // Dominant-color wash: tint on top, near-black at the bottom.
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                tint.withValues(alpha: 0.45),
                tint.withValues(alpha: 0.18),
                Colors.black.withValues(alpha: 0.62),
              ],
              stops: const [0.0, 0.45, 1.0],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          _background(theme),
          SafeArea(
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
                      child: SingleChildScrollView(
                        physics: const NeverScrollableScrollPhysics(),
                        child: Column(
                          children: [
                            // Two-sided cover box: front = cover, back =
                            // lyrics (chen 2026-11-17). Swipe-to-switch
                            // lives ONLY on the cover side; title /
                            // progress / lyrics / blank areas do not
                            // switch songs.
                            _coverOrLyrics(song, lyricIdx),
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
      ],
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

  /// Two-sided cover box (chen 2026-11-17): front = cover image, back =
  /// lyrics, both in the SAME fixed square, so flipping never moves the
  /// badge / title / controls below. Simple cross-fade (250 ms), no
  /// flip animation. `showLyrics` false => cover, true => lyrics; the
  /// flag is the user's last choice and is NOT reset on song change.
  Widget _coverOrLyrics(Song song, int lyricIdx) {
    final size = math.min(MediaQuery.of(context).size.width * 0.68, 300.0);
    return Obx(() {
      final showL = _c.showLyrics.value;
      return SizedBox(
        width: size,
        height: size,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: (child, animation) =>
              FadeTransition(opacity: animation, child: child),
          child: showL
              ? _lyricsFace(lyricIdx, size)
              : _coverFace(song, size),
        ),
      );
    });
  }

  /// Cover side: tap flips to lyrics, horizontal swipe switches songs.
  /// Tap vs swipe are disambiguated by the gesture arena (quick tap
  /// fires onTap, drag fires the pan handlers, never both).
  Widget _coverFace(Song song, double size) {
    return GestureDetector(
      key: const ValueKey('playerCover'),
      onPanStart: _onPanStart,
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      onTap: _toggleLyrics,
      behavior: HitTestBehavior.opaque,
      child: _cover(song, size),
    );
  }

  /// Lyrics side, in the cover's square. Dark scrim so white lyrics stay
  /// readable over the bright blurred-cover background (the player is
  /// white text on dark by design, so this is neutral, not a theme
  /// color). Tap a line = seek (stays on lyrics); tap blank = back to
  /// cover. The ListView scrolls vertically; there is NO switch-songs
  /// detector here, so swiping lyrics never changes songs.
  Widget _lyricsFace(int lyricIdx, double size) {
    return Container(
      key: const ValueKey('playerLyrics'),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.30),
        borderRadius: BorderRadius.circular(20),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Obx(() {
          final lines = _c.lyrics;
          if (lines.isEmpty) {
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleLyrics,
              child: Center(
                child: Text(
                  _c.lyricsFailed.value ? '暂无歌词' : '歌词加载中…',
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ),
            );
          }
          // Tap a line = seek to that line's timestamp; tap empty space
          // = back to cover. The inner (line) tap wins the gesture arena
          // over the outer (face) tap, so a line tap never also flips.
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleLyrics,
            child: ListView.builder(
              controller: _lyricScroll,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              itemCount: lines.length,
              itemBuilder: (ctx, i) {
                final current = i == lyricIdx;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _c.seek(
                    Duration(milliseconds: (lines[i].t * 1000).round()),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      lines[i].text,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: current ? Colors.white : Colors.white54,
                        fontSize: current ? 16 : 14,
                        fontWeight:
                            current ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        }),
      ),
    );
  }

  Widget _cover(Song song, double size) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: song.cover.isEmpty
          ? Container(
              width: size,
              height: size,
              color: Colors.white.withValues(alpha: 0.15),
              child: const Icon(Icons.music_note, color: Colors.white54, size: 72),
            )
          : Image(
              image: MusicImageProvider(song.cover),
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
          // NOTE: no Obx here — isFav() reads Hive (not an Rx observable),
          // so an Obx around this button threw "improper use of GetX" on
          // every build and corrupted the title-row layout (the row blew
          // up to 100000pt tall, pushing all controls off-screen and
          // leaving a grey box on the phone). The star refreshes via the
          // setState() in onPressed below.
          IconButton(
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
            // Flip cover <-> lyrics (chen 2026-11-17). Auto-scroll already
            // follows the current line, so the old scroll-to-line action
            // is not needed anymore; tapping again flips back to cover.
            onPressed: _toggleLyrics,
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

  /// Flip cover <-> lyrics; when flipping to lyrics, re-scroll to the
  /// current line after the rebuild (the ListView has no clients while
  /// the cover side is showing, so the scroll must wait a frame).
  void _toggleLyrics() {
    final wasShown = _c.showLyrics.value;
    _c.toggleLyrics();
    if (wasShown) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _lastLyricIdx = -1;
      _scrollToLyric(_c.lyricIndexFor(_c.position.value));
    });
  }
}
