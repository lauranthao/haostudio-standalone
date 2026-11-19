import 'dart:async';

// Song search (fix 12).
//
// Input + type segments (歌曲/歌单/歌手/专辑） + 搜索 button only.
// Platform capsule (stage 2, Beans `SearchView` providerPicker /
// `RootView` PlatformPickerSheet): ONE platform at a time (网易/QQ/
// 酷狗/酷我，no "全部"), persisted in SearchPlatformStore; song,
// playlist, artist and album search all query only that platform,
// and the hot words are that platform's (hotSearch(platform)).
// Song search still streams per-leg results (~1 s to first result);
// the wy+tx-first sort stays in place and is a no-op with a single
// platform. Playback resolving is NOT filtered: it still asks all
// sources serially and plays the first playable URL (chen's 铁律).

import 'package:flutter/material.dart';

import '../../core/theme/glass.dart';
import '../../core/theme/hao_themes.dart';
import '../../core/theme/haptics.dart';
import '../../services/music/hot_search_service.dart';
import '../../services/music/music_api.dart';
import '../../services/music/music_models.dart';
import '../../services/music/music_store.dart';
import '../../services/music/search_cover_backfill.dart';
import '../../services/music/search_platform_store.dart';
import '../../services/music/search_prewarm.dart';
import '../../services/music/song_search_service.dart';
import 'album_detail_page.dart';
import 'artist_detail_page.dart';
import 'music_player_controller.dart';
import 'music_player_sheet.dart';
import 'plaza_page.dart';
import 'widgets/song_row.dart';
import 'widgets/track_more_sheet.dart';
import 'widgets/music_image.dart';
import '../../widgets/platform_logo.dart';

enum _SearchType { song, playlist, artist, album }

class SongSearchPage extends StatefulWidget {
  const SongSearchPage({super.key, this.searchService, this.api});

  /// Test seam: the page builds its own service/api by default.
  /// Widget tests inject fakes here so a search runs without network.
  final SongSearchService? searchService;
  final MusicApi? api;

  @override
  State<SongSearchPage> createState() => _SongSearchPageState();
}

class _SongSearchPageState extends State<SongSearchPage> {
  final _queryController = TextEditingController();
  final _scrollController = ScrollController();
  late final SongSearchService _searchService =
      widget.searchService ?? SongSearchService();
  late final MusicApi _api = widget.api ?? MusicApi();
  final _hotService = HotSearchService();
  // Current search platform (stage 2 capsule, Beans `SearchView`
  // provider): one platform at a time, persisted, no "全部".
  late MusicPlatform _platform;
  // Hot words for the current platform (stage 2 plugs the platform
  // capsule in here; the service is already hotSearch(platform)).
  List<String> _hotWords = [];
  StreamSubscription<SearchStreamUpdate>? _searchSub;
  StreamSubscription<PlaylistSearchUpdate>? _playlistSub;
  StreamSubscription<ArtistSearchUpdate>? _artistSub;
  // Prewarm: resolve the first few visible songs' URLs while the
  // user is still looking, so tapping one plays from the cache.
  final _prewarm = SearchPrewarm();
  // Cover backfill: Kuwo/Kugou rows mostly arrive coverless — fill
  // the visible rows' covers from NetEase (serial, cached, see
  // SearchCoverBackfill). Same lifecycle as the prewarm.
  final _coverBackfill = SearchCoverBackfill();
  // Page-side generation: a new search cancels the old subscription
  // and bumps this, so stale stream callbacks can never touch the new
  // list (the service has the same guard; both must hold).
  var _pageGen = 0;
  // Platforms with at least one search leg not yet settled (from the
  // latest stream update). Shown in the footer while streaming.
  Set<MusicPlatform> _pendingPlatforms = {};

  var _type = _SearchType.song;
  var _loading = false;
  var _searched = false;
  List<Song> _songs = [];
  var _shown = kSearchPageSize;
  List<PlaylistSummary> _playlists = [];
  List<ArtistSummary> _artists = [];
  List<AlbumSummary> _albums = [];
  String _error = '';

  // Results-cache identity: every cached list (_songs / _playlists /
  // _artists / _albums) belongs to one (query, platform) pair. A
  // search for a different pair clears all four lists first (see
  // _search), so switching types can show the cache only when the
  // pair matches — never another query's or platform's rows.
  String _cacheQuery = '';
  MusicPlatform? _cachePlatform;

