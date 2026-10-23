"""
RasoiCare backend — database layer.

Two modes, chosen by whether DATABASE_URL is set:

- Unset (default): SQLite, a single file on disk (rasoicare.db). Zero
  setup, which makes it the right choice for local development — but
  Render's free web services have ephemeral disk, so anything written
  here is wiped on every redeploy.
- Set to a Postgres connection string (e.g. a free Neon/Render/Railway/
  Supabase database): every real booking, account, and stock change
  survives redeploys.

app.py's routes never touch this distinction — they all call
conn.execute(...)/.fetchone()/.fetchall() with `?` placeholders and
dict-style row access (row["col"]) exactly as sqlite3.Row provides.
When DATABASE_URL is set, get_db() returns a thin wrapper around a real
psycopg2/Postgres connection that accepts the same calling convention,
so nothing outside this file needs to change.
"""

import sqlite3
import os
import contextlib
import re
import json
import threading
import uuid
from datetime import datetime, timezone

DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "rasoicare.db")
DATABASE_URL = os.environ.get("DATABASE_URL")

# Every column the bookings table ends up with after SCHEMA plus the
# migrate_* functions below — the single source of truth app.py uses to
# build its blob-free list projection (BOOKING_LIST_SELECT). If you add a
# bookings column (i.e. another `ALTER TABLE bookings ADD COLUMN` branch in
# migrate_bookings_columns), add it here too: tests/test_booking_list_payload.py
# asserts this tuple against the real schema on every test run, so a missed
# entry fails CI instead of silently degrading list payloads.
BOOKINGS_COLUMNS = (
    # from SCHEMA
    "id", "category", "service", "price", "technician_id", "customer_name",
    "status", "bachat_slot", "service_rating", "tech_rating", "area",
    "created_at", "updated_at",
    # added by migrate_bookings_columns
    "user_id", "service_id", "total_amount", "lat", "lng", "in_progress_at",
    "suction_before", "suction_after", "time_on_site_min", "cancelled_at",
    "cancellation_fee", "directions", "notes", "issues_json", "payment_method",
    "start_code", "before_photo_b64", "after_photo_b64", "signature_b64",
    "scheduled_at", "address_line", "brand", "model_number", "city",
    # added by migrate_payment_columns
    "payment_mode", "amount_paid_paise", "paid_at",
)

# The base64 job-photo/signature columns — up to 12MB (photos) / 4MB
# (signature) of text each. List endpoints must never SELECT these raw;
# app.py's BOOKING_LIST_SELECT aliases them to tiny boolean expressions
# instead, while detail/audit paths keep fetching the real bytes.
BOOKINGS_BLOB_COLUMNS = ("before_photo_b64", "after_photo_b64", "signature_b64")

