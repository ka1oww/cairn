// APP STATE band (docs/architecture.md): the pending import's rules.
//
// **The defect this closes** (the import torture-test's R6): an imported but
// not-yet-accepted plan died with the process. Someone who fought a
// three-page scan through text recognition lost the whole result to an
// incoming call, because the box was memory and nothing else.
//
// The rules, all four of them, live here and nowhere else:
//
//  - **An import starts a draft.** Nothing else does — not the example plan,
//    not "build it by hand", not a plan typed from scratch. The draft exists
//    because recognition and extraction are expensive to redo; typing is
//    not, and a box that quietly remembered every keystroke would be a
//    different feature with a different question to answer.
//  - **While it stands, it tracks the box.** Every edit the person makes to
//    imported text updates it ([keepInStep]), so a restored draft can never
//    be older than what they last had in front of them. This is what makes
//    "it must never silently resurrect over something the person has since
//    typed by hand" true by construction rather than by a timestamp.
//  - **Emptying the box forgets it.** Clearing what was imported is how a
//    person discards an import; there is no other discard gesture on that
//    screen, and inventing one would be a button nobody asked for.
//  - **Accepting the plan forgets it.** The text has become the trip
//    (`PasteFlow.accept`), so the draft has nothing left to protect.
//
// And one rule that is a *restore* rule, held by the paste screen because it
// is the only thing that knows what is in the box: a draft is only ever put
// back into a box that would otherwise open empty. It never lands over a
// re-paste's pre-filled plan text, and never over a character the person has
// typed while the read was in flight.
//
// Deliberately no expiry. An hour, a week and a month are all product
// policies about when to destroy the person's own text, and the tracking
// rule above already makes an old draft harmless: it is only ever offered
// into an empty box, and it always says what the box last said.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repositories/plan_draft_repository.dart';

/// Bound to the real repository by the composition root (`bootstrap.dart`),
/// and to a fake by a test that wants one. Left unbound it throws, loudly.
final planDraftRepositoryProvider = Provider<PlanDraftRepository>(
  (ref) => throw UnimplementedError(
    'planDraftRepositoryProvider is bound in bootstrap.dart (or a test '
    'override)',
  ),
);

/// The pending import, as the screens and the paste flow speak to it.
final planDraftProvider = Provider<PlanDraft>(
  (ref) => PlanDraft(ref.watch(planDraftRepositoryProvider)),
);

class PlanDraft {
  const PlanDraft(this._store);

  final PlanDraftRepository _store;

  /// What to put back into an empty box, or null when there is nothing.
  Future<String?> read() => _store.read();

  /// An import landed: remember it, replacing whatever the last one left.
  Future<void> remember(String text) => _store.write(text);

  /// The box changed. A draft that stands follows it; an empty box forgets
  /// it; a box that never held an import is left alone.
  Future<void> keepInStep(String text) => text.trim().isEmpty
      ? _store.clear()
      : _store.overwriteIfPresent(text);

  /// The draft has done its job, or been given up on.
  Future<void> forget() => _store.clear();
}
