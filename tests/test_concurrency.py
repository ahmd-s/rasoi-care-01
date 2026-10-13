"""P1-04 concurrency regression tests.

Covers the two races that could corrupt production data under concurrent
load (N2 and N6 in the audit):

1. Booking-id minting — the old next_id() was a SELECT-then-UPDATE
   read-modify-write; two simultaneous creations could both read the same
   counter value and mint the same RC-N id, the second INSERT dying on the
   bookings primary key with a 500 (worse on Postgres where connections
   genuinely run in parallel). Now: Postgres uses a single
   INSERT..ON CONFLICT..RETURNING; SQLite takes BEGIN IMMEDIATE first.

2. Completion side effects — the old advance_booking() updated the status
   unconditionally after a non-guarded read, so two concurrent "complete"
   requests could both fire jobs_completed++ / incentives / Care Coins.
   Now the status UPDATE carries `AND status = ?` and side effects fire
   only when it won (rowcount == 1).
"""
import threading

import database
import app as app_module
from conftest import register_and_login, auth_headers, mock_firebase_claims


def test_concurrent_next_id_mints_unique_values(client):
    """12 threads each mint an id from their own connection — every value
    must be distinct. (The old code could return the same value twice.)"""
    conn = database.get_db()
    conn.execute("INSERT INTO counters (name, value) VALUES ('order', 100)")
    conn.commit()
    conn.close()

    results = []
    errors = []
    barrier = threading.Barrier(12)

    def mint():
        try:
            barrier.wait(timeout=10)
            c = database.get_db()
            results.append(database.next_id(c, "order", "RC"))
            c.commit()
            c.close()
        except Exception as e:  # pragma: no cover — surfaces real races
            errors.append(repr(e))

    threads = [threading.Thread(target=mint) for _ in range(12)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=30)

    assert not errors, errors
    assert len(results) == 12, results
    assert len(set(results)) == 12, f"duplicate ids minted: {sorted(results)}"
    assert all(r.startswith("RC-") for r in results)

    conn = database.get_db()
    value = conn.execute("SELECT value FROM counters WHERE name = 'order'").fetchone()["value"]
    conn.close()
    assert value == 112, value  # 100 + 12 mints, none lost, none doubled


def test_concurrent_booking_creation_mints_unique_booking_ids(client):
    """End-to-end: 12 concurrent booking creations every returned id is
    unique and every response is a clean 201."""
    conn = database.get_db()
    conn.execute(
        "INSERT INTO technicians (id, name, category, area, verified, online, rating, rating_count, jobs_completed) "
        "VALUES ('seed-tech', 'Seed Tech', 'RasoiSpark', 'Test Area', 1, 1, 4.5, 10, 10)"
    )
    conn.commit()
    conn.close()

    service_id = client.get("/api/services").get_json()[0]["id"]
    results = []
    errors = []
    barrier = threading.Barrier(12)

    def create_booking(i):
        try:
            barrier.wait(timeout=10)
            with app_module.app.test_client() as c:
                reg = c.post(
                    "/api/auth/register",
                    json={
                        "email": f"racer{i}@example.com",
                        "password": "hunter22",
                        "name": f"Racer {i}",
                        "phone": f"98766000{i:02d}",
                    },
                )
                assert reg.status_code == 201, reg.get_json()
                token = reg.get_json()["token"]
                resp = c.post(
                    "/api/bookings",
                    json={"service_id": service_id},
                    headers=auth_headers(token),
                )
                results.append((resp.status_code, resp.get_json()))
        except Exception as e:  # pragma: no cover
            errors.append(repr(e))

    threads = [threading.Thread(target=create_booking, args=(i,)) for i in range(12)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=60)

    assert not errors, errors
    assert len(results) == 12, results
    failures = [r for r in results if r[0] != 201]
    assert not failures, f"concurrent creations failed: {failures}"
    ids = [body["id"] for _status, body in results]
    assert len(set(ids)) == 12, f"duplicate booking ids: {sorted(ids)}"


