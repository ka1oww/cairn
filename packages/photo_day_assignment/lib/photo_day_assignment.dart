/// Decides which day of a trip a photo belongs to.
///
/// See the package README for the degradation ladder this implements and,
/// importantly, what it cannot do.
library;

export 'src/assign.dart' show assignPhotoToDay, initializePhotoDayAssignment;
export 'src/local_date_time.dart' show LocalDateTime;
export 'src/photo_metadata.dart' show PhotoMetadata;
export 'src/result.dart'
    show
        PhotoDayAssignmentConfidence,
        PhotoDayAssignmentMethod,
        PhotoDayAssignmentOutcome,
        PhotoDayAssignmentResult;
export 'src/trip_definition.dart' show TripDefinition;
