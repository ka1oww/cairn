// APP STATE band (docs/architecture.md), platform-edge side: Apple Vision's
// text recognition, behind a seam — the same shape as camera_source.dart.
// Everything above this file asks for the lines visible in some bytes and is
// handed them in reading order; nothing above it names Vision, a request
// revision, or a method channel.
//
// This is the file-import feature's OCR edge (the import plan §3, §6 slice
// D): a chat screenshot, a photographed printout, or a scanned PDF goes in
// and honest lines come out — lines the person sees land in the paste box,
// visibly, before the parser reads them, so recognition junk is fixable
// editor input and never a silent parse.
//
// **Judged on a device only** (the camera path's evidence rule, verbatim):
// the fake below makes the whole flow walkable in tests and on the
// Simulator, and neither a green suite nor a green simulator run is any
// evidence that recognition itself works. All automated tests bind the fake.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// How far through a multi-page read recognition has got: page 3 of 8.
typedef RecognitionProgress = void Function(int page, int pageCount);

/// One recognized read: every line of visible text, top-to-bottom, and how
/// many pages the bytes held. An empty [lines] is an honest answer — a
/// picture of a dog contains no text — not a failure.
class RecognizedScan {
  final List<String> lines;
  final int pageCount;

  const RecognizedScan({required this.lines, required this.pageCount});
}

/// The reader could not be used, or the bytes could not be read as a
/// picture at all. Carries a sentence a person could read.
class RecognitionRefused implements Exception {
  final String reason;
  const RecognitionRefused(this.reason);

  @override
  String toString() => 'RecognitionRefused: $reason';
}

/// Whatever can read the lines of text visible in some bytes.
abstract interface class TextRecognitionEdge {
  /// Reads every line of visible text out of [bytes] — a photograph, a
  /// screenshot, or a scanned PDF — ordered top-to-bottom. Reports
  /// multi-page progress through [onPage]. Throws [RecognitionRefused]
  /// when the bytes cannot be read at all.
  Future<RecognizedScan> recognize(Uint8List bytes, {RecognitionProgress? onPage});
}

/// The real one: a `VNRecognizeTextRequest` over the hand-written
/// `cairn/text_recognition` channel (ios/Runner/TextRecognition.swift).
///
/// Accurate mode and language correction are decided on the native side,
/// where Vision lives; this side only speaks lines and pages.
class DeviceTextRecognizer implements TextRecognitionEdge {
  const DeviceTextRecognizer();

  static const _channel = MethodChannel('cairn/text_recognition');

  @override
  Future<RecognizedScan> recognize(
    Uint8List bytes, {
    RecognitionProgress? onPage,
  }) async {
    // Native reports progress over the same channel while the read is in
    // flight; the handler lives exactly as long as the call does.
    if (onPage != null) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'onPage' && call.arguments is Map) {
          final args = call.arguments! as Map;
          onPage(args['page'] as int, args['of'] as int);
        }
        return null;
      });
    }
    try {
      final answer = await _channel.invokeMethod<Map<Object?, Object?>>(
        'recognizeLines',
        {'bytes': Uint8List.fromList(bytes)},
      );
      return RecognizedScan(
        lines: (answer?['lines'] as List<Object?>? ?? const [])
            .cast<String>()
            .toList(growable: false),
        pageCount: answer?['pages'] as int? ?? 1,
      );
    } on PlatformException catch (e) {
      throw RecognitionRefused(
        e.message ?? 'This device could not read that picture.',
      );
    } on MissingPluginException {
      // No channel host — a platform this feature does not run on.
      throw const RecognitionRefused(
        'This device cannot read text from pictures.',
      );
    } finally {
      if (onPage != null) _channel.setMethodCallHandler(null);
    }
  }
}

/// The test double: answers from a scripted list, in order, remembering the
/// bytes it was handed so a test can pin what reached recognition. A
/// [RecognitionRefused] entry refuses instead of answering; running past the
/// script refuses too, loudly enough to be a test bug rather than silence.
///
/// This fake is the *only* recognition the automated suite exercises — the
/// real channel is judged on a device (see the header).
class FakeTextRecognition implements TextRecognitionEdge {
  FakeTextRecognition(List<Object> answers) : _answers = answers;

  /// [RecognizedScan]s and [RecognitionRefused]s, in call order.
  final List<Object> _answers;
  var _next = 0;

  /// Every byte payload handed to [recognize], in order.
  final List<Uint8List> received = [];

  /// Set by a test to observe — or stall — the next recognition: it receives
  /// the progress reporter and its returned future is awaited before the
  /// scripted answer resolves. Reporting then awaiting a test-held completer
  /// is how the mid-read states become assertable.
  Future<void> Function(RecognitionProgress report)? beforeNextAnswer;

  @override
  Future<RecognizedScan> recognize(
    Uint8List bytes, {
    RecognitionProgress? onPage,
  }) async {
    received.add(Uint8List.fromList(bytes));
    final gate = beforeNextAnswer;
    beforeNextAnswer = null;
    if (gate != null) await gate(onPage ?? (_, _) {});
    if (_next >= _answers.length) {
      throw const RecognitionRefused('No scripted recognition answer.');
    }
    final answer = _answers[_next++];
    if (answer is RecognitionRefused) throw answer;
    return answer as RecognizedScan;
  }
}

/// Bound to [DeviceTextRecognizer] for the app, and to a fake by tests
/// through bootstrapApp.
final textRecognitionEdgeProvider = Provider<TextRecognitionEdge>(
  (ref) => const DeviceTextRecognizer(),
);
