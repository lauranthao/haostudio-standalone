// Android ABI detection for per-ABI APK updates (P1-A1).
//
// `flutter build apk --split-per-abi` ships one APK per ABI; the in-app
// updater must download the APK matching the device's primary ABI.
// Build.SUPPORTED_ABIS[0] is read through the native channel
// (DeviceInfoPlugin.kt); the result is cached after the first call.
// Anything unknown (channel absent, empty list, non-Android) yields
// null, and callers fall back to the fat APK URL — never a wrong-ABI
// download, never a crash.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// MethodChannel name shared with DeviceInfoPlugin.kt.
const String androidDeviceInfoChannelName =
    'com.haostudio.standalone/device_info';

class AndroidAbi {
  AndroidAbi._();

  static const MethodChannel _channel =
      MethodChannel(androidDeviceInfoChannelName);

  static Future<String?>? _pending;
  static String? _cached;

  /// Primary ABI ('arm64-v8a', 'armeabi-v7a', 'x86_64'), or null when
  /// unknown (not yet detected, or no native side). Null-safe by
  /// design: callers fall back to the fat APK.
  static String? get current => _cached;

  /// Detect once and cache. Safe to call unawaited at startup and safe
  /// to call again (returns the cached value). Never throws.
  static Future<String?> detect({MethodChannel? channel}) {
    return _pending ??= _detectOnce(channel ?? _channel);
  }

  static Future<String?> _detectOnce(MethodChannel channel) async {
    try {
      final abis = await channel.invokeListMethod<String>('getSupportedAbis');
      if (abis != null && abis.isNotEmpty) {
        _cached = abis.first;
      }
    } catch (_) {
      // No native side (tests, non-Android): stay null, caller falls back.
    }
    return _cached;
  }

  @visibleForTesting
  static void setTestAbi(String? abi) {
    _pending = Future.value(abi);
    _cached = abi;
  }

  @visibleForTesting
  static void resetForTest() {
    _pending = null;
    _cached = null;
  }
}
