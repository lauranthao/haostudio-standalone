// Splash page — chen's spec (2026-11-16): animation #4, gentle fade-in +
// float-up, Apple-like, max ~1.5 s. Native LaunchScreen.storyboard shows
// the same logo statically (white bg) while the engine boots; this page
// continues the motion in Flutter and hands over to AppShell.
//
// Timeline (total 1500 ms):
//   0–900 ms   logo fades in (0 -> 1) and floats up (+28 -> 0), easeOutCubic
//   900–1150 ms hold
//   1150–1500 ms whole page fades out (1 -> 0), then AppShell.

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
  static const _total = Duration(milliseconds: 1500);

  late final AnimationController _controller;
  late final Animation<double> _fadeIn;
  late final Animation<double> _rise;
  late final Animation<double> _fadeOut;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _total);

    // Fade in + float up over the first 900 ms (0.0–0.6 of the timeline).
    _fadeIn = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOutCubic),
      ),
    );
    _rise = Tween<double>(begin: 28, end: 0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOutCubic),
      ),
    );
    // Fade the whole page out over the last 350 ms (0.77–1.0).
    _fadeOut = Tween<double>(begin: 1, end: 0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.77, 1.0, curve: Curves.easeInCubic),
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
          opacity: _fadeIn.value * _fadeOut.value,
          child: Scaffold(
            backgroundColor: Colors.white,
            body: Center(
              child: Transform.translate(
                offset: Offset(0, _rise.value),
                child: Image.asset(
                  'assets/logo.png',
                  width: 168,
                  height: 168,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
