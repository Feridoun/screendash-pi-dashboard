import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:screendash/config/app_config.dart';
import 'package:screendash/controllers/celebration_controller.dart';
import 'package:screendash/controllers/motd_controller.dart';
import 'package:screendash/models/celebration.dart';
import 'package:screendash/services/backend_client.dart';
import 'package:screendash/ui/widgets/celebration_overlay.dart';

void main() {
  group('CelebrationController', () {
    testWidgets('a photo batch raises a celebration and it expires on its own',
        (tester) async {
      final c = CelebrationController();
      addTearDown(c.dispose);
      expect(c.isCelebrating, isFalse);

      c.photosArrived(3);
      expect(c.current!.kind, CelebrationKind.photos);
      expect(c.current!.count, 3);

      await tester.pump(
          AppConfig.celebrationDuration - const Duration(seconds: 1));
      expect(c.isCelebrating, isTrue, reason: 'still inside its window');

      await tester.pump(const Duration(seconds: 2));
      expect(c.isCelebrating, isFalse);
    });

    test('an empty batch is not a celebration', () {
      final c = CelebrationController();
      c.photosArrived(0);
      expect(c.isCelebrating, isFalse);
      c.dispose();
    });

    test('a second arrival replaces the first rather than queueing', () {
      final c = CelebrationController();
      c.photosArrived(2);
      final first = c.current!;

      c.noticeArrived();
      final second = c.current!;

      expect(second.kind, CelebrationKind.notice);
      expect(second.serial, greaterThan(first.serial),
          reason: 'a fresh serial is what restarts the overlay animation');
      c.dispose();
    });

    test('back-to-back celebrations of the same kind stay distinct', () {
      final c = CelebrationController();
      c.noticeArrived();
      final first = c.current!;
      c.noticeArrived();

      expect(c.current, isNot(first));
      c.dispose();
    });
  });

  group('what counts as an arrival', () {
    /// A notice controller whose next payload the test controls, reporting
    /// arrivals into a counter instead of the real overlay.
    ({MotdController motd, List<int> hits}) rig(List<String> texts) {
      final hits = <int>[];
      var call = 0;
      final controller = MotdController(
        config: const AppConfig(),
        client: BackendClient(
          httpClient: MockClient((_) async {
            final text = texts[call.clamp(0, texts.length - 1)];
            call++;
            // `updated` tracks the notice, not the request — re-serving the
            // same notice must look identical, as it does from the backend.
            final published = texts.indexOf(text) + 1;
            return http.Response(
              jsonEncode(
                  {'text': text, 'updated': '2026-07-29T0$published:00:00Z'}),
              200,
            );
          }),
        ),
        onNoticeArrived: () => hits.add(1),
      );
      return (motd: controller, hits: hits);
    }

    test('the first notice of the session is not news', () async {
      final r = rig(['Coffee machine is fixed']);
      await r.motd.poll();

      expect(r.motd.motd.text, 'Coffee machine is fixed');
      expect(r.hits, isEmpty, reason: 'a reboot must not throw a party');
      r.motd.client.close();
    });

    test('a notice replacing another one is', () async {
      final r = rig(['Coffee machine is fixed', 'Fire drill at 2pm']);
      await r.motd.poll();
      await r.motd.poll();

      expect(r.hits.length, 1);
      r.motd.client.close();
    });

    test('the same notice arriving again is not', () async {
      final r = rig(['Fire drill at 2pm']);
      await r.motd.poll();
      await r.motd.poll();
      await r.motd.poll();

      expect(r.hits, isEmpty);
      r.motd.client.close();
    });

    test('clearing the banner is a change, but nothing to announce', () async {
      final r = rig(['Fire drill at 2pm', '']);
      await r.motd.poll();
      await r.motd.poll();

      expect(r.motd.feed.isEmpty, isTrue);
      expect(r.hits, isEmpty);
      r.motd.client.close();
    });
  });

  group('CelebrationOverlay', () {
    Widget harness(CelebrationController c) => MaterialApp(
          home: ChangeNotifierProvider<CelebrationController>.value(
            value: c,
            child: const Scaffold(body: CelebrationOverlay()),
          ),
        );

    testWidgets('shows nothing while the board is idle', (tester) async {
      final c = CelebrationController();
      addTearDown(c.dispose);

      await tester.pumpWidget(harness(c));
      expect(find.textContaining('NEW'), findsNothing);
    });

    testWidgets('announces a new notice, then clears itself', (tester) async {
      final c = CelebrationController();
      addTearDown(c.dispose);

      await tester.pumpWidget(harness(c));
      c.noticeArrived();
      await tester.pump();

      expect(find.text('NEW NOTICE'), findsOneWidget);

      // Let the burst play out; the controller takes it down on its own timer.
      await tester.pump(AppConfig.celebrationDuration);
      await tester.pumpAndSettle();
      expect(find.text('NEW NOTICE'), findsNothing);
    });

    testWidgets('counts a photo batch, and reads singular for one',
        (tester) async {
      final c = CelebrationController();
      addTearDown(c.dispose);

      await tester.pumpWidget(harness(c));

      c.photosArrived(4);
      await tester.pump();
      expect(find.text('NEW PHOTOS'), findsOneWidget);
      expect(find.text('4 just arrived'), findsOneWidget);

      c.photosArrived(1);
      await tester.pump();
      expect(find.text('NEW PHOTO'), findsOneWidget);
      expect(find.text('one just arrived'), findsOneWidget);

      // Leave no timer running past the end of the test.
      c.dismiss();
      await tester.pumpAndSettle();
    });

    testWidgets('never intercepts a click meant for the dashboard',
        (tester) async {
      final c = CelebrationController();
      addTearDown(c.dispose);

      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<CelebrationController>.value(
            value: c,
            child: Scaffold(
              body: Stack(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => taps++,
                    child: const SizedBox.expand(),
                  ),
                  const CelebrationOverlay(),
                ],
              ),
            ),
          ),
        ),
      );

      c.noticeArrived();
      await tester.pump();
      expect(find.text('NEW NOTICE'), findsOneWidget);

      // Straight through the middle, where the card sits.
      await tester.tap(find.byType(Scaffold));
      expect(taps, 1, reason: 'the overlay must stay pointer-transparent');

      c.dismiss();
      await tester.pumpAndSettle();
    });
  });
}
