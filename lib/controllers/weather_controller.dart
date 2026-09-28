import '../config/app_config.dart';
import '../models/weather.dart';
import '../services/backend_client.dart';
import 'polling_controller.dart';

/// Polls weather.json and exposes the today/tomorrow outlook.
///
/// No manual refresh trigger, unlike the directory: nobody stands at the board
/// waiting for a forecast to update, and the backend re-syncs on its own cron
/// regardless.
class WeatherController extends PollingController {
  final AppConfig config;
  final BackendClient client;

  WeatherController({required this.config, required this.client});

  @override
  Duration get interval => client.jittered(AppConfig.weatherPollInterval);

  WeatherOutlook _outlook = WeatherOutlook.empty;
  WeatherOutlook get outlook => _outlook;

  /// The days worth putting on the wall — empty once the forecast has aged out,
  /// so the strip disappears instead of asserting yesterday's weather.
  List<WeatherDay> get days =>
      _outlook.isStale() ? const <WeatherDay>[] : _outlook.days;

  bool get hasOutlook => days.isNotEmpty;

  @override
  Future<void> poll({bool force = false}) async {
    final result = await client.getJson(config.weatherUri, bypassCache: force);
    if (result.notModified) return;
    _outlook = WeatherOutlook.fromJson(result.json!);
    safeNotify();
  }
}
