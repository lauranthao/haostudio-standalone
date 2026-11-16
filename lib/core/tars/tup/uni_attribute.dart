// TUP attribute map — port of Pure Live 3.x
// lib/core/tars/tup/uni_attribute.dart, TUP3 only.
//
// Upstream also carries the legacy TUP (v2) `oldData` path; this port
// drops it: every Huya WUP call sets TUP3 (`PACKET_TYPE_TUP3`) and the
// server answers in kind. Method names match upstream so a full port
// stays a drop-in later.

import 'dart:typed_data';

import '../codec/tars_input_stream.dart';
import '../codec/tars_output_stream.dart';
import '../codec/tars_struct.dart';
import 'const.dart';
import 'object_create_exception.dart';

class UniAttribute extends TarsStruct {
  Map<String, Uint8List> newData = <String, Uint8List>{};

  Map<String, Object> cachedData = <String, Object>{};

  int version = TupConst.packetTypeTup3;
  String encodeName = 'UTF-8';

  final TarsInputStream inputStream = TarsInputStream(null);

  void clearCacheData() {
    cachedData.clear();
  }

  bool isEmpty() => newData.isEmpty;

  int get length => newData.length;

  bool containsKey(String key) => newData.containsKey(key);

  void put<T>(String name, T t) {
    if (name.isEmpty) {
      throw ArgumentError('put key can not be null');
    }

    final out = TarsOutputStream();
    out.setServerEncoding(encodeName);
    out.write(t, 0);
    final sBuffer = out.toUint8List();

    cachedData.remove(name);
    newData[name] = sBuffer;
  }

  Object decodeData(Uint8List data, Object? proxy) {
    inputStream.wrap(data);
    inputStream.setServerEncoding(encodeName);
    final o = inputStream.read(proxy, 0, true);
    return o;
  }

  T getByClass<T>(String name, T proxy) {
    if (!newData.containsKey(name)) {
      return null as T;
    } else if (cachedData.containsKey(name)) {
      return cachedData[name] as T;
    } else {
      try {
        final data = newData[name]!;
        final o = decodeData(data, proxy!);
        saveDataCache(name, o);
        return o as T;
      } catch (ex) {
        throw ObjectCreateException(ex.toString());
      }
    }
  }

  /// Returns [defaultObj] when the key is absent or undecodable.
  T get<T>(String name, T defaultObj) {
    try {
      final Object? result = getByClass<T>(name, defaultObj);
      if (result == null) {
        return defaultObj;
      }
      return result as T;
    } catch (_) {
      return defaultObj;
    }
  }

  void saveDataCache(String name, Object o) {
    cachedData[name] = o;
  }

  Uint8List encode() {
    final outputStream = TarsOutputStream();
    outputStream.setServerEncoding(encodeName);
    outputStream.write(newData, 0);
    return outputStream.toUint8List();
  }

  void decode(Uint8List buffer, {int index = 0}) {
    inputStream.wrap(buffer, pos: index);
    inputStream.setServerEncoding(encodeName);
    version = TupConst.packetTypeTup3;
    newData = inputStream.readMap<String, Uint8List>(
      <String, Uint8List>{'': Uint8List.fromList(<int>[0x0])},
      0,
      false,
    );
  }

  @override
  void writeTo(TarsOutputStream outputStream) {
    outputStream.write(newData, 0);
  }

  @override
  void readFrom(TarsInputStream inputStream) {
    // readMap builds a fresh map — assign it (upstream drops the return
    // value here; harmless there only because UniPacket overrides readFrom
    // to read the RequestPacket instead).
    newData = inputStream.readMap<String, Uint8List>(
      <String, Uint8List>{'': Uint8List.fromList(<int>[0x0])},
      0,
      false,
    );
  }

  @override
  Object deepCopy() {
    throw UnimplementedError();
  }

  @override
  void displayAsString(StringBuffer sb, int level) {
    throw UnimplementedError();
  }
}
