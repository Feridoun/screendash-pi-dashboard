import 'dart:io';

/// Resolves the per-app writable directory, replacing `path_provider`.
///
/// Why not `path_provider`: it drags in `path_provider_foundation`, which
/// depends on `objective_c`, which forces Flutter's code-assets build hooks on.
/// Those hooks then demand a Linux CMake cache that `flutterpi_tool` never
/// generates, so the arm64 release bundle simply cannot be built. The plugin is
/// also pure overhead here — the Pi target is Linux, and on Linux
/// `getApplicationSupportDirectory()` returns exactly what this computes.
///
/// Follows the XDG Base Directory spec: `$XDG_DATA_HOME/<app>`, falling back to
/// `~/.local/share/<app>`. Windows/macOS branches exist only so host-side
/// development and `flutter test` keep working.
class AppDirectories {
  const AppDirectories._();

  /// Directory name used under the platform's data root.
  static const String appName = 'screendash';

  /// The app's support directory. **Not** created by this call — callers that
  /// write decide when to `create(recursive: true)`, which keeps a read-only
  /// filesystem from being touched by a mere read.
  static Future<Directory> support() async => Directory(supportPath());

  /// Synchronous form, for the constructor-default case.
  static String supportPath() {
    final env = Platform.environment;

    if (Platform.isLinux) {
      final xdg = env['XDG_DATA_HOME'];
      if (xdg != null && xdg.isNotEmpty) return _join(xdg, appName);
      final home = env['HOME'];
      if (home != null && home.isNotEmpty) {
        return _join(home, '.local', 'share', appName);
      }
    } else if (Platform.isWindows) {
      final appData = env['APPDATA'];
      if (appData != null && appData.isNotEmpty) return _join(appData, appName);
    } else if (Platform.isMacOS) {
      final home = env['HOME'];
      if (home != null && home.isNotEmpty) {
        return _join(home, 'Library', 'Application Support', appName);
      }
    }

    // No HOME at all — e.g. a systemd unit with a stripped environment. Fall
    // back to the temp dir so caching degrades rather than crashing the display.
    return _join(Directory.systemTemp.path, appName);
  }

  static String _join(String a, [String? b, String? c, String? d]) {
    final sep = Platform.pathSeparator;
    return [a, b, c, d].whereType<String>().join(sep);
  }
}
