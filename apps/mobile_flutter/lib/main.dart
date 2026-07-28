import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/app.dart';
import 'src/services/network_settings.dart';
import 'src/services/privacy_settings.dart';
import 'src/services/app_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Keep system-bar handling consistent across OEM skins, gesture navigation,
  // tablets, foldables and Android's enforced edge-to-edge mode.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  await NetworkSettings.initialize();
  await PrivacySettings.initialize();
  await AppSettings.initialize();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarContrastEnforced: false,
    ),
  );
  runApp(const KasVaultApp());
}
