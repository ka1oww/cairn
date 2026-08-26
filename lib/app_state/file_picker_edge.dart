// APP STATE band (docs/architecture.md), platform-edge side: the document
// picker, behind a seam — the same shape as camera_source.dart. Everything
// above this file asks for one picked file and is handed its bytes; nothing
// above it names a plugin, a UTType, or Files.app.
//
// The real edge uses the native iOS document picker (`file_picker`), so
// iCloud Drive and third-party file providers work with no custom browsing
// UI; picks are copied into the sandbox and read into memory here, which is
// why no band above ever touches a path. The fake answers from memory, so
// the whole import flow walks in tests without a device.
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plan_extraction/plan_extraction.dart';

/// Whatever can hand the app one picked file's bytes.
abstract interface class FilePickerEdge {
  /// Opens the platform document picker limited to [allowedExtensions]
  /// (lowercased, no dots). Returns null when the person dismissed it —
  /// an ordinary answer, never an error.
  Future<PickedBytes?> pick({required Set<String> allowedExtensions});

  /// Opens the photo library limited to still images — the screenshots
  /// door (the import plan §2.6's second row). Same contract as [pick]:
  /// null is a dismissal. iOS presents PHPicker, which asks for no
  /// permission; picks are copied into the sandbox like document picks.
  Future<PickedBytes?> pickImage();
}

/// The real one: the native document picker over `file_picker`.
class DeviceFilePicker implements FilePickerEdge {
  const DeviceFilePicker();

  @override
  Future<PickedBytes?> pick({required Set<String> allowedExtensions}) async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: allowedExtensions.toList(),
    );
    return _toPicked(file);
  }

  @override
  Future<PickedBytes?> pickImage() async {
    final file = await FilePicker.pickFile(type: FileType.image);
    return _toPicked(file);
  }

  Future<PickedBytes?> _toPicked(PlatformFile? file) async {
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    return PickedBytes(
      fileName: file.name,
      extension: file.extension?.toLowerCase(),
      bytes: bytes,
    );
  }
}

/// The test double: answers from scripted lists, in order, remembering what
/// it was asked for so a test can pin the picker filter too. A null entry
/// is a dismissal. The two doors script separately — a test pins *which*
/// door opened as well as what came through it.
class FakeFilePicker implements FilePickerEdge {
  /// The positional answers reply to [pick] in order; [imageAnswers] reply
  /// to [pickImage]. Either list may be empty.
  FakeFilePicker(
    this._answers, {
    this.imageAnswers = const [],
  });

  final List<PickedBytes?> _answers;

  /// Answers for [pickImage], in order.
  final List<PickedBytes?> imageAnswers;

  var _next = 0;
  var _nextImage = 0;

  /// The extensions of the last [pick] call.
  Set<String>? lastAllowedExtensions;

  /// How many times each door was opened.
  int documentPicks = 0;
  int imagePicks = 0;

  @override
  Future<PickedBytes?> pick({required Set<String> allowedExtensions}) async {
    lastAllowedExtensions = allowedExtensions;
    documentPicks++;
    if (_next >= _answers.length) return null;
    return _answers[_next++];
  }

  @override
  Future<PickedBytes?> pickImage() async {
    imagePicks++;
    if (_nextImage >= imageAnswers.length) return null;
    return imageAnswers[_nextImage++];
  }
}

/// Bound to [DeviceFilePicker] for the app, and to a fake by tests through
/// bootstrapApp.
final filePickerEdgeProvider = Provider<FilePickerEdge>(
  (ref) => const DeviceFilePicker(),
);