SCHEMA = """
CREATE TABLE IF NOT EXISTS technicians (
    id                    TEXT PRIMARY KEY,
    name                  TEXT NOT NULL,
    category              TEXT NOT NULL,
    area                  TEXT NOT NULL DEFAULT '',
    verified              INTEGER NOT NULL DEFAULT 0,
    online                INTEGER NOT NULL DEFAULT 1,
    rating                REAL NOT NULL DEFAULT 5.0,
    rating_count          INTEGER NOT NULL DEFAULT 0,
    jobs_completed        INTEGER NOT NULL DEFAULT 0,
    photo_url             TEXT,
    experience_years      INTEGER,
    id_document_url       TEXT,
    bank_account_name     TEXT,
    bank_account_number   TEXT,
    bank_ifsc             TEXT,
    pan_number            TEXT,
    application_submitted INTEGER NOT NULL DEFAULT 0
);

-- At most one current position per technician. Customer reads are always
-- authorized through their own active booking in app.py; raw location data
-- is never exposed from a public or client-writable Firestore collection.
CREATE TABLE IF NOT EXISTS technician_live_locations (
    technician_id TEXT PRIMARY KEY REFERENCES technicians(id) ON DELETE CASCADE,
    lat           REAL NOT NULL,
    lng           REAL NOT NULL,
    updated_at    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS bookings (
    id              TEXT PRIMARY KEY,
    category        TEXT NOT NULL,
    service         TEXT NOT NULL,
    price           INTEGER NOT NULL,
    technician_id   TEXT REFERENCES technicians(id),
    customer_name   TEXT NOT NULL DEFAULT 'Amit Sharma',
    status          TEXT NOT NULL DEFAULT 'Requested',
    bachat_slot     INTEGER,
    service_rating  INTEGER,
    tech_rating     INTEGER,
    area            TEXT,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS technician_ledger (
    id              TEXT PRIMARY KEY,
    technician_id   TEXT NOT NULL REFERENCES technicians(id),
    booking_id      TEXT REFERENCES bookings(id),
    kind            TEXT NOT NULL,
    amount_paise    INTEGER NOT NULL,
    reason          TEXT NOT NULL,
    created_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS booking_parts (
    id              TEXT PRIMARY KEY,
    booking_id      TEXT NOT NULL REFERENCES bookings(id),
    name            TEXT NOT NULL,
    sku             TEXT,
    qty             INTEGER NOT NULL DEFAULT 1,
    price_paise     INTEGER NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending',
    created_at      TEXT NOT NULL,
    decided_at      TEXT
);

-- A real record of the technician swapping this booking's service for a
-- different one in the same catalog category — e.g. the customer asked
-- mid-visit to upgrade a filter clean into a full deep clean. old/new
-- price are whole rupees, matching bookings.price/total_amount's own
-- convention. See update_booking_service in app.py.
CREATE TABLE IF NOT EXISTS booking_service_changes (
    id              TEXT PRIMARY KEY,
    booking_id      TEXT NOT NULL REFERENCES bookings(id),
    old_service     TEXT NOT NULL,
    new_service     TEXT NOT NULL,
    old_price       INTEGER NOT NULL,
    new_price       INTEGER NOT NULL,
    created_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS complaints (
    id              TEXT PRIMARY KEY,
    booking_id      TEXT NOT NULL REFERENCES bookings(id),
    text            TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'New',
    response        TEXT,
    created_at      TEXT NOT NULL
);

-- Replay guard for POST /api/bookings/cart: a retried/double-tapped checkout
-- sends the same Idempotency-Key and gets the original response back instead
-- of creating (and charging coins for) a second set of bookings.
CREATE TABLE IF NOT EXISTS booking_idempotency (
    user_id       TEXT NOT NULL,
    idem_key      TEXT NOT NULL,
    response_json TEXT NOT NULL,
    created_at    TEXT NOT NULL,
    PRIMARY KEY (user_id, idem_key)
);

CREATE TABLE IF NOT EXISTS counters (
    name    TEXT PRIMARY KEY,
    value   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS staff (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    phone           TEXT UNIQUE NOT NULL,
    pin_hash        TEXT NOT NULL,
    role            TEXT NOT NULL DEFAULT 'staff',
    active          INTEGER NOT NULL DEFAULT 1,
    created_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS inventory (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    sku             TEXT NOT NULL,
    category        TEXT NOT NULL,
    quantity        INTEGER NOT NULL DEFAULT 0,
    reorder_level   INTEGER NOT NULL DEFAULT 10,
    updated_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS users (
    id              TEXT PRIMARY KEY,
    email           TEXT UNIQUE NOT NULL,
    password_hash   TEXT NOT NULL,
    name            TEXT NOT NULL,
    phone           TEXT,
    created_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS appliances (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    category        TEXT NOT NULL,
    mono            TEXT NOT NULL,
    created_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS services (
    id              TEXT PRIMARY KEY,
    appliance_id    TEXT NOT NULL REFERENCES appliances(id),
    category        TEXT NOT NULL,
    name            TEXT NOT NULL,
    price           INTEGER NOT NULL,
    quick_fix       INTEGER NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS appliance_health (
    id              TEXT PRIMARY KEY,
    user_id         TEXT NOT NULL REFERENCES users(id),
    appliance_id    TEXT NOT NULL REFERENCES appliances(id),
    metric_name     TEXT NOT NULL,
    value_pct       INTEGER NOT NULL,
    status_label    TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    UNIQUE(user_id, appliance_id)
);

CREATE TABLE IF NOT EXISTS shop_orders (
    id              TEXT PRIMARY KEY,
    user_id         TEXT NOT NULL REFERENCES users(id),
    items_json      TEXT NOT NULL,
    total_paise     INTEGER NOT NULL,
    status          TEXT NOT NULL DEFAULT 'Placed',
    created_at      TEXT NOT NULL,
    payment_order_id TEXT
);

CREATE TABLE IF NOT EXISTS razorpay_payment_intents (
    order_id        TEXT PRIMARY KEY,
    user_id         TEXT NOT NULL REFERENCES users(id),
    amount_paise    INTEGER NOT NULL,
    checkout_json   TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'created',
    response_json   TEXT,
    payment_id      TEXT,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);

-- Server-verified money received against a booking. kind 'qr' rows are the
-- technician's dynamic invoice QR (one Razorpay QR code per row); a row only
-- becomes 'paid' after the server has seen a captured payment for exactly the
-- QR's amount, and razorpay_payment_id is unique so one payment can never be
-- credited to two bookings.
CREATE TABLE IF NOT EXISTS booking_payments (
    id                  TEXT PRIMARY KEY,
    booking_id          TEXT NOT NULL REFERENCES bookings(id),
    kind                TEXT NOT NULL,
    razorpay_ref        TEXT NOT NULL,
    amount_paise        INTEGER NOT NULL,
    status              TEXT NOT NULL DEFAULT 'active',
    razorpay_payment_id TEXT,
    image_url           TEXT,
    created_at          TEXT NOT NULL,
    updated_at          TEXT NOT NULL
);

-- Standalone Home Services app (separate from the RasoiCare tables
-- above), keyed by the same authenticated user id as RasoiCare's own
-- bookings — Home Services reuses the RasoiCare login rather than
-- having its own account system.
CREATE TABLE IF NOT EXISTS hs_bookings (
    id              TEXT PRIMARY KEY,
    user_id         TEXT NOT NULL REFERENCES users(id),
    service_id      TEXT NOT NULL,
    service_name    TEXT NOT NULL,
    price           INTEGER NOT NULL,
    date            TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'Requested',
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS hs_wallet (
    user_id TEXT PRIMARY KEY REFERENCES users(id),
    points  INTEGER NOT NULL DEFAULT 100
);

CREATE TABLE IF NOT EXISTS hs_wallet_tx (
    id          TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL REFERENCES users(id),
    label       TEXT NOT NULL,
    amount      INTEGER NOT NULL,
    created_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS hs_profile (
    user_id TEXT PRIMARY KEY REFERENCES users(id),
    name    TEXT NOT NULL DEFAULT '',
    plan    TEXT
);

-- Kitchen Passport (V9.7). kitchen_appliances are the customer's *own*
-- registered units (distinct from `appliances`, the service catalogue);
-- see kitchen_passport.py for the category ids and `specs` fields.
CREATE TABLE IF NOT EXISTS kitchen_appliances (
    id              TEXT PRIMARY KEY,
    user_id         TEXT NOT NULL REFERENCES users(id),
    category        TEXT NOT NULL,
    brand           TEXT NOT NULL,
    model           TEXT NOT NULL DEFAULT '',
    serial_number   TEXT NOT NULL DEFAULT '',
    install_year    INTEGER,
    specs           TEXT NOT NULL DEFAULT '{}',
    notes           TEXT NOT NULL DEFAULT '',
    registered_by   TEXT NOT NULL REFERENCES technicians(id),
    booking_id      TEXT,
    -- Duplicate identity (see kitchen_passport.py): a serial number is unique
    -- per customer + category (serial_key = case/space-folded, '' when none),
    -- and client_request_id makes a retried submit idempotent per technician.
    serial_key        TEXT NOT NULL DEFAULT '',
    client_request_id TEXT NOT NULL DEFAULT '',
    created_at      TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_kitchen_appliance_serial
    ON kitchen_appliances (user_id, category, serial_key) WHERE serial_key <> '';
CREATE UNIQUE INDEX IF NOT EXISTS ux_kitchen_appliance_request
    ON kitchen_appliances (registered_by, client_request_id) WHERE client_request_id <> '';

-- One row per checklist item per appliance per visit (a booking is the
-- visit). Saving again updates the row. See kitchen_passport.CHECKLISTS.
CREATE TABLE IF NOT EXISTS kitchen_inspection_checks (
    id              TEXT PRIMARY KEY,
    appliance_id    TEXT NOT NULL REFERENCES kitchen_appliances(id),
    booking_id      TEXT NOT NULL REFERENCES bookings(id),
    technician_id   TEXT NOT NULL REFERENCES technicians(id),
    check_key       TEXT NOT NULL,
    result          TEXT NOT NULL,
    note            TEXT NOT NULL DEFAULT '',
    updated_at      TEXT NOT NULL,
    UNIQUE(appliance_id, booking_id, check_key)
);

-- Vision AI inspection jobs (Stage A; see docs/VISION_AI.md). One row per
-- submission. NO image bytes are ever stored — only the SHA-256 of each
-- upload and the validated, guardrail-checked result. worker_id/heartbeat_at
-- give a live process ownership of its jobs; a job whose owner stops
-- heartbeating is marked failed ('interrupted') by the staleness sweep.
CREATE TABLE IF NOT EXISTS kitchen_ai_inspections (
    id                TEXT PRIMARY KEY,
    appliance_id      TEXT NOT NULL REFERENCES kitchen_appliances(id),
    booking_id        TEXT NOT NULL REFERENCES bookings(id),
    technician_id     TEXT NOT NULL REFERENCES technicians(id),
    status            TEXT NOT NULL,
    client_request_id TEXT NOT NULL DEFAULT '',
    worker_id         TEXT NOT NULL DEFAULT '',
    heartbeat_at      TEXT NOT NULL,
    provider          TEXT NOT NULL DEFAULT '',
    model             TEXT NOT NULL DEFAULT '',
    attempts          INTEGER NOT NULL DEFAULT 0,
    provider_called   INTEGER NOT NULL DEFAULT 0,
    retryable         INTEGER NOT NULL DEFAULT 0,
    error_code        TEXT NOT NULL DEFAULT '',
    error_message     TEXT NOT NULL DEFAULT '',
    image_count       INTEGER NOT NULL DEFAULT 0,
    image_hashes      TEXT NOT NULL DEFAULT '[]',
    result_json       TEXT,
    condition_score   INTEGER,
    -- 1 when a simulated (test) provider produced the result. Written by the
    -- server from the provider object that actually ran, never from a request.
    simulated         INTEGER NOT NULL DEFAULT 0,
    created_at        TEXT NOT NULL,
    started_at        TEXT,
    completed_at      TEXT,
    updated_at        TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_kitchen_ai_request
    ON kitchen_ai_inspections (technician_id, client_request_id) WHERE client_request_id <> '';
CREATE INDEX IF NOT EXISTS ix_kitchen_ai_status_heartbeat
    ON kitchen_ai_inspections (status, heartbeat_at);
CREATE INDEX IF NOT EXISTS ix_kitchen_ai_appliance_visit
    ON kitchen_ai_inspections (appliance_id, booking_id, created_at);

-- Vision AI technician review (Stage C). APPEND-ONLY: a decision is never
-- updated or deleted; a changed mind is a new revision, and the highest
-- revision is the effective one. The AI result in kitchen_ai_inspections is
-- never touched; result_sha256 binds each decision to the exact stored result
-- it was made about.
CREATE TABLE IF NOT EXISTS kitchen_ai_reviews (
    id                TEXT PRIMARY KEY,
    inspection_id     TEXT NOT NULL REFERENCES kitchen_ai_inspections(id),
    appliance_id      TEXT NOT NULL REFERENCES kitchen_appliances(id),
    booking_id        TEXT NOT NULL REFERENCES bookings(id),
    technician_id     TEXT NOT NULL REFERENCES technicians(id),
    revision          INTEGER NOT NULL,
    decision          TEXT NOT NULL,
    client_request_id TEXT NOT NULL,
    finding_decisions TEXT NOT NULL DEFAULT '[]',
    reason            TEXT NOT NULL DEFAULT '',
    reviewed_score    INTEGER,
    result_sha256     TEXT NOT NULL,
    -- Copied from the inspection at review time; a simulated result's review
    -- never feeds a health score.
    simulated         INTEGER NOT NULL DEFAULT 0,
    created_at        TEXT NOT NULL,
    UNIQUE (inspection_id, revision)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_kitchen_ai_review_request
    ON kitchen_ai_reviews (technician_id, client_request_id);
CREATE INDEX IF NOT EXISTS ix_kitchen_ai_review_visit
    ON kitchen_ai_reviews (appliance_id, booking_id);

-- Brands a technician added via "Add Brand", reusable for that appliance
-- category. name_key is the case-folded name so "bosch" and "Bosch" collide.
CREATE TABLE IF NOT EXISTS custom_brands (
    id              TEXT PRIMARY KEY,
    technician_id   TEXT NOT NULL REFERENCES technicians(id),
    category        TEXT NOT NULL,
    name            TEXT NOT NULL,
    name_key        TEXT NOT NULL,
    created_at      TEXT NOT NULL,
    UNIQUE(technician_id, category, name_key)
);
"""

