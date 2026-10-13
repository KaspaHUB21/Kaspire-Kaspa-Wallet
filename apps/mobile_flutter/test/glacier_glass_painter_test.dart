import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/widgets/hub21_material.dart';

Future<List<int>> paintGlass(double radius, bool strong) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xFFF1F8FA), BlendMode.src);
  final painter =
      GlacierGlassDecoration(radius: radius, strong: strong, shadow: false)
          .createBoxPainter();
  painter.paint(canvas, const Offset(60, 60),
      const ImageConfiguration(size: Size(260, 40)));
  painter.dispose();
  final picture = recorder.endRecording();
  final image = await picture.toImage(380, 160);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List().toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final strong in [false, true]) {
    test('Glacier capsule facets clamp to the actual radius (strong=$strong)',
        () async {
      expect(await paintGlass(999, strong), await paintGlass(20, strong));
    });
  }
}
