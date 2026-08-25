// THE SEAM (docs/architecture.md): the only layer that knows storage
// backends exist. Above it, a provider asks "the trip's photos" and cannot
// tell — by construction — whether the answer came off disk or over the wire.
//
// **This file is the read side only.** Capture, the camera-roll sweep, the
// outbox and the `photos` row are the write path, and none of them is here.
// What is here is the shape the Pool reads through, so the screen above it
// can be built and tested before a single photo exists.
//
// It is an interface rather than a concrete class — the one place in this
// layer that is — because there is no store behind it yet. `TripRepository`
// is concrete because it has a Drift database to wrap; this has nothing to
// wrap until the capture slice lands its store, and an interface is how the
// screen gets built against the seam's shape rather than against a stand-in.
import 'package:cairn_model/cairn_model.dart';

/// One photo in the trip's shared pool, as the seam hands it up.
///
/// The [ref] is the domain's own word for a photo — which day it belongs to,
/// who contributed it, when it was taken. [localPath] is the one thing the
/// domain deliberately does not carry: **where the bytes are on this phone**,
/// when they are on this phone at all.
///
/// [localPath] being null is not a defect and not a loading state. The pool
/// is shared by eight people and stores originals
/// (`docs/decisions/2026-08-22-grill-round-one.md` §3); a photo somebody else
/// took is a real row in the index long before its bytes have been fetched
/// here. Today it is null for every photo, because nothing writes bytes yet.
class PooledPhoto {
  final PhotoRef ref;

  /// An absolute path to the image file on this device, or null when the
  /// bytes are not here.
  final String? localPath;

  const PooledPhoto({required this.ref, this.localPath});
}

/// The trip's shared photo pool, read-only.
///
/// One question, because the Pool asks one: every photo of the trip, in one
/// pool everyone can see. Grouping them by day is the app-state layer's job
/// (`lib/app_state/pool_view.dart`) and needs no second query — `PhotoRef`
/// already carries the day it was assigned to.
abstract interface class PhotoRepository {
  /// Every photo in the trip's pool, re-emitting when the pool changes.
  ///
  /// Unordered: what order a day's photos are shown in is
  /// `cairn_model.DayPool`'s rule, applied above this layer, so a store is
  /// never asked to remember it too.
  Stream<List<PooledPhoto>> watchTripPhotos();
}

/// The pool held in memory, which is where the whole pool lives until the
/// capture slice gives it a store.
///
/// Bound in `bootstrap.dart` with nothing in it — that is the honest state of
/// this app, and it is why the Pool tab opens on its empty state rather than
/// on invented tiles. Tests seed it to build the other state.
///
/// It emits once and completes, because nothing in this slice can change it.
/// A store-backed implementation re-emits after every write; that is the
/// interface's contract and what the screen above is written against.
class InMemoryPhotoPool implements PhotoRepository {
  InMemoryPhotoPool([Iterable<PooledPhoto> photos = const []])
      : _photos = List.unmodifiable(photos);

  final List<PooledPhoto> _photos;

  @override
  Stream<List<PooledPhoto>> watchTripPhotos() => Stream.value(_photos);
}