APPLIANCES_SEED = [
    ("app_chimney", "Chimney", "RasoiAir", "CH"),
    ("app_hob", "Hob", "RasoiSpark", "HB"),
    ("app_cooktop", "Cooktop", "RasoiSpark", "CT"),
    ("app_microwave", "Built-in Microwave", "RasoiBuilt", "MW"),
    ("app_dishwasher", "Dishwasher", "RasoiWash", "DW"),
    ("app_fridge", "Refrigerator", "RasoiChill", "RF"),
    ("app_otg", "OTG", "RasoiBuilt", "OT"),
    ("app_purifier", "Water Purifier", "RasoiPure", "WP"),
]

# (id, appliance_id, category, name, price, quick_fix)
SERVICES_SEED = [
    ("svc_chimney_deep_cleaning", "app_chimney", "RasoiAir", "Deep Cleaning", 1600, 0),
    ("svc_chimney_low_suction", "app_chimney", "RasoiAir", "Low Suction", 399, 1),
    ("svc_chimney_noisy_motor", "app_chimney", "RasoiAir", "Noisy Motor", 499, 1),
    ("svc_hob_ignition_fix", "app_hob", "RasoiSpark", "Ignition Fix", 399, 1),
    ("svc_hob_burner_cleaning", "app_hob", "RasoiSpark", "Burner Cleaning", 299, 1),
    ("svc_cooktop_ignition_fix", "app_cooktop", "RasoiSpark", "Ignition Fix", 399, 1),
    ("svc_cooktop_autoshutoff", "app_cooktop", "RasoiSpark", "Auto-shutoff Issue", 449, 1),
    ("svc_microwave_not_heating", "app_microwave", "RasoiBuilt", "Not Heating", 599, 0),
    ("svc_microwave_door_repair", "app_microwave", "RasoiBuilt", "Door / Hinge Repair", 399, 1),
    ("svc_microwave_general", "app_microwave", "RasoiBuilt", "General Service", 349, 1),
    ("svc_dishwasher_not_draining", "app_dishwasher", "RasoiWash", "Not Draining", 549, 0),
    ("svc_dishwasher_general", "app_dishwasher", "RasoiWash", "General Service", 399, 1),
    ("svc_fridge_not_cooling", "app_fridge", "RasoiChill", "Not Cooling", 699, 0),
    ("svc_fridge_gas_refill", "app_fridge", "RasoiChill", "Gas Refill", 1200, 0),
    ("svc_fridge_general", "app_fridge", "RasoiChill", "General Service", 399, 1),
    ("svc_otg_not_heating", "app_otg", "RasoiBuilt", "Not Heating", 399, 1),
    ("svc_otg_general", "app_otg", "RasoiBuilt", "General Service", 299, 1),
    ("svc_purifier_filter_change", "app_purifier", "RasoiPure", "Filter Change", 499, 1),
    ("svc_purifier_not_purifying", "app_purifier", "RasoiPure", "Not Purifying", 399, 1),
    ("svc_purifier_annual_service", "app_purifier", "RasoiPure", "Annual Service", 349, 1),
]

# (id, appliance_id, category, name, price, quick_fix) — the deep-clean /
# repair / install / uninstall services the Customer app's Service tab has
# always shown (previously hardcoded client-side with no real catalog row
# behind them, so a booking's price could never be verified server-side).
# Added via migrate_add_customer_catalog_services below rather than
# SERVICES_SEED so it reaches databases that were already seeded. The
# versioned customer-catalog migration below applies the approved October
# price changes without resetting later admin-managed prices at each boot.
CUSTOMER_CATALOG_SEED = [
    ("svc_chimney_steam_deep_clean", "app_chimney", "RasoiAir", "Steam deep clean", 1299, 0),
    ("svc_chimney_deep_clean_full", "app_chimney", "RasoiAir", "Deep clean — filters, motor, duct", 1699, 0),
    ("svc_chimney_filter_clean", "app_chimney", "RasoiAir", "Normal filter clean", 899, 0),
    ("svc_chimney_repair_visit", "app_chimney", "RasoiAir", "Repair visit and diagnosis", 399, 1),
    ("svc_chimney_install", "app_chimney", "RasoiAir", "Installation with duct work", 1699, 0),
    ("svc_chimney_uninstall", "app_chimney", "RasoiAir", "Uninstall and shift", 599, 0),
    ("svc_hob_deep_clean_full", "app_hob", "RasoiSpark", "Deep clean — burners, valves, igniters", 799, 0),
    ("svc_hob_repair_visit", "app_hob", "RasoiSpark", "Repair visit and diagnosis", 399, 1),
    ("svc_hob_install", "app_hob", "RasoiSpark", "Installation with gas line check", 499, 0),
    ("svc_hob_uninstall", "app_hob", "RasoiSpark", "Uninstall and cap the line", 299, 0),
    ("svc_cooktop_deep_clean_full", "app_cooktop", "RasoiSpark", "Deep clean and calibration", 499, 0),
    ("svc_cooktop_repair_visit", "app_cooktop", "RasoiSpark", "Repair visit and diagnosis", 399, 1),
    ("svc_cooktop_install", "app_cooktop", "RasoiSpark", "Installation and panel fitting", 399, 0),
    ("svc_cooktop_uninstall", "app_cooktop", "RasoiSpark", "Uninstall and pack for a move", 299, 0),
    ("svc_dishwasher_deep_clean_full", "app_dishwasher", "RasoiWash", "Deep clean — filter, spray arms, seals", 1199, 0),
    ("svc_dishwasher_repair_visit", "app_dishwasher", "RasoiWash", "Repair visit and diagnosis", 599, 1),
    ("svc_dishwasher_install", "app_dishwasher", "RasoiWash", "Installation and plumbing connection", 1499, 0),
    ("svc_dishwasher_uninstall", "app_dishwasher", "RasoiWash", "Uninstall and cap the lines", 599, 0),
    ("svc_microwave_deep_clean_full", "app_microwave", "RasoiBuilt", "Deep clean and safety check", 549, 0),
    ("svc_microwave_repair_visit", "app_microwave", "RasoiBuilt", "Repair visit and diagnosis", 399, 1),
    ("svc_microwave_install", "app_microwave", "RasoiBuilt", "Built-in installation and trim kit", 999, 0),
    ("svc_microwave_uninstall", "app_microwave", "RasoiBuilt", "Uninstall and cap the housing", 599, 0),
    ("svc_otg_deep_clean_full", "app_otg", "RasoiBuilt", "Deep clean and element check", 549, 0),
    ("svc_otg_repair_visit", "app_otg", "RasoiBuilt", "Repair visit and diagnosis", 399, 1),
    ("svc_otg_install", "app_otg", "RasoiBuilt", "Installation and test bake", 999, 0),
    ("svc_otg_uninstall", "app_otg", "RasoiBuilt", "Uninstall and pack for a move", 599, 0),
]


from werkzeug.security import generate_password_hash

