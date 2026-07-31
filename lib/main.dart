import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'config/app_config.dart';
import 'controllers/calendar_controller.dart';
import 'controllers/celebration_controller.dart';
import 'controllers/directory_controller.dart';
import 'controllers/dim_controller.dart';
import 'controllers/message_controller.dart';
import 'controllers/motd_controller.dart';
import 'controllers/photo_controller.dart';
import 'services/backend_client.dart';
import 'ui/dashboard_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // --- Phase 3: hard-cap the decoded-image cache. A 1080p frame is ~8 MB, so
  //     without this a photo rotation pins 100+ MB and grows unbounded with the
  //     manifest. The Pi 3B's 1 GB raises the ceiling but doesn't remove it.  ---
  PaintingBinding.instance.imageCache
    ..maximumSize = AppConfig.imageCacheMaxCount
    ..maximumSizeBytes = AppConfig.imageCacheMaxBytes;

  // Kiosk chrome: hide any status bars, run edge-to-edge.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  runApp(const DashboardApp());
}

class DashboardApp extends StatefulWidget {
  const DashboardApp({super.key});

  @override
  State<DashboardApp> createState() => _DashboardAppState();
}

class _DashboardAppState extends State<DashboardApp> {
  static const _config = AppConfig();

  late final BackendClient _client;
  late final PhotoController _photos;
  late final CalendarController _calendar;
  late final MotdController _motd;
  late final MessageController _messages;
  late final DirectoryController _directory;
  late final DimController _dim;
  late final CelebrationController _celebration;

  @override
  void initState() {
    super.initState();
    _client = BackendClient();
    // Built before the pollers, since they report arrivals into it.
    _celebration = CelebrationController();
    _photos = PhotoController(
      config: _config,
      client: _client,
      onPhotosArrived: _celebration.photosArrived,
    )..start();
    _calendar = CalendarController(config: _config, client: _client)..start();
    _motd = MotdController(
      config: _config,
      client: _client,
      onNoticeArrived: _celebration.noticeArrived,
    )..start();
    _messages = MessageController(config: _config, client: _client)..start();
    _directory = DirectoryController(config: _config, client: _client)..start();
    _dim = DimController()..start();
  }

  @override
  void dispose() {
    _photos.dispose();
    _calendar.dispose();
    _motd.dispose();
    _messages.dispose();
    _directory.dispose();
    _dim.dispose();
    _celebration.dispose();
    _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _photos),
        ChangeNotifierProvider.value(value: _calendar),
        ChangeNotifierProvider.value(value: _motd),
        ChangeNotifierProvider.value(value: _messages),
        ChangeNotifierProvider.value(value: _directory),
        ChangeNotifierProvider.value(value: _dim),
        ChangeNotifierProvider.value(value: _celebration),
      ],
      child: MaterialApp(
        title: 'Ambient Office Dashboard',
        debugShowCheckedModeBanner: false,
        theme: DashTheme.build(),
        home: const DashboardScreen(),
      ),
    );
  }
}
