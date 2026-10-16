# Vision AI inspection — Stage B (OpenAI provider)

Status: **OpenAI Vision adapter is implemented; real calls remain off by
default.** The adapter uses the server-side Responses API, structured JSON
output, and the existing validation pipeline. With default configuration AI is
off: every submission is refused with `503 ai_unavailable` and Kitchen Health
scores stay technician-only.

Stage C (technician review) is implemented: see the last section. The 70/30 blend
is unchanged and `aiScore` / `combinedScore` stay `null` until a technician
accepts a valid result.

## Configuration (server environment only)

| Variable | Default | Meaning |
|---|---|---|
| `VISION_AI_PROVIDER` | unset | Selects a provider. Unset or unknown → AI disabled. |
| `VISION_AI_ENABLED` | unset | Must be exactly `1` to make the OpenAI provider selectable. This is a separate explicit operator opt-in. |
| `OPENAI_API_KEY` | unset | Required server secret. Never place it in Flutter, source control, logs, or `render.yaml`. |
| `OPENAI_VISION_MODEL` | `gpt-4.1-mini` | Server-side model name; use a model that supports image input and Structured Outputs. |
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

To opt in on a non-production server, set `VISION_AI_ENABLED=1`,
`VISION_AI_PROVIDER=openai`, and `OPENAI_API_KEY` in that server's secret
configuration. Missing any required setting leaves the provider disabled. The
kill switch (`VISION_AI_KILL_SWITCH=1`) disables it immediately. These values
are intentionally **not** added to `render.yaml`; no deployment configuration
or production service is changed by this implementation.

The adapter sends in-memory, metadata-stripped JPEGs to OpenAI with `store=false`
and image detail `auto`. It accepts at most five images / 6 MB combined, caps
the JSON response at 1,200 output tokens, and bounds each HTTP call by the
configured provider timeout (maximum 60 seconds). SDK automatic retries are
disabled; the job worker owns retries and its request budget. The existing
guardrail validator still checks every returned string and produces all labels,
recommendations, limitations, and scores on the server.

There is **no monetary spending cap**. Limits are counts of analyses. Each
attempt, including a retry or malformed-response re-ask, can incur provider
cost. Set a conservative global daily count limit and monitor provider usage;
do not describe the count limit as a monetary cap.

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
- Flutter capture/review UI, technician acceptance and the combined health
  score are later stages.
- Jobs in flight when the process dies are lost (see above). A job that was
  queued but never started is failed after the hard runtime cap instead of
  waiting forever.
- Logs contain only job ids and exception *class names* for provider and
  worker failures, never exception messages (they can carry request details).
  A real adapter must still avoid putting secrets in its own logging.
- Created-at timestamps have one-second resolution, so analyses created within
  the same second list in arbitrary order.

## Partner app UI (read-only)

The Partner app has a "Photo inspection (AI, advisory)" button on each
appliance's checklist screen (`careplus_partner/lib/features/passport/
ai_inspection_screen.dart`). It reads the config endpoint first and offers
capture only when `enabled` is true; otherwise it says AI inspection is not
available. Photos come from the camera or gallery (`image_picker`, already a
dependency; resized to 1280 px / quality 80 by the picker), are previewed and
removable, checked against the config limits (type by content, per-image and
total size, count, duplicates), held in memory only, and uploaded only when the
technician taps Analyse. Polling (2 s, easing to 5 s) stops at `completed`,
`failed` or `rejected`, after 3 consecutive network failures, or after 60
checks, and then offers "Check again". A job still running for the visit is
resumed when the screen reopens. A retry after a failed job is an explicit new
request (new `clientRequestId`); a resend after an unconfirmed network error
reuses the same id so the server replays the original job.

**The backend has no accept / edit / reject endpoint**, so the results screen
is read-only and says so. The AI condition score is shown as "visual only,
not used in the Kitchen Health score"; the app never calls the checklist or
health endpoints from this screen. Strings on the new screens are English-only,
like the other Kitchen Passport screens. Verified with Flutter widget tests
against fake API/picker objects only; not yet exercised on a device, with real
camera/gallery permission prompts, or against a real provider.

## Stage C — technician review and the combined score

**Endpoint:** `POST …/ai-inspections/<id>/review`
`{decision: accept|edit|reject, findings?: [{code, decision: confirm|reject, severity?, note?}], reason?, clientRequestId}`
(`clientRequestId` is required, 8–64 chars). `201` new decision, `200` replay.
`GET …/ai-inspections/<id>` now also returns `review` (the latest decision or
`null`) and sets `result.accepted` / `result.usedInHealthScore` **in the
response only**.

**Storage.** Decisions live in the append-only table `kitchen_ai_reviews`
(technician id, UTC timestamp, revision, per-finding decisions, reason, the
server-recomputed `reviewed_score`, and `result_sha256` of the AI result they
were made about). Rows are never updated or deleted; changing a decision adds a
revision (max 10). `kitchen_ai_inspections.result_json` is never modified.

**Who may review.** The technician who ran the analysis, on a booking still
assigned to them and not Completed/Cancelled (`409 booking_closed`). Anyone
else, any foreign appliance/booking/inspection id, gets `404`. A reassigned
booking's new technician cannot review the previous technician's analysis.

**Validation.** Only completed results with a readable stored result can be
reviewed. `accept` takes no per-finding data; `edit` must decide every finding
the AI returned (by code; none can be added), severities must be
low/medium/high/critical, at least one finding must stay confirmed (otherwise
use `reject`), notes/reasons are ≤300 chars and pass the same prohibited-claim
and untrusted-text scan as AI output. Results with unclear photos (no score)
can only be rejected. Any score the client sends is ignored.

**Score.** `accept` uses the stored server-computed condition score; `edit`
recomputes it from the confirmed findings (with the technician's severities)
using the same fixed penalties. The AI score is used only when ALL hold: the
newest completed analysis of that appliance for the visit has a latest decision
of accept/edit; it has a score; its stored result still hashes to what was
reviewed; and the technician score for the same visit exists (>= 6 of 8 checks).
Then `combinedScore = round-half-up(0.7 × technician + 0.3 × AI)`. Rejected,
unreviewed, superseded (a newer analysis exists) or tampered results change
nothing; no value is ever invented.

**Status.** `technicianScore`, coverage, checklist answers and the checklist
safety flags are never altered. The headline `status` follows the combined
score through the unchanged bands (85/70/50) but is capped at the technician's
own band, so clean photos cannot upgrade a technician-assessed
Attention/Priority/Critical appliance; and a visible safety-relevant finding
the technician confirmed holds the status below Healthy (the same cap as a
flagged checklist safety item). Both rules only ever lower a status.

**Not done in this stage:** the kitchen-level `aiScore` / `combinedScore` stay
`null` (only per-appliance rows carry them; the kitchen average is still
technician-only); no customer-facing Passport UI; no per-visit history or
trends. Verified on SQLite only (see the test suite); not on managed
PostgreSQL. Timestamps have one-second resolution, so two analyses completed in
the same second have arbitrary order for the "newest analysis" rule.
