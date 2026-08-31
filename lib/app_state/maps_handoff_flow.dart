import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/maps_handoff.dart';
import 'day_view.dart';
import 'device_prefs.dart';
import 'link_opener_edge.dart';

class MapsHandoff {
  MapsHandoff(this._ref);
  final Ref _ref;

  Future<bool> openStop(DayStop stop) async {
    if (stop.kind == StopLineKind.inert) return false;
    final pref = await _currentMapsApp();
    final classified = ClassifiedStop(
      kind: stop.kind,
      mealLabel: stop.mealLabel,
      query: _queryFor(stop),
      places: stop.places,
    );
    // Multi-place short tap opens area alone, per plan §6.2 C
    if (stop.places.length > 1 && stop.area != null) {
      final uri = areaSearchUri(area: stop.area!, app: pref);
      return _ref.read(linkOpenerEdgeProvider).open(uri);
    }
    final uri = mapsSearchUri(stop: classified, area: stop.area, app: pref);
    if (uri == null) return false;
    return _ref.read(linkOpenerEdgeProvider).open(uri);
  }

  Future<bool> openPlace(String place, {String? area}) async {
    final pref = await _currentMapsApp();
    final uri = placeSearchUri(place: place, area: area, app: pref);
    return _ref.read(linkOpenerEdgeProvider).open(uri);
  }

  Future<bool> openArea(String area) async {
    final pref = await _currentMapsApp();
    final uri = areaSearchUri(area: area, app: pref);
    return _ref.read(linkOpenerEdgeProvider).open(uri);
  }

  Future<MapsApp> _currentMapsApp() async {
    try {
      final repo = _ref.read(devicePrefsRepositoryProvider);
      final raw = await repo.readMapsApp();
      return mapsAppFromString(raw);
    } catch (_) {
      return MapsApp.googleMaps;
    }
  }

  String _queryFor(DayStop stop) {
    // DayStop.text is the raw line; classifier query may be derived differently.
    // Better to derive via classifier on text, but we already have kind.
    // Use text stripped of meal label via classifier logic would be more accurate.
    // Instead, derive query by classifying stop.text fresh (so meal label stripped).
    final c = classifyStopLine(stop.text);
    if (c.kind == StopLineKind.inert) return stop.text;
    return c.query;
  }
}

final mapsHandoffProvider = Provider<MapsHandoff>(MapsHandoff.new);
