// 路 A 迁移快照 — Swift 2.0 迁移主路 (§5.3),Flutter 1.1.6.x 小版本先发.
//
// Swift 读不了 Hive(差距表 §6-11),所以在发布 Swift 2.0 之前先发
// 这个 Flutter 小版本:每次启动把 `app_settings` 全量导出为一份
// 类型化 JSON 快照 (`Documents/migration_snapshot.json`,每次启动
// 覆盖写)。用户只要在这期间打开过一次旧 app,快照就是新鲜的;
// Swift 2.0 首次启动读它迁移。不发这个小版本,主路不存在。
//
// 事实基线 (§5.2):值形态只有 JSON 字符串 / String / int / double /
// bool / `List<int>`,无自定义 Hive 对象。快照保留每个值的真实
// 类型 (逐键类型标签 `types`),Swift 侧按类型读。探针 R1 补了一
// 种基线漏的形态:`List<double>` (Hive typeId 7,
// `hao_eq_band_gains`),同样保留真实类型 (标签 `'doubleList'`)。
// 基线之外的
// 值 (Uint8List / DateTime / 坏值) 也容错处理,见 [typeOf]。
//
// 安全规则 (本文件绝不违反):
// - 绝不删除 Hive box 文件,绝不写 box,只读。
// - 导出失败绝不能崩 app、绝不能拖慢启动:启动链上只挂一个
//   fire-and-forget 的 [writeAfterStartup],全部 try/catch +
//   静默日志,失败就下次启动再写;不弹任何打扰用户的东西。
// - 原子写:先写同目录临时文件 (flush) 再换名覆盖 (LocalStore
//   的 `.atomic` 做法);写坏了旧快照还在,临时文件会被清掉。
// - 快照内容与 box 当时内容一致:读 box 是同步循环 (中间无
//   await,Dart 单线程),整份拷贝是某一时刻的完整 box,不会
//   出现一半旧一半新的半份快照;序列化只读这份内存拷贝。
//
// 参考实现核对 (2026-11-23):`standalone-app-2.0-hive` 的
// `storage_migration.dart` + `f20_hive_recovery_test.dart` 已逐项
// 读过——它们依赖的 `HiveStore.isInitialized / wasRecovered /
// recoveredBackupPath` 与 `HiveKeys.storageSchemaVersion /
// storageRecoveredAt` 在 build 31 的 `hive_store.dart` 里根本
// 不存在 (那份工作未验证、未提交、未合入),所以本文件不引用
// 它的任何结论,只用 build 31 真实存在的 `HiveStore.box`。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

import '../../app/consts.dart';
import '../logging/app_log.dart';
import 'hive_store.dart';
import 'local_paths.dart';

class MigrationSnapshot {
  MigrationSnapshot._();

  /// 快照文件名 (Documents 下,Swift 2.0 按此名读)。
  static const String fileName = 'migration_snapshot.json';

  /// 快照 envelope 的 schema 版本。只在 envelope 结构本身变了
  /// (旧快照读不了) 才 bump;加键/加类型标签不 bump。
  static const int schemaVersion = 1;

  /// 导出进行中标志:启动只调一次,重入直接跳过,绝不并发写
  /// 同一个快照文件。
  static bool _inFlight = false;

