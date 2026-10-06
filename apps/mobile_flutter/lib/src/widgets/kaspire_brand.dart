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
          child: switch (theme) {
            KaspireTheme.neptune => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _image(const Color(0xFF9CF8F0)),
                  const Text('Flow Beyond Limits',
                      style: TextStyle(
                          fontFamily: 'NeptuneScript',
                          fontSize: 21,
                          height: 1.1,
                          color: Color(0xFFD7F3EC),
                          shadows: [
                            Shadow(color: Color(0xFF001820), blurRadius: 4)
                          ])),
                ],
              ),
            KaspireTheme.hub21 => Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Positioned.fill(
                    child: Transform.translate(
                      offset: const Offset(0, 2),
                      child: ImageFiltered(
                        imageFilter: ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2),
                        child: _image(Colors.black),
                      ),
                    ),
                  ),
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
                        Color(0xFFFFE8B6),
                      ],
                      stops: [0, .35, .57, .78, 1],
                    ).createShader(rect),
                    child: _image(Colors.white),
                  ),
                ],
              ),
            KaspireTheme.glacier => Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Positioned.fill(
                    child: Transform.translate(
                      offset: const Offset(0, 1.5),
                      child: ImageFiltered(
                        imageFilter:
                            ui.ImageFilter.blur(sigmaX: 1.8, sigmaY: 1.8),
                        child: _image(const Color(0xAAFFFFFF)),
                      ),
                    ),
                  ),
                  ShaderMask(
                    blendMode: BlendMode.srcIn,
                    shaderCallback: (rect) => const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFF173A47),
                        Color(0xFF4E6D91),
                        Color(0xFF087F86),
                        Color(0xFF8C78A8),
                      ],
                    ).createShader(rect),
                    child: _image(Colors.white),
                  ),
                ],
              ),
            _ => _image(null),
          },
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
