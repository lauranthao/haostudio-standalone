// Sites.of() must return the SAME adapter instance per platform.
//
// The adapters cache per-instance state (Bilibili buvid / w_webid /
// sub-area parent map, Douyin anonymous cookie, Huya viewer identity
// + token leases). A fresh instance per call defeated every one of
// those caches: each live-tab page load re-fetched buvid + w_webid,
// each Bilibili category page re-fetched the category list first,
// and each follow-status check paid a fresh identity fetch.

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/shared/platforms/sites.dart';

void main() {
  test('Sites.of returns the same instance for the same platform', () {
    for (final id in Sites.supportedSiteIds) {
      expect(identical(Sites.of(id), Sites.of(id)), isTrue);
    }
  });

  test('Sites.of returns different instances for different platforms', () {
    final bilibili = Sites.of(Sites.bilibiliSite);
    final huya = Sites.of(Sites.huyaSite);
    expect(identical(bilibili, huya), isFalse);
  });

  test('Sites.of still throws for an unsupported platform', () {
    expect(() => Sites.of('not-a-platform'), throwsArgumentError);
  });

  test('Sites.all returns one adapter per supported platform', () {
    final all = Sites.all;
    expect(all.map((s) => s.id).toList(), Sites.supportedSiteIds);
    // Same singletons as of().
    for (var i = 0; i < all.length; i++) {
      expect(identical(all[i], Sites.of(Sites.supportedSiteIds[i])), isTrue);
    }
  });
}
