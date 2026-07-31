import 'dart:io';

import 'package:flutter/foundation.dart';

/// Triggers a clean shutdown so the board can be unplugged safely.
///
/// Why this exists: the rootfs is journalled ext4, so the filesystem itself
/// usually survives a yanked plug — but this device writes more or less
/// continuously (journald, the photo cache, `dim_schedule.json`, and updater
/// downloads), and cutting power mid-write is how SD cards get corrupted. A
/// wall-mounted board with no keyboard needs a way to stop cleanly.
///
/// Requires the narrow sudoers rule in `deploy/dashboard-power.sudoers`
/// (`systemctl poweroff` only). Without it this fails soft and the UI says so,
/// rather than appearing to work and leaving someone to pull the plug anyway.
class PowerService {
  const PowerService();

  /// Both paths are listed in the sudoers rule; Bookworm uses /usr/bin, but
  /// /bin is a symlink to it and sudo matches on the literal path given.
  static const List<String> _args = ['systemctl', 'poweroff'];

  /// Returns true if the shutdown was accepted. A true result means the system
  /// is going down — the app will be SIGTERMed shortly after, so callers should
  /// not expect to run much afterwards.
  Future<bool> shutdown() async {
    try {
      final result = await Process.run('sudo', ['-n', ..._args]);
      if (result.exitCode == 0) return true;
      debugPrint(
        '[PowerService] poweroff failed (${result.exitCode}): ${result.stderr}',
      );
      return false;
    } catch (e) {
      // No sudo, no such binary, running on a dev host — never crash the wall.
      debugPrint('[PowerService] poweroff unavailable: $e');
      return false;
    }
  }
}
