// Person segmentation bridge — Dart side of
// ios/Runner/PersonSegmentationPlugin.swift.
//
// Sends one low-frequency MPV snapshot (JPEG) to Vision and gets a
// single-channel person mask back. iOS 15+, on-device, no permission,
// no model download, no network.
//
// Best-effort throughout: a missing native side (unit tests,
// Android until its native side lands, any native failure) never
// throws — [segmentFrame] returns null and the caller treats it as
// "skip this frame, keep the old mask".

import 'package:flutter/services.dart';

import '../logging/app_log.dart';

/// MethodChannel name shared with
/// ios/Runner/PersonSegmentationPlugin.swift.
const String personSegmentationChannelName =
    'com.haostudio.standalone/person_segmentation';

/// One Vision person mask (single mask for all people — the iOS 17+
/// per-person API is not used, deployment target stays 15.0).
class PersonMask {
  const PersonMask({
    required this.bytes,
    required this.width,
    required this.height,
    required this.frameWidth,
    required this.frameHeight,
    required this.hasPerson,
    required this.thermalState,
  });

  /// Single-channel 8-bit mask, [width] x [height] bytes, row-major.
  /// 255 = person, 0 = background (soft edges in between).
  final Uint8List bytes;

  /// Mask size. `.fast` quality returns 256x144.
  final int width;
  final int height;

  /// Source frame size (the JPEG that was segmented), for aligning
  /// the mask with the displayed video rect (contain black bars).
  final int frameWidth;
  final int frameHeight;

  /// Whether the frame contains a real person (native side counts
  /// pixels > 127, threshold ~0.1% of the mask).
  final bool hasPerson;

  /// ProcessInfo.ThermalState raw value at segmentation time:
  /// 0 nominal, 1 fair, 2 serious, 3 critical.
  final int thermalState;
}

class PersonSegmentation {
  PersonSegmentation({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel(personSegmentationChannelName);

  final MethodChannel _channel;

  /// Segment [jpegBytes] (one MPV snapshot). Returns null on any
  /// failure — missing plugin, bad args, Vision error, malformed
  /// reply — never throws.
  Future<PersonMask?> segmentFrame(Uint8List jpegBytes) async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'segmentFrame',
        <String, Object>{'jpeg': jpegBytes},
      );
      if (result == null) return null;
      final mask = result['mask'];
      final width = result['width'];
      final height = result['height'];
      final frameWidth = result['frameWidth'];
      final frameHeight = result['frameHeight'];
      final hasPerson = result['hasPerson'];
      final thermalState = result['thermalState'];
      if (mask is! Uint8List ||
          width is! int ||
          height is! int ||
          frameWidth is! int ||
          frameHeight is! int ||
          hasPerson is! bool ||
          thermalState is! int) {
        return null;
      }
      if (width <= 0 ||
          height <= 0 ||
          frameWidth <= 0 ||
          frameHeight <= 0 ||
          mask.length != width * height) {
        return null;
      }
      return PersonMask(
        bytes: mask,
        width: width,
        height: height,
        frameWidth: frameWidth,
        frameHeight: frameHeight,
        hasPerson: hasPerson,
        thermalState: thermalState,
      );
    } catch (e) {
      AppLog.warn('人物分割失败：$e');
      return null;
    }
  }
}
