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
// white triangle controls (prev/play/next, no background circles), bottom
// row of 3 pure icons only (lyrics, AirPlay, queue), no text labels. The
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
import '../../../core/theme/haptics.dart';
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

  /// Lyrics manual-scroll state (Beans `LyricsSection`): while the
  /// user is dragging the lyrics, auto-follow pauses so the list never
  /// fights the finger. On release the list snaps to the nearest line
  /// at the auto-follow anchor, and 3 s later auto-follow resumes.
  /// Programmatic auto-scrolls never set this — only a real drag does
  /// (ScrollStartNotification with dragDetails != null).
  var _lyricsUserScrolling = false;
  var _lyricsUserDrag = false;
  Timer? _lyricsResumeTimer;

  /// Progress-bar scrub position (0..1) while the user is dragging
  /// the bar, null when not dragging. While set, the bar fill and
  /// the elapsed label follow the finger instead of the player's
  /// position stream (which would fight the drag), and the seek
  /// itself fires once on drag end — not once per drag event, which
  /// queued a native seek per frame and stuttered the audio.
  double? _scrubFrac;

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
    _lyricsResumeTimer?.cancel();
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
    // Manual scroll in progress: never fight the finger (Beans).
    if (_lyricsUserScrolling) return;
    if (idx < 0 || !_lyricScroll.hasClients) return;
    if (idx == _lastLyricIdx) return;
    _lastLyricIdx = idx;
    // Row stride: 17pt lines (~20.4pt line height) + 12pt vertical
    // padding ≈ 32pt; the current 20pt line is ~36pt, one row only,
    // so the stride error stays < 4pt. -90 keeps the current line
    // ~102pt from the viewport top (upper-middle), as before.
    final target = math.max(0.0, idx * 32.0 - 90.0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_lyricScroll.hasClients) return;
      _lyricScroll.animateTo(
        target.clamp(0.0, _lyricScroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  /// Snap the lyrics to the nearest line at the auto-follow anchor
  /// (same -90 offset as [_scrollToLyric]) after a manual scroll ends
  /// (Beans `LyricsSection`: release snaps to the viewport-centre line).
  ///
  /// The animateTo MUST be deferred with addPostFrameCallback:
  /// ScrollEnd is dispatched synchronously from inside
  /// ScrollPosition.beginActivity, so an animateTo called directly
  /// from the notification creates a Driven activity that the outer
  /// beginActivity disposes immediately afterwards — the snap would
  /// never move (found by the snap widget test: target computed, offset
  /// never changed). Deferring lets the activity transition finish
  /// first, the same reason [_scrollToLyric] defers.
  void _snapLyricsToNearest() {
    if (!_lyricScroll.hasClients) return;
    final count = _c.lyrics.length;
    if (count == 0) return;
    final idx = ((_lyricScroll.offset + 90.0) / 32.0).round().clamp(
      0,
      count - 1,
    );
    _lastLyricIdx = idx;
    final target = math
        .max(0.0, idx * 32.0 - 90.0)
        .clamp(0.0, _lyricScroll.position.maxScrollExtent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_lyricScroll.hasClients) return;
      _lyricScroll.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  /// Lyrics scroll notifications: a user drag pauses auto-follow;
  /// release snaps to the nearest line and starts the 3 s resume
  /// timer; when it fires, auto-follow resumes (Beans: 3 s).
  bool _onLyricScroll(ScrollNotification n) {
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _lyricsUserDrag = true;
      _lyricsUserScrolling = true;
      _lyricsResumeTimer?.cancel();
    } else if (n is ScrollEndNotification && _lyricsUserDrag) {
      _lyricsUserDrag = false;
      _snapLyricsToNearest();
      _lyricsResumeTimer?.cancel();
      _lyricsResumeTimer = Timer(const Duration(seconds: 3), () {
        if (!mounted) return;
        _lyricsUserScrolling = false;
        _lastLyricIdx = -1;
        _scrollToLyric(_c.lyricIndexFor(_c.position.value));
      });
    }
    return false;
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
    // Back closes the floating queue panel first: the panel is a Stack
    // overlay, not a route, so without this the system back (Android)
    // / swipe-back (iOS) pops the whole player page while the queue is
    // open. Only a second back leaves the player. The outer Obx reads
    // showQueuePanel only — the blurred-cover background and the inner
    // Obx scopes are untouched, so position ticks do not rebuild this.
    return Obx(
      () => PopScope(
        canPop: !_c.showQueuePanel.value,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _c.showQueuePanel.value = false;
        },
        child: Scaffold(
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
                              const SizedBox(height: 12),
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
            icon: const Icon(
              Icons.keyboard_arrow_down,
              color: Colors.white,
              size: 30,
            ),
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
  /// lyrics, both in the SAME fixed height, so flipping never moves the
  /// badge / title / controls below. The cover stays a square; the
  /// lyrics face is wider (near full screen width, 16pt margins) with
  /// bigger text and no background box (chen 2026-11-17). Simple
  /// cross-fade (250 ms), no flip animation. `showLyrics` false =>
  /// cover, true => lyrics; the flag is the user's last choice and is
  /// NOT reset on song change.
  Widget _coverOrLyrics(Song song, int lyricIdx) {
    final screenW = MediaQuery.of(context).size.width;
    final size = math.min(screenW * 0.68, 300.0);
    // Lyrics use near-full width (16pt margins each side, capped so
    // a tablet line never gets absurdly long); the cover stays a
    // square. Height is the same on both sides so nothing below
    // moves when flipping.
    final lyricsWidth = math.min(screenW - 32.0, 560.0);
    return Obx(() {
      final showL = _c.showLyrics.value;
      return SizedBox(
        width: showL ? lyricsWidth : size,
        height: size,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: (child, animation) =>
              FadeTransition(opacity: animation, child: child),
          child: showL
              ? _lyricsFace(lyricIdx, lyricsWidth, size)
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

  /// Faint text shadow under lyric text: with no background box, this
  /// is what keeps white lyrics readable over a bright blurred cover.
  static const _lyricShadow = Shadow(
    color: Color.fromRGBO(0, 0, 0, 0.45),
    offset: Offset(0, 1),
    blurRadius: 8,
  );

  /// Lyrics side: same height as the cover square, near-full width,
  /// NO background box (chen 2026-11-17 — the dark rounded container
  /// is deleted entirely, no replacement backdrop/border/shadow-box).
  /// White lyrics sit directly on the blurred-cover background; a
  /// faint text shadow keeps them readable over bright covers (the
  /// player background is already a dark-tinted wash, top bright,
  /// bottom near-black). Tap a line = seek (stays on lyrics); tap
  /// blank = back to cover. The ListView scrolls vertically; there is
  /// NO switch-songs detector here, so swiping lyrics never changes
  /// songs.
  Widget _lyricsFace(int lyricIdx, double width, double height) {
    return SizedBox(
      key: const ValueKey('playerLyrics'),
      width: width,
      height: height,
      child: Obx(() {
        final lines = _c.lyrics;
        if (lines.isEmpty) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleLyrics,
            child: Center(
              child: Text(
                _c.lyricsFailed.value ? '暂无歌词' : '歌词加载中…',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 16,
                  shadows: [_lyricShadow],
                ),
              ),
            ),
          );
        }
        // Tap a line = seek to that line's timestamp; tap empty space
        // = back to cover. The inner (line) tap wins the gesture arena
        // over the outer (face) tap, so a line tap never also flips.
        // Manual scroll pauses auto-follow (see _onLyricScroll); the
        // top/bottom fade mask is Beans' lyrics viewport fade.
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleLyrics,
          child: NotificationListener<ScrollNotification>(
            onNotification: _onLyricScroll,
            child: ShaderMask(
              shaderCallback: (rect) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.fromRGBO(0, 0, 0, 0),
                  Colors.black,
                  Colors.black,
                  Color.fromRGBO(0, 0, 0, 0),
                ],
                stops: [0.0, 0.10, 0.90, 1.0],
              ).createShader(rect),
              blendMode: BlendMode.dstIn,
              child: ListView.builder(
                controller: _lyricScroll,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                itemCount: lines.length,
                itemBuilder: (ctx, i) {
                  final current = i == lyricIdx;
                  final translation = lines[i].translation;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _c.seek(
                      Duration(milliseconds: (lines[i].t * 1000).round()),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            lines[i].text,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: current ? Colors.white : Colors.white54,
                              fontSize: current ? 20 : 17,
                              fontWeight: current
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              shadows: const [_lyricShadow],
                            ),
                          ),
                          // Translation under the focused line only
                          // (Beans `LyricsSection`): smaller, dimmer.
                          if (current &&
                              translation != null &&
                              translation.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(
                                translation,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w400,
                                  shadows: [_lyricShadow],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      }),
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
              child: const Icon(
                Icons.music_note,
                color: Colors.white54,
                size: 72,
              ),
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
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('这首歌播不了，换一首试试')));
          }
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
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
              HaoHaptics.tap();
              await _c.toggleFav(song);
              setState(() {});
            },
          ),
          IconButton(
            icon: const Icon(Icons.more_horiz, color: Colors.white, size: 26),
            onPressed: () {
              HaoHaptics.tap();
              _openTrackMore(song);
            },
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
            // While scrubbing, the bar follows the finger.
            final frac =
                _scrubFrac ??
                (total.inMilliseconds > 0
                    ? (pos.inMilliseconds / total.inMilliseconds).clamp(
                        0.0,
                        1.0,
                      )
                    : 0.0);
            return GestureDetector(
              key: const ValueKey('progressBar'),
              behavior: HitTestBehavior.opaque,
              // onTapUp (not onTapDown): a drag starts with a press,
              // and onTapDown would seek to the press point before the
              // drag even moves — one extra jump per scrub. onTapUp
              // fires only for a completed tap, so a drag seeks once,
              // on release (see _endScrub).
              onTapUp: (d) => _seekByFractionTap(d, total),
              onHorizontalDragStart: (d) {
                HaoHaptics.medium();
                _setScrubFrac(d.globalPosition.dx, total);
              },
              onHorizontalDragUpdate: (d) =>
                  _setScrubFrac(d.globalPosition.dx, total),
              onHorizontalDragEnd: (_) => _endScrub(total),
              onHorizontalDragCancel: () => _endScrub(total),
              child: SizedBox(
                height: 24,
                child: Center(
                  child: SizedBox(
                    height: 4,
                    child: LayoutBuilder(
                      builder: (ctx, constraints) {
                        final w = constraints.maxWidth;
                        return Stack(
                          clipBehavior: Clip.none,
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
                            // Scrub bubble (Beans `SeekBar`): while the
                            // finger is down, the scrub time floats
                            // above the thumb, clamped to the bar.
                            if (_scrubFrac != null && total.inMilliseconds > 0)
                              Positioned(
                                left: (w * _scrubFrac! - 31).clamp(
                                  0.0,
                                  math.max(0.0, w - 62),
                                ),
                                top: -30,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 9,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.48),
                                    borderRadius: BorderRadius.circular(11),
                                    border: Border.all(
                                      color: Colors.white.withValues(
                                        alpha: 0.22,
                                      ),
                                    ),
                                  ),
                                  child: Text(
                                    formatDuration(
                                      (total.inMilliseconds * _scrubFrac!)
                                              .round() ~/
                                          1000,
                                    ),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
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
              Obx(() {
                // While scrubbing, the elapsed label shows the
                // scrub target, not the still-moving playhead.
                final total = _c.duration.value;
                final pos = _scrubFrac != null && total.inMilliseconds > 0
                    ? Duration(
                        milliseconds: (total.inMilliseconds * _scrubFrac!)
                            .round(),
                      )
                    : _c.position.value;
                return Text(
                  formatDuration(pos.inSeconds),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                );
              }),
              Obx(() {
                final total = _c.duration.value;
                final remain = total - _c.position.value;
                final text = total.inSeconds <= 0
                    ? '-0:00'
                    : '-${formatDuration(remain.inSeconds < 0 ? 0 : remain.inSeconds)}';
                return Text(
                  text,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                );
              }),
            ],
          ),
        ],
      ),
    );
  }

  /// Fraction of the bar at a horizontal drag position (bar spans the
  /// padded area: 24pt insets on a full-width bar).
  double _fractionAt(double globalDx, Duration total) {
    if (total.inMilliseconds <= 0) return 0;
    final width = MediaQuery.of(context).size.width - 48;
    return ((globalDx - 24) / width).clamp(0.0, 1.0);
  }

  /// Drag in progress: move the scrub marker only — no native seek
  /// until the finger lifts (see _endScrub).
  void _setScrubFrac(double globalDx, Duration total) {
    final f = _fractionAt(globalDx, total);
    if (_scrubFrac != f) setState(() => _scrubFrac = f);
  }

  /// Finger lifted (or drag cancelled): one seek to the scrub target.
  void _endScrub(Duration total) {
    final f = _scrubFrac;
    if (f == null) return;
    setState(() => _scrubFrac = null);
    if (total.inMilliseconds <= 0) return;
    HaoHaptics.tap();
    _c.seek(Duration(milliseconds: (total.inMilliseconds * f).round()));
  }

  void _seekByFractionTap(TapUpDetails d, Duration total) {
    if (total.inMilliseconds <= 0) return;
    final width = MediaQuery.of(context).size.width - 48;
    final x = (d.globalPosition.dx - 24).clamp(0.0, width);
    _c.seek(
      Duration(milliseconds: (total.inMilliseconds * (x / width)).round()),
    );
  }

  Widget _transportRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.skip_previous, color: Colors.white, size: 54),
          onPressed: () {
            HaoHaptics.tap();
            _c.prev();
          },
        ),
        const SizedBox(width: 20),
        Obx(() {
          // Resolving a URL with nothing sounding yet: show a
          // spinner in place of the play button so a tap never
          // looks dead for the seconds a resolve can take. While a
          // song is playing (auto-advance / crossfade) the old
          // track keeps sounding, so no spinner. The box is 80x80,
          // the same size as the IconButton it replaces, so the
          // prev/next buttons do not shift.
          if (_c.isResolving.value && !_c.isPlaying.value) {
            return const SizedBox(
              width: 80,
              height: 80,
              child: Center(
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 3,
                  ),
                ),
              ),
            );
          }
          final playing = _c.isPlaying.value;
          return IconButton(
            // Play/pause morph (Beans `PlayPauseMorphIcon`): the
            // icon cross-fades + scales instead of swapping hard.
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, animation) => ScaleTransition(
                scale: animation,
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: Icon(
                playing ? Icons.pause : Icons.play_arrow,
                key: ValueKey(playing),
                color: Colors.white,
                size: 64,
              ),
            ),
            onPressed: () {
              HaoHaptics.tap();
              _c.togglePlayPause();
            },
          );
        }),
        const SizedBox(width: 20),
        IconButton(
          icon: const Icon(Icons.skip_next, color: Colors.white, size: 54),
          onPressed: () {
            HaoHaptics.tap();
            _c.next();
          },
        ),
      ],
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
            icon: const Icon(
              Icons.article_outlined,
              color: Colors.white,
              size: 26,
            ),
            // Flip cover <-> lyrics (chen 2026-11-17). Auto-scroll already
            // follows the current line, so the old scroll-to-line action
            // is not needed anymore; tapping again flips back to cover.
            onPressed: () {
              HaoHaptics.tap();
              _toggleLyrics();
            },
          ),
          IconButton(
            icon: const Icon(Icons.airplay, color: Colors.white, size: 26),
            // Real AirPlay: ask iOS to open the system route picker
            // (AVRoutePickerView). The picker itself shows the
            // available routes — or just this iPhone when none are
            // around — so no device-availability message is invented
            // here. A toast appears only when the picker genuinely
            // could not be opened at all.
            onPressed: () async {
              HaoHaptics.tap();
              final opened = await _c.showAirPlayPicker();
              if (!opened && mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('无法打开隔空播放选择器')));
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.queue_music, color: Colors.white, size: 26),
            onPressed: () {
              HaoHaptics.tap();
              _c.showQueuePanel.value = true;
            },
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
