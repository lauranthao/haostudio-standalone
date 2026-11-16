// Live tab data layer — drives the room grid from real adapter data.
//
// The controller owns all fetching state (platform, category, pagination,
// loading / empty / error) and talks to platforms ONLY through the
// LiveSite contract (Sites.of / getRecommendRooms / getCategoryRooms /
// getCategories). It never fabricates rooms: an adapter that returns []
// (e.g. a platform whose adapter has not landed yet) surfaces as an
// honest empty state, never as placeholder cards.
//
// Stale-response guard: every fetch bumps [_epoch]; a response whose
// epoch no longer matches is discarded, so a slow platform-A request can
// never overwrite platform-B rooms after a fast switch.

import 'package:flutter/foundation.dart';

import '../../../core/models/live_models.dart';
import '../../../shared/platforms/live_site.dart';
import '../../../shared/platforms/sites.dart';

/// What the grid should show right now.
enum LiveTabStatus {
  /// First page (or a platform/category switch) is in flight.
  loading,

  /// At least one room is on screen.
  ready,

  /// The platform returned no rooms at all.
  empty,

  /// The first page failed — nothing to show, offer a retry.
  error,
}

class LiveTabController extends ChangeNotifier {
  LiveTabController({
    LiveSite Function(String platformId)? siteOf,
    String initialPlatform = Sites.bilibiliSite,
  })  : _siteOf = siteOf ?? Sites.of,
        _platform = initialPlatform;

  final LiveSite Function(String platformId) _siteOf;

  /// Page size sent to the adapters (their default is 30).
  static const int pageSize = 30;

  String _platform;
  String get platform => _platform;

  List<LiveRoom> _rooms = const [];
  List<LiveRoom> get rooms => _rooms;

  List<LiveArea> _categories = const [];
  List<LiveArea> get categories => _categories;

  /// Null = "全部" (recommend list); non-null = that category's rooms.
  LiveArea? _selectedArea;
  LiveArea? get selectedArea => _selectedArea;

  LiveTabStatus _status = LiveTabStatus.loading;
  LiveTabStatus get status => _status;

  /// Human-readable failure for the first-page load (null unless error).
  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  /// True when the last page came back full — there may be more.
  bool _hasMore = false;
  bool get hasMore => _hasMore;

  /// A pagination request is in flight.
  bool _loadingMore = false;
  bool get loadingMore => _loadingMore;

  /// The last pagination request failed; the footer offers a retry.
  /// The rooms already on screen are kept.
  bool _loadMoreFailed = false;
  bool get loadMoreFailed => _loadMoreFailed;

  int _page = 1;
  int _epoch = 0;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// First load for the current platform (call once from the page).
  Future<void> loadInitial() => _load();

  /// Pull-to-refresh / empty- and error-state retry.
  Future<void> refresh() => _load();

  Future<void> retry() => _load();

  /// Switch platform: resets rooms, category and pagination, then loads
  /// page 1 of the new platform. A no-op when already on that platform
  /// (unless it previously errored, in which case this retries).
  Future<void> selectPlatform(String id) async {
    if (id == _platform && _status != LiveTabStatus.error) return;
    _platform = id;
    _selectedArea = null;
    await _load();
  }

  /// Switch category (null = "全部" / recommend list). Resets pagination.
  Future<void> selectCategory(LiveArea? area) async {
    if (area?.areaId == _selectedArea?.areaId) return;
    _selectedArea = area;
    await _load();
  }

  /// Next page, appended to the rooms already shown. No-op when there is
  /// no next page, when a page is already loading, or when the first page
  /// has not loaded successfully yet.
  Future<void> loadMore() async {
    if (_loadingMore || !_hasMore) return;
    if (_status != LiveTabStatus.ready) return;
    _loadingMore = true;
    _loadMoreFailed = false;
    notifyListeners();
    final epoch = _epoch;
    try {
      final next = await _fetchRooms(page: _page + 1);
      if (_disposed || epoch != _epoch) return;
      _page += 1;
      _rooms = [..._rooms, ...next];
      _hasMore = next.length >= pageSize;
    } catch (_) {
      if (_disposed || epoch != _epoch) return;
      // Keep the rooms already shown; the footer offers a retry.
      _loadMoreFailed = true;
    } finally {
      if (!_disposed && epoch == _epoch) {
        _loadingMore = false;
        notifyListeners();
      }
    }
  }

  Future<void> _load() async {
    final epoch = ++_epoch;
    _page = 1;
    _rooms = const [];
    _hasMore = false;
    _loadingMore = false;
    _loadMoreFailed = false;
    _status = LiveTabStatus.loading;
    _errorMessage = null;
    notifyListeners();
    final site = _siteOf(_platform);
    try {
      // Categories are optional garnish: a failure there must never fail
      // the room list, and a platform with no categories just shows none.
      final roomsFuture = _fetchRooms(site: site, page: 1);
      final categoriesFuture = _fetchCategories(site);
      final results = await Future.wait([
        roomsFuture,
        categoriesFuture,
      ]);
      if (_disposed || epoch != _epoch) return;
      final rooms = results[0] as List<LiveRoom>;
      final categories = results[1] as List<LiveArea>;
      _rooms = rooms;
      _categories = categories;
      _hasMore = rooms.length >= pageSize;
      _status = rooms.isEmpty ? LiveTabStatus.empty : LiveTabStatus.ready;
    } catch (e) {
      if (_disposed || epoch != _epoch) return;
      _rooms = const [];
      _hasMore = false;
      _status = LiveTabStatus.error;
      _errorMessage = e.toString();
    }
    if (!_disposed && epoch == _epoch) notifyListeners();
  }

  Future<List<LiveRoom>> _fetchRooms({
    required int page,
    LiveSite? site,
  }) async {
    final s = site ?? _siteOf(_platform);
    final area = _selectedArea;
    if (area != null) {
      return s.getCategoryRooms(area, page: page, pageSize: pageSize);
    }
    return s.getRecommendRooms(page: page, pageSize: pageSize);
  }

  Future<List<LiveArea>> _fetchCategories(LiveSite site) async {
    try {
      return await site.getCategories();
    } catch (_) {
      return const <LiveArea>[];
    }
  }
}
