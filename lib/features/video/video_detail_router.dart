// Shared CMS / Emby detail routing (1.1.6, browse A3; audit P0 +
// §4.4).
//
// ONE function for the history page, the favourites page, the video
// tab (including the aggregated continue-watching bar) and the
// version sheet. Three copies of the same `source == 'emby'` branch
// used to drift — the history page routed every row to the CMS page,
// so an Emby row opened on the wrong page and died on
// `CmsException('unknown source')` (CMS source ids are ints; the
// Emby source id is the string 'emby').
//
// Rule: `source == EmbyClient.sourceId` → `EmbyDetailPage`,
// otherwise → `VideoDetailPage`. Type/search pages are CMS-only by
// construction (`CmsClient` never yields an Emby item) and keep their
// direct `VideoDetailPage` call — routing them through here would be
// dead code, not a fix.

import 'package:flutter/cupertino.dart';

import '../../services/video/emby_client.dart';
import 'emby_detail_page.dart';
import 'video_detail_page.dart';
import 'video_detail_service.dart';
import 'video_models.dart';

/// Open the detail page for [source]/[vodId], routing by source.
/// [startEpName] opens the page at that episode and auto-plays it
/// from 0 (the 下一集 card); null keeps the normal open. The
/// [detailService]/[embyClient] params are test seams only — null in
/// production.
Future<T?> openVideoDetail<T>(
  BuildContext context, {
  required dynamic source,
  required String vodId,
  VideoItem? preload,
  bool autoResume = false,
  String? startEpName,
  VideoDetailService? detailService,
  EmbyClient? embyClient,
}) {
  if (source.toString() == EmbyClient.sourceId) {
    return Navigator.of(context).push<T>(
      CupertinoPageRoute<T>(
        builder: (_) => EmbyDetailPage(
          itemId: vodId,
          preload: preload,
          autoResume: autoResume,
          startEpName: startEpName,
          client: embyClient,
        ),
      ),
    );
  }
  return Navigator.of(context).push<T>(
    CupertinoPageRoute<T>(
      builder: (_) => VideoDetailPage(
        sourceId: source,
        vodId: vodId,
        preload: preload,
        autoResume: autoResume,
        startEpName: startEpName,
        detailService: detailService,
      ),
    ),
  );
}

/// Open the detail page for a history row (same routing, preload
/// built from the row — including its year, which feeds the alt
/// sweep). [startEpName] is the 下一集 name when the row is opened
/// from the 下一集栏.
Future<T?> openHistoryDetail<T>(
  BuildContext context,
  WatchHistoryEntry entry, {
  bool autoResume = true,
  String? startEpName,
  VideoDetailService? detailService,
  EmbyClient? embyClient,
}) {
  final preload = VideoItem(
    source: entry.source,
    sourceName: '',
    vodId: entry.vodId,
    name: entry.title,
    pic: entry.pic,
    picAlt: entry.picAlt,
    year: entry.year,
  );
  return openVideoDetail<T>(
    context,
    source: entry.source,
    vodId: entry.vodId,
    preload: preload,
    autoResume: autoResume,
    startEpName: startEpName,
    detailService: detailService,
    embyClient: embyClient,
  );
}
