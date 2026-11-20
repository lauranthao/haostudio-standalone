// Windows system volume backend — the DEVICE (master) volume via
// the Windows Core Audio API (MMDeviceEnumerator -> default render
// endpoint -> IAudioEndpointVolume).
//
// Why hand-rolled: package:win32 6.4.0 ships IMMDeviceEnumerator and
// IMMDevice but NOT IAudioEndpointVolume, so the interface is defined
// here following win32's own generated pattern (IUnknownVtbl base +
// one method slot per vtable entry, in COM order). Only two methods
// are ever called — GetMasterVolumeLevelScalar (slot 9) and
// SetMasterVolumeLevelScalar (slot 7) — but the vtable struct
// declares all 18 methods in order so the offsets line up.
//
// Change notifications: implementing IAudioEndpointVolumeCallback in
// Dart would mean exposing a COM vtable to native code, which win32
// does not support for user code — so external changes (hardware
// keys, the Windows volume mixer) are picked up by polling
// GetMasterVolumeLevelScalar every 500 ms while a listener is
// attached (see [setChangeListener]). Own-set echoes are suppressed
// in the poller (same rule as SystemVolume's 150 ms window, longer
// here because the poll only reads twice a second).
//
// Everything is lazy and best-effort: constructing this backend calls
// NO native code (safe to construct on any platform — the wrapper
// only constructs it on Windows), COM is initialised and the endpoint
// opened on first use, and every failure returns null / no-ops
// instead of throwing. If the default device changes, the cached
// endpoint is dropped and re-opened on the next call.

// ignore_for_file: non_constant_identifier_names

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'system_volume.dart';

/// `{5CDF2C82-841E-4546-9722-0CF74078229A}` — IAudioEndpointVolume.
final IID_IAudioEndpointVolume = GUID.fromComponents(
  0x5cdf2c82,
  0x841e,
  0x4546,
  Uint8List.fromList(
    const [0x97, 0x22, 0x0c, 0xf7, 0x40, 0x78, 0x22, 0x9a],
  ),
);

/// Hand-rolled IAudioEndpointVolume (win32 6.4.0 does not ship it).
/// Only Get/SetMasterVolumeLevelScalar are called; the rest of the
/// vtable is declared for layout only.
class IAudioEndpointVolume extends IUnknown implements ComInterface {
  IAudioEndpointVolume(super.ptr)
      : _vtable = ptr.value.cast<IAudioEndpointVolumeVtbl>().ref;

  final IAudioEndpointVolumeVtbl _vtable;

  late final _getMasterVolumeLevelScalarFn =
      _vtable.GetMasterVolumeLevelScalar.asFunction<
        int Function(VTablePointer, Pointer<Float>)
      >();

  late final _setMasterVolumeLevelScalarFn =
      _vtable.SetMasterVolumeLevelScalar.asFunction<
        int Function(VTablePointer, double, Pointer<GUID>)
      >();

  /// Current master volume, 0..1. Throws [WindowsException] on a
  /// failed COM call.
  double getMasterVolumeLevelScalar() {
    final pfLevel = calloc<Float>();
    try {
      final hr = HRESULT(
        _getMasterVolumeLevelScalarFn(ptr, pfLevel),
      );
      if (hr.isError) throw WindowsException(hr);
      return pfLevel.value.clamp(0.0, 1.0);
    } finally {
      calloc.free(pfLevel);
    }
  }

  /// Set the master volume, 0..1. Throws [WindowsException] on a
  /// failed COM call.
  void setMasterVolumeLevelScalar(double level) {
    final hr = HRESULT(
      _setMasterVolumeLevelScalarFn(ptr, level.clamp(0.0, 1.0), nullptr),
    );
    if (hr.isError) throw WindowsException(hr);
  }
}

