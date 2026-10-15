import 'dart:async';

import 'package:google_fonts/google_fonts.dart';

// google_fonts fetches font files over the network on first use. In a
// sandboxed/offline test run that fetch stalls instead of failing fast,
// hanging the whole suite. Force it to fall back to the platform default
// font immediately so tests run without network access.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  GoogleFonts.config.allowRuntimeFetching = false;
  await testMain();
}
