// Multi-view — item 14 (build 29, I group).
//
// 2 or 4 rooms on one screen. One cell is focused: it is the only
// one with sound and the only one at full quality; every other cell
// is muted and at its lowest tier (see live_multiview.dart — four
// simultaneous 原画 streams would stall on most connections).
// Tap a cell to focus it (sound moves, that cell upgrades to the
// preferred quality, the old focus drops back to muted + low).
// Each cell owns its own PlaybackSession + resolution, exactly like
// a small room page: getRoomDetail -> getPlayQualities ->
// resolvePlayUrls -> session.open. Long-press a cell opens that
// room full-screen (single room page, via [onOpenSingle]).
//
// No login, no server: cells resolve through the same five platform
// adapters as the room page. A cell that fails shows an honest
// failure card with a retry — never a fake frame.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../../core/models/live_models.dart';
import '../../../../core/storage/hive_store.dart';
import '../../../../core/theme/hao_radius.dart';
import '../../../../core/theme/hao_themes.dart';
import '../../../../features/player/playback_session.dart';
import '../../../../shared/platforms/sites.dart';
import '../../data/playback_header_resolver.dart';
import '../../live_multiview.dart';

class LiveMultiViewPage extends StatefulWidget {
  const LiveMultiViewPage({
    super.key,
    required this.rooms,
    this.onOpenSingle,
  });

  /// Rooms to show (first 2 or 4 are used). The first room starts
  /// focused.
  final List<LiveRoom> rooms;

  /// Open one room full-screen. Defaults to nothing when null (the
  /// caller passes its own room-page entry).
  final void Function(LiveRoom room)? onOpenSingle;

  @override
  State<LiveMultiViewPage> createState() => _LiveMultiViewPageState();
}

class _LiveMultiViewPageState extends State<LiveMultiViewPage> {
  late final LiveMultiViewState _state;
  int _count = 2;

  @override
  void initState() {
    super.initState();
    _count = widget.rooms.length >= 4 ? 2 : widget.rooms.length.clamp(1, 2);
    _state = LiveMultiViewState(roomCount: _count);
  }

  List<LiveRoom> get _visible => widget.rooms.take(_count).toList();

