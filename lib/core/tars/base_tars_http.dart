// TARS-over-HTTP (WUP) client — port of Pure Live 3.x
// lib/core/tars/base_tars_http.dart.
//
// POSTs a TUP3 packet to https://wup.huya.com with
// `Content-Type: application/x-wup` and decodes the TUP3 response.
// Upstream logs via `package:logger` (not a dependency here); logging is
// dropped — failures surface as exceptions to the caller instead.
//
// Dio posts the raw bytes directly (upstream streams them one byte at a
// time; same wire bytes).

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'tup/const.dart';
import 'tup/tars_uni_packet.dart';
import 'tup/tup_response.dart';
import 'tup/tup_result_exception.dart';

class BaseTarsHttp {
  BaseTarsHttp(
    this.baseUrl,
    this.servantName, {
    this.path = '',
    this.timeOut = 60000,
    this.headers = const <String, String>{},
  }) {
    dio = Dio(
      BaseOptions(
        connectTimeout: Duration(seconds: timeOut),
        baseUrl: baseUrl,
        responseType: ResponseType.bytes,
        headers: <String, String>{
          HttpHeaders.contentTypeHeader: 'application/x-wup',
          ...headers,
        },
      ),
    );
  }

  final String baseUrl;
  final String path;
  final String servantName;
  final Map<String, String> headers;

  /// Timeout in seconds (connect timeout; callers also set send/receive
  /// timeouts on [dio] and wrap calls in `.timeout(...)`).
  int timeOut;

  late final Dio dio;

  Future<RSP> tupRequest<REQ, RSP>(
    String methodName,
    REQ tReq,
    RSP tRsp,
  ) async {
    final response =
        await tupRequestWithRspCode<REQ, RSP>(methodName, tReq, tRsp);
    if (response.code == 0) {
      return response.response!;
    } else {
      throw TupResultException(response.code);
    }
  }

  Future<TupResponse<RSP>> tupRequestWithRspCode<REQ, RSP>(
    String methodName,
    REQ tReq,
    RSP tRsp,
  ) async {
    final data = buildRequest(methodName, tReq);
    dio.options.headers[HttpHeaders.contentLengthHeader] =
        data.lengthInBytes;
    final result = await dio.post<List<int>>(path, data: data);
    final value = result.data;
    return tupResponseDecode(methodName, value!, tRsp);
  }

  Future<TupResponse<void>> tupRequestWithRspCodeNoRsp<REQ>(
    String methodName,
    REQ tReq,
  ) async {
    final data = buildRequest(methodName, tReq);
    dio.options.headers[HttpHeaders.contentLengthHeader] =
        data.lengthInBytes;
    final result = await dio.post<List<int>>(path, data: data);
    final value = result.data;
    return tupEmptyResponseDecode(methodName, value!);
  }

  Future<void> tupRequestNoRsp<REQ>(String methodName, REQ tReq) async {
    final response =
        await tupRequestWithRspCodeNoRsp<REQ>(methodName, tReq);
    if (response.code == 0) {
      return;
    } else {
      throw TupResultException(response.code);
    }
  }

  Uint8List buildRequest<REQ>(String methodName, REQ tReq) {
    final encodePack = TarsUniPacket();
    encodePack.requestId = 0;
    encodePack.setTarsVersion(TupConst.packetTypeTup3);
    encodePack.setTarsPacketType(TupConst.packetTypeTarsNormal);
    encodePack.servantName = servantName;
    encodePack.funcName = methodName;
    encodePack.put('tReq', tReq);
    final bytes = encodePack.encode();
    return bytes;
  }

  TupResponse<RSP> tupResponseDecode<RSP>(
    String methodName,
    List<int> list,
    RSP tRsp,
  ) {
    final bytes = Uint8List.fromList(list);
    final respPack = TarsUniPacket();
    respPack.decode(bytes);
    final code = respPack.get('', 0);
    final rsp = respPack.get<RSP>('tRsp', tRsp);
    return TupResponse<RSP>(code: code, response: rsp);
  }

  TupResponse<void> tupEmptyResponseDecode(
    String methodName,
    List<int> list,
  ) {
    final bytes = Uint8List.fromList(list);
    final respPack = TarsUniPacket();
    respPack.decode(bytes);
    final code = respPack.get('', 0);
    return TupResponse<void>(code: code);
  }
}
