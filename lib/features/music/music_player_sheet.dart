// Music player page — Kumone classic骨架 + immersive歌词态 (2026-11-18 重做).
//
// 结构 (Kumone NowPlayingView.swift classicCompactLayout :662-699):
// 顶栏悬浮按钮 / 封面(或歌词) / 音质徽章 / 左对齐标题 + 右侧星标/··· /
// 进度条 / 控制行(三颗裸白三角，CompactTransportControls :1892-1920) /
// 底部行(歌词/AirPlay/队列)。页面横向 padding 16，区块间距 20、底部
// 控制组间距 12 (Kumone classic VStack :662-699)。
//
// 白字体系 (Kumone .preferredColorScheme(.dark), NowPlayingView.swift:133):
// 本页是强制深色沉浸面 —— 背景是封面取色，与主题明暗无关 —— 所以文字 /
// 图标沿用白不透明度层级 (1.0 / 0.85 / 0.8 / 0.72 / 0.65 / 0.62 / 0.55 /
// 0.45)，不是漏网之鱼；激活态与徽章用主题 accent
// (HaoTheme.of(context).accent，Kumone 红 #EC4949 一律不抄)。四个浮层
// sheet (队列 / 音质 / 睡眠 / ···) 继续沿用主题变量。
//
// 玻璃强度 (PL-P1-5, build 27 定稿：本页明确不跟强度滑块)：沉浸页是封面取
// 色 + 白字体系，与玻璃强度无关；强度滑块只管 liquid glass chrome
// (底栏 / mini 播放器 / 浮层 / 卡片)。背景 blur 与各白底圆的 alpha 写死，
// 不乘 intensity —— 行为不动，特此写明。
//
// 行为 (不动): 歌词在封面后 (点封面出歌词、点行 seek、点空白回封面，
// showLyrics 换歌不重置)；滑切歌只在封面面 (≥60px 且 |dx|>1.2|dy|)；
// 无音量条 (音量恒 1.0)；进度拖动只改本地、松手才 seek 一次；AVPlayer /
// just_audio / 跨 fade / 播放内核选择器 / lib/services/music/ 全部不动。
// MiniLyrics 不抄 (封面下三行迷你歌词，小屏会溢出，且与封面后歌词重复)。
// 不做逐字高亮 (没有 yrc 逐字数据，不许做假逐字)。
// 手动滚动歌词时的中央虚线选择线 + 时间标签没做：行高按每行实测偏移滚动
// (PL-P1-4)；固定步长只作未建行的 fallback。选择线仍不加 (不在本轮)。
//
// Kumone 数值来源见各处注释 (文件:行号均为 ~/workspace/research/kumone
// 仓库 2026-11-18 现状；设计值汇总见 research/kumone-player-study.md)。

import '../../core/theme/hao_radius.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:get/get.dart';

import '../../../core/theme/hao_themes.dart';
import '../../../core/theme/haptics.dart';
import '../../../services/music/music_models.dart';
import '../../../services/music/music_quality.dart';
import 'equalizer_page.dart';
import 'music_player_controller.dart';
import 'widgets/music_image.dart';
import 'widgets/play_queue_panel.dart';
import 'widgets/quality_sheet.dart';
import 'widgets/track_more_sheet.dart';
import '../../widgets/native_music_transport.dart';

class MusicPlayerPage extends StatefulWidget {
  const MusicPlayerPage({super.key, this.nativeMusicTransport = false});

  /// False (default) = the Flutter transport row. True + iOS = the
  /// SwiftUI transport (needs MusicTransportPlugin registered AND
  /// Codemagic-verified — no Xcode on the VM, so the flag stays
  /// false until the plugin compiles there). Same convention as the
  /// VOD page's nativeVodControls flag.
  final bool nativeMusicTransport;

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
  /// (上留白 200 + 当前行半高约 15 − 面高/2)。滚动落点按每行实测的
  /// RenderBox 偏移算 (PL-P1-4，Kumone scrollTo anchor:.center，
  /// NowPlayingView.swift:1400)；固定步长只在目标行尚未建行时作
  /// fallback（当前行带译文时实测约 74pt，比步长多约 24pt，旧算法
  /// 在此必偏）。每行一个 GlobalKey，建行后才有 context。
  static const _lyricRowStride = 50.0;

