// SystemDragController.setVolumeLevel — the keyboard / mouse-wheel
// volume steps on Windows (live room + VOD player) go through it.
// Pure unit test: no widget pump, no Hive, no platform channel —
// the controller takes an injected SystemVolume with a recording
// backend, and the HUD linger is shortened so the test stays fast.

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/native/system_volume.dart';
import 'package:standalone/features/player/system_drag_controller.dart';

class _RecordingBackend implements SystemVolumeBackend {
  final List<double> sets = [];
  var level = 0.5;

  @override
  Future<double?> getVolume() async => level;

  @override
  Future<void> setVolume(double volume) async {
    sets.add(volume);
    level = volume;
  }

  @override
  void setChangeListener(void Function(double)? onChanged) {}

  @override
  void dispose() {}
}

void main() {
  test('setVolumeLevel applies the level and shows the volume HUD', () async {
    final backend = _RecordingBackend();
    final volume = SystemVolume(backend: backend);
    final drag = SystemDragController(
      systemVolume: volume,
      hudLinger: const Duration(milliseconds: 50),
    );
    addTearDown(drag.dispose);
    addTearDown(volume.dispose);

    await drag.setVolumeLevel(0.5);

    expect(drag.volumeLevel, 0.5);
    expect(drag.value.value, 0.5);
    expect(drag.side.value, SystemDragSide.volume);
    expect(backend.sets, [0.5]);

    // HUD hides after the linger.
    await Future.delayed(const Duration(milliseconds: 100));
    expect(drag.side.value, isNull);
  });

  test('setVolumeLevel clamps out-of-range values', () async {
    final backend = _RecordingBackend();
    final volume = SystemVolume(backend: backend);
    final drag = SystemDragController(systemVolume: volume);
    addTearDown(drag.dispose);
    addTearDown(volume.dispose);

    await drag.setVolumeLevel(1.5);
    expect(drag.volumeLevel, 1.0);
    expect(backend.sets, [1.0]);

    await drag.setVolumeLevel(-0.2);
    expect(drag.volumeLevel, 0.0);
    expect(backend.sets, [1.0, 0.0]);
  });
}
