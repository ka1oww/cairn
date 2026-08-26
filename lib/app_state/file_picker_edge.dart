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
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    return PickedBytes(
      fileName: file.name,
      extension: file.extension?.toLowerCase(),
      bytes: bytes,
    );
  }
}

/// The test double: answers from a scripted list, in order, remembering what
/// it was asked for so a test can pin the picker filter too. A null entry is
/// a dismissal.
class FakeFilePicker implements FilePickerEdge {
  FakeFilePicker(this._answers);

  final List<PickedBytes?> _answers;
  var _next = 0;

  /// The extensions of the last [pick] call.
  Set<String>? lastAllowedExtensions;

  @override
  Future<PickedBytes?> pick({required Set<String> allowedExtensions}) async {
    lastAllowedExtensions = allowedExtensions;
    if (_next >= _answers.length) return null;
    return _answers[_next++];
  }
}

/// Bound to [DeviceFilePicker] for the app, and to a fake by tests through
/// bootstrapApp.
final filePickerEdgeProvider = Provider<FilePickerEdge>(
  (ref) => const DeviceFilePicker(),
);
