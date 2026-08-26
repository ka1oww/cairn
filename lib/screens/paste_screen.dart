// SCREENS band (docs/architecture.md): knows app state and nothing below it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state/import_flow.dart';
import '../app_state/paste_flow.dart';
import 'join_screen.dart';

// The Cairn look, scoped to this screen: the round-4 design mock's tokens
// (paper, olive, coral family), applied here ahead of the app-wide theme
// pass the trail/capture screens still wait on. When that pass lands, these
// constants fold into it.
const _paper = Color(0xFFF7F6E8);
const _ink = Color(0xFF2A2A22);
const _muted = Color(0xFF6E6E5E);
const _olive = Color(0xFF5A6B2F);
const _oliveSoft = Color(0xFFE4E9D2);
const _boxFill = Color(0xFFFBFAF0);
const _coralSoft = Color(0xFFF7E3DC);
const _coralInk = Color(0xFF8F3B2D);

const _serif = TextStyle(
  fontFamily: 'Georgia',
  fontFamilyFallback: ['Times New Roman', 'serif'],
);

/// The realistic full-plan sample of design round 4's Screen 1: shown faded
/// as the empty box's ghost text so the expected shape teaches itself, and
/// filled in verbatim by "Try an example". One constant on purpose — the
/// example a person reads and the example the button submits must be the
/// same plan.
const sampleItinerary = '''
Day 1 - Tokyo
Land at Haneda, drop bags in Shinjuku
Meiji Shrine walk
Omoide Yokocho for dinner

Day 2 - Tokyo
TeamLab Planets 11am
Asakusa and Senso-ji
Golden Gai at night

Day 3 - Hakone
Romancecar from Shinjuku 9:05am
Open-Air Museum
Onsen stay by Lake Ashi

Day 4 - Kyoto
Shinkansen to Kyoto
Fushimi Inari at dusk

Day 5 - Kyoto
Arashiyama bamboo grove
Kinkaku-ji
Night bus to the airport''';

/// The paste box that teaches (design round 4, Screen 1): the whole-plan
/// headline, a believable five-day ghost sample, one green button, and two
/// soft pills under it. Everything interesting still happens on the screen
/// after it.
class PasteScreen extends ConsumerStatefulWidget {
  const PasteScreen({
    super.key,
    this.initialText = '',
    this.repastingLivePlan = false,
  });

  /// Refilled when the person comes back via "Back to the paste" — the paste
  /// is kept, never thrown away — and pre-filled with a running trip's own
  /// plan, said back as text, on a re-paste.
  final String initialText;

  /// True when this box was opened over a running trip. Reading it merges
  /// into that trip rather than replacing it, so the screen says so and
  /// swaps the first-timer's doors for the way back to the editor: an
  /// example plan or a blank hand-built day would both be answers to a
  /// question nobody asked here.
  final bool repastingLivePlan;

  @override
  ConsumerState<PasteScreen> createState() => _PasteScreenState();
}

class _PasteScreenState extends ConsumerState<PasteScreen> {
  late final TextEditingController _controller;

  /// Provenance from the last import ("Read 3 of 8 pages") — shown above the
  /// box until the next import, because a partial read is a success the
  /// person may want to know about while they fix it in the editor.
  String? _importNote;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _read() {
    ref.read(pasteFlowProvider.notifier).parse(_controller.text);
  }

  /// The import door (the import plan §2.5): the file's text lands in the
  /// box, visibly, and the same green button reads it — one extra tap that
  /// buys the person a look at exactly what came out of their file before
  /// the parser sees it. Refusals never reach here; they live in the flow's
  /// state and show as the error card.
  Future<void> _importFile() async {
    setState(() => _importNote = null);
    final done = await ref.read(importFlowProvider.notifier).pickAndExtract();
    if (!mounted || done == null) return;
    setState(() {
      _controller.text = done.text;
      _importNote = done.notes.isEmpty ? null : done.notes.join(' ');
    });
  }

  void _fillExample() {
    _controller.text = sampleItinerary;
  }

  // The hand-building entrance. The real destination is Screen 4's editor
  // starting empty; until that slice lands, the seam is deliberately this
  // thin — a one-header parse drops the person on the existing confirm
  // screen holding a single empty day, and the editor slice replaces only
  // what this line hands over.
  void _buildByHand() {
    ref.read(pasteFlowProvider.notifier).parse('Day 1');
  }

