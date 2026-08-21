import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The number of digest bytes read by [stableDigestValue]: 6 bytes, 48 bits.
///
/// Not the full 32-byte digest, and deliberately not 8 bytes. Dart compiled
/// to JavaScript represents `int` as a double, which is exact only up to
/// 2^53. A 64-bit value would be correct on the Dart VM and silently lose
/// precision on web, so two phones on the same trip would derive different
/// schedules depending on which backend built the app. 48 bits stays exact
/// on every backend while still giving ~2.8e14 distinct values, far more
/// resolution than choosing a minute of the day needs.
const int _digestBytesRead = 6;

/// `2^48 - 1`, spelled out as a literal on purpose.
///
/// Writing it as `(1 << 48) - 1` evaluates to `281474976710655` on the
/// Dart VM and to `-1` under dart2js, whose `int` bitwise operators are
/// specified as 32-bit. Both figures are reproduced, not recalled -- see
/// the table on [stableDigestValue].
const int _max48 = 281474976710655;

/// Turns a string seed into a deterministic integer in `[0, 2^48)`.
///
/// This is the single point in the package where "same input -> same
/// output, on every device, forever" has to hold. Everything else --
/// which slot a person gets, which minute inside it, which days have
/// slots at all -- is integer arithmetic layered on top of this one
/// function. It is deliberately simple and deliberately frozen:
///
///  * Hash algorithm: SHA-256 ([sha256] from `package:crypto`), a spec'd
///    algorithm with no platform- or version-dependent behaviour -- unlike
///    [Object.hashCode] or [Object.hash], which Dart explicitly does not
///    guarantee to be stable across runs, isolates, or versions.
///  * Input encoding: UTF-8 bytes of the seed string, via [utf8.encode].
///  * Output: the first [_digestBytesRead] bytes of the digest, read as a
///    big-endian unsigned integer.
///
/// **The arithmetic matters as much as the byte count.** This accumulates
/// with multiplication and addition (`value * 256 + byte`), never a
/// bitwise `<<`/`|`. dart2js specifies `int` bitwise operators as 32-bit,
/// so a shift-based accumulation of 48 bits silently truncates on web
/// while working fine on the VM -- exactly the divergence this function
/// exists to prevent, and a bug this file has actually shipped before.
///
/// Accumulating the six bytes `DE AD BE EF 12 34` both ways, compiled for
/// each backend, gives:
///
/// ```text
///                      Dart VM            dart2js / Node
///   (value << 8) | b   244837814047284    3203338804   <- truncated
///   value * 256 + b    244837814047284    244837814047284
/// ```
///
/// Multiplication and addition stay exact on every backend as long as the
/// values stay under 2^53, which 48 bits does by two orders of magnitude.
///
/// `test/golden_values_test.dart` pins the output of this function against
/// values cross-checked on a dart2js build. Do not "simplify" the
/// arithmetic back to shifts; see the package README, "What must never
/// change".
int stableDigestValue(String seed) {
  final bytes = sha256.convert(utf8.encode(seed)).bytes;
  var value = 0;
  for (var i = 0; i < _digestBytesRead; i++) {
    value = value * 256 + bytes[i];
  }
  return value;
}

/// The largest value [stableDigestValue] can return, `2^48 - 1`.
int get stableDigestMax => _max48;

/// A deterministic integer in `[0, bound)`, derived from [seed].
///
/// This is the only way the package turns a hash into a choice: which
/// member takes a slot, which minute inside that slot. Both are small
/// integer choices, so the derivation stays in integers end to end and
/// never has to round a float into a time -- one less place for two
/// backends to disagree by a microsecond.
///
/// Modulo introduces a bias of at most `bound / 2^48` towards the low
/// values, which for a party of eight is about one part in 10^14. That is
/// far below any bias that could be observed over the length of a trip,
/// and rejection sampling to remove it would cost the property that
/// matters more here: a fixed, obvious, auditable number of hash calls per
/// decision.
///
/// [bound] must be positive.
int stableIndex(String seed, int bound) {
  if (bound <= 0) {
    throw ArgumentError.value(bound, 'bound', 'must be positive');
  }
  return stableDigestValue(seed) % bound;
}

/// A short, stable fingerprint of [parts], for use inside a seed string.
///
/// Seeds are built by concatenation, so an unbounded input (a party of
/// forty member ids) would make an unbounded seed. Hashing the variable
/// part down to a fixed 16 hex characters keeps seeds a predictable size
/// without weakening the derivation: the fingerprint still changes
/// whenever any member id changes.
///
/// Parts are joined with a newline, which cannot appear in a UUID, so
/// `['ab', 'c']` and `['a', 'bc']` cannot collide by concatenation.
String stableFingerprint(Iterable<String> parts) {
  final digest = sha256.convert(utf8.encode(parts.join('\n')));
  return digest.toString().substring(0, 16);
}
