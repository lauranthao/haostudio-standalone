// VOD player control clusters, iOS-native (build 29, K group).
//
// iOS: the real SwiftUI buttons from
// ios/Runner/VodControlsPlugin.swift, hosted in a `UiKitView` —
// transport cluster (prev / play-pause / next, 144x48) and trailing
// cluster (rate + exit-fullscreen, 112x48). Other platforms, or
// when [nativeEnabled] is false (the default): the Flutter buttons
// verbatim — same icons, sizes, tooltips, callbacks — so the page
// behaves exactly as before until G group registers the plugin
// (AppDelegate + Runner target) and the page flips the flag.
//
// Why only these two clusters are native (H group's three points):
//   (a) They are tap-only — no drag ever starts on them, so a
//       PlatformView here cannot eat the drag-seek gesture. The
//       Slider and the line pills stay Flutter.
//   (b) No size negotiation: both clusters are fixed-width and the
//       rate label is bounded to 5 chars ("1.25x") in a fixed
//       56 px button. Line names stay Flutter.
//   (c) The fallback below IS the Flutter fallback — the page
//       renders this widget unconditionally and the flag only
//       chooses the implementation.
//
// Single source of truth: the Flutter-side props ([playing] /
// [rateLabel]). The native view only mirrors them — Dart pushes
// `setState` when props change, the native side only reports user
// taps as `onTap` {id, action} on the events channel, and Dart
// echoes nothing back for its own taps (the parent rebuild carries
// the same value, so `didUpdateWidget` sees no diff). No second
// state is created anywhere.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/hao_themes.dart';

/// Platform-view type registered by VodControlsPlugin.
const String nativeVodControlsViewType =
    'com.haostudio.standalone/vod_controls';

/// Command channel (Dart -> native): setState {playing?, rateLabel?}.
/// Must match ios/Runner/VodControlsPlugin.swift.
const String nativeVodControlsCommandChannel =
    'com.haostudio.standalone/vod_controls';

/// Event channel (native -> Dart): onTap {id, action}. Must match
/// ios/Runner/VodControlsPlugin.swift.
const String nativeVodControlsEventChannel =
    'com.haostudio.standalone/vod_controls/events';

/// Actions the native clusters report. The raw values must match
/// the Swift `VodControlAction` enum.
enum VodControlAction {
  prev,
  playPause,
  next,
  rate,
  exit;

  static VodControlAction? fromName(String? name) {
    for (final action in VodControlAction.values) {
      if (action.name == name) return action;
    }
    return null;
  }
}

enum _VodControlsCluster { transport, trailing }

/// One of the two native VOD control clusters.
///
/// [NativeVodControls.transport]: prev / play-pause / next, 144x48.
/// [NativeVodControls.trailing]: rate label + exit-fullscreen, 112x48.
/// [onAction] receives the tapped action; the page maps it to the
/// existing callbacks (`_goEpisode`, play/pause + hide-timer re-arm,
/// `_cycleRate`, `_close`).
class NativeVodControls extends StatefulWidget {
  const NativeVodControls.transport({
    super.key,
    required this.playing,
    required this.onAction,
    this.nativeEnabled = false,
  })  : _cluster = _VodControlsCluster.transport,
        rateLabel = '1.0x';

  const NativeVodControls.trailing({
    super.key,
    required this.rateLabel,
    required this.onAction,
    this.nativeEnabled = false,
  })  : _cluster = _VodControlsCluster.trailing,
        playing = false;

  final _VodControlsCluster _cluster;

  /// Transport only: whether the play/pause button shows pause.
  final bool playing;

  /// Trailing only: the rate label ("1.0x", "1.25x", …).
  final String rateLabel;

  final ValueChanged<VodControlAction> onAction;

  /// False (default) = Flutter fallback on every platform.
  /// True + iOS = the SwiftUI view (needs the plugin registered).
  final bool nativeEnabled;

  @override
  State<NativeVodControls> createState() => _NativeVodControlsState();
}

class _NativeVodControlsState extends State<NativeVodControls> {
  static const MethodChannel _commandChannel =
      MethodChannel(nativeVodControlsCommandChannel);
  static const MethodChannel _eventChannel =
      MethodChannel(nativeVodControlsEventChannel);

  static int _nextId = 1;
  static final Map<int, _NativeVodControlsState> _live = {};
  static bool _eventsInstalled = false;

  late final int _id;

  /// Last state the native view holds (or the fallback rendered).
  /// Initialised from the props; updated on native taps and on
  /// prop changes, so a push only happens on a real diff.
  late bool _nativePlaying;
  late String _nativeRateLabel;

