"""Kitchen Passport V9.7 — appliance registration and custom brands.

Technicians register appliances for the customer of a booking assigned to
them; the customer reads their own passport. Brands added through "Add
Brand" are per technician and per appliance category.
"""
import pytest

import kitchen_passport
from conftest import register_and_login, auth_headers, mock_firebase_claims
import database


def _bootstrap_tech(client, monkeypatch, uid):
    mock_firebase_claims(monkeypatch, uid=uid, email=f"{uid}@example.com", email_verified=True)
    resp = client.post(
        "/api/technician/bootstrap",
        json={"name": "Passport Tech", "category": "RasoiSpark", "area": "Test Area"},
        headers=auth_headers("x"),
    )
    assert resp.status_code == 200
    tech = resp.get_json()
    conn = database.get_db()
    conn.execute("UPDATE technicians SET verified = 1, online = 1 WHERE id = ?", (tech["id"],))
    conn.commit()
    conn.close()
    return tech


def _claimed_booking(client, email="pp-customer@example.com", phone="9876900010"):
    user = register_and_login(client, email=email, phone=phone)
    service_id = client.get("/api/services").get_json()[0]["id"]
    booking = client.post(
        "/api/bookings", json={"service_id": service_id}, headers=auth_headers(user["token"])
    ).get_json()
    resp = client.patch(f"/api/bookings/{booking['id']}/claim", json={}, headers=auth_headers("x"))
    assert resp.status_code == 200
    return user, booking


@pytest.fixture()
def setup(client, monkeypatch):
    tech = _bootstrap_tech(client, monkeypatch, "tech-passport")
    user, booking = _claimed_booking(client)
    return client, tech, user, booking


HOB = {"category": "hob", "brand": "Elica", "specs": {"fuel": "gas", "burners": 4}}


def _register(client, booking_id, body):
    return client.post(
        f"/api/technician/bookings/{booking_id}/kitchen/appliances",
        json=body, headers=auth_headers("x"),
    )


def test_register_and_list_for_customer(setup):
    client, _tech, user, booking = setup
    resp = _register(client, booking["id"], {**HOB, "model": "  Flexi 4B ", "installYear": 2021})
    assert resp.status_code == 201, resp.get_json()
    body = resp.get_json()
    assert body["category"] == "hob" and body["brand"] == "Elica"
    assert body["model"] == "Flexi 4B" and body["installYear"] == 2021
    assert body["specs"] == {"fuel": "gas", "burners": 4}

    listed = client.get(f"/api/technician/bookings/{booking['id']}/kitchen", headers=auth_headers("x"))
    assert [a["id"] for a in listed.get_json()["appliances"]] == [body["id"]]

    mine = client.get("/api/kitchen-passport", headers=auth_headers(user["token"]))
    assert [a["id"] for a in mine.get_json()["appliances"]] == [body["id"]]


def test_customer_only_sees_own_appliances(setup):
    client, _tech, _user, booking = setup
    assert _register(client, booking["id"], HOB).status_code == 201
    other = register_and_login(client, email="other@example.com", phone="9876900011")
    resp = client.get("/api/kitchen-passport", headers=auth_headers(other["token"]))
    assert resp.status_code == 200 and resp.get_json()["appliances"] == []


def test_passport_requires_auth(client):
    assert client.get("/api/kitchen-passport").status_code == 401
    assert client.get("/api/technician/custom-brands").status_code == 401


def test_other_technicians_booking_is_404(setup, monkeypatch):
    client, _tech, _user, booking = setup
    _bootstrap_tech(client, monkeypatch, "tech-intruder")
    assert _register(client, booking["id"], HOB).status_code == 404
    resp = client.get(f"/api/technician/bookings/{booking['id']}/kitchen", headers=auth_headers("x"))
    assert resp.status_code == 404


def test_unknown_booking_is_404(setup):
    client, *_ = setup
    assert _register(client, "NOPE-1", HOB).status_code == 404


@pytest.mark.parametrize("category", kitchen_passport.CATEGORIES)
def test_every_category_registers_with_valid_specs(setup, category):
    client, _tech, _user, booking = setup
    specs = {}
    for key, rule in kitchen_passport.SPEC_FIELDS[category].items():
        specs[key] = rule["choices"][0] if rule["kind"] == "choice" else rule["min"]
    resp = _register(client, booking["id"], {"category": category, "brand": "Test", "specs": specs})
    assert resp.status_code == 201, resp.get_json()


