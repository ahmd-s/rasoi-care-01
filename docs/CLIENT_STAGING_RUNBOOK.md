# Rasoi Care client-testing runbook

Client testing uses exactly two Android apps:

- **Customer** — `careplus_flutter`, for customer sign-in, bookings, and Kitchen Passport.
- **Partner** — `careplus_partner`, for technician workflows plus staff and owner operations.

The former standalone `careplus_admin` APK is not a client deliverable. Its operations screens are integrated into Partner and use the same Firebase identity as the backend role check.

## Staging services

- Firebase project: `rasoi-care-b78ea`.
- Render API: `https://rasoi-care-01.onrender.com`.
- Render PostgreSQL: `rasoicare-staging-db`.
- Android packages: Customer `com.careplus.care_plus`; Partner `com.rasoicare.care_plus_partner`.

Use synthetic records only. Never point a client build at production. Do not put server secrets in app source, build arguments, or this document.

## Firebase console steps still required

The local Customer and Partner Android `firebase_options.dart` files now match their staging `google-services.json` registrations. The current staging JSON files contain no Google OAuth web client, so Partner owner sign-in is not ready yet.

Before building Partner:

1. In Firebase Authentication for `rasoi-care-b78ea`, enable Google sign-in. Keep the other test providers as needed.
2. Add the SHA-1/SHA-256 fingerprints for the Partner APK signing key in Firebase project settings. If testing a locally signed release APK, use that release keystore's fingerprints.
3. Download refreshed `google-services.json` files for Customer and Partner after setup. Regenerate/update the matching Android Firebase options and set Partner's `googleServerClientId` to the staging Web client ID. Never use the production client ID.
4. Keep these project-specific files local and uncommitted unless the team explicitly chooses a safe configuration mechanism.

The owner Gmail must be verified by Google and included in Render's `STAFF_BOOTSTRAP_OWNER_EMAILS`. The backend refuses owner access when the allowlist is missing or the signed-in identity is not listed. Staff accounts must already exist in the staff roster; an uninvited Firebase user is not made staff by bootstrap.

## Render staging settings

Confirm the staging service has:

- `FIREBASE_PROJECT_ID` set to `rasoi-care-b78ea`.
- Its staging-only `DATABASE_URL` and `JWT_SECRET`.
- `STAFF_BOOTSTRAP_OWNER_EMAILS` set to the owner's Gmail address(es).
- `VISION_AI_KILL_SWITCH=1`; leave provider selection and provider credentials unset.
- CORS origins limited to the staging app/web origins that are actually used.

Do not copy production secrets or customer data into staging. Deploy the updated backend to the staging Render service only after the local checks below pass and the owner explicitly chooses the staging deploy step.

## Build the two test APKs

After the Firebase console steps are complete, build each app from its directory:

```bash
cd careplus_flutter
flutter pub get
flutter build apk --release --dart-define=API_BASE_URL=https://rasoi-care-01.onrender.com
```

```bash
cd careplus_partner
flutter pub get
flutter build apk --release --dart-define=API_BASE_URL=https://rasoi-care-01.onrender.com
```

The output is `build/app/outputs/flutter-apk/app-release.apk` in each app folder. Do not distribute the `careplus_admin` APK.

## Client-test checklist

1. Customer: sign in with a staging test identity, create a booking, and confirm it persists after reopening the app.
2. Technician: sign in with a staging phone identity, complete onboarding, and verify a technician cannot open operations data unless separately assigned a staff role.
3. Staff: invite a staff test phone from the owner account, verify the phone in staging Firebase, and confirm staff can use the operations tabs but cannot open Staff & Access, and that staff see no revenue, P&L, technician earnings or payout bank details (the backend withholds these; they are owner-only).
4. Owner: sign in with the explicitly allowlisted Gmail using Google. Confirm overview, reports, bookings, team, stock, and Staff & Access load.
5. Negative authorization: try a different verified Gmail and a staff/technician account against owner-only screens and APIs; both must be denied.
6. Vision AI: confirm Partner displays “Coming Soon,” offers no upload/analysis flow, and the backend remains kill-switched.
7. Confirm customer, technician, staff, and owner data is synthetic and isolated from production.
