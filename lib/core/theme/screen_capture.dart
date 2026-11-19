// Screen capture for the accent-colour dropper.
//
// The app's root content sits inside a RepaintBoundary keyed here
// (see main.dart). The dropper captures that boundary's last painted
// frame — the app UI behind the colour sheet — and the user taps a
// point in the captured image to pick that pixel's colour. The sheet
// and the dropper view itself are separate routes above the
// boundary, so they never appear in the capture.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

class ScreenCapture {
  /// Key for the RepaintBoundary around the app's root content
  /// (main.dart). The boundary must be mounted and painted before
  /// a capture.
  static final GlobalKey boundaryKey = GlobalKey();

  /// Capture the app's current frame at [pixelRatio] (1.0 is enough
  /// for colour picking and keeps the byte buffer small). Returns
  /// null when the boundary is not mounted, has not painted yet, or
  /// the rasterisation fails — the caller must treat null as "pick
  /// failed" and say so, never as a silent dead button.
  static Future<ui.Image?> capture({double pixelRatio = 1.0}) async {
    final context = boundaryKey.currentContext;
    if (context == null) return null;
    final boundary =
        context.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null || boundary.debugNeedsPaint) return null;
    try {
      return await boundary.toImage(pixelRatio: pixelRatio);
    } catch (_) {
      return null;
    }
  }

  /// The colour of the pixel at [imageOffset] (image-pixel
  /// coordinates — the caller scales a tap offset by the
  /// image/display ratio first) in [image]. Returns null when the
  /// bytes cannot be read.
  static Future<Color?> sample(
    ui.Image image,
    Offset imageOffset,
  ) async {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bytes == null) return null;
    final data = bytes.buffer.asUint8List();
    final x = imageOffset.dx.round().clamp(0, image.width - 1);
    final y = imageOffset.dy.round().clamp(0, image.height - 1);
    final i = (y * image.width + x) * 4;
    if (i + 3 >= data.length) return null;
    return Color.fromARGB(data[i + 3], data[i], data[i + 1], data[i + 2]);
  }
}
