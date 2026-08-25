// The trip's id is minted on the phone, before the trip has ever been near a
// server (docs/decisions/2026-08-25-the-trip-mints-its-own-id.md). This
// package holds the *shape* half of that: it formats sixteen bytes somebody
// else drew, and it can say whether a spelling is the one `trips.id` will
// take. Where the bytes come from is the app's, and is tested there.
import 'package:cairn_model/cairn_model.dart';
import 'package:test/test.dart';

/// Sixteen bytes with every nibble distinguishable, so a misplaced hyphen or
/// a transposed pair shows up in the assertion rather than hiding.
const _bytes = [
  0x00, 0x11, 0x22, 0x33, //
  0x44, 0x55,
  0x66, 0x77,
  0x88, 0x99,
  0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
];

void main() {
  group('minting a trip id', () {
    test('formats the bytes as one lower-case hyphenated uuid', () {
      // Byte 6 becomes 0x46 (version 4) and byte 8 becomes 0x88 (variant
      // 10xx); every other byte is passed through untouched.
      expect(TripId.mint(_bytes).value, '00112233-4455-4677-8899-aabbccddeeff');
    });

    test('stamps version 4 and the RFC 4122 variant over whatever it is given',
        () {
      // All-zero bytes are not random, but the *shape* is this factory's
      // promise, so even they come back well-formed.
      final zeros = TripId.mint(List.filled(16, 0));
      expect(zeros.value, '00000000-0000-4000-8000-000000000000');
      expect(zeros.isCanonical, isTrue);

      final ones = TripId.mint(List.filled(16, 0xff));
      expect(ones.value, 'ffffffff-ffff-4fff-bfff-ffffffffffff');
      expect(ones.isCanonical, isTrue);
    });

    test('is the id it was handed, not a fresh one each read', () {
      final id = TripId.mint(_bytes);
      expect(id, TripId.mint(_bytes));
      expect(id.value, id.value);
    });

    test('two different draws are two different trips', () {
      final other = [..._bytes]..[15] = 0x00;
      expect(TripId.mint(_bytes), isNot(TripId.mint(other)));
    });

    test('refuses anything that is not sixteen bytes', () {
      expect(() => TripId.mint(const []), throwsArgumentError);
      expect(() => TripId.mint(List.filled(15, 0)), throwsArgumentError);
      expect(() => TripId.mint(List.filled(17, 0)), throwsArgumentError);
    });

    test('refuses a value that is not a byte', () {
      expect(() => TripId.mint(List.filled(16, 256)), throwsArgumentError);
      expect(() => TripId.mint(List.filled(16, -1)), throwsArgumentError);
    });
  });

  group('the spelling the server will keep', () {
    test('a minted id is canonical', () {
      expect(TripId.mint(_bytes).isCanonical, isTrue);
    });

    test('an id from before the mint existed is not', () {
      // The constant every trip on this phone used to carry. The store's
      // migration looks for exactly this case.
      expect(TripId('local-trip').isCanonical, isFalse);
    });

    test('a uuid spelled the wrong way is not canonical either', () {
      final minted = TripId.mint(_bytes).value;
      expect(TripId(minted.toUpperCase()).isCanonical, isFalse,
          reason: 'Postgres reads a uuid back lower-case');
      expect(TripId(minted.replaceAll('-', '')).isCanonical, isFalse);
      // Version 1, not 4: a well-formed uuid, but not one this app mints.
      expect(
          TripId('00112233-4455-1677-8899-aabbccddeeff').isCanonical, isFalse);
    });

    test('an id is still just an id: a trip id never equals a member id', () {
      final minted = TripId.mint(_bytes);
      expect(minted, isNot(MemberId(minted.value)));
    });
  });
}
