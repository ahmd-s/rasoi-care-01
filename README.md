# RasoiCare backend

Serves three separate apps — Customer, Technician, and Admin — each its
own page (`/customer`, `/technician`, `/admin`), plus a landing hub at
`/`. A real Flask + SQLite REST API is the server all three call, so an
action on one device
(e.g. a technician marking a job complete) is visible to another device
(e.g. the customer's phone) as soon as it polls the API.

This has been built and tested (every endpoint below was exercised with
real HTTP requests, including a full booking → accept → advance →
complete → rate → complaint → resolve cycle, and a check that data
survives a server restart). It currently only runs on `127.0.0.1` inside
a sandbox with no public address — follow "Deploy it for real" below to
get a URL that an actual phone can reach.

## Files

- `app.py` — the Flask app and all API routes
- `database.py` — SQLite schema, seed data, connection helper
- `requirements.txt` — Python dependencies
- `Procfile` — tells hosting platforms how to start the app in production

## Run it locally (to test on one machine)

```bash
pip install -r requirements.txt
python3 app.py
```

Starts on `http://127.0.0.1:8420`. Try it:

```bash
curl http://127.0.0.1:8420/api/health
curl http://127.0.0.1:8420/api/bookings
```

A `rasoicare.db` SQLite file is created automatically on first run, seeded
with the same starting data used across the prototype apps.

## Deploy it for real (so separate phones can reach it)

Any host that runs Python works. **Render** has the simplest free path,
and this repo ships a `render.yaml` blueprint so it's a one-click deploy
— no manual build/start command entry needed:

1. Click **[Deploy to Render](https://render.com/deploy?repo=https://github.com/ankitchouria-oss/Rasoi-care)**
   (sign in with GitHub if prompted — this step has to happen in your
   own Render account, nobody else can do it for you).
2. Render reads `render.yaml`, provisions a free web service named
   `rasoicare-backend`, and generates a random `JWT_SECRET` for you.
3. Click **Apply** / **Create Web Service**. First deploy takes a
   couple of minutes.
4. Render gives you a public URL like
   `https://rasoicare-backend.onrender.com`.
5. Test it from anywhere: `curl https://rasoicare-backend.onrender.com/api/health`

Prefer doing it by hand instead of the blueprint? Same result:
**New → Web Service** → connect this repo → Render auto-detects
`requirements.txt` and `Procfile`, so the build/start commands are
already right — just click Deploy.

**Railway** and **Fly.io** work the same way (both read `Procfile` /
auto-detect Flask). Pick whichever you already have an account with.

### Persistent data (important once real customers use it)

Render's **free** web services use ephemeral disk — the SQLite file
above gets wiped on every redeploy, taking any real bookings/accounts
with it. The backend now ships a blueprint (`render.yaml`) that fixes
this by default: deploying the blueprint provisions a **PostgreSQL
database and wires `DATABASE_URL` to it automatically** — no manual
environment variable needed.

**Plan policy (read before the first deploy):**

- The blueprint's database plan is a **paid tier on purpose**. The free
  Postgres plan expires and keeps no backups — it is acceptable only as
  a short-lived throwaway preview/CI database, **never as the permanent
  production database**.
- Production must run a paid plan with automated backups, verified in
  the Render dashboard after the first deploy.
- The first boot logs which storage backend actually took effect
  (`init_db: storage backend = …`) — check it after every deploy; it
  must say PostgreSQL for any deployment holding real data.

Manual alternative (any host, no blueprint):

1. Provision a **persistent** Postgres database (paid tier for
   production; free tiers from Neon/Supabase are fine for throwaway
   dev/test databases only).
2. Copy its connection string (looks like
   `postgresql://user:password@host/dbname?sslmode=require`).
3. In the Render dashboard, open the `rasoicare-backend` service →
   **Environment** → add a variable named `DATABASE_URL` with that
   connection string as the value → save (Render redeploys
   automatically).
4. That's it — `database.py` creates the tables on Postgres exactly
   like it does on SQLite, and every booking/account from then on
   survives redeploys.

Without `DATABASE_URL` set, the backend keeps working exactly as
before (SQLite, zero setup) — but on an ephemeral host that means the
data is still wiped per redeploy, so treat SQLite as local-development
only.

### Worker model (do not scale the gunicorn worker count)

`Procfile` and `render.yaml` pin gunicorn to `--workers 1 --threads 1`
— deliberately, not as a placeholder. Rate-limit buckets, auth-backoff
counters, and cancellation OTP codes live in this one process's memory;
a second worker would split that state and silently disarm all of it.
Scale out only after moving that state to a shared store (Redis/DB).

### Important: SQLite + free hosting tiers

Free web-service tiers on Render/Railway typically use an **ephemeral
disk** — if the service restarts or redeploys, the `rasoicare.db` file
resets. That's fine for local development and throwaway deploys, but
for anything real use the Postgres setup above (blueprint or manual) —
and never the free Postgres plan for production data.

## The three apps

`customer.html`, `technician.html` and `admin.html` are each served
directly by Flask at `/customer`, `/technician` and `/admin` (see the
routes at the top of `app.py`). They call the API same-origin — no
`API_BASE` to configure — so once you deploy this app to Render/Railway/
Fly.io, all three URLs work immediately off that one deployed address,
e.g. `https://rasoicare-backend.onrender.com/customer`.

Open `/customer` and `/technician` on two different devices (or have a
customer and a technician open them independently) — they're both
talking to the same server, so actions genuinely sync between them: a
booking placed on `/customer` shows up in the `/technician` job feed
within seconds, and advancing it there is reflected live on the
customer's tracking screen and on `/admin`.

Customer sign-in is phone-number first (OTP is simulated — the demo
code `4402` auto-fills) but backed by real `/api/auth/*` JWT accounts
under the hood. The technician and admin apps have no login screen by
design (see `/api/bookings`'s auth-optional behavior in `app.py`) — they
show the operations-wide view, not a scoped one.

### Technicians: areas, verification and auto-routing

Every technician has a service `area` (a locality string like "Gangapur
Road") and a `verified` flag. Admin adds new hires from the Team tab —
they start unverified and offline, invisible to auto-routing and the
technician job feed, until admin reviews and verifies them (which also
brings them online).

When a customer books a service, `create_booking` in `app.py` auto-picks
a technician: a verified, online technician in the same area and
category first, then any verified/online technician in that category,
then any technician in that category at all (never a mismatched
specialty) as a last resort. Admin can always override the pick from a
booking's detail sheet, where the technician list is sorted with
same-area matches first.

### Admin: staff accounts, reports and stock

`/admin` is now gated by a real sign-in screen — phone + PIN, backed by a
`staff` table (separate from the customer `users` table). Two roles:

- **Owner** — sees everything, including the Reports tab's Financial P&amp;L
  card, and can invite/suspend/reinstate staff and promote/demote roles
  from the Settings tab.
- **Staff** — sees Overview, Bookings, Team, Reports (minus P&amp;L), and
  Stock, but the Settings tab is read-only (no invite button, no role
  controls).

Demo logins (seeded once, left alone by `/api/reset`): **Owner** —
`9822000001` / PIN `1234`. **Staff** — `9822000002` / PIN `1234`.

The **Reports** tab is built entirely from real data — no mock numbers —
switchable between week/month/quarter: a revenue trend bar chart, revenue
by appliance category, a technician leaderboard (jobs + revenue in the
period), and a complaint status breakdown. The owner-only P&amp;L
(gross revenue, technician payout, net margin) uses one clearly-labeled
assumption — a 65% payout rate (`TECH_PAYOUT_RATE` in `app.py`) — since
there's no real payroll ledger to draw from; everything else on the tab
is a direct aggregation of the same `bookings`/`complaints`/`technicians`
tables the rest of the app uses.

The **Stock** tab now tracks a real `inventory` table (spare parts by
SKU, quantity, reorder level) instead of a hardcoded illustrative list —
admin/staff can add items and restock them, and a banner surfaces
anything below its reorder level.

## WebView Android apps (`rasoi_web_customer`, `rasoi_web_partner`, `rasoi_web_admin`)

Three thin Flutter/WebView wrapper apps, one per role, each one loading the
real web app above (`/customer`, `/technician`, `/admin`) inside a native
Android shell instead of a browser tab. This is separate from the fuller
native Flutter apps in `careplus_flutter`/`careplus_partner`/`careplus_admin`
— these wrappers exist so the exact same server-rendered pages (and every
future change to `customer.html`/`technician.html`/`admin.html`) show up in
an installable APK with no rebuild required on the web side.

Each app has one thing to configure before it's useful: `kBackendBaseUrl` at
the top of `lib/main.dart`, currently a placeholder. Once this Flask app is
deployed (see "Deploy it for real" above), set it to that public URL and
rebuild:

```bash
cd rasoi_web_customer   # or rasoi_web_partner / rasoi_web_admin
flutter build apk --release
```

Until `kBackendBaseUrl` is set, the app shows an in-app notice instead of a
blank/broken WebView, explaining what to configure.

## API reference

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/health` | Check the server is up |
| POST | `/api/auth/register` / `/api/auth/login` | Real JWT accounts — the customer app derives email/password from the phone number |
| GET | `/api/appliances`, `/api/services` | The real catalog customer.html browses and prices bookings from |
| GET | `/api/bookings` | List bookings — only the caller's own with a Bearer token, all of them without one (what technician.html/admin.html use) |
| GET | `/api/bookings/<id>` | Get one booking |
| POST | `/api/bookings` | Create a booking — `{service_id}` (catalog price looked up server-side) or the legacy `{category, service, price, bachatSlot?}` shape |
| PATCH | `/api/bookings/<id>/advance` | Move a booking to its next status |
| PATCH | `/api/bookings/<id>/assign` | Assign or reassign the technician on a booking `{technician_id}` — what admin.html's booking detail sheet calls |
| POST | `/api/bookings/<id>/rating` | Submit ratings `{serviceRating, techRating, raiseComplaint?, complaintText?}` |
| GET | `/api/complaints` | List all complaints |
| PATCH | `/api/complaints/<id>` | Update `{response?, status?}` |
| GET | `/api/technicians` | List all technicians with live rating/job counts |
| POST | `/api/technicians` | Admin adds a technician `{name, category, area}` — starts unverified and offline |
| PATCH | `/api/technicians/<id>/verify` | Admin verifies a technician, bringing them online and into auto-routing |
| POST | `/api/staff/login` | Owner/staff sign-in `{phone, pin}` — returns a staff JWT (separate from customer auth) |
| GET | `/api/staff/me` | Current staff account (requires staff Bearer token) |
| GET | `/api/staff` | List owner/staff accounts (requires staff Bearer token) |
| POST | `/api/staff` | Owner-only: invite a staff member `{name, phone, pin, role}` |
| PATCH | `/api/staff/<id>` | Owner-only: change `{role, active}` |
| GET | `/api/inventory` | List spare-parts stock |
| POST | `/api/inventory` | Add a stock item `{name, sku, category, quantity, reorderLevel}` (requires staff Bearer token) |
| PATCH | `/api/inventory/<id>` | Update `{quantity, reorderLevel}` (requires staff Bearer token) |
| GET | `/api/stats/overview` | KPIs for the admin dashboard |
| GET | `/api/stats/reports?period=week\|month\|quarter` | Revenue/rating trends, technician leaderboard, complaint breakdown, owner-only P&L (requires staff Bearer token) |
| POST | `/api/reset` | Reset all data back to seed state |