# The owner/staff accounts seed_staff() creates on first boot.
#
# SECURITY MODEL (fixes audit N4 — "known owner credentials on default
# deploys"): the seeded phone numbers and the built-in fallback PIN are
# public — they live in this source file, which anyone can read. Shipping a
# deployment whose owner login is a credential printed in the repo is
# equivalent to having no owner login at all. Therefore:
#
#   * Set STAFF_SEED_OWNER_PIN / STAFF_SEED_STAFF_PIN (4+ digit codes of your
#     choosing) BEFORE the first boot that creates the staff table. Seeding
#     happens exactly once; changing these later does NOT touch rows that
#     already exist (rotate via the admin invite/reset flows instead).
#   * If either variable is missing on a fresh database, seed_staff REFUSES
#     to seed and logs a loud warning instead — a deployment that meant to
#     configure it fails safe (no owner login at all) rather than failing
#     open (owner login everyone knows).
#   * RASOI_ALLOW_DEFAULT_STAFF_PIN=1 is the explicit escape hatch for local
#     development and the test suite only. Never set it on anything
#     reachable outside a trusted network.
STAFF_SEED = [
    # (id, name, phone, role) — PINs are resolved at seed time, not import
    # time, so a deployment's env config is always what actually applies.
    ("staff_owner", "Priya Deshmukh", "9822000001", "owner"),
    ("staff_ops", "Rahul Jadhav", "9822000002", "staff"),
]

# The well-known fallback PIN. Compared against by seed_staff's guard; the
# VALUE IS NEVER LOGGED anywhere (logs must not contain credentials).
_DEFAULT_STAFF_PIN = "1234"


class _PgRow(dict):
    """Postgres rows come back as plain dicts (via RealDictCursor) — this
    just adds sqlite3.Row's attribute-style access isn't needed, but
    dict already supports row["col"] and "col" in row.keys(), which is
    every access pattern app.py actually uses."""


class _PgCursor:
    """Wraps a psycopg2 cursor so callers written for sqlite3 don't need
    to change: fetchone()/fetchall() return dict-like rows."""

    def __init__(self, cur):
        self._cur = cur

    def fetchone(self):
        row = self._cur.fetchone()
        return _PgRow(row) if row is not None else None

    def fetchall(self):
        return [_PgRow(r) for r in self._cur.fetchall()]

    def close(self):
        self._cur.close()

    @property
    def rowcount(self):
        """Needed by claim_booking's atomic UPDATE ... WHERE technician_id
        IS NULL — the row count is how it tells a real claim from a race
        it just lost, exactly like sqlite3.Cursor.rowcount already works
        for the SQLite path."""
        return self._cur.rowcount


_QMARK_RE = re.compile(r"\?")


class _PgConnection:
    """Wraps a psycopg2 connection so app.py's sqlite3-style calls
    (`?` placeholders, conn.execute(...).fetchone()/.fetchall(),
    conn.executescript(...)) work unchanged against Postgres."""

    def __init__(self, pg_conn, pool=None):
        self._conn = pg_conn
        # When pool is set, close() returns the connection to the pool
        # instead of destroying it — that's the whole point of pooling
        # (skips the TCP+TLS handshake per request). Pool or no pool, the
        # sqlite3 semantics app.py relies on are preserved exactly:
        # close() with an open transaction DISCARDS the uncommitted work
        # (rollback), never leaks it into the next borrower.
        self._pool = pool

    def execute(self, sql, params=()):
        import psycopg2.extras

        cur = self._conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(_QMARK_RE.sub("%s", sql), params)
        return _PgCursor(cur)

    def executescript(self, sql):
        cur = self._conn.cursor()
        cur.execute(sql)
        cur.close()

    def commit(self):
        self._conn.commit()

    def rollback(self):
        self._conn.rollback()

    def close(self):
        if self._pool is not None:
            try:
                import psycopg2.extensions

                if self._conn.status == psycopg2.extensions.STATUS_IN_TRANSACTION:
                    self._conn.rollback()
            except Exception:
                # The connection itself is broken (server gone, network
                # drop) — hand it back flagged for destruction so the pool
                # doesn't hand a dead socket to the next request.
                self._pool.putconn(self._conn, close=True)
                return
            self._pool.putconn(self._conn)
            return
        self._conn.close()


# Postgres connection pool — deliberately small: this deployment runs
# exactly one gunicorn worker and one thread (enforced in Procfile /
# render.yaml / app.py's boot check), so typical concurrency is 1; the
# ceiling exists only so a future thread bump or an interim misconfiguration
# can't exhaust Postgres's own max_connections.
PG_POOL_MIN = 1
PG_POOL_MAX = 4

_pg_pool = None
_pg_pool_lock = threading.Lock()


def _get_pg_pool():
    """Lazily-built process-wide pool; None means 'create on first use'.
    Raises through to the caller if Postgres can't be reached (same visible
    behavior as the old connect-per-call path: the request fails)."""
    global _pg_pool
    if _pg_pool is None:
        with _pg_pool_lock:
            if _pg_pool is None:
                import psycopg2.pool

                _pg_pool = psycopg2.pool.SimpleConnectionPool(
                    PG_POOL_MIN, PG_POOL_MAX, DATABASE_URL
                )
    return _pg_pool


def get_db():
    if DATABASE_URL:
        import psycopg2

        try:
            pool = _get_pg_pool()
            pg_conn = pool.getconn()
        except Exception:
            # Pool unavailable (init failed / exhausted / broken) — fall
            # back to a direct one-off connection so the request behaves
            # exactly as it did before pooling existed.
            pg_conn = psycopg2.connect(DATABASE_URL)
            return _PgConnection(pg_conn)
        return _PgConnection(pg_conn, pool=pool)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def get_db_unpooled():
    """A connection that never touches the shared Postgres pool.

    psycopg2's SimpleConnectionPool "can't be shared across different
    threads", and get_db() draws from it. Anything running off the request
    thread (the Vision AI background worker) must use this instead: on
    Postgres it opens its own connection, and close() really closes it; on
    SQLite it is identical to get_db() (every call already opens a fresh
    connection)."""
    if DATABASE_URL:
        import psycopg2

        return _PgConnection(psycopg2.connect(DATABASE_URL))
    return get_db()


@contextlib.contextmanager
def db_session_unpooled():
    """db_session() for background threads — see get_db_unpooled()."""
    conn = get_db_unpooled()
    try:
        yield conn
        conn.commit()
    except Exception:
        try:
            conn.rollback()
        except Exception:
            pass
        raise
    finally:
        conn.close()


@contextlib.contextmanager
def db_session():
    """Error-safe replacement for the manual get_db()/commit()/close() dance:
    yields a connection, commits on clean exit (including plain `return` from
    inside the with-block), rolls back and re-raises on exception, and ALWAYS
    closes — an unexpected error can no longer leak the connection (on
    Postgres: a socket; on SQLite: an open handle + a hot journal).

    Deliberately incremental: existing handlers still calling
    get_db()/conn.close() keep working unchanged; handlers migrate to this
    one at a time, money-path booking mutations first."""
    conn = get_db()
    try:
        yield conn
        conn.commit()
    except Exception:
        try:
            conn.rollback()
        except Exception:
            pass  # a broken connection must not mask the real error
        raise
    finally:
        conn.close()


def _table_columns(conn, table_name):
    """Column names for `table_name` — works against either backend, so
    the three migrate_* functions below don't need to know which one
    they're running against."""
    if DATABASE_URL:
        # table_schema filter: without it, a same-named table in ANY schema
        # on the search_path (e.g. a leftover `temp.bookings`, or a shared
        # hosting schema) makes this return that table's columns too —
        # corrupting every migrate_* decision below with another table's
        # shape. current_schema() scopes the lookup to the schema this
        # connection actually writes to.
        rows = conn.execute(
            "SELECT column_name AS name FROM information_schema.columns "
            "WHERE table_name = ? AND table_schema = current_schema()",
            (table_name,),
        ).fetchall()
    else:
        rows = conn.execute(f"PRAGMA table_info({table_name})").fetchall()
    return {row["name"] for row in rows}


