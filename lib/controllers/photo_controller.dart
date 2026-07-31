import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import '../services/app_directories.dart';

import '../config/app_config.dart';
import '../models/photo_manifest.dart';
import '../services/backend_client.dart';
import 'polling_controller.dart';

/// Owns the photo lifecycle: poll the manifest, sync the on-disk cache, and
/// advance the currently-displayed image on a dwell timer.
///
/// This is the memory-critical controller (Phase 3). Two disciplines:
///   1. On-disk cache is bounded to exactly the manifest — files dropped from
///      the manifest are deleted from disk.
///   2. The outgoing decoded image is evicted from Flutter's ImageCache on every
///      transition, and only the *next* image is precached — never the whole set.
///
/// Pinning holds one photo on screen indefinitely. It has two sources that must
/// coexist without fighting each other:
///   * the backend, via `"pinned": true` on a manifest entry (set by a
///     `pinphoto:` email), and
///   * a click on the photo itself, which is device-local.
///
/// The rule: a *change* in what the manifest says wins, because it's a fresh
/// instruction from a human. An unchanged manifest never re-asserts itself, so
/// someone standing at the screen can override the backend's pin and have it
/// stick until the backend actually changes its mind.
///
/// Deleting a photo from the stage is deliberately *not* a backend call: it
/// hides the file from this device's rotation only, persisted locally so it
/// survives a reboot. The manifest, R2, and every other kiosk are untouched —
/// this is "stop showing me that one here," not "take it down for everyone."
/// A hidden name is dropped the moment the backend's own manifest stops
/// listing it, so the local list never outlives the photo it refers to.
class PhotoController extends PollingController {
  final AppConfig config;
  final BackendClient client;

  /// Called with the size of a batch of newly downloaded photos. Not called for
  /// the first sync of the session. Wired to the celebration overlay.
  final void Function(int count)? onPhotosArrived;

  PhotoController({
    required this.config,
    required this.client,
    this.onPhotosArrived,
  });

  @override
  Duration get interval => client.jittered(AppConfig.manifestPollInterval);

  Directory? _cacheDir;
  File? _hiddenFile;
  String _lastHash = '';

  /// Filenames hidden from this device's rotation by a tap on the stage.
  /// Lives outside [_cacheDir] — that directory's contents are pruned to
  /// exactly the manifest (see [_sync]), which would otherwise delete this
  /// bookkeeping file the moment it wasn't itself a listed photo.
  Set<String> _hidden = {};

  /// Whether a sync has completed this session. The first one is the board
  /// filling an empty cache after a reboot, not photos "arriving".
  bool _syncedOnce = false;

  /// Files (basenames) currently present on disk and known-good, in manifest order.
  List<String> _available = const [];
  int _index = 0;
  Timer? _dwell;

  /// The photo held on screen, or null when rotating normally. This is the
  /// effective pin, whatever its source.
  String? _pinned;

  /// What the last synced manifest asked for, so we can tell a *new* backend
  /// instruction apart from the same one arriving again on the next poll.
  String? _lastManifestPin;

  /// The file currently on screen, or null before the first sync completes.
  File? get currentFile =>
      _available.isEmpty ? null : File('${_cacheDir!.path}/${_available[_index]}');

  bool get hasPhotos => _available.isNotEmpty;

  /// Position of the photo on screen within the rotation, and how many there
  /// are — for the on-screen "4 / 12" counter.
  int get index => _index;
  int get count => _available.length;

  /// Whether the photo on screen is being held rather than rotating.
  bool get isPinned => _pinned != null;

  /// Step the rotation by hand. The dwell timer restarts from zero, so a photo
  /// someone just chose gets a full window rather than the tail of the previous
  /// one.
  ///
  /// Stepping while pinned moves the pin along with it: "hold this one" stays
  /// true, it's just a different one. Unpinning is the pin button's job.
  void next() => _step(1);
  void previous() => _step(-1);

