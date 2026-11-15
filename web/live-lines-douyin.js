// ---- Douyin live lines (Pure Live port) ----
// Port of Pure Live (packages/live_core/lib/src/sites/douyin/):
//   DouyinSigner (douyin_sign.dart, a_bogus / X-Bogus) + room/web/enter/
//   play path + real search (/aweme/v1/web/live/search/,
//   /aweme/v1/web/general/search/stream/) + partition fallback
//   (douyin_site.dart, douyin_api.dart).
//
// LOAD ORDER: this file loads AFTER app.js and overrides by re-declaring
// the same function names (later function declarations win):
//   directDyRoomPlay, directDyRoomPlayById (overrides)
//   directDySearchLive (new)
// Everything else in this file is prefixed DOUYIN_LL_ and only uses
// function declarations / consts with that prefix, so it cannot clash
// with app.js names. It reuses app.js helpers: nativeJson, nativeText,
// nativeFetch, directDyPrime, directDyPickRoomId, directDyHlsMapGet,
// directDyQualitiesFromMap, directDyUrlFresh, directDyPartitionRoomsByCat,
// directLiveNum, directLiveToHttps, DIRECT_LIVE_UA and the __dy* caches.
//
// INTEGRATION (coordinator):
//   1. index.html: <script src="./live-lines-douyin.js"></script> AFTER app.js.
//   2. directLiveSearch douyin branch: call directDySearchLive(q) instead
//      of the feed substring filter.
//   3. ViewController.swift nativeFetch allowlist: add "www.douyin.com"
//      (live.douyin.com + webcast.amemv.com are already there).
//   4. No server fallback change needed: on any failure these functions
//      return null / [] and the caller falls back as before.
//
// SIGNING NOTES (from douyin_sign.dart):
//   a_bogus = SM3(SM3(query+'cus'))[21,22] + SM3(SM3(body+'cus'))[21,22]
//   + SM3(base64(RC4([0,1,14], UA)))[23,24] + timestamps + options
//   [0,1,14] + aid 6383 + browser fingerprint, laid out in _order,
//   XOR check byte in _checkOrder, stream-ciphered with the 256-byte
//   table, custom base64 (alphabet0). Verified against the vectors in
//   packages/live_core/test/sites/douyin_site_test.dart (SM3 examples,
//   4 a_bogus vectors, 2 signedUrl vectors, X-Bogus vectors) — see the
//   node test in the handoff; all pass offline. Whether the LIVE server
//   accepts the signature is a separate question (smoke test below).

// Douyin web app id / UA (the UA a_bogus encodes; must match the UA the
// requests are sent with — same string as app.js DIRECT_LIVE_UA).
const DOUYIN_LL_AID = 6383;
const DOUYIN_LL_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
const DOUYIN_LL_SALT = 'cus';
const DOUYIN_LL_OPTIONS = [0, 1, 14];
const DOUYIN_LL_PAGE_ID = 0;
const DOUYIN_LL_UA_KEY = [0, 1, 14];
const DOUYIN_LL_MSTOKEN_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789=';
const DOUYIN_LL_ALPHABET0 = 'Dkdpgh2ZmsQB80/MfvV36XI1R45-WUAlEixNLwoqYTOPuzKFjJnry79HbGcaStCe';
const DOUYIN_LL_ALPHABET1 = 'ckdp1h4ZKsUB80/Mfvw36XIgR25+WQAlEi7NLboqYTOPuzmFjJnryx9HVGDaStCe';
const DOUYIN_LL_XBOGUS_ALPHABET = 'Dkdpgh4ZKsQB80/Mfvw36XI1R25+WUAlEi7NLboqYTOPuzmFjJnryx9HVGcaStCe';
const DOUYIN_LL_ORDER = [
  18, 20, 52, 26, 30, 34, 58, 38, 40, 53, 42, 21, 27, 54, 55, 31, 35, 57, 39, 41, 43, 22, 28, 32, 60, 36, 23,
  29, 33, 37, 44, 45, 59, 46, 47, 48, 49, 50, 24, 25, 65, 66, 70, 71
];
const DOUYIN_LL_CHECK_ORDER = [
  18, 20, 26, 30, 34, 38, 40, 42, 21, 27, 31, 35, 39, 41, 43, 22, 28, 32, 36, 23, 29, 33, 37, 44, 45, 46, 47,
  48, 49, 50, 24, 25, 52, 53, 54, 55, 57, 58, 59, 60, 65, 66, 70, 71
];
const DOUYIN_LL_TABLE = [
  121, 243, 55, 234, 103, 36, 47, 228, 30, 231, 106, 6, 115, 95, 78, 101, 250, 207, 198, 50, 139, 227, 220, 105,
  97, 143, 34, 28, 194, 215, 18, 100, 159, 160, 43, 8, 169, 217, 180, 120, 247, 45, 90, 11, 27, 197, 46, 3,
  84, 72, 5, 68, 62, 56, 221, 75, 144, 79, 73, 161, 178, 81, 64, 187, 134, 117, 186, 118, 16, 241, 130, 71,
  89, 147, 122, 129, 65, 40, 88, 150, 110, 219, 199, 255, 181, 254, 48, 4, 195, 248, 208, 32, 116, 167, 69, 201,
  17, 124, 125, 104, 96, 83, 80, 127, 236, 108, 154, 126, 204, 15, 20, 135, 112, 158, 13, 1, 188, 164, 210, 237,
  222, 98, 212, 77, 253, 42, 170, 202, 26, 22, 29, 182, 251, 10, 173, 152, 58, 138, 54, 141, 185, 33, 157, 31,
  252, 132, 233, 235, 102, 196, 191, 223, 240, 148, 39, 123, 92, 82, 128, 109, 57, 24, 38, 113, 209, 245, 2, 119,
  153, 229, 189, 214, 230, 174, 232, 63, 52, 205, 86, 140, 66, 175, 111, 171, 246, 133, 238, 193, 99, 60, 74, 91,
  225, 51, 76, 37, 145, 211, 166, 151, 213, 206, 0, 200, 244, 176, 218, 44, 184, 172, 49, 216, 93, 168, 53, 21,
  183, 41, 67, 85, 224, 155, 226, 242, 87, 177, 146, 70, 190, 12, 162, 19, 137, 114, 25, 165, 163, 192, 23, 59,
  9, 94, 179, 107, 35, 7, 142, 131, 239, 203, 149, 136, 61, 249, 14, 156
];
const DOUYIN_LL_SM3_IV = [0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600, 0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e];
const DOUYIN_LL_Q_NAME = { ORIGION: '原画', ORIGIN: '原画', FULL_HD1: '蓝光', UHD: '蓝光', HD1: '超清', HD: '超清', SD2: '高清', SD: '高清', SD1: '标清', LD: '标清', MD: '流畅' };
const DOUYIN_LL_Q_TIER = { ORIGION: 6000000, ORIGIN: 6000000, FULL_HD1: 5000000, UHD: 5000000, HD1: 4000000, HD: 4000000, SD2: 3000000, SD: 3000000, SD1: 2000000, LD: 2000000, MD: 1000000 };

