import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

abstract interface class LinkOpenerEdge {
  Future<bool> open(Uri uri);
}

class DeviceLinkOpener implements LinkOpenerEdge {
  @override
  Future<bool> open(Uri uri) async {
    if (await launchUrl(uri, mode: LaunchMode.externalNonBrowserApplication)) {
      return true;
    }
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

class RecordingLinkOpener implements LinkOpenerEdge {
  Uri? lastUri;
  List<Uri> uris = [];

  @override
  Future<bool> open(Uri uri) async {
    lastUri = uri;
    uris.add(uri);
    return true;
  }
}

final linkOpenerEdgeProvider = Provider<LinkOpenerEdge>(
  (_) => throw UnimplementedError('bound by bootstrap'),
);