def now():
    # timezone-aware UTC, formatted exactly as the old naive utcnow() output
    # (ISO 8601 seconds precision, Z-suffixed) — identical string, no
    # deprecation warning. Every stored timestamp keeps its existing format,
    # so comparisons against stored values (updated_at >= cutoff etc.) and
    # client-side parsing are unchanged.
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def seed(conn):
    """Used to populate demo technicians/bookings for local development.
    Production no longer calls this automatically (see init_db) — a real
    deployment should start with zero technicians and zero bookings, not
    four invented technicians who'd silently keep winning every real
    customer's auto-routing and a couple of fake "Amit Sharma" bookings
    sitting in real customers' history. Kept only as an explicit opt-in
    for local/dev use via `python database.py --seed-demo`."""
    conn.executescript(
        "DELETE FROM complaints; DELETE FROM bookings; "
        "DELETE FROM technicians; DELETE FROM counters;"
    )
    conn.execute(
        "INSERT INTO technicians (id, name, category, area, verified, online, rating, rating_count, jobs_completed) "
        "VALUES (?,?,?,?,?,?,?,?,?)",
        ("ramesh", "Ramesh Kumar", "RasoiSpark", "College Road", 1, 1, 4.8, 312, 312),
    )
    for tid, name, category, area, online, rating, jobs in [
        ("suresh", "Suresh Patil", "RasoiAir", "Gangapur Road", 0, 4.6, 240),
        ("deepak", "Deepak Verma", "RasoiBuilt", "Indira Nagar", 1, 4.9, 150),
        ("anjali", "Anjali Kulkarni", "RasoiSpark", "Panchavati", 1, 4.7, 190),
    ]:
        conn.execute(
            "INSERT INTO technicians (id, name, category, area, verified, online, rating, rating_count, jobs_completed) "
            "VALUES (?,?,?,?,?,?,?,?,?)",
            (tid, name, category, area, 1, online, rating, jobs, jobs),
        )

    ts = now()
    conn.execute(
        "INSERT INTO bookings (id, category, service, price, technician_id, customer_name, status, "
        "bachat_slot, service_rating, tech_rating, area, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
        ("RC-2291", "RasoiSpark", "Ignition Fix", 399, "ramesh", "Amit Sharma", "Completed",
         None, 2, 2, "College Road", ts, ts),
    )
    conn.execute(
        "INSERT INTO bookings (id, category, service, price, technician_id, customer_name, status, "
        "bachat_slot, service_rating, tech_rating, area, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
        ("RC-1987", "RasoiAir", "Deep Cleaning", 1600, "ramesh", "Amit Sharma", "Completed",
         1, 5, 5, "Gangapur Road", ts, ts),
    )
    conn.execute(
        "INSERT INTO complaints (id, booking_id, text, status, response, created_at) VALUES (?,?,?,?,?,?)",
        ("CMP-1", "RC-2291",
         "Technician arrived 40 minutes late and the ignition issue came back within 2 days "
         "of the visit. Would like a free re-visit.",
         "New", None, ts),
    )
    conn.execute("INSERT INTO counters (name, value) VALUES ('order', 2292)")
    conn.execute("INSERT INTO counters (name, value) VALUES ('complaint', 2)")
    conn.commit()


# The exact demo rows `seed()` used to insert into every fresh production
# database. Kept as plain IDs (not a blanket DELETE) so a one-time cleanup
# can remove precisely these, and nothing a real customer or technician has
# since created, from a database that already picked up the old seed.
_DEMO_TECHNICIAN_IDS = ("ramesh", "suresh", "deepak", "anjali")
_DEMO_BOOKING_IDS = ("RC-2291", "RC-1987")
_DEMO_COMPLAINT_IDS = ("CMP-1",)
_DEMO_INVENTORY_IDS = (
    "inv_baffle_filter",
    "inv_ro_membrane",
    "inv_hob_igniter",
    "inv_dw_pump",
    "inv_fridge_gas",
)


def purge_demo_seed_rows(conn):
    """One-time cleanup for a database that already ran the old
    always-seeds-fake-data `init_db` — deletes exactly the four demo
    technicians, two demo bookings (+ their complaint), and the five demo
    stock/inventory rows by id, and nothing else. Safe to call repeatedly:
    a no-op once they're gone."""
    conn.execute(
        f"DELETE FROM complaints WHERE id IN ({','.join('?' * len(_DEMO_COMPLAINT_IDS))})",
        _DEMO_COMPLAINT_IDS,
    )
    conn.execute(
        f"DELETE FROM bookings WHERE id IN ({','.join('?' * len(_DEMO_BOOKING_IDS))})",
        _DEMO_BOOKING_IDS,
    )
    conn.execute(
        f"DELETE FROM technicians WHERE id IN ({','.join('?' * len(_DEMO_TECHNICIAN_IDS))})",
        _DEMO_TECHNICIAN_IDS,
    )
    conn.execute(
        f"DELETE FROM inventory WHERE id IN ({','.join('?' * len(_DEMO_INVENTORY_IDS))})",
        _DEMO_INVENTORY_IDS,
    )
    conn.commit()


def migrate_bookings_columns(conn):
    """Older rasoicare.db files predate the auth/catalog work and lack
    these columns. SQLite's ALTER TABLE ADD COLUMN is safe to run on an
    existing table with data, so this upgrades in place instead of
    requiring a manual db reset."""
    cols = _table_columns(conn, "bookings")
    if "user_id" not in cols:
        conn.execute("ALTER TABLE bookings ADD COLUMN user_id TEXT")
    if "service_id" not in cols:
        conn.execute("ALTER TABLE bookings ADD COLUMN service_id TEXT")
    if "total_amount" not in cols:
        conn.execute("ALTER TABLE bookings ADD COLUMN total_amount INTEGER")
        conn.execute("UPDATE bookings SET total_amount = price WHERE total_amount IS NULL")
    if "area" not in cols:
        conn.execute("ALTER TABLE bookings ADD COLUMN area TEXT")
    if "lat" not in cols:
        conn.execute("ALTER TABLE bookings ADD COLUMN lat REAL")
    if "lng" not in cols:
        conn.execute("ALTER TABLE bookings ADD COLUMN lng REAL")
    if "in_progress_at" not in cols:
        conn.execute("ALTER TABLE bookings ADD COLUMN in_progress_at TEXT")
    if "suction_before" not in cols:
        conn.execute("ALTER TABLE bookings ADD COLUMN suction_before INTEGER")
    if "suction_after" not in cols:
        conn.execute("ALTER TABLE bookings ADD COLUMN suction_after INTEGER")
    if "time_on_site_min" not in cols:
        conn.execute("ALTER TABLE bookings ADD COLUMN time_on_site_min INTEGER")
    if "cancelled_at" not in cols:
        conn.execute("ALTER TABLE bookings ADD COLUMN cancelled_at TEXT")
    if "cancellation_fee" not in cols:
        conn.execute("ALTER TABLE bookings ADD COLUMN cancellation_fee INTEGER")
    if "directions" not in cols:
        conn.execute("ALTER TABLE bookings ADD COLUMN directions TEXT")
    if "notes" not in cols:
        conn.execute("ALTER TABLE bookings ADD COLUMN notes TEXT")
    if "issues_json" not in cols:
        conn.execute("ALTER TABLE bookings ADD COLUMN issues_json TEXT")
    if "payment_method" not in cols:
        conn.execute("ALTER TABLE bookings ADD COLUMN payment_method TEXT")
    if "start_code" not in cols:
        conn.execute("ALTER TABLE bookings ADD COLUMN start_code TEXT")
    if "before_photo_b64" not in cols:
        conn.execute("ALTER TABLE bookings ADD COLUMN before_photo_b64 TEXT")
    if "after_photo_b64" not in cols:
        conn.execute("ALTER TABLE bookings ADD COLUMN after_photo_b64 TEXT")
    if "signature_b64" not in cols:
        conn.execute("ALTER TABLE bookings ADD COLUMN signature_b64 TEXT")
    if "scheduled_at" not in cols:
        # ISO 8601, customer's chosen day+slot — real enough to measure
        # "hours before service" against for the time-based cancellation
        # policy (see app.py's _cancellation_fee_for). Null for anything
        # booked before this column existed, or if the client ever omits
        # it; callers fall back to the older status-based tiers for those.
        conn.execute("ALTER TABLE bookings ADD COLUMN scheduled_at TEXT")
    if "address_line" not in cols:
        # The customer's real street address (building/floor, street, the
        # reverse-geocoded area) — previously only `area` (a short label
        # like "Home"/"Office") ever reached the backend, so a technician's
        # job screen showed that label as the entire address while the map
        # pin (lat/lng, sent separately) pointed at the real location: the
        # address text and the map disagreed. Null for bookings made
        # before this existed, or by a client that didn't send one.
        conn.execute("ALTER TABLE bookings ADD COLUMN address_line TEXT")
    if "brand" not in cols:
        # Set by the technician on-site (see PATCH .../appliance) — the
        # customer never types this, so it starts null rather than guessed.
        conn.execute("ALTER TABLE bookings ADD COLUMN brand TEXT")
    if "model_number" not in cols:
        conn.execute("ALTER TABLE bookings ADD COLUMN model_number TEXT")
    if "city" not in cols:
        # Which of the Partner app's five service cities this booking is
        # actually in — see infer_city in app.py. Distinct from `area`
        # (a short label like "Home"/"Office", never a city) and from
        # `address_line` (the free-text street address a city name might
        # or might not appear in verbatim): this is the field
        # technician_available_bookings matches against a technician's own
        # `area` (their chosen service city) for dispatch. Null for
        # bookings made before this existed, or where no city could be
        # inferred from the address/coordinates sent.
        conn.execute("ALTER TABLE bookings ADD COLUMN city TEXT")
    conn.commit()


