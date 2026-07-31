import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:screendash/config/app_config.dart';
import 'package:screendash/controllers/directory_controller.dart';
import 'package:screendash/models/directory_entry.dart';
import 'package:screendash/services/backend_client.dart';
import 'package:screendash/ui/directory_screen.dart';
import 'package:screendash/ui/widgets/directory_column.dart';

/// A directory whose contents are set directly, so the column can be pumped
/// without a backend.
class _FakeDirectory extends DirectoryController {
  _FakeDirectory(this._groups)
      : super(config: const AppConfig(), client: BackendClient());

  final List<DirectoryGroup> _groups;

  @override
  List<DirectoryGroup> get groups => _groups;
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

/// Provider above [MaterialApp], as in main.dart — the pushed DirectoryScreen
/// is a new route, so it only sees providers that outlive the Navigator.
Widget _harness(DirectoryController dir) =>
    ChangeNotifierProvider<DirectoryController>.value(
      value: dir,
      child: MaterialApp(
        home: Scaffold(
          // Roughly a third of a 1080p panel — the real dashboard geometry.
          body: Center(
            child: SizedBox(
              width: 640,
              height: 700,
              child: const DirectoryColumn(),
            ),
          ),
        ),
      ),
    );

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

    testWidgets('a plain tap still opens the full directory', (tester) async {
      final dir = _FakeDirectory(_manyGroups());
      await tester.pumpWidget(_harness(dir));

      expect(find.byType(DirectoryScreen), findsNothing);

      await tester.tap(find.byType(DirectoryColumn));
      await tester.pumpAndSettle();

      expect(find.byType(DirectoryScreen), findsOneWidget);

      dir.client.close();
    });

    testWidgets('an empty directory shows the placeholder, not a scroller',
        (tester) async {
      final dir = _FakeDirectory(const []);
      await tester.pumpWidget(_harness(dir));

      expect(find.text('No directory entries'), findsOneWidget);
      expect(find.byType(Scrollable), findsNothing);

      dir.client.close();
    });
  });
}