  void _step(int delta) {
    if (_available.length <= 1) return;
    final outgoing = currentFile;
    _index = (_index + delta) % _available.length;
    if (_index < 0) _index += _available.length;
    if (_pinned != null) _pinned = _available[_index];
    safeNotify();

    // Same memory discipline as the automatic advance.
    if (outgoing != null) FileImage(outgoing).evict();
    PaintingBinding.instance.imageCache.clearLiveImages();
    _startDwell();
    // While pinned the dwell timer stays off, so _startDwell bails before it
    // warms the neighbour — do it here, since someone stepping by hand is
    // likely to step again.
    if (_pinned != null) _precacheNext();
  }

  /// Hold the current photo on screen, or release it back into rotation.
  /// No-op before the first sync, when there's nothing to pin.
  void togglePin() {
    if (_available.isEmpty) return;
    _pinned = _pinned == null ? _available[_index] : null;
    safeNotify();
    _applyPin();
  }

  /// Drop the photo on screen from this device's rotation, permanently (until
  /// the backend itself stops listing it — see [_sync]). Nothing is sent
  /// upstream: other kiosks, R2, and the manifest are unaffected. No-op before
  /// the first sync.
  void hideCurrent() {
    if (_available.isEmpty) return;
    final file = _available[_index];
    _hidden.add(file);
    _saveHidden();

    final outgoing = currentFile;
    _available = List.of(_available)..removeAt(_index);
    if (_index >= _available.length) _index = 0;
    if (_pinned == file) _pinned = null;

    safeNotify();
    if (outgoing != null) FileImage(outgoing).evict();
    PaintingBinding.instance.imageCache.clearLiveImages();
    _applyPin(); // restarts the dwell timer (or stays parked on a remaining pin)
  }

  Future<Directory> _dir() async {
    if (_cacheDir != null) return _cacheDir!;
    final base = await AppDirectories.support();
    final dir = Directory('${base.path}/photo_cache');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _cacheDir = dir;
    _hiddenFile = File('${base.path}/hidden_photos.json');
    _loadHidden();
    return dir;
  }

