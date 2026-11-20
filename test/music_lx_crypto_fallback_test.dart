// stellarwave / stellarwave014 / huibi wyEapi crypto fallback guards
// (P1-T3 — same pattern as music_jiexiang_crypto_test.dart).
//
// The three scripts call utils.crypto.md5 / utils.crypto.aesEncrypt
// in wyEapi, but the app's lx prelude ships utils with ONLY buffer
// (kLxPrelude in lx_script_engine.dart) — no crypto. Without the
// script-local fallback (pure-JS __haoMd5 + __haoAesEcb, copied
// verbatim from jiexiang.js) wyEapi throws
// `TypeError: cannot read property 'md5' of undefined`.
//
// Verification of the crypto itself is by Node, not by flutter test
// (the Linux test host has no JS runtime): node --check on each file
// plus a harness that loads each script with an app-faithful mock
// prelude (buffer only, no crypto) and checks md5 x4, AES-128-ECB x4
// and wyEapi params end to end against Node crypto (33/33 pass,
// 2026-11-21). This file only guards the fix against regressions in
// the script text (e.g. someone re-introducing the bare
// utils.crypto call).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LX crypto fallback (P1-T3)', () {
    for (final name in ['stellarwave', 'stellarwave014', 'huibi']) {
      test('$name.js has the local crypto fallback', () {
        final code =
            File('assets/lx_scripts/$name.js').readAsStringSync();
        // Local implementations exist…
        expect(code, contains('const __haoMd5 = '));
        expect(code, contains('const __haoAesEcb = '));
        // …and the call sites prefer host crypto but fall back to them.
        expect(
          code,
          contains(
            'const md5 = (str) => (utils && utils.crypto ? utils.crypto.md5(str) : __haoMd5(str))',
          ),
        );
        expect(code, contains('if (utils && utils.crypto)'));
        expect(code, contains('return __haoAesEcb(data, key)'));
        // The bare crashing calls are gone: each utils.crypto call
        // occurs exactly once — on the guarded fallback line
        // (`if (utils && utils.crypto) return …`), never bare.
        expect(
          code,
          isNot(contains('const md5 = (str) => utils.crypto.md5(str)')),
        );
        expect(
          RegExp('utils\\.crypto\\.aesEncrypt\\(').allMatches(code).length,
          1,
        );
        expect(
          RegExp('utils\\.crypto\\.md5\\(').allMatches(code).length,
          1,
        );
      });
    }
  });
}
