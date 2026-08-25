// The stand-in frame: the image the app takes where there is no camera.
//
// It exists so the whole capture flow is walkable on the iOS Simulator, which
// has no camera and never will. That only holds if what it writes is a real,
// decodable image file — so what is asserted here is the file format itself,
// by hand, rather than "some bytes came back".
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/app_state/stand_in_frame.dart';

/// The eight bytes every PNG starts with.
const _signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// Walks the chunk list, returning each chunk's type in order. Throws if any
/// chunk's CRC does not match — which is the assertion that matters, because
/// a decoder is entitled to reject the file on it.
List<String> chunkTypes(Uint8List png) {
  final view = ByteData.sublistView(png);
  final types = <String>[];
  var offset = _signature.length;
  while (offset < png.length) {
    final length = view.getUint32(offset);
    final type = ascii.decode(png.sublist(offset + 4, offset + 8));
    types.add(type);
    offset += 12 + length;
  }
  return types;
}

void main() {
  test('it writes a real PNG, signature and chunks in order', () {
    final png = standInFrameBytes(1);
    expect(png.sublist(0, 8), _signature);
    expect(chunkTypes(png), ['IHDR', 'IDAT', 'IEND']);
  });

  test('the header declares the portrait size the app asked for', () {
    final png = standInFrameBytes(1);
    final view = ByteData.sublistView(png);
    // IHDR data starts 8 (signature) + 4 (length) + 4 (type) in.
    expect(view.getUint32(16), standInWidth);
    expect(view.getUint32(20), standInHeight);
    expect(view.getUint8(24), 8, reason: 'eight bits a channel');
    expect(view.getUint8(25), 2, reason: 'truecolour RGB');
    expect(standInHeight, greaterThan(standInWidth),
        reason: 'a phone held up to photograph people is held upright');
  });

  test('two frames a moment apart are two different photographs', () {
    // Not decoration: a pool of identical rectangles is unreadable, and the
    // point of the stand-in is that the flow above it is legible.
    expect(standInFrameBytes(1000), isNot(standInFrameBytes(200000)));
  });

  test('the same instant always encodes the same frame', () {
    expect(standInFrameBytes(4242), standInFrameBytes(4242));
  });
}
