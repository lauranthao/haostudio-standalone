// Huya WUP (TARS-over-HTTP) calls — port of the WUP pieces of Pure Live
// 3.x lib/shared/platforms/huya/huya_site.dart (getNativeCdnTokenInfoEx,
// getCndTokenInfoEx, HuyaCdnTokenLease) + lib/shared/platforms/huya/
// huya_utils.dart (getHuyaSuperChatMessageList, huyaSuperChatsFromPanel).
//
// Two WUP contracts live here:
//
// 1. Native playback token (`getCdnTokenInfoEx`, servant `liveui`): the
//    long-lived FLV anti-code. The web-template path signs a ~120 s
//    transport lease; the native WUP token outlives it (~420 s in Pure
//    Live's probes). It is FLV-only — NEVER reuse it for HLS.
// 2. Super-chat message board (`getHeadLineMessageBoard`, servant
//    `wupui`): the HTTP fallback for 醒目留言. The WS only carries a
//    uri-2001314 board notification; the board itself is fetched here.
//
// Both calls own their Dio client and close it (force) when done, so a
// timeout cannot leak a socket across repeated calls. Every function
// takes an optional [clientFactory] so tests can stub the transport
// without touching the network.

import 'dart:math';

import '../../../core/models/live_models.dart';
import '../../../core/tars/base_tars_http.dart';
import '../../../core/tars/game_event_message_board_panel.dart';
import '../../../core/tars/get_cdn_token_ex_req.dart';
import '../../../core/tars/get_cdn_token_ex_resp.dart';
import '../../../core/tars/get_game_event_message_board_req.dart';
import '../../../core/tars/get_game_event_message_board_rsp.dart';
import '../../../core/tars/types.dart';
import 'huya_anti_code.dart';
import 'huya_models.dart';
import 'huya_request_params.dart';

/// Creates a fresh WUP client for [servant] with [headers]; the caller
/// owns it and must close `client.dio` (force) when done.
typedef HuyaWupClientFactory = BaseTarsHttp Function();

/// Web-identity token constants (Pure Live HuyaSite L161-164).
const String _webPlaybackTarsUserAgent = 'webh5&0.1.0&websocket';
const int _webPlaybackAppId = 66;
const int _webPlaybackTokenLoopTime = 0;

/// Native-play user agent for the WUP token client (Pure Live
/// `HuyaSite.nativePlayUserAgent` = the HYSDK UA).
const String _nativePlayUserAgent = HuyaRequestParams.hysdkUa;

BaseTarsHttp _createCdnTokenClient(Map<String, String> headers) {
  final client = BaseTarsHttp(
    'https://wup.huya.com',
    'liveui',
    timeOut: 6,
    headers: headers,
  );
  client.dio.options.sendTimeout = const Duration(seconds: 6);
  client.dio.options.receiveTimeout = const Duration(seconds: 6);
  return client;
}

BaseTarsHttp _createMessageBoardClient() {
  // Auxiliary to playback: short timeouts, and one retry must not retain
  // another retry's socket (callers always close the client).
  final client = BaseTarsHttp(
    'https://wup.huya.com',
    'wupui',
    timeOut: 2,
    headers: HuyaRequestParams.requestHeaders,
  );
  client.dio.options.sendTimeout = const Duration(seconds: 2);
  client.dio.options.receiveTimeout = const Duration(seconds: 2);
  return client;
}

// ------------------------------------------------------- native FLV token

/// Long-lived FLV credential from native WUP (Pure Live
/// `HuyaCdnTokenLease`).
///
/// [invalidAt] is the hard expiry (wsTime + 5 min, capped by the
/// server's `iExpireTime` when earlier); [refreshAt] is 30 s before it —
/// the official player refreshes the WUP token before expiry and never
/// extends `wsTime` locally.
class HuyaCdnTokenLease {
  const HuyaCdnTokenLease({
    required this.antiCode,
    required this.invalidAt,
    required this.refreshAt,
    required this.serverExpireValue,
  });

