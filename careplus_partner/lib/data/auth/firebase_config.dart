/// Small config values that live outside `firebase_options.dart` because
/// `flutterfire configure` doesn't generate them — you get these directly
/// from the Firebase console.
class FirebaseConfig {
  /// Firebase console → Authentication → Sign-in method → Google →
  /// "Web SDK configuration" → Web client ID. Needed so `google_sign_in`
  /// requests an ID token Firebase Auth will actually accept; leaving this
  /// null still lets Google sign-in work for most setups, but set it if
  /// you see `sign_in_failed` / `DEVELOPER_ERROR` on Android.
  // Staging project `rasoi-care-b78ea` Web client ID (client_type 3 from its
  // google-services.json). Never use the production client ID here.
  static const String? googleServerClientId =
      '35192038815-8m2vlbabmmnq7pvtqh2v6flcl2e5ts1a.apps.googleusercontent.com';
}
