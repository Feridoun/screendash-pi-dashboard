import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:screendash/config/app_config.dart';
import 'package:screendash/controllers/directory_controller.dart';
import 'package:screendash/controllers/rota_controller.dart';
import 'package:screendash/models/directory_entry.dart';
import 'package:screendash/models/rota.dart';
import 'package:screendash/services/backend_client.dart';
import 'package:screendash/ui/directory_screen.dart';
import 'package:screendash/ui/widgets/directory_column.dart';
import 'package:screendash/ui/widgets/rota_card.dart';

/// A directory whose contents are set directly, so the column can be pumped
/// without a backend.
class _FakeDirectory extends DirectoryController {
  _FakeDirectory(this._groups)
      : super(config: const AppConfig(), client: BackendClient());

  final List<DirectoryGroup> _groups;

  @override
  List<DirectoryGroup> get groups => _groups;
}

/// A rota whose feed is set directly, likewise.
class _FakeRota extends RotaController {
  _FakeRota(this._feed)
      : super(config: const AppConfig(), client: BackendClient());

  final RotaFeed _feed;

  @override
  RotaFeed get feed => _feed;
}

/// Enough people that the compact column cannot possibly fit them all.
List<DirectoryGroup> _manyGroups() => [
      for (var g = 0; g < 6; g++)
        DirectoryGroup(
          name: 'Team $g',
          people: [
            for (var p = 0; p < 6; p++)
              DirectoryEntry(
                name: 'Person $g-$p',
                phone: '020 7946 0${g}0$p',
                email: 'person$g$p@example.yourteam.dev',
              ),
          ],
        ),
    ];

/// A roster of [count] doctors for today and the week after, every one of
/// them away — the longest status text the card draws, so the fit is tested
/// at its worst.
RotaFeed _todayWith(int count) {
  final now = DateTime.now();
  return RotaFeed(updated: now, days: [
    for (var d = 0; d < 7; d++)
      RotaDay(
        date: RotaFeed.isoDate(DateTime(now.year, now.month, now.day + d)),
        people: [
          for (var i = 0; i < count; i++)
            RotaPerson(
              name: 'Dr Person $i',
              role: 'Consultant',
              status: RotaStatus.away,
              label: 'Study leave',
              contact: 'email',
            ),
        ],
      ),
  ]);
}

