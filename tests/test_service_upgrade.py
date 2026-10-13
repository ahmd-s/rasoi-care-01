"""P1-10 (a) — PR #79 regression tests: service upgrade/reprice.

update_booking_service must reprice from the LIVE catalog only (never a
client-supplied amount), refuse cross-category swaps, stay blocked once
the job is Completed, and surface the change in the customer-visible list
payload.
"""
import database
from conftest import register_and_login, auth_headers, mock_firebase_claims


def _setup(client, monkeypatch):
    mock_firebase_claims(monkeypatch, uid="tech-svc", email="svc@example.com",
                         email_verified=True)
    resp = client.post(
        "/api/technician/bootstrap",
        json={"name": "Service Tech", "category": "RasoiSpark", "area": "Test Area"},
        headers=auth_headers("x"),
    )
    assert resp.status_code == 200
    tech = resp.get_json()
    conn = database.get_db()
    conn.execute("UPDATE technicians SET verified = 1, online = 1 WHERE id = ?", (tech["id"],))
    conn.commit()
    conn.close()

    user = register_and_login(client, email="svc-customer@example.com", phone="9876800001")
    services = client.get("/api/services").get_json()
    spark_services = [s for s in services if s["category"] == "RasoiSpark"]
    other_category = next(s for s in services if s["category"] != "RasoiSpark")
    booking = client.post(
        "/api/bookings",
        json={"service_id": spark_services[0]["id"]},
        headers=auth_headers(user["token"]),
    ).get_json()
    claim = client.patch(f"/api/bookings/{booking['id']}/claim", json={},
                         headers=auth_headers("x"))
    assert claim.status_code == 200, claim.get_json()
    return user, booking, spark_services[1], other_category


def test_service_upgrade_reprices_from_live_catalog(client, monkeypatch):
    user, booking, new_service, _other = _setup(client, monkeypatch)
    resp = client.patch(
        f"/api/technician/bookings/{booking['id']}/service",
        json={"serviceId": new_service["id"]},
        headers=auth_headers("x"),
    )
    assert resp.status_code == 200, resp.get_json()
    body = resp.get_json()
    # price/total must be the CATALOG's price, not anything client-supplied
    assert body["price"] == new_service["price"], body
    assert body["total_amount"] == new_service["price"], body
    assert new_service["name"] in body["service"], body
    # a change record exists with old + new prices in paise
    assert len(body["serviceChanges"]) == 1
    change = body["serviceChanges"][0]
    assert change["newPricePaise"] == new_service["price"] * 100
    assert change["oldPricePaise"] == booking["price"] * 100


def test_service_upgrade_rejects_cross_category_swap(client, monkeypatch):
    _user, booking, _new_service, other_category = _setup(client, monkeypatch)
    resp = client.patch(
        f"/api/technician/bookings/{booking['id']}/service",
        json={"serviceId": other_category["id"]},
        headers=auth_headers("x"),
    )
    assert resp.status_code == 400
    assert resp.get_json()["error"] == "Service category mismatch"


def test_service_upgrade_blocked_after_completion(client, monkeypatch):
    user, booking, new_service, _other = _setup(client, monkeypatch)
    detail = client.get(f"/api/bookings/{booking['id']}",
                        headers=auth_headers(user["token"])).get_json()
    for status in ("Completed",):  # drive to terminal status directly
        conn = database.get_db()
        conn.execute("UPDATE bookings SET status = ? WHERE id = ?", (status, booking["id"]))
        conn.commit()
        conn.close()
    resp = client.patch(
        f"/api/technician/bookings/{booking['id']}/service",
        json={"serviceId": new_service["id"]},
        headers=auth_headers("x"),
    )
    assert resp.status_code == 400
    assert resp.get_json()["error"] == "Job already finished"
    # the catalog price must NOT have leaked onto the invoice
    conn = database.get_db()
    row = conn.execute("SELECT price, total_amount FROM bookings WHERE id = ?",
                       (booking["id"],)).fetchone()
    conn.close()
    assert row["price"] == booking["price"]
    assert row["total_amount"] == booking["price"]


def test_service_change_surfaces_in_customer_list_payload(client, monkeypatch):
    user, booking, new_service, _other = _setup(client, monkeypatch)
    assert client.patch(
        f"/api/technician/bookings/{booking['id']}/service",
        json={"serviceId": new_service["id"]},
        headers=auth_headers("x"),
    ).status_code == 200
    listing = client.get("/api/bookings", headers=auth_headers(user["token"])).get_json()
    mine = next(b for b in listing if b["id"] == booking["id"])
    assert len(mine["serviceChanges"]) == 1
    assert mine["serviceChanges"][0]["newService"].endswith(new_service["name"])
    assert mine["price"] == new_service["price"]


def test_service_upgrade_requires_the_assigned_technician(client, monkeypatch):
    _user, booking, new_service, _other = _setup(client, monkeypatch)
    # a different technician's session must not be able to reprice someone
    # else's job (404-scoped like every other booking route)
    mock_firebase_claims(monkeypatch, uid="tech-other", email="other@example.com",
                         email_verified=True)
    client.post(
        "/api/technician/bootstrap",
        json={"name": "Other Tech", "category": "RasoiSpark", "area": "Test Area"},
        headers=auth_headers("x"),
    )
    resp = client.patch(
        f"/api/technician/bookings/{booking['id']}/service",
        json={"serviceId": new_service["id"]},
        headers=auth_headers("x"),
    )
    assert resp.status_code == 404
