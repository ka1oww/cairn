// SCREENS band (docs/architecture.md): knows app state and nothing below it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  const PasteScreen({super.key, this.initialText = ''});

  /// Refilled when the person comes back via "Paste something else" — the
  /// paste is kept, never thrown away.
  final String initialText;

  @override
  ConsumerState<PasteScreen> createState() => _PasteScreenState();
}

class _PasteScreenState extends ConsumerState<PasteScreen> {
  late final TextEditingController _controller;

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _paper,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Drop your itinerary here.',
                style: _serif.copyWith(
                  fontSize: 28,
                  height: 1.2,
                  color: _ink,
                  fontWeight: FontWeight.w400,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                "We'll split it into days for you.",
                style: _serif.copyWith(fontSize: 15, color: _muted),
              ),
              const SizedBox(height: 16),
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
                child: const Text('Read my plan'),
              ),
              const SizedBox(height: 8),
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
              // The second of design surface 6a's two doors. Most people
              // arrive here holding a code somebody told them rather than a
              // plan to paste, so the other door is on this screen and not
              // buried — bare, until the first-launch screen itself exists.
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
/// competing with the one green button above it.
class _SoftPill extends StatelessWidget {
  const _SoftPill({super.key, required this.label, required this.onPressed});

  final String label;
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
      child: Text(label),
    );
  }
}
