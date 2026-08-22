import 'stable_hash.dart';

/// The shortest a slot is allowed to be, in minutes.
///
/// A person's slot is never shorter than the thirty minutes they have to
/// answer their ping in. This is the constant that makes a short day yield
/// fewer slots than there are people instead of crowding everyone in: on a
/// three-hour departure morning a party of eight is dealt six slots, and
/// the other two sit that day out.
const int minimumSlotMinutes = 30;

/// How much of each slot, as a percentage, is held back at each end.
///
/// The ping never lands in the outer fifth of its slot, which does two
/// things. The first and last minutes of the waking day stay empty, so
/// nobody is pinged at 08:00 sharp. And consecutive pings cannot crowd
/// each other across a slot boundary: the closest two people can be dealt
/// is the two insets combined, **40% of a slot**.
///
/// That floor is a fraction of the slot, not a fixed number of minutes, so
/// it scales with how crowded the day is: about 43 minutes for a party of
/// eight on a full day, and 12 minutes in the tightest case
/// [minimumSlotMinutes] permits. Buying a larger floor would mean pinning
/// the ping to a fixed point in its slot, and a schedule you can predict
/// is a schedule you can pose for -- see [pingMinuteForSlot].
const int _slotInsetPercent = 20;

/// How many slots a day of [availableMinutes] can hold for a party of
/// [partySize].
///
/// One slot per person, unless the day is too short to give everyone
/// [minimumSlotMinutes], in which case it is however many fit. Returns 0
/// for a day with no room at all -- land at 23:00 and nobody is pinged
/// that day, which is the right answer rather than a shortfall to pad.
int slotCountFor({required int partySize, required int availableMinutes}) {
  if (partySize <= 0 || availableMinutes < minimumSlotMinutes) return 0;
  final fit = availableMinutes ~/ minimumSlotMinutes;
  return fit < partySize ? fit : partySize;
}

/// The minute (from local midnight) at which slot [slotIndex] of
/// [slotCount] begins, for a day running from [openMinute] to
/// [closeMinute].
///
/// Slots divide the day evenly. Integer division means their lengths can
/// differ by one minute, never more, and the last slot ends exactly on
/// [closeMinute] with no drift accumulated along the way.
///
/// All of this is integer arithmetic on minutes-since-midnight, bounded by
/// a day (1440) times the party size. That is nowhere near 2^53, so it is
/// exact on the Dart VM and under dart2js alike -- the same portability
/// concern documented on [stableDigestValue], carried through the rest of
/// the derivation rather than dropped after the hash.
int slotStartMinute({
  required int openMinute,
  required int closeMinute,
  required int slotCount,
  required int slotIndex,
}) {
  final span = closeMinute - openMinute;
  return openMinute + (span * slotIndex) ~/ slotCount;
}

/// The minute (from local midnight) at which the person holding slot
/// [slotIndex] is pinged.
///
/// Somewhere in the middle three fifths of the slot, chosen by hashing
/// [seedBase] with the slot index. The jitter is not decoration: a
/// schedule that pinged at 08:00, 09:48, 11:36 every single day would be
/// learnable, and a ping you can see coming is a ping you can pose for.
/// The whole mechanic depends on the photograph being one nobody planned.
int pingMinuteForSlot({
  required String seedBase,
  required int openMinute,
  required int closeMinute,
  required int slotCount,
  required int slotIndex,
}) {
  final start = slotStartMinute(
    openMinute: openMinute,
    closeMinute: closeMinute,
    slotCount: slotCount,
    slotIndex: slotIndex,
  );
  final end = slotStartMinute(
    openMinute: openMinute,
    closeMinute: closeMinute,
    slotCount: slotCount,
    slotIndex: slotIndex + 1,
  );
  final length = end - start;
  final inset = (length * _slotInsetPercent) ~/ 100;
  final jitterSpan = length - 2 * inset;
  if (jitterSpan <= 1) return start + inset;
  return start + inset + stableIndex('$seedBase/minute/$slotIndex', jitterSpan);
}

/// A permutation of `0..partySize-1`: which member takes each slot.
///
/// Element `s` is the index (into the party's canonical member list) of
/// the person holding slot `s`. Because it is a permutation, two people
/// cannot be dealt the same slot and one person cannot be dealt two --
/// that guarantee is structural, not probabilistic, which is the whole
/// reason the party is an input. Hashing each id independently, as this
/// package used to, permits both collisions and clustering.
///
/// On a day with fewer slots than people, the first `slotCount` entries
/// are the ones dealt in; the rest of the permutation is who sits that day
/// out. Since the permutation is reshuffled every day, sitting out rotates
/// too.
///
/// This is Fisher-Yates with the swap partner drawn from the hash instead
/// of a random number generator. `Random()` never appears in this package:
/// a seeded PRNG would still be an implementation whose stream Dart does
/// not promise to keep stable across versions, whereas SHA-256 is frozen
/// by its specification.
List<int> dealOrder({required String seedBase, required int partySize}) {
  final order = List<int>.generate(partySize, (i) => i);
  for (var i = partySize - 1; i > 0; i--) {
    final j = stableIndex('$seedBase/swap/$i', i + 1);
    final held = order[i];
    order[i] = order[j];
    order[j] = held;
  }
  return order;
}
