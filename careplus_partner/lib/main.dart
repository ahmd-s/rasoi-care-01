import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';

import 'core/theme/care_plus_theme.dart';
import 'l10n/app_localizations.dart';
import 'state/auth_providers.dart';
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
  runApp(const ProviderScope(child: RasoiCarePartnerApp()));
}

class RasoiCarePartnerApp extends ConsumerStatefulWidget {
  const RasoiCarePartnerApp({super.key});

  @override
  ConsumerState<RasoiCarePartnerApp> createState() => _RasoiCarePartnerAppState();
}

class _RasoiCarePartnerAppState extends ConsumerState<RasoiCarePartnerApp>
    with WidgetsBindingObserver {
  AppLifecycleState? _lastState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Biometric login was only ever re-checked at process cold start
    // (SplashScreen), so leaving the app backgrounded and switching back
    // — without the process being killed — skipped the lock entirely.
    // Re-lock on the paused-to-resumed transition specifically, not any
    // resumed event, since some platforms fire an initial `resumed`
    // during normal startup with no real backgrounding involved.
    if (_lastState == AppLifecycleState.paused && state == AppLifecycleState.resumed) {
      _maybeRelock();
    }
    _lastState = state;
  }

  Future<void> _maybeRelock() async {
    if (!ref.read(authServiceProvider).isSignedIn) return;
    final tech = await fetchTechnicianMe();
    final stage = stageFromTechnicianJson(tech);
    // Same gate as SplashScreen's cold-start check — only a fully
    // onboarded, verified technician's session is worth locking; someone
    // still mid-application has nothing sensitive to protect yet.
    if (stage == TechnicianStage.jobs && await ref.read(biometricServiceProvider).isEnabled()) {
      router.go('/lock');
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    return MaterialApp.router(
      title: 'Rasoi Care Partner',
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
