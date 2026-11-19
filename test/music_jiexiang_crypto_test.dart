// jiexiang.js wyEapi md5 crash (2026-11-19) — regression guard.
//
// Script: assets/lx_scripts/jiexiang.js (杰翔聚合音源 v2.3.0).
// Root cause: the script destructures `utils` from `globalThis.lx`
// and calls `utils.crypto.md5` / `utils.crypto.aesEncrypt`, but the
// app's lx prelude (kLxPrelude in lx_script_engine.dart) ships
// `lx.utils` with ONLY `buffer` — no `crypto`. So `utils.crypto`
// is undefined and wyEapi throws
// `TypeError: cannot read property 'md5' of undefined`, at
// md5 (<eval>) / wyEapi (<eval>:97) / fetch (<eval>:1000) — the
// logcat line numbers match this file exactly (wyEapi's md5 call
// is line 97, the 网易云官方 fetch is line 1000). The same latent
// gap exists in stellarwave / huibi / stellarwave014 (they also
// call utils.crypto.*) — only jiexiang is fixed here, per the
// brief; the siblings are reported, not silently changed.
//
// Fix (script-local only, no engine change): when `utils.crypto`
// is missing, md5 falls back to a pure-JS __haoMd5 and aesEncrypt
// to a pure-JS AES-128-ECB __haoAesEcb (wyEapi's only mode);
// when the host provides utils.crypto (real LX desktop) the
// original path is used unchanged.
//
// Verification is by Node, not by flutter test — the Linux test
// host has no JS runtime (flutter_js is iOS/Android only), so no
// Dart test can execute the script. Evidence (run from the repo):
//   node --check assets/lx_scripts/jiexiang.js   # pass
//   node /tmp/jx/verify.js                        # 11/11 pass:
//     md5 x5 (empty, abc, hello world, the exact wyEapi digest
//     input, Chinese text) vs Node crypto;
//     AES-128-ECB x3 (one-block, multi-block, exact-block) vs Node;
//     wyEapi params end to end vs Node (same ids/level payload as
//     the fetch at line ~1000); md5 for the fishSign path;
//     host-provided utils.crypto is still preferred when present.
// The repro before the fix (same Node harness, app-faithful mock
// prelude) threw the exact logcat TypeError at jiexiang.js:74.
//
// This file only guards the fix against regressions in the script
// text (e.g. someone re-introducing the bare utils.crypto call).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('jiexiang.js has the local crypto fallback', () {
    final code = File('assets/lx_scripts/jiexiang.js').readAsStringSync();
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
    // The bare crashing call is gone.
    expect(code, isNot(contains('const md5 = (str) => utils.crypto.md5(str)')));
  });
}
