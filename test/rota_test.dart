import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:screendash/config/app_config.dart';
import 'package:screendash/controllers/rota_controller.dart';
import 'package:screendash/models/rota.dart';
import 'package:screendash/services/backend_client.dart';
import 'package:screendash/ui/theme.dart';
import 'package:screendash/ui/widgets/rota_card.dart';

/// A rota whose feed is set directly, so [shownDays] can be exercised without
/// a backend or a real calendar.
class _FakeRota extends RotaController {
  _FakeRota(this._feed)
      : super(config: const AppConfig(), client: BackendClient());

  final RotaFeed _feed;

  @override
  RotaFeed get feed => _feed;
}

RotaPerson _person(String name, RotaStatus status, {String label = '8–6'}) =>
    RotaPerson(name: name, status: status, label: label, role: 'F1');

/// A fortnight from [from], everyone off at the weekend unless [weekends].
RotaFeed _fortnight(DateTime from, {bool weekends = false}) => RotaFeed(
      updated: from,
      days: [
        for (var i = 0; i < 14; i++)
          () {
            final day = DateTime(from.year, from.month, from.day + i);
            final working = weekends || day.weekday < DateTime.saturday;
            return RotaDay(
              date: RotaFeed.isoDate(day),
              people: [
                _person('Dr A', working ? RotaStatus.present : RotaStatus.off,
                    label: working ? '8–6' : 'Off'),
              ],
            );
          }(),
      ],
    );

/// The card's width on the wall: a third of 1920, less the column's padding.
const double _width = 595;

/// The height the card gets at the board's geometry: the lower half of the
/// column, less its heading and the strip kept clear of the status overlay.
/// Rounded down, so a test that passes here passes on the wall.
const double _halfHeight = 330;

