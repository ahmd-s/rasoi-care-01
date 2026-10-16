# Android emulator walkthrough (staging, simulated AI)

Everything here runs against a **local** backend and a **separate staging
Firebase project**. Do not do it against production. See `docs/LOCAL_SETUP.md`.

## What was and was not verified (as of this document)
Verified on an Android 16 arm64 emulator, unauthenticated only: the Partner app
installs and launches, shows its sign-in screen when given
`API_BASE_URL=http://10.0.2.2:8420`, and shows the "Backend URL not configured"
screen (and logs the same message) when built with no URL. The emulator can
reach the host backend at `10.0.2.2:8420`.
**Not verified:** every step below that needs sign-in. Sign-in needs Firebase,
and the only Firebase project configured in the repo is production.

## Prerequisites (your action)
1. **Staging Firebase project** (new, not `rasoi-care`): enable the sign-in
   methods the apps use (phone and/or email), download its
   `google-services.json` into `careplus_flutter/android/app/` and
   `careplus_partner/android/app/` (do **not** commit them), and regenerate
   `lib/firebase_options.dart` with `flutterfire configure` against it.
   Phone sign-in: add Firebase **test phone numbers** (with fixed codes) so no real
   SMS is sent.
2. Start the backend with `FIREBASE_PROJECT_ID=<staging project id>` plus the
   env in `docs/LOCAL_SETUP.md`, **and** the test-mode AI flags:
   `RASOI_ALLOW_FAKE_VISION=1 VISION_AI_PROVIDER=fake`.
3. Emulator (headless is fine):
   `~/Library/Android/sdk/emulator/emulator -avd Medium_Phone_API_36.1`
   (list AVDs with `emulator -list-avds`); wait for
   `~/Library/Android/sdk/platform-tools/adb shell getprop sys.boot_completed` = 1.
4. Build and run each app with an explicit URL:
   `flutter run -d emulator-5554 --dart-define=API_BASE_URL=http://10.0.2.2:8420`
   in `careplus_flutter` (customer), `careplus_partner` and `careplus_admin`.

## Walkthrough
Use two emulator profiles or sign out between roles. "Expect" = what should
happen; record anything else as a bug.

1. **Customer sign-in and booking** (customer app): sign in with a staging test
   number; add an address; book any service. Expect a booking in Bookings.
2. **Technician sign-in** (partner app): sign in with a second test number and
   complete the application. The technician starts unverified.
3. **Verify the technician** (admin app, staff login with your
   `STAFF_SEED_OWNER_PIN`; or `PATCH /api/technicians/<id>/verify` with a staff
   token). Expect the technician able to go online and see jobs.
4. **Assignment**: technician accepts the booking. Expect it under the job list.
   *Authorization check:* a second technician must not see or open this booking.
5. **Appliance registration**: in the job, open Kitchen Passport, register a Hob
   (brand, burners). Expect it listed. Try registering a duplicate serial: expect
   a clear error.
6. **Checklist**: open the appliance checklist, mark at least 6 of 8 items, save.
   Expect a technician score and status (e.g. all Good = 100 Healthy).
7. **Photo capture / selection**: open "Photo inspection (AI, advisory)".
   Expect the red **TEST MODE — RESULTS WILL BE SIMULATED** banner and the
   privacy notice. Use the camera (emulator virtual camera) and the gallery
   (push a synthetic image: `adb push photo.jpg /sdcard/Pictures/` then rescan);
   expect previews, removal, and errors for a non-image or oversized file.
   **Use synthetic images only, never real customer photos.**
8. **Simulated inspection**: tap Analyse. Expect queued → analysing → a result
   with the red **SIMULATED — NOT A REAL INSPECTION** banner and
   "Simulated: never used in any health score".
9. **Technician review**: Accept (and separately Edit / Reject). Expect a saved
   confirmation saying a simulated result is not used in any score, a new
   revision when you change your mind, and **no change** to the checklist score
   (back on the checklist, the health panel shows no AI/combined score).
10. **Customer Kitchen Passport** (customer app): Account → Kitchen Passport.
    Expect the kitchen score, the appliance score = the technician-only score
    (never the simulated result), flagged items, next-service guidance, and the
    visit under Service history. Pull to refresh.
11. **Authorization failures** (curl with the staging customer/technician ID
    tokens against `http://localhost:8420`): customer token on a technician route
    → 401; technician token on `/api/kitchen-passport/overview` → 401; a second
    customer's overview shows none of the first customer's appliances; a second
    technician gets 404 on the first booking's inspection and review.
12. **Camera permission denial**: before step 7 run
    `adb shell pm revoke com.rasoicare.care_plus_partner android.permission.CAMERA`
    (then, on Android, choose *Don't allow* if prompted). Tap Take photo: expect
    the "Camera access is off…" message and the gallery still working. Restore
    with `adb shell pm grant com.rasoicare.care_plus_partner android.permission.CAMERA`.
13. **Network failures**: (a) during step 8 enable airplane mode
    (`adb shell cmd connectivity airplane-mode enable`): expect "Connection lost —
    retrying…" then "Check again"; disable it and tap Check again to finish.
    (b) Stop the backend before tapping Analyse: expect a clear upload error and
    that retrying does not create two analyses. (c) Open the customer Passport
    offline: expect the error with Try again.
14. **Real AI stays off**: confirm no `OPENAI_API_KEY`/`VISION_AI_ENABLED` is set
    in the backend environment; the only provider in use is `fake`.

## Cleanup
Stop the emulator (`adb emu kill`), stop the backend, delete the throwaway
`rasoicare.db` and any staging Firebase test users.
