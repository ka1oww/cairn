import 'local_date_time.dart';

/// The metadata this package needs to place one photo on a trip day.
///
/// All fields are optional except that at least one of [exifLocalTimestamp]
/// or [fileModifiedTime] should be supplied for a useful result — with
/// neither, [assignPhotoToDay] returns
/// [PhotoDayAssignmentOutcome.insufficientMetadata].
///
/// This package never reads image bytes or EXIF tags itself; the app layer
/// is responsible for extracting these values and handing them over.
class PhotoMetadata {
  /// The EXIF `DateTimeOriginal` (or similar) wall-clock reading, with no
  /// timezone attached — because EXIF doesn't carry one. `null` if the photo
  /// has no EXIF timestamp (common for forwarded/re-encoded images).
  final LocalDateTime? exifLocalTimestamp;

  /// GPS latitude in degrees, [-90, 90]. `null` if unavailable (most
  /// forwarded photos have GPS stripped — see the package README).
  final double? gpsLatitude;

  /// GPS longitude in degrees, [-180, 180]. `null` if unavailable.
  final double? gpsLongitude;

  /// The file's last-modified time, as a real absolute instant (e.g.
  /// `file.lastModifiedSync().toUtc()` or a server-recorded upload time).
  /// This is the last-resort fallback when there is no EXIF timestamp at
  /// all. Unlike [exifLocalTimestamp], this is a genuine instant — it may be
  /// passed as UTC or local Dart [DateTime]; either way it is converted with
  /// `.toUtc()`, which is safe because a [DateTime] always encodes a real
  /// point in time regardless of its `isUtc` flag.
  final DateTime? fileModifiedTime;

  const PhotoMetadata({
    this.exifLocalTimestamp,
    this.gpsLatitude,
    this.gpsLongitude,
    this.fileModifiedTime,
  });

  /// True only when both latitude and longitude are present and in range.
  /// A photo with just one of the two (malformed metadata) is treated as
  /// having no usable GPS at all — half a coordinate can't be looked up.
  bool get hasUsableGps =>
      gpsLatitude != null &&
      gpsLongitude != null &&
      gpsLatitude! >= -90 &&
      gpsLatitude! <= 90 &&
      gpsLongitude! >= -180 &&
      gpsLongitude! <= 180;
}
