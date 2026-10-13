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
import re
import json
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
    created_at      TEXT NOT NULL
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
# SERVICES_SEED so it reaches databases that were already seeded — prices
# match exactly what the app already charges, so this changes no customer-
# facing number, only makes it server-verifiable.
CUSTOMER_CATALOG_SEED = [
    ("svc_chimney_deep_clean_full", "app_chimney", "RasoiAir", "Deep clean — filters, motor, duct", 1599, 0),
    ("svc_chimney_filter_clean", "app_chimney", "RasoiAir", "Normal filter clean", 899, 0),
    ("svc_chimney_repair_visit", "app_chimney", "RasoiAir", "Repair visit and diagnosis", 399, 1),
    ("svc_chimney_install", "app_chimney", "RasoiAir", "Installation with duct work", 1699, 0),
    ("svc_chimney_uninstall", "app_chimney", "RasoiAir", "Uninstall and shift", 599, 0),
    ("svc_hob_deep_clean_full", "app_hob", "RasoiSpark", "Deep clean — burners, valves, igniters", 799, 0),
    ("svc_hob_repair_visit", "app_hob", "RasoiSpark", "Repair visit and diagnosis", 399, 1),
    ("svc_hob_install", "app_hob", "RasoiSpark", "Installation with gas line check", 699, 0),
    ("svc_hob_uninstall", "app_hob", "RasoiSpark", "Uninstall and cap the line", 399, 0),
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

# The demo owner/staff logins seed_staff() creates on first boot.
# STAFF_SEED_OWNER_PIN/STAFF_SEED_STAFF_PIN let a real deployment set its
# own PINs via environment config instead of shipping with the same
# well-known "1234" every clone of this repo starts with — the phone
# numbers and default PIN are public (they're right here in source
# control), so anyone who hasn't rotated them has a fully-known owner
# login. Set these before the first boot that creates the staff table;
# seed_staff never touches an existing row, so changing them later has no
# effect on an already-seeded deployment.
_SEED_OWNER_PIN = os.environ.get("STAFF_SEED_OWNER_PIN", "1234")
_SEED_STAFF_PIN = os.environ.get("STAFF_SEED_STAFF_PIN", "1234")

STAFF_SEED = [
    # (id, name, phone, pin, role)
    ("staff_owner", "Priya Deshmukh", "9822000001", _SEED_OWNER_PIN, "owner"),
    ("staff_ops", "Rahul Jadhav", "9822000002", _SEED_STAFF_PIN, "staff"),
]


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

    def __init__(self, pg_conn):
        self._conn = pg_conn

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

    def close(self):
        self._conn.close()


def get_db():
    if DATABASE_URL:
        import psycopg2

        pg_conn = psycopg2.connect(DATABASE_URL)
        return _PgConnection(pg_conn)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def _table_columns(conn, table_name):
    """Column names for `table_name` — works against either backend, so
    the three migrate_* functions below don't need to know which one
    they're running against."""
    if DATABASE_URL:
        rows = conn.execute(
            "SELECT column_name AS name FROM information_schema.columns "
            "WHERE table_name = ?",
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
    """Owner/staff demo logins for the admin web app, seeded once and left
    alone afterwards (real invites shouldn't be wiped by a demo reset)."""
    row = conn.execute("SELECT COUNT(*) AS n FROM staff").fetchone()
    if row["n"] > 0:
        return
    if _SEED_OWNER_PIN == "1234" or _SEED_STAFF_PIN == "1234":
        print(
            "WARNING: seeding the owner/staff accounts with the default PIN "
            "'1234' — this and the seeded phone numbers are public (they're "
            "in source control). Set STAFF_SEED_OWNER_PIN/STAFF_SEED_STAFF_PIN "
            "to real secrets before the first boot of any deployment "
            "reachable outside a trusted network."
        )
    ts = now()
    for sid, name, phone, pin, role in STAFF_SEED:
        conn.execute(
            "INSERT INTO staff (id, name, phone, pin_hash, role, active, created_at) VALUES (?,?,?,?,?,1,?)",
            (sid, name, phone, generate_password_hash(pin), role, ts),
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


def init_db():
    conn = get_db()
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
    migrate_bookings_columns(conn)
    migrate_bookings_technician_nullable(conn)
    migrate_technicians_columns(conn)
    migrate_firebase_columns(conn)
    migrate_users_columns(conn)
    migrate_home_services_columns(conn)
    seed_catalog(conn)
    migrate_add_customer_catalog_services(conn)
    seed_staff(conn)
    # Cleans up the four demo technicians and two demo bookings any
    # deployment before this fix already picked up from the old
    # always-seed-fake-data behavior in seed() above. Idempotent — a
    # no-op once they're gone — so it's safe to run on every boot rather
    # than needing a one-time migration step.
    purge_demo_seed_rows(conn)
    conn.close()


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