  /// 值的类型标签。Swift 读侧契约 (2026-11-23 定):`types` 的取值
  /// 只许用这 7 个 —— `string | int | double | bool | json |
  /// intList | doubleList`。其中 `'json'` = JSON 字符串值 (读侧
  /// 先解析再落盘,快照里保持原串不预解析);`'intList'` =
  /// `List<int>`;`'doubleList'` = `List<double>` (探针 R1:
  /// `hao_eq_band_gains` 在 `equalizer_store.dart:264` 以
  /// `List<double>` (Hive typeId 7) 写入)。
  ///
  /// 映射表 (实键形态全覆盖;其余形态按“有损但安全”就近归入,
  /// 绝不引入第 8 个标签):
  /// - JSON 字符串 (能解析成 Map/List 的 String) → `'json'`,
  ///   值保持原串;普通 String → `'string'`。只认对象/数组:
  ///   `"123"`、`"true"` 这类标量串仍是 `'string'`。
  /// - `int` → `'int'`;有限 `double` → `'double'`;
  ///   `bool` → `'bool'`。
  /// - 全 int 的 List → `'intList'`;全 num 的 List (纯 double
  ///   与 int/double 混杂) → `'doubleList'` (读侧按 [Double]
  ///   解,整数位 widen,真实量级下数值无损);空 List 无法分元
  ///   素类型,记 `'intList'`。
  /// - `Map` 与非数值 List (String/bool/Map 元素) → `'json'`,
  ///   值编成 JSON 字符串 (读侧解析后原样落盘,无损)。
  /// - 基线外形态 (app 当前不写,防御性处理):`Uint8List` →
  ///   `'string'` (base64 文本);`DateTime` → `'string'` (UTC
  ///   ISO 8601 文本)。探针 R2:普通 `DateTime` (含
  ///   `DateTime.utc`) 走 DateTimeWithTimezoneAdapter (Hive
  ///   typeId 18,毫秒 + isUtc),只有内部类 `DateTimeWithoutTZ`
  ///   走 typeId 16;两者解码后都是 Dart `DateTime`,这里一律
  ///   转 UTC 存,瞬时值不丢。
  /// - 契约里没有 null 标签:null 值与 JSON 写不出的值 (非有限
  ///   double、含 NaN 的集合、非 String 键的 Map、Set/HiveList
  ///   等未知类型) → 值存 null、标签记 `'string'`。读侧按
  ///   String 取不到值会安全跳过该键;键本身仍留在 `data` 里,
  ///   探针的键集对照不受影响。其它键不受影响。
  /// 读侧契约的 7 个合法类型标签。单测用它断言快照不写出
  /// 第 8 个标签。
  static const List<String> allowedTypes = <String>[
    'string',
    'int',
    'double',
    'bool',
    'json',
    'intList',
    'doubleList',
  ];

  static String typeOf(Object? value) {
    if (value == null) return 'string';
    if (value is String) return _isJsonString(value) ? 'json' : 'string';
    if (value is bool) return 'bool';
    if (value is int) return 'int';
    if (value is double) return value.isFinite ? 'double' : 'string';
    if (value is Uint8List) return 'string';
    if (value is DateTime) return 'string';
    if (value is List) {
      if (!_isJsonEncodable(value)) return 'string';
      if (value.isEmpty) return 'intList';
      if (value.every((e) => e is int)) return 'intList';
      if (value.every((e) => e is num)) return 'doubleList';
      return 'json';
    }
    if (value is Map) {
      return _isJsonEncodable(value) ? 'json' : 'string';
    }
    return 'string';
  }

