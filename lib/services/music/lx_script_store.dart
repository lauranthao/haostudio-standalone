// LX script source settings — Hive-backed (M-P0-6).
//
// Two things live here:
// - Enable/disable per script id (bundled + custom). Default: all
//   enabled; the store keeps the DISABLED list only. No "at least one"
//   guard: scripts are additive to the built-in resolvers, so turning
//   them all off is harmless.
// - User-added custom scripts: {id, name, url, code, addedAt}. The code
//   is stored so scripts load offline at startup without re-fetching.
//
// All methods take an optional [box] so tests can pass a throwaway
// box; production call sites omit it and use HiveStore.box.

import 'dart:convert';

import 'package:hive_ce_flutter/hive_ce_flutter.dart';

import '../../core/storage/hive_store.dart';

class LxCustomScript {
  const LxCustomScript({
    required this.id,
    required this.name,
    required this.url,
    required this.code,
    required this.addedAt,
  });

  factory LxCustomScript.fromJson(Map<String, dynamic> j) =>
      LxCustomScript(
        id: j['id']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        url: j['url']?.toString() ?? '',
        code: j['code']?.toString() ?? '',
        addedAt: (j['addedAt'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'code': code,
        'addedAt': addedAt,
      };

  final String id;
  final String name;
  final String url;
  final String code;
  final int addedAt;
}

class LxScriptSourcesStore {
  static List<String> _disabledIds({Box<dynamic>? box}) {
    final b = _safeBox(box);
    if (b == null) return const [];
    final raw = b.get(HiveKeys.lxScriptDisabled);
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded.map((e) => e.toString()).toList();
        }
      } catch (_) {}
    }
    return const [];
  }

  static bool isEnabled(String scriptId, {Box<dynamic>? box}) =>
      !_disabledIds(box: box).contains(scriptId);

  static Future<void> setEnabled(
    String scriptId,
    bool value, {
    Box<dynamic>? box,
  }) async {
    final b = _safeBox(box);
    if (b == null) return;
    final next = _disabledIds(box: b).toSet();
    if (value) {
      next.remove(scriptId);
    } else {
      next.add(scriptId);
    }
    await b.put(HiveKeys.lxScriptDisabled, jsonEncode(next.toList()));
  }

  static List<LxCustomScript> customScripts({Box<dynamic>? box}) {
    final b = _safeBox(box);
    if (b == null) return const [];
    final raw = b.get(HiveKeys.lxCustomScripts);
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return [
            for (final e in decoded)
              if (e is Map<String, dynamic>)
                LxCustomScript.fromJson(e)
              else if (e is Map)
                LxCustomScript.fromJson(
                  Map<String, dynamic>.from(e),
                ),
          ].where((s) => s.id.isNotEmpty && s.code.isNotEmpty).toList();
        }
      } catch (_) {}
    }
    return const [];
  }

  static Future<void> saveCustomScript(
    LxCustomScript script, {
    Box<dynamic>? box,
  }) async {
    final b = _safeBox(box);
    if (b == null) return;
    final next = customScripts(box: b).where((s) => s.id != script.id).toList()
      ..add(script);
    await b.put(
      HiveKeys.lxCustomScripts,
      jsonEncode(next.map((s) => s.toJson()).toList()),
    );
  }

  static Future<void> removeCustomScript(
    String id, {
    Box<dynamic>? box,
  }) async {
    final b = _safeBox(box);
    if (b == null) return;
    final next = customScripts(box: b).where((s) => s.id != id).toList();
    await b.put(
      HiveKeys.lxCustomScripts,
      jsonEncode(next.map((s) => s.toJson()).toList()),
    );
  }
}

/// The caller's box, or HiveStore.box when Hive is initialised.
/// Returns null when Hive is NOT initialised yet — callers fall back
/// to defaults instead of crashing.
Box<dynamic>? _safeBox(Box<dynamic>? box) {
  if (box != null) return box;
  try {
    return HiveStore.box;
  } catch (_) {
    return null;
  }
}
