import 'package:flutter/foundation.dart';

bool get isAndroidNative =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

bool get isWindowsDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
