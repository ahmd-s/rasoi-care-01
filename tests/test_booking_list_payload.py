"""P1-05 regression tests — list endpoints must not transport base64 blobs.

Guards three things at once:
1. database.BOOKINGS_COLUMNS stays in sync with the real bookings schema
   (the drift guard that keeps BOOKING_LIST_SELECT's explicit projection
   correct as new columns are migrated in).
2. List responses carrying bookings with real multi-MB photos/signatures
   stay small (the actual N3 fix) while the photo-ready booleans stay
   exactly as truthful as before (the Partner app gates its completion
   flow on them).
3. Detail endpoints still expose the same booleans (unchanged behavior).
"""
import base64
import json

import database
from conftest import register_and_login, auth_headers, add_technician


def _test_schema_matches_constant(client):
    """Drift guard: SCHEMA + migrations must produce exactly the columns
    database.BOOKINGS_COLUMNS promises (the source of truth for the list
    projection). Runs on the fresh per-test database init_db() just made."""
    conn = database.get_db()
    real = database._table_columns(conn, "bookings")
    conn.close()
    assert real == set(database.BOOKINGS_COLUMNS), (
        "bookings schema drifted from database.BOOKINGS_COLUMNS — update the "
        "constant (and BOOKING_LIST_SELECT picks it up automatically): "
        f"missing={sorted(real - set(database.BOOKINGS_COLUMNS))} "
        f"extra={sorted(set(database.BOOKINGS_COLUMNS) - real)}"
    )


def _blob_row_bytes(kind: str, size: int) -> str:
    # deterministic, valid-ish base64 of roughly `size` chars
    return base64.b64encode(b"\x89PNG" + kind.encode() * size).decode("ascii")


def _make_booking_with_blobs(client):
    """One booking owned by a registered user, with a ~1MB before photo,
    ~1MB after photo and ~0.5MB signature written straight into the row
    (same columns the photo/signature endpoints write; writing here keeps
    the test focused on the query projection, not the upload path)."""
    _test_schema_matches_constant(client)
    conn = database.get_db()
    add_technician(conn)
    conn.close()

    user = register_and_login(client)
    service_id = client.get("/api/services").get_json()[0]["id"]
    booking = client.post(
        "/api/bookings", json={"service_id": service_id}, headers=auth_headers(user["token"])
    ).get_json()

    before = _blob_row_bytes("b", 750_000)
    after = _blob_row_bytes("a", 750_000)
    sig = _blob_row_bytes("s", 380_000)
    conn = database.get_db()
    conn.execute(
        "UPDATE bookings SET before_photo_b64 = ?, after_photo_b64 = ?, signature_b64 = ? "
        "WHERE id = ?",
        (before, after, sig, booking["id"]),
    )
    conn.commit()
    conn.close()
    return user, booking, (before, after, sig)


MAX_LIST_BYTES = 256 * 1024


def test_user_list_stays_small_with_blobs_present(client):
    user, booking, _blobs = _make_booking_with_blobs(client)
    resp = client.get("/api/bookings", headers=auth_headers(user["token"]))
    assert resp.status_code == 200
    raw = resp.data
    assert len(raw) < MAX_LIST_BYTES, (
        f"list response is {len(raw)} bytes — the base64 photo/signature "
        "blobs are being selected into list queries again"
    )
    body = resp.get_json()
    assert body[0]["id"] == booking["id"]
    # booleans stay exactly as truthful as before (Partner app's completion
    # gate reads these from the list payload)
    assert body[0]["beforePhotoReady"] is True
    assert body[0]["afterPhotoReady"] is True
    assert body[0]["signatureReady"] is True


def test_staff_list_stays_small_with_blobs_present(client):
    _user, _booking, _blobs = _make_booking_with_blobs(client)
    login = client.post(
        "/api/staff/login", json={"phone": "9822000001", "pin": "1234"}
    ).get_json()
    resp = client.get("/api/bookings?limit=50", headers=auth_headers(login["token"]))
    assert resp.status_code == 200
    assert len(resp.data) < MAX_LIST_BYTES, len(resp.data)
    assert resp.get_json()[0]["beforePhotoReady"] is True


def test_booking_without_blobs_reports_not_ready(client):
    _user, booking, _ = _make_booking_with_blobs(client)
    conn = database.get_db()
    conn.execute(
        "UPDATE bookings SET before_photo_b64 = NULL, after_photo_b64 = NULL, "
        "signature_b64 = NULL WHERE id = ?",
        (booking["id"],),
    )
    conn.commit()
    conn.close()
    # any authenticated caller works; re-register a fresh viewer
    user = register_and_login(client, email="viewer@example.com", phone="9876500011")
    resp = client.get("/api/bookings", headers=auth_headers(user["token"]))
    # viewer has no bookings of their own — use the staff path instead
    login = client.post(
        "/api/staff/login", json={"phone": "9822000001", "pin": "1234"}
    ).get_json()
    resp = client.get("/api/bookings?limit=50", headers=auth_headers(login["token"]))
    row = next(r for r in resp.get_json() if r["id"] == booking["id"])
    assert row["beforePhotoReady"] is False
    assert row["afterPhotoReady"] is False
    assert row["signatureReady"] is False


def test_detail_endpoint_booleans_unchanged(client):
    user, booking, _blobs = _make_booking_with_blobs(client)
    resp = client.get(f"/api/bookings/{booking['id']}", headers=auth_headers(user["token"]))
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["beforePhotoReady"] is True
    assert body["signatureReady"] is True


def test_stats_report_endpoint_stays_small(client):
    _user, _booking, _blobs = _make_booking_with_blobs(client)
    login = client.post(
        "/api/staff/login", json={"phone": "9822000001", "pin": "1234"}
    ).get_json()
    resp = client.get("/api/stats/reports?period=week", headers=auth_headers(login["token"]))
    assert resp.status_code == 200
    assert len(resp.data) < MAX_LIST_BYTES, len(resp.data)