  bool get _isIOS => defaultTargetPlatform == TargetPlatform.iOS;
  bool get _useNative => widget.nativeEnabled && _isIOS;
  bool get _isTransport =>
      widget._cluster == _VodControlsCluster.transport;

  @override
  void initState() {
    super.initState();
    _id = _nextId++;
    _nativePlaying = widget.playing;
    _nativeRateLabel = widget.rateLabel;
    _live[_id] = this;
    _installEventHandler();
  }

  static void _installEventHandler() {
    if (_eventsInstalled) return;
    _eventsInstalled = true;
    _eventChannel.setMethodCallHandler((call) async {
      if (call.method != 'onTap') return null;
      final args = call.arguments;
      if (args is! Map) return null;
      final id = (args['id'] as num?)?.toInt();
      final action =
          VodControlAction.fromName(args['action'] as String?);
      final state = id == null ? null : _live[id];
      if (state != null && action != null && state.mounted) {
        state._onNativeTap(action);
      }
      return null;
    });
  }

  @override
  void didUpdateWidget(NativeVodControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    // No "view created" guard: the native side silently ignores a
    // command for an id whose view does not exist yet, and
    // creationParams already carry the latest values — so a push
    // here can only help, never duplicate or crash.
    if (_isTransport && widget.playing != _nativePlaying) {
      _nativePlaying = widget.playing;
      _push('setState', {'playing': widget.playing});
    }
    if (!_isTransport && widget.rateLabel != _nativeRateLabel) {
      _nativeRateLabel = widget.rateLabel;
      _push('setState', {'rateLabel': widget.rateLabel});
    }
  }

  @override
  void dispose() {
    _live.remove(_id);
    super.dispose();
  }

  void _onNativeTap(VodControlAction action) {
    // No echo: the parent rebuilds with the new state, and
    // didUpdateWidget then sees widget.playing == _nativePlaying
    // (or the same rate label).
    if (action == VodControlAction.playPause) {
      _nativePlaying = !_nativePlaying;
    }
    widget.onAction(action);
  }

  void _push(String method, Map<String, Object?> args) {
    if (!_useNative) return;
    unawaited(
      _commandChannel
          .invokeMethod(method, {'id': _id, ...args})
          // Best-effort (same convention as SystemVolume): a missing
          // native side never throws into the build/gesture path.
          .catchError((_) => null),
    );
  }

  /// The Flutter fallback — the current bottom-row buttons verbatim
  /// (same icons, sizes, tooltips, callbacks). Any change here
  /// must match the page's pre-native row exactly.
  Widget _fallback(BuildContext context) {
    final shadows = HaoTheme.legibilityShadows(context);
    if (_isTransport) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              widget.playing ? Icons.pause : Icons.play_arrow,
              shadows: shadows,
              color: Colors.white,
              size: 32,
            ),
            onPressed: () => widget.onAction(VodControlAction.playPause),
          ),
          IconButton(
            icon: Icon(
              Icons.skip_previous,
              shadows: shadows,
              color: Colors.white,
            ),
            tooltip: '上一集',
            onPressed: () => widget.onAction(VodControlAction.prev),
          ),
          IconButton(
            icon: Icon(
              Icons.skip_next,
              shadows: shadows,
              color: Colors.white,
            ),
            tooltip: '下一集',
            onPressed: () => widget.onAction(VodControlAction.next),
          ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(
          onPressed: () => widget.onAction(VodControlAction.rate),
          child: Text(
            widget.rateLabel,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        IconButton(
          icon: Icon(
            Icons.fullscreen_exit,
            shadows: shadows,
            color: Colors.white,
          ),
          tooltip: '退出全屏',
          onPressed: () => widget.onAction(VodControlAction.exit),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Fallback: NO fixed width — the buttons size exactly as the
    // page's original row did (the Flutter TextButton's minimum
    // width + padding makes the trailing cluster ~128 px, not
    // 112 — a fixed 112 box overflows by 16 px, see the first
    // regression run). The fixed size is only needed for the
    // native UiKitView, whose SwiftUI layout is 144 / 112 by
    // construction (no Flutter minimum-width artefact there).
    if (!_useNative) return _fallback(context);
    final params = <String, Object?>{
      'id': _id,
      'cluster': _isTransport ? 'transport' : 'trailing',
      'playing': widget.playing,
      'rateLabel': widget.rateLabel,
    };
    return SizedBox(
      width: _isTransport ? 144 : 112,
      height: 48,
      child: UiKitView(
        viewType: nativeVodControlsViewType,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
      ),
    );
  }
}