def test_seven_categories_and_no_generic_type_field():
    assert len(kitchen_passport.CATEGORIES) == 7
    assert set(kitchen_passport.SPEC_FIELDS) == set(kitchen_passport.CATEGORIES)
    for fields in kitchen_passport.SPEC_FIELDS.values():
        assert "type" not in fields


@pytest.mark.parametrize("body,field", [
    ({"brand": "Elica", "specs": {}}, "category"),
    ({"category": "toaster", "brand": "X"}, "category"),
    ({**HOB, "brand": "   "}, "brand"),
    ({**HOB, "brand": "x" * 61}, "brand"),
    ({"category": "hob", "brand": "Elica", "specs": {"burners": 4}}, "specs.fuel"),
    ({"category": "hob", "brand": "Elica", "specs": {"fuel": "gas", "burners": 9}}, "specs.burners"),
    ({"category": "hob", "brand": "Elica", "specs": {"fuel": "coal", "burners": 4}}, "specs.fuel"),
    ({"category": "hob", "brand": "Elica", "specs": {"fuel": "gas", "burners": True}}, "specs.burners"),
    ({"category": "hob", "brand": "Elica", "specs": {"fuel": "gas", "burners": 4, "voltage": 1}}, "specs.voltage"),
    ({**HOB, "installYear": 1850}, "installYear"),
    ({**HOB, "installYear": "2020"}, "installYear"),
    ({**HOB, "model": 5}, "model"),
    ({"category": "chimney", "brand": "Faber", "specs": {"fuel": "gas"}}, "specs.fuel"),
])
def test_invalid_registrations_rejected(setup, body, field):
    client, _tech, _user, booking = setup
    resp = _register(client, booking["id"], body)
    assert resp.status_code == 400
    assert field in resp.get_json()["fields"]
    listed = client.get(f"/api/technician/bookings/{booking['id']}/kitchen", headers=auth_headers("x"))
    assert listed.get_json()["appliances"] == []


def test_custom_brand_add_is_idempotent_and_category_scoped(setup):
    client, *_ = setup
    h = auth_headers("x")
    first = client.post("/api/technician/custom-brands",
                        json={"category": "chimney", "name": "  Nova   Air "}, headers=h)
    assert first.status_code == 201
    assert first.get_json()["name"] == "Nova Air"
    again = client.post("/api/technician/custom-brands",
                        json={"category": "chimney", "name": "nova air"}, headers=h)
    assert again.status_code == 200
    assert again.get_json()["id"] == first.get_json()["id"]

    chimney = client.get("/api/technician/custom-brands?category=chimney", headers=h).get_json()["brands"]
    assert [b["name"] for b in chimney] == ["Nova Air"]
    ro = client.get("/api/technician/custom-brands?category=ro_purifier", headers=h).get_json()["brands"]
    assert ro == []
    # same name under another category is a separate brand
    assert client.post("/api/technician/custom-brands",
                       json={"category": "ro_purifier", "name": "Nova Air"}, headers=h).status_code == 201


def test_custom_brands_are_per_technician(setup, monkeypatch):
    client, *_ = setup
    client.post("/api/technician/custom-brands", json={"category": "hob", "name": "Mine"},
                headers=auth_headers("x"))
    _bootstrap_tech(client, monkeypatch, "tech-other-brands")
    resp = client.get("/api/technician/custom-brands?category=hob", headers=auth_headers("x"))
    assert resp.get_json()["brands"] == []


@pytest.mark.parametrize("body,field", [
    ({"category": "hob", "name": ""}, "name"),
    ({"category": "hob", "name": "   "}, "name"),
    ({"category": "hob", "name": "y" * 61}, "name"),
    ({"category": "hob"}, "name"),
    ({"category": "toaster", "name": "Ok"}, "category"),
    ({"name": "Ok"}, "category"),
])
def test_invalid_custom_brand_rejected(setup, body, field):
    client, *_ = setup
    resp = client.post("/api/technician/custom-brands", json=body, headers=auth_headers("x"))
    assert resp.status_code == 400
    assert field in resp.get_json()["fields"]


