import 'package:flutter/foundation.dart';

/// One person in the office directory.
@immutable
class DirectoryEntry {
  final String name;
  final String? phone; // extension or full number, as a display string
  final String? email;
  final String? role; // optional job title / role line

  const DirectoryEntry({
    required this.name,
    this.phone,
    this.email,
    this.role,
  });

  factory DirectoryEntry.fromJson(Map<String, dynamic> json) => DirectoryEntry(
        name: json['name'] as String? ?? '',
        phone: json['phone'] as String?,
        email: json['email'] as String?,
        role: json['role'] as String?,
      );
}

/// A named group of people (e.g. a team or department).
@immutable
class DirectoryGroup {
  final String name;
  final List<DirectoryEntry> people;

  const DirectoryGroup({required this.name, required this.people});

  factory DirectoryGroup.fromJson(Map<String, dynamic> json) => DirectoryGroup(
        name: json['name'] as String? ?? '',
        people: (json['people'] as List<dynamic>? ?? const [])
            .map((e) => DirectoryEntry.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
      );
}

/// The directory.json payload: an update timestamp plus grouped people.
@immutable
class DirectoryFeed {
  final DateTime? updated;
  final List<DirectoryGroup> groups;

  const DirectoryFeed({required this.updated, required this.groups});

  static const DirectoryFeed empty =
      DirectoryFeed(updated: null, groups: <DirectoryGroup>[]);

  bool get isEmpty => groups.every((g) => g.people.isEmpty);

  factory DirectoryFeed.fromJson(Map<String, dynamic> json) => DirectoryFeed(
        updated: DateTime.tryParse(json['updated'] as String? ?? ''),
        groups: (json['groups'] as List<dynamic>? ?? const [])
            .map((e) => DirectoryGroup.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
      );
}
