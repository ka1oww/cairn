// APP STATE band (docs/architecture.md): the tap-to-Maps handoff.
//
// It owns none of the decisions. What a line searches for is
// `lib/logic/maps_handoff.dart`'s; which app it opens in is the person's,
// read from `device_prefs.dart`; opening it at all is the edge's. This is
// the wiring between the three, and it is deliberately thin enough that
// there is nowhere for a second rule to hide.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/maps_handoff.dart';
import 'day_view.dart';
import 'device_prefs.dart';
import 'link_opener_edge.dart';

class MapsHandoff {
  MapsHandoff(this._ref);
  final Ref _ref;

  /// Opens the search a whole row stands for: its words, plus its area.
  ///
  /// Returns false when there was nothing to search for — an inert row — so a
  /// caller never has to ask that question twice.
  Future<bool> openStop(DayStop stop) =>
      openSearch(searchText: stop.searchText, area: stop.area);

  /// Opens one place off a row that names several, in the area that row is
  /// standing in.
  Future<bool> openPlace(String place, {String? area}) =>
      openSearch(searchText: place, area: area);

  /// Opens the area itself — "just show me Asakusa", the answer to a stop
  /// whose name a maps app is unlikely to know.
  Future<bool> openArea(String area) =>
      openSearch(searchText: area, area: null);

  Future<bool> openSearch({required String? searchText, String? area}) async {
    final query = mapsQueryFor(searchText: searchText, area: area);
    if (query == null) return false;
    final app = await _ref.read(devicePrefsRepositoryProvider).readMapsApp();
    return _ref.read(linkOpenerEdgeProvider).open(mapsSearchUri(app, query));
  }
}

final mapsHandoffProvider = Provider<MapsHandoff>(MapsHandoff.new);
