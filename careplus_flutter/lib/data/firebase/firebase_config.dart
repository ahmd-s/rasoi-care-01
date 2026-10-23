/// Small config values that live outside `firebase_options.dart` because
/// `flutterfire configure` doesn't generate them — you get these directly
/// from the Firebase console.
class FirebaseConfig {
  /// Firebase console → Authentication → Sign-in method → Google →
  /// "Web SDK configuration" → Web client ID. Needed so `google_sign_in`
  /// requests an ID token Firebase Auth will actually accept; leaving this
  /// null still lets Google sign-in work for most setups, but set it if
  /// you see `sign_in_failed` / `DEVELOPER_ERROR` on Android.
  // No staging OAuth web client is present in the current Android config.
  // Keep this unset until the staging Google provider/client is configured.
  static const String? googleServerClientId = null;
}
