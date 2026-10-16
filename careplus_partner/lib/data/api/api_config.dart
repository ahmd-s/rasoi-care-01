// Base URL for the shared Flask backend (app.py / database.py at the repo root).
//
// RELEASE builds (`flutter build apk --release`) use the production backend
// unless API_BASE_URL says otherwise, so shipped apps are unchanged.
//
// DEBUG and PROFILE builds never default to production. They need an explicit
// non-production URL, for example:
//   flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8420   (Android emulator -> your machine)
//   flutter run --dart-define=API_BASE_URL=http://<your-LAN-IP>:8420   (physical device)
// Without one, requests go to an unreachable placeholder host (so nothing can
// reach production by accident) and main() shows a clear error screen; see
// ApiConfig.debugProblem. A production URL passed to a debug build is rejected
// the same way. See docs/LOCAL_SETUP.md.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

abstract final class ApiConfig {
  static const productionUrl = 'https://rasoicare-backend.onrender.com';
  static const _productionHost = 'rasoicare-backend.onrender.com';

  /// Where a non-release build points when no safe URL was given. The .invalid
  /// TLD is reserved (RFC 2606) and never resolves.
  static const unconfiguredUrl = 'http://api-base-url-not-configured.invalid';

  static const _override = String.fromEnvironment('API_BASE_URL');

  static String get baseUrl =>
      resolve(override: _override, releaseMode: kReleaseMode);

  /// The URL to use. Pure so it can be tested for every combination.
  @visibleForTesting
  static String resolve({required String override, required bool releaseMode}) {
    final url = _trim(override);
    if (releaseMode) return url.isEmpty ? productionUrl : url;
    return url.isEmpty || _isProduction(url) ? unconfiguredUrl : url;
  }

  /// A developer-facing explanation when a non-release build has no safe API
  /// URL, or null when it is fine (always null in release builds).
  @visibleForTesting
  static String? problemFor({
    required String override,
    required bool releaseMode,
  }) {
    if (releaseMode) return null;
    final url = _trim(override);
    if (url.isEmpty) {
      return 'API_BASE_URL is not set.\n\nDebug and profile builds never default to the production '
          'backend. Run with an explicit non-production URL, e.g.\n'
          'flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8420\n'
          '(10.0.2.2 is the Android emulator\'s address for your machine).';
    }
    if (_isProduction(url)) {
      return 'API_BASE_URL points at the production backend, which debug and profile builds '
          'refuse to use.\n\nUse a local or staging URL, e.g. http://10.0.2.2:8420.';
    }
    return null;
  }

  static String? debugProblem() =>
      problemFor(override: _override, releaseMode: kReleaseMode);

  static String _trim(String v) => v.trim();

  static bool _isProduction(String url) =>
      Uri.tryParse(url)?.host.toLowerCase() == _productionHost;
}

/// Shown instead of the app when a non-release build has no safe API URL.
class ApiConfigErrorApp extends StatelessWidget {
  const ApiConfigErrorApp(this.message, {super.key});
  final String message;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Backend URL not configured',
                  key: ValueKey('api-config-error-title'),
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                Text(message, key: const ValueKey('api-config-error-message')),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
