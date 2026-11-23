// Safe casts for JSON / Hive / server data (build 31 crash hunt).
//
// The danmaku crash (b30) proved the trap: `(box.get(key) as num?)`
// throws TypeError when an old build stored a value of the wrong type,
// and the throw escapes into a page load / app start and kills the app.
// Every cast in this file returns a default instead of throwing, so a
// wrong-typed stored / cached / server value degrades to "missing"
// instead of crashing.
//
// Rules:
// - Strict `is` checks, no coercion: a String '123' is NOT an int, a
//   num 1 is NOT a bool. Well-typed data behaves byte-identically to
//   the old `as X?` casts; wrong-typed data falls back to the default.
// - `jStr`/`jInt`/`jDouble`/`jBool` return a non-null default (for
//   `?? default` call sites); the `N` variants return null (for
//   nullable fields where null is meaningful).
// - `jList`/`jMap` return empty collections, never null.

/// String field, default '' (or [def]).
String jStr(dynamic v, [String def = '']) => v is String ? v : def;

/// Nullable String field.
String? jStrN(dynamic v) => v is String ? v : null;

/// Int field, default 0 (or [def]). Accepts int and double.
int jInt(dynamic v, [int def = 0]) => v is num ? v.toInt() : def;

/// Nullable int field.
int? jIntN(dynamic v) => v is num ? v.toInt() : null;

/// Double field, default 0.0 (or [def]). Accepts int and double.
double jDouble(dynamic v, [double def = 0.0]) =>
    v is num ? v.toDouble() : def;

/// Nullable double field.
double? jDoubleN(dynamic v) => v is num ? v.toDouble() : null;

/// Bool field, default false (or [def]).
bool jBool(dynamic v, [bool def = false]) => v is bool ? v : def;

/// Nullable bool field.
bool? jBoolN(dynamic v) => v is bool ? v : null;

/// List field, default empty. Accepts any List (elements unchecked —
/// callers filter with whereType / per-entry try as before).
List<dynamic> jList(dynamic v) => v is List ? v : const [];

/// Nullable List field.
List<dynamic>? jListN(dynamic v) => v is List ? v : null;

/// Map field, default empty. Accepts any Map. A map that is already
/// `Map<String, dynamic>` is returned as-is; any other map is copied
/// with String keys (a JSON object always has String keys; a
/// non-String-keyed map returns `{}`).
Map<String, dynamic> jMap(dynamic v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) {
    try {
      return Map<String, dynamic>.from(v);
    } catch (_) {
      return const {};
    }
  }
  return const {};
}

/// Nullable Map field.
Map<String, dynamic>? jMapN(dynamic v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) {
    try {
      return Map<String, dynamic>.from(v);
    } catch (_) {
      return null;
    }
  }
  return null;
}