  factory HuyaCdnTokenLease.fromResponse(
    GetCdnTokenExResp response, {
    DateTime? now,
  }) {
    final antiCode = response.sFlvToken.trim();
    if (antiCode.isEmpty) {
      throw const FormatException('Huya WUP returned an empty FLV token');
    }
    final query = Uri(query: antiCode).queryParameters;
    final wsTime = int.tryParse(query['wsTime'] ?? '', radix: 16);
    if (wsTime == null) {
      throw const FormatException('Huya WUP token has no valid wsTime');
    }

    // wsTime receives a five-minute validity allowance; refresh is
    // requested thirty seconds earlier.
    var invalidAt = DateTime.fromMillisecondsSinceEpoch(wsTime * 1000,
            isUtc: true)
        .add(const Duration(minutes: 5));
    final current = (now ?? DateTime.now()).toUtc();
    final serverExpiry = response.iExpireTime;
    if (serverExpiry > 0) {
      final serverInvalidAt = serverExpiry > 1000000000000
          ? DateTime.fromMillisecondsSinceEpoch(serverExpiry, isUtc: true)
          : serverExpiry > 1000000000
              ? DateTime.fromMillisecondsSinceEpoch(serverExpiry * 1000,
                  isUtc: true)
              : current.add(Duration(seconds: serverExpiry));
      if (serverInvalidAt.isBefore(invalidAt)) invalidAt = serverInvalidAt;
    }
    return HuyaCdnTokenLease(
      antiCode: antiCode,
      invalidAt: invalidAt,
      refreshAt: invalidAt.subtract(const Duration(seconds: 30)),
      serverExpireValue: serverExpiry,
    );
  }

  final String antiCode;
  final DateTime invalidAt;
  final DateTime refreshAt;
  final int serverExpireValue;

  bool needsRefresh(DateTime timestamp) =>
      !timestamp.toUtc().isBefore(refreshAt);

  bool isExpired(DateTime timestamp) => !timestamp.toUtc().isBefore(invalidAt);
}

/// Native token request (Pure Live `buildNativePlaybackTokenRequest`):
/// stream name + a random SDK UA. No viewer uid/guid — the native
/// contract identifies by SDK UA, not by the anonymous web identity.
GetCdnTokenExReq buildNativePlaybackTokenRequest(HuyaLineModel line) =>
    GetCdnTokenExReq()
      ..sStreamName = line.streamName
      ..tId = (HuyaUserId()..sHuYaUA = HuyaRequestParams.requestHuyaUA);

/// Fetches the native FLV token for one line via WUP `getCdnTokenInfoEx`
/// (servant `liveui`). Throws on transport error, non-zero TUP code, an
/// empty token, or a token without a valid wsTime. Callers fall back to
/// the web-template anti-code.
Future<HuyaCdnTokenLease> fetchNativeHuyaCdnToken(
  HuyaLineModel line, {
  HuyaWupClientFactory? clientFactory,
}) async {
  final client = (clientFactory ?? () => _createCdnTokenClient(<String, String>{
        'Origin': HuyaRequestParams.baseUrl,
        'Referer': '${HuyaRequestParams.baseUrl}/',
        'User-Agent': _nativePlayUserAgent,
      }))();
  try {
    final response = await client
        .tupRequest('getCdnTokenInfoEx', buildNativePlaybackTokenRequest(line),
            GetCdnTokenExResp())
        .timeout(const Duration(seconds: 8));
    return HuyaCdnTokenLease.fromResponse(response);
  } finally {
    client.dio.close(force: true);
  }
}

/// Web-identity token request (Pure Live `buildPlaybackTokenRequest`):
/// the fallback when the room's own FLV template cannot be signed. Uses
/// the anonymous viewer identity + webh5 UA, NOT the native SDK identity.
GetCdnTokenExReq buildPlaybackTokenRequest(
  HuyaLineModel line,
  HuyaViewerIdentity viewer, {
  String cookie = '',
}) {
  return GetCdnTokenExReq()
    ..sFlvUrl = secureHuyaCdnBase(line.line)
    ..sStreamName = line.streamName
    ..iLoopTime = _webPlaybackTokenLoopTime
    ..tId = buildPlaybackTokenUserId(viewer, cookie: cookie)
    ..iAppId = _webPlaybackAppId;
}

/// Huya's web bundle passes TafLink.getUserId() to getCdnTokenInfoEx:
/// webh5 + the page cookie, rather than the desktop HYSDK/pc_exe
/// identity used by unrelated legacy WUP calls.
HuyaUserId buildPlaybackTokenUserId(
  HuyaViewerIdentity viewer, {
  String cookie = '',
}) {
  return HuyaUserId()
    ..lUid = viewer.uid
    ..sGuid = viewer.guid
    ..sToken = ''
    ..sHuYaUA = _webPlaybackTarsUserAgent
    ..sCookie = cookie
    ..iTokenType = 0;
}

