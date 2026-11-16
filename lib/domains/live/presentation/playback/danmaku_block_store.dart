// Danmaku block store (S3/S4) — keyword + username blocking.
//
// Hive-backed (`hao_dm_block`), same shape and match semantics as the
// web app's `hao_dm_block`, which was never ported to Flutter until
// now: entries are {id, text, kind} with kind 'word' (keyword) or
// 'user' (username). Matching is substring, exactly like the web
// `haoDmBlocked`: a keyword blocks any message whose text contains
// it; a username entry blocks any sender whose name contains it.
// No regex blocking (decided against — see the gap list §S3).

import 'dart:convert';

import 'package:hive_ce_flutter/hive_ce_flutter.dart';

import '../../../../core/storage/hive_store.dart';

/// One block entry.
class DanmakuBlockEntry {
  const DanmakuBlockEntry({
    required this.id,
    required this.text,
    required this.kind,
  });

  factory DanmakuBlockEntry.fromJson(Map<String, dynamic> json) =>
      DanmakuBlockEntry(
        id: json['id']?.toString() ?? '',
        text: json['text']?.toString() ?? '',
        kind: json['kind']?.toString() == 'user' ? 'user' : 'word',
      );

  /// `b<epochMillis>` — same id scheme as the web store.
  final String id;

  /// The blocked word or username (trimmed, non-empty).
  final String text;

  /// 'word' (keyword) or 'user' (username).
  final String kind;

  bool get isUser => kind == 'user';

  Map<String, dynamic> toJson() => {'id': id, 'text': text, 'kind': kind};
}

/// Keyword + username block list.
class DanmakuBlockStore {
  static List<DanmakuBlockEntry> getAll({Box<dynamic>? box}) {
    final b = _safeBox(box);
    final raw = b?.get(HiveKeys.danmakuBlockList);
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map<String, dynamic>>()
            .map(DanmakuBlockEntry.fromJson)
            .where((e) => e.text.isNotEmpty)
            .toList();
      }
    } catch (_) {}
    return const [];
  }

  static Future<void> _save(
    List<DanmakuBlockEntry> entries, {
    Box<dynamic>? box,
  }) async {
    final b = _safeBox(box);
    if (b == null) return;
    await b.put(
      HiveKeys.danmakuBlockList,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }

  /// Add an entry. Returns false (and writes nothing) when [text] is
  /// empty or an identical text+kind entry already exists — same as
  /// the web `haoDmBlockAdd`.
  static Future<bool> add(
    String text,
    String kind, {
    Box<dynamic>? box,
  }) async {
    final t = text.trim();
    if (t.isEmpty) return false;
    final k = kind == 'user' ? 'user' : 'word';
    final list = getAll(box: box);
    if (list.any((e) => e.text == t && e.kind == k)) return false;
    list.add(
      DanmakuBlockEntry(
        id: 'b${DateTime.now().millisecondsSinceEpoch}',
        text: t,
        kind: k,
      ),
    );
    await _save(list, box: box);
    return true;
  }

  static Future<void> remove(String id, {Box<dynamic>? box}) async {
    await _save(
      getAll(box: box).where((e) => e.id != id).toList(),
      box: box,
    );
  }

  static List<String> keywords({Box<dynamic>? box}) => getAll(box: box)
      .where((e) => !e.isUser)
      .map((e) => e.text)
      .toList();

  static List<String> usernames({Box<dynamic>? box}) => getAll(box: box)
      .where((e) => e.isUser)
      .map((e) => e.text)
      .toList();

  /// Web `haoDmBlocked` semantics: keyword = substring of the
  /// message text; username = substring of the sender name.
  static bool blocksMessage(
    String message,
    String userName, {
    Box<dynamic>? box,
  }) {
    for (final e in getAll(box: box)) {
      if (e.isUser) {
        if (userName.isNotEmpty && userName.contains(e.text)) return true;
      } else {
        if (message.isNotEmpty && message.contains(e.text)) return true;
      }
    }
    return false;
  }
}

Box<dynamic>? _safeBox(Box<dynamic>? box) {
  if (box != null) return box;
  try {
    return HiveStore.box;
  } catch (_) {
    return null;
  }
}
