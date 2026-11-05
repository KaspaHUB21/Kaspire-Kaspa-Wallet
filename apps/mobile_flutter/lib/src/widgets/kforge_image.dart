import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class KForgeImage extends StatelessWidget {
  const KForgeImage({super.key, this.url, this.size = 44});
  final String? url;
  final double size;
  @override
  Widget build(BuildContext context) {
    Widget logo() => SvgPicture.asset('assets/browser/kforge.svg',
        width: size, height: size, semanticsLabel: 'KForge logo');
    return SizedBox.square(
      dimension: size,
      child: url == null
          ? logo()
          : ClipRRect(
              borderRadius: BorderRadius.circular(size * .24),
              child: Image.network(url!,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  errorBuilder: (_, e, s) => logo())),
    );
  }
}
