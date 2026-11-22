// Fullscreen corner clock — item 12 (build 29, I group).
//
// A live clock over the fullscreen video. Position is one of the
// four corners, persisted in Hive (literal key — HiveKeys is owned
// by the settings group); tapping the clock cycles the corner, so
// it never needs a settings row. The clock only renders in
// fullscreen (the room page gates it on the fullscreen flag) and
// never intercepts gestures that belong to the video (it is a small
// tap target of its own; the video gesture layer sits below it in
// the Stack).
//
// Style: white text on a dark pill — legible over any frame in
// every theme/mode, same treatment as the watching pill. Time is
// local HH:mm, ticking once a second.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/storage/hive_store.dart';

/// Hive key for the clock corner (string, one of the
/// [LiveClockCorner] names).
const String liveClockCornerKey = 'hao_live_clock_corner';

/// The four corners the fullscreen clock can sit in.
enum LiveClockCorner {
  topLeft('左上'),
  topRight('右上'),
  bottomLeft('左下'),
  bottomRight('右下');

  const LiveClockCorner(this.label);

  final String label;

  /// Next corner clockwise (tap cycles: 左上 -> 右上 -> 右下 -> 左下).
  LiveClockCorner get next => switch (this) {
    LiveClockCorner.topLeft => LiveClockCorner.topRight,
    LiveClockCorner.topRight => LiveClockCorner.bottomRight,
    LiveClockCorner.bottomRight => LiveClockCorner.bottomLeft,
    LiveClockCorner.bottomLeft => LiveClockCorner.topLeft,
  };

  static LiveClockCorner fromName(String? name) {
    for (final c in LiveClockCorner.values) {
      if (c.name == name) return c;
    }
    return LiveClockCorner.topRight;
  }
}

LiveClockCorner loadClockCorner() {
  try {
    return LiveClockCorner.fromName(
      HiveStore.getString(liveClockCornerKey, 'topRight'),
    );
  } catch (_) {
    return LiveClockCorner.topRight;
  }
}

Future<void> saveClockCorner(LiveClockCorner corner) =>
    HiveStore.put(liveClockCornerKey, corner.name);

/// Format HH:mm for [time] (local). Pure, unit-testable.
String formatClockTime(DateTime time) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}';
}

/// The clock itself: a dark pill with the current time, ticking once
/// a second. Tapping it cycles the corner ([onCornerChanged] fires
/// with the new corner — the parent re-positions it).
class LiveFullscreenClock extends StatefulWidget {
  const LiveFullscreenClock({
    super.key,
    required this.corner,
    required this.onCornerChanged,
  });

  final LiveClockCorner corner;
  final ValueChanged<LiveClockCorner> onCornerChanged;

  @override
  State<LiveFullscreenClock> createState() => _LiveFullscreenClockState();
}

class _LiveFullscreenClockState extends State<LiveFullscreenClock> {
  late Timer _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => widget.onCornerChanged(widget.corner.next),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xA6000000),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          formatClockTime(_now),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}
