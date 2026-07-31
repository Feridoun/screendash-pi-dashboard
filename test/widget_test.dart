import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:screendash/config/app_config.dart';
import 'package:screendash/controllers/dim_controller.dart';
import 'package:screendash/controllers/motd_controller.dart';
import 'package:screendash/models/dim_schedule.dart';
import 'package:screendash/models/directory_entry.dart';
import 'package:screendash/models/motd.dart';
import 'package:screendash/models/photo_manifest.dart';
import 'package:screendash/services/backend_client.dart';
import 'package:screendash/services/dim_schedule_store.dart';
import 'package:screendash/ui/theme.dart';
import 'package:screendash/ui/widgets/motd_banner.dart';

/// Keeps schedule writes inside a throwaway temp dir rather than the real
/// support directory, so a test run never touches a developer's actual cache.
DimScheduleStore scratchStore() => DimScheduleStore(
    directory: () async => Directory.systemTemp.createTemp('dim_scratch'));

void main() {
  test('manifest parses and reports emptiness', () {
    final m = PhotoManifest.fromJson({
      'hash': 'abc',
      'generated': '2026-07-23T09:00:00Z',
      'photos': [
        {'file': 'a.jpg', 'w': 1920, 'h': 1080, 'bytes': 1000},
      ],
    });
    expect(m.hash, 'abc');
    expect(m.photos.single.file, 'a.jpg');
    expect(m.isEmpty, isFalse);
    expect(PhotoManifest.empty.isEmpty, isTrue);
  });

  test('manifest reports no pin by default', () {
    final m = PhotoManifest.fromJson({
      'hash': 'abc',
      'photos': [
        {'file': 'a.jpg', 'bytes': 1000},
        {'file': 'b.jpg', 'bytes': 2000},
      ],
    });
    expect(m.photos.every((p) => p.pinned), isFalse);
    expect(m.pinnedFile, isNull);
  });

  test('manifest surfaces the pinned photo', () {
    final m = PhotoManifest.fromJson({
      'hash': 'abc',
      'photos': [
        {'file': 'a.jpg', 'bytes': 1000},
        {'file': 'b.jpg', 'bytes': 2000, 'pinned': true},
      ],
    });
    expect(m.pinnedFile, 'b.jpg');
    expect(m.photos.first.pinned, isFalse);
  });

  test('pin state participates in entry equality', () {
    const base = PhotoEntry(file: 'a.jpg', width: 1, height: 1, bytes: 10);
    const pinned =
        PhotoEntry(file: 'a.jpg', width: 1, height: 1, bytes: 10, pinned: true);
    expect(base == pinned, isFalse);
  });

  test('motd empty detection', () {
    expect(const Motd(text: '   ').isEmpty, isTrue);
    expect(const Motd(text: 'Hello').isEmpty, isFalse);
  });

  test('motd feed puts the current notice ahead of its history', () {
    final feed = MotdFeed.fromJson({
      'text': 'Fire drill at 3pm',
      'updated': '2026-07-29T09:00:00Z',
      'history': [
        {'text': 'Kitchen closed', 'updated': '2026-07-21T09:00:00Z'},
        {'text': '   '}, // blank entries never make it into the feed
      ],
    });
    expect(feed.length, 2);
    expect(feed.current.text, 'Fire drill at 3pm');
    expect(feed.at(1).text, 'Kitchen closed');
    expect(feed.current.updated, isNotNull);
  });

  test('a cleared motd clears its history too', () {
    final feed = MotdFeed.fromJson({
      'text': '',
      'history': [
        {'text': 'Kitchen closed'},
      ],
    });
    expect(feed.isEmpty, isTrue);
    expect(feed.current.isEmpty, isTrue);
  });

  test('motd feed clamps a stale index rather than throwing', () {
    final feed = MotdFeed.fromJson({'text': 'Only one'});
    expect(feed.at(4).text, 'Only one');
    expect(MotdFeed.empty.at(0).isEmpty, isTrue);
  });

  group('motd banner', () {
    // Long enough to overflow the banner's three-line cap at any sane width.
    const long =
        'The minibus leaves the main entrance at 08:15 sharp. If you are running '
        'late, call the office rather than the driver and we will hold a seat. '
        'Lunch is included: tell Priya today if you need a vegetarian option. '
        'Badges are on the table by reception, and the coach back leaves at 17:30.';

    /// A controller holding one long current notice and two older ones, fetched
    /// through a stubbed HTTP layer so nothing here touches the network.
    Future<MotdController> loadedController() async {
      final controller = MotdController(
        config: const AppConfig(),
        client: BackendClient(
          httpClient: MockClient((_) async => http.Response(
                jsonEncode({
                  'text': long,
                  'updated': '2026-07-29T08:05:00Z',
                  'history': [
                    {'text': 'Kitchen tap is fixed', 'updated': '2026-07-21T09:12:00Z'},
                    {'text': 'Fire drill Thursday', 'updated': '2026-07-16T14:40:00Z'},
                  ],
                }),
                200,
              )),
        ),
      );
      // poll() rather than refreshNow(), which would leave the poll timer armed.
      await controller.poll();
      return controller;
    }

    Widget wrap(MotdController controller) => MaterialApp(
          home: ChangeNotifierProvider<MotdController>.value(
            value: controller,
            child: const Scaffold(
              body: Column(children: [Spacer(), MotdBanner()]),
            ),
          ),
        );

    /// Unmount, then let the retired scroll cycle's outstanding delay expire so
    /// the test doesn't end with a timer still pending.
    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(AppConfig.motdScrollHold * 2);
    }

    testWidgets('scrolls a notice too long to fit', (tester) async {
      tester.view.physicalSize = const Size(900, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = await loadedController();
      await tester.pumpWidget(wrap(controller));

      final position = tester.state<ScrollableState>(find.byType(Scrollable)).position;
      expect(position.maxScrollExtent, greaterThan(0), reason: 'text should overflow');
      expect(position.pixels, 0, reason: 'starts at the top');

      // Hold at the top, then creep down.
      await tester.pump(AppConfig.motdScrollHold + const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 2));
      expect(position.pixels, greaterThan(0));

      await unmount(tester);
    });

    testWidgets('arrows step back through history, then it returns to current',
        (tester) async {
      tester.view.physicalSize = const Size(900, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = await loadedController();
      await tester.pumpWidget(wrap(controller));
      expect(find.text('Kitchen tap is fixed'), findsNothing);

      // The controls are hidden until the banner is touched.
      await tester.tap(find.byType(MotdBanner));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pump();
      expect(find.text('Kitchen tap is fixed'), findsOneWidget);
      expect(controller.isCurrent, isFalse);
      expect(find.text('2 / 3'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pump();
      expect(find.text('Fire drill Thursday'), findsOneWidget);
      expect(controller.canShowOlder, isFalse, reason: 'end of the feed');

      // Left alone, the banner goes back to the notice in force.
      await tester.pump(AppConfig.motdViewLinger + const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.isCurrent, isTrue);
      expect(find.text('Fire drill Thursday'), findsNothing);

      await unmount(tester);
    });

    testWidgets('a new notice takes the screen back from history',
        (tester) async {
      final controller = await loadedController();
      controller.showOlder();
      expect(controller.isCurrent, isFalse);

      await controller.poll(); // same artifact, freshly fetched
      expect(controller.isCurrent, isFalse, reason: 'unchanged notice, keep reading');

      controller.client.close();
    });
  });

  test('directory parses groups and people', () {
    final feed = DirectoryFeed.fromJson({
      'updated': '2026-07-23T09:00:00Z',
      'groups': [
        {
          'name': 'Engineering',
          'people': [
            {'name': 'Priya Shah', 'phone': 'x4021', 'email': 'priya@yourteam.dev'},
          ],
        },
        {'name': 'Empty Team', 'people': <dynamic>[]},
      ],
    });
    expect(feed.groups.length, 2);
    expect(feed.groups.first.people.single.name, 'Priya Shah');
    expect(feed.isEmpty, isFalse);
    expect(DirectoryFeed.empty.isEmpty, isTrue);
  });

  test('theme hex parsing', () {
    expect(DashTheme.parseHex('#E8A33D'), const Color(0xFFE8A33D));
    expect(DashTheme.parseHex('bad'), isNull);
    expect(DashTheme.parseHex(null), isNull);
  });

  test('dim controller construction and schedule sanity', () {
    final calls = <bool>[];
    final dim = DimController(hardwarePower: (on) async => calls.add(on));

    expect(DisplayState.values.length, 3);
    expect(AppConfig.activeStartHour < AppConfig.activeEndHour, isTrue);
    expect(AppConfig.activeEndHour < AppConfig.dimmedEndHour, isTrue);

    dim.dispose();
  });

  test('schedule validation rejects boundaries that do not run forward', () {
    expect(DimController.isValidSchedule(8, 18, 22), isTrue);
    expect(DimController.isValidSchedule(0, 24, 24), isTrue);
    expect(DimController.isValidSchedule(18, 8, 22), isFalse); // start after end
    expect(DimController.isValidSchedule(8, 22, 18), isFalse); // dim after off
    expect(DimController.isValidSchedule(8, 18, 25), isFalse); // past midnight+1
  });

  test('dim controller applies a valid schedule and refuses a bad one', () {
    final dim =
        DimController(hardwarePower: (_) async {}, store: scratchStore());

    expect(
      dim.updateSchedule(
          activeStartHour: 6, activeEndHour: 20, dimmedEndHour: 23),
      isTrue,
    );
    expect(dim.activeStartHour, 6);
    expect(dim.activeEndHour, 20);
    expect(dim.dimmedEndHour, 23);

    expect(dim.updateSchedule(activeStartHour: 21), isFalse);
    expect(dim.activeStartHour, 6, reason: 'rejected edit must not apply');

    dim.resetSchedule();
    expect(dim.activeStartHour, AppConfig.activeStartHour);
    dim.dispose();
  });

  test('scrim opacity is clamped by the configured dimness', () {
    final dim =
        DimController(hardwarePower: (_) async {}, store: scratchStore());
    dim.updateSchedule(dimmedScrimOpacity: 2.0);
    expect(dim.dimmedScrimOpacity, 1.0);
    dim.updateSchedule(dimmedScrimOpacity: -1.0);
    expect(dim.dimmedScrimOpacity, 0.0);
    dim.dispose();
  });

  test('wake lights the panel and sleepNow returns it to the schedule', () async {
    final calls = <bool>[];
    final dim = DimController(
        hardwarePower: (on) async => calls.add(on), store: scratchStore());

    // Every valid schedule keeps one bright window, so put that window on an
    // hour that isn't now — whatever time the suite happens to run at.
    if (DateTime.now().hour == 0) {
      dim.updateSchedule(
          activeStartHour: 23, activeEndHour: 24, dimmedEndHour: 24);
    } else {
      dim.updateSchedule(activeStartHour: 0, activeEndHour: 1, dimmedEndHour: 1);
    }
    await Future<void>.delayed(Duration.zero);
    expect(dim.state, DisplayState.blanked);
    expect(dim.scrimOpacity, 1.0);
    expect(dim.isDark, isTrue);
    expect(calls.last, isFalse, reason: 'panel powered off when blanked');

    dim.wake();
    expect(dim.isAwake, isTrue);
    expect(dim.scrimOpacity, 0.0);
    expect(dim.isDark, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(calls.last, isTrue, reason: 'tap re-powers the panel');

    dim.sleepNow();
    expect(dim.isAwake, isFalse);
    expect(dim.scrimOpacity, 1.0);
    await Future<void>.delayed(Duration.zero);
    expect(calls.last, isFalse);

    dim.dispose();
  });

  group('dim schedule persistence', () {
    late Directory tmp;
    late DimScheduleStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('dim_schedule_test');
      store = DimScheduleStore(directory: () async => tmp);
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    File savedFile() =>
        File('${tmp.path}${Platform.pathSeparator}${DimScheduleStore.fileName}');

    test('load returns null when nothing has been saved', () async {
      expect(await store.load(), isNull);
    });

    test('save then load round-trips the schedule', () async {
      const schedule = DimSchedule(
        activeStartHour: 7,
        activeEndHour: 19,
        dimmedEndHour: 23,
        dimmedScrimOpacity: 0.4,
      );
      await store.save(schedule);

      expect(savedFile().existsSync(), isTrue);
      expect(jsonDecode(savedFile().readAsStringSync()), {
        'activeStartHour': 7,
        'activeEndHour': 19,
        'dimmedEndHour': 23,
        'dimmedScrimOpacity': 0.4,
      });
      expect(await store.load(), schedule);
    });

    test('a corrupt or out-of-order file falls back to no saved schedule',
        () async {
      await savedFile().writeAsString('{not json');
      expect(await store.load(), isNull);

      await savedFile().writeAsString(jsonEncode({
        'activeStartHour': 20,
        'activeEndHour': 9, // backwards
        'dimmedEndHour': 23,
        'dimmedScrimOpacity': 0.5,
      }));
      expect(await store.load(), isNull);
    });

    test('clear removes the override', () async {
      await store.save(DimSchedule.defaults);
      await store.clear();
      expect(savedFile().existsSync(), isFalse);
      expect(await store.load(), isNull);
    });

    test('a saved edit is written and reloaded by a fresh controller', () async {
      final dim = DimController(hardwarePower: (_) async {}, store: store);
      dim.updateSchedule(
          activeStartHour: 9, activeEndHour: 17, dimmedEndHour: 21);
      // Let the fire-and-forget write land.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      dim.dispose();

      final restored = DimController(hardwarePower: (_) async {}, store: store)
        ..start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(restored.activeStartHour, 9);
      expect(restored.activeEndHour, 17);
      expect(restored.dimmedEndHour, 21);
      restored.dispose();
    });

    test('reset deletes the saved override', () async {
      final dim = DimController(hardwarePower: (_) async {}, store: store);
      dim.updateSchedule(activeStartHour: 9);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(savedFile().existsSync(), isTrue);

      dim.resetSchedule();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(savedFile().existsSync(), isFalse);
      expect(dim.activeStartHour, AppConfig.activeStartHour);
      dim.dispose();
    });
  });
}
