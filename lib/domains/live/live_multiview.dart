// ignore_for_file: prefer_initializing_formals
// Multi-view (same screen, 2 / 4 rooms) — item 14 (build 29, I group).
//
// Focus state + low-quality rule, pure Dart. The page
// (live_multiview_page.dart) owns one [LiveMultiViewState]: the
// focused cell is the only one with sound (its session volume is
// 1.0; every other cell is muted at 0.0), and every non-focused cell
// plays its LOWEST quality tier (bandwidth for 4 simultaneous
// streams is the real constraint — a 4-way grid at 原画 would stall
// on most connections). Tapping a cell focuses it (sound moves,
// quality upgrades to the preferred tier); the previously focused
// cell drops back to muted + low quality.
//
// Quality order: the adapters list tiers high -> low (原画 first),
// so the lowest tier is the last element; when a "流畅" tier exists
// it is preferred explicitly (a platform that appends an odd tier
// after 流畅 must not make the cell play it).

import '../../core/models/live_models.dart';

/// Focus + layout state for one multi-view session.
class LiveMultiViewState {
  LiveMultiViewState({required int roomCount, int columns = 2})
    : _roomCount = roomCount,
      columns = columns.clamp(1, 2);

  int _roomCount;

  /// Grid columns: 2 (2 or 4 rooms). A 2-room session is 1 column x
  /// 2 rows when [columns] is 1, 2x1 when 2 — the page picks.
  final int columns;

  int _focusedIndex = 0;

  int get roomCount => _roomCount;
  int get focusedIndex => _focusedIndex;

  /// Focus [index] (clamped). Returns true when the focus moved.
  bool focus(int index) {
    final next = index.clamp(0, _roomCount - 1);
    if (next == _focusedIndex) return false;
    _focusedIndex = next;
    return true;
  }

  /// True when [index] is the sounding cell.
  bool isFocused(int index) => index == _focusedIndex;

  /// Session volume for [index]: 1.0 focused, 0.0 otherwise.
  double volumeFor(int index) => isFocused(index) ? 1.0 : 0.0;

  /// Replace the room list (e.g. the user swapped a cell's room).
  /// Focus is kept when it still points at a room, else reset to 0.
  void setRoomCount(int count) {
    _roomCount = count;
    if (_focusedIndex >= _roomCount) _focusedIndex = 0;
  }
}

/// Lowest-quality tier index for a cell that is NOT focused.
/// Prefers the "流畅" tier when the room offers one, else the last
/// (lowest) tier. Empty list -> 0.
int lowQualityIndex(List<LivePlayQuality> qualities) {
  if (qualities.isEmpty) return 0;
  final smooth = qualities.indexWhere((q) => q.quality == '流畅');
  if (smooth >= 0) return smooth;
  return qualities.length - 1;
}
