// Google Maps configuration for the Partner app. Mirrors the Customer app's
// "no config, graceful fallback" pattern used for Firebase throughout this
// codebase. TechJobScreen's map stays hidden (a static address line instead)
// until a valid API key is configured.
//
// To configure Google Maps:
//
//   1. Get a Google Maps API key from the Google Cloud console and enable the
//      Maps SDK for Android API on the project.
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
//   3. Build with the API key passed as a dart-define:
//
//        flutter run --dart-define=MAPS_API_KEY=your-key-here
//        flutter build apk --release --dart-define=MAPS_API_KEY=your-key-here
//
// The [isConfigured] flag automatically reflects whether a non-empty API key
// was provided at build time. No manual MAPS_CONFIGURED flag is needed.
//
// Owner-side configuration still required:
// - Set up Google Cloud project with billing enabled
// - Enable Maps SDK for Android API
// - Configure API key restrictions (Android package name, SHA-1 fingerprint)
// - Set up proper API quotas and monitoring
abstract final class MapsConfig {
  /// Automatically true when a non-empty MAPS_API_KEY is provided at build time.
  static const isConfigured = apiKey.isNotEmpty;
  static const apiKey = String.fromEnvironment('MAPS_API_KEY', defaultValue: '');
}