def test_duplicate_completion_fires_side_effects_exactly_once(client, monkeypatch):
    """Deterministic double-completion race (N6): request A reads the
    booking at In Progress, then — while A is paused between its read and
    its status UPDATE — request B completes the booking through the real
    API. When A resumes, its UPDATE must NOT match (guarded by
    `AND status = ?`), so side effects fire exactly once (B's).

    The pause is injected through app.now(), which advance_booking calls
    exactly between the row read and the guarded UPDATE."""
    # --- set up a technician (verified), a user, a booking at In Progress
    mock_firebase_claims(monkeypatch, uid="tech-finish", email="finish@example.com",
                         email_verified=True, name="Finish Tech")
    resp = client.post(
        "/api/technician/bootstrap",
        json={"name": "Finish Tech", "category": "RasoiSpark", "area": "Test Area"},
        headers=auth_headers("x"),
    )
    assert resp.status_code == 200, resp.get_json()
    tech = resp.get_json()
    conn = database.get_db()
    conn.execute("UPDATE technicians SET verified = 1, online = 1 WHERE id = ?", (tech["id"],))
    conn.commit()
    conn.close()

    user = register_and_login(client, email="finish-customer@example.com", phone="9876700001")
    service_id = client.get("/api/services").get_json()[0]["id"]
    booking = client.post(
        "/api/bookings", json={"service_id": service_id}, headers=auth_headers(user["token"])
    ).get_json()
    expected_coins = (booking["total_amount"] * 2) // 100

    claim = client.patch(f"/api/bookings/{booking['id']}/claim", json={},
                         headers=auth_headers("x"))
    assert claim.status_code == 200, claim.get_json()

    otw = client.patch(f"/api/bookings/{booking['id']}/advance", json={}, headers=auth_headers("x"))
    assert otw.status_code == 200 and otw.get_json()["status"] == "On the way", otw.get_json()

    detail = client.get(
        f"/api/bookings/{booking['id']}", headers=auth_headers(user["token"])
    ).get_json()
    start_code = detail["startCode"]
    assert start_code, detail

    ip = client.patch(
        f"/api/bookings/{booking['id']}/advance",
        json={"startCode": start_code},
        headers=auth_headers("x"),
    )
    assert ip.status_code == 200 and ip.get_json()["status"] == "In Progress", ip.get_json()

    # photos + signature so completion's own gates pass
    assert client.patch(f"/api/bookings/{booking['id']}/photo",
                        json={"kind": "before", "dataBase64": "cGhvdG8="},
                        headers=auth_headers("x")).status_code == 200
    assert client.patch(f"/api/bookings/{booking['id']}/photo",
                        json={"kind": "after", "dataBase64": "cGhvdG8="},
                        headers=auth_headers("x")).status_code == 200
    assert client.patch(f"/api/bookings/{booking['id']}/signature",
                        json={"dataBase64": "c2lnbg=="},
                        headers=auth_headers("x")).status_code == 200

    # --- the deterministic interleaving:
    # first now() call inside A's advance pauses, and a second "request B"
    # completes the booking, then A resumes with its now-stale read.
    # B is driven directly at the SQL level (nesting a second Flask request
    # inside this one isn't possible) — these are exactly the statements
    # B's handler executes and commits, including the guarded transition.
    real_now = app_module.now
    fired = {"done": False}

    def interleaving_now():
        ts = real_now()
        if not fired["done"]:
            fired["done"] = True
            c = database.get_db()
            c.execute(
                "UPDATE bookings SET status = 'Completed', updated_at = ? "
                "WHERE id = ? AND status = 'In Progress'",
                (ts, booking["id"]),
            )
            c.execute(
                "UPDATE technicians SET jobs_completed = jobs_completed + 1 WHERE id = ?",
                (tech["id"],),
            )
            if expected_coins > 0:
                c.execute(
                    "UPDATE users SET coins_balance = coins_balance + ? WHERE email = ?",
                    (expected_coins, "finish-customer@example.com"),
                )
            c.commit()
            c.close()
        return ts

    monkeypatch.setattr(app_module, "now", interleaving_now)
    loser_resp = client.patch(
        f"/api/bookings/{booking['id']}/advance", json={}, headers=auth_headers("x")
    )
    # NOTE: deliberately no monkeypatch.undo() here — undoing mid-test would
    # also tear down the client fixture's own patches (DB_PATH) while the
    # request is still on the stack. After the first call the hook is a
    # pass-through, so leaving it active is harmless.
    assert loser_resp.status_code == 200, loser_resp.get_json()
    assert loser_resp.get_json()["status"] == "Completed", loser_resp.get_json()

    # --- side effects fired exactly once (the inner "winner" request)
    conn = database.get_db()
    tech_row = conn.execute(
        "SELECT jobs_completed FROM technicians WHERE id = ?", (tech["id"],)
    ).fetchone()
    user_row = conn.execute(
        "SELECT coins_balance FROM users WHERE email = ?", ("finish-customer@example.com",)
    ).fetchone()
    ledger_rows = conn.execute(
        "SELECT COUNT(*) AS n FROM technician_ledger WHERE booking_id = ?",
        (booking["id"],),
    ).fetchone()
    booking_row = conn.execute(
        "SELECT status FROM bookings WHERE id = ?", (booking["id"],)
    ).fetchone()
    conn.close()

    assert tech_row["jobs_completed"] == 1, tech_row["jobs_completed"]
    assert user_row["coins_balance"] == expected_coins, (
        user_row["coins_balance"], expected_coins,
    )
    assert ledger_rows["n"] <= 1, ledger_rows["n"]
    assert booking_row["status"] == "Completed"