/// Fetches the web-identity FLV token for one line (same WUP method,
/// different request identity). Same throw/fallback contract as
/// [fetchNativeHuyaCdnToken].
Future<HuyaCdnTokenLease> fetchWebHuyaCdnToken(
  HuyaLineModel line,
  HuyaViewerIdentity viewer, {
  String cookie = '',
  HuyaWupClientFactory? clientFactory,
}) async {
  final client = (clientFactory ?? () => _createCdnTokenClient(<String, String>{
        'Origin': HuyaRequestParams.baseUrl,
        'Referer': '${HuyaRequestParams.baseUrl}/',
        'User-Agent': HuyaRequestParams.kUserAgent,
        if (cookie.isNotEmpty) 'Cookie': cookie,
      }))();
  try {
    final response = await client
        .tupRequest('getCdnTokenInfoEx',
            buildPlaybackTokenRequest(line, viewer, cookie: cookie),
            GetCdnTokenExResp())
        .timeout(const Duration(seconds: 8));
    return HuyaCdnTokenLease.fromResponse(response);
  } finally {
    client.dio.close(force: true);
  }
}

// ------------------------------------------------------------ super chat

/// Fetches the super-chat message board for one room (Pure Live
/// `getHuyaSuperChatMessageList`, `POST https://wup.huya.com`,
/// `getHeadLineMessageBoard`).
///
/// Both initial room load and WS reconciliation request full snapshots
/// with [first]; the latter deduplicates by event id in its session.
/// With [first], only the newest 10 are kept so one fetch never floods
/// the danmaku area; otherwise only the newest item is returned (the
/// compatibility single-item path chooses the newest start time, not
/// price). Each call owns its client and always closes it.
Future<List<LiveSuperChatMessage>> getHuyaSuperChatMessageList({
  required int lPid,
  bool first = false,
  HuyaWupClientFactory? clientFactory,
}) async {
  final messageBoardClient =
      (clientFactory ?? _createMessageBoardClient)();
  final userId = HuyaUserId()..sHuYaUA = HuyaRequestParams.hysdkUa;
  final req = GetGameEventMessageBoardReq()
    ..lPid = lPid
    ..tId = userId
    ..iMessageBoardScope = 0
    ..iPageSize = 50;
  final GetGameEventMessageBoardRsp rsp;
  try {
    rsp = await messageBoardClient
        .tupRequest(
            'getHeadLineMessageBoard', req, GetGameEventMessageBoardRsp())
        .timeout(const Duration(seconds: 3));
  } finally {
    // Future.timeout only stops waiting. Closing the actual transport
    // here prevents outstanding HTTP requests from accumulating on
    // repeated super-chat fetches.
    messageBoardClient.dio.close(force: true);
  }
  final messages = huyaSuperChatsFromPanel(rsp.tMessageBoardPanel);
  // Newest first (by startTime, descending); upstream notes Huya sorts
  // by money -> level -> countDown, normalised to time order here.
  messages.sort((a, b) => b.startTime.compareTo(a.startTime));
  if (first) {
    // First load keeps only the newest 10.
    return messages.length > 10 ? messages.sublist(0, 10) : messages;
  }
  return messages.isEmpty ? messages : <LiveSuperChatMessage>[messages.first];
}

/// Maps a message-board panel to super-chat messages (Pure Live
/// `huyaSuperChatsFromPanel`).
///
/// Skips empty content and entries whose display window already ended
/// (`remainSec <= 0`). Price falls back to `iCostPay / 100` (rounded,
/// min 1) when `iCost` is 0.
List<LiveSuperChatMessage> huyaSuperChatsFromPanel(
  GameEventMessageBoardPanel panel, {
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final messages = <LiveSuperChatMessage>[];
  for (final item in panel.vGameEventMessageBoardInfo) {
    final content = item.sContent.trim();
    if (content.isEmpty) {
      continue;
    }
    // start_time --- cur ---> end_time
    final remainSec =
        item.iCountDown > 0 ? item.iCountDown : item.iTotalSec;
    if (remainSec <= 0) {
      continue;
    }

    final totalSeconds = item.iTotalSec > 0 ? item.iTotalSec : remainSec;

    var price = item.iCost;
    if (price <= 0 && item.iCostPay > 0) {
      price = max(1, (item.iCostPay / 100).round());
    }

    final endTime = at.add(Duration(seconds: remainSec));
    final startTime = endTime.subtract(Duration(seconds: totalSeconds));

    messages.add(
      LiveSuperChatMessage(
        messageId: item.lMessageId > 0 ? 'huya:${item.lMessageId}' : '',
        backgroundBottomColor: '#246488',
        backgroundColor: '#ffffff',
        endTime: endTime,
        face: item.tMessageUser.sAvatar,
        message: content,
        price: price,
        startTime: startTime,
        userName: item.tMessageUser.sNick.trim(),
      ),
    );
  }
  return messages;
}
