// Danmaku occlusion mask widget (1.1.6, reduced version) — the
// whole-layer ShaderMask around the danmaku layer.
//
// Wraps a FlameBarrageWidget (or any danmaku layer) and erases the
// danmaku where Vision saw a person. Whole-layer, NOT per-item:
// flame_barrage 0.0.9 has no per-item mask entry (audit HB-2), so
// the mask is applied to the entire layer at once with
// BlendMode.dstOut (opaque shader = erase the danmaku under it).
//
//  - No mask (off / non-MPV / no person / expired / failed) -> the
//    child is returned untouched: plain danmaku, zero overhead, no
//    ShaderMask in the tree at all.
//  - TileMode.decal: outside the video rect the shader is
//    transparent, so a person touching the frame edge never erases
//    danmaku in the letterbox black bars.
//  - The mask is mapped onto the actual video display rect
//    (videoDisplayRect), not the whole layer bounds — a non-16:9
//    source keeps its mask aligned with the picture.

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'danmaku_occlusion.dart';

/// Wraps [child] (the danmaku layer) in a person-shaped cutout
/// driven by [controller]. [fit] is the video fit the page uses
/// (VOD: the user's VideoFitMode; live: BoxFit.contain).
class DanmakuOcclusionMask extends StatelessWidget {
  const DanmakuOcclusionMask({
    super.key,
    required this.controller,
    required this.fit,
    required this.child,
  });

  final DanmakuOcclusionController controller;
  final BoxFit fit;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, child) {
        final mask = controller.maskImage;
        final frameSize = controller.frameSize;
        if (mask == null || frameSize == null) return child!;
        return LayoutBuilder(
          builder: (context, constraints) {
            final bounds = Size(
              constraints.maxWidth,
              constraints.maxHeight,
            );
            final videoRect = videoDisplayRect(
              container: bounds,
              video: frameSize,
              fit: fit,
            );
            final maskSize = Size(
              mask.width.toDouble(),
              mask.height.toDouble(),
            );
            return ShaderMask(
              blendMode: BlendMode.dstOut,
              shaderCallback: (Rect shaderBounds) => ui.ImageShader(
                mask,
                ui.TileMode.decal,
                ui.TileMode.decal,
                maskShaderMatrix(
                  videoRect: videoRect,
                  maskSize: maskSize,
                ).storage,
              ),
              child: child,
            );
          },
        );
      },
      child: child,
    );
  }
}
