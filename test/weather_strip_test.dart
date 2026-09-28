import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// intl exports its own TextDirection, which would shadow dart:ui's below.
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import 'package:screendash/config/app_config.dart';
import 'package:screendash/controllers/calendar_controller.dart';
import 'package:screendash/controllers/message_controller.dart';
import 'package:screendash/controllers/rota_controller.dart';
import 'package:screendash/controllers/weather_controller.dart';
import 'package:screendash/models/weather.dart';
import 'package:screendash/services/backend_client.dart';
import 'package:screendash/ui/widgets/calendar_column.dart';
import 'package:screendash/ui/widgets/clock_header.dart';
import 'package:screendash/ui/widgets/weather_strip.dart';

/// A controller whose outlook is set directly, so the strip can be pumped
/// without a backend.
class _FakeWeather extends WeatherController {
  _FakeWeather(this._days)
      : super(config: const AppConfig(), client: BackendClient());

  final List<WeatherDay> _days;

  @override
  List<WeatherDay> get days => _days;
}

Widget _harness(WeatherController weather) =>
    ChangeNotifierProvider<WeatherController>.value(
      value: weather,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            // Roughly the calendar column's width on a 1080p panel.
            child: SizedBox(width: 640, child: const WeatherStrip()),
          ),
        ),
      ),
    );

