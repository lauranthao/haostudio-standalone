// A-B loop (build 29, music) — repeat one passage of the current
// track. Pure state machine; the controller owns the position
// listener that asks [seekTarget] and the per-track reset (a loop
// never survives a track change).

class AbLoop {
  Duration? _a;
  Duration? _b;

  Duration? get a => _a;
  Duration? get b => _b;

  bool get hasA => _a != null;
  bool get hasB => _b != null;

  /// True once both points are set and B is after A.
  bool get isActive => _a != null && _b != null && _b! > _a!;

  /// Human label for the player sheet ("A-B 循环 01:23–01:45",
  /// "A 点 01:23", or '' when nothing is set).
  String get label {
    if (_a == null) return '';
    final a = _fmt(_a!);
    if (_b == null) return 'A 点 $a';
    return 'A-B 循环 $a–${_fmt(_b!)}';
  }

  static String _fmt(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  /// Set point A at [position]. A B at or before the new A is
  /// dropped — a loop can never run backwards.
  void setA(Duration position) {
    _a = position;
    if (_b != null && _b! <= position) _b = null;
  }

  /// Set point B at [position]. Ignored without an A, or at/before A.
  void setB(Duration position) {
    if (_a == null || position <= _a!) return;
    _b = position;
  }

  void clear() {
    _a = null;
    _b = null;
  }

  /// The seek target when [position] reached the end of the loop:
  /// point A once [position] is at/past B, null otherwise.
  Duration? seekTarget(Duration position) {
    if (!isActive) return null;
    return position >= _b! ? _a : null;
  }
}
