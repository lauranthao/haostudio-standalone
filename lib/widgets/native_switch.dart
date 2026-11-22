// The app's only switch component (build 29, E group + G item).
//
// iOS: the real `UISwitch` from ios/Runner/NativeSwitchPlugin.swift,
// hosted in a `UiKitView`. chen (2026-11-22, second confirmation)
// wants the iOS native control — the 1.1.6 all-Flutter-Cupertino
// decision was rejected, so no Flutter switch stands in for it on
// iOS. Other platforms (Android / Windows / tests): there is no
// UISwitch there, so the fallback is a `CupertinoSwitch` — its
// thumb is always white and its active track is the accent, so the
// black-block class of bug cannot recur there either.
//
// Root cause it replaces (chen's 音源管理 screenshot): the old rows
// used Material `SwitchListTile` with `activeThumbColor:
// theme.accent`. The default appleGlass light accent is pure black
// (0xFF000000) and the theme's selected track is the same accent, so
// thumb == track == black and the knob vanished — a solid black
// oval with no visible state. The LX script rows on the same page
// used the library `GlassSwitch`, which draws its own white knob
// and only tints the track with the accent, so they stayed readable.
// The native switch pins the thumb white (`thumbTintColor = .white`
// on the Swift side) whatever the accent is, and its OFF track is
// iOS's own system grey — visible in light/dark, at glass 0%/100%,
// because the switch paints no glass of its own.
//
// Single source of truth: the Flutter-side `value` prop (the
// Hive-backed store the caller already reads). The native view only
// mirrors it — Dart pushes `setValue` / `setOnTintColor` /
// `setEnabled` when props change, the native side only reports user
// flips as `onChanged`, and Dart echoes nothing back for its own
// flips (the parent rebuild carries the same value, so
// `didUpdateWidget` sees no diff). No second state is created
// anywhere.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/hao_themes.dart';
import '../core/theme/haptics.dart';

/// Platform-view type registered by NativeSwitchPlugin.
const String nativeSwitchViewType =
    'com.haostudio.standalone/native_switch';

/// Command channel (Dart -> native): setValue / setOnTintColor /
/// setEnabled. Must match ios/Runner/NativeSwitchPlugin.swift.
const String nativeSwitchCommandChannel =
    'com.haostudio.standalone/native_switch';

/// Event channel (native -> Dart): onChanged {id, value}. Must match
/// ios/Runner/NativeSwitchPlugin.swift.
const String nativeSwitchEventChannel =
    'com.haostudio.standalone/native_switch/events';

/// iOS-native switch, 51x31 (the iOS size the old GlassSwitch used).
/// [onChanged] null (or [enabled] false) disables the switch.
class HaoNativeSwitch extends StatefulWidget {
  const HaoNativeSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor,
    this.enabled = true,
    this.semanticsLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  /// ON track colour. Null = the theme accent. The thumb stays
  /// white regardless — never the accent, never the track colour.
  final Color? activeColor;
  final bool enabled;

  /// Accessibility label for the native switch (usually the row
  /// title). Only used on iOS; the fallback control announces its
  /// own toggled state.
  final String? semanticsLabel;

  @override
  State<HaoNativeSwitch> createState() => _HaoNativeSwitchState();
}

class _HaoNativeSwitchState extends State<HaoNativeSwitch> {
  static const MethodChannel _commandChannel =
      MethodChannel(nativeSwitchCommandChannel);
  static const MethodChannel _eventChannel =
      MethodChannel(nativeSwitchEventChannel);

  static int _nextId = 1;
  static final Map<int, _HaoNativeSwitchState> _live = {};
  static bool _eventsInstalled = false;

  late final int _id;

  /// Last value the native view holds (or the fallback rendered).
  /// Initialised from the prop; updated on native flips and on
  /// prop changes, so a push only happens on a real diff.
  late bool _nativeValue;

  /// Last tint / enabled state pushed (or carried in creationParams
  /// on the first build). Null until the first didChangeDependencies.
  Color? _nativeTint;
  bool? _nativeEnabled;

  bool get _isIOS => defaultTargetPlatform == TargetPlatform.iOS;
  bool get _effectiveEnabled => widget.enabled && widget.onChanged != null;

  Color get _effectiveTint =>
      widget.activeColor ?? HaoTheme.ofOrDefault(context).accent;

  @override
  void initState() {
    super.initState();
    _id = _nextId++;
    _nativeValue = widget.value;
    _live[_id] = this;
    _installEventHandler();
  }

