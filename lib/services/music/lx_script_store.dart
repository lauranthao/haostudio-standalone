// LX script source settings — Hive-backed (M-P0-6).
//
// Two things live here:
// - Enable/disable per script id (bundled + custom). Default: all
//   enabled, except the dead-host ids in [_defaultDisabledIds]
//   (ikun), which are off until the user turns one on — the store
//   keeps the DISABLED list only for the rest, plus an
//   explicit-enable list for the default-disabled ones. No "at least
//   one" guard: scripts are additive to the built-in resolvers, so
//   turning them all off is harmless.
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
  /// Bundled scripts disabled by default (dead upstream host): a
  /// fresh install has them OFF, but they still load and show in
  /// 音源管理 with their toggle, and a user who turns one ON stays
  /// on — the explicit-enable list is the record of that choice and
  /// is never reset by an upgrade. No stored choice is ever
  /// overwritten. (2026-11-23: the only entry, ikun, was DELETED
  /// outright — api.ikunshare.com re-verified dead — along with
  /// luoxue and xinlan, so this set is empty for now.)
  static const _defaultDisabledIds = <String>{};

  static List<String> _explicitlyEnabledIds({Box<dynamic>? box}) {
    final b = _safeBox(box);
    if (b == null) return const [];
    final raw = b.get(HiveKeys.lxScriptExplicitlyEnabled);
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

  static bool isEnabled(String scriptId, {Box<dynamic>? box}) {
    if (_defaultDisabledIds.contains(scriptId)) {
      return _explicitlyEnabledIds(box: box).contains(scriptId);
    }
    return !_disabledIds(box: box).contains(scriptId);
  }

  static Future<void> setEnabled(
    String scriptId,
    bool value, {
    Box<dynamic>? box,
  }) async {
    final b = _safeBox(box);
    if (b == null) return;
    if (_defaultDisabledIds.contains(scriptId)) {
      // The explicit-enable list is the source of truth for these
      // ids; drop any stale disabled-list entry so the two lists
      // cannot disagree about the same script.
      final next = _explicitlyEnabledIds(box: b).toSet();
      if (value) {
        next.add(scriptId);
      } else {
        next.remove(scriptId);
      }
      await b.put(
        HiveKeys.lxScriptExplicitlyEnabled,
        jsonEncode(next.toList()),
      );
      final disabled = _disabledIds(box: b).toSet()..remove(scriptId);
      await b.put(HiveKeys.lxScriptDisabled, jsonEncode(disabled.toList()));
      return;
    }
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

  /// Manual script order (chen 2026-11-18: drag to reorder in
  /// 音源管理). JSON list of script ids, first = tried first among
  /// LX script jobs. Ids absent from the list (newly added scripts)
  /// sort after all listed ones; stale ids (deleted scripts) are
  /// ignored by readers and pruned when a script is deleted.
  static List<String> scriptOrder({Box<dynamic>? box}) {
    final b = _safeBox(box);
    if (b == null) return const [];
    final raw = b.get(HiveKeys.lxScriptOrder);
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded
              .map((e) => e.toString())
              .where((s) => s.isNotEmpty)
              .toList();
        }
      } catch (_) {}
    }
    return const [];
  }

  static Future<void> saveScriptOrder(
    List<String> ids, {
    Box<dynamic>? box,
  }) async {
    final b = _safeBox(box);
    if (b == null) return;
    await b.put(HiveKeys.lxScriptOrder, jsonEncode(ids));
  }

  /// Bundled scripts the user deleted. A deleted bundled id is never
  /// re-seeded from assets and never loaded again — including after an
  /// app restart. Re-adding is possible via its URL (addCustomScript).
  static List<String> deletedBundledIds({Box<dynamic>? box}) {
    final b = _safeBox(box);
    if (b == null) return const [];
    final raw = b.get(HiveKeys.lxDeletedBundledScripts);
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

  static bool isBundledDeleted(String id, {Box<dynamic>? box}) =>
      deletedBundledIds(box: box).contains(id);

  static Future<void> markBundledDeleted(
    String id, {
    Box<dynamic>? box,
  }) async {
    final b = _safeBox(box);
    if (b == null) return;
    final next = deletedBundledIds(box: b).toSet()..add(id);
    await b.put(
      HiveKeys.lxDeletedBundledScripts,
      jsonEncode(next.toList()),
    );
  }

  static Future<void> unmarkBundledDeleted(
    String id, {
    Box<dynamic>? box,
  }) async {
    final b = _safeBox(box);
    if (b == null) return;
    final next = deletedBundledIds(box: b).toSet()..remove(id);
    await b.put(
      HiveKeys.lxDeletedBundledScripts,
      jsonEncode(next.toList()),
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
