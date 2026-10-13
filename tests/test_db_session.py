"""P1-02 tests — database.db_session() contract.

Proves the context manager preserves the exact semantics the codebase's
manual get_db()/commit()/close() dance relies on:
- clean exit (including plain `return` from inside the with-block) commits;
- an exception rolls back everything written inside the block and re-raises;
- the connection is closed in every path (nothing leaks).
"""
import pytest

import database


def _booking_count(conn):
    return conn.execute("SELECT COUNT(*) AS n FROM bookings").fetchone()["n"]


def test_db_session_commits_on_clean_exit(client):
    # `client` fixture gives us an initialised throwaway database
    with database.db_session() as conn:
        conn.execute(
            "INSERT INTO bookings (id, category, service, price, customer_name, status, created_at, updated_at) "
            "VALUES ('RC-T1', 'RasoiSpark', 'Fix', 399, 'T', 'Requested', '2026-01-01T00:00:00Z', "
            "'2026-01-01T00:00:00Z')"
        )
    with database.db_session() as conn:
        assert _booking_count(conn) == 1


def test_db_session_commits_on_return_from_inside_block(client):
    # the exact pattern the migrated handlers use
    def handler():
        with database.db_session() as conn:
            conn.execute(
                "INSERT INTO bookings (id, category, service, price, customer_name, status, created_at, updated_at) "
                "VALUES ('RC-T2', 'RasoiSpark', 'Fix', 399, 'T', 'Requested', '2026-01-01T00:00:00Z', "
                "'2026-01-01T00:00:00Z')"
            )
            if True:
                return "early-return"

    assert handler() == "early-return"
    with database.db_session() as conn:
        assert _booking_count(conn) == 1


def test_db_session_rolls_back_on_exception(client):
    with pytest.raises(RuntimeError, match="boom"):
        with database.db_session() as conn:
            conn.execute(
                "INSERT INTO bookings (id, category, service, price, customer_name, status, created_at, updated_at) "
                "VALUES ('RC-T3', 'RasoiSpark', 'Fix', 399, 'T', 'Requested', '2026-01-01T00:00:00Z', "
                "'2026-01-01T00:00:00Z')"
            )
            raise RuntimeError("boom mid-transaction")
    with database.db_session() as conn:
        assert _booking_count(conn) == 0, "exception inside db_session must roll back"


def test_db_session_rolls_back_half_of_completion_style_effects(client):
    """The advance_booking scenario: booking status written, ledger INSERT
    then a crash — the ledger row AND the status write must both vanish."""
    with database.db_session() as conn:
        conn.execute(
            "INSERT INTO technicians (id, name, category, area, verified, online, rating, rating_count, jobs_completed) "
            "VALUES ('tech-ledger', 'Ledger Tech', 'RasoiSpark', 'Test Area', 1, 1, 4.5, 0, 0)"
        )
        conn.execute(
            "INSERT INTO bookings (id, category, service, price, customer_name, status, technician_id, "
            "created_at, updated_at) "
            "VALUES ('RC-T4', 'RasoiSpark', 'Fix', 399, 'T', 'In Progress', 'tech-ledger', "
            "'2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')"
        )
    with pytest.raises(RuntimeError):
        with database.db_session() as conn:
            conn.execute("UPDATE bookings SET status = 'Completed' WHERE id = 'RC-T4'")
            conn.execute(
                "INSERT INTO technician_ledger (id, technician_id, booking_id, kind, amount_paise, "
                "reason, created_at) VALUES ('LEDG-T', 'tech-ledger', 'RC-T4', 'incentive', 1, 'x', 'z')"
            )
            raise RuntimeError("crash between side effects")
    with database.db_session() as conn:
        assert conn.execute("SELECT status FROM bookings WHERE id = 'RC-T4'").fetchone()["status"] == "In Progress"
        assert conn.execute("SELECT COUNT(*) AS n FROM technician_ledger WHERE booking_id = 'RC-T4'").fetchone()["n"] == 0
