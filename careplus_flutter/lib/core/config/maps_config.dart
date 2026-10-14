// Google Maps configuration for the Customer app. Until a valid API key is
// configured, all real-map/live-location UI elements stay gated off in favor
// of static placeholders — the app runs perfectly fine with zero Maps
// configuration, following the same "no config, graceful fallback" philosophy
// used for Firebase throughout this codebase (grep `Firebase.apps.isEmpty`).
//
// To configure Google Maps:
//
//   1. Get a Google Maps API key from the Google Cloud console and enable the
//      following APIs on the project:
//      - Maps SDK for Android
//      - Places API
//      - Geocoding API
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
//   3. Build with the API key passed as a dart-define for the app's direct
//      Places/Geocoding HTTP calls (the manifest entry only covers the native
//      GoogleMap widget itself):
//
//        flutter run --dart-define=MAPS_API_KEY=your-key-here
//        flutter build apk --release --dart-define=MAPS_API_KEY=your-key-here
//
// The [isConfigured] flag automatically reflects whether a non-empty API key
// was provided at build time. No manual MAPS_CONFIGURED flag is needed.
//
// Owner-side configuration still required:
// - Set up Google Cloud project with billing enabled
// - Enable required APIs (Maps SDK for Android, Places API, Geocoding API)
// - Configure API key restrictions (Android package name, SHA-1 fingerprint)
// - Set up proper API quotas and monitoring
abstract final class MapsConfig {
  /// Automatically true when a non-empty MAPS_API_KEY is provided at build time.
  /// Gates every real-map/live-location UI element vs. static placeholders.
  static const isConfigured = apiKey != '';

  /// The raw API key for Places Autocomplete and Geocoding REST API calls.
  /// The native GoogleMap widget reads its key from the Android manifest instead.
  /// Empty until passed at build time; every call site checks [isConfigured] first.
  static const apiKey = String.fromEnvironment('MAPS_API_KEY', defaultValue: '');
}
