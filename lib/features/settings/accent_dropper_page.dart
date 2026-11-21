// Accent-colour dropper: a full-screen view of the captured app
// frame. The user taps anywhere to pick that pixel's colour; the
// colour is returned to the colour sheet (which applies it
// immediately). × / back pops without picking.
//
// The capture is passed in as an image (see ScreenCapture) — the
// page never captures itself, so the sheet and this page cannot
// appear in the frame being sampled.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../../widgets/hao_pressable.dart';

import '../../core/theme/screen_capture.dart';

class AccentDropperPage extends StatelessWidget {
  const AccentDropperPage({
    super.key,
    required this.image,
  });

  /// The captured app frame (captured at pixelRatio 1.0).
  final ui.Image image;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // The capture is exactly the screen's logical size, so a
          // tap maps onto image pixels 1:1 — unless the display size
          // differs (tests), in which case the tap is scaled by the
          // image/display ratio first.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) async {
                final scaleX = image.width / size.width;
                final scaleY = image.height / size.height;
                final picked = await ScreenCapture.sample(
                  image,
                  Offset(
                    details.localPosition.dx * scaleX,
                    details.localPosition.dy * scaleY,
                  ),
                );
                if (!context.mounted) return;
                if (picked != null) {
                  Navigator.of(context).pop<Color>(picked);
                }
              },
              child: RawImage(
                image: image,
                width: size.width,
                height: size.height,
                fit: BoxFit.fill,
              ),
            ),
          ),
          // Cancel: × pops without picking.
          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            left: 16,
            child: _RoundButton(
              icon: Icons.close,
              onTap: () => Navigator.of(context).pop<Color>(),
            ),
          ),
        ],
      ),
    );
  }
}

/// Translucent dark circle button (the sheet's × / dropper style):
/// readable over any captured content.
class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: HaoPressable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: 0.45),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.35),
              width: 1,
            ),
          ),
          child: Icon(icon, size: 20, color: Colors.white),
        ),
      ),
    );
  }
}
