import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';

import 'core/theme/care_plus_theme.dart';
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
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (e) {
    // Expected until you run `flutterfire configure` with a real project —
    // see lib/firebase_options.dart. The app falls back to MockAuthService
    // (lib/state/auth_providers.dart) so everything still runs.
    debugPrint('Firebase not configured — using mock auth. ($e)');
  }
  runApp(const ProviderScope(child: RasoiCareAdminApp()));
}

class RasoiCareAdminApp extends ConsumerWidget {
  const RasoiCareAdminApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: 'Rasoi Care Admin',
      debugShowCheckedModeBanner: false,
      theme: CarePlusTheme.light(),
      darkTheme: CarePlusTheme.dark(),
      themeMode: mode,
      routerConfig: router,
    );
  }
}