  static void _installEventHandler() {
    if (_eventsInstalled) return;
    _eventsInstalled = true;
    _eventChannel.setMethodCallHandler((call) async {
      if (call.method != 'onChanged') return null;
      final args = call.arguments;
      if (args is! Map) return null;
      final id = (args['id'] as num?)?.toInt();
      final value = args['value'] as bool?;
      final state = id == null ? null : _live[id];
      if (state != null && value != null && state.mounted) {
        state._onNativeChanged(value);
      }
      return null;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Theme-driven tint changes (e.g. a new custom accent) arrive
    // here, not in didUpdateWidget. The first call runs before the
    // first build, when creationParams already carry these values —
    // record without pushing.
    final tint = _effectiveTint;
    final enabled = _effectiveEnabled;
    if (_nativeTint == null || _nativeEnabled == null) {
      _nativeTint = tint;
      _nativeEnabled = enabled;
      return;
    }
    if (_nativeTint != tint) {
      _nativeTint = tint;
      _push('setOnTintColor', {'color': tint.toARGB32()});
    }
    if (_nativeEnabled != enabled) {
      _nativeEnabled = enabled;
      _push('setEnabled', {'enabled': enabled});
    }
  }

  @override
  void didUpdateWidget(HaoNativeSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    // No "view created" guard: the native side silently ignores a
    // command for an id whose view does not exist yet, and
    // creationParams already carry the latest values — so a push
    // here can only help, never duplicate or crash.
    if (widget.value != _nativeValue) {
      _nativeValue = widget.value;
      _push('setValue', {'value': widget.value, 'animated': true});
    }
    // Explicit activeColor prop changes arrive here (theme-derived
    // ones go through didChangeDependencies above).
    if (widget.activeColor != oldWidget.activeColor &&
        widget.activeColor != null) {
      _nativeTint = widget.activeColor;
      _push('setOnTintColor', {'color': widget.activeColor!.toARGB32()});
    }
    final enabled = _effectiveEnabled;
    if (_nativeEnabled != enabled) {
      _nativeEnabled = enabled;
      _push('setEnabled', {'enabled': enabled});
    }
  }

  @override
  void dispose() {
    _live.remove(_id);
    super.dispose();
  }

  void _onNativeChanged(bool value) {
    // No echo: the parent rebuilds with this value, and
    // didUpdateWidget then sees widget.value == _nativeValue.
    _nativeValue = value;
    widget.onChanged?.call(value);
  }

  void _push(String method, Map<String, Object?> args) {
    if (!_isIOS) return;
    unawaited(
      _commandChannel
          .invokeMethod(method, {'id': _id, ...args})
          // Best-effort (same convention as SystemVolume): a missing
          // native side never throws into the build/gesture path.
          .catchError((_) => null),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tint = _effectiveTint;
    final enabled = _effectiveEnabled;
    final label = widget.semanticsLabel;
    final Widget child;
    if (_isIOS) {
      final params = <String, Object?>{
        'id': _id,
        'value': widget.value,
        'onTintColor': tint.toARGB32(),
        'enabled': enabled,
      };
      if (label != null) params['semanticsLabel'] = label;
      child = UiKitView(
        viewType: nativeSwitchViewType,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
      );
    } else {
      child = CupertinoSwitch(
        value: widget.value,
        activeTrackColor: tint,
        onChanged: enabled
            ? (v) {
                // UISwitch clicks natively on iOS; the fallback
                // has no built-in feedback, so match it here.
                HaoHaptics.select();
                _nativeValue = v;
                widget.onChanged?.call(v);
              }
            : null,
      );
    }
    // UISwitch's intrinsic size is 51x31; the box keeps the row
    // layout identical on every platform.
    return SizedBox(width: 51, height: 31, child: child);
  }
}

/// A settings row with a trailing [HaoNativeSwitch] — the
/// replacement for `SwitchListTile` (same row-tap toggles, same
/// title/subtitle styling). The switch itself never paints glass,
/// so the row reads the same at glass 0% and 100%.
class HaoSwitchRow extends StatelessWidget {
  const HaoSwitchRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.activeColor,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.ofOrDefault(context);
    return ListTile(
      title: Text(title, style: TextStyle(color: theme.textPrimary)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: TextStyle(color: theme.textSecondary)),
      trailing: HaoNativeSwitch(
        value: value,
        onChanged: onChanged,
        activeColor: activeColor ?? theme.accent,
        semanticsLabel: title,
      ),
      onTap: () => onChanged(!value),
    );
  }
}
