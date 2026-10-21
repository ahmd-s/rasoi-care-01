"""Technician live location: who may publish, who may read, and staleness."""
import pytest

import app as app_module
import database
from conftest import auth_headers, register_and_login

CLAIMS = {
    "tech-token": dict(uid="tech-uid", email=None, email_verified=False,
                       sign_in_provider="phone", phone_number="+919999900001"),
}
FIX = {"lat": 19.07, "lng": 72.87}


@pytest.fixture(autouse=True)
def _stub(monkeypatch):
    monkeypatch.setattr(app_module, "verify_firebase_token",
                        lambda t: ({"name": None, **CLAIMS[t]} if t in CLAIMS else None))


def _setup(client, status="On the way", verified=1, online=1):
    cust = register_and_login(client)
    tech = client.post("/api/technician/bootstrap", json={"name": "T"},
                       headers=auth_headers("tech-token")).get_json()
    conn = database.get_db()
    conn.execute("UPDATE technicians SET verified = ?, online = ? WHERE id = ?",
                 (verified, online, tech["id"]))
    ts = database.now()
    conn.execute(
        "INSERT INTO bookings (id, category, service, price, technician_id, status, "
        "user_id, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?)",
        ("BK1", "RasoiSpark", "Clean", 500, tech["id"], status, cust["user"]["id"], ts, ts),
    )
    conn.commit()
    conn.close()
    return cust, tech


def _push(client, body=FIX):
    return client.post("/api/technician/location", json=body, headers=auth_headers("tech-token"))


def _read(client, cust, bid="BK1"):
    return client.get(f"/api/bookings/{bid}/live-location", headers=auth_headers(cust["token"]))


def _rows():
    conn = database.get_db()
    n = conn.execute("SELECT COUNT(*) AS n FROM technician_live_locations").fetchone()["n"]
    conn.close()
    return n


def test_requires_auth(client):
    assert client.post("/api/technician/location", json=FIX).status_code == 401
    assert client.get("/api/bookings/BK1/live-location").status_code == 401


def test_publish_then_owner_reads(client):
    cust, _ = _setup(client)
    assert _push(client).status_code == 200
    loc = _read(client, cust).get_json()["location"]
    assert loc["lat"] == 19.07 and loc["lng"] == 72.87


@pytest.mark.parametrize("body", [
    {"lat": 91, "lng": 0}, {"lat": 0, "lng": 181}, {"lat": "1", "lng": 2},
    {"lat": True, "lng": 2}, {}, {"lat": float("nan"), "lng": 1},
])
def test_rejects_invalid_coordinates(client, body):
    _setup(client)
    assert _push(client, body).status_code == 400
    assert _rows() == 0


def test_unapproved_technician_cannot_publish(client):
    _setup(client, verified=0)
    assert _push(client).status_code == 403
    assert _rows() == 0


def test_offline_technician_cannot_publish_and_fix_is_removed(client):
    cust, tech = _setup(client)
    assert _push(client).status_code == 200
    conn = database.get_db()
    conn.execute("UPDATE technicians SET online = 0 WHERE id = ?", (tech["id"],))
    conn.commit()
    conn.close()
    assert _push(client).status_code == 403
    assert _rows() == 0
    assert _read(client, cust).get_json()["location"] is None


def test_offline_technician_hidden_from_customer_even_with_fresh_row(client):
    cust, tech = _setup(client)
    assert _push(client).status_code == 200
    conn = database.get_db()
    conn.execute("UPDATE technicians SET online = 0 WHERE id = ?", (tech["id"],))
    conn.commit()
    conn.close()
    assert _read(client, cust).get_json()["location"] is None


def test_no_active_job_cannot_publish(client):
    _setup(client, status="Requested")
    assert _push(client).status_code == 409
    assert _rows() == 0


def test_completed_booking_stops_exposure(client):
    cust, tech = _setup(client)
    assert _push(client).status_code == 200
    conn = database.get_db()
    conn.execute("UPDATE bookings SET status = 'Completed' WHERE id = 'BK1'")
    conn.commit()
    conn.close()
    assert _read(client, cust).get_json()["location"] is None
    assert _push(client).status_code == 409
    assert _rows() == 0


