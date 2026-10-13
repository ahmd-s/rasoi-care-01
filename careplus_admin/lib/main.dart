import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';

import 'core/theme/care_plus_theme.dart';
import 'state/providers.dart';
import 'app/router.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (e) {
    // Expected until you run `flutterfire configure` with a real project —
    // see lib/firebase_options.dart. Debug/profile fall back to
    // MockAuthService; release uses UnconfiguredAuthService (no demo OTP).
    debugPrint('Firebase not configured — auth factory will choose mock or fail-closed. ($e)');
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
