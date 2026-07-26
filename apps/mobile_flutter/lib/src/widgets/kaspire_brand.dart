import 'package:flutter/material.dart';

class KaspireWordmark extends StatelessWidget {
  const KaspireWordmark({super.key, this.height = 24});

  final double height;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Kaspire',
        image: true,
        child: Image.asset(
          'assets/branding/kaspire_wordmark.png',
          height: height,
          fit: BoxFit.contain,
          alignment: Alignment.centerLeft,
          filterQuality: FilterQuality.high,
        ),
      );
}