def test_custom_brand_list_rejects_unknown_category(setup):
    client, *_ = setup
    resp = client.get("/api/technician/custom-brands?category=toaster", headers=auth_headers("x"))
    assert resp.status_code == 400


def test_partner_app_catalog_matches_backend():
    """The Partner app carries its own copy of the category/field table (see
    passport_catalog.dart); fail here if the two drift apart."""
    import pathlib
    import re

    src = pathlib.Path(__file__).resolve().parent.parent.joinpath(
        "careplus_partner/lib/features/passport/passport_catalog.dart").read_text()
    body = src[src.index("const kApplianceCategories"):]
    blocks = re.split(r"\n  ApplianceCategory\(", body)[1:]
    assert [re.search(r"id: '(\w+)'", b).group(1) for b in blocks] == list(kitchen_passport.CATEGORIES)
    for block in blocks:
        category = re.search(r"id: '(\w+)'", block).group(1)
        rules = kitchen_passport.SPEC_FIELDS[category]
        dart_keys = re.findall(r"SpecField\.(?:choice|integer)\('(\w+)'", block)
        assert dart_keys == list(rules), category
        chunks = {}
        for part in re.split(r"(?=SpecField\.(?:choice|integer)\()", block)[1:]:
            chunks[re.match(r"SpecField\.\w+\('(\w+)'", part).group(1)] = part
        for key, rule in rules.items():
            chunk = chunks[key]
            assert ("required: false" in chunk) == (not rule["required"]), (category, key)
            if rule["kind"] == "choice":
                assert re.findall(r"'(\w+)':", chunk) == list(rule["choices"]), (category, key)
            else:
                assert f"min: {rule['min']}" in chunk and f"max: {rule['max']}" in chunk, (category, key)


# ------------------------------------------------------------ access control
def _set_status(booking_id, status):
    conn = database.get_db()
    conn.execute("UPDATE bookings SET status = ? WHERE id = ?", (status, booking_id))
    conn.commit()
    conn.close()


def _row_count(table="kitchen_appliances"):
    conn = database.get_db()
    n = conn.execute(f"SELECT COUNT(*) AS n FROM {table}").fetchone()["n"]
    conn.close()
    return n


@pytest.mark.parametrize("status", ["Completed", "Cancelled"])
def test_closed_booking_is_readable_but_not_writable(setup, status):
    client, _tech, _user, booking = setup
    created = _register(client, booking["id"], HOB).get_json()
    _set_status(booking["id"], status)

    listed = client.get(f"/api/technician/bookings/{booking['id']}/kitchen", headers=auth_headers("x"))
    assert listed.status_code == 200
    assert [a["id"] for a in listed.get_json()["appliances"]] == [created["id"]]

    resp = _register(client, booking["id"], {**HOB, "brand": "Faber"})
    assert resp.status_code == 409
    assert resp.get_json()["code"] == "booking_closed"
    assert _row_count() == 1


@pytest.mark.parametrize("method", ["put", "patch", "delete"])
def test_appliances_cannot_be_modified_or_deleted(setup, method):
    client, _tech, _user, booking = setup
    created = _register(client, booking["id"], HOB).get_json()
    for url in (
        f"/api/technician/bookings/{booking['id']}/kitchen/appliances/{created['id']}",
        f"/api/technician/bookings/{booking['id']}/kitchen/appliances",
        f"/api/kitchen-passport/{created['id']}",
    ):
        resp = getattr(client, method)(url, json={"brand": "X"}, headers=auth_headers("x"))
        assert resp.status_code in (404, 405), (method, url, resp.status_code)
    assert _row_count() == 1


def test_unassigned_booking_is_404_for_read_and_write(client, monkeypatch):
    _bootstrap_tech(client, monkeypatch, "tech-unassigned")
    user = register_and_login(client, email="unassigned@example.com", phone="9876900020")
    service_id = client.get("/api/services").get_json()[0]["id"]
    booking = client.post("/api/bookings", json={"service_id": service_id},
                          headers=auth_headers(user["token"])).get_json()  # never claimed
    assert _register(client, booking["id"], HOB).status_code == 404
    resp = client.get(f"/api/technician/bookings/{booking['id']}/kitchen", headers=auth_headers("x"))
    assert resp.status_code == 404
    assert _row_count() == 0


