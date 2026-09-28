import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:screendash/config/app_config.dart';
import 'package:screendash/controllers/photo_controller.dart';
import 'package:screendash/services/backend_client.dart';
import 'package:screendash/ui/widgets/photo_stage.dart';

/// A rotation of exactly one photo at a time, set directly, so the stage can be
/// pumped without a backend or a photo cache on disk.
class _FakePhotos extends PhotoController {
  _FakePhotos(this._file)
      : super(config: const AppConfig(), client: BackendClient());

  File _file;

  set file(File value) {
    _file = value;
    notifyListeners();
  }

  @override
  File? get currentFile => _file;

  @override
  bool get hasPhotos => true;

  @override
  int get index => 0;

  @override
  int get count => 1;

  @override
  bool get isPinned => false;
}

/// A flat-coloured 24-bit BMP of exactly the given size. Only the dimensions
/// matter — the stage's whole decision is the photo's shape against the
/// panel's — and a BMP is the one format that can be written out by hand, with
/// no encoder and no engine call to await.
File _image(Directory dir, String name, int w, int h) {
  final stride = (w * 3 + 3) & ~3; // rows are padded to 4 bytes
  final pixels = stride * h;
  final bytes = Uint8List(54 + pixels);
  final header = ByteData.view(bytes.buffer);

  bytes[0] = 0x42; // 'B'
  bytes[1] = 0x4D; // 'M'
  header.setUint32(2, bytes.length, Endian.little);
  header.setUint32(10, 54, Endian.little); // pixels start here
  header.setUint32(14, 40, Endian.little); // BITMAPINFOHEADER
  header.setInt32(18, w, Endian.little);
  header.setInt32(22, h, Endian.little);
  header.setUint16(26, 1, Endian.little); // planes
  header.setUint16(28, 24, Endian.little); // bits per pixel
  header.setUint32(34, pixels, Endian.little);

  for (var i = 54; i < bytes.length; i += 3) {
    bytes[i] = 0x99; // B
    bytes[i + 1] = 0x66; // G
    bytes[i + 2] = 0x33; // R
  }

  return File('${dir.path}/$name')..writeAsBytesSync(bytes);
}

/// The stage at the real kiosk shape: a tall third of a 1080p panel.
Widget _harness(PhotoController photos) => ChangeNotifierProvider<
    PhotoController>.value(
  value: photos,
  child: const MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(width: 639, height: 990, child: PhotoStage()),
      ),
    ),
  ),
);

/// Decode a photo into the image cache, and wait for it.
///
/// The fit is chosen from the photo's measured shape, and reading a file is
/// real async work: started from inside the test's fake-async zone it would
/// never complete. Doing it here, in [WidgetTester.runAsync], means the frame
/// is already cached by the time the stage asks — which is also the live case,
/// since the controller precaches the photo it is about to show.
Future<void> _warm(WidgetTester tester, File file) => tester.runAsync(() {
  final decoded = Completer<void>();
  ResizeImage(FileImage(file), width: AppConfig.photoDecodeWidth)
      .resolve(ImageConfiguration.empty)
      .addListener(
        ImageStreamListener(
          (info, _) {
            info.dispose();
            if (!decoded.isCompleted) decoded.complete();
          },
          onError: (error, _) => decoded.completeError(error),
        ),
      );
  return decoded.future;
});

/// Settle the cross-fade between the fit assumed before the photo was measured
/// and the one chosen once it was.
Future<void> _settleFit(WidgetTester tester) async {
  await tester.pump(); // the rebuild the measurement defers to the next frame
  await tester.pump(AppConfig.photoScaleFade + const Duration(milliseconds: 50));
  await tester.pump(AppConfig.photoScaleFade + const Duration(milliseconds: 50));
}

Future<void> _pumpDecoded(
  WidgetTester tester,
  Widget harness,
  File file,
) async {
  // The default 800x600 test surface would clamp the panel to something wider
  // than the wall's, and the panel's shape is half of the comparison.
  await tester.binding.setSurfaceSize(const Size(1000, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await _warm(tester, file);
  await tester.pumpWidget(harness);
  await _settleFit(tester);
}

/// The matte is a second [Image] of the same file behind the photo, so the
/// count of images on screen is what tells fill and letterbox apart.
int _imageCount(WidgetTester tester) =>
    tester.widgetList(find.byType(Image)).length;

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('photo_stage_test');
    // The stage and the controller share cache entries by provider identity;
    // a stale entry from a previous test would answer for the wrong file.
    PaintingBinding.instance.imageCache.clear();
  });

  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps a handle on a file the engine has decoded. It's a temp
      // directory of a few hundred KB; leaving it beats failing a green test.
    }
  });

  testWidgets('a landscape photo is letterboxed onto a matte, not cropped',
      (tester) async {
    final wide = _image(dir, 'wide.bmp', 320, 200);
    await _pumpDecoded(tester, _harness(_FakePhotos(wide)), wide);

    expect(_imageCount(tester), 2);
  });

  testWidgets('a photo close to the panel shape still fills it', (tester) async {
    final tall = _image(dir, 'tall.bmp', 200, 300);
    await _pumpDecoded(tester, _harness(_FakePhotos(tall)), tall);

    expect(_imageCount(tester), 1);
  });

  testWidgets('a tap overrides the choice for that photo only', (tester) async {
    final tall = _image(dir, 'tall.bmp', 200, 300);
    final photos = _FakePhotos(tall);
    await _pumpDecoded(tester, _harness(photos), tall);
    expect(_imageCount(tester), 1, reason: 'filling to start with');

    // fill -> fit, which brings the matte with it.
    await tester.tap(find.byType(PhotoStage));
    await tester.pump();
    await tester.pump(AppConfig.photoScaleFade * 2);
    expect(_imageCount(tester), 2, reason: 'tapped onto a letterbox');

    // A different photo is judged on its own shape rather than inheriting it.
    final next = _image(dir, 'tall2.bmp', 210, 315);
    await _warm(tester, next);
    photos.file = next;
    await _settleFit(tester);
    // Plus the slow cross-fade between the two photos themselves.
    await tester.pump(AppConfig.photoFade + const Duration(milliseconds: 50));
    await tester.pump(AppConfig.photoFade + const Duration(milliseconds: 50));
    expect(_imageCount(tester), 1, reason: 'back to filling on the next photo');

    // Let the controls' linger timer expire so none is left pending.
    await tester.pump(AppConfig.photoControlsLinger);
  });
}
