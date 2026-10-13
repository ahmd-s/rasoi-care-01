"""P1-03 / P1-11 — Postgres-backed migration + persistence tests.

These run ONLY when TEST_DATABASE_URL points at a real (disposable!) Postgres
database — they create/drop tables in it. Without the variable the whole
module skips, so the standard local suite stays SQLite-only and green.

Usage (owner/operator with a throwaway database — never point these at
production):
    TEST_DATABASE_URL="postgresql://user:pass@host/dbname?sslmode=require" \
        python -m pytest tests/test_migrations_postgres.py -v

What they prove:
- init_db() is a clean no-op the second time on Postgres (the #83-class
  syntax/compatibility bugs and the unconditional DROP NOT NULL both fail
  here, loudly);
- schema matches the BOOKINGS_COLUMNS contract app.py's list projection
  depends on;
- data survives a redeploy simulation (reconnect + re-init + row still
  there) — the C1 acceptance criterion, database-side half;
- concurrent booking creation via next_id() never mints duplicate ids
  under REAL parallel connections (SQLite cannot prove this).
"""
import os

import pytest

pytestmark = pytest.mark.skipif(
    not os.environ.get("TEST_DATABASE_URL"),
    reason="TEST_DATABASE_URL not set — Postgres-mode tests need a disposable database",
)

import database  # noqa: E402  (import after skip guard for clarity)


@pytest.fixture(scope="module")
def pg():
    """Points database.py at the test database for this module."""
    url = os.environ["TEST_DATABASE_URL"]
    old_url, old_path = database.DATABASE_URL, database.DB_PATH
    database.DATABASE_URL = url
    try:
        yield url
    finally:
        database.DATABASE_URL = old_url
        database.DB_PATH = old_path
        # tear the pool down so later tests can't borrow a connection tied
        # to the test database
        pool = database._pg_pool
        database._pg_pool = None
        if pool is not None:
            pool.closeall()


def _drop_all(conn):
    conn.execute(
        "DO $$ DECLARE r RECORD; BEGIN "
        "FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = current_schema()) LOOP "
        "EXECUTE 'DROP TABLE IF EXISTS ' || quote_ident(r.tablename) || ' CASCADE'; END LOOP; END $$;"
    )
    conn.commit()


def _schema_snapshot(conn):
    rows = conn.execute(
        "SELECT table_name, column_name, is_nullable FROM information_schema.columns "
        "WHERE table_schema = current_schema() ORDER BY table_name, column_name"
    ).fetchall()
    return [tuple(r.values()) for r in rows]


def test_pg_init_db_twice_is_clean_noop(pg):
    conn = database.get_db()
    _drop_all(conn)
    conn.close()

    database.init_db()
    conn = database.get_db()
    first = _schema_snapshot(conn)
    conn.close()

    database.init_db()  # second boot — must be a no-op, not a crash
    database.init_db()  # third boot for good measure
    conn = database.get_db()
    second = _schema_snapshot(conn)
    conn.close()
    assert first == second, "double init_db on Postgres changed the schema"


def test_pg_schema_matches_bookings_contract(pg):
    database.init_db()
    conn = database.get_db()
    real = database._table_columns(conn, "bookings")
    conn.close()
    assert real == set(database.BOOKINGS_COLUMNS)


def test_pg_data_survives_redeploy_simulation(pg):
    """C1 acceptance criterion (database half): a row written before a
    'redeploy' (full disconnect + re-init) is still there afterwards."""
    database.init_db()
    conn = database.get_db()
    conn.execute(
        "INSERT INTO bookings (id, category, service, price, customer_name, status, created_at, updated_at) "
        "VALUES ('RC-PG1', 'RasoiSpark', 'Fix', 399, 'PG', 'Requested', '2026-01-01T00:00:00Z', "
        "'2026-01-01T00:00:00Z')"
    )
    conn.commit()
    conn.close()

    # simulate redeploy: every pooled connection discarded, fresh connects
    pool = database._pg_pool
    database._pg_pool = None
    if pool is not None:
        pool.closeall()

    database.init_db()  # new boot's migration pass
    conn = database.get_db()
    row = conn.execute("SELECT id, status FROM bookings WHERE id = 'RC-PG1'").fetchone()
    conn.close()
    assert row is not None
    assert row["status"] == "Requested"


def test_pg_migrations_run_against_fk_referenced_rows(pg):
    """Migrations must not corrupt/lock up on a database that already has
    live bookings referencing technicians (the audit's pre-seeded-FK case)."""
    database.init_db()
    conn = database.get_db()
    conn.execute(
        "INSERT INTO technicians (id, name, category, area, verified, online, rating, rating_count, jobs_completed) "
        "VALUES ('pg-tech', 'PG Tech', 'RasoiSpark', 'PG Area', 1, 1, 4.5, 0, 0)"
    )
    conn.execute(
        "INSERT INTO bookings (id, category, service, price, customer_name, status, technician_id, "
        "created_at, updated_at) VALUES ('RC-PG2', 'RasoiSpark', 'Fix', 399, 'PG', 'Requested', "
        "'pg-tech', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')"
    )
    conn.commit()
    conn.close()

    database.init_db()  # full migration pass over a database with FK rows
    conn = database.get_db()
    row = conn.execute("SELECT technician_id FROM bookings WHERE id = 'RC-PG2'").fetchone()
    conn.close()
    assert row["technician_id"] == "pg-tech"


def test_pg_concurrent_next_id_never_duplicates(pg):
    """12 REAL parallel connections (not threads sharing a process lock) —
    the definitive proof the RETURNING-based counter is atomic."""
    import threading

    database.init_db()
    conn = database.get_db()
    conn.execute("INSERT INTO counters (name, value) VALUES ('order', 200)")
    conn.commit()
    conn.close()

    results = []
    errors = []
    barrier = threading.Barrier(12)

    def mint():
        try:
            barrier.wait(timeout=15)
            c = database.get_db()
            results.append(database.next_id(c, "order", "RC"))
            c.commit()
            c.close()
        except Exception as e:
            errors.append(repr(e))

    threads = [threading.Thread(target=mint) for _ in range(12)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=60)

    assert not errors, errors
    assert len(results) == 12, results
    assert len(set(results)) == 12, f"DUPLICATE IDS ON REAL POSTGRES: {sorted(results)}"

    conn = database.get_db()
    value = conn.execute("SELECT value FROM counters WHERE name = 'order'").fetchone()["value"]
    conn.close()
    assert value == 212, value
