import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/weather_controller.dart';
import '../../models/weather.dart';
import '../theme.dart';

/// Rain chance below this is not worth the ink. In this climate a forecast
/// carrying "10%" on every dry day teaches people to stop reading the number.
const int _rainWorthMentioning = 20;

/// The two-day outlook, to the right of the clock in the calendar column.
///
/// ```
///  ☀  TODAY          21° / 13°
///     Sunny
///  ☂  TOMORROW       18° / 12°
///     Light rain 70%
/// ```
///
/// A tight two-line block per day rather than one wide row each: the label,
/// condition and rain chance for a day sit together as one thing to read, which
/// is what lets the whole outlook live in the right half of the column beside
/// the clock stack.
///
/// Renders nothing at all when there is no fresh forecast — see
/// [WeatherController.days]. An empty gap is honest; yesterday's weather
/// presented as today's is not.
class WeatherStrip extends StatelessWidget {
  const WeatherStrip({super.key});

  @override
  Widget build(BuildContext context) {
    final days = context.watch<WeatherController>().days;
    if (days.isEmpty) return const SizedBox.shrink();

    // A Table rather than a Row per day: the text and temperature columns are
    // sized to their own widest content, so the two days line up without anyone
    // guessing a pixel width for "TOMORROW". A hardcoded width is wrong the
    // moment the panel, the system font or the platform's text scaling differ
    // from the machine it was tuned on — which is exactly what happened when
    // this was first written against a fixed 104px.
    //
    // Every column is intrinsic, none flex: the block shrink-wraps its content
    // instead of stretching to whatever width it is offered, which is what
    // keeps the pieces of a day close together.
    return Table(
      columnWidths: const {
        0: IntrinsicColumnWidth(), // icon
        1: IntrinsicColumnWidth(), // TODAY / TOMORROW over the conditions
        2: IntrinsicColumnWidth(), // high / low
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      children: [
        for (var i = 0; i < days.length; i++)
          // Position, not the date string, decides the label: the backend
          // publishes today first and the controller has already refused a
          // stale payload, so the first row is today by construction.
          _dayRow(days[i], i == 0 ? 'TODAY' : 'TOMORROW', first: i == 0),
      ],
    );
  }
}

/// One day as a table row. [first] suppresses the leading gap on the top row.
TableRow _dayRow(WeatherDay day, String label, {required bool first}) {
  final rain = day.rain;
  final showRain = rain != null && rain >= _rainWorthMentioning;
  final pad = EdgeInsets.only(top: first ? 0 : 14);

  return TableRow(
    children: [
      Padding(
        // A hair down, so the glyph sits on the label's line rather than
        // riding above its cap height.
        padding: pad.copyWith(top: pad.top + 1),
        child: Icon(_iconFor(day.code), size: 24, color: DashTheme.accent),
      ),
      Padding(
        padding: pad.copyWith(left: 10, right: 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 1,
              style: const TextStyle(
                color: DashTheme.inkSoft,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.3,
                height: 1.0,
              ),
            ),
            const SizedBox(height: 6),
            // Condition and rain chance on one line: the chance is a fact
            // about the condition, not a column of its own.
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: Text(
                    day.condition,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: DashTheme.inkSoft,
                      fontSize: 19,
                      fontWeight: FontWeight.w500,
                      height: 1.0,
                    ),
                  ),
                ),
                if (showRain)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      '$rain%',
                      maxLines: 1,
                      style: const TextStyle(
                        color: DashTheme.inkFaint,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        height: 1.0,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      Padding(
        padding: pad,
        child: _Temperatures(high: day.high, low: day.low),
      ),
    ],
  );
}

/// High over low, the high carrying the weight. Tabular figures so the two
/// rows' digits line up under each other.
class _Temperatures extends StatelessWidget {
  const _Temperatures({required this.high, required this.low});

  final int? high;
  final int? low;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: high == null ? '—' : '$high°',
            style: const TextStyle(
              color: DashTheme.ink,
              fontWeight: FontWeight.w700,
            ),
          ),
          const TextSpan(text: ' / '),
          TextSpan(text: low == null ? '—' : '$low°'),
        ],
      ),
      style: const TextStyle(
        color: DashTheme.inkFaint,
        fontSize: 24,
        fontWeight: FontWeight.w500,
        height: 1.0,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// WMO code → a Material icon.
///
/// Material icons rather than emoji on purpose: Pi OS Lite ships no emoji font,
/// which is why [DashTheme] carries a bundled fallback at all. Icons come from
/// Flutter's own font and can't turn into tofu on the wall.
IconData _iconFor(int? code) {
  switch (code) {
    case 0:
    case 1:
      return Icons.wb_sunny;
    case 2:
      return Icons.wb_cloudy;
    case 3:
      return Icons.cloud;
    case 45:
    case 48:
      return Icons.foggy;
    case 51:
    case 53:
    case 55:
    case 56:
    case 57:
      return Icons.grain;
    case 61:
    case 63:
    case 65:
    case 66:
    case 67:
    case 80:
    case 81:
    case 82:
      return Icons.water_drop;
    case 71:
    case 73:
    case 75:
    case 77:
    case 85:
    case 86:
      return Icons.ac_unit;
    case 95:
    case 96:
    case 99:
      return Icons.thunderstorm;
    default:
      // Unknown or absent code: a neutral mark keeps the row's alignment
      // without claiming to know the weather.
      return Icons.thermostat;
  }
}