/// Three days — Tue 22 to Thu 24 Sep 2026 — of the same roster, unless
/// [days] gives each day its own.
Widget _harness(
  List<RotaPerson> people, {
  double? height = _halfHeight,
  List<List<RotaPerson>>? days,
}) {
  final rosters = days ?? [people, people, people];
  return MaterialApp(
    theme: DashTheme.build(),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: _width,
          height: height,
          child: RotaCard(
            days: [
              for (var i = 0; i < rosters.length; i++)
                RotaDay(date: '2026-09-${22 + i}', people: rosters[i]),
            ],
            today: DateTime(2026, 9, 22, 10),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('RotaFeed', () {
    test('parses the published shape and keeps roster order', () {
      final feed = RotaFeed.fromJson({
        'updated': '2026-09-18T07:15:00Z',
        'days': [
          {
            'date': '2026-09-18',
            'people': [
              {'name': 'Dr A Khan', 'role': 'Consultant', 'status': 'in', 'label': '8–6'},
              {
                'name': 'Dr B Smith',
                'role': 'Consultant',
                'status': 'away',
                'label': 'Study leave',
                'contact': 'email',
              },
              {
                'name': 'Dr D Patel',
                'status': 'partial',
                'label': '8–6',
                'detail': 'Meeting 10–12',
                'contact': 'phone',
              },
              {'name': 'Dr C Lee', 'status': 'off', 'label': 'Off'},
            ],
          },
        ],
      });
      expect(feed.days, hasLength(1));
      final people = feed.days.single.people;
      expect(people.map((p) => p.name),
          ['Dr A Khan', 'Dr B Smith', 'Dr D Patel', 'Dr C Lee']);
      expect(people[0].status, RotaStatus.present);
      expect(people[1].status, RotaStatus.away);
      expect(people[1].contact, 'email');
      expect(people[2].detail, 'Meeting 10–12');
      expect(people[3].status, RotaStatus.off);
      expect(people[3].role, isNull);
    });

    test('a status this build does not know still shows, as partial', () {
      expect(RotaStatus.parse('oncall'), RotaStatus.partial);
      expect(RotaStatus.parse(null), RotaStatus.partial);
    });

    test('dayFor looks up by local date, any time of day', () {
      final feed = _fortnight(DateTime(2026, 9, 17));
      expect(feed.dayFor(DateTime(2026, 9, 18, 23, 59))?.date, '2026-09-18');
      expect(feed.dayFor(DateTime(2026, 9, 16)), isNull);
      expect(feed.dayFor(DateTime(2026, 10, 1)), isNull);
    });

    test('malformed entries are dropped rather than crashing the card', () {
      final feed = RotaFeed.fromJson({
        'days': [
          {'date': '2026-09-18', 'people': [{'status': 'in'}, 'junk', {'name': 'Dr A', 'status': 'in', 'label': '8–6'}]},
          {'people': []},
          'junk',
        ],
      });
      expect(feed.days, hasLength(1));
      expect(feed.days.single.people.single.name, 'Dr A');
    });
  });

  group('RotaController.shownDays', () {
    List<String> shown(RotaController rota, DateTime now) =>
        rota.shownDays(now: now).map((d) => d.date).toList();

    test('is today and the next two on a Monday', () {
      final rota = _FakeRota(_fortnight(DateTime(2026, 9, 14))); // Mon
      addTearDown(rota.client.close);
      expect(shown(rota, DateTime(2026, 9, 14, 10)),
          ['2026-09-14', '2026-09-15', '2026-09-16']);
    });

    test('skips a weekend nobody works: Friday shows Fri, Mon, Tue', () {
      final rota = _FakeRota(_fortnight(DateTime(2026, 9, 14)));
      addTearDown(rota.client.close);
      expect(shown(rota, DateTime(2026, 9, 18, 10)),
          ['2026-09-18', '2026-09-21', '2026-09-22']);
      // Saturday and Sunday look ahead to the working week.
      expect(shown(rota, DateTime(2026, 9, 19, 10)),
          ['2026-09-21', '2026-09-22', '2026-09-23']);
      expect(shown(rota, DateTime(2026, 9, 20, 10)),
          ['2026-09-21', '2026-09-22', '2026-09-23']);
    });

    test('shows the weekend days themselves when someone works them', () {
      final rota = _FakeRota(_fortnight(DateTime(2026, 9, 14), weekends: true));
      addTearDown(rota.client.close);
      expect(shown(rota, DateTime(2026, 9, 18, 10)),
          ['2026-09-18', '2026-09-19', '2026-09-20']);
    });

    test('is empty when the feed does not cover today (stale or absent)', () {
      final rota = _FakeRota(_fortnight(DateTime(2026, 9, 1)));
      addTearDown(rota.client.close);
      expect(rota.shownDays(now: DateTime(2026, 9, 17, 10)), isEmpty);
      final empty = _FakeRota(RotaFeed.empty);
      addTearDown(empty.client.close);
      expect(empty.shownDays(now: DateTime(2026, 9, 17, 10)), isEmpty);
    });

    test('is shorter at the end of the published window, never padded', () {
      // A fortnight ending on Sunday the 20th.
      final rota = _FakeRota(_fortnight(DateTime(2026, 9, 7)));
      addTearDown(rota.client.close);
      expect(shown(rota, DateTime(2026, 9, 17, 10)),
          ['2026-09-17', '2026-09-18']);
      // A weekend with Monday not published: the weekend day itself.
      expect(shown(rota, DateTime(2026, 9, 20, 10)), ['2026-09-20']);
    });
  });

  group('RotaCard', () {
    List<RotaPerson> many(int n, {String label = '8–6'}) => [
          for (var i = 0; i < n; i++)
            _person('Dr Person $i', RotaStatus.present, label: label),
        ];

    /// Every name on the wall, exactly once.
    void expectAll(int n) {
      for (var i = 0; i < n; i++) {
        expect(find.text('Dr Person $i'), findsOneWidget);
      }
    }

    /// The gap between two rows' names, i.e. the row height.
    double rowHeight(WidgetTester tester) =>
        tester.getTopLeft(find.text('Dr Person 1')).dy -
        tester.getTopLeft(find.text('Dr Person 0')).dy;

    testWidgets('shows every person once, with a cell for each day',
        (tester) async {
      final people = [
        _person('Dr A Khan', RotaStatus.present),
        _person('Dr B Smith', RotaStatus.away, label: 'Study leave'),
        _person('Dr C Lee', RotaStatus.off, label: 'Off'),
        _person('Dr D Patel', RotaStatus.partial),
        _person('Dr E Wong', RotaStatus.present),
        _person('Dr F Ali', RotaStatus.away, label: 'Annual leave'),
        _person('Dr G Brown', RotaStatus.present, label: '9–5'),
        _person('Dr H Green', RotaStatus.away, label: 'Sick'),
      ];
      await tester.pumpWidget(_harness(people));
      expect(tester.takeException(), isNull);
      for (final p in people) {
        expect(find.text(p.name), findsOneWidget);
      }
      expect(find.textContaining('Study leave'), findsNWidgets(3));
      expect(find.textContaining('Off'), findsNWidgets(3));
      // The three columns are headed by their dates.
      expect(find.text('TUE 22'), findsOneWidget);
      expect(find.text('WED 23'), findsOneWidget);
      expect(find.text('THU 24'), findsOneWidget);
    });

    testWidgets('the days share the width to the right of the names',
        (tester) async {
      await tester.pumpWidget(_harness(many(8)));
      final name = tester.getTopLeft(find.text('Dr Person 0'));
      final tue = tester.getTopLeft(find.text('TUE 22'));
      final wed = tester.getTopLeft(find.text('WED 23'));
      final thu = tester.getTopLeft(find.text('THU 24'));
      expect(tue.dx, greaterThan(name.dx));
      expect(wed.dx - tue.dx, closeTo(thu.dx - wed.dx, 0.5));
      expect(thu.dx, lessThan(_width));
      // The name column is capped, so the days get most of the card.
      expect(tue.dx, lessThanOrEqualTo(RotaCard.nameMax + 10));
    });

    testWidgets('takes the roomiest scale the height allows', (tester) async {
      // Unbounded: nothing to fit, so the biggest type — and the roles.
      await tester.pumpWidget(_harness(many(8), height: null));
      final unbounded = tester.getSize(find.byType(RotaCard)).height;
      expect(find.text('F1'), findsNWidgets(8));

      // Half a column: eight still fit at that size…
      await tester.pumpWidget(_harness(many(8)));
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(RotaCard)).height,
          lessThanOrEqualTo(_halfHeight));
      final eightRow = rowHeight(tester);
      expect(eightRow * 8, closeTo(unbounded - 22, 0.5));
      expect(find.text('F1'), findsNWidgets(8));

      // …and nine only at a tighter one, which has no line for the role.
      await tester.pumpWidget(_harness(many(9)));
      expect(tester.takeException(), isNull);
      final nineRow = rowHeight(tester);
      expect(nineRow, lessThan(eightRow));
      expect(nineRow * 9 + 22, lessThanOrEqualTo(_halfHeight));
      expect(find.text('F1'), findsNothing);
    });

    testWidgets('fits a team of fourteen in the half column', (tester) async {
      await tester.pumpWidget(_harness(many(14)));
      expect(tester.takeException(), isNull);
      expectAll(14);
      expect(tester.getSize(find.byType(RotaCard)).height,
          lessThanOrEqualTo(_halfHeight));
      // One name column: everyone starts at the same x.
      final left = tester.getTopLeft(find.text('Dr Person 0')).dx;
      for (var i = 1; i < 14; i++) {
        expect(tester.getTopLeft(find.text('Dr Person $i')).dx,
            closeTo(left, 0.5));
      }
    });

    testWidgets('a cell leads with the caveat, and carries the contact',
        (tester) async {
      const patel = RotaPerson(
        name: 'Dr D Patel',
        role: 'Specialty Doctor',
        status: RotaStatus.partial,
        label: '8–6',
        detail: 'Meeting 10–12',
        contact: 'phone',
      );
      // Roomy: the contact on its own line under the caveat.
      await tester.pumpWidget(_harness([patel]));
      expect(find.text('Meeting 10–12'), findsNWidgets(3));
      expect(find.text('phone'), findsNWidgets(3));
      expect(find.textContaining('8–6'), findsNothing);
      expect(find.text('Specialty Doctor'), findsOneWidget);

      // Tighter: the contact rides along after it.
      await tester.pumpWidget(_harness([patel, ...many(13, label: '9–5')]));
      expect(find.textContaining('Meeting 10–12 · phone'), findsNWidgets(3));
      expect(find.text('Specialty Doctor'), findsNothing);
    });

    testWidgets('a word for the day shows as the day', (tester) async {
      await tester.pumpWidget(_harness([
        const RotaPerson(
          name: 'Dr C Lee',
          status: RotaStatus.partial,
          label: 'WFH',
        ),
      ]));
      expect(find.text('WFH'), findsNWidgets(3));
    });

    testWidgets('each day has its own cell, and a day can be missing someone',
        (tester) async {
      await tester.pumpWidget(_harness(
        const [],
        days: [
          [
            _person('Dr Old', RotaStatus.present),
            _person('Dr New', RotaStatus.present),
          ],
          [_person('Dr New', RotaStatus.away, label: 'Annual leave')],
          [_person('Dr New', RotaStatus.off, label: 'Off')],
        ],
      ));
      expect(tester.takeException(), isNull);
      expect(find.text('Dr Old'), findsOneWidget);
      expect(find.text('Dr New'), findsOneWidget);
      expect(find.text('8–6'), findsNWidgets(2));
      expect(find.text('Annual leave'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
      // Day cells sit in their day's column, on their person's row.
      final newRow = tester.getTopLeft(find.text('Dr New')).dy;
      expect(tester.getTopLeft(find.text('Annual leave')).dy,
          inInclusiveRange(newRow, newRow + 38));
      expect(tester.getTopLeft(find.text('Off')).dx,
          greaterThan(tester.getTopLeft(find.text('Annual leave')).dx));
    });

    testWidgets('says so when there is no rota', (tester) async {
      await tester.pumpWidget(_harness(const []));
      expect(find.text('Rota not available'), findsOneWidget);
    });
  });
}