void main() {
  group('WeatherStrip', () {
    testWidgets('shows both days, labelled by position', (tester) async {
      final weather = _FakeWeather(const [
        WeatherDay(
          date: '2026-08-03',
          code: 3,
          high: 21,
          low: 13,
          rain: 20,
          condition: 'Cloudy',
        ),
        WeatherDay(
          date: '2026-08-04',
          code: 61,
          high: 18,
          low: 12,
          rain: 70,
          condition: 'Light rain',
        ),
      ]);
      await tester.pumpWidget(_harness(weather));

      expect(find.text('TODAY'), findsOneWidget);
      expect(find.text('TOMORROW'), findsOneWidget);
      expect(find.text('Cloudy'), findsOneWidget);
      expect(find.text('Light rain'), findsOneWidget);
      expect(find.text('70%'), findsOneWidget);

      weather.client.close();
    });

    testWidgets('omits a rain chance too low to be worth reading',
        (tester) async {
      final weather = _FakeWeather(const [
        WeatherDay(
          date: '2026-08-03',
          code: 0,
          high: 24,
          low: 15,
          rain: 5,
          condition: 'Clear',
        ),
      ]);
      await tester.pumpWidget(_harness(weather));

      expect(find.text('Clear'), findsOneWidget);
      expect(find.text('5%'), findsNothing);

      weather.client.close();
    });

    testWidgets('renders nothing when there is no fresh forecast',
        (tester) async {
      // The controller hides a stale outlook by returning no days at all, so a
      // board that lost its backend shows a gap rather than old weather.
      final weather = _FakeWeather(const []);
      await tester.pumpWidget(_harness(weather));

      expect(find.byType(Icon), findsNothing);
      expect(find.text('TODAY'), findsNothing);

      weather.client.close();
    });

    testWidgets('a missing temperature renders a dash, not a crash',
        (tester) async {
      final weather = _FakeWeather(const [
        WeatherDay(date: '2026-08-03', code: 3, high: 21, condition: 'Cloudy'),
      ]);
      await tester.pumpWidget(_harness(weather));

      expect(find.textContaining('21°'), findsOneWidget);
      expect(find.textContaining('—'), findsOneWidget);

      weather.client.close();
    });
  });

  group('the strip in its column', () {
    // The panel on the wall is 1080p and the calendar column is a third of it.
    // The column is dense enough that adding anything to it risks pushing the
    // message panel off the bottom, so this pins the geometry the board
    // actually runs at. (Below roughly this height it overflows with or without
    // the strip — the column has always been sized for a 1080p panel.)
    setUp(() {
      final view = TestWidgetsFlutterBinding.ensureInitialized()
          .platformDispatcher
          .views
          .first;
      view.physicalSize = const Size(1920, 1200);
      view.devicePixelRatio = 1.0;
      addTearDown(() {
        view.resetPhysicalSize();
        view.resetDevicePixelRatio();
      });
    });

    testWidgets('does not push the calendar column into an overflow',
        (tester) async {
      final weather = _FakeWeather(const [
        WeatherDay(
          date: '2026-08-03',
          code: 3,
          high: 21,
          low: 13,
          rain: 20,
          condition: 'Cloudy',
        ),
        WeatherDay(
          date: '2026-08-04',
          code: 61,
          high: 18,
          low: 12,
          rain: 70,
          condition: 'Light rain',
        ),
      ]);
      final calendar =
          CalendarController(config: const AppConfig(), client: BackendClient());
      final messages =
          MessageController(config: const AppConfig(), client: BackendClient());
      final rota =
          RotaController(config: const AppConfig(), client: BackendClient());
      addTearDown(() {
        weather.client.close();
        calendar.client.close();
        messages.client.close();
        rota.client.close();
      });

      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<CalendarController>.value(value: calendar),
          ChangeNotifierProvider<MessageController>.value(value: messages),
          ChangeNotifierProvider<RotaController>.value(value: rota),
          ChangeNotifierProvider<WeatherController>.value(value: weather),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              // A third of 1920 wide; 1080 less the notice banner tall.
              child: SizedBox(
                width: 640,
                height: 920,
                child: CalendarColumn(),
              ),
            ),
          ),
        ),
      ));

      expect(tester.takeException(), isNull);

      // The header band: the clock stack on the left, the outlook clear of it
      // on the right. Anchored on the weekday, which is the widest line of the
      // stack — if the outlook starts left of where that ends, the two have
      // begun to collide.
      final weekday = tester.getRect(find.byType(ClockHeader));
      final outlook = tester.getRect(find.byType(WeatherStrip));
      expect(outlook.left, greaterThan(weekday.right - 1),
          reason: 'the outlook must sit to the right of the clock');

      // Day, date and time stacked and flush left, in that order.
      final now = DateTime.now();
      final day = tester.getRect(find.text(DateFormat('EEEE').format(now)));
      final date = tester.getRect(find.text(DateFormat('d MMM y').format(now)));
      final time = tester.getRect(find.text(DateFormat('h:mm a').format(now)));
      expect(date.top, greaterThan(day.top));
      expect(time.top, greaterThan(date.top));
      for (final line in [date, time]) {
        expect(line.left, closeTo(day.left, 0.5), reason: 'stack is flush left');
      }

      // Both labels on one line each. A fixed label width used to wrap
      // "TOMORROW" wherever the platform's text metrics ran wider than the
      // machine it was tuned on.
      for (final label in ['TODAY', 'TOMORROW']) {
        final text = tester.widget<Text>(find.text(label));
        final painter = TextPainter(
          text: TextSpan(text: label, style: text.style),
          textDirection: TextDirection.ltr,
        )..layout();
        expect(
          tester.getSize(find.text(label)).width,
          greaterThanOrEqualTo(painter.width),
          reason: '$label must have room to render on a single line',
        );
      }
    });
  });

  group('WeatherController', () {
    /// Poll a controller against a canned weather.json and return it.
    Future<WeatherController> polled(String body) async {
      final client = BackendClient(
        httpClient: MockClient((_) async => http.Response(
              body,
              200,
              headers: {'content-type': 'application/json'},
            )),
      );
      final controller =
          WeatherController(config: const AppConfig(), client: client);
      addTearDown(() {
        controller.dispose();
        client.close();
      });
      await controller.poll();
      return controller;
    }

    String payload(DateTime firstDay) {
      String iso(DateTime d) =>
          '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
      return '''
{
  "updated": "2026-08-03T09:40:00.000Z",
  "place": "Anytown",
  "days": [
    {"date": "${iso(firstDay)}", "code": 3, "high": 21, "low": 13, "rain": 20,
     "condition": "Cloudy"},
    {"date": "${iso(firstDay.add(const Duration(days: 1)))}", "code": 61,
     "high": 18, "low": 12, "rain": 70, "condition": "Light rain"}
  ]
}
''';
    }

    test('surfaces a forecast that starts today', () async {
      final controller = await polled(payload(DateTime.now()));

      expect(controller.hasOutlook, isTrue);
      expect(controller.days, hasLength(2));
      expect(controller.days.first.condition, 'Cloudy');
    });

    test('withholds one that has aged out', () async {
      final controller = await polled(
        payload(DateTime.now().subtract(const Duration(days: 2))),
      );

      // Parsed fine — it is only *showing* it that would be a lie.
      expect(controller.outlook.days, hasLength(2));
      expect(controller.hasOutlook, isFalse);
      expect(controller.days, isEmpty);
    });
  });
}