def test_other_technicians_closed_booking_stays_hidden(setup, monkeypatch):
    client, _tech, _user, booking = setup
    _set_status(booking["id"], "Completed")
    _bootstrap_tech(client, monkeypatch, "tech-other-closed")
    assert client.get(f"/api/technician/bookings/{booking['id']}/kitchen",
                      headers=auth_headers("x")).status_code == 404
    assert _register(client, booking["id"], HOB).status_code == 404


def test_customer_cannot_use_technician_routes_or_see_others(setup, monkeypatch):
    client, _tech, user, booking = setup
    created = _register(client, booking["id"], HOB).get_json()
    # A customer bearer token is not a technician Firebase session.
    import app as app_module
    monkeypatch.setattr(app_module, "verify_firebase_token", lambda token: None)
    resp = client.get(f"/api/technician/bookings/{booking['id']}/kitchen",
                      headers=auth_headers(user["token"]))
    assert resp.status_code == 401
    mine = client.get("/api/kitchen-passport", headers=auth_headers(user["token"])).get_json()
    assert [a["id"] for a in mine["appliances"]] == [created["id"]]


# --------------------------------------------------- limits and duplicates
def test_appliance_limit_is_per_customer(setup, monkeypatch):
    client, tech, _user, booking = setup
    monkeypatch.setattr(kitchen_passport, "MAX_APPLIANCES_PER_CUSTOMER", 3)
    for i in range(3):
        assert _register(client, booking["id"], {**HOB, "serialNumber": f"S{i}"}).status_code == 201
    resp = _register(client, booking["id"], {**HOB, "serialNumber": "S9"})
    assert resp.status_code == 409
    assert resp.get_json()["code"] == "appliance_limit_reached"
    assert _row_count() == 3

    # another customer of the same technician is unaffected
    _user2, booking2 = _claimed_booking(client, email="second@example.com", phone="9876900021")
    assert _register(client, booking2["id"], HOB).status_code == 201


def test_custom_brand_limit_is_per_technician(setup, monkeypatch):
    client, *_ = setup
    monkeypatch.setattr(kitchen_passport, "MAX_CUSTOM_BRANDS_PER_TECHNICIAN", 2)
    h = auth_headers("x")
    for name in ("One", "Two"):
        assert client.post("/api/technician/custom-brands",
                           json={"category": "hob", "name": name}, headers=h).status_code == 201
    over = client.post("/api/technician/custom-brands", json={"category": "hob", "name": "Three"}, headers=h)
    assert over.status_code == 409
    assert over.get_json()["code"] == "brand_limit_reached"
    # re-adding an existing brand at the cap is still an idempotent 200
    again = client.post("/api/technician/custom-brands", json={"category": "hob", "name": "one"}, headers=h)
    assert again.status_code == 200
    assert _row_count("custom_brands") == 2


def test_same_serial_is_a_duplicate_for_that_customer_and_category(setup):
    client, _tech, _user, booking = setup
    assert _register(client, booking["id"], {**HOB, "serialNumber": "AB-123"}).status_code == 201
    dup = _register(client, booking["id"], {**HOB, "brand": "Faber", "serialNumber": "  ab-123 "})
    assert dup.status_code == 409
    assert dup.get_json()["code"] == "duplicate_appliance"
    spaced = _register(client, booking["id"], {**HOB, "serialNumber": "AB -123"})
    assert spaced.status_code == 409
    assert _row_count() == 1

    # same serial under a different category is a different appliance
    chimney = {"category": "chimney", "brand": "Faber", "serialNumber": "AB-123",
               "specs": {"mounting": "wall_mounted", "filter": "baffle", "width_cm": 90}}
    assert _register(client, booking["id"], chimney).status_code == 201
    # ... and the same serial for another customer is fine
    _u2, booking2 = _claimed_booking(client, email="third@example.com", phone="9876900022")
    assert _register(client, booking2["id"], {**HOB, "serialNumber": "AB-123"}).status_code == 201


