# Safe local setup (backend + apps)

Goal: run the backend and the Flutter apps on your machine without touching
production, and without any real AI provider.

## 1. Backend (local, throwaway database)
```bash
pip install -r requirements.txt
export JWT_SECRET=local-dev-only
export RASOI_ALLOW_DEFAULT_STAFF_PIN=1      # local machine only; never on a shared/public host
python3 app.py                              # http://127.0.0.1:8420, SQLite file rasoicare.db (git-ignored)
```
Do **not** set `DATABASE_URL`, `OPENAI_API_KEY` or `VISION_AI_ENABLED` locally.

### Vision AI in test mode (optional)
```bash
export RASOI_ALLOW_FAKE_VISION=1
export VISION_AI_PROVIDER=fake
```
The fake provider fabricates findings and makes no network calls. Its results
are **simulated**: the server marks them (`simulated: true` on the inspection
and the review, set by the server and not changeable by any request), the
Partner app shows "SIMULATED — NOT A REAL INSPECTION", and a simulated result
is never used in any technician- or customer-visible health score, even if a
technician accepts it. Never set these two variables on a shared or production
environment. Real OpenAI additionally needs `VISION_AI_ENABLED=1`,
`VISION_AI_PROVIDER=openai` and `OPENAI_API_KEY`, and stays off otherwise.

## 2. Flutter apps must be given a non-production API URL
Debug and profile builds **never default to production**. Without
`API_BASE_URL` the app shows a "Backend URL not configured" screen (and talks to
an unreachable placeholder host), and a production URL passed to a debug build is
rejected the same way. Release builds (`flutter build apk --release`, as CI does)
still default to production, so shipped apps are unchanged.

| Target | Command |
|---|---|
| Android emulator | `flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8420` |
| Physical device (same Wi-Fi) | `flutter run --dart-define=API_BASE_URL=http://<your-LAN-IP>:8420` |
| Hosted staging (https) | `flutter run --dart-define=API_BASE_URL=https://<your-staging-host>` |

`10.0.2.2` is the emulator's name for your computer. Debug builds allow plain
`http://` (debug-only manifest setting); profile and release builds do not, so
use an `https` staging URL for those. `flutter test` needs no URL: tests run as
debug builds and are pointed at the placeholder host, never production.

## 3. Sign-in needs Firebase
The backend only accepts Firebase ID tokens (technicians) or its own JWT
(customers); the apps sign in through Firebase. The committed
`google-services.json` files belong to the **production** Firebase project
(`rasoi-care`). Use a separate staging Firebase project for testing: replace
`google-services.json`, set `FIREBASE_PROJECT_ID` on the backend, and enable
phone/email sign-in. Do not create test accounts in the production project.

## 4. Not covered here
- `rasoi_web_customer`, `rasoi_web_partner`, `rasoi_web_admin` are separate
  web wrappers with their own hard-coded production URL; they are not
  protected by this check.
- The "Deploy to Render" button in the README targets the client's repository;
  do not use it.
