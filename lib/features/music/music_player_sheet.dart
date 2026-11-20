// Music player page — Kumone classic骨架 + immersive歌词态 (2026-11-18 重做).
//
// 结构 (Kumone NowPlayingView.swift classicCompactLayout :662-699):
// 顶栏悬浮按钮 / 封面(或歌词) / 音质徽章 / 居中标题 / 进度条 / 控制行 /
// 底部行。页面横向 padding 16，区块间距沿用现有值。
//
// 白字体系 (Kumone .preferredColorScheme(.dark), NowPlayingView.swift:133):
// 本页是强制深色沉浸面 —— 背景是封面取色，与主题明暗无关 —— 所以文字 /
// 图标沿用白不透明度层级 (1.0 / 0.85 / 0.8 / 0.72 / 0.65 / 0.62 / 0.55 /
// 0.45)，不是漏网之鱼；激活态与徽章用主题 accent
// (HaoTheme.of(context).accent，Kumone 红 #EC4949 一律不抄)。四个浮层
// sheet (队列 / 音质 / 睡眠 / ···) 继续沿用主题变量。
//
// 行为 (不动): 歌词在封面后 (点封面出歌词、点行 seek、点空白回封面，
// showLyrics 换歌不重置)；滑切歌只在封面面 (≥60px 且 |dx|>1.2|dy|)；
// 无音量条 (音量恒 1.0)；进度拖动只改本地、松手才 seek 一次；AVPlayer /
// just_audio / 跨 fade / 播放内核选择器 / lib/services/music/ 全部不动。
// MiniLyrics 不抄 (封面下三行迷你歌词，小屏会溢出，且与封面后歌词重复)。
// 不做逐字高亮 (没有 yrc 逐字数据，不许做假逐字)。
// 手动滚动歌词时的中央虚线选择线 + 时间标签没做：行高是固定步长估算
// (当前行译文会让后续行下移约 22pt)，选择线会指错行，所以不加。
//
// Kumone 数值来源见各处注释 (文件:行号均为 ~/workspace/research/kumone
// 仓库 2026-11-18 现状；设计值汇总见 research/kumone-player-study.md)。

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:get/get.dart';

import '../../../core/native/system_volume.dart';
import '../../../core/theme/hao_themes.dart';
import '../../../core/theme/haptics.dart';
import '../../../services/music/music_models.dart';
import '../../../services/music/music_quality.dart';
import '../../../services/music/music_store.dart';
import '../../../services/music/play_mode.dart';
import '../../../services/music/sleep_timer.dart';
import '../player/desktop_shortcuts.dart';
import 'equalizer_page.dart';
import 'music_player_controller.dart';
import 'widgets/music_image.dart';
import 'widgets/play_queue_panel.dart';
import 'widgets/quality_sheet.dart';
import 'widgets/sleep_timer_sheet.dart';
import 'widgets/track_more_sheet.dart';

class MusicPlayerPage extends StatefulWidget {
  const MusicPlayerPage({super.key});

  @override
  State<MusicPlayerPage> createState() => _MusicPlayerPageState();
}