  /// Read the hidden-filename list, if any. A missing or corrupt file is the
  /// same as an empty one — this is a convenience list, not source of truth.
  void _loadHidden() {
    final f = _hiddenFile;
    if (f == null || !f.existsSync()) return;
    try {
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is List) _hidden = decoded.whereType<String>().toSet();
    } catch (_) {
      // Corrupt file — start clean rather than crash the display.
    }
  }

  void _saveHidden() {
    final f = _hiddenFile;
    if (f == null) return;
    try {
      f.writeAsStringSync(jsonEncode(_hidden.toList()));
    } catch (_) {
      // Best-effort: worst case a hidden photo reappears next boot.
    }
  }

  @override
  Future<void> poll({bool force = false}) async {
    final result = await client.getJson(config.manifestUri, bypassCache: force);
    if (result.notModified) return; // 304 — nothing changed, do no work

    final manifest = PhotoManifest.fromJson(result.json!);
    if (manifest.hash == _lastHash && _available.isNotEmpty && !force) return;

    await _sync(manifest);
    _lastHash = manifest.hash;
  }

  /// Download new files, delete files no longer listed, then refresh rotation.
  Future<void> _sync(PhotoManifest manifest) async {
    final dir = await _dir();
    final wanted = manifest.photos.map((p) => p.file).toSet();

    // A hidden name only makes sense while the backend still lists the photo
    // it refers to — once pruned there, forget it too, so the local list
    // can't grow forever.
    if (_hidden.any((h) => !wanted.contains(h))) {
      _hidden = _hidden.intersection(wanted);
      _saveHidden();
    }

    // Delete anything on disk that's no longer in the manifest.
    for (final entity in dir.listSync()) {
      if (entity is File) {
        final name = entity.uri.pathSegments.last;
        if (!wanted.contains(name)) {
          try {
            entity.deleteSync();
            FileImage(entity).evict(); // drop any decoded copy too
          } catch (_) {/* best-effort cleanup */}
        }
      }
    }

    // Download files we don't have yet.
    var fetched = 0;
    for (final entry in manifest.photos) {
      final f = File('${dir.path}/${entry.file}');
      if (f.existsSync() && f.lengthSync() == entry.bytes) continue;
      try {
        final bytes = await client.getBytes(config.photoUri(entry.file));
        await f.writeAsBytes(bytes, flush: true);
        fetched++;
      } catch (e) {
        // Skip a bad download; keep going. We'll retry on the next poll.
        debugPrint('[PhotoController] failed to fetch ${entry.file}: $e');
      }
    }

    // Rebuild the rotation list from what actually made it to disk, in order —
    // minus anything hidden locally.
    _available = manifest.photos
        .map((p) => p.file)
        .where((name) => File('${dir.path}/$name').existsSync())
        .where((name) => !_hidden.contains(name))
        .toList(growable: false);

    if (_index >= _available.length) _index = 0;

    // Adopt the manifest's pin only when it differs from the one we saw last
    // sync — see the class doc. Re-asserting an unchanged pin every poll would
    // stomp a local click within five minutes.
    final manifestPin = manifest.pinnedFile;
    if (manifestPin != _lastManifestPin) {
      _lastManifestPin = manifestPin;
      _pinned = manifestPin;
    }
    // A pinned photo can still disappear (pruned, or its download failed).
    // Drop the pin rather than freezing on a file we can't show.
    if (_pinned != null && !_available.contains(_pinned)) _pinned = null;

    safeNotify();
    _applyPin();

    // Announce the batch, but never the one that fills an empty cache on boot.
    if (_syncedOnce && fetched > 0) onPhotosArrived?.call(fetched);
    _syncedOnce = true;
  }

  /// Point the rotation at the pinned photo and stop the dwell timer, or resume
  /// rotation when nothing is pinned. Safe to call whenever the pin changes.
  void _applyPin() {
    if (_pinned != null) {
      final at = _available.indexOf(_pinned!);
      if (at >= 0 && at != _index) {
        final outgoing = currentFile;
        _index = at;
        safeNotify();
        if (outgoing != null) FileImage(outgoing).evict();
        PaintingBinding.instance.imageCache.clearLiveImages();
      }
    }
    _startDwell();
  }

  /// Begin (or restart) the timer that advances to the next photo.
  void _startDwell() {
    _dwell?.cancel();
    if (_pinned != null) return; // held on screen — no rotation
    if (_available.length <= 1) return; // nothing to rotate to
    _dwell = Timer.periodic(AppConfig.photoDwell, (_) => _advance());
    _precacheNext();
  }

  void _advance() {
    if (_pinned != null || _available.length <= 1) return;
    final outgoing = currentFile;
    _index = (_index + 1) % _available.length;
    safeNotify();

    // Memory discipline: release the image we just left, then prune anything
    // not currently on screen. Precache only the single next image.
    if (outgoing != null) FileImage(outgoing).evict();
    PaintingBinding.instance.imageCache.clearLiveImages();
    _precacheNext();
  }

  void _precacheNext() {
    if (_available.length <= 1 || _cacheDir == null) return;
    final nextName = _available[(_index + 1) % _available.length];
    final provider = ResizeImage(
      FileImage(File('${_cacheDir!.path}/$nextName')),
      width: AppConfig.photoDecodeWidth,
    );
    // Warm the cache off-screen; ignore errors (the file may vanish on next sync).
    provider
        .resolve(ImageConfiguration.empty)
        .addListener(ImageStreamListener((_, _) {}, onError: (_, _) {}));
  }

  @override
  void dispose() {
    _dwell?.cancel();
    super.dispose();
  }
}
