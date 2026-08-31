// SCREENS band. The house design system's tokens, lifted verbatim from
// docs/design/README.md ("House system") and the drawn surfaces in the
// handoffs — the authority is the design record, and this file is its one
// transcription into Dart. A screen that needs a house colour takes it from
// here; a second spelling of any of these values is the thing to refuse in
// review.
//
// Paper is the ground every surface sits on; sticker is the raised card
// (the tab bar, the day's card); wash is the pressed/selected fill drawn
// throughout the handoffs (frame 5b's active tab, 15c's share card); ink and
// muted are the two text colours. Coral fills only the today-flag and one
// primary action per screen — never counts, never chrome.
import 'dart:ui';

/// `#FFF4E4` — the paper every screen is laid on.
const housePaper = Color(0xFFFFF4E4);

/// `#FFFDF8` — the sticker: raised cards and the tab bar's body.
const houseSticker = Color(0xFFFFFDF8);

/// `#43382C` — ink, the full-strength text and icon colour.
const houseInk = Color(0xFF43382C);

/// `#8C7B66` — muted, the quiet text and inactive-icon colour.
const houseMuted = Color(0xFF8C7B66);

/// `#F4623E` — coral. The today-flag and one primary action per screen only.
const houseCoral = Color(0xFFF4623E);

/// `#E9A13B` — amber.
const houseAmber = Color(0xFFE9A13B);

/// `#3E6795` — work blue.
const houseWorkBlue = Color(0xFF3E6795);

/// `#EFE3D2` — the wash: the selected/pressed fill on a sticker surface
/// (frame 5b's active tab pill, 15c's share card).
const houseWash = Color(0xFFEFE3D2);

/// `rgba(67,56,44,.14)` — the sticker's lift, as drawn on the tab bar
/// (`box-shadow: 0 1px 4px`).
const houseStickerShadow = Color(0x2443382C);

/// Atkinson Hyperlegible carries all running text in the house system
/// (Young Serif carries display). Bundled in `assets/fonts/`, declared in
/// `pubspec.yaml`.
const houseTextFamily = 'Atkinson Hyperlegible';
