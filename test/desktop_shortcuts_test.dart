// Windows desktop player shortcuts (phase 2, step 2): the helper in
// lib/features/player/desktop_shortcuts.dart is platform-independent —
// the Platform.isWindows gates live in the callers — so its key/wheel
// mapping is unit-testable on any platform.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/features/player/desktop_shortcuts.dart';

KeyDownEvent key(LogicalKeyboardKey logical, {PhysicalKeyboardKey? physical}) {
  return KeyDownEvent(
    logicalKey: logical,
    physicalKey: physical ?? PhysicalKeyboardKey.keyA,
    timeStamp: Duration.zero,
  );
}

void main() {
  // handleDesktopPlayerKey reads FocusManager.instance (the text-field
  // guard), which needs the binding — a plain test() does not
  // initialise it on its own.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('handleDesktopPlayerKey', () {
    test('Space toggles play/pause and is handled', () {
      var called = false;
      final result = handleDesktopPlayerKey(
        key(LogicalKeyboardKey.space),
        onTogglePlayPause: () => called = true,
      );
      expect(result, KeyEventResult.handled);
      expect(called, isTrue);
    });

    test('key-up events are ignored', () {
      var called = false;
      final result = handleDesktopPlayerKey(
        KeyUpEvent(
          logicalKey: LogicalKeyboardKey.space,
          physicalKey: PhysicalKeyboardKey.space,
          timeStamp: Duration.zero,
        ),
        onTogglePlayPause: () => called = true,
      );
      expect(result, KeyEventResult.ignored);
      expect(called, isFalse);
    });

    test('Left seeks on VOD, goes previous on music', () {
      var seeked = false;
      var prev = false;
      expect(
        handleDesktopPlayerKey(
          key(LogicalKeyboardKey.arrowLeft),
          onTogglePlayPause: () {},
          onSeekBackward: () => seeked = true,
          onPrevious: () => prev = true,
        ),
        KeyEventResult.handled,
      );
      expect(seeked, isTrue);
      expect(prev, isFalse);

      expect(
        handleDesktopPlayerKey(
          key(LogicalKeyboardKey.arrowLeft),
          onTogglePlayPause: () {},
          onPrevious: () => prev = true,
        ),
        KeyEventResult.handled,
      );
      expect(prev, isTrue);
    });

    test('Up/Down step the volume by 1/16 of the range', () {
      final steps = <int>[];
      handleDesktopPlayerKey(
        key(LogicalKeyboardKey.arrowUp),
        onTogglePlayPause: () {},
        onVolumeStep: steps.add,
      );
      handleDesktopPlayerKey(
        key(LogicalKeyboardKey.arrowDown),
        onTogglePlayPause: () {},
        onVolumeStep: steps.add,
      );
      expect(steps, [1, -1]);
    });

    test('F toggles fullscreen; Esc exits it only when provided', () {
      var toggled = false;
      var exited = false;
      expect(
        handleDesktopPlayerKey(
          key(LogicalKeyboardKey.keyF),
          onTogglePlayPause: () {},
          onToggleFullscreen: () => toggled = true,
        ),
        KeyEventResult.handled,
      );
      expect(toggled, isTrue);

      expect(
        handleDesktopPlayerKey(
          key(LogicalKeyboardKey.escape),
          onTogglePlayPause: () {},
          onExitFullscreen: () => exited = true,
        ),
        KeyEventResult.handled,
      );
      expect(exited, isTrue);

      expect(
        handleDesktopPlayerKey(
          key(LogicalKeyboardKey.escape),
          onTogglePlayPause: () {},
        ),
        KeyEventResult.ignored,
      );
    });

    test('unmapped keys are ignored', () {
      expect(
        handleDesktopPlayerKey(
          key(LogicalKeyboardKey.keyA),
          onTogglePlayPause: () {},
        ),
        KeyEventResult.ignored,
      );
    });
  });

  group('handleDesktopWheel', () {
    test('scroll up is louder, scroll down is quieter', () {
      final deltas = <double>[];
      handleDesktopWheel(
        const PointerScrollEvent(scrollDelta: Offset(0, -120)),
        deltas.add,
      );
      handleDesktopWheel(
        const PointerScrollEvent(scrollDelta: Offset(0, 120)),
        deltas.add,
      );
      expect(deltas, [0.05, -0.05]);
    });

    test('horizontal scroll is ignored', () {
      final deltas = <double>[];
      handleDesktopWheel(
        const PointerScrollEvent(scrollDelta: Offset(120, 0)),
        deltas.add,
      );
      expect(deltas, isEmpty);
    });
  });
}