  /// JSON 字符串 (读侧先解析再落盘的那种):首字符是 `{`/`[`
  /// 且能解析成 Map/List。标量串 (`"123"`、`"true"`) 不是。
  static bool _isJsonString(String value) {
    final trimmed = value.trimLeft();
    if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) {
      return false;
    }
    try {
      final decoded = jsonDecode(value);
      return decoded is Map || decoded is List;
    } catch (_) {
      return false;
    }
  }

  /// 该值能不能原样进 `jsonEncode` (递归检查)。`Uint8List` /
  /// `DateTime` 在顶层有专门的存法,嵌在集合里则算写不出。
  static bool _isJsonEncodable(Object? value) {
    if (value == null || value is String || value is bool) return true;
    if (value is int) return true;
    if (value is double) return value.isFinite;
    if (value is List) return value.every(_isJsonEncodable);
    if (value is Map) {
      return value.entries.every(
        (e) => e.key is String && _isJsonEncodable(e.value),
      );
    }
    return false;
  }

  /// 按类型标签把值转成可进 JSON 的形态。
  /// - `'json'` 且值是 Map/List:编成 JSON 字符串 (读侧解析
  ///   后落盘);值已是 String 时保持原串。
  /// - `Uint8List` → base64 文本;`DateTime` → UTC ISO 8601
  ///   文本 (两者标签都是 `'string'`)。
  /// - 标签 `'string'` 但值不是 String (null、非有限 double、
  ///   写不出的集合/未知类型) → null,读侧安全跳过该键。
  /// - 其余原样。
  static Object? _snapshotValue(Object? value, String type) {
    if (value == null) return null;
    if (type == 'json' && value is! String) {
      try {
        return jsonEncode(value);
      } catch (_) {
        return null;
      }
    }
    if (value is Uint8List) return base64Encode(value);
    if (value is DateTime) return value.toUtc().toIso8601String();
    if (type == 'string' && value is! String) return null;
    return value;
  }

  /// 从一份已读进内存的键值表建 envelope (纯函数,可单测)。
  /// 键排序后写,输出稳定可 diff。`entries` 必须是一份完整的
  /// box 拷贝,不要边读边调——调用方先整体读完再传进来。
  static Map<String, dynamic> buildEnvelope(
    Map<String, Object?> entries, {
    required String appVersion,
    required int appBuild,
    DateTime? now,
  }) {
    final keys = entries.keys.toList()..sort();
    final data = <String, Object?>{};
    final types = <String, String>{};
    for (final key in keys) {
      final value = entries[key];
      final type = typeOf(value);
      types[key] = type;
      data[key] = _snapshotValue(value, type);
    }
    return <String, dynamic>{
      'schema': schemaVersion,
      'app': 'HAo Studio',
      'appVersion': appVersion,
      'appBuild': appBuild,
      'exportedAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
      'entries': keys.length,
      'data': data,
      'types': types,
    };
  }

  /// 把 [box] 全量导出到 `documentsDir/migration_snapshot.json`。
  /// 永不抛错:任何一步失败都返回 false (调用方只记日志,下次
  /// 启动再写),且绝不留半份快照文件 (失败时旧快照原样保留,
  /// 临时文件会被清掉)。
  static Future<bool> writeSnapshot({
    required Box<dynamic> box,
    required Directory documentsDir,
    String? appVersion,
    int? appBuild,
    DateTime? now,
  }) async {
    if (_inFlight) return false;
    _inFlight = true;
    final target = File('${documentsDir.path}/$fileName');
    final tmp = File('${documentsDir.path}/$fileName.tmp');
    try {
      // 1. 同步整体读进内存:循环内无 await,所以这份拷贝是某
      //    一时刻的完整 box (见文件头注释)。
      final entries = <String, Object?>{};
      for (final key in box.keys) {
        entries[key.toString()] = box.get(key);
      }
      // 2. 序列化只读内存拷贝,不碰 box。
      final json = jsonEncode(
        buildEnvelope(
          entries,
          appVersion: appVersion ?? kAppVersion,
          appBuild: appBuild ?? kAppBuild,
          now: now,
        ),
      );
      // 3. 原子写:临时文件 (同目录、同文件系统) + flush + 换名。
      await tmp.writeAsString(json, flush: true);
      await tmp.rename(target.path);
      return true;
    } catch (e) {
      debugPrint('MigrationSnapshot: write failed ($e)');
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      return false;
    } finally {
      _inFlight = false;
    }
  }

  /// 启动链入口 (main.dart warm-up 里 fire-and-forget 调用)。
  /// Documents 路径已由 warm-up 先行 warm 好;这里只做兜底
  /// (缓存未命中时现取)。永不抛错、永不阻塞启动。
  static Future<void> writeAfterStartup() async {
    try {
      final docsPath =
          LocalPaths.documentsPathSync ??
          await LocalPaths.ensureDocumentsPath();
      final ok = await writeSnapshot(
        box: HiveStore.box,
        documentsDir: Directory(docsPath),
      );
      if (ok) {
        AppLog.debug('迁移快照已写 $fileName');
      } else {
        AppLog.warn('迁移快照写入失败,下次启动重试');
      }
    } catch (e) {
      // Hive 未初始化 / 取目录失败等:静默日志,下次启动再写。
      debugPrint('MigrationSnapshot: $e');
      try {
        AppLog.warn('迁移快照失败: $e');
      } catch (_) {}
    }
  }
}
