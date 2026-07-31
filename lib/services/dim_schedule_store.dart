import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/dim_schedule.dart';
import 'app_directories.dart';

/// Persists the on-device dim schedule to a single small JSON file, so a
/// schedule set from the modal survives a reboot or a power cut.
///
/// Everything here is best-effort: a read-only filesystem, a missing plugin on
/// a desktop host, or a truncated file all degrade to "no saved schedule" and
/// the compile-time defaults, never to a crash on a wall-mounted display.
class DimScheduleStore {
  DimScheduleStore({Future<Directory> Function()? directory})
      : _directory = directory ?? AppDirectories.support;

  final Future<Directory> Function() _directory;

  static const String fileName = 'dim_schedule.json';

  Future<File> _file() async {
    final dir = await _directory();
    return File('${dir.path}${Platform.pathSeparator}$fileName');
  }

  /// The saved schedule, or null if there isn't a usable one on disk.
  Future<DimSchedule?> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      return DimSchedule.fromJson(decoded);
    } catch (e) {
      debugPrint('[DimScheduleStore] load failed: $e');
      return null;
    }
  }

  /// Write via a temp file + rename, so a power cut mid-write leaves either the
  /// old schedule or the new one — never a half-parsed file.
  Future<void> save(DimSchedule schedule) async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(schedule.toJson()), flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('[DimScheduleStore] save failed: $e');
    }
  }

  /// Drop the override so the compile-time defaults apply again.
  Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('[DimScheduleStore] clear failed: $e');
    }
  }
}
