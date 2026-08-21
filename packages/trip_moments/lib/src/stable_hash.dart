import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Turns a string seed into a deterministic value in `[0, 1)`.
///
/// This is the single point in the package where "same input -> same
/// output, on every device, forever" has to hold. It is deliberately
/// simple and deliberately frozen:
///
///  * Hash algorithm: SHA-256 ([sha256] from `package:crypto`), a spec'd
///    algorithm with no platform- or version-dependent behaviour — unlike
///    [Object.hashCode] or [Object.hash], which Dart explicitly does not
///    guarantee to be stable across runs, isolates, or versions.
///  * Input encoding: UTF-8 bytes of the seed string, via [utf8.encode].
///  * Output: the first 6 bytes (48 bits) of the digest, read as a
///    big-endian unsigned integer, divided by `2^48 - 1`.
///
/// 48 bits (not the full 64/256) is a deliberate choice for portability:
/// Dart compiled to JavaScript (web) represents `int` as a double and can
/// only exactly represent integers up to 2^53. Using 64 bits would work on
/// the Dart VM but silently lose precision — and therefore diverge — on
/// web. 48 bits keeps the *value* exact on every backend (VM, AOT, and
/// web) while still giving ~2.8e14 distinct buckets, far more than enough
/// resolution for scheduling a time of day.
///
/// The arithmetic to get there matters as much as the bit count: this
/// deliberately uses multiplication/addition (`value * 256 + byte`), not
/// bitwise `<<`/`|`. dart2js's bitwise int operators are specified as
/// 32-bit, so a shift-based accumulation silently truncates on web while
/// working fine on the VM — exactly the kind of divergence this function
/// exists to prevent. Multiplication and addition on `int`/`double` stay
/// exact up to 2^53 on every backend, so this form gives the same result
/// everywhere. Likewise `max48` is written as the literal
/// `281474976710655` (2^48 - 1) rather than computed with `(1 << 48) - 1`,
/// which evaluates to `0` under dart2js's 32-bit shift.
///
/// See the package README ("What must never change") for the full list of
/// things that would silently split devices into disagreeing groups if
/// changed after the app has shipped, and "Verified cross-platform" for
/// how this guarantee is actually tested.
double stableUnitInterval(String seed) {
  final digest = sha256.convert(utf8.encode(seed));
  final bytes = digest.bytes;
  var value = 0;
  for (var i = 0; i < 6; i++) {
    value = value * 256 + bytes[i];
  }
  const max48 = 281474976710655; // 2^48 - 1, spelled out — see doc comment.
  return value / max48;
}
