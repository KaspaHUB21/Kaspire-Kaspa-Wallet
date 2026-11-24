import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Three soft, content-free textures shared by all Glacier surfaces. Keeping
/// these tiny decoded images avoids re-running Gaussian filters as cards enter
/// the viewport during a fling. Text, balances and crisp rims stay live/vector.
class GlacierGlazeCache extends ChangeNotifier {
  GlacierGlazeCache._();
  static final instance = GlacierGlazeCache._();
  static const assets = [
    'assets/themes/glacier/glaze-square.png',
    'assets/themes/glacier/glaze-card.png',
    'assets/themes/glacier/glaze-wide.png',
  ];
  final _images = <String, ui.Image>{};
  Future<void>? _loading;
  bool get ready => _images.length == assets.length;
  static String assetFor(ui.Size size) => assets[
      size.width / size.height > 3 ? 2 : size.width / size.height < 1.4 ? 0 : 1];
  ui.Image? imageFor(ui.Size size) => _images[assetFor(size)];
  Future<void> ensure() => _loading ??= _load();

  Future<void> _load() async {
    try {
      for (final asset in assets) {
        final bytes = await rootBundle.load(asset);
        final codec = await ui.instantiateImageCodec(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
        try { _images[asset] = (await codec.getNextFrame()).image; }
        finally { codec.dispose(); }
      }
    } catch (_) {
      // A damaged/missing decorative asset must never block wallet startup.
      // The cheap live base gradient/rim remains usable without the veils.
      for (final image in _images.values) { image.dispose(); }
      _images.clear();
    }
    notifyListeners();
  }
}
