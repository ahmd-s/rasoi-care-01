import 'package:flutter/material.dart';

/// The supplied Rasoi Care logo, shown exactly as provided (black artwork
/// background, not cropped, recoloured or redrawn). Used on brand surfaces
/// only: splash and sign-in — not on every functional screen.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.size = 96, this.rounded = true});
  final double size;
  final bool rounded;

  static const asset = 'assets/brand/rasoi_care_logo.jpg';

  @override
  Widget build(BuildContext context) {
    final img = Image.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      semanticLabel: 'Rasoi Care',
    );
    return rounded
        ? ClipRRect(borderRadius: BorderRadius.circular(size * 0.14), child: img)
        : img;
  }
}
