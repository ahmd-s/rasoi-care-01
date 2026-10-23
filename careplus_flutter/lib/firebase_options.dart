// Android values are real — copied from the rasoi-care-b78ea staging Firebase project's
// google-services.json (package com.careplus.care_plus). iOS/web are still
// placeholders since no app is registered for those platforms yet; add them
// the same way (Firebase console → Add app) if/when needed.
//
// main.dart calls Firebase.initializeApp() at startup inside a try/catch.
// With real Android values it succeeds, so authServiceProvider switches to
// FirebaseAuthService automatically — no other code changes. iOS/web still
// fail fast into MockAuthService until their REPLACE_ME values are filled in.
//
// Still to do in the Firebase console for auth to fully work:
//   1. Authentication → Sign-in method → enable Phone, Email/Password, Google.
//   2. Project settings → your Android app → add your SHA-1/SHA-256
//      fingerprint (Phone auth and Google Sign-in both silently fail without
//      this even with correct config values).
//   3. For Google Sign-in, set FirebaseConfig.googleServerClientId in
//      lib/data/firebase/firebase_config.dart to the Web client ID shown
//      under Authentication → Sign-in method → Google → Web SDK configuration
//      if you hit a DEVELOPER_ERROR/sign_in_failed on Android.
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for this platform.',
        );
    }
  }

  static const web = FirebaseOptions(
    apiKey: 'REPLACE_ME',
    appId: 'REPLACE_ME',
    messagingSenderId: 'REPLACE_ME',
    projectId: 'rasoi-care-b78ea',
  );

  static const android = FirebaseOptions(
    apiKey: 'AIzaSyBcTSAtrbLlNCvqEEn_BVvaoftdtOdXIgU',
    appId: '1:35192038815:android:d7208da53e60a9b28349aa',
    messagingSenderId: '35192038815',
    projectId: 'rasoi-care-b78ea',
    storageBucket: 'rasoi-care-b78ea.firebasestorage.app',
  );

  static const ios = FirebaseOptions(
    apiKey: 'REPLACE_ME',
    appId: 'REPLACE_ME',
    messagingSenderId: 'REPLACE_ME',
    projectId: 'rasoi-care-b78ea',
    iosBundleId: 'com.careplus.carePlus',
  );
}
