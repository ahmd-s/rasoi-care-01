"""P1-10 (b) — PR #79 regression tests: the pending-parts completion gate.

A part/quote the technician raised and the customer hasn't decided must
block completion (an undecided quote after invoicing would never get paid).
Once every part is decided (approved or rejected — or deleted while still
pending), completion may proceed.
"""
import database
from conftest import register_and_login, auth_headers, mock_firebase_claims

BEFORE_PHOTO = {"kind": "before", "dataBase64": "cGhvdG8="}
AFTER_PHOTO = {"kind": "after", "dataBase64": "cGhvdG8="}
SIGNATURE = {"dataBase64": "c2lnbg=="}


def _setup(client, monkeypatch):
    mock_firebase_claims(monkeypatch, uid="tech-parts", email="parts@example.com",
                         email_verified=True)
    resp = client.post(
        "/api/technician/bootstrap",
        json={"name": "Parts Tech", "category": "RasoiSpark", "area": "Test Area"},
        headers=auth_headers("x"),
    )
    assert resp.status_code == 200
    tech = resp.get_json()
    conn = database.get_db()
    conn.execute("UPDATE technicians SET verified = 1, online = 1 WHERE id = ?", (tech["id"],))
    conn.commit()
    conn.close()

    user = register_and_login(client, email="parts-customer@example.com", phone="9876900001")
    service_id = client.get("/api/services").get_json()[0]["id"]
    booking = client.post(
        "/api/bookings", json={"service_id": service_id}, headers=auth_headers(user["token"])
    ).get_json()
    assert client.patch(f"/api/bookings/{booking['id']}/claim", json={},
                        headers=auth_headers("x")).status_code == 200
    assert client.patch(f"/api/bookings/{booking['id']}/advance", json={},
                        headers=auth_headers("x")).status_code == 200
    detail = client.get(f"/api/bookings/{booking['id']}",
                        headers=auth_headers(user["token"])).get_json()
    assert client.patch(
        f"/api/bookings/{booking['id']}/advance",
        json={"startCode": detail["startCode"]},
        headers=auth_headers("x"),
    ).status_code == 200
    assert client.patch(f"/api/bookings/{booking['id']}/photo", json=BEFORE_PHOTO,
                        headers=auth_headers("x")).status_code == 200
    assert client.patch(f"/api/bookings/{booking['id']}/photo", json=AFTER_PHOTO,
                        headers=auth_headers("x")).status_code == 200
    assert client.patch(f"/api/bookings/{booking['id']}/signature", json=SIGNATURE,
                        headers=auth_headers("x")).status_code == 200
    return user, booking


def _advance_to_completed(client, booking_id):
    return client.patch(f"/api/bookings/{booking_id}/advance", json={},
                        headers=auth_headers("x"))


def test_pending_part_blocks_completion(client, monkeypatch):
    _user, booking = _setup(client, monkeypatch)
    part = client.post(
        f"/api/technician/bookings/{booking['id']}/parts",
        json={"name": "Baffle filter", "qty": 1, "pricePaise": 64000},
        headers=auth_headers("x"),
    ).get_json()
    resp = _advance_to_completed(client, booking["id"])
    assert resp.status_code == 400
    body = resp.get_json()
    assert body["error"] == "Awaiting customer approval"
    assert "Baffle filter" in body["message"]
    conn = database.get_db()
    status = conn.execute("SELECT status FROM bookings WHERE id = ?",
                          (booking["id"],)).fetchone()["status"]
    conn.close()
    assert status == "In Progress", "blocked completion must not advance"


def test_decided_part_allows_completion(client, monkeypatch):
    user, booking = _setup(client, monkeypatch)
    part = client.post(
        f"/api/technician/bookings/{booking['id']}/parts",
        json={"name": "Thermostat", "qty": 1, "pricePaise": 120000},
        headers=auth_headers("x"),
    ).get_json()
    assert client.patch(
        f"/api/bookings/{booking['id']}/parts/{part['id']}",
        json={"status": "approved"},
        headers=auth_headers(user["token"]),
    ).status_code == 200
    resp = _advance_to_completed(client, booking["id"])
    assert resp.status_code == 200, resp.get_json()
    assert resp.get_json()["status"] == "Completed"


def test_rejected_part_also_allows_completion(client, monkeypatch):
    user, booking = _setup(client, monkeypatch)
    part = client.post(
        f"/api/technician/bookings/{booking['id']}/parts",
        json={"name": "Optional gadget", "qty": 1, "pricePaise": 90000},
        headers=auth_headers("x"),
    ).get_json()
    assert client.patch(
        f"/api/bookings/{booking['id']}/parts/{part['id']}",
        json={"status": "rejected"},
        headers=auth_headers(user["token"]),
    ).status_code == 200
    resp = _advance_to_completed(client, booking["id"])
    assert resp.status_code == 200, resp.get_json()
    assert resp.get_json()["status"] == "Completed"


def test_deleted_pending_part_unblocks_completion(client, monkeypatch):
    user, booking = _setup(client, monkeypatch)
    part = client.post(
        f"/api/technician/bookings/{booking['id']}/parts",
        json={"name": "Raised by mistake", "qty": 1, "pricePaise": 5000},
        headers=auth_headers("x"),
    ).get_json()
    assert client.delete(
        f"/api/technician/bookings/{booking['id']}/parts/{part['id']}",
        headers=auth_headers("x"),
    ).status_code == 200
    resp = _advance_to_completed(client, booking["id"])
    assert resp.status_code == 200, resp.get_json()
    assert resp.get_json()["status"] == "Completed"


def test_customer_cannot_decide_a_part_on_someone_elses_booking(client, monkeypatch):
    _user, booking = _setup(client, monkeypatch)
    part = client.post(
        f"/api/technician/bookings/{booking['id']}/parts",
        json={"name": "Gasket", "qty": 2, "pricePaise": 30000},
        headers=auth_headers("x"),
    ).get_json()
    stranger = register_and_login(client, email="stranger@example.com",
                                  name="Stranger", phone="9876910001")
    resp = client.patch(
        f"/api/bookings/{booking['id']}/parts/{part['id']}",
        json={"status": "approved"},
        headers=auth_headers(stranger["token"]),
    )
    assert resp.status_code == 404
    conn = database.get_db()
    status = conn.execute("SELECT status FROM booking_parts WHERE id = ?",
                          (part["id"],)).fetchone()["status"]
    conn.close()
    assert status == "pending"
