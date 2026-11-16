// Platform registry — Big-5 only (Pure Live sites.dart, §1.3).
//
// `Sites.of(id)` returns the adapter for one of the five platforms.
// The other 29 Pure Live platforms are NOT added (chen's scope rule).

import 'live_site.dart';
import 'bilibili/bilibili_site.dart';
import 'douyin/douyin_site.dart';
import 'douyu/douyu_site.dart';
import 'huya/huya_site.dart';
import 'kuaishou/kuaishou_site.dart';

export 'bilibili/bilibili_site.dart';
export 'douyin/douyin_site.dart';
export 'douyu/douyu_site.dart';
export 'huya/huya_site.dart';
export 'kuaishou/kuaishou_site.dart';

class Sites {
  Sites._();

  static const String bilibiliSite = 'bilibili';
  static const String douyuSite = 'douyu';
  static const String huyaSite = 'huya';
  static const String douyinSite = 'douyin';
  static const String kuaishouSite = 'kuaishou';
  static const String allSite = 'all';

  static const List<String> supportedSiteIds = [
    bilibiliSite,
    douyuSite,
    huyaSite,
    douyinSite,
    kuaishouSite,
  ];

  static bool isSupported(String id) => supportedSiteIds.contains(id);

  static LiveSite of(String id) {
    switch (id) {
      case bilibiliSite:
        return BiliBiliSite();
      case douyuSite:
        return DouyuSite();
      case huyaSite:
        return HuyaSite();
      case douyinSite:
        return DouyinSite();
      case kuaishouSite:
        return KuaishouSite();
      default:
        throw ArgumentError('Unsupported live platform: $id');
    }
  }

  /// Display order on the live tab.
  static List<LiveSite> get all => supportedSiteIds.map(of).toList();
}
