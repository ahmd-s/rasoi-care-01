// Android values are real — copied from the rasoi-care-b78ea staging Firebase project's
// google-services.json (package com.rasoicare.care_plus_partner, a separate
// Android app registration under the same project as careplus_flutter). iOS
// is still a placeholder since no app is registered for that platform yet.
//
// main.dart calls Firebase.initializeApp() at startup inside a try/catch.
// With real Android values it succeeds, so authServiceProvider switches to
// FirebaseAuthService automatically — no other code changes.
//
// Still to do in the Firebase console for auth to fully work:
//   1. Authentication → Sign-in method → enable Email/Password (project-wide
//      — only needs doing once across all three apps).
//   2. Project settings → this Android app → add your SHA-1/SHA-256
//      fingerprint.
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
    appId: '1:35192038815:android:e2160124450300be8349aa',
    messagingSenderId: '35192038815',
    projectId: 'rasoi-care-b78ea',
    storageBucket: 'rasoi-care-b78ea.firebasestorage.app',
  );

  static const ios = FirebaseOptions(
    apiKey: 'REPLACE_ME',
    appId: 'REPLACE_ME',
    messagingSenderId: 'REPLACE_ME',
    projectId: 'rasoi-care-b78ea',
    iosBundleId: 'com.rasoicare.carePlusPartner',
  );
}
