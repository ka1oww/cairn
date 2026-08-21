import 'package:cairn_model/cairn_model.dart';
import 'package:test/test.dart';

void main() {
  const jonas = MemberId('jonas');
  const tomas = MemberId('tomas');

  PhotoRef photo(String id, MemberId by, DateTime takenAt) => PhotoRef(
        id: PhotoId(id),
        dayNumber: 4,
        contributor: by,
        takenAt: takenAt,
        origin: PhotoOrigin.pinged,
      );

  final morning = photo('a', jonas, DateTime.utc(2026, 6, 17, 1));
  final afternoon = photo('b', tomas, DateTime.utc(2026, 6, 17, 6));
  final evening = photo('c', jonas, DateTime.utc(2026, 6, 17, 13));

  test('photos come back oldest first however they went in', () {
    final pool = DayPool.of(4, [evening, morning, afternoon]);
    expect(pool.photos.map((p) => p.id.value), ['a', 'b', 'c']);
    expect(DayPool.empty(4).add(evening).add(morning).photos.first, morning);
  });

  test('photos taken at the same instant order by id, so the order is total',
      () {
    final tie = photo('a2', tomas, morning.takenAt);
    expect(
      DayPool.of(4, [tie, morning]).photos.map((p) => p.id.value),
      ['a', 'a2'],
    );
  });

  test('a photo belonging to another day is refused', () {
    final elsewhere = PhotoRef(
      id: const PhotoId('d'),
      dayNumber: 5,
      contributor: jonas,
      takenAt: DateTime.utc(2026, 6, 18, 2),
      origin: PhotoOrigin.imported,
    );
    expect(() => DayPool.of(4, [elsewhere]), throwsA(isA<ArgumentError>()));
    expect(
        () => DayPool.empty(4).add(elsewhere), throwsA(isA<ArgumentError>()));
  });

  test('the same photo cannot be in the pool twice', () {
    expect(
        () => DayPool.of(4, [morning, morning]), throwsA(isA<ArgumentError>()));
  });

  group('deleting', () {
    final pool = DayPool.of(4, [morning, afternoon, evening]);

    test('you can delete your own photo', () {
      final after = pool.deletePhoto(const PhotoId('a'), by: jonas);
      expect(after.photos.map((p) => p.id.value), ['b', 'c']);
    });

    test('you cannot delete someone else\'s', () {
      expect(
        () => pool.deletePhoto(const PhotoId('a'), by: tomas),
        throwsA(isA<ArgumentError>()),
      );
      expect(pool.photos.length, 3, reason: 'and nothing changed');
    });

    test('deleting a photo that is not there is an error, not a no-op', () {
      expect(
        () => pool.deletePhoto(const PhotoId('nope'), by: jonas),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('contributors survive deletion, always', () {
      final emptied = pool
          .deletePhoto(const PhotoId('a'), by: jonas)
          .deletePhoto(const PhotoId('c'), by: jonas)
          .deletePhoto(const PhotoId('b'), by: tomas);
      expect(emptied.isEmpty, isTrue);
      expect(emptied.contributors, {jonas, tomas});
    });
  });

  group('rebuilding a pool', () {
    test('restore keeps contributors whose photos are gone', () {
      final reloaded = DayPool.restore(
        dayNumber: 4,
        photos: const [],
        contributors: const [jonas],
      );
      expect(reloaded.hasContributed(jonas), isTrue);
      expect(reloaded.isEmpty, isTrue);
    });

    test('of seeds contributors from the photos alone, which is the trap', () {
      // Rebuilding a day from just the surviving photos revokes access the
      // person already earned. This asserts the sharp edge exists so that
      // DayPool.restore is obviously the one to reach for on reload.
      final emptied =
          DayPool.of(4, [morning]).deletePhoto(const PhotoId('a'), by: jonas);
      expect(emptied.hasContributed(jonas), isTrue);
      expect(DayPool.of(4, emptied.photos).hasContributed(jonas), isFalse);
    });
  });

  test('the photo list cannot be mutated through the pool', () {
    final pool = DayPool.of(4, [morning]);
    expect(() => pool.photos.add(evening), throwsUnsupportedError);
    expect(() => pool.contributors.add(tomas), throwsUnsupportedError);
  });
}