/// Providers above [MaterialApp], as in main.dart — the pushed DirectoryScreen
/// is a new route, so it only sees providers that outlive the Navigator.
///
/// The default [height] is the column's on the wall: 1080 less the notice
/// banner. The width is a third of 1920.
Widget _harness(
  DirectoryController dir, {
  RotaController? rota,
  double height = 920,
}) {
  final rotaController = rota ?? _FakeRota(RotaFeed.empty);
  if (rota == null) addTearDown(rotaController.client.close);
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<DirectoryController>.value(value: dir),
      ChangeNotifierProvider<RotaController>.value(value: rotaController),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 640,
            height: height,
            child: const DirectoryColumn(),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('DirectoryColumn', () {
    // The dashboard and the full directory are both laid out for a 1080p panel;
    // the 800x600 default test surface overflows their headers.
    setUp(() {
      final view = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first;
      view.physicalSize = const Size(1920, 1080);
      view.devicePixelRatio = 1.0;
      addTearDown(() {
        view.resetPhysicalSize();
        view.resetDevicePixelRatio();
      });
    });

    testWidgets('the compact list scrolls in place on the dashboard',
        (tester) async {
      final dir = _FakeDirectory(_manyGroups());
      await tester.pumpWidget(_harness(dir));

      final scrollable = find.byType(Scrollable);
      expect(scrollable, findsOneWidget);

      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.pixels, 0);
      expect(position.maxScrollExtent, greaterThan(0),
          reason: 'the fixture must overflow for the drag to mean anything');

      await tester.drag(scrollable, const Offset(0, -200));
      await tester.pumpAndSettle();

      expect(position.pixels, greaterThan(0));

      dir.client.close();
    });

    testWidgets('it eases back to the top once nobody is touching it',
        (tester) async {
      final dir = _FakeDirectory(_manyGroups());
      await tester.pumpWidget(_harness(dir));

      final scrollable = find.byType(Scrollable);
      final position = tester.state<ScrollableState>(scrollable).position;

      await tester.drag(scrollable, const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(0));

      // Still parked a moment before the linger elapses.
      await tester.pump(AppConfig.directoryScrollLinger - const Duration(seconds: 1));
      expect(position.pixels, greaterThan(0));

      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(position.pixels, 0, reason: 'the board should reset itself');
    });

    testWidgets('a fresh scroll restarts the idle countdown', (tester) async {
      final dir = _FakeDirectory(_manyGroups());
      await tester.pumpWidget(_harness(dir));

      final scrollable = find.byType(Scrollable);
      final position = tester.state<ScrollableState>(scrollable).position;

      await tester.drag(scrollable, const Offset(0, -200));
      await tester.pumpAndSettle();

      // Someone touches it again just before it would have reset.
      await tester.pump(AppConfig.directoryScrollLinger - const Duration(seconds: 2));
      await tester.drag(scrollable, const Offset(0, -60));
      await tester.pumpAndSettle();
      final afterSecondDrag = position.pixels;

      // The original deadline passes with no reset — the clock restarted.
      await tester.pump(const Duration(seconds: 3));
      expect(position.pixels, afterSecondDrag);

      // It still comes home a full linger after the *last* touch.
      await tester.pump(AppConfig.directoryScrollLinger);
      await tester.pumpAndSettle();
      expect(position.pixels, 0);
    });

    testWidgets('a plain tap on the directory still opens the full one',
        (tester) async {
      final dir = _FakeDirectory(_manyGroups());
      await tester.pumpWidget(_harness(dir));

      expect(find.byType(DirectoryScreen), findsNothing);

      // The banner is the affordance, so it is what people aim for.
      await tester.tap(find.text('Scroll, or click to expand'));
      await tester.pumpAndSettle();

      expect(find.byType(DirectoryScreen), findsOneWidget);

      dir.client.close();
    });

    testWidgets('a tap on the rota half goes nowhere', (tester) async {
      final dir = _FakeDirectory(_manyGroups());
      final rota = _FakeRota(_todayWith(4));
      await tester.pumpWidget(_harness(dir, rota: rota));

      await tester.tap(find.text('Dr Person 0'));
      await tester.pumpAndSettle();

      expect(find.byType(DirectoryScreen), findsNothing);

      dir.client.close();
      rota.client.close();
    });

    testWidgets('an empty directory shows the placeholder, not a scroller',
        (tester) async {
      final dir = _FakeDirectory(const []);
      await tester.pumpWidget(_harness(dir));

      expect(find.text('No directory entries'), findsOneWidget);
      expect(find.byType(Scrollable), findsNothing);

      dir.client.close();
    });

    testWidgets('the two halves are equal, directory above the rota',
        (tester) async {
      final dir = _FakeDirectory(_manyGroups());
      final rota = _FakeRota(_todayWith(4));
      await tester.pumpWidget(_harness(dir, rota: rota));
      expect(tester.takeException(), isNull);

      final directory = tester.getTopLeft(find.text('DIRECTORY'));
      final rotaHeading = tester.getTopLeft(find.text('DOCTORS ROTA'));
      final column = tester.getRect(find.byType(DirectoryColumn));
      expect(rotaHeading.dy, greaterThan(directory.dy));
      expect(rotaHeading.dy - column.top,
          closeTo(column.height / 2, column.height * 0.05),
          reason: 'the rota heading should sit at the column\'s midpoint');

      dir.client.close();
      rota.client.close();
    });

    testWidgets('a team of eight fits its half with roles, twelve without',
        (tester) async {
      final dir = _FakeDirectory(_manyGroups());
      final eight = _FakeRota(_todayWith(8));
      await tester.pumpWidget(_harness(dir, rota: eight));
      expect(tester.takeException(), isNull);
      expect(find.text('Consultant'), findsNWidgets(8));
      eight.client.close();

      final rota = _FakeRota(_todayWith(12));
      await tester.pumpWidget(_harness(dir, rota: rota));
      expect(tester.takeException(), isNull);

      for (var i = 0; i < 12; i++) {
        expect(find.text('Dr Person $i'), findsOneWidget);
      }
      expect(find.text('Consultant'), findsNothing,
          reason: 'twelve rows only fit at a scale with no line for the role');

      // Nothing under the status overlay's icons: the last row ends above the
      // strip the column keeps clear for them.
      final column = tester.getRect(find.byType(DirectoryColumn));
      final card = tester.getRect(find.byType(RotaCard));
      final lastRow = tester.getRect(find.text('Dr Person 11'));
      expect(lastRow.bottom, lessThanOrEqualTo(card.bottom));
      expect(card.bottom,
          lessThanOrEqualTo(column.bottom - 24 - DirectoryColumn.statusOverlayClearance));

      dir.client.close();
      rota.client.close();
    });

    testWidgets('a bigger rotation still shows everyone', (tester) async {
      final dir = _FakeDirectory(_manyGroups());
      final rota = _FakeRota(_todayWith(20));
      await tester.pumpWidget(_harness(dir, rota: rota));
      expect(tester.takeException(), isNull);

      for (var i = 0; i < 20; i++) {
        expect(find.text('Dr Person $i'), findsOneWidget);
      }

      dir.client.close();
      rota.client.close();
    });

    testWidgets('no rota says so under its heading', (tester) async {
      final dir = _FakeDirectory(_manyGroups());
      await tester.pumpWidget(_harness(dir));

      expect(find.text('DOCTORS ROTA'), findsOneWidget);
      expect(find.text('Rota not available'), findsOneWidget);

      dir.client.close();
    });
  });
}