def test_eight_concurrent_completions_all_succeed_with_single_side_effects(client, monkeypatch):
    """Load-level smoke: 8 threads advance the same booking at the same
    instant — every response is a clean 200 showing Completed, and the
    side effects still fired exactly once."""
    # --- set up a technician (verified), a user, a booking at In Progress
    mock_firebase_claims(monkeypatch, uid="tech-finish8", email="finish8@example.com",
                         email_verified=True, name="Finish Tech 8")
    resp = client.post(
        "/api/technician/bootstrap",
        json={"name": "Finish Tech 8", "category": "RasoiSpark", "area": "Test Area"},
        headers=auth_headers("x"),
    )
    assert resp.status_code == 200, resp.get_json()
    tech = resp.get_json()
    conn = database.get_db()
    conn.execute("UPDATE technicians SET verified = 1, online = 1 WHERE id = ?", (tech["id"],))
    conn.commit()
    conn.close()

    user = register_and_login(client, email="finish8-customer@example.com", phone="9876700002")
    service_id = client.get("/api/services").get_json()[0]["id"]
    booking = client.post(
        "/api/bookings", json={"service_id": service_id}, headers=auth_headers(user["token"])
    ).get_json()
    expected_coins = (booking["total_amount"] * 2) // 100

    assert client.patch(f"/api/bookings/{booking['id']}/claim", json={},
                        headers=auth_headers("x")).status_code == 200
    assert client.patch(f"/api/bookings/{booking['id']}/advance", json={},
                        headers=auth_headers("x")).status_code == 200
    detail = client.get(f"/api/bookings/{booking['id']}",
                        headers=auth_headers(user["token"])).get_json()
    assert client.patch(f"/api/bookings/{booking['id']}/advance",
                        json={"startCode": detail["startCode"]},
                        headers=auth_headers("x")).status_code == 200
    assert client.patch(f"/api/bookings/{booking['id']}/photo",
                        json={"kind": "before", "dataBase64": "cGhvdG8="},
                        headers=auth_headers("x")).status_code == 200
    assert client.patch(f"/api/bookings/{booking['id']}/photo",
                        json={"kind": "after", "dataBase64": "cGhvdG8="},
                        headers=auth_headers("x")).status_code == 200
    assert client.patch(f"/api/bookings/{booking['id']}/signature",
                        json={"dataBase64": "c2lnbg=="},
                        headers=auth_headers("x")).status_code == 200

    statuses = []
    errors = []
    barrier = threading.Barrier(8)

    def advance():
        try:
            barrier.wait(timeout=10)
            with app_module.app.test_client() as c:
                r = c.patch(
                    f"/api/bookings/{booking['id']}/advance",
                    json={},
                    headers=auth_headers("x"),
                )
                statuses.append((r.status_code, r.get_json().get("status")))
        except Exception as e:  # pragma: no cover
            errors.append(repr(e))

    threads = [threading.Thread(target=advance) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=60)

    assert not errors, errors
    assert len(statuses) == 8, statuses
    non_200 = [s for s in statuses if s[0] != 200]
    assert not non_200, f"concurrent advances failed: {non_200}"
    assert all(s[1] == "Completed" for s in statuses), statuses

    conn = database.get_db()
    tech_row = conn.execute(
        "SELECT jobs_completed FROM technicians WHERE id = ?", (tech["id"],)
    ).fetchone()
    user_row = conn.execute(
        "SELECT coins_balance FROM users WHERE email = ?", ("finish8-customer@example.com",)
    ).fetchone()
    booking_row = conn.execute(
        "SELECT status FROM bookings WHERE id = ?", (booking["id"],)
    ).fetchone()
    conn.close()

    assert tech_row["jobs_completed"] == 1, tech_row["jobs_completed"]
    assert user_row["coins_balance"] == expected_coins, (
        user_row["coins_balance"], expected_coins,
    )
    assert booking_row["status"] == "Completed"