  MusicPlayerController get _player => MusicPlayerController.ensure();

  @override
  void initState() {
    super.initState();
    _platform = SearchPlatformStore.current();
    _scrollController.addListener(_onScroll);
    _loadHot();
  }

  Future<void> _loadHot() async {
    final words = await _hotService.hotSearch(_platform);
    if (!mounted) return;
    setState(() {
      _hotWords = words;
    });
  }

  /// Platform picker sheet (Beans `RootView.PlatformPickerSheet`,
  /// RootView.swift:463-530: title 19 bold, rows padding h14 v12,
  /// glass rounded 14, checkmark for the current platform).
  Future<void> _openPlatformPicker() async {
    HaoHaptics.tap();
    final picked = await showModalBottomSheet<MusicPlatform>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final theme = HaoTheme.of(ctx);
        final options = SearchPlatformStore.options();
        return GlassCard(
          radius: 24,
          shadow: GlassShadow.panel,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '选择平台',
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              for (final pf in options)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: GlassCard(
                    radius: 14,
                    padding: EdgeInsets.zero,
                    shadow: GlassShadow.none,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => Navigator.of(ctx).pop(pf),
                        borderRadius: BorderRadius.circular(14),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              // Real brand logo (chen 2026-11-18), not
                              // the generic ♪ — the checkmark stays as
                              // the trailing selected marker.
                              PlatformLogo(platform: pf, size: 28),
                              const SizedBox(width: 10),
                              Text(
                                pf.displayName,
                                style: TextStyle(
                                  color: theme.textPrimary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const Spacer(),
                              if (pf == _platform)
                                Icon(
                                  Icons.check_circle,
                                  size: 18,
                                  color: theme.accent,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
    if (picked != null) unawaited(_selectPlatform(picked));
  }

  /// Capsule tap -> platform switch (Beans `SearchView` onChange of
  /// provider: persist, reload that platform's hot words, re-run the
  /// current query on the new platform; with no query, drop the stale
  /// results so the page never shows another platform's list).
  Future<void> _selectPlatform(MusicPlatform pf) async {
    if (pf == _platform) return;
    final ok = await SearchPlatformStore.set(pf);
    if (!ok || !mounted) return;
    setState(() {
      _platform = pf;
      _hotWords = [];
    });
    unawaited(_loadHot());
    final q = _queryController.text.trim();
    if (q.isEmpty) {
      _clearSearch();
    } else {
      unawaited(_search());
    }
  }

  @override
  void dispose() {
    unawaited(_searchSub?.cancel());
    unawaited(_playlistSub?.cancel());
    unawaited(_artistSub?.cancel());
    _prewarm.cancel();
    _coverBackfill.cancel();
    _queryController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    // No `_loading` guard: while a search streams in, already-loaded
    // rows can be revealed by scrolling; new legs append below.
    if (_type != _SearchType.song) return;
    if (_shown >= _songs.length) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      setState(
        () => _shown = (_shown + kSearchPageSize).clamp(0, _songs.length),
      );
      // Newly revealed rows may still be coverless — fill them too.
      _fillVisibleCovers(_pageGen);
    }
  }

  int _resultCountFor(_SearchType t) => switch (t) {
    _SearchType.song => _songs.length,
    _SearchType.playlist => _playlists.length,
    _SearchType.artist => _artists.length,
    _SearchType.album => _albums.length,
  };

  void _clearResultsFor(_SearchType t) {
    switch (t) {
      case _SearchType.song:
        _songs = [];
        _prewarm.cancel();
        _coverBackfill.cancel();
      case _SearchType.playlist:
        _playlists = [];
      case _SearchType.artist:
        _artists = [];
      case _SearchType.album:
        _albums = [];
    }
  }

  /// Switching the type tabs re-runs the current query for the new
  /// type — the old code only flipped _type, so the new type's list
  /// stayed empty until the user tapped search again (reported
  /// 2026-11-19). Cached results for the same query + platform are
  /// shown as-is, no re-search; an empty cache (never searched, or a
  /// new query) triggers one search. The old type's in-flight request
  /// is cancelled first so two types never run at once (they share
  /// _loading); if it was still loading, its partial list is dropped
  /// so switching back re-searches full results instead of presenting
  /// a partial list as complete.
  void _onTypeChanged(_SearchType next) {
    if (next == _type) return;
    if (_loading) _clearResultsFor(_type);
    _pageGen++;
    unawaited(_searchSub?.cancel());
    unawaited(_playlistSub?.cancel());
    unawaited(_artistSub?.cancel());
    setState(() => _type = next);
    if (!_searched) return;
    final q = _queryController.text.trim();
    if (q.isEmpty) return;
    if (_cacheQuery == q &&
        _cachePlatform == _platform &&
        _resultCountFor(next) > 0) {
      return;
    }
    unawaited(_search());
  }

  Future<void> _search() async {
    final q = _queryController.text.trim();
    if (q.isEmpty) return;
    // Record the term once a search is actually started — not on an
    // empty query, not when the page is just opened. Best-effort, and
    // fire-and-forget: the Hive write must not sit on the critical
    // path to the first result (the search starts immediately).
    unawaited(MusicStore.saveSearchQuery(q).catchError((_) {}));
    // A search for a new (query, platform) invalidates every cached
    // list, not just the current type's — otherwise switching types
    // would show another query's / platform's rows.
    if (q != _cacheQuery || _platform != _cachePlatform) {
      _cacheQuery = q;
      _cachePlatform = _platform;
      _songs = [];
      _playlists = [];
      _artists = [];
      _albums = [];
    }
    // Cancel any in-flight search and bump the generation before
    // dispatching, so the album branch (a single await, no stream)
    // also drops a stale run instead of letting it land behind the
    // new search. The per-type branches repeat this (their own
    // convention) — double cancel / double bump is harmless.
    _pageGen++;
    unawaited(_searchSub?.cancel());
    unawaited(_playlistSub?.cancel());
    unawaited(_artistSub?.cancel());
    if (_type == _SearchType.song) {
      _searchSongs(q);
      return;
    }
    if (_type == _SearchType.playlist) {
      _searchPlaylists(q);
      return;
    }
    if (_type == _SearchType.artist) {
      _searchArtists(q);
      return;
    }
    // Album only (stage 2): one platform, its own album endpoint —
    // still a single await, not streamed (no multi-leg fan-out).
    // Generation-guarded like the streams: a newer search (or a type
    // switch, which bumps _pageGen) makes this late completion a
    // no-op instead of clearing _loading under the new search.
    final gen = _pageGen;
    setState(() {
      _loading = true;
      _searched = true;
      _error = '';
      _shown = kSearchPageSize;
    });
    try {
      // _SearchType.album (stage 2): one platform, its own album
      // endpoint — see MusicApi.searchAlbums.
      final albums = await _api
          .searchAlbums(_platform, q)
          .catchError((_) => <AlbumSummary>[]);
      if (!mounted || gen != _pageGen) return;
      setState(() {
        _albums = albums;
        if (_albums.isEmpty) _error = '没搜到相关专辑';
      });
    } finally {
      if (mounted && gen == _pageGen) setState(() => _loading = false);
    }
  }

  /// Streaming playlist search: results appear as each platform leg
  /// returns (wy + kw, or just the capsule platform when set), the
  /// rest append after it — same generation guard and pending footer
  /// as [_searchSongs]. A leg that fails or times out contributes
  /// nothing and never blocks the others.
  void _searchPlaylists(String q) {
    final gen = ++_pageGen;
    unawaited(_searchSub?.cancel());
    unawaited(_playlistSub?.cancel());
    unawaited(_artistSub?.cancel());
    setState(() {
      _loading = true;
      _searched = true;
      _error = '';
      _shown = kSearchPageSize;
      _playlists = [];
      _pendingPlatforms = {};
    });
    _playlistSub = _searchService
        .searchPlaylistsStream(q, onlyPlatform: _platform)
        .listen(
          (update) {
            if (!mounted || gen != _pageGen) return;
            setState(() {
              _playlists = update.items;
              _pendingPlatforms = update.pending;
            });
          },
          onError: (_) {
            if (!mounted || gen != _pageGen) return;
            setState(() {
              _loading = false;
              _error = '搜索失败，请重试';
            });
          },
          onDone: () {
            if (!mounted || gen != _pageGen) return;
            setState(() {
              _loading = false;
              if (_playlists.isEmpty) _error = '没搜到相关歌单';
            });
          },
          cancelOnError: false,
        );
  }

  /// Streaming artist search: same convention as [_searchPlaylists]
  /// (legs wy + tx + kw, or just the capsule platform).
  void _searchArtists(String q) {
    final gen = ++_pageGen;
    unawaited(_searchSub?.cancel());
    unawaited(_playlistSub?.cancel());
    unawaited(_artistSub?.cancel());
    setState(() {
      _loading = true;
      _searched = true;
      _error = '';
      _shown = kSearchPageSize;
      _artists = [];
      _pendingPlatforms = {};
    });
    _artistSub = _searchService
        .searchArtistsStream(q, onlyPlatform: _platform)
        .listen(
          (update) {
            if (!mounted || gen != _pageGen) return;
            setState(() {
              _artists = update.items;
              _pendingPlatforms = update.pending;
            });
          },
          onError: (_) {
            if (!mounted || gen != _pageGen) return;
            setState(() {
              _loading = false;
              _error = '搜索失败，请重试';
            });
          },
          onDone: () {
            if (!mounted || gen != _pageGen) return;
            setState(() {
              _loading = false;
              if (_artists.isEmpty) _error = '没搜到相关歌手';
            });
          },
          cancelOnError: false,
        );
  }

  /// Streaming song search: results appear as each platform leg
  /// returns (the fastest, usually ~1 s), the rest append after it.
  /// Starting a new search cancels the old subscription and bumps the
  /// generation, so stale emissions can never touch the new list.
  void _searchSongs(String q) {
    final gen = ++_pageGen;
    unawaited(_searchSub?.cancel());
    unawaited(_playlistSub?.cancel());
    unawaited(_artistSub?.cancel());
    _prewarm.cancel();
    _coverBackfill.cancel();
    setState(() {
      _loading = true;
      _searched = true;
      _error = '';
      _shown = kSearchPageSize;
      _songs = [];
      _pendingPlatforms = {};
    });
    _searchSub = _searchService
        .searchAllStream(q, onlyPlatform: _platform)
        .listen(
          (update) {
            if (!mounted || gen != _pageGen) return;
            setState(() {
              // Re-apply already-known covers: the service re-emits the
              // whole list on every leg settle, which would otherwise
              // wipe a cover filled a moment ago.
              _songs = _coverBackfill.applyCached(update.songs);
              _pendingPlatforms = update.pending;
            });
            // Warm the first few visible rows' URLs while the user is
            // still looking, so tapping one plays from the cache.
            _prewarm.prewarm(update.songs);
            // Fill the visible rows' missing covers from NetEase.
            _fillVisibleCovers(gen);
          },
          onError: (_) {
            if (!mounted || gen != _pageGen) return;
            setState(() {
              _loading = false;
              _error = '搜索失败，请重试';
            });
          },
          onDone: () {
            if (!mounted || gen != _pageGen) return;
            setState(() {
              _loading = false;
              if (_songs.isEmpty) _error = '没搜到';
            });
          },
          cancelOnError: false,
        );
  }

  /// Fill empty covers of the currently visible rows from NetEase
  /// (serial, cached, generation-guarded — see SearchCoverBackfill).
  /// Called on every streaming update and when scrolling reveals more
  /// rows. A filled cover is merged by identityKey; the callback's
  /// generation check keeps a stale run from touching the new list.
  void _fillVisibleCovers(int gen) {
    _coverBackfill.fill(_songs.take(_shown).toList(), (filled) {
      if (!mounted || gen != _pageGen) return;
      setState(() {
        _songs = _songs
            .map((s) => s.identityKey == filled.identityKey ? filled : s)
            .toList();
      });
    });
  }

  /// Clear the query and reset to the idle (history) state (Beans
  /// search-field × button): cancels any streaming search so no stale
  /// leg can repopulate the list after the clear.
  void _clearSearch() {
    _pageGen++;
    unawaited(_searchSub?.cancel());
    unawaited(_playlistSub?.cancel());
    unawaited(_artistSub?.cancel());
    _prewarm.cancel();
    _coverBackfill.cancel();
    _queryController.clear();
    _cacheQuery = '';
    _cachePlatform = null;
    setState(() {
      _loading = false;
      _searched = false;
      _error = '';
      _songs = [];
      _playlists = [];
      _artists = [];
      _albums = [];
      _pendingPlatforms = {};
    });
  }

  /// Footer text while legs are still pending, e.g. "正在搜索 QQ、酷狗…".
  /// Falls back to a plain "正在搜索…" when no platform names are known
  /// (the last update already settled every leg — transient).
  String get _pendingLabel {
    if (_pendingPlatforms.isEmpty) return '正在搜索…';
    final names = _pendingPlatforms.map((p) => p.badgeName).join('、');
    return '正在搜索 $names…';
  }

  /// Bottom "still searching…" row while legs are pending (same as the
  /// song list's footer). Only rendered when the list already has rows
  /// — with no rows yet the full-screen spinner shows instead.
  Widget _pendingFooter(HaoTheme theme) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(_pendingLabel, style: TextStyle(color: theme.textMuted)),
        ],
      ),
    );
  }

