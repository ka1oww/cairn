// Prints the exact values pinned by test/golden_values_test.dart, so the
// cross-platform claim in the README is a command anyone can re-run rather
// than folklore:
//
//   dart run tool/print_goldens.dart > /tmp/vm.txt
//   dart compile js -O0 -o /tmp/goldens.js tool/print_goldens.dart
//   node /tmp/goldens.js > /tmp/js.txt
//   diff /tmp/vm.txt /tmp/js.txt
//
// An empty diff is the proof: the Dart VM and dart2js derive byte-for-byte
// identical schedules, so two people on the same trip cannot be split by
// which backend built their app. A non-empty diff means someone has
// reintroduced a construct dart2js implements differently -- almost always
// a bitwise operator in the hash. See lib/src/stable_hash.dart.
//
// Both this file and the golden test read the same goldenLines(), so what
// is verified here and what is pinned there cannot drift apart.

import '../test/golden_fixture.dart';

void main() {
  goldenLines().forEach(print);
}
