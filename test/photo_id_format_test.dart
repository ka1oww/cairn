// A photo's id is one rule written on both sides of a seam, and this is the
// only thing that compares them.
//
// The phone mints the id (`mintPhotoId`), the upload function validates it
// (`UUID_RE` in `supabase/functions/r2-upload-url/handler.ts`), and Postgres
// stores it (`photos.id uuid`, `supabase/migrations/0006_photos.sql`). Nothing
// has ever run those three against each other — no photo byte has ever moved
// between two phones — and they had in fact already drifted: the minter wrote
// thirty-two undashed hex characters, which the function refuses with a 400 and
// which no `uuid` column accepts. The first real upload would have been the
// first thing to notice.
//
// So this test does what `supabase/tests/rls_probe.py` does when it reads the
// invite vocabulary out of `packages/cairn_model/lib/src/`: it reads the *other
// side's own source* rather than a copy of it, because a copy is a third thing
// to keep in step.
import 'dart:io';

import 'package:cairn/repositories/photo_repository.dart';
import 'package:cairn_model/cairn_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// `UUID_RE` exactly as the edge function declares it.
///
/// Read rather than copied. If the declaration moves or changes shape this
/// throws instead of quietly passing, which is the point: a drift detector
/// that cannot find one half is not reporting agreement.
RegExp uploadFunctionUuidPattern() {
  final source = File('supabase/functions/r2-upload-url/handler.ts')
      .readAsStringSync();
  final declaration = RegExp(
    r'export const UUID_RE\s*=\s*/(.+)/([a-z]*);',
    dotAll: false,
  ).firstMatch(source);
  if (declaration == null) {
    throw StateError(
      'could not find UUID_RE in handler.ts — the seam moved, so this test '
      'can no longer say whether the two halves agree',
    );
  }
  final flags = declaration.group(2)!;
  return RegExp(declaration.group(1)!, caseSensitive: !flags.contains('i'));
}

void main() {
  test('a minted photo id is spelled the way the upload function demands', () {
    final pattern = uploadFunctionUuidPattern();
    for (var i = 0; i < 200; i++) {
      final id = mintPhotoId();
      expect(
        pattern.hasMatch(id),
        isTrue,
        reason: '$id is not the spelling r2-upload-url accepts',
      );
    }
  });

  test(
    'and it is a version-4 uuid, which is what photos.id will read back',
    () {
      for (var i = 0; i < 200; i++) {
        expect(PhotoId(mintPhotoId()).isCanonical, isTrue);
      }
    },
  );

  test('a trip id and a photo id are spelled identically', () {
    // Both are `uuid` columns and both are minted on the phone, so one
    // formatter serves both (`cairn_model`'s `_uuidFrom`). This is what
    // notices if that stops being true.
    final pattern = uploadFunctionUuidPattern();
    final tripId = TripId.mint(List<int>.generate(16, (i) => i * 7 % 256));
    expect(pattern.hasMatch(tripId.value), isTrue);
    expect(tripId.isCanonical, isTrue);
  });

  test(
    'the undashed form the minter used to produce is refused by that pattern',
    () {
      // Not a hypothetical: this is exactly what `_mintPhotoId` returned.
      final pattern = uploadFunctionUuidPattern();
      expect(pattern.hasMatch('2222222222224222822222222222222a'), isFalse);
    },
  );

  test('PhotoId.mint refuses anything that is not sixteen bytes', () {
    expect(() => PhotoId.mint(const []), throwsArgumentError);
    expect(() => PhotoId.mint(List<int>.filled(15, 0)), throwsArgumentError);
    expect(() => PhotoId.mint(List<int>.filled(16, 256)), throwsArgumentError);
  });
}
