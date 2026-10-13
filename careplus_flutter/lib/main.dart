import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';

import 'core/theme/care_plus_theme.dart';
import 'l10n/app_localizations.dart';
import 'state/providers.dart';
import 'app/router.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)
        .timeout(const Duration(seconds: 3));
  } catch (e) {
    // Expected until you run `flutterfire configure` with a real project —
    // see lib/firebase_options.dart. Debug/profile fall back to
    // MockAuthService; release uses UnconfiguredAuthService (no demo OTP).
    debugPrint('Firebase not configured — auth factory will choose mock or fail-closed. ($e)');
  }
  runApp(const ProviderScope(child: CarePlusApp()));
}

class CarePlusApp extends ConsumerWidget {
  const CarePlusApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    return MaterialApp.router(
      title: 'Rasoi Care',
      debugShowCheckedModeBanner: false,
      theme: CarePlusTheme.light(),
      darkTheme: CarePlusTheme.dark(),
      themeMode: mode,
      locale: locale,
      supportedLocales: supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: router,
    );
  }
}
