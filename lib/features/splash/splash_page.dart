// Splash page — animation #4 (chen 2026-11-16, chosen from 4 previews).
// Faithful port of the Swift implementation in
// ~/workspace/deploy/standalone-app/ios/HAoStudio/ViewController.swift
// (runSplashAnimation + layoutSplashOverlays), which is the reference
// chen approved. The Flutter version that shipped in v1.0.5–v1.0.7 was
// a compressed copy that dropped the shadow and the red-dot breathing —
// that is why the animation looked wrong on chen's phone.
//
// Timeline (total 1800 ms):
//   0.0–1.0s  logo fades in from white and floats up 22pt (ease-out,
//             scale 0.97 -> 1.0). Logo 180x180, final centre 30pt above
//             screen centre.
//   0.15–1.0s soft shadow grows beneath it (alpha 0 -> 1, scale 0.7 -> 1.0).
//             Shadow is a black radial glow, 220x64, maxAlpha 0.32,
//             top edge 4pt below the logo's bottom edge.
//   0.7–1.0s  red live dot fades/scales in (alpha 0 -> 1, scale 0.6 -> 1.0).
//             The dot is a separate overlay centred on the logo's own
//             red dot (centre ~0.678W / 0.409H of the square logo,
//             diameter ~0.069W); the baked-in logo dot stays put, so the
//             overlay reads as the dot itself.
//   0.9–1.5s  dot breathes once, slow and subtle (scale 1 -> 1.12) and
//             a soft red glow halo grows behind it (alpha 0 -> 0.55).
//   1.5–1.8s  whole page fades out, then AppShell.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../widgets/app_shell.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage>
    with SingleTickerProviderStateMixin {
  static const _total = Duration(milliseconds: 1800);

  // Logo is 180x180; the dot/glow geometry is fractions of that size,
  // copied from the Swift layoutSplashOverlays.
  static const _logoSize = 180.0;
  static const _dotDiameter = _logoSize * 0.069;
  static const _dotCenterX = _logoSize * 0.678;
  static const _dotCenterY = _logoSize * 0.409;
  static const _glowSize = _logoSize * 0.22;
  static const _dotRed = Color(0xFFF53333);

  late final AnimationController _controller;
  late final Animation<double> _logoOpacity;
  late final Animation<double> _rise;
  late final Animation<double> _logoScale;
  late final Animation<double> _shadowOpacity;
  late final Animation<double> _shadowScale;
  late final Animation<double> _dotOpacity;
  late final Animation<double> _dotScaleIn;
  late final Animation<double> _dotBreathe;
  late final Animation<double> _glowOpacity;
  late final Animation<double> _fadeOut;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _total);

    // 0.0–1.0s: logo fades in + floats up 22pt + scales 0.97 -> 1.0.
    _logoOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.556, curve: Curves.easeOut),
      ),
    );
    _rise = Tween<double>(begin: 22, end: 0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.556, curve: Curves.easeOut),
      ),
    );
    _logoScale = Tween<double>(begin: 0.97, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.556, curve: Curves.easeOut),
      ),
    );
    // 0.15–1.0s: shadow grows (alpha + scale).
    _shadowOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.083, 0.556, curve: Curves.easeOut),
      ),
    );
    _shadowScale = Tween<double>(begin: 0.7, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.083, 0.556, curve: Curves.easeOut),
      ),
    );
    // 0.7–1.0s: red dot fades/scales in.
    _dotOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.389, 0.556, curve: Curves.easeOut),
      ),
    );
    _dotScaleIn = Tween<double>(begin: 0.6, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.389, 0.556, curve: Curves.easeOut),
      ),
    );
    // 0.9–1.5s: dot breathes once (scale 1 -> 1.12) + glow halo grows.
    _dotBreathe = Tween<double>(begin: 1, end: 1.12).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.5, 0.833, curve: Curves.easeInOut),
      ),
    );
    _glowOpacity = Tween<double>(begin: 0, end: 0.55).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.5, 0.833, curve: Curves.easeInOut),
      ),
    );
    // 1.5–1.8s: whole page fades out.
    _fadeOut = Tween<double>(begin: 1, end: 0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.833, 1.0, curve: Curves.easeIn),
      ),
    );

    _controller.forward().then((_) {
      if (!mounted) return;
      Get.offAll(() => const AppShell());
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Opacity(
          opacity: _fadeOut.value,
          child: Scaffold(
            backgroundColor: Colors.white,
            body: Stack(
              children: [
                // Soft ground shadow, fixed in place beneath the logo
                // (it grows while the logo floats up into place).
                // Logo bottom = centre - 30 + 90 = centre + 60, so the
                // shadow (64 tall, top 4 below the logo bottom) is
                // centred at centre + 88.
                Center(
                  child: Transform.translate(
                    offset: const Offset(0, 88),
                    child: Transform.scale(
                      scale: _shadowScale.value,
                      child: Opacity(
                        opacity: _shadowOpacity.value,
                        child: Container(
                          width: 220,
                          height: 64,
                          decoration: BoxDecoration(
                            gradient: RadialGradient(
                              center: Alignment.center,
                              radius: 0.5,
                              colors: [
                                Colors.black.withValues(alpha: 0.32),
                                Colors.black.withValues(alpha: 0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Logo (180x180, final centre 30pt above screen centre),
                // rising 22pt into place. The dot + glow live inside
                // the logo box so they move with it.
                Center(
                  child: Transform.translate(
                    offset: Offset(0, -30 + _rise.value),
                    child: Transform.scale(
                      scale: _logoScale.value,
                      child: Opacity(
                        opacity: _logoOpacity.value,
                        child: SizedBox(
                          width: _logoSize,
                          height: _logoSize,
                          child: Stack(
                            children: [
                              Image.asset(
                                'assets/logo.png',
                                width: _logoSize,
                                height: _logoSize,
                                fit: BoxFit.contain,
                              ),
                              // Red glow halo behind the dot.
                              Positioned(
                                left: _dotCenterX - _glowSize / 2,
                                top: _dotCenterY - _glowSize / 2,
                                child: Opacity(
                                  opacity: _glowOpacity.value,
                                  child: Container(
                                    width: _glowSize,
                                    height: _glowSize,
                                    decoration: BoxDecoration(
                                      gradient: RadialGradient(
                                        center: Alignment.center,
                                        radius: 0.5,
                                        colors: [
                                          _dotRed.withValues(alpha: 0.85),
                                          _dotRed.withValues(alpha: 0),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              // Red live dot overlay, centred on the
                              // logo's own red dot.
                              Positioned(
                                left: _dotCenterX - _dotDiameter / 2,
                                top: _dotCenterY - _dotDiameter / 2,
                                child: Transform.scale(
                                  scale:
                                      _dotScaleIn.value * _dotBreathe.value,
                                  child: Opacity(
                                    opacity: _dotOpacity.value,
                                    child: Container(
                                      width: _dotDiameter,
                                      height: _dotDiameter,
                                      decoration: const BoxDecoration(
                                        color: _dotRed,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