  void _playSong(Song song, List<Song> queue) {
    final idx = queue.indexWhere((s) => s.identityKey == song.identityKey);
    unawaited(_player.playQueue(queue, idx < 0 ? 0 : idx));
    unawaited(
      Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const MusicPlayerPage())),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackground,
      appBar: AppBar(title: const Text('搜歌')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: GlassCard(
              radius: 18,
              padding: const EdgeInsets.symmetric(
                horizontal: 15,
                vertical: 6,
              ),
              shadow: GlassShadow.small,
              child: Row(
                children: [
                  Icon(Icons.search, size: 15, color: theme.textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 32,
                      child: TextField(
                        controller: _queryController,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) {
                          HaoHaptics.tap();
                          _search();
                        },
                        decoration: InputDecoration(
                          hintText: '搜索歌曲 / 歌手…',
                          hintStyle: TextStyle(color: theme.textMuted),
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 20,
                    height: 22,
                    child: _loading
                        ? const Padding(
                            padding: EdgeInsets.all(3),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : ValueListenableBuilder<TextEditingValue>(
                            valueListenable: _queryController,
                            builder: (ctx, value, _) {
                              if (value.text.isEmpty) {
                                return const SizedBox.shrink();
                              }
                              return IconButton(
                                icon: Icon(
                                  Icons.cancel,
                                  color: theme.textMuted,
                                  size: 15,
                                ),
                                padding: EdgeInsets.zero,
                                onPressed: () {
                                  HaoHaptics.tap();
                                  _clearSearch();
                                },
                              );
                            },
                          ),
                  ),
                  const SizedBox(width: 6),
                  GlassPressScale(
                    pressedScale: 0.9,
                    child: GlassCard(
                      radius: 999,
                      padding: EdgeInsets.zero,
                      shadow: GlassShadow.none,
                      child: SizedBox(
                        width: 54,
                        height: 30,
                        child: TextButton(
                          onPressed: _loading
                              ? null
                              : () {
                                  HaoHaptics.tap();
                                  _search();
                                },
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(
                            '搜索',
                            style: TextStyle(
                              color: theme.accent,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Type tabs (Beans `typeTabs` capsule segmented control):
          // 歌曲 / 歌单 / 歌手 / 专辑 under the field, full width. The
          // SegmentedButton styling comes from the theme.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: SegmentedButton<_SearchType>(
                    segments: const [
                      ButtonSegment(value: _SearchType.song, label: Text('歌曲')),
                      ButtonSegment(
                        value: _SearchType.playlist,
                        label: Text('歌单'),
                      ),
                      ButtonSegment(
                        value: _SearchType.artist,
                        label: Text('歌手'),
                      ),
                      ButtonSegment(
                        value: _SearchType.album,
                        label: Text('专辑'),
                      ),
                    ],
                    selected: {_type},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) => _onTypeChanged(s.first),
                  ),
                ),
                const SizedBox(width: 8),
                // Platform capsule (stage 2, Beans `SearchView` right-
                // top "网易云音乐 ⌄" / `RootView` PlatformPickerSheet):
                // current platform (name + ⌄), tap opens the picker.
                // No "全部" — one platform at a time.
                _PlatformCapsule(
                  platform: _platform,
                  onTap: () => unawaited(_openPlatformPicker()),
                ),
              ],
            ),
          ),
          Expanded(child: _results(theme)),
        ],
      ),
    );
  }

  Widget _results(HaoTheme theme) {
    // Streaming: show the list as soon as the first leg returns, even
    // while other legs are still pending. The full-screen spinner is
    // only for "nothing yet" (the current type's list is still empty);
    // once rows exist, the pending legs show as a footer row instead.
    final listEmpty = switch (_type) {
      _SearchType.song => _songs.isEmpty,
      _SearchType.playlist => _playlists.isEmpty,
      _SearchType.artist => _artists.isEmpty,
      _SearchType.album => _albums.isEmpty,
    };
    if (_loading && listEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_searched) {
      final history = MusicStore.getSearchHistory();
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        children: [
          if (history.isNotEmpty)
            _SearchHistory(
              history: history,
              onTap: (q) {
                HaoHaptics.tap();
                _queryController.text = q;
                unawaited(_search());
              },
              onClear: () async {
                HaoHaptics.tap();
                await MusicStore.clearSearchHistory();
                if (mounted) setState(() {});
              },
              onRemove: (q) async {
                HaoHaptics.tap();
                await MusicStore.removeSearchQuery(q);
                if (mounted) setState(() {});
              },
            ),
          // Hot search (Beans `SearchView.hotSection`): ranked pills,
          // top 3 with an icon badge, 4-10 with a number. Shown only
          // when the platform really returned words — an empty list
          // hides the section instead of showing fake words.
          if (_hotWords.isNotEmpty) ...[
            if (history.isNotEmpty) const SizedBox(height: 28),
            _HotSearch(
              title: '${_platform.displayName}热搜',
              words: _hotWords,
              onTap: (q) {
                HaoHaptics.tap();
                _queryController.text = q;
                unawaited(_search());
              },
            ),
          ],
        ],
      );
    }
    if (_error.isNotEmpty) {
      // Beans `ErrorStateView`: icon + message + retry (re-runs the
      // same query — the "没搜到" empty case lands here too, and retry
      // is harmless there).
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_off, size: 44, color: theme.textMuted),
              const SizedBox(height: 12),
              Text(
                _error,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.textSecondary, fontSize: 15),
              ),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _search, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    switch (_type) {
      case _SearchType.song:
        final shown = _songs.take(_shown).toList();
        final favIds = MusicStore.getFavIds();
        // Beans song-list header: result count + "播放全部" (plays
        // from the first result). Pinned above the list so it is
        // reachable without scrolling back to the top.
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  Text(
                    // Count only — the platform is already in the
                    // switch capsule above, so no "找到 N 首 · 平台" echo.
                    '${_songs.length} 首',
                    style: TextStyle(color: theme.textMuted, fontSize: 12),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _songs.isEmpty
                        ? null
                        : () => _playSong(_songs.first, _songs),
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: const Text('播放全部', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                itemCount: shown.length + 1,
                itemBuilder: (ctx, i) {
                  if (i >= shown.length) {
                    if (_loading) {
                      // Legs still pending: more results may arrive. Never
                      // show "已加载全部" while a search is still streaming.
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _pendingLabel,
                              style: TextStyle(color: theme.textMuted),
                            ),
                          ],
                        ),
                      );
                    }
                    final hasMore = _songs.length > _shown;
                    // More rows are already in hand — scrolling reveals
                    // them, so nothing is shown while there are more.
                    // Only the end of the list gets a footer.
                    if (hasMore) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '已加载全部',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.textMuted),
                      ),
                    );
                  }
                  final song = shown[i];
                  return SongRow(
                    song: song,
                    isFav: favIds.contains(song.identityKey),
                    onPlay: () => _playSong(song, _songs),
                    onToggleFav: () async {
                      await _player.toggleFav(song);
                      setState(() {});
                    },
                    onOpenArtist: () => _openArtist(song),
                    onOpenAlbum: song.album.isEmpty
                        ? null
                        : () => _openAlbum(song),
                    onLongPress: (rowCtx) =>
                        unawaited(openSongQuickMenu(rowCtx, song)),
                  );
                },
              ),
            ),
          ],
        );
      case _SearchType.playlist:
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  Text(
                    // Count only (see the song header above).
                    '${_playlists.length} 个',
                    style: TextStyle(color: theme.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: _playlists.length + (_loading ? 1 : 0),
                itemBuilder: (ctx, i) {
                  if (i >= _playlists.length) return _pendingFooter(theme);
                  final p = _playlists[i];
                  return GlassCard(
                    radius: 16,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Material(
                      color: Colors.transparent,
                      child: ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: p.cover.isEmpty
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
                                  image: MusicImageProvider(p.cover),
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
                        title: Text(
                          p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: theme.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          '${p.platform.displayName} · ${p.creator} · ${p.playCount}次播放',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: theme.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                        trailing: Icon(
                          Icons.chevron_right,
                          color: theme.textMuted,
                        ),
                        onTap: () {
                          HaoHaptics.tap();
                          _openPlazaDetail(p);
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      case _SearchType.artist:
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  Text(
                    // Count only (see the song header above).
                    '${_artists.length} 位',
                    style: TextStyle(color: theme.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: _artists.length + (_loading ? 1 : 0),
                itemBuilder: (ctx, i) {
                  if (i >= _artists.length) return _pendingFooter(theme);
                  final a = _artists[i];
                  return GlassCard(
                    radius: 16,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Material(
                      color: Colors.transparent,
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundImage: a.cover.isEmpty
                              ? null
                              : MusicImageProvider(a.cover),
                          backgroundColor: theme.accentSoft,
                          child: a.cover.isEmpty
                              ? Icon(Icons.person, color: theme.textMuted)
                              : null,
                        ),
                        title: Text(
                          a.name,
                          style: TextStyle(
                            color: theme.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          '${a.platform.displayName} · ${a.musicSize} 首 · ${a.albumSize} 张专辑',
                          style: TextStyle(
                            color: theme.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                        trailing: Icon(
                          Icons.chevron_right,
                          color: theme.textMuted,
                        ),
                        onTap: () {
                          HaoHaptics.tap();
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => ArtistDetailPage(
                                platform: a.platform,
                                artistId: a.id,
                                artistName: a.name,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      case _SearchType.album:
        // Stage 2 album results (Beans `SearchView.albumResultsArea`,
        // SearchView.swift:678-730): count-only header, rows cover
        // 46/radius 10 + name + artist, tap opens the existing
        // AlbumDetailPage. GlassCard rows match the other search types
        // on this page.
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  Text(
                    // Count only (see the song header above).
                    '${_albums.length} 张',
                    style: TextStyle(color: theme.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: _albums.length,
                itemBuilder: (ctx, i) {
                  final a = _albums[i];
                  final subtitle = a.year > 0
                      ? '${a.artist} · ${a.year}年'
                      : a.artist;
                  return GlassCard(
                    radius: 16,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Material(
                      color: Colors.transparent,
                      child: ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: a.cover.isEmpty
                              ? Container(
                                  width: 46,
                                  height: 46,
                                  color: theme.accentSoft,
                                  child: Icon(
                                    Icons.album,
                                    color: theme.textMuted,
                                  ),
                                )
                              : Image(
                                  image: MusicImageProvider(a.cover),
                                  width: 46,
                                  height: 46,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => Container(
                                    width: 46,
                                    height: 46,
                                    color: theme.accentSoft,
                                    child: Icon(
                                      Icons.album,
                                      color: theme.textMuted,
                                    ),
                                  ),
                                ),
                        ),
                        title: Text(
                          a.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: theme.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: theme.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                        trailing: Icon(
                          Icons.chevron_right,
                          color: theme.textMuted,
                        ),
                        onTap: () {
                          HaoHaptics.tap();
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => AlbumDetailPage(
                                platform: a.platform,
                                albumId: a.id,
                                albumName: a.name,
                                artistName: a.artist,
                                albumCover: a.cover,
                                albumYear: a.year,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
    }
  }

  void _openArtist(Song song) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ArtistDetailPage(
          platform: song.platform,
          artistId: '',
          artistName: firstArtist(song.artist),
        ),
      ),
    );
  }

  void _openAlbum(Song song) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AlbumDetailPage(
          platform: song.platform,
          albumId: '',
          albumName: song.album,
          artistName: firstArtist(song.artist),
        ),
      ),
    );
  }

  void _openPlazaDetail(PlaylistSummary p) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PlazaDetailPage(playlist: p)),
    );
  }
}

/// Search history section — Beans `SearchHistorySection`
/// (SearchHistorySection.swift). Numbers copied: title 15 bold,
/// "清空" 12 medium with a trash icon, chips in a flow with 8pt
/// spacing, chip = clock 10 medium + word 13 medium, spacing 4,
/// padding h12 v7, glass capsule; the per-chip x is a separate
/// 16x16 circle button (xmark 9 bold, muted 0.8).
/// Behaviour unchanged: tap a chip re-runs the search, x deletes just
/// that term, 清空 clears all.
class _SearchHistory extends StatelessWidget {
  const _SearchHistory({
    required this.history,
    required this.onTap,
    required this.onClear,
    required this.onRemove,
  });

  final List<String> history;
  final void Function(String query) onTap;
  final VoidCallback onClear;
  final void Function(String query) onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '搜索历史',
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: onClear,
              icon: Icon(Icons.delete_outline, size: 14, color: theme.textMuted),
              label: Text(
                '清除',
                style: TextStyle(
                  color: theme.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: history
              .take(8)
              .map(
                (q) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GlassPressScale(
                      pressedScale: 0.97,
                      child: GlassCard(
                        radius: 999,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        shadow: GlassShadow.none,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => onTap(q),
                            borderRadius: BorderRadius.circular(999),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.history,
                                  size: 10,
                                  color: theme.textPrimary,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  q,
                                  style: TextStyle(
                                    color: theme.textPrimary,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => onRemove(q),
                          customBorder: const CircleBorder(),
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: theme.surfaceStrong,
                              border: Border.all(color: theme.hairline),
                            ),
                            child: Icon(
                              Icons.clear,
                              size: 9,
                              color: theme.textMuted.withValues(alpha: 0.8),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              )
              .toList(),
        ),
      ],
    );
  }
}

/// Hot search pills — Beans `SearchView.hotTag` (SearchView.swift:
/// 467-535). Numbers copied: FlowLayout spacing 10, pill padding h14
/// v9, content spacing 7, top-3 badge circle 24 with icon 10 bold,
/// word 15 bold (top 3) / 14 medium (rest), rank number 11 bold in an
/// 18-wide frame, press scale 0.92.
///
/// Deviation: Beans' top-3 badge is a coloured gradient (orange-red /
/// gold / ice-blue) with a glow shadow. Not copied: the ice-blue
/// breaks the blue->black rule and the orange-red breaks the
/// less-red rule. The badge is the theme accent instead (black in
/// light mode, dark grey in dark mode) with a white icon — the same
/// monochrome treatment as the rest of the app.
class _HotSearch extends StatelessWidget {
  const _HotSearch({
    required this.title,
    required this.words,
    required this.onTap,
  });

  final String title;
  final List<String> words;
  final void Function(String query) onTap;

  static const _topIcons = [
    Icons.workspace_premium, // crown
    Icons.whatshot, // flame
    Icons.auto_awesome, // sparkles
  ];

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: theme.textPrimary,
            fontSize: 21,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (var i = 0; i < words.length; i++)
              GlassPressScale(
                pressedScale: 0.92,
                child: GlassCard(
                  radius: 999,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                  shadow: GlassShadow.none,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => onTap(words[i]),
                      borderRadius: BorderRadius.circular(999),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (i < 3)
                            Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: theme.accent,
                              ),
                              child: Icon(
                                _topIcons[i],
                                size: 10,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onPrimary,
                              ),
                            )
                          else
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: Center(
                                child: Text(
                                  '${i + 1}',
                                  style: TextStyle(
                                    color: theme.textMuted,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          const SizedBox(width: 7),
                          Text(
                            words[i],
                            style: TextStyle(
                              color: i < 3
                                  ? theme.textPrimary
                                  : theme.textSecondary,
                              fontSize: i < 3 ? 15 : 14,
                              fontWeight: i < 3
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Platform capsule (stage 2, Beans `SearchView` right-top capsule:
/// current platform name + ⌄, tap opens the picker).
///
/// Beans' own capsule is the segmented `providerPicker`
/// (SearchView.swift:343-380: per-platform pill, selected pill filled
/// with the platform tint, 13 semibold, h6 spacing, v9 padding, capsule
/// container padding 4). This page keeps the existing full-width
/// segmented TYPE control and puts the platform in a single capsule
/// button beside it instead — the task's spec ("胶囊显示当前平台
/// logo + 名称 + ⌄，点开切换") — so the two segmented controls do not
/// fight for the same row. Colours come from the theme only (no
/// platform-brand tints: Beans' red/green tints break the less-red /
/// blue->black rules).
class _PlatformCapsule extends StatelessWidget {
  const _PlatformCapsule({required this.platform, required this.onTap});

  final MusicPlatform platform;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GlassPressScale(
      pressedScale: 0.97,
      child: GlassCard(
        radius: 999,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        shadow: GlassShadow.none,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              HaoHaptics.tap();
              onTap();
            },
            borderRadius: BorderRadius.circular(999),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PlatformLogo(platform: platform, size: 18),
                const SizedBox(width: 6),
                Text(
                  platform.displayName,
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.keyboard_arrow_down,
                  size: 16,
                  color: theme.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
