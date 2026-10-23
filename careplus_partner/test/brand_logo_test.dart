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

  test('the primary logo asset is declared, bundled and unmodified (875x880 PNG)', () async {
    final data = await rootBundle.load(BrandLogo.asset);
    final b = data.buffer.asUint8List();
    expect(b.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    expect(File(BrandLogo.asset).lengthSync(), b.length);
    final decoded = await decodeImageFromList(b);
    expect([decoded.width, decoded.height], [875, 880]);
  });
}
