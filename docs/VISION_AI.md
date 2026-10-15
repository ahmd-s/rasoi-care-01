# Vision AI inspection — Stage A (plumbing only)

Status: **no real AI provider is integrated.** Stage A adds the server-side
plumbing, guardrails and tests, exercised only with a deterministic fake
provider. With default configuration AI is **off**: every submission is refused
with `503 ai_unavailable` and the Kitchen Health scores stay technician-only.

Not in this stage: Flutter photo capture/review UI, technician acceptance, and
any change to the Kitchen Health formula. `aiScore` and `combinedScore` in the
health endpoints remain `null`.

## Configuration (server environment only)

| Variable | Default | Meaning |
|---|---|---|
| `VISION_AI_PROVIDER` | unset | Selects a provider. Unset or unknown → AI disabled. No real provider exists yet. |
| `RASOI_ALLOW_FAKE_VISION` | unset | Must be `1` before the `fake` provider can be selected (tests / local demos only). |
| `VISION_AI_KILL_SWITCH` | unset | `1` disables AI immediately, whatever else is set. Takes effect on restart of the process environment. |
| `VISION_AI_MAX_SUBMISSIONS_PER_VISIT` | `3` | Per appliance per visit (provisional). |
| `VISION_AI_TECH_DAILY_LIMIT` | `20` | Per technician per UTC day. |
| `VISION_AI_GLOBAL_DAILY_LIMIT` | `500` | Analyses per UTC day across everyone; `0` = unlimited. |
| `VISION_AI_PROVIDER_TIMEOUT` | `45` | Seconds a provider adapter may wait on one call. |
| `VISION_AI_STALE_SECONDS` | `120` | No heartbeat for this long → job is marked interrupted (never below 3× the keeper interval). |
| `VISION_AI_KEEPER_SECONDS` | `30` | Heartbeat / sweep interval. |
| `VISION_AI_MAX_RUNTIME_SECONDS` | `180` | Hard cap on one job's running time. |
| `VISION_AI_MAX_IMAGE_BYTES` / `_MAX_TOTAL_BYTES` / `_MAX_PIXELS` / `_MAX_DIMENSION` | 1.5 MB / 6 MB / 24 MP / 8000 px | Upload limits. |

A real provider's credentials must be **server environment variables only**
(like `HTTPSMS_API_KEY`). They must never appear in the Flutter apps, in the
repository, in `render.yaml` values, in logs or in any API response. These
variables are intentionally **not** added to `render.yaml`: production
configuration is unchanged by Stage A.

There is **no monetary spending cap**. Limits are counts of analyses. A
spend cap needs a chosen provider's real pricing and has not been implemented
or tested; do not describe the limits above as one.

## Endpoints (technician Firebase auth, assigned booking required)

- `GET  /api/technician/ai-inspection/config` — enabled flag, limits, privacy notice.
- `POST /api/technician/bookings/<b>/kitchen/appliances/<a>/ai-inspections` —
  `{images: [{data: base64, mimeType?}], clientRequestId?}`, 1–5 images.
  `202` queued (or `200` when `clientRequestId` replays an existing job).
  Refused with `404` (not assigned / foreign appliance), `409 booking_closed`,
  `400` (invalid images), `429` (limits), `503` (`ai_unavailable`, `busy`,
  `circuit_open`).
- `GET  …/ai-inspections` and `GET …/ai-inspections/<id>` — status and the
  validated result. Readable on closed bookings.

Job states: `queued → running → completed | failed | rejected`.

## How a job runs

1. The request is authenticated, ownership-checked, limit-checked and its
   images are validated and re-encoded; a `queued` row is created and the
   request returns immediately.
2. A daemon worker thread (2 at most) claims the row with a conditional update,
   calls the provider (retrying transient errors with backoff, at most 3 calls
   including one re-ask for a malformed reply), validates the reply and stores
   the result.
3. The Partner app polls the status endpoint.

Every state change after submission is `UPDATE … WHERE id = ? AND worker_id =
<this process> AND status = <expected>`. A superseded or stale worker therefore
cannot overwrite a newer state; its result is discarded.

The worker uses its own **unpooled** database connection
(`database.get_db_unpooled`): psycopg2's `SimpleConnectionPool`, used by
`get_db()`, is not thread-safe.

## What happens if the process restarts

Images exist only in the memory of the process that received them (they are
never written to disk or the database), so **an in-flight job cannot be
resumed**. Such a job is marked `failed`, `retryable`, error `interrupted`,
once its heartbeat is older than the stale period (default 120 s), by a sweep
that runs on status/list/submit requests and from the keeper thread. The
technician must resubmit the photos (the Stage B app keeps them in memory
until a final state). The system never pretends a job resumed.

