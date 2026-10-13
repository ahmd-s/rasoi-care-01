"""P1-03 tests — migration idempotence (SQLite-runnable part).

init_db() runs on EVERY boot and is also re-runnable via staff-only
POST /api/reset, so running it twice must be a clean no-op: identical
schema, no errors, seed rows not duplicated. The Postgres twin of this
file (test_migrations_postgres.py) covers the same guarantees against a
real Postgres when TEST_DATABASE_URL is provided.
"""
import os

import pytest

import database

# These tests inspect SQLite internals (sqlite_master / PRAGMA table_info).
# In Postgres mode (TEST_DATABASE_URL set) their subject matter is covered
# by test_migrations_postgres.py instead.
pytestmark = pytest.mark.skipif(
    bool(os.environ.get("TEST_DATABASE_URL")),
    reason="SQLite-only internals — Postgres equivalents live in test_migrations_postgres.py",
)


def test_double_init_db_is_clean_noop(client):
    """init_db() already ran once (the client fixture); run it again and
    make sure nothing errors and the database is byte-for-byte equivalent
    in shape and seed content."""
    def snapshot(conn):
        tables = [
            r["name"] for r in conn.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            ).fetchall()
        ]
        schema = conn.execute(
            "SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY type, name"
        ).fetchall()
        catalog = conn.execute("SELECT COUNT(*) AS n FROM services").fetchone()["n"]
        staff = conn.execute("SELECT COUNT(*) AS n FROM staff").fetchone()["n"]
        return tables, [tuple(r) for r in schema], catalog, staff

    conn = database.get_db()
    before = snapshot(conn)
    conn.close()

    database.init_db()  # second boot
    database.init_db()  # and a third, for good measure

    conn = database.get_db()
    after = snapshot(conn)
    conn.close()
    assert before == after


def test_technician_nullable_migration_does_not_rebuild_after_first_run(client):
    """SQLite's technician_id-nullable path rebuilds the bookings table the
    first time it sees a NOT NULL column — a fresh SCHEMA-created database
    already has it nullable, so no rebuild may ever run (the pragma says
    notnull=0 → early return). Assert the column is nullable and the table
    wasn't rebuilt (same integer root page / no bookings_new leftovers)."""
    conn = database.get_db()
    info = conn.execute("PRAGMA table_info(bookings)").fetchall()
    tech_col = next(r for r in info if r["name"] == "technician_id")
    leftovers = conn.execute(
        "SELECT COUNT(*) AS n FROM sqlite_master WHERE name LIKE 'bookings_new%'"
    ).fetchone()["n"]
    conn.close()
    assert tech_col["notnull"] == 0
    assert leftovers == 0


def test_rebuild_path_migrates_data_when_needed(client):
    """Force the SQLite rebuild path: construct an old-style database with
    technician_id NOT NULL plus a data row, run the migration, and check the
    row survives with the column now nullable."""
    import os
    import tempfile

    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    old = database.DATABASE_URL
    original_path = database.DB_PATH
    database.DATABASE_URL = None
    database.DB_PATH = path
    try:
        conn = database.get_db()
        # minimal old-world schema: technician_id NOT NULL, one legacy column
        conn.executescript(
            "CREATE TABLE technicians (id TEXT PRIMARY KEY, name TEXT NOT NULL, "
            "category TEXT NOT NULL, area TEXT NOT NULL DEFAULT '', verified INTEGER NOT NULL DEFAULT 0, "
            "online INTEGER NOT NULL DEFAULT 1, rating REAL NOT NULL DEFAULT 5.0, "
            "rating_count INTEGER NOT NULL DEFAULT 0, jobs_completed INTEGER NOT NULL DEFAULT 0);"
            "CREATE TABLE bookings (id TEXT PRIMARY KEY, category TEXT NOT NULL, service TEXT NOT NULL, "
            "price INTEGER NOT NULL, technician_id TEXT NOT NULL REFERENCES technicians(id), "
            "customer_name TEXT NOT NULL DEFAULT 'X', status TEXT NOT NULL DEFAULT 'Requested', "
            "created_at TEXT NOT NULL, updated_at TEXT NOT NULL);"
            "CREATE TABLE counters (name TEXT PRIMARY KEY, value INTEGER NOT NULL);"
        )
        conn.execute(
            "INSERT INTO technicians (id, name, category) VALUES ('t1', 'Old Tech', 'RasoiSpark')"
        )
        conn.execute(
            "INSERT INTO bookings (id, category, service, price, technician_id, created_at, updated_at) "
            "VALUES ('RC-OLD', 'RasoiSpark', 'Fix', 399, 't1', '2025-01-01T00:00:00Z', "
            "'2025-01-01T00:00:00Z')"
        )
        conn.commit()
        conn.close()

        conn = database.get_db()
        database.migrate_bookings_technician_nullable(conn)
        conn.close()
        conn = database.get_db()
        info = conn.execute("PRAGMA table_info(bookings)").fetchall()
        tech_col = next(r for r in info if r["name"] == "technician_id")
        row = conn.execute(
            "SELECT id, technician_id FROM bookings WHERE id = 'RC-OLD'"
        ).fetchone()
        conn.close()
        assert tech_col["notnull"] == 0
        assert row["technician_id"] == "t1"
    finally:
        database.DATABASE_URL = old
        database.DB_PATH = original_path
        conn = None
        import os as _os
        _os.unlink(path)
