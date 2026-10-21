// Google Maps configuration for the Customer app. Until a valid API key is
// configured, all real-map/live-location UI elements stay gated off in favor
// of static placeholders — the app runs perfectly fine with zero Maps
// configuration, following the same "no config, graceful fallback" philosophy
// used for Firebase throughout this codebase (grep `Firebase.apps.isEmpty`).
//
// To configure Google Maps:
//
//   1. Get an Android-restricted Google Maps API key and enable Maps SDK for
//      Android. Places API (New) and Geocoding are called through the backend.
//
//   2. Add the key to `android/local.properties` (already gitignored —
//      create the file if it doesn't exist):
//
//        MAPS_API_KEY=your-key-here
//
//      The Android build.gradle.kts already reads this and exposes it as a
//      manifest placeholder. AndroidManifest.xml declares the matching
//      `com.google.android.geo.API_KEY` meta-data tag, defaulting to an empty
//      string so the app never crashes from a missing manifest entry.
//
//   3. Build with the same restricted Android key passed as a dart-define so
//      the app can gate map UI (the native GoogleMap widget reads the
//      manifest entry). Places and Geocoding requests run through authenticated
//      backend proxies; their server key belongs in MAPS_SERVER_API_KEY on the
//      backend and must never be shipped in the APK.
//
//        flutter run --dart-define=MAPS_API_KEY=your-key-here
//        flutter build apk --release --dart-define=MAPS_API_KEY=your-key-here
//
// The [isConfigured] flag automatically reflects whether a non-empty API key
// was provided at build time. No manual MAPS_CONFIGURED flag is needed.
//
// Owner-side configuration still required:
// - Set up Google Cloud project with billing enabled
// - Enable Maps SDK for Android in the app's project
// - Store a separate server-side Places/Geocoding key in backend env
// - Configure API key restrictions (Android package name, SHA-1 fingerprint)
// - Set up proper API quotas and monitoring
abstract final class MapsConfig {
  /// Automatically true when a non-empty MAPS_API_KEY is provided at build time.
  /// Gates every real-map/live-location UI element vs. static placeholders.
  static const isConfigured = apiKey != '';

  /// Android-restricted Maps SDK key, also used as a non-secret build-time
  /// switch. Places and Geocoding use the authenticated backend proxy.
  static const apiKey = String.fromEnvironment('MAPS_API_KEY', defaultValue: '');
}
