// APP STATE band (docs/architecture.md), platform-edge side: the frame the
// app takes when there is no camera to take one with.
//
// **Why this exists at all.** The captain tests on the iOS Simulator, which
// has no camera and never will. Without a source that works there, the whole
// capture flow — the ping, the pause, the word, the write — could only ever
// be walked on a cable-attached phone, which is exactly the sort of thing
// that stays untested until the week it matters.
//
// So this encodes a real image file with no camera and no dependency: a PNG
// written by hand, out of `dart:io`'s zlib and a CRC table. It is a stand-in
// and reads as one. It is deliberately *not* a fixed asset: the colour is
// derived from the instant, so two frames taken a minute apart are visibly
// two different photographs and a pool of them is legible.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The stand-in frame's pixel size. Portrait, because a phone held up to
/// photograph the people you are with is a phone held upright.
const standInWidth = 360;
const standInHeight = 480;

/// Encodes one stand-in frame as PNG bytes.
///
/// [seed] chooses the colour; pass the capture instant's millisecond count so
/// successive frames differ. The image is a plain two-tone field split on a
/// diagonal — enough to see it is an image, and honest about not being a
/// photograph.
Uint8List standInFrameBytes(int seed) {
  final hue = seed % 360;
  final (r1, g1, b1) = _fromHue(hue, 0.55, 0.72);
  final (r2, g2, b2) = _fromHue((hue + 40) % 360, 0.45, 0.38);

  // One filter byte (0 — no filter) then RGB triples, per PNG scanlines.
  final raw = Uint8List(standInHeight * (1 + standInWidth * 3));
  var i = 0;
  for (var y = 0; y < standInHeight; y++) {
    raw[i++] = 0;
    for (var x = 0; x < standInWidth; x++) {
      final belowDiagonal = y * standInWidth > x * standInHeight;
      raw[i++] = belowDiagonal ? r2 : r1;
      raw[i++] = belowDiagonal ? g2 : g1;
      raw[i++] = belowDiagonal ? b2 : b1;
    }
  }

  final out = BytesBuilder();
  out.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  out.add(_chunk('IHDR', _ihdr()));
  out.add(_chunk('IDAT', Uint8List.fromList(ZLibCodec().encode(raw))));
  out.add(_chunk('IEND', Uint8List(0)));
  return out.takeBytes();
}

Uint8List _ihdr() {
  final data = ByteData(13);
  data.setUint32(0, standInWidth);
  data.setUint32(4, standInHeight);
  data.setUint8(8, 8); // bit depth
  data.setUint8(9, 2); // colour type 2: truecolour RGB
  data.setUint8(10, 0); // deflate
  data.setUint8(11, 0); // adaptive filtering
  data.setUint8(12, 0); // no interlace
  return data.buffer.asUint8List();
}

/// One PNG chunk: length, type, data, CRC over type+data.
Uint8List _chunk(String type, Uint8List data) {
  final typeBytes = ascii.encode(type);
  final body = Uint8List(typeBytes.length + data.length)
    ..setRange(0, typeBytes.length, typeBytes)
    ..setRange(typeBytes.length, typeBytes.length + data.length, data);

  final out = BytesBuilder();
  final length = ByteData(4)..setUint32(0, data.length);
  out.add(length.buffer.asUint8List());
  out.add(body);
  final crc = ByteData(4)..setUint32(0, _crc32(body));
  out.add(crc.buffer.asUint8List());
  return out.takeBytes();
}

final List<int> _crcTable = () {
  final table = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}();

int _crc32(Uint8List bytes) {
  var c = 0xFFFFFFFF;
  for (final byte in bytes) {
    c = _crcTable[(c ^ byte) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// A colour from a hue, so the seed only has to be a number.
(int, int, int) _fromHue(int hue, double saturation, double value) {
  final h = hue / 60.0;
  final c = value * saturation;
  final x = c * (1 - ((h % 2) - 1).abs());
  final m = value - c;
  final (r, g, b) = switch (h.floor()) {
    0 => (c, x, 0.0),
    1 => (x, c, 0.0),
    2 => (0.0, c, x),
    3 => (0.0, x, c),
    4 => (x, 0.0, c),
    _ => (c, 0.0, x),
  };
  return (
    ((r + m) * 255).round(),
    ((g + m) * 255).round(),
    ((b + m) * 255).round(),
  );
}
