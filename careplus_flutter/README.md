# Care+ — Flutter mobile app

Expert care for the heart of your home. This is the **customer app** for Care+,
a service-and-repair platform for eight kitchen appliances (chimney, hob,
cooktop, built-in microwave, dishwasher, refrigerator, OTG, water purifier).

It runs **today, with no backend** — every repository is backed by in-memory
mock data. Firebase, Razorpay and Maps are stubbed behind interfaces so you can
wire them in one seam at a time (see §5).

> Heads-up: this scaffold was written without a Flutter toolchain to compile it,
> so treat the first `flutter run` as a shakedown. The structure and APIs are
> deliberate, but expect to fix a small import or type nit or two.

---

## 1 · Run it

This package now includes the `android/` platform folder — no `flutter create`
needed. Unpack the tarball and run:

```bash
tar -xzf care_plus_flutter.tar.gz
cd careplus_flutter
flutter pub get
flutter run          # with an emulator running or a device connected via USB debugging
```

`flutter pub get` also fetches the one missing binary — see §1a for the Gradle
wrapper jar caveat. If you'd rather have Flutter regenerate the platform
folder itself (e.g. once you also want iOS), run `flutter create .` inside
`careplus_flutter/` and say **n** if it offers to overwrite existing files —
that preserves the Android setup here.

Requires **Flutter 3.27+ / Dart 3.6+** — the theme uses `Color.withValues()` and
the `CardThemeData` / `DialogThemeData` component classes. On an older SDK,
`flutter upgrade` first.

Fonts (Fraunces, Plus Jakarta Sans, IBM Plex Mono) are pulled at runtime by
`google_fonts` on first launch, so keep a network connection for that run. To
ship offline, bundle the `.ttf` files and register them in `pubspec.yaml`.

---

### 1a · Android platform folder — already included

Unlike the last drop, this package now ships a real `android/` folder — you
don't need `flutter create` just to get Android scaffolding. It includes:

- `applicationId` **com.careplus.care_plus**, minSdk 23 (covers 99%+ of Indian
  Android installs), targetSdk/compileSdk from your Flutter SDK
- Permissions matched to what the app actually does: `INTERNET` (backend),
  `ACCESS_FINE/COARSE_LOCATION` (live tracking), `CAMERA` (issue photos),
  `POST_NOTIFICATIONS` (job updates, required explicitly on Android 13+),
  `CALL_PHONE` (the "call technician" button)
- A pine-green `LaunchTheme` so there's no white flash before the Flutter
  splash screen takes over
- A generated adaptive launcher icon — the heat-dial mark in pine/brass, at
  every density (`mipmap-mdpi` → `xxxhdpi`) plus the Android 8+ adaptive-icon
  background/foreground layers
- Release build type wired for ProGuard/R8 shrinking and a signing config that
  reads `key.properties` if present, falling back to the debug key otherwise

**One thing this package can't include:** the Gradle wrapper's binary jar
(`gradle/wrapper/gradle-wrapper.jar`). It's a compiled binary fetched from
Gradle's distribution servers, not something written by hand. `gradlew` /
`gradlew.bat` are included; only the jar is missing. Fix it once with either:

```bash
# From inside careplus_flutter/android — regenerates the missing jar
gradle wrapper --gradle-version 8.9
```

or simply run `flutter pub get` from the project root — Flutter tooling
fetches it automatically on first build if it's absent.

### 1b · Signing a release build

For a Play Store build, generate a keystore once and point `key.properties` at
it (this file is gitignored — never commit it):

```bash
keytool -genkey -v -keystore ~/careplus-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias rasoicare
```

Create `android/key.properties`:

```properties
storePassword=<your password>
keyPassword=<your password>
keyAlias=rasoicare
storeFile=/absolute/path/to/careplus-release.jks
```

Then build:

```bash
flutter build appbundle   # for Play Store — this is what you upload
flutter build apk --release --split-per-abi   # for direct-install testing
```

Without `key.properties`, release builds fall back to the debug key
automatically, so `flutter build apk --release` still works for local testing.

---

## 2 · What's in the box

The full customer happy path is playable end to end:

`splash → onboarding → phone → OTP (auto-fills 4402) → home →
service detail → book (issue · slot · address · pay) → confirmed →
live tracking → invoice → rate`