def migrate_bookings_technician_nullable(conn):
    """Bookings used to require a technician_id at creation — one picked
    up front by _route_technician's "closest available match" logic. Real
    dispatch now works like Uber/Ola/Rapido instead: a booking is created
    unassigned and broadcast to every eligible technician, and whoever
    accepts first claims it (see /api/bookings/<id>/claim in app.py) — so
    technician_id has to be allowed to sit NULL until that happens.
    Postgres can drop the NOT NULL constraint directly; SQLite has no
    ALTER COLUMN for constraints at all, so this rebuilds the table (once,
    guarded by the notnull check below) copying whatever columns actually
    exist today rather than a hardcoded list, so it can't drift out of
    sync with migrate_bookings_columns as more columns get added later."""
    if DATABASE_URL:
        # Idempotence guard: previously this ran `DROP NOT NULL` on EVERY
        # boot. Unconditional ALTERs take an ACCESS EXCLUSIVE table lock and
        # rewrite catalog rows each boot — on a busy production database
        # that's a pointless lock queue at every deploy, and it breaks
        # read-only/limited-migration roles. Check the actual nullability
        # first and ALTER only when the constraint is genuinely still there.
        row = conn.execute(
            "SELECT is_nullable FROM information_schema.columns "
            "WHERE table_schema = current_schema() AND table_name = 'bookings' "
            "AND column_name = 'technician_id'"
        ).fetchone()
        if row is None:
            # bookings doesn't exist in this schema — SCHEMA above should
            # have created it; failing loudly beats ALTERing a phantom.
            raise RuntimeError(
                "migrate_bookings_technician_nullable: bookings.technician_id "
                "not found in the current schema"
            )
        if row["is_nullable"] == "NO":
            conn.execute("ALTER TABLE bookings ALTER COLUMN technician_id DROP NOT NULL")
            conn.commit()
        return
    info = conn.execute("PRAGMA table_info(bookings)").fetchall()
    tech_col = next((r for r in info if r["name"] == "technician_id"), None)
    if tech_col is None or not tech_col["notnull"]:
        return  # already nullable (or migrated in a previous run)
    col_defs = []
    col_names = []
    for r in info:
        name = r["name"]
        col_names.append(name)
        if name == "technician_id":
            col_defs.append("technician_id TEXT REFERENCES technicians(id)")
            continue
        parts = [name, r["type"] or "TEXT"]
        if r["pk"]:
            parts.append("PRIMARY KEY")
        elif r["notnull"]:
            parts.append("NOT NULL")
        if r["dflt_value"] is not None:
            parts.append(f"DEFAULT {r['dflt_value']}")
        col_defs.append(" ".join(parts))
    col_list = ", ".join(col_names)
    # complaints/booking_parts both hold a FOREIGN KEY REFERENCES bookings(id)
    # — with foreign_keys enforcement on (see get_db), SQLite refuses to DROP
    # a table another one still references, even mid-rebuild of that same
    # table. Off for just this script, same as SQLite's own documented
    # pattern for rebuilding a referenced table.
    conn.execute("PRAGMA foreign_keys = OFF")
    conn.executescript(
        "CREATE TABLE bookings_new (" + ", ".join(col_defs) + ");\n"
        f"INSERT INTO bookings_new ({col_list}) SELECT {col_list} FROM bookings;\n"
        "DROP TABLE bookings;\n"
        "ALTER TABLE bookings_new RENAME TO bookings;"
    )
    conn.execute("PRAGMA foreign_keys = ON")
    conn.commit()


def migrate_technicians_columns(conn):
    """Older rasoicare.db files predate the area/verification work."""
    cols = _table_columns(conn, "technicians")
    if "area" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN area TEXT NOT NULL DEFAULT ''")
    if "verified" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN verified INTEGER NOT NULL DEFAULT 0")
        # Technicians that already existed before this column shipped were
        # already live and taking real jobs — treat them as verified rather
        # than silently pulling them out of rotation.
        conn.execute("UPDATE technicians SET verified = 1")
    if "email" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN email TEXT")
    if "firebase_uid" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN firebase_uid TEXT")
        conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_technicians_firebase_uid "
            "ON technicians(firebase_uid) WHERE firebase_uid IS NOT NULL"
        )
    # KYC application fields — modelled on Urban Company's partner
    # onboarding (profile photo, experience, ID document, payout bank
    # details), collected by the Partner app's self-signup flow and
    # reviewed by the Admin app before a technician is verified.
    if "photo_url" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN photo_url TEXT")
    if "experience_years" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN experience_years INTEGER")
    if "id_document_url" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN id_document_url TEXT")
    if "bank_account_name" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN bank_account_name TEXT")
    if "bank_account_number" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN bank_account_number TEXT")
    if "bank_ifsc" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN bank_ifsc TEXT")
    if "pan_number" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN pan_number TEXT")
    if "application_submitted" not in cols:
        conn.execute(
            "ALTER TABLE technicians ADD COLUMN application_submitted INTEGER NOT NULL DEFAULT 0"
        )
        # Technicians that already existed before this column shipped were
        # already live and taking real jobs — treat their application as
        # already-submitted rather than sending them back through signup.
        conn.execute("UPDATE technicians SET application_submitted = 1")
    # Personal/financial details matching Urban Company's "Financial
    # details" screen (GST, PAN, Bank, Personal Details incl. DOB and
    # Aadhaar) — all optional, self-reported by the technician.
    if "aadhar_number" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN aadhar_number TEXT")
    if "date_of_birth" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN date_of_birth TEXT")
    if "gst_number" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN gst_number TEXT")
    # A real safety feature (matches Swiggy's Partner app "Emergency
    # details") — just a contact the technician sets for themselves, shown
    # back to them; no monitored-SOS backend needed for this to be genuine.
    if "emergency_contact_name" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN emergency_contact_name TEXT")
    if "emergency_contact_phone" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN emergency_contact_phone TEXT")
    # Dedicated Aadhaar/PAN card photo uploads (separate from the older
    # generic id_document_url) plus home address and UPI payout ID — the
    # signup flow now collects these as their own real fields/uploads.
    if "aadhar_document_url" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN aadhar_document_url TEXT")
    if "pan_document_url" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN pan_document_url TEXT")
    if "address" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN address TEXT")
    if "upi_id" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN upi_id TEXT")
    # A technician can now be skilled in more than one appliance category —
    # categories_json holds the full list (JSON array of category codes);
    # `category` is kept in sync as categories[0] so every older query that
    # still filters on the single column (job routing, reporting) keeps
    # working against at least the technician's primary skill.
    if "categories_json" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN categories_json TEXT")
    # Aadhaar's address/QR is printed on the back, not the front — collected
    # as its own upload alongside the existing front photo.
    if "aadhar_document_back_url" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN aadhar_document_back_url TEXT")
    # A passbook/cancelled-cheque photo for the admin to manually cross-check
    # against the typed bank details — there's no automatic account-
    # ownership verification (that needs a paid penny-drop KYC vendor), so
    # this feeds the same human review step Aadhaar/PAN already go through.
    if "bank_passbook_url" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN bank_passbook_url TEXT")
    # Assigned once, the moment an admin verifies a technician (see
    # verify_technician in app.py) — a short human-shareable ID for the
    # technician's own reference, distinct from their internal database id.
    if "partner_code" not in cols:
        conn.execute("ALTER TABLE technicians ADD COLUMN partner_code TEXT")
        conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_technicians_partner_code "
            "ON technicians(partner_code) WHERE partner_code IS NOT NULL"
        )
    # Self-declared once during KYC/onboarding (see update_technician_me in
    # app.py), never editable by an admin afterward — drives which
    # commission formula compute_commission_paise applies. Existing
    # technicians (from before this column existed) default to
    # 'outsourced', the more common case for a marketplace of independent
    # technicians.
    if "employment_type" not in cols:
        conn.execute(
            "ALTER TABLE technicians ADD COLUMN employment_type TEXT NOT NULL DEFAULT 'outsourced'"
        )
    conn.commit()


