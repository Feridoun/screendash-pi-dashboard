import 'package:flutter/foundation.dart';

/// One entry in the photo manifest. Immutable.
@immutable
class PhotoEntry {
  final String file;
  final int width;
  final int height;
  final int bytes;

  /// Set by the backend when this photo should be held on screen instead of
  /// rotating. Absent on older manifests, hence the default.
  final bool pinned;

  const PhotoEntry({
    required this.file,
    required this.width,
    required this.height,
    required this.bytes,
    this.pinned = false,
  });

  factory PhotoEntry.fromJson(Map<String, dynamic> json) => PhotoEntry(
        file: json['file'] as String,
        width: (json['w'] as num?)?.toInt() ?? 0,
        height: (json['h'] as num?)?.toInt() ?? 0,
        bytes: (json['bytes'] as num?)?.toInt() ?? 0,
        pinned: json['pinned'] == true,
      );

  @override
  bool operator ==(Object other) =>
      other is PhotoEntry &&
      other.file == file &&
      other.bytes == bytes &&
      other.pinned == pinned;

  @override
  int get hashCode => Object.hash(file, bytes, pinned);
}

/// The manifest the Pi polls. `hash` lets us skip all work when nothing changed.
@immutable
class PhotoManifest {
  final String hash;
  final DateTime? generated;
  final List<PhotoEntry> photos;

  const PhotoManifest({
    required this.hash,
    required this.generated,
    required this.photos,
  });

  static const PhotoManifest empty =
      PhotoManifest(hash: '', generated: null, photos: <PhotoEntry>[]);

  factory PhotoManifest.fromJson(Map<String, dynamic> json) => PhotoManifest(
        hash: json['hash'] as String? ?? '',
        generated: DateTime.tryParse(json['generated'] as String? ?? ''),
        photos: (json['photos'] as List<dynamic>? ?? const [])
            .map((e) => PhotoEntry.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
      );

  bool get isEmpty => photos.isEmpty;

  /// The filename the backend wants held on screen, or null for normal
  /// rotation. Only the first pinned entry counts — a manifest with several is
  /// malformed, and picking the first keeps behaviour deterministic.
  String? get pinnedFile {
    for (final p in photos) {
      if (p.pinned) return p.file;
    }
    return null;
  }
}
