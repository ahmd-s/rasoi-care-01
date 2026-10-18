"""Customer -> Partner -> Owner booking flow against the real routes, using
the same /api/bookings/cart checkout the Customer app calls. Each actor has
its own bearer token; Firebase verification is stubbed per token (no network,
no real project)."""
import pytest

import app as app_module
import database
from conftest import auth_headers, register_and_login

OWNER_EMAIL = "real-owner@example.com"
CLAIMS = {
    "tech-token": dict(uid="tech-uid", email="tech@example.com", email_verified=True, sign_in_provider="phone"),
    "tech2-token": dict(uid="tech2-uid", email="tech2@example.com", email_verified=True, sign_in_provider="phone"),
    "owner-token": dict(uid="owner-uid", email=OWNER_EMAIL, email_verified=True, sign_in_provider="google.com"),
    "other-token": dict(uid="other-uid", email="someone@gmail.com", email_verified=True, sign_in_provider="google.com"),
}


@pytest.fixture(autouse=True)
def _stub_firebase(monkeypatch):
    def verify(token):
        c = CLAIMS.get(token)
        return {"name": None, "phone_number": None, **c} if c else None
    monkeypatch.setattr(app_module, "verify_firebase_token", verify)
    monkeypatch.setattr(app_module, "_STAFF_BOOTSTRAP_OWNER_EMAILS", {OWNER_EMAIL})


def _tech(client, token, category=None, area="Nashik", online=True):
    body = {"name": "Tech", "area": area}
    if category:
        body["category"] = category
    tech = client.post("/api/technician/bootstrap", json=body, headers=auth_headers(token)).get_json()
    conn = database.get_db()
    conn.execute("UPDATE technicians SET verified = 1, online = ? WHERE id = ?", (1 if online else 0, tech["id"]))
    conn.commit()
    conn.close()
    return tech


def _service(client):
    s = client.get("/api/services").get_json()[0]
    return s["id"], s["category"]


def _cart(client, user, ids, **extra):
    return client.post("/api/bookings/cart", json={"serviceIds": ids, "useCoins": False, **extra},
                       headers=auth_headers(user["token"]))


def test_cart_requires_auth(client):
    assert client.post("/api/bookings/cart", json={"serviceIds": ["x"]}).status_code == 401


def test_cart_unknown_service_is_400_with_message(client):
    _tech(client, "tech-token")
    user = register_and_login(client)
    resp = _cart(client, user, ["nope"])
    assert resp.status_code == 400 and resp.get_json()["error"]


def test_cart_no_technician_registered_is_503(client):
    user = register_and_login(client)
    sid, _ = _service(client)
    resp = _cart(client, user, [sid])
    assert resp.status_code == 503
    assert "technician" in resp.get_json()["error"].lower()
    assert client.get("/api/bookings", headers=auth_headers(user["token"])).get_json() == []


def test_cart_empty_or_malformed_body_is_400(client):
    user = register_and_login(client)
    for body in ({}, {"serviceIds": []}, {"serviceIds": "svc"}, {"serviceIds": [1]}):
        resp = client.post("/api/bookings/cart", json=body, headers=auth_headers(user["token"]))
        assert resp.status_code == 400, body


def test_full_flow_customer_partner_owner(client):
    sid, cat = _service(client)
    tech = _tech(client, "tech-token", category=cat)
    user = register_and_login(client)

    resp = _cart(client, user, [sid], area="Home", addressLine="Gangapur Road, Nashik")
    assert resp.status_code == 201, resp.get_json()
    booking = resp.get_json()["bookings"][0]
    bid = booking["id"]
    assert bid.startswith("RC-") and booking["status"] == "Requested"

    # Persisted + customer sees it.
    mine = client.get("/api/bookings", headers=auth_headers(user["token"])).get_json()
    assert [b["id"] for b in mine] == [bid]

    # Partner incoming feed (customer contact redacted).
    feed = client.get("/api/technician/bookings/available", headers=auth_headers("tech-token")).get_json()
    assert [b["id"] for b in feed] == [bid]

    # Owner dashboard reads the same booking.
    assert client.post("/api/staff/bootstrap", json={}, headers=auth_headers("owner-token")).status_code == 200
    owner_list = client.get("/api/bookings", headers=auth_headers("owner-token")).get_json()
    assert [(b["id"], b["status"]) for b in owner_list] == [(bid, "Requested")]

    # Partner accepts -> owner and customer see the update on the same record.
    assert client.patch(f"/api/bookings/{bid}/claim", json={}, headers=auth_headers("tech-token")).status_code == 200
    owner_list = client.get("/api/bookings", headers=auth_headers("owner-token")).get_json()
    assert owner_list[0]["id"] == bid and owner_list[0]["technicianId"] == tech["id"]
    assert owner_list[0]["status"] != "Requested"
    mine = client.get("/api/bookings", headers=auth_headers(user["token"])).get_json()
    assert mine[0]["status"] == owner_list[0]["status"]
    # No longer in the incoming feed, and a second partner can't take it.
    assert client.get("/api/technician/bookings/available", headers=auth_headers("tech-token")).get_json() == []
    _tech(client, "tech2-token", category=cat)
    assert client.patch(f"/api/bookings/{bid}/claim", json={}, headers=auth_headers("tech2-token")).status_code in (404, 409)
    my = client.get("/api/technician/bookings", headers=auth_headers("tech-token")).get_json()
    assert [b["id"] for b in my] == [bid]


