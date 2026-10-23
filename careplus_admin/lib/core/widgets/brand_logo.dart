import 'package:flutter/material.dart';

/// The supplied Rasoi Care primary logo, shared by the Admin app's brand surfaces.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.size = 96, this.rounded = true});

  final double size;
  final bool rounded;

  static const asset = 'assets/brand/rasoi_care_primary_logo.png';

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      semanticLabel: 'Rasoi Care',
    );
    return rounded
        ? ClipRRect(
            borderRadius: BorderRadius.circular(size * 0.14),
            child: image,
          )
        : image;
  }
}