def migrate_firebase_columns(conn):
    """Bridges Firebase-authenticated native apps (Customer/Partner/Admin)
    onto this backend without disturbing the existing password/PIN auth
    the web apps use — each table just gains an optional firebase_uid to
    key off once a native app calls its bootstrap endpoint."""
    user_cols = _table_columns(conn, "users")
    if "firebase_uid" not in user_cols:
        conn.execute("ALTER TABLE users ADD COLUMN firebase_uid TEXT")
        conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_firebase_uid "
            "ON users(firebase_uid) WHERE firebase_uid IS NOT NULL"
        )

    staff_cols = _table_columns(conn, "staff")
    if "email" not in staff_cols:
        conn.execute("ALTER TABLE staff ADD COLUMN email TEXT")
    if "firebase_uid" not in staff_cols:
        conn.execute("ALTER TABLE staff ADD COLUMN firebase_uid TEXT")
        conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_staff_firebase_uid "
            "ON staff(firebase_uid) WHERE firebase_uid IS NOT NULL"
        )
    conn.commit()


def seed_catalog(conn):
    """Appliances/services/AMC plans are static reference data, seeded
    once and left alone by demo resets (unlike bookings/complaints)."""
    row = conn.execute("SELECT COUNT(*) AS n FROM appliances").fetchone()
    if row["n"] > 0:
        return
    ts = now()
    for aid, name, category, mono in APPLIANCES_SEED:
        conn.execute(
            "INSERT INTO appliances (id, name, category, mono, created_at) VALUES (?,?,?,?,?)",
            (aid, name, category, mono, ts),
        )
    for sid, appliance_id, category, name, price, quick_fix in SERVICES_SEED:
        conn.execute(
            "INSERT INTO services (id, appliance_id, category, name, price, quick_fix, created_at) "
            "VALUES (?,?,?,?,?,?,?)",
            (sid, appliance_id, category, name, price, quick_fix, ts),
        )
    conn.commit()


def seed_staff(conn):
    """Owner/staff logins for the admin web app, seeded once on the first
    boot of a fresh database (the staff table is empty) and left alone
    afterwards — real invites shouldn't be wiped by a demo reset.

    Fail-safe credential policy (audit N4): without explicit configuration
    this REFUSES to create any staff account rather than silently minting a
    login whose credential is public in the repo. See the STAFF_SEED comment
    above for the exact contract. PIN values are never logged."""
    row = conn.execute("SELECT COUNT(*) AS n FROM staff").fetchone()
    if row["n"] > 0:
        return

    owner_pin = (os.environ.get("STAFF_SEED_OWNER_PIN") or "").strip()
    staff_pin = (os.environ.get("STAFF_SEED_STAFF_PIN") or "").strip()
    allow_default = os.environ.get("RASOI_ALLOW_DEFAULT_STAFF_PIN") == "1"

    if not owner_pin or not staff_pin:
        if not allow_default:
            print(
                "SECURITY: refusing to seed owner/staff accounts — "
                "STAFF_SEED_OWNER_PIN/STAFF_SEED_STAFF_PIN are not both set, and "
                "seeding them with the built-in fallback credential would give "
                "anyone who reads this repo a known owner login. Set both "
                "variables before the first boot of any deployment (or set "
                "RASOI_ALLOW_DEFAULT_STAFF_PIN=1 for throwaway local "
                "development only). The admin app will have no PIN login until "
                "then; Firebase sign-in + the owner-email allowlist path "
                "(STAFF_BOOTSTRAP_OWNER_EMAILS) is unaffected.",
                flush=True,
            )
            return
        print(
            "WARNING: seeding owner/staff accounts with the built-in fallback "
            "credential because RASOI_ALLOW_DEFAULT_STAFF_PIN=1. This is only "
            "acceptable on a machine/instance nobody outside a trusted network "
            "can reach — never on a public deployment.",
            flush=True,
        )
        owner_pin = owner_pin or _DEFAULT_STAFF_PIN
        staff_pin = staff_pin or _DEFAULT_STAFF_PIN
    elif owner_pin == _DEFAULT_STAFF_PIN or staff_pin == _DEFAULT_STAFF_PIN:
        # Configured, but configured TO the public value — same exposure as
        # not configuring it at all. Loud warning, still seeds (the operator
        # may have deliberately chosen it), value never printed.
        print(
            "SECURITY: STAFF_SEED_OWNER_PIN/STAFF_SEED_STAFF_PIN is set to the "
            "credential value that is public in this repository — every reader "
            "of the repo knows it. Choose a different value before first boot "
            "of any deployment reachable outside a trusted network.",
            flush=True,
        )

    ts = now()
    pins = {"staff_owner": owner_pin, "staff_ops": staff_pin}
    for sid, name, phone, role in STAFF_SEED:
        conn.execute(
            "INSERT INTO staff (id, name, phone, pin_hash, role, active, created_at) VALUES (?,?,?,?,?,1,?)",
            (sid, name, phone, generate_password_hash(pins[sid]), role, ts),
        )
    conn.commit()


def migrate_home_services_columns(conn):
    """Home Services used to be a single-user prototype (one fixed row,
    id=1, in hs_wallet/hs_profile, and no owner on hs_bookings/hs_wallet_tx).
    It now reuses the RasoiCare login, so every row needs a user_id. Older
    databases predate that column; add it in place rather than dropping
    the old prototype's rows. The old id=1 wallet/profile rows (if any)
    are simply orphaned — nothing reads them by id anymore."""
    cols = _table_columns(conn, "hs_bookings")
    if "user_id" not in cols:
        conn.execute("ALTER TABLE hs_bookings ADD COLUMN user_id TEXT")
    cols = _table_columns(conn, "hs_wallet")
    if "user_id" not in cols:
        conn.execute("ALTER TABLE hs_wallet ADD COLUMN user_id TEXT")
    cols = _table_columns(conn, "hs_wallet_tx")
    if "user_id" not in cols:
        conn.execute("ALTER TABLE hs_wallet_tx ADD COLUMN user_id TEXT")
    cols = _table_columns(conn, "hs_profile")
    if "user_id" not in cols:
        conn.execute("ALTER TABLE hs_profile ADD COLUMN user_id TEXT")
    conn.commit()


def migrate_vision_simulated_columns(conn):
    """Adds the `simulated` marker to Vision AI tables created before it
    existed, and backfills it for results a fake provider already produced
    (identified by the provider/model the server recorded). Idempotent."""
    for table in ("kitchen_ai_inspections", "kitchen_ai_reviews"):
        if "simulated" not in _table_columns(conn, table):
            conn.execute(f"ALTER TABLE {table} ADD COLUMN simulated INTEGER NOT NULL DEFAULT 0")
    # No literal % in SQL: the Postgres wrapper hands every query to psycopg2 with a
    # params tuple, which would read it as a format character (see tests/test_sql_percent_guard.py).
    conn.execute("UPDATE kitchen_ai_inspections SET simulated = 1 "
                 "WHERE simulated = 0 AND (provider = 'fake' OR substr(model, 1, 4) = 'fake')")
    conn.execute("UPDATE kitchen_ai_reviews SET simulated = 1 WHERE simulated = 0 AND inspection_id IN "
                 "(SELECT id FROM kitchen_ai_inspections WHERE simulated = 1)")
    conn.commit()


def migrate_users_columns(conn):
    """Care Coins loyalty balance — earned automatically when a booking is
    marked Completed (2% of its real total, see advance_booking in app.py),
    redeemable at checkout via POST /api/me/coins/redeem. 1 coin = ₹1."""
    cols = _table_columns(conn, "users")
    if "coins_balance" not in cols:
        conn.execute("ALTER TABLE users ADD COLUMN coins_balance INTEGER NOT NULL DEFAULT 0")
    conn.commit()