def test_other_customer_cannot_read(client):
    _setup(client)
    assert _push(client).status_code == 200
    other = register_and_login(client, email="bob@example.com", name="Bob", phone="9876500000")
    assert _read(client, other).status_code == 404


def test_stale_fix_is_hidden(client):
    cust, tech = _setup(client)
    assert _push(client).status_code == 200
    conn = database.get_db()
    conn.execute("UPDATE technician_live_locations SET updated_at = '2020-01-01T00:00:00Z'")
    conn.commit()
    conn.close()
    assert _read(client, cust).get_json()["location"] is None


def test_unassigned_booking_has_no_location(client):
    cust, _ = _setup(client)
    conn = database.get_db()
    conn.execute("UPDATE bookings SET technician_id = NULL WHERE id = 'BK1'")
    conn.commit()
    conn.close()
    assert _read(client, cust).get_json()["location"] is None


def test_delete_clears_fix(client):
    _setup(client)
    assert _push(client).status_code == 200
    r = client.delete("/api/technician/location", headers=auth_headers("tech-token"))
    assert r.status_code == 200 and _rows() == 0


def test_booking_payload_does_not_expose_technician_firebase_uid(client):
    cust, _ = _setup(client)
    r = client.get("/api/bookings/BK1", headers=auth_headers(cust["token"]))
    assert r.status_code == 200
    assert "technicianFirebaseUid" not in r.get_json()


def test_maps_server_key_is_environment_only_and_proxy_requires_auth(client, monkeypatch):
    assert client.get("/api/maps/autocomplete?input=mumbai").status_code == 401
    cust = register_and_login(client)
    monkeypatch.setattr(app_module, "MAPS_SERVER_API_KEY", "")
    r = client.get("/api/maps/autocomplete?input=mumbai", headers=auth_headers(cust["token"]))
    assert r.status_code == 503
    assert "key" not in r.get_data(as_text=True).lower().replace("maps search", "")


def test_maps_proxy_returns_minimal_shape_and_never_the_key(client, monkeypatch):
    secret = "test-server-key-should-never-leak"
    monkeypatch.setattr(app_module, "MAPS_SERVER_API_KEY", secret)
    seen = {}

    def fake_places(payload):
        seen["places"] = payload
        return {"suggestions": [
            {"placePrediction": {"placeId": "p1", "text": {"text": "Andheri, Mumbai"}, "extra": 1}},
            {"queryPrediction": {}}, "junk",
        ]}

    def fake_geocode(path, params):
        seen["geocode"] = params
        return {"status": "OK", "results": [{
            "formatted_address": "Andheri, Mumbai", "place_id": "p1", "types": ["x"],
            "geometry": {"location": {"lat": 19.1, "lng": 72.8}}}]}

    monkeypatch.setattr(app_module, "_places_server_post", fake_places)
    monkeypatch.setattr(app_module, "_maps_server_get", fake_geocode)
    cust = register_and_login(client)
    h = auth_headers(cust["token"])

    r = client.get("/api/maps/autocomplete?input=andheri", headers=h)
    assert r.get_json() == {"predictions": [{"description": "Andheri, Mumbai", "place_id": "p1"}]}
    assert seen["places"]["includedRegionCodes"] == ["in"]
    r2 = client.get("/api/maps/geocode?placeId=p1", headers=h)
    assert r2.get_json() == {"results": [
        {"formatted_address": "Andheri, Mumbai", "lat": 19.1, "lng": 72.8}]}
    assert secret not in r.get_data(as_text=True) + r2.get_data(as_text=True)
    assert client.get("/api/maps/autocomplete?input=ab", headers=h).status_code == 400
    assert client.get("/api/maps/geocode?lat=999&lng=0", headers=h).status_code == 400
    assert client.get("/api/maps/geocode", headers=h).status_code == 400
