// The Partner app ships IBM Plex Mono so mono text renders offline. These
// tests run with google_fonts runtime fetching disabled (see
// flutter_test_config.dart): a weight that isn't bundled throws instead of
// silently falling back to a network fetch.
import 'package:care_plus_partner/core/theme/care_plus_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

void main() {
  test('runtime font fetching is off, so only bundled fonts can load', () {
    expect(GoogleFonts.config.allowRuntimeFetching, isFalse);
  });

  test('every IBM Plex Mono weight the app uses is a bundled asset', () async {
    final assets = (await AssetManifest.loadFromAssetBundle(rootBundle)).listAssets();
    for (final w in ['Medium', 'SemiBold', 'Bold']) {
      expect(assets, contains('assets/google_fonts/IBMPlexMono-$w.ttf'));
      final data = await rootBundle.load('assets/google_fonts/IBMPlexMono-$w.ttf');
      expect(data.lengthInBytes, greaterThan(50000), reason: w);
    }
  });

  testWidgets('mono and eyebrow styles load offline at w500/w600/w700', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Column(children: [
          Text('a', style: CareType.mono(Colors.black)),
          Text('b', style: CareType.mono(Colors.black, w: FontWeight.w600)),
          Text('c', style: CareType.mono(Colors.black, w: FontWeight.w700)),
          Text('d', style: CareType.eyebrow(Colors.black)),
        ]),
      ),
    ));
    // Font loads complete on the real event loop, not FakeAsync.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // GoogleFonts registers each loaded file under its own family name.
    final families = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.style!.fontFamily)
        .toSet();
    expect(families, isNotEmpty);
    for (final f in families) {
      expect(f, startsWith('IBMPlexMono'));
    }
  });
}