def migrate_add_customer_catalog_services(conn):
    """Idempotently inserts CUSTOMER_CATALOG_SEED's rows — safe to run on
    every boot (rows already present, keyed on the primary key `id`, are
    skipped) so it reaches databases seed_catalog already ran on long ago.

    `INSERT OR IGNORE` is SQLite-only syntax; Postgres needs
    `ON CONFLICT ... DO NOTHING` instead. Getting this wrong isn't a
    no-op — it's a syntax error from init_db() on every single boot
    against Postgres, which crash-loops gunicorn and leaves Render stuck
    serving whatever build last deployed successfully. That's exactly
    what happened here: this line shipped in #83, and every deploy since
    (including #84's dispatch fix) silently failed to go live for over a
    week while the app kept serving August 29's build."""
    ts = now()
    insert = "INSERT" if DATABASE_URL else "INSERT OR IGNORE"
    on_conflict = "ON CONFLICT (id) DO NOTHING" if DATABASE_URL else ""
    for sid, appliance_id, category, name, price, quick_fix in CUSTOMER_CATALOG_SEED:
        conn.execute(
            f"{insert} INTO services (id, appliance_id, category, name, price, quick_fix, created_at) "
            f"VALUES (?,?,?,?,?,?,?) {on_conflict}",
            (sid, appliance_id, category, name, price, quick_fix, ts),
        )
    conn.commit()


def migrate_customer_catalog_price_updates(conn):
    """Apply the October customer-approved catalogue changes once.

    Seed rows are normally insert-only so admin-managed prices survive later
    boots. This versioned migration intentionally updates only the three
    requested existing prices; the steam service is added by the seed above.
    """
    conn.execute(
        "CREATE TABLE IF NOT EXISTS schema_migrations "
        "(version TEXT PRIMARY KEY, applied_at TEXT NOT NULL)"
    )
    version = "customer_catalog_steam_and_prices_2026_10"
    if conn.execute("SELECT 1 FROM schema_migrations WHERE version = ?", (version,)).fetchone():
        return
    for service_id, price in (
        ("svc_chimney_deep_clean_full", 1699),
        ("svc_hob_install", 499),
        ("svc_hob_uninstall", 299),
    ):
        conn.execute("UPDATE services SET price = ? WHERE id = ?", (price, service_id))
    insert = "INSERT" if DATABASE_URL else "INSERT OR IGNORE"
    on_conflict = "ON CONFLICT (version) DO NOTHING" if DATABASE_URL else ""
    conn.execute(
        f"{insert} INTO schema_migrations (version, applied_at) VALUES (?, ?) {on_conflict}",
        (version, now()),
    )
    conn.commit()


def init_db():
    conn = get_db()
    try:
        _init_db_contents(conn)
    finally:
        # A migration that raises mid-init must not leak the connection —
        # on Postgres that's a socket (pooled close() rolls back dirty
        # transactions first), on SQLite an open handle with a hot journal.
        conn.close()


def _init_db_contents(conn):
    # Boot-time proof of which storage backend actually took effect — the
    # silent-failure mode this guards against is the exact C1 incident: a
    # deploy that meant to use Postgres but didn't get DATABASE_URL set falls
    # back to SQLite on ephemeral disk and everything written is lost on the
    # next redeploy. The connection string itself is deliberately never
    # logged — it embeds the database password.
    if DATABASE_URL:
        print("init_db: storage backend = PostgreSQL (persistent, from DATABASE_URL)", flush=True)
    else:
        print(
            f"init_db: storage backend = SQLite at {DB_PATH} — data is lost on "
            "ephemeral hosts on every redeploy; set DATABASE_URL to a persistent "
            "Postgres instance for production",
            flush=True,
        )
    conn.executescript(SCHEMA)
    conn.commit()
    migrate_shop_orders_payment_order_id(conn)
    migrate_payment_columns(conn)
    migrate_bookings_columns(conn)
    migrate_bookings_technician_nullable(conn)
    migrate_technicians_columns(conn)
    migrate_firebase_columns(conn)
    migrate_users_columns(conn)
    migrate_vision_simulated_columns(conn)
    migrate_home_services_columns(conn)
    seed_catalog(conn)
    migrate_add_customer_catalog_services(conn)
    migrate_customer_catalog_price_updates(conn)
    seed_staff(conn)
    # Cleans up the four demo technicians and two demo bookings any
    # deployment before this fix already picked up from the old
    # always-seed-fake-data behavior in seed() above. Idempotent — a
    # no-op once they're gone — so it's safe to run on every boot rather
    # than needing a one-time migration step.
    purge_demo_seed_rows(conn)


def migrate_shop_orders_payment_order_id(conn):
    """Add the payment reference used to make paid shop checkouts replay-safe."""
    if DATABASE_URL:
        conn.execute("ALTER TABLE shop_orders ADD COLUMN IF NOT EXISTS payment_order_id TEXT")
    else:
        columns = {row["name"] for row in conn.execute("PRAGMA table_info(shop_orders)").fetchall()}
        if "payment_order_id" not in columns:
            conn.execute("ALTER TABLE shop_orders ADD COLUMN payment_order_id TEXT")
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS shop_orders_payment_order_id_uq "
        "ON shop_orders(payment_order_id) WHERE payment_order_id IS NOT NULL"
    )
    conn.commit()


def migrate_payment_columns(conn):
    """Pay-now / pay-after-service tracking on bookings, the captured payment id
    on payment intents, and the uniqueness guards on booking_payments."""
    def add(table, column, ddl):
        if DATABASE_URL:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN IF NOT EXISTS {column} {ddl}")
        else:
            cols = {r["name"] for r in conn.execute(f"PRAGMA table_info({table})").fetchall()}
            if column not in cols:
                conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {ddl}")

    add("bookings", "payment_mode", "TEXT")
    add("bookings", "amount_paid_paise", "INTEGER NOT NULL DEFAULT 0")
    add("bookings", "paid_at", "TEXT")
    add("razorpay_payment_intents", "payment_id", "TEXT")
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS booking_payments_payment_id_uq "
        "ON booking_payments(razorpay_payment_id) WHERE razorpay_payment_id IS NOT NULL"
    )
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS booking_payments_one_active_qr_uq "
        "ON booking_payments(booking_id) WHERE kind = 'qr' AND status = 'active'"
    )
    conn.commit()


def next_id(conn, counter_name, prefix):
    """Mints the next human-facing id (RC-7, CMP-3) from the named counter.

    Atomically, per backend:

    - Postgres: one `INSERT ... ON CONFLICT DO UPDATE ... RETURNING` — the
      row lock taken by the UPDATE itself serializes concurrent minters, so
      two simultaneous creations can never observe the same value. (The old
      SELECT-then-UPDATE here was a read-modify-write race: under concurrent
      load both requests read the same value, both minted e.g. RC-41, and
      the second booking INSERT died on the bookings primary key with a 500.)
    - SQLite: same read-modify-write shape, but inside BEGIN IMMEDIATE so
      the database's write lock is taken before the read — concurrent
      minters queue instead of interleaving. (If a transaction is somehow
      already open on this connection we can't upgrade it; the fallback is
      still safe — the loser's UPDATE hits SQLite's busy/lock error and the
      request fails loudly rather than minting a duplicate.)

    Callers must commit() (as every handler does) — the counter value only
    becomes visible to other requests at commit, so an aborted handler just
    releases the number back, and no id is ever burned by a failed request.
    """
    if DATABASE_URL:
        row = conn.execute(
            "INSERT INTO counters (name, value) VALUES (?, 1) "
            "ON CONFLICT (name) DO UPDATE SET value = counters.value + 1 "
            "RETURNING value",
            (counter_name,),
        ).fetchone()
        return f"{prefix}-{row['value']}"
    if not conn.in_transaction:
        conn.execute("BEGIN IMMEDIATE")
    row = conn.execute("SELECT value FROM counters WHERE name = ?", (counter_name,)).fetchone()
    if row is None:
        # Used to always exist because seed() unconditionally inserted the
        # 'order'/'complaint' counters alongside its demo data. Now that a
        # fresh database starts with no demo data at all, the first real
        # booking/complaint has to create its own counter starting at 1.
        conn.execute("INSERT INTO counters (name, value) VALUES (?, 1)", (counter_name,))
        value = 1
    else:
        value = row["value"]
    conn.execute("UPDATE counters SET value = ? WHERE name = ?", (value + 1, counter_name))
    return f"{prefix}-{value}"


def new_uuid_id(prefix):
    """IDs for entities outside the demo-reset lifecycle (users, AMC
    subscriptions) — not counter-based, so a demo /api/reset can't
    collide them with previously-issued ids."""
    return f"{prefix}-{uuid.uuid4().hex[:10]}"