/// @nodoc
base class IAudioEndpointVolumeVtbl extends Struct {
  external IUnknownVtbl base$;
  external Pointer<
    NativeFunction<Int32 Function(VTablePointer, VTablePointer)>
  >
  RegisterControlChangeNotify;
  external Pointer<
    NativeFunction<Int32 Function(VTablePointer, VTablePointer)>
  >
  UnregisterControlChangeNotify;
  external Pointer<
    NativeFunction<Int32 Function(VTablePointer, Pointer<Uint32>)>
  >
  GetChannelCount;
  external Pointer<
    NativeFunction<
      Int32 Function(VTablePointer, Float, Pointer<GUID>)
    >
  >
  SetMasterVolumeLevel;
  external Pointer<
    NativeFunction<
      Int32 Function(VTablePointer, Float, Pointer<GUID>)
    >
  >
  SetMasterVolumeLevelScalar;
  external Pointer<
    NativeFunction<Int32 Function(VTablePointer, Pointer<Float>)>
  >
  GetMasterVolumeLevel;
  external Pointer<
    NativeFunction<Int32 Function(VTablePointer, Pointer<Float>)>
  >
  GetMasterVolumeLevelScalar;
  external Pointer<
    NativeFunction<
      Int32 Function(
        VTablePointer,
        Uint32,
        Float,
        Pointer<GUID>,
      )
    >
  >
  SetChannelVolumeLevel;
  external Pointer<
    NativeFunction<
      Int32 Function(
        VTablePointer,
        Uint32,
        Float,
        Pointer<GUID>,
      )
    >
  >
  SetChannelVolumeLevelScalar;
  external Pointer<
    NativeFunction<
      Int32 Function(VTablePointer, Uint32, Pointer<Float>)
    >
  >
  GetChannelVolumeLevel;
  external Pointer<
    NativeFunction<
      Int32 Function(VTablePointer, Uint32, Pointer<Float>)
    >
  >
  GetChannelVolumeLevelScalar;
  external Pointer<
    NativeFunction<
      Int32 Function(VTablePointer, Int32, Pointer<GUID>)
    >
  >
  SetMute;
  external Pointer<
    NativeFunction<Int32 Function(VTablePointer, Pointer<Int32>)>
  >
  GetMute;
  external Pointer<
    NativeFunction<
      Int32 Function(VTablePointer, Pointer<Uint32>, Pointer<Uint32>)
    >
  >
  GetVolumeStepInfo;
  external Pointer<
    NativeFunction<Int32 Function(VTablePointer, Pointer<GUID>)>
  >
  VolumeStepUp;
  external Pointer<
    NativeFunction<Int32 Function(VTablePointer, Pointer<GUID>)>
  >
  VolumeStepDown;
  external Pointer<
    NativeFunction<Int32 Function(VTablePointer, Pointer<Uint32>)>
  >
  QueryHardwareSupport;
  external Pointer<
    NativeFunction<
      Int32 Function(
        VTablePointer,
        Pointer<Float>,
        Pointer<Float>,
        Pointer<Float>,
      )
    >
  >
  GetVolumeRange;
}

final class IAudioEndpointVolumeCompanion
    extends ComCompanion<IAudioEndpointVolume> {
  const IAudioEndpointVolumeCompanion();

  @override
  IAudioEndpointVolume Function(VTablePointer) get fromPointer =>
      IAudioEndpointVolume.new;

  @override
  GUID get iid => IID_IAudioEndpointVolume;
}

/// Windows implementation of [SystemVolumeBackend]: the master volume
/// through IAudioEndpointVolume, with polling for external changes.
class WindowsSystemVolumeBackend implements SystemVolumeBackend {
  WindowsSystemVolumeBackend() {
    // Register the hand-rolled interface once so
    // IMMDevice.activate<IAudioEndpointVolume>() can resolve it.
    // Registering twice is a harmless overwrite (only predefined
    // companions throw).
    ComInterface.register<IAudioEndpointVolume>(
      const IAudioEndpointVolumeCompanion(),
    );
  }

  /// Poll interval for external volume changes (hardware keys,
  /// Windows mixer). 500 ms: fast enough for the HUD to follow a key
  /// press, slow enough to be free.
  static const Duration _pollInterval = Duration(milliseconds: 500);