  /// The import's two soft surfaces above the box (the import plan §2.6):
  /// the refusal card — dismissible, never a dead end, the box and every
  /// other door staying usable underneath — and the partial-read note.
  /// Empty when there is nothing to say.
  List<Widget> _importFeedback(ImportState importState) {
    if (importState is ImportFailed) {
      return [
        const SizedBox(height: 12),
        Card(
          key: const Key('import-error'),
          color: _coralSoft,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    importState.explanation,
                    style: const TextStyle(fontSize: 13.5, color: _coralInk),
                  ),
                ),
                IconButton(
                  key: const Key('import-error-dismiss'),
                  icon: const Icon(Icons.close, size: 18),
                  color: _coralInk,
                  tooltip: 'Dismiss',
                  onPressed: () {
                    setState(() => _importNote = null);
                    ref.read(importFlowProvider.notifier).dismiss();
                  },
                ),
              ],
            ),
          ),
        ),
      ];
    }
    if (_importNote != null) {
      return [
        const SizedBox(height: 8),
        Text(
          _importNote!,
          key: const Key('import-note'),
          style: const TextStyle(fontSize: 13, color: _muted),
        ),
      ];
    }
    // Nothing to say: still hold the screen's original 16 px gap between the
    // subhead and the box, which the feedback branches take the place of.
    return const [SizedBox(height: 16)];
  }

  @override
  Widget build(BuildContext context) {
    final repasting = widget.repastingLivePlan;
    final importState = ref.watch(importFlowProvider);
    return Scaffold(
      backgroundColor: _paper,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                repasting ? 'Your plan, as text.' : 'Drop your itinerary here.',
                key: const Key('paste-headline'),
                style: _serif.copyWith(
                  fontSize: 28,
                  height: 1.2,
                  color: _ink,
                  fontWeight: FontWeight.w400,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                repasting
                    ? 'Edit it and read it again. What you change is merged '
                          'into the trip — nothing is thrown away.'
                    : "We'll split it into days for you.",
                key: const Key('paste-subhead'),
                style: _serif.copyWith(fontSize: 15, color: _muted),
              ),
              ..._importFeedback(importState),
              Expanded(
                child: TextField(
                  key: const Key('paste-input'),
                  controller: _controller,
                  maxLines: null,
                  minLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(fontSize: 14, color: _ink),
                  decoration: InputDecoration(
                    // The ghost sample: a real full plan, fading as you type.
                    hintText: sampleItinerary,
                    hintStyle: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: _muted.withValues(alpha: 0.55),
                    ),
                    filled: true,
                    fillColor: _boxFill,
                    contentPadding: const EdgeInsets.all(14),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _olive, width: 1.5),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _olive, width: 2),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // The one green button. Everything else on the screen stays
              // visually secondary to it.
              FilledButton(
                key: const Key('read-button'),
                onPressed: _read,
                style: FilledButton.styleFrom(
                  backgroundColor: _olive,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(48),
                  shape: const StadiumBorder(),
                  textStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: Text(repasting ? 'Read it again' : 'Read my plan'),
              ),
              const SizedBox(height: 8),
              // The file door, in both modes (the import plan §2.6): on a
              // first paste it fills an empty box; on a re-paste it replaces
              // the pre-filled plan text and "Read it again" merges. Progress
              // takes the pill's place inline — no modal, no blocked box.
              if (importState is ImportReading)
                _ImportProgress(name: importState.fileName)
              else
                _SoftPill(
                  key: const Key('import-pill'),
                  label: 'Import a file',
                  sublabel: supportedFormatsLabel,
                  onPressed: _importFile,
                ),
              const SizedBox(height: 8),
              if (repasting)
                TextButton(
                  key: const Key('cancel-repaste'),
                  onPressed: () =>
                      ref.read(pasteFlowProvider.notifier).cancelRepaste(),
                  style: TextButton.styleFrom(foregroundColor: _muted),
                  child: const Text('Back to the editor'),
                )
              else ...[
                Row(
                  children: [
                    Expanded(
                      child: _SoftPill(
                        key: const Key('try-example'),
                        label: 'Try an example',
                        onPressed: _fillExample,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _SoftPill(
                        key: const Key('build-by-hand'),
                        label: 'Build it by hand',
                        onPressed: _buildByHand,
                      ),
                    ),
                  ],
                ),
              ],
              // The second of design surface 6a's two doors. Most people
              // arrive here holding a code somebody told them rather than a
              // plan to paste, so the other door is on this screen and not
              // buried — bare, until the first-launch screen itself exists.
              // It stays on the re-paste too: unlike the two pills above, it
              // neither clobbers the pre-filled plan nor reads it, it only
              // opens a route, and it is the app's only way to the second
              // door once a trip is running.
              TextButton(
                key: const Key('join-door'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) => const JoinScreen(),
                  ),
                ),
                style: TextButton.styleFrom(foregroundColor: _muted),
                child: const Text('I have an invite'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A soft secondary pill: olive-tinted, full finger height (min 44pt), never
/// competing with the one green button above it. An optional [sublabel]
/// renders a second, quieter line — the import pill names its formats there.
class _SoftPill extends StatelessWidget {
  const _SoftPill({
    super.key,
    required this.label,
    required this.onPressed,
    this.sublabel,
  });

  final String label;
  final String? sublabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonal(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: _oliveSoft,
        foregroundColor: _olive,
        minimumSize: const Size.fromHeight(44),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      child: sublabel == null
          ? Text(label)
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label),
                Text(
                  sublabel!,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
    );
  }
}

/// Import progress, drawn inline in the pill's place: what is being read,
/// and that something is happening — no modal over the screen.
class _ImportProgress extends StatelessWidget {
  const _ImportProgress({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('import-progress'),
      height: 44,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            'Reading $name…',
            style: const TextStyle(
              fontSize: 13,
              color: _muted,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}