def test_identical_appliances_without_serial_are_allowed(setup):
    client, *_ , booking = setup
    body = {**HOB, "model": "Flexi 4B"}
    assert _register(client, booking["id"], body).status_code == 201
    assert _register(client, booking["id"], body).status_code == 201
    assert _row_count() == 2


def test_retried_request_id_returns_the_same_appliance(setup):
    client, _tech, user, booking = setup
    body = {**HOB, "clientRequestId": "req-0123456789"}
    first = _register(client, booking["id"], body)
    again = _register(client, booking["id"], body)
    assert first.status_code == 201 and again.status_code == 200
    assert first.get_json()["id"] == again.get_json()["id"]
    assert _row_count() == 1
    mine = client.get("/api/kitchen-passport", headers=auth_headers(user["token"])).get_json()
    assert len(mine["appliances"]) == 1


def test_replay_works_at_the_cap_and_after_the_booking_is_not_needed(setup, monkeypatch):
    client, _tech, _user, booking = setup
    monkeypatch.setattr(kitchen_passport, "MAX_APPLIANCES_PER_CUSTOMER", 1)
    body = {**HOB, "clientRequestId": "req-cap-000001"}
    assert _register(client, booking["id"], body).status_code == 201
    assert _register(client, booking["id"], body).status_code == 200


def test_request_id_cannot_be_replayed_onto_another_customer(setup):
    client, _tech, _user, booking = setup
    body = {**HOB, "clientRequestId": "req-shared-0001"}
    assert _register(client, booking["id"], body).status_code == 201
    _u2, booking2 = _claimed_booking(client, email="fourth@example.com", phone="9876900023")
    resp = _register(client, booking2["id"], body)
    assert resp.status_code == 409
    assert resp.get_json()["code"] == "request_id_reused"
    assert _row_count() == 1


@pytest.mark.parametrize("bad", ["short", "has space 123456", "x" * 65, 12345678, "bad!chars-12345"])
def test_invalid_client_request_id_rejected(setup, bad):
    client, _tech, _user, booking = setup
    resp = _register(client, booking["id"], {**HOB, "clientRequestId": bad})
    assert resp.status_code == 400
    assert "clientRequestId" in resp.get_json()["fields"]


def test_normal_valid_registrations_still_work(setup):
    client, _tech, _user, booking = setup
    ids = set()
    for body in (
        HOB,
        {**HOB, "brand": "Faber", "serialNumber": "F-1", "clientRequestId": "req-normal-001"},
        {"category": "ro_purifier", "brand": "Kent",
         "specs": {"technology": "ro_uv", "mounting": "wall", "tank_litres": 8}},
    ):
        resp = _register(client, booking["id"], body)
        assert resp.status_code == 201, resp.get_json()
        ids.add(resp.get_json()["id"])
    assert len(ids) == 3


def test_request_id_is_scoped_to_the_authenticated_technician(client, monkeypatch):
    """Two technicians that happen to send the same clientRequestId each get
    their own appliance; neither can be handed the other's record."""
    _bootstrap_tech(client, monkeypatch, "tech-scope-a")
    user_a, booking_a = _claimed_booking(client, email="scope-a@example.com", phone="9876900030")
    body = {**HOB, "clientRequestId": "req-scope-0001"}
    first = _register(client, booking_a["id"], body)
    assert first.status_code == 201

    _bootstrap_tech(client, monkeypatch, "tech-scope-b")
    user_b, booking_b = _claimed_booking(client, email="scope-b@example.com", phone="9876900031")
    second = _register(client, booking_b["id"], body)
    assert second.status_code == 201
    assert second.get_json()["id"] != first.get_json()["id"]

    # Technician B cannot replay the key against technician A's customer.
    assert _register(client, booking_a["id"], body).status_code == 404
    mine_b = client.get("/api/kitchen-passport", headers=auth_headers(user_b["token"])).get_json()
    assert [a["id"] for a in mine_b["appliances"]] == [second.get_json()["id"]]
    mine_a = client.get("/api/kitchen-passport", headers=auth_headers(user_a["token"])).get_json()
    assert [a["id"] for a in mine_a["appliances"]] == [first.get_json()["id"]]