def test_partner_visibility_rules(client):
    sid, cat = _service(client)
    _tech(client, "tech-token", category=cat, area="Nashik")
    _tech(client, "tech2-token", category="SomeOtherCategory", area="Nashik")
    user = register_and_login(client)
    assert _cart(client, user, [sid]).status_code == 201
    assert len(client.get("/api/technician/bookings/available", headers=auth_headers("tech-token")).get_json()) == 1
    # Different category -> not eligible.
    assert client.get("/api/technician/bookings/available", headers=auth_headers("tech2-token")).get_json() == []
    # Offline -> sees nothing.
    conn = database.get_db()
    conn.execute("UPDATE technicians SET online = 0 WHERE firebase_uid = 'tech-uid'")
    conn.commit(); conn.close()
    assert client.get("/api/technician/bookings/available", headers=auth_headers("tech-token")).get_json() == []


def test_city_scoping_of_dispatch(client):
    sid, cat = _service(client)
    _tech(client, "tech-token", category=cat, area="Pune")
    user = register_and_login(client)
    assert _cart(client, user, [sid], addressLine="Somewhere in Nashik").status_code == 201
    assert client.get("/api/technician/bookings/available", headers=auth_headers("tech-token")).get_json() == []


def test_unauthenticated_and_customer_cannot_use_partner_or_owner_routes(client):
    user = register_and_login(client)
    assert client.get("/api/technician/bookings/available").status_code == 401
    assert client.get("/api/technician/bookings/available", headers=auth_headers(user["token"])).status_code == 401
    assert client.get("/api/bookings").status_code == 401
    assert client.get("/api/stats/overview", headers=auth_headers(user["token"])).status_code in (401, 403)


def test_non_allowlisted_gmail_cannot_read_owner_dashboard(client):
    resp = client.post("/api/staff/bootstrap", json={}, headers=auth_headers("other-token"))
    assert resp.status_code in (401, 403, 404)
    assert client.get("/api/bookings", headers=auth_headers("other-token")).status_code == 401
    assert client.get("/api/stats/overview", headers=auth_headers("other-token")).status_code in (401, 403)


def test_duplicate_submit_creates_one_booking_with_idempotency_key(client):
    sid, cat = _service(client)
    _tech(client, "tech-token", category=cat)
    user = register_and_login(client)
    h = {**auth_headers(user["token"]), "Idempotency-Key": "abc-123-key"}
    body = {"serviceIds": [sid], "useCoins": False}
    r1 = client.post("/api/bookings/cart", json=body, headers=h)
    r2 = client.post("/api/bookings/cart", json=body, headers=h)
    assert r1.status_code == 201 and r2.status_code == 201
    assert r1.get_json()["bookings"][0]["id"] == r2.get_json()["bookings"][0]["id"]
    assert len(client.get("/api/bookings", headers=auth_headers(user["token"])).get_json()) == 1
    # A different key is a genuinely new order.
    h2 = {**auth_headers(user["token"]), "Idempotency-Key": "another-key-1"}
    assert client.post("/api/bookings/cart", json=body, headers=h2).status_code == 201
    assert len(client.get("/api/bookings", headers=auth_headers(user["token"])).get_json()) == 2


def test_firebase_customer_without_backend_profile_gets_401_until_bootstrapped(client, monkeypatch):
    """Root-cause repro: the Customer app's post-sign-in /api/me/bootstrap is
    fire-and-forget; if it was lost (e.g. Render cold start) the user has a
    valid Firebase token but no users row, so checkout 401s."""
    sid, cat = _service(client)
    _tech(client, "tech-token", category=cat)
    CLAIMS["cust-token"] = dict(uid="cust-uid", email="c@example.com", email_verified=True, sign_in_provider="phone")
    try:
        h = auth_headers("cust-token")
        assert client.post("/api/bookings/cart", json={"serviceIds": [sid]}, headers=h).status_code == 401
        assert client.post("/api/me/bootstrap", json={"name": "Cust"}, headers=h).status_code == 200
        resp = client.post("/api/bookings/cart", json={"serviceIds": [sid]}, headers=h)
        assert resp.status_code == 201 and resp.get_json()["bookings"][0]["id"].startswith("RC-")
    finally:
        CLAIMS.pop("cust-token", None)


def test_replayed_checkout_does_not_redeem_coins_twice(client):
    sid, cat = _service(client)
    _tech(client, "tech-token", category=cat)
    user = register_and_login(client)
    conn = database.get_db()
    conn.execute("UPDATE users SET coins_balance = 100 WHERE email = ?", ("alice@example.com",))
    conn.commit(); conn.close()
    h = {**auth_headers(user["token"]), "Idempotency-Key": "coins-key-0001"}
    body = {"serviceIds": [sid], "useCoins": True}
    first = client.post("/api/bookings/cart", json=body, headers=h).get_json()
    again = client.post("/api/bookings/cart", json=body, headers=h).get_json()
    assert first == again and first["pricing"]["coinsRedeemed"] == 100
    me = client.get("/api/auth/me", headers=auth_headers(user["token"])).get_json()
    assert me["coinsBalance"] == 0


def test_bad_idempotency_key_rejected(client):
    user = register_and_login(client)
    h = {**auth_headers(user["token"]), "Idempotency-Key": "bad key!"}
    assert client.post("/api/bookings/cart", json={"serviceIds": ["x"]}, headers=h).status_code == 400