plus the four-tab shell: **Home · Services · Bookings · Account**, an AMC/plans
screen, light + dark mode (toggle in Account), and the reusable component
library.

The **technician app** is also ported — reachable from Account → "Switch app":

`job feed (earnings, accept/pass on a countdown, today's route) →
job in progress (customer card, checklist, before/after photos, parts +
quote) → close the job (invoice recap, finger-signature capture, payment
collection)`

The checklist ticks and the "after" photo captures are real, stateful
Riverpod-backed interactions — not static mockup.

The **admin console** is ported too, from the same Account entry point:
Overview (revenue/jobs/SLA/rating KPIs, a 7-day bookings chart, technician
utilisation and first-time-fix rings, a "needs attention" queue), Bookings
(filterable by status), Team (roster with duty status and ratings), and Stock
(reorder levels with a low-stock alert). All three app surfaces from the
original design brief — customer, technician, admin — are now in Flutter.

---

## 3 · Architecture

MVVM with Riverpod, as laid out in the build spec.

```
lib/
  main.dart                     ProviderScope + MaterialApp.router
  app/
    router.dart                 go_router: all routes + booking flow + shell
    customer_shell.dart         bottom NavigationBar + center "Book" FAB
  core/
    theme/care_plus_theme.dart  design tokens, ColorScheme, CareDial, Pressable
    widgets/care_widgets.dart   CareCard, StatusChip, CareField, StepDot, …
  data/
    models.dart                 domain models; Money (paise → ₹ en_IN)
    mock_repository.dart        CareRepository interface + MockRepository
  state/
    providers.dart              repositoryProvider, themeMode, BookingDraft VM
  features/
    auth/ home/ catalog/ booking/ tracking/ invoice/ account/
    technician/                  job feed · job in progress · close/invoice
    admin/                       overview · bookings · team · stock
```

Money is stored in **paise (int)** everywhere and only formatted at the edge via
`Money.rupees()`. Pricing on the booking screen is *derived* from line items, not
stored, so discounts and taxes can never drift out of sync.

The booking flow carries one immutable `BookingDraft` through all four steps via
a single Riverpod notifier — the View reads it, intents mutate it.

---

## 4 · The signature element

`CareDial` is a hob control-knob ring with 12 ticks that light as the value
climbs. It's the one visual motif reused everywhere it appears: the logo mark,
the splash, onboarding art, the AMC "visits used" gauge, and the technician-ETA
readout on the tracking screen. One widget, one meaning — "how far along is
this."

Palette: pine cabinetry (primary), brass fittings (accent), cast-iron ink,
porcelain worktop (bg). Type: Fraunces for headlines, Plus Jakarta Sans for UI,
IBM Plex Mono for anything you read back (IDs, prices, timers).

---

## 5 · Going live — the backend seams

Everything the app needs from the outside world goes through
`CareRepository` (`lib/data/mock_repository.dart`). To go live you write one
class and change one line.

**a. Auth — already wired, needs your project.** Phone-OTP, email/password,
and Google sign-in are all built in (`lib/data/firebase/`), chosen
automatically:

- `main.dart` calls `Firebase.initializeApp()` at startup inside a try/catch.
  If it fails — which it will, until you configure a real project — the app
  falls back to `MockAuthService` and everything works exactly as before
  (phone auto-fills `4402`; email/Google "succeed" instantly without hitting
  a network).
- If it succeeds, `authServiceProvider` switches to `FirebaseAuthService`
  automatically (`lib/state/auth_providers.dart`) — no other code changes.
  The Phone screen sends a real OTP via `verifyPhoneNumber`; "Continue with
  Google" opens the real account picker; "Continue with email" (a new screen,
  `EmailAuthScreen`) signs in or creates a real account via
  `createUserWithEmailAndPassword`/`signInWithEmailAndPassword`. Errors
  (wrong code, wrong password, email already in use, cancelled Google
  picker, too many attempts, etc.) all surface as a snackbar with a
  human-readable message instead of a raw Firebase error code — see
  `FirebaseAuthService._friendly()`.

**To activate it**, since I have no network access to reach Firebase's
servers from here, you'll need to do this part yourself:

