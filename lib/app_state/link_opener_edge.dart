import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

abstract interface class LinkOpenerEdge {
  Future<bool> open(Uri uri);
}

// All three handoffs are keyless https universal links (google.com/maps/search,
// maps.apple.com/?q=, waze.com/ul?q=). Universal links need no
// LSApplicationQueriesSchemes and no canLaunchUrl check: iOS hands the https
// URL to the installed app if present, otherwise opens the web page. The
// plist entries for comgooglemaps/comgooglemapsios/waze are kept for a
// future canLaunchUrl-based "is installed?" check (e.g. to grey an option),
// not for the current open() path, which deliberately avoids custom schemes.
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
