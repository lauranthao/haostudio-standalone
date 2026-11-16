// SM3 hash (GB/T 32905-2016) — pure-Dart implementation.
//
// Pure Live's A-Bogus port (`abogus.dart`) calls `SM3.hashBytes` from the
// `dart_sm` package, which this project does not depend on. Rather than add
// a dependency for one hash, SM3 is implemented here from the public
// standard so `abogus.dart` stays a verbatim port apart from its import.
//
// Test vectors (GB/T 32905-2016, §5 / GM/T 0004-2012 examples):
//   SM3("")    = 1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b
//   SM3("abc") = 66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0

import 'dart:typed_data';

class SM3 {
  SM3._();

  static const List<int> _iv = <int>[
    0x7380166f,
    0x4914b2b9,
    0x172442d7,
    0xda8a0600,
    0xa96f30bc,
    0x163138aa,
    0xe38dee4d,
    0xb0fb0e4e,
  ];

  static const int _t0 = 0x79cc4519;
  static const int _t1 = 0x7a879d8a;

  static int _rotl(int x, int n) {
    n &= 31;
    return ((x << n) | (x >>> (32 - n))) & 0xffffffff;
  }

  static int _p0(int x) => x ^ _rotl(x, 9) ^ _rotl(x, 17);

  static int _p1(int x) => x ^ _rotl(x, 15) ^ _rotl(x, 23);

  static int _ff(int x, int y, int z, int j) =>
      j < 16 ? x ^ y ^ z : (x & y) | ((x | y) & z);

  static int _gg(int x, int y, int z, int j) =>
      j < 16 ? x ^ y ^ z : (x & y) | ((~x) & z);

  /// Hex-encoded SM3 digest of [data] (same shape as `dart_sm`'s
  /// `SM3.hashBytes`, which `abogus.dart` expects).
  static String hashBytes(Uint8List data) {
    final digest = hash(data);
    final out = StringBuffer();
    for (final byte in digest) {
      out.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  static Uint8List hash(List<int> data) {
    // Padding: 0x80, zeros, 64-bit big-endian bit length.
    final padded = <int>[...data, 0x80];
    while (padded.length % 64 != 56) {
      padded.add(0);
    }
    final bitLen = data.length * 8;
    for (var i = 7; i >= 0; i--) {
      padded.add((bitLen >> (i * 8)) & 0xff);
    }

    var v = List<int>.from(_iv);
    for (var offset = 0; offset < padded.length; offset += 64) {
      v = _compress(v, padded, offset);
    }
    final out = Uint8List(32);
    for (var i = 0; i < 8; i++) {
      out[i * 4] = (v[i] >> 24) & 0xff;
      out[i * 4 + 1] = (v[i] >> 16) & 0xff;
      out[i * 4 + 2] = (v[i] >> 8) & 0xff;
      out[i * 4 + 3] = v[i] & 0xff;
    }
    return out;
  }

  static List<int> _compress(List<int> v, List<int> block, int offset) {
    final w = List<int>.filled(68, 0);
    for (var i = 0; i < 16; i++) {
      w[i] = ((block[offset + i * 4] << 24) |
              (block[offset + i * 4 + 1] << 16) |
              (block[offset + i * 4 + 2] << 8) |
              block[offset + i * 4 + 3]) &
          0xffffffff;
    }
    for (var i = 16; i < 68; i++) {
      w[i] = (_p1(w[i - 16] ^ w[i - 9] ^ _rotl(w[i - 3], 15)) ^
              _rotl(w[i - 13], 7) ^
              w[i - 6]) &
          0xffffffff;
    }
    final wPrime = List<int>.generate(64, (i) => (w[i] ^ w[i + 4]) & 0xffffffff);

    var a = v[0];
    var b = v[1];
    var c = v[2];
    var d = v[3];
    var e = v[4];
    var f = v[5];
    var g = v[6];
    var h = v[7];
    for (var j = 0; j < 64; j++) {
      final t = j < 16 ? _t0 : _t1;
      final ss1 = _rotl(
          (_rotl(a, 12) + e + _rotl(t, j)) & 0xffffffff, 7);
      final ss2 = ss1 ^ _rotl(a, 12);
      final tt1 = (_ff(a, b, c, j) + d + ss2 + wPrime[j]) & 0xffffffff;
      final tt2 = (_gg(e, f, g, j) + h + ss1 + w[j]) & 0xffffffff;
      d = c;
      c = _rotl(b, 9);
      b = a;
      a = tt1;
      h = g;
      g = _rotl(f, 19);
      f = e;
      e = _p0(tt2);
    }
    return <int>[
      v[0] ^ a,
      v[1] ^ b,
      v[2] ^ c,
      v[3] ^ d,
      v[4] ^ e,
      v[5] ^ f,
      v[6] ^ g,
      v[7] ^ h,
    ];
  }
}
