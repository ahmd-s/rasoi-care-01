# Customer Kitchen Passport (Stage D)

Customer app: Account → Your Rasoi Care → **Kitchen Passport** (`/passport`).
Backend: `GET /api/kitchen-passport/overview` (customer bearer token; every
query is scoped to the token's own user — another customer's token sees only
their own, and a technician-only or missing token gets 401).

## What it shows (all read from the server, nothing computed or invented in the app)
- **Kitchen Health Score** — the existing kitchen average of technician scores
  (unchanged formula and 85/70/50 bands), with how many appliances were
  assessed. No score → "No score yet", never 0.
- **Per appliance** — score and status, checks tested, flagged item labels,
  safety flag, and whether an accepted photo review is part of the score.
- **Needs attention** — appliances that are Attention/Priority/Critical or
  safety-flagged, most urgent first.
- **Next recommended service** — the most urgent appliance's guidance. The
  mapping reuses the project's own urgency table (critical → urgent, 0 days;
  priority → 7; attention → soon, 21; healthy → routine, 35); a flagged safety
  item counts as at least "priority". No status → no recommendation.
- **Service history** — per appliance, the real past visits at which a
  technician recorded checks (service name, date, that visit's technician-only
  score/status), newest first, max 10. Only bookings owned by the customer
  can appear. "Not scored" when a visit had too few checks.

## What it deliberately does not show
Technician notes, booking/technician ids, serial numbers, AI scores, findings,
evidence or inspection ids. A technician-**accepted** AI review can raise or
lower an appliance's score through the existing 70/30 blend (labelled "reviewed
photo analysis"); unreviewed, rejected or superseded AI never affects it.

## Limits
- Wording comes from localized strings (en/hi/mr). Hindi and Marathi text was
  written without a native reviewer — have it reviewed. Checklist item labels
  ("Ignition", …) come from the server and are English only.
- Kitchen-level score is still the technician average (the photo-review blend
  exists per appliance only).
- History covers visits with recorded checklists, not every booking; the full
  booking list stays under Bookings.
- Verified with unit/widget tests and SQLite; not on a device, managed
  PostgreSQL, or real Firebase.