  /// One GlobalKey per lyric row (created once, reused across
  /// rebuilds) so [_lyricRowCenterTarget] can measure real offsets.
  final Map<int, GlobalKey> _lyricRowKeys = <int, GlobalKey>{};
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
      // P1-P2: 200 px decode + URL-keyed tint cache (no re-decode when
      // switching back to a song).
      tint = await coverTintForUrl(song.cover);
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

  /// Scroll offset that centres lyric row [idx] in the viewport,
  /// measured from the row's real RenderBox (Kumone scrollTo
  /// anchor:.center). Null when the row is not laid out yet (the
  /// builder only builds visible rows); callers fall back to the
  /// fixed-stride estimate for that frame.
  double? _lyricRowCenterTarget(int idx) {
    final ctx = _lyricRowKeys[idx]?.currentContext;
    if (ctx == null || !_lyricScroll.hasClients) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final viewport = RenderAbstractViewport.of(box);
    return viewport
        .getOffsetToReveal(box, 0.5)
        .offset
        .clamp(0.0, _lyricScroll.position.maxScrollExtent);
  }

  void _scrollToLyric(int idx) {
    // Manual scroll in progress: never fight the finger (Beans).
    if (_lyricsUserScrolling) return;
    if (idx < 0 || !_lyricScroll.hasClients) return;
    if (idx == _lastLyricIdx) return;
    _lastLyricIdx = idx;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_lyricScroll.hasClients) return;
      final pos = _lyricScroll.position;
      // Real row offset when the row is built; stride estimate only
      // when it is not (e.g. jumping several lines at once — the next
      // call re-targets once the row exists).
      final target =
          _lyricRowCenterTarget(idx) ??
          math
              .max(0.0, idx * _lyricRowStride + _lyricCenterOffset)
              .clamp(0.0, pos.maxScrollExtent);
      _lyricScrollController.animateWith(
        SpringSimulation(
          _lyricSpring,
          pos.pixels,
          target,
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
    // Nearest BUILT row to the viewport centre (measured offsets);
    // stride estimate only when no row is built yet.
    var idx = -1;
    var target = 0.0;
    var bestDist = double.infinity;
    for (final i in _lyricRowKeys.keys) {
      if (i < 0 || i >= count) continue;
      final centre = _lyricRowCenterTarget(i);
      if (centre == null) continue;
      final dist = (centre - _lyricScroll.offset).abs();
      if (dist < bestDist) {
        bestDist = dist;
        idx = i;
        target = centre;
      }
    }
    if (idx < 0) {
      idx = ((_lyricScroll.offset - _lyricCenterOffset) / _lyricRowStride)
          .round()
          .clamp(0, count - 1);
      target = math
          .max(0.0, idx * _lyricRowStride + _lyricCenterOffset)
          .clamp(0.0, _lyricScroll.position.maxScrollExtent);
    }
    _lastLyricIdx = idx;
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

  /// Background: blurred cover打底 (1.25× + blur 36, Beans
  /// CoverBlurBackground.swift:223 — PL-P1-3) with
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
              // Beans CoverBlurBackground radius 36 (PL-P1-3).
              imageFilter: ui.ImageFilter.blur(sigmaX: 36, sigmaY: 36),
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
                                final gaps = _flexGaps(
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
                                        // three equal flexible gaps, each
                                        // capped at 24pt (PL-P1-1c); the
                                        // excess pools into the bottom
                                        // padding instead of stretching
                                        // the gaps. Kumone classic
                                        // absorbs it all in its lyrics
                                        // preview (NowPlayingView.swift
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
                                        SizedBox(height: gaps.gap),
                                        _coverOrLyrics(song, lyricIdx),
                                        const SizedBox(height: 20),
                                        _qualityBadge(),
                                        const SizedBox(height: 20),
                                        _titleRow(song),
                                        const SizedBox(height: 20),
                                        SizedBox(height: gaps.gap),
                                        _progressBar(),
                                        SizedBox(height: gaps.gap),
                                        _transportRow(),
                                        const SizedBox(height: 12),
                                        _bottomIconRow(),
                                        SizedBox(height: gaps.bottomPad),
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
    );
  }

  /// Top bar (Kumone NowPlayingView.swift:73-111,199-210): 36×36
  /// white-0.12 circle buttons, 14pt icons in white 0.85, horizontal
  /// padding 20, vertical padding 20 (PL-P2-6, Kumone's top padding).
  /// Left: collapse (chevron.down). Right: sound effects only
  /// (tune → equalizer page, iOS only — hidden on Android, which
  /// has no native EQ engine) — the lyrics toggle moved to the
  /// bottom row (PL-P0-3), so it is not duplicated here. Classic
  /// has no centre "正在播放" text — removed.
  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Row(
        children: [
          _topCircleBtn(
            icon: CupertinoIcons.chevron_down,
            onTap: () => Navigator.of(context).pop(),
          ),
          const Spacer(),
          // Equalizer has no native engine on Android: hide the
          // button there instead of opening a page whose sliders do
          // nothing. Shown everywhere else (iOS behaviour unchanged;
          // `!isAndroid` also keeps the Linux test env green).
          if (!Platform.isAndroid)
            _topCircleBtn(
              icon: CupertinoIcons.slider_horizontal_3,
              onTap: () {
                HaoHaptics.tap();
                unawaited(
                  Navigator.of(context).push(
                    CupertinoPageRoute<void>(
                      builder: (_) => const EqualizerPage(),
                    ),
                  ),
                );
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
          icon, shadows: HaoTheme.legibilityShadows(context), 
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
  /// the layout math in [_flexGaps] must use the same number.
  static double _coverSizeFor(Size size) =>
      math.min(math.min(size.width - 64, size.height * 0.38), 300.0);

  /// The three flexible gaps in the player column + the bottom
  /// padding (PL-P1-1c). The other sections have (near-)fixed
  /// heights: badge ~20, title ~46 (21pt + 5 + 13.5pt), progress
  /// ~43 (24 bar + 5 + ~14 times row), bottom row 44, transport 64
  /// (compact: minHeight 64, no width rule — three equal slots);
  /// fixed gaps 20/20/20/12 (Kumone classic VStack spacing 20,
  /// bottom control group spacing 12) + 24 base bottom padding.
  /// Each gap is capped at 24pt; slack beyond 3×24 pools into the
  /// bottom padding, so the column still exactly fills [available].
  /// A few pt of estimate error only leaves a hair of space or clips
  /// a hair — the scroll view absorbs it, and the render goldens
  /// show the real result.
  ///
  /// NOTE: [available] is the Expanded height, already net of the
  /// top bar — the top bar's height is NOT part of [rest], so the
  /// P2-6 top-bar change (vertical 4→20) needs no rest adjustment
  /// here; adding 32 to rest would double-count and leave a 32pt
  /// blank band under the bottom row.
  ({double gap, double bottomPad}) _flexGaps(double available, Size size) {
    const transportH = 64.0;
    const rest = 20.0 + 20 + 20 + 46 + 20 + 43 + 12 + 44 + 24;
    final slack = available - _coverSizeFor(size) - transportH - rest;
    if (slack <= 0) return (gap: 0, bottomPad: 24);
    final gap = math.min(slack / 3, 24.0);
    return (gap: gap, bottomPad: 24 + (slack - gap * 3));
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
  /// Legibility shadow for every white glyph on this page (title,
  /// artist, badge, times, transport, icons): the 1.1.6 glass
  /// legibility fix never reached this sheet — its white text and
  /// icons had no shadow at all, so a light cover could hide them.
  /// Same shadow the lyrics already used; this page does not follow
  /// the glass-intensity slider, so the strength is fixed.
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
                    key: _lyricRowKeys.putIfAbsent(i, () => GlobalKey()),
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
                          // Build 29: hidden when the user turned the
                          // translation switch off in the `···` sheet.
                          if (current &&
                              _c.showLyricTranslation.value &&
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
    // No-cover placeholder (Kumone :1045-1049): white 0.06 base +
    // 48pt note in white 0.3. Material Icons.music_note has no light
    // weight — the regular weight is the closest match.
    final placeholder = Container(
      width: size,
      height: size,
      color: Colors.white.withValues(alpha: 0.06),
      child: Icon(
        Icons.music_note, shadows: HaoTheme.legibilityShadows(context), 
        color: Colors.white.withValues(alpha: 0.3),
        size: 48,
      ),
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
      // Slim tag, not a button (PL-P2-4; Kumone QualityTag,
      // Components.swift:178-193): no fill, hairline border only,
      // 10.5pt, H8 V2 padding, radius 4 (HaoRadius.badge). The white
      // 0.35 border stays (not Kumone's accent border — no red here).
      // Tap still opens the quality sheet.
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(HaoRadius.badge),
          border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
        ),
        child: Obx(
          () => Text(
            _c.actualQuality.value.badgeLabel,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              shadows: [_lyricShadow],
            ),
          ),
        ),
      ),
    );
  }

  /// Left-aligned title block (chen reference screenshot; Kumone
  /// immersive CompactTrackHeader, NowPlayingView.swift:1776-1872):
  /// song 21 bold white / artist 13.5 white 0.65 (classic values,
  /// unchanged), 5pt between the lines; star + `···` on the right,
  /// 44×44 each, 21pt icons in white 0.88, star active = theme
  /// accent. Long titles ellipsize — the two buttons never squeeze.
  Widget _titleRow(Song song) {
    return Row(
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.left,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  shadows: [_lyricShadow],
                ),
              ),
              const SizedBox(height: 5),
              Text(
                song.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.left,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.65),
                  fontSize: 13.5,
                  shadows: [_lyricShadow],
                ),
              ),
            ],
          ),
        ),
        // NOTE: no Obx here — isFav() reads Hive (not an Rx
        // observable), so an Obx around this button threw "improper
        // use of GetX" on every build and corrupted the title-row
        // layout (the old transport-row star had the same bug). The
        // star refreshes via the setState() in onTap below, and the
        // page's outer Obx rebuilds on every position tick anyway.
        _titleIconBtn(
          icon: _c.isFav(song) ? Icons.star : Icons.star_border,
          active: _c.isFav(song),
          onTap: () async {
            HaoHaptics.tap();
            await _c.toggleFav(song);
            setState(() {});
          },
        ),
        _titleIconBtn(
          icon: CupertinoIcons.ellipsis,
          onTap: () {
            HaoHaptics.tap();
            _openTrackMore(song);
          },
        ),
      ],
    );
  }

  /// One 44×44 title-row icon (Kumone CompactTrackHeader:
  /// 21pt medium icon, white 0.88; active = theme accent).
  Widget _titleIconBtn({
    required IconData icon,
    required VoidCallback onTap,
    bool active = false,
  }) {
    final theme = HaoTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Icon(
          icon, shadows: HaoTheme.legibilityShadows(context), 
          size: 21,
          weight: 500,
          color: active
              ? _activeOnDark(theme.accent)
              : Colors.white.withValues(alpha: 0.88),
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
  /// REMAINING right ('-m:ss', v1.0.4 format — chen reference;
  /// Kumone shows total, see audit PL-P1-7). 24pt hit area; drag
  /// only moves the local scrub position, seek fires once on release.
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
                                borderRadius: BorderRadius.circular(HaoRadius.badge),
                                // Lifts the thin bar off a light cover.
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color.fromRGBO(0, 0, 0, 0.35),
                                    blurRadius: 4,
                                    offset: Offset(0, 1),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              width: w * frac,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(HaoRadius.badge),
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
                    shadows: [_lyricShadow],
                  ),
                );
              }),
              Obx(() {
                // Remaining time, '-m:ss' (v1.0.4 format: total<=0
                // shows '-0:00', never a bare total). While scrubbing
                // it follows the finger, like the elapsed label.
                final total = _c.duration.value;
                final pos = _scrubFrac != null && total.inMilliseconds > 0
                    ? Duration(
                        milliseconds: (total.inMilliseconds * _scrubFrac!)
                            .round(),
                      )
                    : _c.position.value;
                final remain = total - pos;
                final text = total.inSeconds <= 0
                    ? '-0:00'
                    : '-${formatDuration(remain.inSeconds < 0 ? 0 : remain.inSeconds)}';
                return Text(
                  text,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 10.5,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    shadows: [_lyricShadow],
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

  /// Transport row (Kumone CompactTransportControls,
  /// NowPlayingView.swift:1892-1920): three equal slots, no
  /// background circles — bare white triangles. Prev/next 25pt
  /// semibold, min height 58; play/pause 36pt bold, min height 64.
  /// Star → title row (PL-P0-2), AirPlay → bottom row (PL-P0-3),
  /// tune → top bar only (PL-P1-6), shuffle → the `···` sheet's
  /// play-mode row (PL-P0-1; the queue panel header mode button is
  /// untouched). Only the surface changed; playback logic is intact.
  ///
  /// build-29 adoption: the Row below is the Flutter fallback. On
  /// iOS with [MusicPlayerPage.nativeMusicTransport] true (after
  /// Codemagic verifies the plugin), the same three buttons render
  /// as SwiftUI via [NativeMusicTransport] instead.
  Widget _transportRow() {
    final fallback = Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 58,
            child: Center(
              child: _transportTriangle(
                icon: Icons.skip_previous,
                size: 25,
                onTap: () {
                  HaoHaptics.tap();
                  _c.prev();
                },
              ),
            ),
          ),
        ),
        Expanded(
          child: SizedBox(
            height: 64,
            child: Center(
              child: Obx(() {
                // Resolving a URL with nothing sounding yet: show a
                // spinner in place of the play button so a tap never
                // looks dead for the seconds a resolve can take. While a
                // song is playing (auto-advance / crossfade) the old
                // track keeps sounding, so no spinner.
                if (_c.isResolving.value && !_c.isPlaying.value) {
                  return const SizedBox(
                    width: 28,
                    height: 28,
                    child: CupertinoActivityIndicator(
                      color: Colors.white,
                      ),
                  );
                }
                final playing = _c.isPlaying.value;
                return AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (child, animation) =>
                      FadeTransition(opacity: animation, child: child),
                  child: _transportTriangle(
                    key: ValueKey(playing),
                    icon: playing ? Icons.pause : Icons.play_arrow,
                    size: 36,
                    bold: true,
                    onTap: () {
                      HaoHaptics.tap();
                      _c.togglePlayPause();
                    },
                  ),
                );
              }),
            ),
          ),
        ),
        Expanded(
          child: SizedBox(
            height: 58,
            child: Center(
              child: _transportTriangle(
                icon: Icons.skip_next,
                size: 25,
                onTap: () {
                  HaoHaptics.tap();
                  _c.next();
                },
              ),
            ),
          ),
        ),
      ],
    );
    return Obx(
      () => NativeMusicTransport(
        playing: _c.isPlaying.value,
        nativeEnabled: widget.nativeMusicTransport,
        onAction: (action) {
          HaoHaptics.tap();
          switch (action) {
            case MusicTransportAction.prev:
              _c.prev();
            case MusicTransportAction.playPause:
              _c.togglePlayPause();
            case MusicTransportAction.next:
              _c.next();
          }
        },
        fallback: fallback,
      ),
    );
  }

  /// One bare white triangle (Kumone compact transport): no circle,
  /// no background — the glyph is the button. [bold] maps the 36pt
  /// play/pause glyph to weight 700, the 25pt prev/next glyphs to
  /// 600 (Icon weight is a no-op on the static Material font, kept
  /// as the documented mapping).
  Widget _transportTriangle({
    Key? key,
    required IconData icon,
    required double size,
    required VoidCallback onTap,
    bool bold = false,
  }) {
    return GestureDetector(
      key: key,
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Icon(
        icon, shadows: HaoTheme.legibilityShadows(context), 
        size: size,
        weight: bold ? 700 : 600,
        color: Colors.white,
      ),
    );
  }

  /// Bottom row (Kumone immersive CompactSecondaryControls,
  /// NowPlayingView.swift:2005-2075, reduced to our 3 actions): 3
  /// equal slots, each a centred 44×44 white-0.08 circle button,
  /// 17pt icon, inactive white 0.72, active theme accent. No labels.
  /// Lyrics toggle / AirPlay / queue (chen reference). Sleep timer
  /// lives in the `···` sheet (PL-P0-3; the sheet already has a
  /// sleep entry, so it is not duplicated here); the `···` key itself
  /// moved to the title row (PL-P0-2). The lyrics key carries the
  /// active state (PL-P2-5): lyrics face shows music.note in accent,
  /// cover face shows format_quote in white 0.72.
  Widget _bottomIconRow() {
    return Row(
      children: [
        Expanded(
          child: Center(
            child: Obx(
              () => _bottomBtn(
                icon: _c.showLyrics.value
                    ? Icons.music_note
                    : Icons.format_quote,
                active: _c.showLyrics.value,
                onTap: () {
                  HaoHaptics.tap();
                  _toggleLyrics();
                },
              ),
            ),
          ),
        ),
        Expanded(
          child: Center(
            child: _bottomBtn(
              icon: Icons.airplay,
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
          ),
        ),
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
          icon, shadows: HaoTheme.legibilityShadows(context), 
          size: 17,
          color: active
              ? _activeOnDark(theme.accent)
              : Colors.white.withValues(alpha: 0.72),
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