  /// Own-set echo suppression for the poller: a polled value within
  /// this of a value this backend set in the last [_echoWindow] is
  /// dropped (the caller already shows it). 1 s covers the poll
  /// interval; the epsilon matches SystemVolume's (below one
  /// hardware-key step, so a real key press is never swallowed — it
  /// lands on a value no recent set produced, or is picked up on the
  /// next poll once the window expires).
  static const Duration _echoWindow = Duration(seconds: 1);
  static const double _echoEpsilon = 0.04;

  IMMDeviceEnumerator? _enumerator;
  IMMDevice? _device;
  IAudioEndpointVolume? _endpoint;
  var _comInitialized = false;

  Timer? _pollTimer;
  void Function(double)? _onChanged;
  double? _lastPolled;

  final List<({double value, int atMs})> _recentOwnSets = [];

  void _recordOwnSet(double value) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _recentOwnSets
      ..removeWhere((e) => now - e.atMs > _echoWindow.inMilliseconds)
      ..add((value: value, atMs: now));
    if (_recentOwnSets.length > 32) {
      _recentOwnSets.removeRange(0, _recentOwnSets.length - 32);
    }
  }

  bool _isOwnEcho(double value) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _recentOwnSets.removeWhere(
      (e) => now - e.atMs > _echoWindow.inMilliseconds,
    );
    return _recentOwnSets.any(
      (e) => (e.value - value).abs() <= _echoEpsilon,
    );
  }

  /// Open (and cache) the default render endpoint's volume control.
  /// Null when COM or the device is unavailable — the caller retries
  /// on the next call (a device change drops the cache, see below).
  IAudioEndpointVolume? _ensureEndpoint() {
    if (_endpoint != null) return _endpoint;
    try {
      if (!_comInitialized) {
        // Best-effort: S_OK / S_FALSE are fine; RPC_E_CHANGED_MODE
        // (already initialised differently) still leaves COM usable
        // for these calls, so the result is ignored.
        CoInitializeEx(COINIT_APARTMENTTHREADED);
        _comInitialized = true;
      }
      _enumerator ??= createInstance<IMMDeviceEnumerator>(
        MMDeviceEnumerator,
      );
      _device ??= _enumerator!.getDefaultAudioEndpoint(
        eRender,
        eConsole,
      );
      _endpoint = _device!.activate<IAudioEndpointVolume>(
        CLSCTX_ALL,
        nullptr,
      );
      return _endpoint;
    } catch (_) {
      // A device change (or a missing device) invalidates the cache;
      // the next call re-opens from the enumerator.
      _dropEndpoint();
      return null;
    }
  }

  void _dropEndpoint() {
    try {
      _endpoint?.release();
    } catch (_) {}
    try {
      _device?.release();
    } catch (_) {}
    _endpoint = null;
    _device = null;
  }

  @override
  Future<double?> getVolume() async {
    try {
      return _ensureEndpoint()?.getMasterVolumeLevelScalar();
    } catch (_) {
      _dropEndpoint();
      return null;
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    final target = volume.clamp(0.0, 1.0);
    _recordOwnSet(target);
    try {
      _ensureEndpoint()?.setMasterVolumeLevelScalar(target);
    } catch (_) {
      _dropEndpoint();
    }
  }

  @override
  void setChangeListener(void Function(double)? onChanged) {
    _onChanged = onChanged;
    _pollTimer?.cancel();
    _pollTimer = null;
    if (onChanged == null) return;
    // Seed without emitting: the wrapper already holds the last
    // known level; only CHANGES are pushed.
    _lastPolled = null;
    _pollTimer = Timer.periodic(_pollInterval, (_) {
      final cb = _onChanged;
      if (cb == null) return;
      double? level;
      try {
        level = _ensureEndpoint()?.getMasterVolumeLevelScalar();
      } catch (_) {
        _dropEndpoint();
        return;
      }
      if (level == null) return;
      if (_lastPolled != null && (level - _lastPolled!).abs() <= 0.001) {
        return;
      }
      _lastPolled = level;
      if (_isOwnEcho(level)) return;
      cb(level);
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _onChanged = null;
    _dropEndpoint();
    try {
      _enumerator?.release();
    } catch (_) {}
    _enumerator = null;
  }
}