  void _setCount(int count) {
    if (count == _count) return;
    setState(() {
      _count = count;
      _state.setRoomCount(count);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final rooms = _visible;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '多画面同看',
          style: TextStyle(shadows: HaoTheme.legibilityShadows(context)),
        ),
        actions: [
          if (widget.rooms.length >= 4)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 2, label: Text('2 路')),
                  ButtonSegment(value: 4, label: Text('4 路')),
                ],
                selected: {_count},
                onSelectionChanged: (s) => _setCount(s.first),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Icon(
                  shadows: HaoTheme.legibilityShadows(context),
                  Icons.volume_up,
                  size: 16,
                  color: theme.textMuted,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '点画面切换出声（带框的在出声），其余画面静音低清晰度',
                    style: TextStyle(
                      shadows: HaoTheme.legibilityShadows(context),
                      color: theme.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _count == 2
                ? Column(
                    children: [
                      for (var i = 0; i < rooms.length; i++)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: _MultiViewCell(
                              room: rooms[i],
                              focused: _state.isFocused(i),
                              onFocus: () => setState(() => _state.focus(i)),
                              onOpenSingle: widget.onOpenSingle == null
                                  ? null
                                  : () => widget.onOpenSingle!(rooms[i]),
                            ),
                          ),
                        ),
                    ],
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(6),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 6,
                          mainAxisSpacing: 6,
                          childAspectRatio: 16 / 9,
                        ),
                    itemCount: rooms.length,
                    itemBuilder: (context, i) => _MultiViewCell(
                      room: rooms[i],
                      focused: _state.isFocused(i),
                      onFocus: () => setState(() => _state.focus(i)),
                      onOpenSingle: widget.onOpenSingle == null
                          ? null
                          : () => widget.onOpenSingle!(rooms[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// One cell: its own session + resolution, like a small room page.
/// Focused = sound on + preferred quality; unfocused = muted +
/// lowest tier (lowQualityIndex). Focus changes re-apply the volume
/// immediately; a newly focused cell upgrades its quality (re-resolve
/// at the preferred tier), the old focus drops back to low on its
/// next focus change (it re-resolves then — no prefetch churn).
class _MultiViewCell extends StatefulWidget {
  const _MultiViewCell({
    required this.room,
    required this.focused,
    required this.onFocus,
    this.onOpenSingle,
  });

  final LiveRoom room;
  final bool focused;
  final VoidCallback onFocus;
  final VoidCallback? onOpenSingle;

  @override
  State<_MultiViewCell> createState() => _MultiViewCellState();
}

class _MultiViewCellState extends State<_MultiViewCell> {
  late final PlaybackSession _session;
  bool _loading = true;
  bool _failed = false;
  List<LivePlayQuality> _qualities = [];
  int _currentQuality = 0;
  LiveRoom _room = const LiveRoom(roomId: '', platform: '');

  @override
  void initState() {
    super.initState();
    _room = widget.room;
    _session = PlaybackSession();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(_MultiViewCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focused != oldWidget.focused) {
      unawaited(_applyFocus());
    }
  }

  Future<void> _applyFocus() async {
    await _session.setVolume(widget.focused ? 1.0 : 0.0);
    if (widget.focused && _qualities.length > 1) {
      // Newly focused: upgrade from low tier to the preferred tier.
      final preferred = HiveStore.getString(HiveKeys.preferResolution, '原画');
      final at = _qualities.indexWhere((q) => q.quality == preferred);
      if (at >= 0 && at != _currentQuality) {
        await _resolveAndPlay(at);
      }
    }
  }

  Future<void> _load() async {
    try {
      final site = Sites.of(widget.room.platform);
      final detail = await site.getRoomDetail(widget.room);
      if (!mounted) return;
      _room = detail;
      final qualities = await site.getPlayQualities(liveRoom: detail);
      if (!mounted) return;
      _qualities = qualities;
      final preferred = HiveStore.getString(HiveKeys.preferResolution, '原画');
      final preferredIndex = qualities.indexWhere(
        (q) => q.quality == preferred,
      );
      final start = widget.focused
          ? (preferredIndex >= 0 ? preferredIndex : 0)
          : lowQualityIndex(qualities);
      await _resolveAndPlay(start);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _resolveAndPlay(int qualityIndex) async {
    if (_qualities.isEmpty) return;
    final site = Sites.of(_room.platform);
    final quality = _qualities[qualityIndex.clamp(0, _qualities.length - 1)];
    try {
      final resolution = await site.resolvePlayUrls(
        liveRoom: _room,
        quality: quality,
      );
      if (!mounted || resolution.urls.isEmpty) {
        if (mounted) {
          setState(() {
            _loading = false;
            _failed = true;
          });
        }
        return;
      }
      _currentQuality = _qualities.indexOf(quality);
      final ok = await _session.open(
        url: resolution.urls.first,
        urls: resolution.urls,
        isLive: true,
        headers: PlaybackHeaderResolver.resolve(
          platform: site.id,
          roomId: _room.roomId,
          douyuCookie: site is DouyuSite ? site.playbackCookie : '',
        ),
        declaredFormat: resolution.factsFor(0).format,
        excludeIjk: site.id == 'huya' || site.id == 'douyu',
      );
      if (!mounted) return;
      await _session.setVolume(widget.focused ? 1.0 : 0.0);
      setState(() {
        _loading = false;
        _failed = !ok;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  @override
  void dispose() {
    unawaited(_session.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GestureDetector(
      onTap: widget.onFocus,
      onLongPress: widget.onOpenSingle,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(HaoRadius.large),
          border: Border.all(
            color: widget.focused ? theme.accent : theme.hairline,
            width: widget.focused ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _session.buildVideoWidget(),
            if (_loading)
              const Center(
                child: CupertinoActivityIndicator(color: Colors.white),
              ),
            if (_failed)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off, color: Colors.white70),
                    const SizedBox(height: 6),
                    Text(
                      '加载失败',
                      style: TextStyle(
                        shadows: HaoTheme.legibilityShadows(context),
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _loading = true;
                          _failed = false;
                        });
                        unawaited(_load());
                      },
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 6,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _room.nick.isEmpty ? _room.title : _room.nick,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (widget.focused)
                    const Icon(
                      Icons.volume_up,
                      color: Colors.white,
                      size: 16,
                    )
                  else
                    const Icon(
                      Icons.volume_off,
                      color: Colors.white70,
                      size: 16,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
