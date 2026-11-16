// Huya data models — port of the model classes at the bottom of Pure Live
// 3.x lib/shared/platforms/huya/huya_site.dart (HuyaLineModel,
// HuyaBitRateModel, HuyaUrlDataModel, HuyaViewerIdentity) plus the danmaku
// credentials carried in LiveRoom.danmakuData.
//
// Our LiveRoom.data is a `Map<String, dynamic>?` (not a typed object as in
// Pure Live), so HuyaUrlDataModel serialises into that map under the keys
// `lines` / `bitRates` / `isXingxiu` and is rebuilt from it on read.

import '../../../core/models/live_models.dart';

/// flv | hls — one entry per (CDN, transport) pair in gameStreamInfoList.
enum HuyaLineType { flv, hls }

/// One CDN line (HuyaLineModel, upstream L1256-1276).
///
/// `line` is the CDN base URL (sFlvUrl / sHlsUrl); `cdnType` is the CDN
/// name exactly as the server returns it (AL / TX / HS … — never
/// hard-coded, server order is kept). `presenterUid` prefers the
/// `presenterUid` field of the stream item and falls back to the room's
/// topSid (lChannelId), matching upstream behaviour.
class HuyaLineModel {
  const HuyaLineModel({
    required this.line,
    required this.lineType,
    required this.flvAntiCode,
    required this.hlsAntiCode,
    required this.streamName,
    required this.cdnType,
    required this.presenterUid,
    this.bitRate = 0,
  });

  final String line;
  final HuyaLineType lineType;
  final String flvAntiCode;
  final String hlsAntiCode;
  final String streamName;
  final String cdnType;
  final int presenterUid;

  /// Bitrate this line was last resolved for (carried on the model by
  /// upstream; the quality menu owns the requested bitrate).
  final int bitRate;

  HuyaLineModel copyWith({int? bitRate}) => HuyaLineModel(
        line: line,
        lineType: lineType,
        flvAntiCode: flvAntiCode,
        hlsAntiCode: hlsAntiCode,
        streamName: streamName,
        cdnType: cdnType,
        presenterUid: presenterUid,
        bitRate: bitRate ?? this.bitRate,
      );

  @override
  String toString() {
    final host = Uri.tryParse(line)?.host;
    return 'HuyaLineModel{host: ${host?.isNotEmpty == true ? host : 'unknown'}, '
        'lineType: $lineType, cdnType: $cdnType, bitRate: $bitRate}';
  }
}

/// One quality entry from vMultiStreamInfo (HuyaBitRateModel).
///
/// `bitRate` is the server's integer bitrate id; 0 = 原画 (source quality).
/// Never invent a bitrate the server did not return (no 2000 fallback).
class HuyaBitRateModel {
  const HuyaBitRateModel({required this.bitRate, required this.name});

  final int bitRate;
  final String name;
}

/// Play descriptor for one room snapshot (HuyaUrlDataModel).
class HuyaUrlDataModel {
  const HuyaUrlDataModel({
    required this.bitRates,
    required this.lines,
    required this.url,
    required this.uid,
    required this.isXingxiu,
  });

  final List<HuyaLineModel> lines;
  final List<HuyaBitRateModel> bitRates;
  final String url;
  final String uid;
  final bool isXingxiu;

  /// LiveRoom.data map keys.
  static const String keyLines = 'lines';
  static const String keyBitRates = 'bitRates';
  static const String keyIsXingxiu = 'isXingxiu';
  static const String keyUid = 'uid';

  Map<String, dynamic> toDataMap() => <String, dynamic>{
        keyLines: lines,
        keyBitRates: bitRates,
        keyIsXingxiu: isXingxiu,
        keyUid: uid,
      };

  /// Rebuild from a LiveRoom.data map; returns null when the map is not a
  /// Huya play descriptor (e.g. a room that was never detailed).
  static HuyaUrlDataModel? fromDataMap(Map<String, dynamic>? data) {
    if (data == null) return null;
    final lines = data[keyLines];
    final bitRates = data[keyBitRates];
    if (lines is! List || bitRates is! List) return null;
    return HuyaUrlDataModel(
      lines: lines.whereType<HuyaLineModel>().toList(growable: false),
      bitRates: bitRates.whereType<HuyaBitRateModel>().toList(growable: false),
      url: '',
      uid: data[keyUid]?.toString() ?? '',
      isXingxiu: data[keyIsXingxiu] == true,
    );
  }
}

/// Anonymous viewer identity (HuyaViewerIdentity).
class HuyaViewerIdentity {
  const HuyaViewerIdentity({
    required this.uid,
    required this.guid,
    required this.isAnonymous,
  });

  final int uid;
  final String guid;
  final bool isAnonymous;
}

/// Danmaku credentials for a room (HuyaDanmakuArgs in Pure Live).
///
/// Stored as a plain map in LiveRoom.danmakuData under these keys; the
/// TARS danmaku transport itself lives in huya_danmaku.dart.
class HuyaDanmakuArgs {
  const HuyaDanmakuArgs({
    required this.uid,
    required this.topSid,
    required this.subSid,
  });

  static const String keyUid = 'uid';
  static const String keyTopSid = 'topSid';
  static const String keySubSid = 'subSid';

  final int uid;
  final int topSid;
  final int subSid;

  Map<String, dynamic> toDataMap() => <String, dynamic>{
        keyUid: uid,
        keyTopSid: topSid,
        keySubSid: subSid,
      };

  static HuyaDanmakuArgs? fromDataMap(Map<String, dynamic>? data) {
    if (data == null) return null;
    final uid = data[keyUid];
    final topSid = data[keyTopSid];
    final subSid = data[keySubSid];
    if (uid is! int || topSid is! int || subSid is! int) return null;
    return HuyaDanmakuArgs(uid: uid, topSid: topSid, subSid: subSid);
  }
}

/// Convenience: the room's Huya play descriptor, if it has one.
HuyaUrlDataModel? huyaDataOf(LiveRoom room) =>
    HuyaUrlDataModel.fromDataMap(room.data);
