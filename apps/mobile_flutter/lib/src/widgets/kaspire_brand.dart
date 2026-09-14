import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import '../services/app_settings.dart';

class KaspireWordmark extends StatelessWidget {
  const KaspireWordmark({super.key, this.height = 24});

  final double height;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<KaspireTheme>(
        valueListenable: AppSettings.theme,
        builder: (context, theme, _) => Semantics(
          label: 'Kaspire',
          image: true,
          child: theme == KaspireTheme.hub21
              ? Stack(alignment: Alignment.centerLeft, children: [
                  Positioned.fill(
                      child: Transform.translate(
                          offset: const Offset(0, 2),
                          child: ImageFiltered(
                              imageFilter:
                                  ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2),
                              child: _image(Colors.black)))),
                  ShaderMask(
                      blendMode: BlendMode.srcIn,
                      shaderCallback: (rect) => const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Color(0xFFFFFFFF),
                                Color(0xFFDFE0DC),
                                Color(0xFFFFE4A4),
                                Color(0xFFBF8C30),
                                Color(0xFFFFE8B6)
                              ],
                              stops: [
                                0,
                                .35,
                                .57,
                                .78,
                                1
                              ]).createShader(rect),
                      child: _image(Colors.white)),
                ])
              : _image(null),
        ),
      );

  Widget _image(Color? color) => Image.asset(
        'assets/branding/kaspire_wordmark.png',
        color: color,
        height: height,
        fit: BoxFit.contain,
        alignment: Alignment.centerLeft,
        filterQuality: FilterQuality.high,
      );
}