- Interrupted jobs (and jobs turned away as `busy`) that made **no provider
  call** do not count toward any submission limit.
- During an overlapping deploy the old instance keeps heartbeating its own
  jobs; the new instance's sweep leaves them alone. Only the owner process id
  can complete a job.
- A provider call that hangs past the hard runtime cap stops being
  heartbeated and is failed as `timeout`; its thread stays blocked until the
  provider's own socket timeout fires, so real adapters **must** set one.
- The circuit breaker and rate counters are in process memory and reset on
  restart (as the app's other rate state does).

## Guardrails (visible evidence only)

- Per-appliance **allowlist of finding codes** for visible defects. Anything
  else rejects the whole result.
- Required evidence text (15–200 chars) and **photo references** for every
  finding; low-confidence (< 0.6) findings are dropped.
- Every string in the provider reply — used or not — is scanned for
  prohibited claims (hidden mechanical, electrical, gas, compressor,
  refrigerant, magnetron, pump, motor, temperature/performance faults; for RO:
  TDS, membrane rejection, pump pressure, UV output, filter life) and for
  untrusted text (URLs, HTML, instruction-like phrases). **One hit rejects the
  entire result.** The scan is a backstop and cannot catch every phrasing; the
  allowlist and server-written text are the primary controls.
- Labels, recommendations, limitations, summary, urgency and the condition
  score are produced by the server. A model-supplied score is ignored.
- Text visible in a photo is untrusted data; model output only ever reaches the
  database as JSON text via parameterised queries and the API as JSON strings.
- AI-detected visible safety defects add a technician-review reason; they do
  **not** change any health score or status in this stage.
- The condition score (100 − 5/15/30/50 per low/medium/high/critical finding)
  is a *visual* score only. A clean set of photos scores 100; that is not a
  statement about hidden faults (see `limitations` in every result).

## Privacy and legal — review before any real use

Photos of customers' homes can capture people, documents and other sensitive
information. Before a real provider or real customer images are used:

- Review the chosen provider's terms: data retention, training on inputs,
  sub-processors, data location, and whether a zero-retention option exists.
- Update and review the privacy policy and the customer-facing consent
  wording (`/privacy`) to cover photo analysis by a third-party provider.
- Have the obligations under applicable Indian data-protection law
  (including the Digital Personal Data Protection Act, 2023) reviewed by
  qualified counsel. This document is not legal advice.
- The Partner app must show the privacy notice returned by the config endpoint
  ("Keep people, documents and any sensitive information out of frame").
- Development and tests use synthetic images only. Never use real customer
  photos in tests.

Retention in this stage: **no image is persisted.** Only the SHA-256 of each
original upload, the validated result and job metadata are stored.

## Known limitations

- **PostgreSQL.** The full backend suite, including every Vision AI test, was
  run against a real PostgreSQL 16.2 server (a throwaway local instance) and
  passed. That covers the `INSERT … SELECT … WHERE (counts) … ON CONFLICT DO
  NOTHING` limit check, the partial unique indexes, conditional state
  transitions and the unpooled connection. It has **not** been run against
  Render's managed Postgres (version and settings may differ) or under real
  multi-instance load.
- **Submission limits across instances.** On Postgres (READ COMMITTED) two
  overlapping transactions can both count the same rows and both insert. A
  deterministic overlap test reproduced exactly that (two jobs created with a
  limit of 1), so creation now takes a transaction-scoped advisory lock
  (`pg_advisory_xact_lock`), and the same test passes. The lock serialises *all*
  Vision AI submission inserts for the few milliseconds of the insert. SQLite
  needs nothing (single writer lock).
- **Clocks.** Heartbeats and staleness use each process's own clock
  (`database.now()`), not the database clock. Instances with clocks skewed by a
  large fraction of the stale period (default 120 s) could misjudge a peer's
  jobs; Render instances are NTP-synced, and the margin is generous.
- Real provider adapters, Flutter capture/review UI, technician acceptance and
  the combined health score are later stages.
- Jobs in flight when the process dies are lost (see above). A job that was
  queued but never started is failed after the hard runtime cap instead of
  waiting forever.
- Logs contain only job ids and exception *class names* for provider and
  worker failures, never exception messages (they can carry request details).
  A real adapter must still avoid putting secrets in its own logging.
- Created-at timestamps have one-second resolution, so analyses created within
  the same second list in arbitrary order.