// ---- byte helpers ----
function DOUYIN_LL_randInt(n){ return Math.floor(Math.random() * n); }
function DOUYIN_LL_utf8(str){
  try { return Array.from(new TextEncoder().encode(String(str))); } catch (e) {
    var s = unescape(encodeURIComponent(String(str))), out = [];
    for (var i = 0; i < s.length; i++) out.push(s.charCodeAt(i) & 0xff);
    return out;
  }
}
function DOUYIN_LL_utf8Decode(bytes){
  try { return new TextDecoder('utf-8', { fatal: false }).decode(new Uint8Array(bytes)); } catch (e) {
    var s = ''; for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]); return s;
  }
}
function DOUYIN_LL_enc(s){
  return encodeURIComponent(String(s)).replace(/[!'()*]/g, function(c){ return '%' + c.charCodeAt(0).toString(16).toUpperCase(); });
}

// ---- SM3 (GB/T 32905-2016), 32-byte digest. Port of DouyinSigner._sm3. ----
function DOUYIN_LL_sm3(input){
  var bytes = input;
  function rotl(x, n){ n = n % 32; if (n === 0) return x >>> 0; return ((x << n) | (x >>> (32 - n))) >>> 0; }
  function p0(x){ return (x ^ rotl(x, 9) ^ rotl(x, 17)) >>> 0; }
  function p1(x){ return (x ^ rotl(x, 15) ^ rotl(x, 23)) >>> 0; }
  var msg = bytes.slice();
  var bitLen = bytes.length * 8;
  msg.push(0x80);
  while (msg.length % 64 !== 56) msg.push(0);
  var hi = Math.floor(bitLen / 4294967296), lo = bitLen >>> 0;
  msg.push((hi >>> 24) & 255, (hi >>> 16) & 255, (hi >>> 8) & 255, hi & 255, (lo >>> 24) & 255, (lo >>> 16) & 255, (lo >>> 8) & 255, lo & 255);
  var v = DOUYIN_LL_SM3_IV.slice();
  var w = new Array(68), w1 = new Array(64);
  for (var off = 0; off < msg.length; off += 64) {
    for (var j = 0; j < 16; j++) w[j] = ((msg[off + 4 * j] << 24) | (msg[off + 4 * j + 1] << 16) | (msg[off + 4 * j + 2] << 8) | msg[off + 4 * j + 3]) >>> 0;
    for (j = 16; j < 68; j++) w[j] = (p1((w[j - 16] ^ w[j - 9] ^ rotl(w[j - 3], 15)) >>> 0) ^ rotl(w[j - 13], 7) ^ w[j - 6]) >>> 0;
    for (j = 0; j < 64; j++) w1[j] = (w[j] ^ w[j + 4]) >>> 0;
    var a = v[0], b = v[1], c = v[2], d = v[3], e = v[4], f = v[5], g = v[6], h = v[7];
    for (j = 0; j < 64; j++) {
      var t = j < 16 ? 0x79cc4519 : 0x7a879d8a;
      var ss1 = rotl(((rotl(a, 12) + e + rotl(t, j)) >>> 0), 7);
      var ss2 = (ss1 ^ rotl(a, 12)) >>> 0;
      var ff = j < 16 ? (a ^ b ^ c) >>> 0 : ((a & b) | (a & c) | (b & c)) >>> 0;
      var gg = j < 16 ? (e ^ f ^ g) >>> 0 : ((e & f) | ((~e) & g)) >>> 0;
      var tt1 = (ff + d + ss2 + w1[j]) >>> 0;
      var tt2 = (gg + h + ss1 + w[j]) >>> 0;
      d = c; c = rotl(b, 9); b = a; a = tt1; h = g; g = rotl(f, 19); f = e; e = p0(tt2);
    }
    v[0] = (v[0] ^ a) >>> 0; v[1] = (v[1] ^ b) >>> 0; v[2] = (v[2] ^ c) >>> 0; v[3] = (v[3] ^ d) >>> 0;
    v[4] = (v[4] ^ e) >>> 0; v[5] = (v[5] ^ f) >>> 0; v[6] = (v[6] ^ g) >>> 0; v[7] = (v[7] ^ h) >>> 0;
  }
  var out = [];
  for (var i = 0; i < 8; i++) out.push((v[i] >>> 24) & 255, (v[i] >>> 16) & 255, (v[i] >>> 8) & 255, v[i] & 255);
  return out;
}

// ---- MD5 over raw bytes (for X-Bogus; directMd5 in app.js only takes a string). ----
function DOUYIN_LL_md5(input){
  var bytes = input.slice();
  var bitLen = bytes.length * 8;
  bytes.push(0x80);
  while (bytes.length % 64 !== 56) bytes.push(0);
  for (var i = 0; i < 8; i++) bytes.push((Math.floor(bitLen / Math.pow(2, i * 8))) & 0xff);
  var K = []; for (var k = 0; k < 64; k++) K.push(Math.floor(Math.abs(Math.sin(k + 1)) * 4294967296) >>> 0);
  var S = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
  function rotl(x, c){ return ((x << c) | (x >>> (32 - c))) >>> 0; }
  var a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
  for (var off = 0; off < bytes.length; off += 64) {
    var M = []; for (var j = 0; j < 16; j++) M.push((bytes[off + j * 4] | (bytes[off + j * 4 + 1] << 8) | (bytes[off + j * 4 + 2] << 16) | (bytes[off + j * 4 + 3] << 24)) >>> 0);
    var A = a0, B = b0, C = c0, D = d0;
    for (var ii = 0; ii < 64; ii++) {
      var F, g;
      if (ii < 16) { F = ((B & C) | (~B & D)) >>> 0; g = ii; }
      else if (ii < 32) { F = ((D & B) | (~D & C)) >>> 0; g = (5 * ii + 1) % 16; }
      else if (ii < 48) { F = (B ^ C ^ D) >>> 0; g = (3 * ii + 5) % 16; }
      else { F = (C ^ (B | ~D)) >>> 0; g = (7 * ii) % 16; }
      F = (F + A + K[ii] + M[g]) >>> 0;
      A = D; D = C; C = B;
      B = (B + rotl(F, S[ii])) >>> 0;
    }
    a0 = (a0 + A) >>> 0; b0 = (b0 + B) >>> 0; c0 = (c0 + C) >>> 0; d0 = (d0 + D) >>> 0;
  }
  var out = [];
  [a0, b0, c0, d0].forEach(function(n){ for (var i = 0; i < 4; i++) out.push((n >>> (i * 8)) & 0xff); });
  return out;
}
function DOUYIN_LL_md5Hex(input){ return DOUYIN_LL_md5(input).map(function(b){ return ('0' + b.toString(16)).slice(-2); }).join(''); }

// ---- RC4. Port of DouyinSigner._rc4. ----
function DOUYIN_LL_rc4(key, data){
  var s = []; for (var i = 0; i < 256; i++) s.push(i);
  var j = 0;
  for (i = 0; i < 256; i++) { j = (j + s[i] + key[i % key.length]) % 256; var tmp = s[i]; s[i] = s[j]; s[j] = tmp; }
  i = 0; j = 0;
  var out = [];
  for (var n = 0; n < data.length; n++) {
    i = (i + 1) % 256; j = (j + s[i]) % 256;
    var t2 = s[i]; s[i] = s[j]; s[j] = t2;
    out.push((data[n] ^ s[(s[i] + s[j]) % 256]) & 0xff);
  }
  return out;
}

// ---- Custom base64. Port of DouyinSigner._encode / _base64. ----
function DOUYIN_LL_encode(bytes){
  var out = '', count = 0;
  for (var i = 0; i < bytes.length; i += 3) {
    var remaining = bytes.length - i;
    var n = (bytes[i] << 16) | (remaining > 1 ? bytes[i + 1] << 8 : 0) | (remaining > 2 ? bytes[i + 2] : 0);
    var chars = remaining > 2 ? 4 : remaining + 1;
    for (var j = 0; j < chars; j++) { out += DOUYIN_LL_ALPHABET0[(n >>> (18 - 6 * j)) & 0x3f]; count++; }
  }
  var pad = (4 - count % 4) % 4;
  for (var k = 0; k < pad; k++) out += '=';
  return out;
}
function DOUYIN_LL_base64(bytes, alphabet){
  var out = '';
  for (var i = 0; i < bytes.length; i += 3) {
    var remaining = bytes.length - i;
    var n = (bytes[i] << 16) | (remaining > 1 ? bytes[i + 1] << 8 : 0) | (remaining > 2 ? bytes[i + 2] : 0);
    var chars = remaining > 2 ? 4 : remaining + 1;
    for (var j = 0; j < chars; j++) out += alphabet[(n >>> (18 - 6 * j)) & 0x3f];
    if (remaining < 3) for (var k = 0; k < 3 - remaining; k++) out += '=';
  }
  return out;
}

// ---- Stream cipher. Port of DouyinSigner._transform (table copied per call). ----
function DOUYIN_LL_transform(bytes){
  var table = DOUYIN_LL_TABLE.slice();
  var length = table.length;
  var output = [];
  var indexB = table[1];
  var initial = 0, valueE = 0;
  for (var index = 0; index < bytes.length; index++) {
    var sum;
    if (index === 0) { initial = table[indexB]; sum = indexB + initial; table[1] = initial; table[indexB] = indexB; }
    else sum = initial + valueE;
    output.push(bytes[index] ^ table[sum % length]);
    var next = (index + 2) % length;
    valueE = table[next];
    sum = (indexB + valueE) % length;
    initial = table[sum];
    table[sum] = table[next];
    table[next] = initial;
    indexB = sum;
  }
  return output;
}
function DOUYIN_LL_randomPrefix(randInt){
  var out = [];
  for (var group = 0; group < 3; group++) {
    var value = randInt(10000);
    out.push((value & 255 & 170) | 1, (value & 255 & 85) | 2, ((value >> 8) & 170) | 5, ((value >> 8) & 85) | 40);
  }
  return out;
}
function DOUYIN_LL_randomFingerprint(randInt){
  function between(low, high){ return low + randInt(high - low + 1); }
  var innerW = between(1024, 1920), innerH = between(768, 1080);
  var outerW = innerW + between(24, 32), outerH = innerH + between(75, 90);
  var screenY = [0, 30][randInt(2)];
  var sizeW = between(1024, 1920), sizeH = between(768, 1080);
  var availW = between(1280, 1920), availH = between(800, 1080);
  return innerW + '|' + innerH + '|' + outerW + '|' + outerH + '|0|' + screenY + '|0|0|' + sizeW + '|' + sizeH + '|' + availW + '|' + availH + '|' + innerW + '|' + innerH + '|24|24|Win32';
}

// ---- Signer. Port of DouyinSigner (factory: injectable UA / fingerprint /
// clock / random, so the Pure Live test vectors can be replayed). ----
function DOUYIN_LL_createSigner(cfg){
  cfg = cfg || {};
  var userAgent = cfg.userAgent || DOUYIN_LL_UA;
  var randInt = cfg.randInt || DOUYIN_LL_randInt;
  var nowMs = cfg.nowMs || function(){ return Date.now(); };
  var fingerprint = cfg.fingerprint || DOUYIN_LL_randomFingerprint(randInt);
  function msToken(length){
    length = (length === undefined) ? 184 : length;
    var s = '';
    for (var i = 0; i < length; i++) s += DOUYIN_LL_MSTOKEN_ALPHABET[randInt(DOUYIN_LL_MSTOKEN_ALPHABET.length)];
    return s;
  }
  function aBogus(query, body){
    body = body || '';
    var start = nowMs();
    var paramsHash = DOUYIN_LL_sm3(DOUYIN_LL_sm3(DOUYIN_LL_utf8(query + DOUYIN_LL_SALT)));
    var bodyHash = DOUYIN_LL_sm3(DOUYIN_LL_sm3(DOUYIN_LL_utf8(body + DOUYIN_LL_SALT)));
    var uaHash = DOUYIN_LL_sm3(DOUYIN_LL_utf8(DOUYIN_LL_base64(DOUYIN_LL_rc4(DOUYIN_LL_UA_KEY, DOUYIN_LL_utf8(userAgent)), DOUYIN_LL_ALPHABET1)));
    var end = nowMs();
    var fields = {};
    fields[8] = 3; fields[18] = 44; fields[66] = 0; fields[69] = 0; fields[70] = 0; fields[71] = 0;
    fields[20] = (start >>> 24) & 255; fields[21] = (start >>> 16) & 255; fields[22] = (start >>> 8) & 255; fields[23] = start & 255;
    fields[24] = 0; fields[25] = 0;
    fields[26] = (DOUYIN_LL_OPTIONS[0] >>> 24) & 255; fields[27] = (DOUYIN_LL_OPTIONS[0] >>> 16) & 255;
    fields[28] = (DOUYIN_LL_OPTIONS[0] >>> 8) & 255; fields[29] = DOUYIN_LL_OPTIONS[0] & 255;
    fields[30] = Math.floor(DOUYIN_LL_OPTIONS[1] / 256) & 255; fields[31] = DOUYIN_LL_OPTIONS[1] % 256;
    fields[32] = (DOUYIN_LL_OPTIONS[1] >>> 24) & 255; fields[33] = (DOUYIN_LL_OPTIONS[1] >>> 16) & 255;
    fields[34] = (DOUYIN_LL_OPTIONS[2] >>> 24) & 255; fields[35] = (DOUYIN_LL_OPTIONS[2] >>> 16) & 255;
    fields[36] = (DOUYIN_LL_OPTIONS[2] >>> 8) & 255; fields[37] = DOUYIN_LL_OPTIONS[2] & 255;
    fields[38] = paramsHash[21]; fields[39] = paramsHash[22];
    fields[40] = bodyHash[21]; fields[41] = bodyHash[22];
    fields[42] = uaHash[23]; fields[43] = uaHash[24];
    fields[44] = (end >>> 24) & 255; fields[45] = (end >>> 16) & 255; fields[46] = (end >>> 8) & 255; fields[47] = end & 255;
    fields[48] = 3; fields[49] = 0; fields[50] = 0;
    fields[51] = (DOUYIN_LL_PAGE_ID >>> 24) & 255; fields[52] = (DOUYIN_LL_PAGE_ID >>> 16) & 255;
    fields[53] = (DOUYIN_LL_PAGE_ID >>> 8) & 255; fields[54] = DOUYIN_LL_PAGE_ID & 255; fields[55] = DOUYIN_LL_PAGE_ID;
    fields[56] = DOUYIN_LL_AID; fields[57] = DOUYIN_LL_AID & 255;
    fields[58] = (DOUYIN_LL_AID >>> 8) & 255; fields[59] = (DOUYIN_LL_AID >>> 16) & 255; fields[60] = (DOUYIN_LL_AID >>> 24) & 255;
    fields[64] = fingerprint.length; fields[65] = fingerprint.length;
    var values = [];
    for (var i = 0; i < DOUYIN_LL_ORDER.length; i++) values.push(fields[DOUYIN_LL_ORDER[i]] || 0);
    for (var c = 0; c < fingerprint.length; c++) values.push(fingerprint.charCodeAt(c) & 255);
    var check = 0;
    for (var k = 0; k < DOUYIN_LL_CHECK_ORDER.length; k++) check ^= (fields[DOUYIN_LL_CHECK_ORDER[k]] || 0);
    values.push(check);
    return DOUYIN_LL_encode(DOUYIN_LL_randomPrefix(randInt).concat(DOUYIN_LL_transform(values)));
  }
  function signedUrl(base, params){
    var u;
    try { u = new URL(base); } catch (e) { throw new Error('DOUYIN_LL bad base url: ' + base); }
    var all = {}, order = [];
    function put(k, v){ k = String(k); if (!(k in all)) order.push(k); all[k] = String(v); }
    if (u.search) {
      u.search.slice(1).split('&').forEach(function(pair){
        if (!pair) return;
        var eq = pair.indexOf('='), k = eq < 0 ? pair : pair.slice(0, eq), v = eq < 0 ? '' : pair.slice(eq + 1);
        try { k = decodeURIComponent(k.replace(/\+/g, ' ')); } catch (e) {}
        try { v = decodeURIComponent(v.replace(/\+/g, ' ')); } catch (e) {}
        put(k, v);
      });
    }
    Object.keys(params || {}).forEach(function(k){ put(k, params[k]); });
    put('aid', '6383'); put('compress', 'gzip'); put('device_platform', 'web');
    put('browser_language', 'zh-CN'); put('browser_platform', 'Win32');
    put('browser_name', 'Edge'); put('browser_version', '125.0.0.0');
    if (!('msToken' in all)) put('msToken', msToken());
    var query = order.map(function(k){ return DOUYIN_LL_enc(k) + '=' + DOUYIN_LL_enc(all[k]); }).join('&');
    return u.protocol + '//' + u.host + u.pathname + '?' + query + '&a_bogus=' + aBogus(query);
  }
  function xBogus(msStub, counter){
    counter = (counter === undefined) ? 1 : counter;
    if (!/^[0-9a-fA-F]{32}$/.test(msStub)) throw new Error('xBogus: expected 32 hex digits');
    var random1 = randInt(256), random2 = randInt(255);
    var raw = [];
    for (var i = 0; i < 16; i++) raw.push(parseInt(msStub.substr(i * 2, 2), 16));
    var digest = DOUYIN_LL_md5(raw);
    var payload = [counter & 0x3f, 0, 1, 0x0e, 0x45, 0x3f, digest[14], digest[15], random2, 0];
    for (var i = 0; i < 9; i++) payload[9] ^= payload[i];
    var encrypted = DOUYIN_LL_rc4([random2], payload);
    var bytes = [0x40 | (random1 & 0x1f), random2].concat(encrypted);
    return DOUYIN_LL_base64(bytes, DOUYIN_LL_XBOGUS_ALPHABET);
  }
  function danmakuSignature(roomId, userUniqueId){
    var stub = ['live_id=1', 'aid=6383', 'version_code=180800', 'webcast_sdk_version=1.0.15', 'room_id=' + roomId, 'sub_room_id=', 'sub_channel_id=', 'did_rule=3', 'user_unique_id=' + userUniqueId, 'device_platform=web', 'device_type=', 'ac=', 'identity=audience'].join(',');
    return xBogus(DOUYIN_LL_md5Hex(DOUYIN_LL_utf8(stub)));
  }
  function visitorId(){
    var s = '7' + String(3 + randInt(7));
    for (var i = 0; i < 17; i++) s += String(randInt(10));
    return s;
  }
  return { userAgent: userAgent, fingerprint: fingerprint, msToken: msToken, aBogus: aBogus, signedUrl: signedUrl, xBogus: xBogus, danmakuSignature: danmakuSignature, visitorId: visitorId };
}
// One signer per page load (fingerprint fixed for the session, like
// Pure Live's per-process signer; the cipher table is re-copied per call).
const DOUYIN_LL_signer = DOUYIN_LL_createSigner({});

// ---- small JSON helpers (port of DouyinApi._map/_text/_first*). ----
function DOUYIN_LL_asMap(v){
  if (v && typeof v === 'object' && !Array.isArray(v)) return v;
  if (typeof v === 'string' && v.trim().charAt(0) === '{') { try { var d = JSON.parse(v); return (d && typeof d === 'object' && !Array.isArray(d)) ? d : null; } catch (e) { return null; } }
  return null;
}
function DOUYIN_LL_text(v){
  if (v === null || v === undefined || typeof v === 'object') return null;
  var t = String(v).trim();
  return (!t || t === 'null') ? null : t;
}
function DOUYIN_LL_firstText(values){
  for (var i = 0; i < values.length; i++) { var t = DOUYIN_LL_text(values[i]); if (t !== null) return t; }
  return null;
}
function DOUYIN_LL_firstId(values){
  for (var i = 0; i < values.length; i++) {
    var t = DOUYIN_LL_text(values[i]);
    if (t !== null && ['0', 'undefined', 'nan', 'none'].indexOf(t.toLowerCase()) < 0) return t;
  }
  return null;
}
function DOUYIN_LL_jsonInt(v){
  if (typeof v === 'number' && isFinite(v)) return Math.trunc(v);
  if (typeof v === 'string' && /^-?\d+$/.test(v.trim())) { var n = parseInt(v.trim(), 10); return isFinite(n) ? n : null; }
  return null;
}
function DOUYIN_LL_firstImage(cands){
  for (var i = 0; i < cands.length; i++) {
    var v = cands[i], m = DOUYIN_LL_asMap(v);
    if (m && Array.isArray(m.url_list)) { var u = DOUYIN_LL_firstText(m.url_list); if (u) return u; }
    var d = DOUYIN_LL_text(v);
    if (d && (d.indexOf('http://') === 0 || d.indexOf('https://') === 0)) return d;
  }
  return '';
}
function DOUYIN_LL_lookup(map, key){
  if (!map) return undefined;
  if (map[key] !== undefined) return map[key];
  var lk = String(key).toLowerCase(), ks = Object.keys(map);
  for (var i = 0; i < ks.length; i++) if (ks[i].toLowerCase() === lk) return map[ks[i]];
  return undefined;
}
function DOUYIN_LL_streamType(u){
  return /\.m3u8(\?|$)/i.test(String(u || '')) ? 'hls' : 'flv';
}
// Online count: enter/reflow answers carry user_count_str ("3000+") but
// often no numeric user_count (feed rooms do have it).
function DOUYIN_LL_online(room){
  var n = DOUYIN_LL_jsonInt(room.user_count);
  if (n === null) n = DOUYIN_LL_jsonInt(room.online_user_count);
  if (n !== null) return n;
  var s = DOUYIN_LL_text(room.user_count_str);
  if (s) { var m = s.match(/\d+/); if (m) return parseInt(m[0], 10); }
  return 0;
}

// ---- Qualities from stream_url. Port of DouyinApi._variants/qualities/
// resolution: stream_data (data.{sdk_key}.main) + flv_pull_url /
// hls_pull_url_map joined by sdk_key case-insensitively, audio-only keys
// dropped, same-URL keys merged, best first. Unlike the old
// directDyQualitiesFromStreamUrl in app.js this keeps FLV lines too
// (FLV first, then HLS, as the platform lists them) — each quality's
// urls[] is its lines, so the player can switch line without re-fetching.
function DOUYIN_LL_qualitiesFromStreamUrl(su){
  if (!su || typeof su !== 'object') return [];
  var lcd = DOUYIN_LL_asMap(su.live_core_sdk_data) || {};
  var pull = DOUYIN_LL_asMap(lcd.pull_data) || {};
  var options = DOUYIN_LL_asMap(pull.options) || {};
  var streamData = DOUYIN_LL_asMap(DOUYIN_LL_asMap(pull.stream_data) ? DOUYIN_LL_asMap(pull.stream_data).data : null) || {};
  var flvMap = DOUYIN_LL_asMap(su.flv_pull_url) || {};
  var hlsMap = DOUYIN_LL_asMap(su.hls_pull_url_map) || {};
  var names = DOUYIN_LL_asMap(su.resolution_name) || {};
  var defaultQuality = DOUYIN_LL_asMap(options.default_quality) || null;
  var defaultKey = null;
  if (defaultQuality && defaultQuality.sdk_key) defaultKey = String(defaultQuality.sdk_key).toLowerCase();
  else if (su.default_resolution) defaultKey = String(su.default_resolution).toLowerCase();
  var desc = {};
  var qlist = Array.isArray(options.qualities) ? options.qualities : [];
  qlist.forEach(function(o){
    var m = DOUYIN_LL_asMap(o), k = m && DOUYIN_LL_text(m.sdk_key);
    if (m && k) desc[k.toLowerCase()] = m;
  });
  var keySet = {};
  Object.keys(desc).forEach(function(k){ keySet[k] = true; });
  Object.keys(streamData).forEach(function(k){ if (String(k).trim()) keySet[String(k).toLowerCase()] = true; });
  Object.keys(flvMap).forEach(function(k){ if (String(k).trim()) keySet[String(k).toLowerCase()] = true; });
  Object.keys(hlsMap).forEach(function(k){ if (String(k).trim()) keySet[String(k).toLowerCase()] = true; });
  function audioOnly(key, lines){
    var token = key.toLowerCase().replace(/[^a-z0-9]+/g, '');
    if (token === 'ao' || token === 'audio' || token === 'audioonly') return true;
    return lines.every(function(l){
      var q = '';
      try { q = (new URL(l.url).searchParams.get('only_audio') || '').toLowerCase(); } catch (e) {}
      return q === '1' || q === 'true';
    });
  }
  function codecOf(v){
    var t = (DOUYIN_LL_text(v) || '').toLowerCase().replace(/[^a-z0-9]+/g, '');
    if (t === 'h264' || t === '264' || t === 'avc' || t === 'avc1') return 'avc';
    if (t === 'h265' || t === '265' || t === 'hevc' || t === 'hev1' || t === 'hvc1' || t === 'bytevc1') return 'hevc';
    return null;
  }
  var ranked = [];
  Object.keys(keySet).forEach(function(key){
    var entry = DOUYIN_LL_asMap(DOUYIN_LL_lookup(streamData, key));
    var main = entry ? DOUYIN_LL_asMap(entry.main) : null;
    var lines = [];
    function add(value, format){
      var u = DOUYIN_LL_text(value);
      if (!u) return;
      var uri = null;
      try { uri = new URL(u); } catch (e) { return; }
      if ((uri.protocol !== 'http:' && uri.protocol !== 'https:') || !uri.host) return;
      var s = uri.toString();
      for (var i = 0; i < lines.length; i++) if (lines[i].url === s) return;
      lines.push({ url: s, format: format });
    }
    if (main) { add(main.flv, 'flv'); add(main.hls, 'hls'); }
    add(DOUYIN_LL_lookup(flvMap, key), 'flv');
    add(DOUYIN_LL_lookup(hlsMap, key), 'hls');
    if (!lines.length || audioOnly(key, lines)) return;
    var sdk = main ? (DOUYIN_LL_asMap(main.sdk_params) || {}) : {};
    var d = desc[key] || {};
    var bitrate = DOUYIN_LL_jsonInt(d.v_bit_rate);
    if (bitrate === null) bitrate = DOUYIN_LL_jsonInt(sdk.vbitrate);
    var level = DOUYIN_LL_jsonInt(d.level) || 0;
    var upKey = key.toUpperCase();
    var tier = DOUYIN_LL_Q_TIER[upKey] || 0;
    var sort = tier > 0 ? tier : (level > 0 ? level * 1000000 : (bitrate || 0));
    var name = DOUYIN_LL_text(d.name) || DOUYIN_LL_text(DOUYIN_LL_lookup(names, key)) || DOUYIN_LL_Q_NAME[upKey] || upKey;
    ranked.push({
      id: upKey, name: name, bitrate: bitrate || 0, sort: sort,
      urls: lines.map(function(l){ return l.url; }),
      codec: codecOf(sdk.VCodec) || codecOf(d.v_codec) || undefined
    });
  });
  ranked.sort(function(a, b){ return (b.sort - a.sort) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0); });
  var kept = [], bySet = {};
  ranked.forEach(function(v){
    var set = v.urls.slice().sort().join('\u0000');
    if (bySet[set] !== undefined) return; // same URLs as a better-ranked key: alias, drop
    bySet[set] = kept.length;
    var q = { id: v.id, name: v.name, bitrate: v.bitrate, urls: v.urls };
    if (v.codec) q.codec = v.codec;
    kept.push(q);
  });
  return kept;
}

// ---- Primary play: signed /webcast/room/web/enter/. Port of
// DouyinSite._enter + DouyinApi.enter. Returns the same shape as the old
// directDyRoomPlay: {url, type, quality, qualities, room} or null.
async function DOUYIN_LL_enter(webRid){
  await directDyPrime();
  var url = DOUYIN_LL_signer.signedUrl('https://live.douyin.com/webcast/room/web/enter/', {
    app_name: 'douyin_web', enter_from: 'web_live', live_id: '1',
    web_rid: String(webRid), is_need_double_stream: 'false'
  });
  var j = await nativeJson(url, { headers: { 'User-Agent': DIRECT_LIVE_UA, 'Referer': 'https://live.douyin.com' } }, 15000);
  if (!j || j.status_code !== 0 || !j.data || !Array.isArray(j.data.data) || !j.data.data.length) return null;
  var room = j.data.data[0] || {};
  var stNum = DOUYIN_LL_jsonInt(room.status);
  var live = (stNum !== null) ? (stNum === 2) : (DOUYIN_LL_jsonInt(j.data.room_status) === 0);
  if (!live) return null;
  var qs = DOUYIN_LL_qualitiesFromStreamUrl(room.stream_url || null);
  if (!qs.length) return null;
  var wr = String(webRid);
  try {
    __dyStreamUrls.set(wr, room.stream_url || {});
    __dyHlsMaps.set(wr, (room.stream_url || {}).hls_pull_url_map || {});
    var r19 = directDyPickRoomId(room);
    if (r19) __dyRoomIdMap.set(wr, r19);
  } catch (e) {}
  var owner = room.owner || {};
  return {
    url: qs[0].urls[0], type: DOUYIN_LL_streamType(qs[0].urls[0]), quality: qs[0].id, qualities: qs,
    room: { roomId: wr, title: room.title || '', uname: owner.nickname || '', online: DOUYIN_LL_online(room), status: room.status }
  };
}

// ---- Real search: parse helpers. Port of DouyinApi.searchRooms /
// _searchRoom / _chunks. The general-search endpoint frames its body as
// <hex byte length>\r\n<document>\r\n chunks ending with 0\r\n\r\n.
function DOUYIN_LL_searchChunks(body){
  if (!/^[0-9a-fA-F]+\r?\n/.test(body)) return [body];
  var bytes = DOUYIN_LL_utf8(body), docs = [], pos = 0;
  function latin1(arr){ var s = ''; for (var i = 0; i < arr.length; i++) s += String.fromCharCode(arr[i]); return s; }
  while (pos < bytes.length) {
    var nl = bytes.indexOf(10, pos);
    if (nl < 0) break;
    var size = parseInt(latin1(bytes.slice(pos, nl)).trim().split(';')[0], 16);
    if (isNaN(size)) throw new Error('search: bad chunk header');
    if (size === 0) break;
    var start = nl + 1;
    if (start + size > bytes.length) throw new Error('search: truncated chunk');
    docs.push(DOUYIN_LL_utf8Decode(bytes.slice(start, start + size)));
    pos = start + size;
    if (bytes[pos] === 13) pos++;
    if (bytes[pos] === 10) pos++;
  }
  if (!docs.length) throw new Error('search: no chunk');
  return docs;
}
function DOUYIN_LL_parseSearchRoom(item){
  item = DOUYIN_LL_asMap(item) || {};
  function at(node, key){ var m = DOUYIN_LL_asMap(node); return m ? m[key] : undefined; }
  var lives = at(item, 'lives'), live = at(item, 'live'), liveInfo = at(item, 'live_info');
  var awemeInfo = at(item, 'aweme_info'), data = at(item, 'data');
  var awemeLive = awemeInfo ? at(awemeInfo, 'live_info') : undefined;
  var cands = [
    at(lives, 'rawdata'), at(lives, 'raw_data'), at(live, 'rawdata'), at(liveInfo, 'rawdata'),
    at(awemeLive, 'rawdata'), at(data, 'rawdata'), item.rawdata, item.lives, item.live,
    item.live_info, awemeLive, item.aweme_info, item.data, item
  ];
  var raw = null;
  for (var i = 0; i < cands.length; i++) { var m = DOUYIN_LL_asMap(cands[i]); if (m) { raw = m; break; } }
  if (!raw) return null;
  var room = DOUYIN_LL_asMap(raw.room) || {};
  var owner = DOUYIN_LL_asMap(raw.owner) || {};
  var roomOwner = DOUYIN_LL_asMap(room.owner) || {};
  var roomId = DOUYIN_LL_firstId([raw.id_str, raw.room_id_str, room.id_str, room.id, raw.room_id, raw.roomId]);
  if (!roomId) return null;
  var id = DOUYIN_LL_firstId([owner.web_rid, raw.web_rid, roomOwner.web_rid]) || roomId;
  var nickname = DOUYIN_LL_firstText([owner.nickname, raw.nickname, roomOwner.nickname, item.nickname]) || '';
  var roadMap = Array.isArray(room.partition_road_map) ? room.partition_road_map : [];
  var roadTitle = null;
  if (roadMap.length) { var rm0 = DOUYIN_LL_asMap(roadMap[0]); if (rm0) roadTitle = DOUYIN_LL_text(rm0.title); }
  var part = DOUYIN_LL_asMap(raw.partition);
  var online = DOUYIN_LL_jsonInt(raw.user_count);
  if (online === null) online = DOUYIN_LL_jsonInt(room.user_count);
  return {
    platform: 'douyin', roomId: String(id),
    title: DOUYIN_LL_firstText([raw.title, room.title, item.title, item.desc, nickname]) || '',
    uname: nickname, online: online || 0,
    cover: DOUYIN_LL_firstImage([owner.avatar_large, raw.cover, room.cover, raw.cover_url]),
    face: DOUYIN_LL_firstImage([owner.avatar_thumb, owner.avatar_large]),
    game: DOUYIN_LL_firstText([raw.video_feed_tag, roadTitle, part ? part.title : undefined, item.search_keyword]) || '',
    live: DOUYIN_LL_jsonInt(raw.status) === 2
  };
}
function DOUYIN_LL_parseSearchRooms(body){
  var docs, items = [];
  try { docs = DOUYIN_LL_searchChunks(String(body || '')); } catch (e) { return []; }
  docs.forEach(function(doc){
    var parsed = null;
    try { parsed = JSON.parse(doc); } catch (e) { return; }
    if (!parsed || typeof parsed !== 'object') return;
    if (parsed.status_code !== undefined && parsed.status_code !== 0) return; // 2483 = login required, etc.
    if (Array.isArray(parsed.data)) items = items.concat(parsed.data);
  });
  var seen = {}, out = [];
  items.forEach(function(item){
    var r = DOUYIN_LL_parseSearchRoom(item);
    if (r && !seen[r.roomId]) { seen[r.roomId] = 1; out.push(r); }
  });
  return out.filter(function(r){ return r.live; });
}
// Partition-name search (anonymous, like Pure Live's _partitionSearch).
async function DOUYIN_LL_partitionSearch(keyword){
  var headers = {
    'User-Agent': DIRECT_LIVE_UA, 'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    'Referer': 'https://www.douyin.com/search/' + encodeURIComponent(keyword) + '?source=switch_tab&type=live',
    'Origin': 'https://www.douyin.com', 'Sec-Fetch-Dest': 'empty', 'Sec-Fetch-Mode': 'cors', 'Sec-Fetch-Site': 'same-origin'
  };
  var j = await nativeJson('https://live.douyin.com/webcast/web/partition/search/?keyword=' + encodeURIComponent(keyword) + '&aid=6383', { headers: headers }, 15000);
  var list = (((j && j.data) || {}).SearchResult) || [];
  var out = [];
  list.forEach(function(it){
    var p = (it && it.partition) || {}, id = String(p.id_str || ''), t = p.type;
    if (id && t !== undefined && t !== null && t !== '') out.push({ id: id + ',' + String(t), name: p.title || '' });
  });
  return out;
}

// ---- Overrides (same names as app.js; this file loads after it). ----

// Room play by 19-digit broadcast room_id: reflow/info first (as before),
// but an ended broadcast (status 4) or a reflow answer with no stream now
// re-enters by the owner's web_rid (Pure Live _fetch), and qualities now
// carry FLV + HLS lines per quality.
async function directDyRoomPlayById(roomId){
  await directDyPrime();
  var rid = String(roomId || '');
  try {
    var j = await nativeJson('https://webcast.amemv.com/webcast/room/reflow/info/?type_id=0&live_id=1&room_id=' + encodeURIComponent(rid) + '&sec_user_id=&version_code=99.99.99&app_id=6383', { headers: { 'User-Agent': DIRECT_LIVE_UA, 'Referer': 'https://live.douyin.com' } }, 15000);
    if (j && j.status_code === 0 && j.data && j.data.room) {
      var room = j.data.room;
      var qs = DOUYIN_LL_qualitiesFromStreamUrl(room.stream_url || null);
      var webRid = (room.owner && room.owner.web_rid) ? String(room.owner.web_rid) : '';
      if ((!qs.length || DOUYIN_LL_jsonInt(room.status) === 4) && webRid) {
        try { var e = await DOUYIN_LL_enter(webRid); if (e) return e; } catch (err) {}
      }
      if (!qs.length) return null;
      if (webRid) { try { __dyStreamUrls.set(webRid, room.stream_url || {}); } catch (err) {} }
      var owner = room.owner || {};
      return {
        url: qs[0].urls[0], type: DOUYIN_LL_streamType(qs[0].urls[0]), quality: qs[0].id, qualities: qs,
        room: { roomId: String(room.id_str || rid), title: room.title || '', uname: owner.nickname || '', online: DOUYIN_LL_online(room), status: room.status }
      };
    }
  } catch (e) {}
  return null;
}

// Room play by web_rid: cached stream -> 19-digit room_id -> cached HLS
// map -> SIGNED room/web/enter/ (new primary path) -> room-page scrape
// (last resort, as before). reflow/info is only used via
// directDyRoomPlayById for 19-digit ids, not as the primary path.
async function directDyRoomPlay(webRid){
  var wr = String(webRid || '');
  if (/^7\d{18}$/.test(wr)) { try { var out0 = await directDyRoomPlayById(wr); if (out0) return out0; } catch (e) {} }
  var su0 = __dyStreamUrls.get(wr);
  if (su0) {
    var qs0 = DOUYIN_LL_qualitiesFromStreamUrl(su0);
    if (qs0.length && directDyUrlFresh(qs0[0].urls[0])) return { url: qs0[0].urls[0], type: DOUYIN_LL_streamType(qs0[0].urls[0]), quality: qs0[0].id, qualities: qs0 };
    __dyStreamUrls.delete(wr);
  }
  var rid19 = __dyRoomIdMap.get(wr);
  if (rid19) { try { var out1 = await directDyRoomPlayById(rid19); if (out1) return out1; } catch (e) {} }
  var m0 = directDyHlsMapGet(wr);
  if (m0) {
    var qsm = directDyQualitiesFromMap(m0);
    if (qsm.length && directDyUrlFresh(qsm[0].urls[0])) return { url: qsm[0].urls[0], type: 'hls', quality: qsm[0].id, qualities: qsm };
    __dyHlsMaps.delete(wr);
  }
  try { var out2 = await DOUYIN_LL_enter(wr); if (out2) return out2; } catch (e) {}
  await directDyPrime();
  var html = await nativeText('https://live.douyin.com/' + encodeURIComponent(wr), { headers: { 'User-Agent': DIRECT_LIVE_UA, 'Referer': 'https://live.douyin.com' } }, 15000);
  var u = html.replace(/\\"/g, '"').replace(/\\u0026/g, '&');
  var idm = u.match(/"id_str":"(7[0-9]{18})"/);
  if (idm) { __dyRoomIdMap.set(wr, idm[1]); if (__dyRoomIdMap.size > 500) __dyRoomIdMap.delete(__dyRoomIdMap.keys().next().value); }
  var i = u.indexOf('hls_pull_url_map');
  if (i < 0) return null;
  var seg = u.slice(i, i + 20000);
  var map = {};
  var re = /"(ORIGION|ORIGIN|FULL_HD1|UHD|HD1|HD|SD2|SD|SD1|LD|MD)"\s*:\s*"(https?:\/\/[^"]+\.m3u8[^"]*)"/g;
  var mm;
  while ((mm = re.exec(seg)) !== null) { if (!map[mm[1]]) map[mm[1]] = mm[2]; }
  var qs = directDyQualitiesFromMap(map);
  if (!qs.length) return null;
  return { url: qs[0].urls[0], type: 'hls', quality: qs[0].id, qualities: qs };
}

// ---- Real search (new). Port of DouyinSite.searchRooms: live search,
// then general search (both need a signed-in cookie — anonymous requests
// answer 2483, so expect these to fail without a login), then the rooms
// of the first 3 partitions whose name matches the keyword, then — only
// so search does not regress vs the old feed filter — the feed substring
// match (searchVia 'feed'). Returns the
// same room shape as directLiveSearch: {platform, roomId, title, uname,
// online, cover, face, game, live} plus searchVia ('live' | 'general' |
// 'partition'). Never throws: [] on total failure.
async function directDySearchLive(keyword, page, pageSize){
  var q = String(keyword || '').trim();
  if (!q) return [];
  var count = Math.max(1, Math.min(50, parseInt(pageSize || '20', 10) || 20));
  var pg = Math.max(1, parseInt(page || '1', 10) || 1);
  var offset = count * (pg - 1);
  await directDyPrime();
  var headers = {
    'User-Agent': DIRECT_LIVE_UA, 'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    'Referer': 'https://www.douyin.com/search/' + encodeURIComponent(q) + '?source=switch_tab&type=live',
    'Origin': 'https://www.douyin.com', 'Sec-Fetch-Dest': 'empty', 'Sec-Fetch-Mode': 'cors', 'Sec-Fetch-Site': 'same-origin'
  };
  var attempts = [
    { path: '/aweme/v1/web/live/search/', via: 'live', extra: { search_source: 'switch_tab', query_correct_type: '1', need_filter_settings: '1', list_type: 'single' } },
    { path: '/aweme/v1/web/general/search/stream/', via: 'general', extra: {} }
  ];
  for (var a = 0; a < attempts.length; a++) {
    var att = attempts[a];
    var params = 'device_platform=webapp&aid=6383&channel=channel_pc_web&search_channel=aweme_live';
    Object.keys(att.extra).forEach(function(k){ params += '&' + DOUYIN_LL_enc(k) + '=' + DOUYIN_LL_enc(att.extra[k]); });
    params += '&keyword=' + encodeURIComponent(q) + '&offset=' + offset + '&count=' + count + '&os_version=10';
    try {
      var r = await nativeFetch('https://www.douyin.com' + att.path + '?' + params, { headers: headers }, 15000);
      if (r.status < 200 || r.status >= 300) continue;
      var rooms = DOUYIN_LL_parseSearchRooms(r.text);
      if (rooms.length) {
        rooms.forEach(function(rm){ rm.searchVia = att.via; });
        return rooms;
      }
    } catch (e) {}
  }
  var out = [], seen = {};
  try {
    var areas = await DOUYIN_LL_partitionSearch(q);
    for (var p = 0; p < Math.min(3, areas.length); p++) {
      var area = areas[p], arr = [];
      try { arr = await directDyPartitionRoomsByCat(area.id, 1); } catch (e) { arr = []; }
      for (var n = 0; n < arr.length; n++) {
        var r = arr[n];
        if (!r || !r.roomId || seen[r.roomId]) continue;
        seen[r.roomId] = 1;
        out.push({ platform: 'douyin', roomId: r.roomId, title: r.title || '', uname: r.uname || '', online: r.online || 0, cover: r.cover || '', face: r.face || '', game: area.name || '', live: true, searchVia: 'partition' });
        if (out.length >= count) return out;
      }
    }
  } catch (e) {}
  if (out.length) return out;
  // Last resort (keeps the old behaviour instead of regressing it): the
  // feed is one random draw, so a streamer-name query only matches when
  // the streamer happens to be in this draw. Marked searchVia 'feed'.
  try {
    var feed = await directDyFeed(), ql = q.toLowerCase();
    feed.forEach(function(fr){
      var hay = ((fr.title || '') + ' ' + (fr.uname || '')).toLowerCase();
      if (hay.indexOf(ql) >= 0 && !seen[fr.roomId]) {
        seen[fr.roomId] = 1;
        out.push({ platform: 'douyin', roomId: fr.roomId, title: fr.title || '', uname: fr.uname || '', online: fr.online || 0, cover: fr.cover || '', face: fr.face || '', game: '', live: true, searchVia: 'feed' });
      }
    });
  } catch (e) {}
  return out;
}

// ---- API hosts used by this file (nativeFetch allowlist) ----
// live.douyin.com — room/web/enter/ (signed a_bogus), webcast/web/
//   partition/detail/room/v2/, webcast/web/partition/search/, room page,
//   homepage prime. (Already allowlisted.)
// webcast.amemv.com — webcast/room/reflow/info/. (Already allowlisted.)
// www.douyin.com — NEW, add to ViewController.allowedHosts:
//   /aweme/v1/web/live/search/ + /aweme/v1/web/general/search/stream/
//   (real search; anonymous requests answer 2483, then the partition
//   fallback runs — search still works, just by category name).
// Media (stream) hosts are dynamic per play URL (pull-hls-*/pull-flv-*
// douyincdn domains and similar) and are fetched by the player, not by
// nativeFetch, so they need no allowlist entry here.
