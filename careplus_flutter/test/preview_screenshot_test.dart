// Local, network-independent preview capture.
//
// This is not a golden/regression test — it renders real app screens off the
// Skia engine bundled with `flutter_tester` (no browser, no CDN) and dumps
// PNGs to build/preview/ so they can be reviewed before shipping an APK.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:care_plus/core/theme/care_plus_theme.dart';
import 'package:care_plus/core/widgets/appliance_illustration.dart';
import 'package:care_plus/data/models.dart';
import 'package:care_plus/l10n/app_localizations.dart';
import 'package:care_plus/features/catalog/catalog_screens.dart';
import 'package:care_plus/features/home/home_screen.dart';

const _boundaryKey = Key('preview_boundary');

Future<void> _capture(WidgetTester tester, String name) async {
  final boundary = tester
      .renderObject<RenderRepaintBoundary>(find.byKey(_boundaryKey));
  // toImage/toByteData complete on the real event loop; inside testWidgets'
  // FakeAsync zone they never resolve and the test hangs until timeout.
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2.0);
    return image.toByteData(format: ui.ImageByteFormat.png);
  });
  final dir = Directory('build/preview');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
}

Widget _wrap(Widget child) => ProviderScope(
      child: MaterialApp(
        theme: CarePlusTheme.light(),
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RepaintBoundary(key: _boundaryKey, child: child),
      ),
    );

void main() {
  testWidgets('home screen', (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(_wrap(const HomeScreen()));
    await tester.pumpAndSettle();
    await _capture(tester, 'home_screen');
  });

  testWidgets('service detail — chimney', (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
        _wrap(const ServiceDetailScreen(appliance: Appliance.chimney)));
    await tester.pumpAndSettle();
    await _capture(tester, 'service_detail_chimney');
  });

  testWidgets('service detail — dishwasher', (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
        _wrap(const ServiceDetailScreen(appliance: Appliance.dishwasher)));
    await tester.pumpAndSettle();
    await _capture(tester, 'service_detail_dishwasher');
  });

  testWidgets('all appliance illustrations grid', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(_wrap(Container(
      color: Colors.white,
      padding: const EdgeInsets.all(16),
      child: GridView.count(
        crossAxisCount: 4,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        children: [
          for (final a in Appliance.values)
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF0EDE6),
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ApplianceIllustration(
                      appliance: a, size: 56, color: const Color(0xFF2B6B4A)),
                  const SizedBox(height: 8),
                  Text(a.label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11)),
                ],
              ),
            ),
        ],
      ),
    )));
    await tester.pumpAndSettle();
    await _capture(tester, 'appliance_grid');
  });
}