```bash
dart pub global activate flutterfire_cli
flutterfire configure       # run from the careplus_flutter/ root
```

This overwrites the placeholder `lib/firebase_options.dart` with your real
project's keys (for Android, `google-services.json` isn't required — this
project deliberately configures Firebase programmatically via
`FirebaseOptions` instead of the Gradle plugin, so no Gradle changes are
needed either; running `flutterfire configure` or copying the four values
by hand from **Project settings → your Android app** both work). Then, in
the Firebase console:

- **Authentication → Sign-in method** → enable **Phone**, **Email/Password**,
  and **Google**.
- **Project settings → your Android app** → add your app's SHA-1/SHA-256
  fingerprint. Both Phone auth and Google sign-in silently fail without this
  even with a correct config. `keytool -list -v -keystore
  ~/.android/debug.keystore -alias androiddebugkey -storepass android
  -keypass android` gets you the debug SHA-1 for local testing.
- If Google sign-in throws `DEVELOPER_ERROR` / `sign_in_failed` on Android,
  set `FirebaseConfig.googleServerClientId` in
  `lib/data/firebase/firebase_config.dart` to the **Web client ID** shown
  under Authentication → Sign-in method → Google → Web SDK configuration.

**b. Firestore.** `UserProfileService`
(`lib/data/firebase/firestore_user_profile_service.dart`) writes a
best-effort `users/{uid}` document — name, email, phone, owned appliances —
the moment someone finishes the "about you" step in `RegisterScreen`, for
every sign-in method. It's a no-op in mock mode and never blocks getting
into the app if the write fails. Everything else the app reads (bookings,
catalog, technicians, AMC) is still `CareRepository` in
`lib/data/mock_repository.dart` — same seam as before: write a
`FirestoreRepository implements CareRepository` and swap the one line in
`lib/state/providers.dart` when you're ready to move the rest off mock data.

**c. Payments (Razorpay).** The seam is `PaymentScreen`'s "Pay" button
(`lib/features/booking/booking_screens.dart`). Today it jumps straight to the
confirmed screen. In production, open Razorpay checkout there, and only advance
after you hear back `payment.status == captured` on the booking doc.

**d. Live tracking (Maps).** `TrackingScreen` shows a map *placeholder* and an
`etaStream` that just counts down. Replace the placeholder with
`GoogleMap`, and back `etaStream` with the technician's live location doc.

**e. Offline (technician app).** The technician screens are ported but still
read/write in-memory mock state — a real technician works in kitchens with bad
signal, so before rollout add the `drift` dep and the outbox pattern from the
build spec: queue checklist ticks, photos, and job-close events locally and
sync when connectivity returns.

---

## 6 · How this was verified (and how it wasn't)

I have no Flutter/Dart toolchain and no network access in the environment that
built this — so nothing here has been through a real compiler. What I could
do instead, and did:

- Every relative `import` in all 25 files resolves to a real file.
- Brackets/parens/braces balance across the whole project (comment- and
  string-aware, not naive counting).
- Every call site of a custom widget's named constructor (77 classes) was
  cross-checked against that widget's actual parameter list — no mismatches.
- Every `context.go`/`context.push` navigation target was checked against the
  declared routes.

None of that catches everything a real `flutter analyze` would (type errors,
missing overrides, null-safety edge cases). Treat the first `flutter pub get
&& flutter run` as the real test. If it errors, the fastest path is to paste
me the exact error — file, line, and message — rather than the whole log.

## 7 · Honest notes

- Prices, SLA windows, warranty length and cancellation terms in the mock data
  are **plausible placeholders**. Replace them with your real commercial terms
  before anyone sees a rupee figure.
- Auth (phone, email/password, Google) and the `users/{uid}` profile
  document are real once you run `flutterfire configure`; every other
  surface — bookings, tracking, technician jobs, admin console — still reads
  from `MockRepository`. Nothing else persists across app restarts yet
  outside of whatever Firebase Auth/Firestore itself keeps.
- A production rollout — Firestore behind the rest of `CareRepository`, live
  payments, offline sync for technicians in the field, and role-based access
  for admin — is still real engineering. This is a strong, on-brand
  foundation with one real backend seam proven out, not a finished product.
