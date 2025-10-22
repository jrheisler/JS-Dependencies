import 'dart:io';
import 'dart:typed_data';

Future<String?> fileSha256(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    return sha256Hex(bytes);
  } catch (_) {
    return null;
  }
}

String sha256Hex(List<int> data) {
  final bytes = data is Uint8List ? data : Uint8List.fromList(data);
  final bitLength = bytes.length * 8;
  final totalLength = ((bytes.length + 9 + 63) ~/ 64) * 64;
  final padded = Uint8List(totalLength);
  padded.setRange(0, bytes.length, bytes);
  padded[bytes.length] = 0x80;
  final lengthData = ByteData(8)..setUint64(0, bitLength, Endian.big);
  padded.setRange(totalLength - 8, totalLength, lengthData.buffer.asUint8List());

  final h = List<int>.from(_initialHashValues);
  final w = Uint32List(64);
  final byteView = ByteData.view(padded.buffer);

  for (var offset = 0; offset < padded.length; offset += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = byteView.getUint32(offset + i * 4, Endian.big);
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = _add32(_add32(_add32(w[i - 16], s0), w[i - 7]), s1);
    }

    var a = h[0];
    var b = h[1];
    var c = h[2];
    var d = h[3];
    var e = h[4];
    var f = h[5];
    var g = h[6];
    var hh = h[7];

    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ (((~e) & 0xffffffff) & g);
      final temp1 = _add32(_add32(_add32(_add32(hh, s1), ch), _k[i]), w[i]);
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = _add32(s0, maj);

      hh = g;
      g = f;
      f = e;
      e = _add32(d, temp1);
      d = c;
      c = b;
      b = a;
      a = _add32(temp1, temp2);
    }

    h[0] = _add32(h[0], a);
    h[1] = _add32(h[1], b);
    h[2] = _add32(h[2], c);
    h[3] = _add32(h[3], d);
    h[4] = _add32(h[4], e);
    h[5] = _add32(h[5], f);
    h[6] = _add32(h[6], g);
    h[7] = _add32(h[7], hh);
  }

  final buffer = StringBuffer();
  for (final value in h) {
    buffer.write(value.toRadixString(16).padLeft(8, '0'));
  }
  return buffer.toString();
}

int _add32(int a, int b) => (a + b) & 0xffffffff;

int _rotr(int value, int amount) =>
    ((value >> amount) | ((value << (32 - amount)) & 0xffffffff)) & 0xffffffff;

const List<int> _initialHashValues = <int>[
  0x6a09e667,
  0xbb67ae85,
  0x3c6ef372,
  0xa54ff53a,
  0x510e527f,
  0x9b05688c,
  0x1f83d9ab,
  0x5be0cd19,
];

const List<int> _k = <int>[
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
];