class _MusicPlayerPageState extends State<MusicPlayerPage>
    with SingleTickerProviderStateMixin {
  final _lyricScroll = ScrollController();
  var _lastLyricIdx = -1;
  double _panDx = 0;
  double _panDy = 0;

  /// Lyrics manual-scroll state (Beans `LyricsSection`): while the
  /// user is dragging the lyrics, auto-follow pauses so the list never
  /// fights the finger. On release the list snaps to the nearest line
  /// at the auto-follow anchor, and 5 s later auto-follow resumes
  /// (Kumone minimal: 5 s, NowPlayingView.swift:2469).
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

  /// Windows-only: the device volume for the ↑/↓ and mouse-wheel
  /// shortcuts (the music player has no volume UI of its own — the
  /// gain is the system volume, like on mobile).
  final _systemVolume = SystemVolume();

  // Apple Music-style cover background: blurred cover + dominant-color
  // gradient. Updated when the song changes (currentIndex listener);
  // _bgSongId guards duplicate work, _bgCoverUrl/_coverTint drive the
  // background. Null tint / empty url => Kumone no-cover fallback
  // (ArtworkPalette.swift:11-14), never a grey block.
  StreamSubscription<int>? _songSub;
  String _bgSongId = '';
  String _bgCoverUrl = '';
  Color? _coverTint;

  /// Spring-driven lyric auto-scroll (Kumone regular column:
  /// spring 0.8/0.85, NowPlayingView.swift:1400). ScrollPosition has
  /// no animateWith in this Flutter version, so the spring runs on
  /// this unbounded controller and each tick jumpTo's the list.
  /// Stiffness (2π/0.8)² ≈ 61.7, damping 2·0.85·(2π/0.8) ≈ 13.35
  /// (same ω² / 2ζω mapping as app_shell.dart settleSpring).
  static const _lyricSpring = SpringDescription(
    mass: 1.0,
    stiffness: 61.685,
    damping: 13.352,
  );
  late final AnimationController _lyricScrollController;

  /// Kumone regular lyrics column (NowPlayingView.swift:1362,1445):
  /// 行距 26 + 20pt 非当前行 ≈ 50pt 步长；当前行中心偏移由歌词面高度算
  /// (上留白 200 + 当前行半高约 15 − 面高/2)。固定步长是估算：当前行
  /// 的译文会让它之后的行下移约 22pt，所以滚动落点在“行中心附近”，
  /// 不是像素级精确 —— 见文件头注释。
  static const _lyricRowStride = 50.0;
  var _lyricsViewportHeight = 300.0;
  double get _lyricCenterOffset => 215.0 - _lyricsViewportHeight / 2;

  /// Page + progress-row horizontal insets (Kumone classic: page 16,
  /// scrubber 24 — NowPlayingView.swift:698,693). The bar starts at
  /// 40pt from the screen edge; the scrub math below uses the same.
  static const _progressInset = 40.0;

  /// Active-state color on this forced-dark page. Kumone's accent is
  /// red (#EC4949, luminance ~0.19) - always readable on dark. Our
  /// theme accents are mapped 1:1, but appleGlass / polarIce in light
  /// mode use BLACK (luminance 0), which is invisible on this dark
  /// surface. Fall back to white when the accent is too dark to read
  /// here; every other theme keeps its own accent.
  static Color _activeOnDark(Color accent) =>
      accent.computeLuminance() < 0.15 ? Colors.white : accent;

  @override
  void initState() {
    super.initState();
    _lyricScrollController = AnimationController.unbounded(vsync: this)
      ..addListener(() {
        if (!_lyricScroll.hasClients) return;
        final pos = _lyricScroll.position;
        _lyricScroll.jumpTo(
          _lyricScrollController.value.clamp(0.0, pos.maxScrollExtent),
        );
      });
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
    _systemVolume.dispose();
    _lyricsResumeTimer?.cancel();
    _lyricScrollController.dispose();
    _songSub?.cancel();
    _lyricScroll.dispose();
    super.dispose();
  }

  /// Fetch the cover (shared cache with the cover widget, so no second
  /// download), extract its dominant color, and switch the background to
  /// the blurred-cover + Kumone gradient. Any failure leaves the
  /// fallback gradient in place — never a grey block.
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
    final target = math.max(0.0, idx * _lyricRowStride + _lyricCenterOffset);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_lyricScroll.hasClients) return;
      final pos = _lyricScroll.position;
      final clamped = target.clamp(0.0, pos.maxScrollExtent);
      _lyricScrollController.animateWith(
        SpringSimulation(
          _lyricSpring,
          pos.pixels,
          clamped,
          _lyricScrollController.velocity,
        ),
      );
    });
  }

  /// Snap the lyrics to the nearest line at the auto-follow anchor
  /// (same centre offset as [_scrollToLyric]) after a manual scroll ends
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
    final idx = ((_lyricScroll.offset - _lyricCenterOffset) / _lyricRowStride)
        .round()
        .clamp(0, count - 1);
    _lastLyricIdx = idx;
    final target = math
        .max(0.0, idx * _lyricRowStride + _lyricCenterOffset)
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

  /// Lyrics scroll notifications: a user drag pauses auto-follow (and
  /// stops any spring auto-scroll in flight); release snaps to the
  /// nearest line and starts the 5 s resume timer; when it fires,
  /// auto-follow resumes (Kumone minimal: 5 s).
  bool _onLyricScroll(ScrollNotification n) {
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _lyricsUserDrag = true;
      _lyricsUserScrolling = true;
      _lyricsResumeTimer?.cancel();
      _lyricScrollController.stop();
    } else if (n is ScrollEndNotification && _lyricsUserDrag) {
      _lyricsUserDrag = false;
      _snapLyricsToNearest();
      _lyricsResumeTimer?.cancel();
      _lyricsResumeTimer = Timer(const Duration(seconds: 5), () {
        if (!mounted) return;
        _lyricsUserScrolling = false;
        _lastLyricIdx = -1;
        _scrollToLyric(_c.lyricIndexFor(_c.position.value));
      });
    }
    return false;
  }

  /// Kumone secondary colour (ArtworkPalette.swift:105-108): hue +0.06,
  /// saturation ×1.1 (cap 0.8), lightness = primary ×0.5 (clamp
  /// 0.12–0.26). HSLColor hue is 0–360, so +0.06 is +21.6°.
  Color _secondaryFromPrimary(Color primary) {
    final hsl = HSLColor.fromColor(primary);
    return HSLColor.fromAHSL(
      1.0,
      (hsl.hue + 21.6) % 360,
      (hsl.saturation * 1.1).clamp(0.0, 0.8),
      (hsl.lightness * 0.5).clamp(0.12, 0.26),
    ).toColor();
  }

  /// Background: blurred cover打底 (1.25× + blur 32, unchanged) with
  /// Kumone's three layers on top (NowPlayingView.swift:243-260):
  /// diagonal primary→secondary gradient, top-left white 0.12 radial
  /// light (radius 700), bottom black 0.35 shade. Song changes
  /// cross-fade the gradient 800ms easeInOut (:259).
  ///
  /// The diagonal gradient is painted at alpha 0.8, not opaque: at
  /// full opacity the blurred cover underneath would be invisible,
  /// which would void the “keep the blurred-cover base” instruction.
  /// No-cover fallback is Kumone's fixed pair (ArtworkPalette
  /// .swift:11-14): primary RGB(0.16,0.16,0.20), secondary
  /// RGB(0.09,0.09,0.12).
  Widget _background() {
    final hasCover = _coverTint != null && _bgCoverUrl.isNotEmpty;
    final primary = _coverTint ?? const Color.fromRGBO(41, 41, 51, 1.0);
    final secondary = hasCover
        ? _secondaryFromPrimary(primary)
        : const Color.fromRGBO(23, 23, 31, 1.0);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Blurred cover, scaled up so the blur has no visible edge.
        if (hasCover)
          Transform.scale(
            scale: 1.25,
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 32, sigmaY: 32),
              child: Image(
                image: MusicImageProvider(_bgCoverUrl),
                fit: BoxFit.cover,
              ),
            ),
          ),
        // Diagonal primary → secondary (keyed by song + tint, so a
        // song change cross-fades 800ms easeInOut).
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 800),
          switchInCurve: Curves.easeInOut,
          switchOutCurve: Curves.easeInOut,
          transitionBuilder: (child, animation) =>
              FadeTransition(opacity: animation, child: child),
          child: Container(
            key: ValueKey('bg-$_bgSongId-${_coverTint?.toARGB32() ?? 'none'}'),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  primary.withValues(alpha: 0.8),
                  secondary.withValues(alpha: 0.8),
                ],
              ),
            ),
          ),
        ),
        // Top-left radial light, white 0.12, radius 700pt.
        LayoutBuilder(
          builder: (ctx, constraints) {
            final shortest = math.min(
              constraints.maxWidth,
              constraints.maxHeight,
            );
            return Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.topLeft,
                  radius: shortest > 0 ? 700 / shortest : 1.0,
                  colors: [
                    Colors.white.withValues(alpha: 0.12),
                    Colors.transparent,
                  ],
                ),
              ),
            );
          },
        ),
        // Bottom shade, black 0.35.
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Color.fromRGBO(0, 0, 0, 0.35)],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
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
        // Windows desktop shortcuts (Focus + mouse wheel); on mobile
        // the Focus never autofocuses and every key/wheel event is
        // ignored, so the tree is untouched there.
        child: Focus(
          autofocus: Platform.isWindows,
          onKeyEvent: _onKeyEvent,
          child: Listener(
            onPointerSignal: _onPointerSignal,
            child: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              _background(),
              SafeArea(
                child: Stack(
                  children: [
                    Obx(() {
                      final song = _c.currentSong;
                      if (song == null) {
                        return const Center(
                          child: Text(
                            '还没有选歌',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 16,
                            ),
                          ),
                        );
                      }
                      final lyricIdx = _c.lyricIndexFor(_c.position.value);
                      _scrollToLyric(lyricIdx);
                      return Column(
                        children: [
                          _topBar(),
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final gap = _flexGap(
                                  constraints.maxHeight,
                                  MediaQuery.of(context).size,
                                );
                                return SingleChildScrollView(
                                  physics:
                                      const NeverScrollableScrollPhysics(),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                    ),
                                    child: Column(
                                      children: [
                                        // Leftover height spread over
                                        // three equal flexible gaps:
                                        // Kumone classic absorbs it all
                                        // in its lyrics preview
                                        // (NowPlayingView.swift
                                        // classicCompactLayout), which our
                                        // cover face doesn't have — so the
                                        // free height is shared instead of
                                        // pooling at the bottom (that
                                        // empty band was the bug).
                                        // Controls stay pinned near the
                                        // bottom, 24pt up, like Kumone.
                                        // On short screens the gaps shrink
                                        // to 0 and the scroll view clips
                                        // exactly as before — no overflow.
                                        SizedBox(height: gap),
                                        _coverOrLyrics(song, lyricIdx),
                                        const SizedBox(height: 14),
                                        _qualityBadge(),
                                        const SizedBox(height: 18),
                                        _titleRow(song),
                                        const SizedBox(height: 16),
                                        SizedBox(height: gap),
                                        _progressBar(),
                                        SizedBox(height: gap),
                                        _transportRow(song),
                                        const SizedBox(height: 12),
                                        _bottomIconRow(song),
                                        const SizedBox(height: 24),
                                      ],
                                    ),
                                  ),
                                );
                              },
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
        ),
      ),
    );
  }

  /// Top bar (Kumone NowPlayingView.swift:73-111,199-210): three 36×36
  /// white-0.12 circle buttons, 14pt icons in white 0.85, horizontal
  /// padding 20. Left: collapse (chevron.down). Right: sound effects
  /// (tune → equalizer page) + lyrics toggle (format_quote). Classic
  /// has no centre "正在播放" text — removed.
  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: Row(
        children: [
          _topCircleBtn(
            icon: Icons.keyboard_arrow_down,
            onTap: () => Navigator.of(context).pop(),
          ),
          const Spacer(),
          _topCircleBtn(
            icon: Icons.tune,
            onTap: () {
              HaoHaptics.tap();
              unawaited(
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const EqualizerPage(),
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 8),
          _topCircleBtn(
            icon: Icons.format_quote,
            onTap: () {
              HaoHaptics.tap();
              _toggleLyrics();
            },
          ),
        ],
      ),
    );
  }

  Widget _topCircleBtn({required IconData icon, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: 14,
          color: Colors.white.withValues(alpha: 0.85),
        ),
      ),
    );
  }

  /// Two-sided cover box (chen 2026-11-17): front = cover image, back =
  /// lyrics, both in the SAME fixed height, so flipping never moves the
  /// badge / title / controls below. The cover is a square sized by the
  /// Kumone classic formula (NowPlayingView.swift:663); the lyrics face
  /// is wider (near full screen width, 16pt margins) with bigger text
  /// and no background box. Flipping uses Kumone's immersive curve
  /// timingCurve(0.16, 1, 0.3, 1, 0.42) (NowPlayingView.swift:1730-1738).
  /// `showLyrics` false => cover, true => lyrics; the flag is the user's
  /// last choice and is NOT reset on song change.
  /// Kumone classic cover size (NowPlayingView.swift:663):
  /// min(width - 64, height * 0.38, 300). Single source of truth —
  /// the layout math in [_flexGap] must use the same number.
  static double _coverSizeFor(Size size) =>
      math.min(math.min(size.width - 64, size.height * 0.38), 300.0);

  /// One of the three flexible gaps in the player column. The other
  /// sections have (near-)fixed heights: badge ~20 (6 padding +
  /// 12pt text), title ~46 (21pt + 5 + 13.5pt), progress ~43 (24
  /// bar + 5 + ~14 times row), bottom row 44, transport 58 wide /
  /// 52 narrow (same <360 rule as _transportRow's LayoutBuilder,
  /// measured on screen width - 32 outer padding); fixed gaps
  /// 14/18/16/12 + 24 bottom padding. A few pt of estimate error
  /// only leaves a hair of space or clips a hair — the scroll view
  /// absorbs it, and the render goldens show the real result.
  double _flexGap(double available, Size size) {
    final transportH = size.width - 32 < 360 ? 52.0 : 58.0;
    const rest = 14.0 + 20 + 18 + 46 + 16 + 43 + 12 + 44 + 24;
    final slack = available - _coverSizeFor(size) - transportH - rest;
    return slack > 0 ? slack / 3 : 0;
  }

  Widget _coverOrLyrics(Song song, int lyricIdx) {
    final size = MediaQuery.of(context).size;
    final coverSize = _coverSizeFor(size);
    _lyricsViewportHeight = coverSize;
    // Lyrics use near-full width (16pt margins each side, capped so
    // a tablet line never gets absurdly long); the cover stays a
    // square. Height is the same on both sides so nothing below
    // moves when flipping.
    final lyricsWidth = math.min(size.width - 32.0, 560.0);
    return Obx(() {
      final showL = _c.showLyrics.value;
      return SizedBox(
        width: showL ? lyricsWidth : coverSize,
        height: coverSize,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 420),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation.drive(
              CurveTween(curve: const Cubic(0.16, 1.0, 0.3, 1.0)),
            ),
            child: child,
          ),
          child: showL
              ? _lyricsFace(lyricIdx, lyricsWidth, coverSize)
              : _coverFace(song, coverSize),
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
      child: Obx(
        () => _SpringScale(
          // Kumone pause shrink (NowPlayingView.swift:1062-1063):
          // playing 1.0 → paused 0.95, spring 0.4/0.6 (Theme.swift:103).
          scale: _c.isPlaying.value ? 1.0 : 0.95,
          child: _cover(song, size),
        ),
      ),
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
  ///
  /// Kumone regular column (NowPlayingView.swift:1300,1362,1388-1391,
  /// 1445,1519): row spacing 26, top/bottom padding 200/240, edge fade
  /// 0→0.12 / 0.85→1, current 26 bold, other 20 semibold white 0.45,
  /// translation under the current line only, 16 white 0.7.
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
        // top/bottom fade mask is Kumone's lyrics viewport fade.
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
                stops: [0.0, 0.12, 0.85, 1.0],
              ).createShader(rect),
              blendMode: BlendMode.dstIn,
              child: ListView.builder(
                controller: _lyricScroll,
                padding: const EdgeInsets.fromLTRB(24, 200, 24, 240),
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
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            lines[i].text,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: current
                                  ? Colors.white
                                  : Colors.white.withValues(alpha: 0.45),
                              fontSize: current ? 26 : 20,
                              fontWeight: current
                                  ? FontWeight.w700
                                  : FontWeight.w600,
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
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 16,
                                  fontWeight: FontWeight.w400,
                                  shadows: const [_lyricShadow],
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

  /// Cover (Kumone NowPlayingView.swift:663,1018-1019,1060-1061):
  /// classic size, corner radius 18, shadow black 0.45 / blur 36 /
  /// y 18, fade-in easeIn 0.25 on song change.
  Widget _cover(Song song, double size) {
    final placeholder = Container(
      width: size,
      height: size,
      color: Colors.white.withValues(alpha: 0.15),
      child: const Icon(Icons.music_note, color: Colors.white54, size: 72),
    );
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation.drive(CurveTween(curve: Curves.easeIn)),
        child: child,
      ),
      child: Container(
        key: ValueKey(song.songId),
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [
            BoxShadow(
              color: Color.fromRGBO(0, 0, 0, 0.45),
              blurRadius: 36,
              offset: Offset(0, 18),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: song.cover.isEmpty
              ? placeholder
              : Image(
                  image: MusicImageProvider(song.cover),
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => placeholder,
                ),
        ),
      ),
    );
  }

  /// Quality badge BELOW the cover, centred (fix: badge under cover).
  /// Position and style unchanged by the Kumone redo.
  Widget _qualityBadge() {
    return GestureDetector(
      onTap: () async {
        final picked = await showQualitySheet(context, _c.userQuality.value);
        if (picked != null) {
          final ok = await _c.setQuality(picked);
          if (!ok && mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('这首歌播不了')));
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

  /// Centred title block (Kumone trackMetaView, NowPlayingView
  /// .swift:1066-1087): max width 400, song 21 bold white, artist
  /// 13.5 white 0.65, 5pt between the lines. The star and `···`
  /// moved out of this row — star to the transport row, `···` to
  /// the bottom row.
  Widget _titleRow(Song song) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 21,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.65),
                fontSize: 13.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openTrackMore(Song song) async {
    await openTrackMoreSheet(context, song, fromPlayer: true);
  }

  /// Progress bar (Kumone NowPlayingScrubber, NowPlayingView
  /// .swift:2850-2915): 4pt capsule track, unplayed white 0.25 /
  /// played pure white; thumb (13 white, shadow black 0.3 / r2 / y1)
  /// only while dragging; NO bubble (Kumone has none); time 10.5pt
  /// tabular figures white 0.55 below the track, elapsed left /
  /// TOTAL right (was remaining). 24pt hit area; drag only moves the
  /// local scrub position, seek fires once on release.
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
                            // Thumb only while dragging (Kumone:
                            // opacity(isHovering || isDragging ? 1 : 0)).
                            if (_scrubFrac != null)
                              Positioned(
                                left: (w * _scrubFrac! - 6.5).clamp(
                                  0.0,
                                  math.max(0.0, w - 13),
                                ),
                                top: -4.5,
                                child: Container(
                                  width: 13,
                                  height: 13,
                                  decoration: const BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: Color.fromRGBO(0, 0, 0, 0.3),
                                        blurRadius: 2,
                                        offset: Offset(0, 1),
                                      ),
                                    ],
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
          const SizedBox(height: 5),
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
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 10.5,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                );
              }),
              Obx(() {
                final total = _c.duration.value;
                return Text(
                  formatDuration(total.inSeconds),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 10.5,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                );
              }),
            ],
          ),
        ],
      ),
    );
  }

  /// Fraction of the bar at a horizontal drag position (bar spans the
  /// padded area: 16pt page + 24pt progress-row insets).
  double _fractionAt(double globalDx, Duration total) {
    if (total.inMilliseconds <= 0) return 0;
    final width = MediaQuery.of(context).size.width - _progressInset * 2;
    return ((globalDx - _progressInset) / width).clamp(0.0, 1.0);
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
    final width = MediaQuery.of(context).size.width - _progressInset * 2;
    final x = (d.globalPosition.dx - _progressInset).clamp(0.0, width);
    _c.seek(
      Duration(milliseconds: (total.inMilliseconds * (x / width)).round()),
    );
  }

  /// Transport row (Kumone classic controls(), NowPlayingView
  /// .swift:1125-1240): 7 items in a Row + spaceEvenly — no Expanded
  /// around the 58pt play circle (it overflows). Left to right: fav
  /// star, shuffle, prev, play, next, AirPlay, sound effects.
  /// Circle buttons are 40×40 white 0.1, icons white 0.8, active
  /// theme accent. Play is a solid white 58 circle, 21pt black 0.85
  /// icon, shadow black 0.3 / r12 / y4; icon swaps by opacity fade
  /// 200ms (.contentTransition(.opacity)).
  Widget _transportRow(Song song) {
    // 7 fixed children total 6x40 + 58 = 298pt; at 320pt wide the
    // page leaves 288pt, so shrink the buttons instead of
    // overflowing (iPhone SE 1st gen). 375pt and up keep Kumone's
    // 40 / 58.
    return LayoutBuilder(
      // NOTE: the builder's context parameter is intentionally `_` so
      // it does not shadow State.context — the onTap closures below
      // use context after awaits (AirPlay picker) and are guarded by
      // `mounted`, which only guards State.context.
      builder: (_, constraints) {
        final narrow = constraints.maxWidth < 360;
        final side = narrow ? 36.0 : 40.0;
        final play = narrow ? 52.0 : 58.0;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // NOTE: no Obx here — isFav() reads Hive (not an Rx observable),
            // so an Obx around this button threw "improper use of GetX" on
            // every build and corrupted the title-row layout (the row blew
            // up to 100000pt tall, pushing all controls off-screen). The
            // star refreshes via the setState() in onPressed below, and
            // the page's outer Obx rebuilds on every position tick anyway.
            _circleBtn(
              icon: _c.isFav(song) ? Icons.star : Icons.star_border,
              iconSize: 15,
              size: side,
              active: _c.isFav(song),
              onTap: () async {
                HaoHaptics.tap();
                await _c.toggleFav(song);
                setState(() {});
              },
            ),
            Obx(() {
              final isShuffle = _c.mode == PlayMode.shuffle;
              return _circleBtn(
                icon: Icons.shuffle,
                iconSize: 14,
                size: side,
                active: isShuffle,
                onTap: _toggleShuffle,
              );
            }),
            _circleBtn(
              icon: Icons.skip_previous,
              iconSize: 16,
              size: side,
              onTap: () {
                HaoHaptics.tap();
                _c.prev();
              },
            ),
            Obx(() {
              // Resolving a URL with nothing sounding yet: show a
              // spinner in place of the play button so a tap never
              // looks dead for the seconds a resolve can take. While a
              // song is playing (auto-advance / crossfade) the old
              // track keeps sounding, so no spinner. The box is 58×58,
              // the same size as the play circle it replaces, so the
              // prev/next buttons do not shift.
              if (_c.isResolving.value && !_c.isPlaying.value) {
                return SizedBox(
                  width: play,
                  height: play,
                  child: Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 3,
                      ),
                    ),
                  ),
                );
              }
              final playing = _c.isPlaying.value;
              return GestureDetector(
                onTap: () {
                  HaoHaptics.tap();
                  _c.togglePlayPause();
                },
                child: Container(
                  width: play,
                  height: play,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Color.fromRGBO(0, 0, 0, 0.3),
                        blurRadius: 12,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      transitionBuilder: (child, animation) =>
                          FadeTransition(opacity: animation, child: child),
                      child: Icon(
                        playing ? Icons.pause : Icons.play_arrow,
                        key: ValueKey(playing),
                        color: Colors.black.withValues(alpha: 0.85),
                        size: 21,
                      ),
                    ),
                  ),
                ),
              );
            }),
            _circleBtn(
              icon: Icons.skip_next,
              iconSize: 16,
              size: side,
              onTap: () {
                HaoHaptics.tap();
                _c.next();
              },
            ),
            // AirPlay is iOS-only (AVRoutePickerView): there is no
            // route picker on Windows, so the button is hidden there
            // instead of showing a toast that it cannot open.
            if (!Platform.isWindows)
              _circleBtn(
                icon: Icons.airplay,
                iconSize: 15,
                size: side,
                onTap: () async {
                // Real AirPlay: ask iOS to open the system route picker
                // (AVRoutePickerView). The picker itself shows the
                // available routes — or just this iPhone when none are
                // around — so no device-availability message is invented
                // here. A toast appears only when the picker genuinely
                // could not be opened at all.
                HaoHaptics.tap();
                final opened = await _c.showAirPlayPicker();
                if (!opened && mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('无法打开隔空播放选择器')));
                }
              },
            ),
            _circleBtn(
              icon: Icons.tune,
              iconSize: 15,
              size: side,
              onTap: () {
                HaoHaptics.tap();
                unawaited(
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const EqualizerPage(),
                    ),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }

  // -- Windows desktop keyboard + mouse wheel (step 2, phase 2). --

  /// Keyboard: Space play/pause, ←/→ previous/next track, ↑/↓
  /// system volume. Off Windows every key is ignored (see
  /// desktop_shortcuts.dart).
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!Platform.isWindows) return KeyEventResult.ignored;
    return handleDesktopPlayerKey(
      event,
      onTogglePlayPause: () => unawaited(_c.togglePlayPause()),
      onPrevious: () => unawaited(_c.prev()),
      onNext: () => unawaited(_c.next()),
      onVolumeStep: (direction) =>
          unawaited(_stepVolume(direction / 16)),
    );
  }

  /// Mouse wheel over the player: system volume ±0.05 per notch
  /// (scroll up = louder). Off Windows ignored.
  void _onPointerSignal(PointerSignalEvent event) {
    if (!Platform.isWindows) return;
    if (event is PointerScrollEvent) {
      handleDesktopWheel(event, (delta) => unawaited(_stepVolume(delta)));
    }
  }

  /// One system-volume step (the player has no volume control of its
  /// own — the gain is the system volume).
  Future<void> _stepVolume(double delta) async {
    final current = await _systemVolume.getVolume();
    await _systemVolume.setVolume((current + delta).clamp(0.0, 1.0));
  }

  /// Shuffle toggle. The controller has five modes (play_mode.dart)
  /// including shuffle, so this button is a real shuffle on/off
  /// switch — not the five-mode cycle (that lives in the queue panel
  /// and the `···` sheet). Writes the mode the same two lines
  /// cyclePlayMode() uses (Rx value + Hive persist); no playback
  /// logic is touched.
  void _toggleShuffle() {
    HaoHaptics.tap();
    final next = _c.mode == PlayMode.shuffle
        ? PlayMode.sequential
        : PlayMode.shuffle;
    _c.playMode.value = next.code;
    unawaited(MusicStore.setPlayMode(next.code));
  }

  /// One 40×40 white-0.1 circle button (Kumone circleButton,
  /// NowPlayingView.swift:1284-1292).
  Widget _circleBtn({
    required IconData icon,
    required double iconSize,
    required VoidCallback onTap,
    bool active = false,
    double size = 40,
  }) {
    final theme = HaoTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.1),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: iconSize,
          color: active
              ? _activeOnDark(theme.accent)
              : Colors.white.withValues(alpha: 0.8),
        ),
      ),
    );
  }

  /// Bottom row (Kumone immersive CompactSecondaryControls,
  /// NowPlayingView.swift:2005-2075, reduced to our 3 actions): 3
  /// equal slots, each a centred 44×44 white-0.08 circle button,
  /// 17pt icon, inactive white 0.72, active theme accent. No labels.
  /// Queue / sleep timer / `···`.
  Widget _bottomIconRow(Song song) {
    return Row(
      children: [
        Expanded(
          child: Center(
            child: _bottomBtn(
              icon: Icons.queue_music,
              onTap: () {
                HaoHaptics.tap();
                _c.showQueuePanel.value = true;
              },
            ),
          ),
        ),
        Expanded(
          child: Center(
            child: Obx(
              () => _bottomBtn(
                icon: Icons.timer,
                active: _c.sleepOption.value != SleepTimerOption.off,
                onTap: _openSleepTimer,
              ),
            ),
          ),
        ),
        Expanded(
          child: Center(
            child: _bottomBtn(
              icon: Icons.more_horiz,
              onTap: () {
                HaoHaptics.tap();
                _openTrackMore(song);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _bottomBtn({
    required IconData icon,
    required VoidCallback onTap,
    bool active = false,
  }) {
    final theme = HaoTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: 17,
          color: active
              ? _activeOnDark(theme.accent)
              : Colors.white.withValues(alpha: 0.72),
        ),
      ),
    );
  }

  Future<void> _openSleepTimer() async {
    HaoHaptics.tap();
    final picked = await showSleepTimerSheet(context);
    if (picked == null || !mounted) return;
    _c.setSleepTimer(picked);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          picked == SleepTimerOption.off ? '睡眠定时已关闭' : '睡眠定时：${_c.sleepLabel}',
        ),
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

/// Scales its child with a real spring (Kumone pause shrink:
/// spring response 0.4 / dampingFraction 0.6 — Theme.swift:103).
/// ω = 2π/0.4, stiffness = ω² ≈ 246.7, damping = 2·0.6·ω ≈ 18.85
/// (same mapping as app_shell.dart settleSpring). Owns its own
/// ticker so the spring ticks don't rebuild the whole player page.
class _SpringScale extends StatefulWidget {
  const _SpringScale({required this.scale, required this.child});

  final double scale;
  final Widget child;

  @override
  State<_SpringScale> createState() => _SpringScaleState();
}

class _SpringScaleState extends State<_SpringScale>
    with SingleTickerProviderStateMixin {
  static const _spring = SpringDescription(
    mass: 1.0,
    stiffness: 246.74,
    damping: 18.85,
  );

  late final AnimationController _controller;
  double _value = 1.0;

  @override
  void initState() {
    super.initState();
    _value = widget.scale;
    _controller = AnimationController.unbounded(vsync: this)
      ..value = _value
      ..addListener(() {
        if (mounted) setState(() => _value = _controller.value);
      });
  }

  @override
  void didUpdateWidget(covariant _SpringScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.scale != oldWidget.scale) {
      _controller.animateWith(
        SpringSimulation(_spring, _value, widget.scale, _controller.velocity),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Transform.scale(scale: _value, child: widget.child);
  }
}
