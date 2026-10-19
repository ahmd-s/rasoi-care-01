import 'dart:io';

import 'package:care_plus_partner/core/widgets/brand_logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('BrandLogo shows the bundled Rasoi Care logo, uncropped', (t) async {
    await t.pumpWidget(const MaterialApp(home: Center(child: BrandLogo(size: 120))));
    final image = t.widget<Image>(find.byType(Image));
    expect((image.image as AssetImage).assetName, BrandLogo.asset);
    expect(image.fit, BoxFit.contain); // never cropped
    expect(find.bySemanticsLabel('Rasoi Care'), findsOneWidget);
  });

  test('the logo asset is declared, bundled and unmodified (1254x1254 JPEG)', () async {
    final data = await rootBundle.load(BrandLogo.asset);
    final b = data.buffer.asUint8List();
    expect(b.sublist(0, 2), [0xFF, 0xD8]); // JPEG, as supplied (not re-encoded)
    expect(File(BrandLogo.asset).lengthSync(), b.length);
    final decoded = await decodeImageFromList(b);
    expect([decoded.width, decoded.height], [1254, 1254]);
  });
}
