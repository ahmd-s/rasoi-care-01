import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';

import 'core/theme/care_plus_theme.dart';
import 'l10n/app_localizations.dart';
import 'state/providers.dart';
import 'app/router.dart';
import 'data/api/api_config.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Debug/profile builds must not silently talk to production: fail fast with
  // a visible, actionable message instead (see lib/data/api/api_config.dart).
  final apiProblem = ApiConfig.debugProblem();
  if (apiProblem != null) {
    debugPrint(apiProblem);
    runApp(ApiConfigErrorApp(apiProblem));
    return;
  }
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)
        .timeout(const Duration(seconds: 3));
  } catch (e) {
    // Expected until you run `flutterfire configure` with a real project —
    // see lib/firebase_options.dart. The app falls back to MockAuthService
    // (lib/state/auth_providers.dart) so everything still runs.
    debugPrint('Firebase not configured — using mock auth. ($e)');
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
