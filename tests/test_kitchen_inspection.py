"""Kitchen Passport V9.7 — appliance-specific technician inspection checklists.

A checklist is saved per appliance per visit (the booking), by the technician
assigned to that booking, and only while the booking is open.
"""
import pathlib
import re

import pytest

import database
import kitchen_passport
from conftest import register_and_login, auth_headers, mock_firebase_claims

EXPECTED_LABELS = {
    "chimney": ["Suction performance", "Filter condition", "Grease and dirt", "Motor condition",
                "Controls and lights", "Duct and airflow", "Physical condition", "Safety"],
    "hob": ["Burner performance", "Ignition", "Gas flow", "Burner and cap condition",
            "Pan support", "Glass / surface", "Knobs and controls", "Safety"],
    "microwave": ["Heating performance", "Power / operation", "Door and seal", "Turntable",
                  "Controls / display", "Interior condition", "Noise / vibration", "Electrical safety"],
    "oven": ["Heating performance", "Temperature control", "Heating elements", "Door and seal",
             "Controls / timer", "Interior condition", "Fan / convection", "Electrical safety"],
    "dishwasher": ["Cleaning performance", "Water inlet", "Drainage", "Spray arms",
                   "Filter condition", "Door and seal", "Noise / vibration", "Electrical safety"],
    "refrigerator": ["Cooling performance", "Compressor", "Door seal", "Frost / ice condition",
                     "Drainage", "Interior condition", "Fan / airflow", "Electrical safety"],
    "ro_purifier": ["Purification / TDS performance", "RO membrane condition",
                    "Pre-filter / sediment filter", "Carbon filter condition", "Water leakage",
                    "Storage tank / float", "Pump / flow condition", "Electrical and safety"],
}

HOB = {"category": "hob", "brand": "Elica", "specs": {"fuel": "gas", "burners": 4}}
H = auth_headers("x")


def _make_tech(client, monkeypatch, uid):
    mock_firebase_claims(monkeypatch, uid=uid, email=f"{uid}@example.com", email_verified=True)
    tech = client.post("/api/technician/bootstrap",
                       json={"name": "Insp Tech", "category": "RasoiSpark", "area": "Test Area"},
                       headers=H).get_json()
    conn = database.get_db()
    conn.execute("UPDATE technicians SET verified = 1, online = 1 WHERE id = ?", (tech["id"],))
    conn.commit()
    conn.close()
    return tech


def _booking(client, email, phone, claim=True):
    user = register_and_login(client, email=email, phone=phone)
    service_id = client.get("/api/services").get_json()[0]["id"]
    booking = client.post("/api/bookings", json={"service_id": service_id},
                          headers=auth_headers(user["token"])).get_json()
    if claim:
        assert client.patch(f"/api/bookings/{booking['id']}/claim", json={}, headers=H).status_code == 200
    return user, booking


def _register_appliance(client, booking_id, body=HOB):
    resp = client.post(f"/api/technician/bookings/{booking_id}/kitchen/appliances", json=body, headers=H)
    assert resp.status_code == 201, resp.get_json()
    return resp.get_json()


def _url(booking_id, appliance_id):
    return f"/api/technician/bookings/{booking_id}/kitchen/appliances/{appliance_id}/inspection"


def _put(client, booking_id, appliance_id, results):
    return client.put(_url(booking_id, appliance_id), json={"results": results}, headers=H)


def _count():
    conn = database.get_db()
    n = conn.execute("SELECT COUNT(*) AS n FROM kitchen_inspection_checks").fetchone()["n"]
    conn.close()
    return n


@pytest.fixture()
def ctx(client, monkeypatch):
    tech = _make_tech(client, monkeypatch, "tech-inspect")
    user, booking = _booking(client, "insp-customer@example.com", "9876900040")
    appliance = _register_appliance(client, booking["id"])
    return client, tech, user, booking, appliance


# ------------------------------------------------------------- definitions
def test_all_seven_checklists_match_the_spec():
    assert set(kitchen_passport.CHECKLISTS) == set(kitchen_passport.CATEGORIES)
    for category, labels in EXPECTED_LABELS.items():
        assert [label for _k, label in kitchen_passport.CHECKLISTS[category]] == labels, category
        keys = [k for k, _l in kitchen_passport.CHECKLISTS[category]]
        assert len(keys) == len(set(keys)) == 8, category


@pytest.mark.parametrize("category", kitchen_passport.CATEGORIES)
def test_each_category_serves_its_own_checklist(client, monkeypatch, category):
    _make_tech(client, monkeypatch, f"tech-def-{category}")
    _user, booking = _booking(client, f"{category}@example.com", "9876900041")
    specs = {}
    for key, rule in kitchen_passport.SPEC_FIELDS[category].items():
        specs[key] = rule["choices"][0] if rule["kind"] == "choice" else rule["min"]
    appliance = _register_appliance(client, booking["id"], {"category": category, "brand": "T", "specs": specs})
    body = client.get(_url(booking["id"], appliance["id"]), headers=H).get_json()
    assert body["category"] == category
    assert [c["label"] for c in body["checks"]] == EXPECTED_LABELS[category]
    assert all(c["result"] is None and c["note"] == "" for c in body["checks"])


def test_partner_app_checklists_match_backend():
    src = pathlib.Path(__file__).resolve().parent.parent.joinpath(
        "careplus_partner/lib/features/passport/inspection_catalog.dart").read_text()
    body = src[src.index("const kInspectionChecklists"):]
    blocks = re.split(r"\n  '(\w+)': \[", body)[1:]
    dart = {blocks[i]: re.findall(r"InspectionItem\('(\w+)', '([^']*)'\)", blocks[i + 1])
            for i in range(0, len(blocks), 2)}
    assert dart == {c: list(items) for c, items in kitchen_passport.CHECKLISTS.items()}


# ------------------------------------------------------ persistence
def test_results_persist_and_reload(ctx):
    client, tech, _user, booking, appliance = ctx
    keys = [k for k, _ in kitchen_passport.CHECKLISTS["hob"]]
    resp = _put(client, booking["id"], appliance["id"], [
        {"key": keys[0], "result": "good"},
        {"key": keys[1], "result": "attention", "note": "  Igniter clicks slowly  "},
        {"key": keys[2], "result": "not_tested", "note": "Induction hob"},
    ])
    assert resp.status_code == 200, resp.get_json()
    reloaded = client.get(_url(booking["id"], appliance["id"]), headers=H).get_json()
    by_key = {c["key"]: c for c in reloaded["checks"]}
    assert by_key[keys[0]]["result"] == "good"
    assert by_key[keys[1]]["result"] == "attention"
    assert by_key[keys[1]]["note"] == "Igniter clicks slowly"
    assert by_key[keys[2]]["result"] == "not_tested"
    assert by_key[keys[3]]["result"] is None  # untouched items stay unrecorded
    assert reloaded["bookingId"] == booking["id"] and reloaded["applianceId"] == appliance["id"]

    conn = database.get_db()
    row = conn.execute("SELECT * FROM kitchen_inspection_checks WHERE check_key = ?", (keys[1],)).fetchone()
    conn.close()
    assert row["technician_id"] == tech["id"]
    assert row["appliance_id"] == appliance["id"] and row["booking_id"] == booking["id"]


def test_saving_again_updates_instead_of_duplicating(ctx):
    client, _tech, _user, booking, appliance = ctx
    key = kitchen_passport.CHECKLISTS["hob"][0][0]
    assert _put(client, booking["id"], appliance["id"], [{"key": key, "result": "attention", "note": "weak"}]).status_code == 200
    assert _put(client, booking["id"], appliance["id"], [{"key": key, "result": "good"}]).status_code == 200
    assert _count() == 1
    check = client.get(_url(booking["id"], appliance["id"]), headers=H).get_json()["checks"][0]
    assert check["result"] == "good" and check["note"] == ""


def test_full_checklist_saves_all_eight(ctx):
    client, _tech, _user, booking, appliance = ctx
    results = [{"key": k, "result": "good"} for k, _ in kitchen_passport.CHECKLISTS["hob"]]
    assert _put(client, booking["id"], appliance["id"], results).status_code == 200
    assert _count() == 8


def test_results_are_kept_per_visit(client, monkeypatch):
    """The same appliance inspected on a second booking has its own results."""
    _make_tech(client, monkeypatch, "tech-visits")
    user, booking1 = _booking(client, "visits@example.com", "9876900042")
    appliance = _register_appliance(client, booking1["id"])
    key = kitchen_passport.CHECKLISTS["hob"][0][0]
    assert _put(client, booking1["id"], appliance["id"], [{"key": key, "result": "attention"}]).status_code == 200
    service_id = client.get("/api/services").get_json()[0]["id"]
    booking2 = client.post("/api/bookings", json={"service_id": service_id},
                           headers=auth_headers(user["token"])).get_json()
    assert client.patch(f"/api/bookings/{booking2['id']}/claim", json={}, headers=H).status_code == 200
    second = client.get(_url(booking2["id"], appliance["id"]), headers=H).get_json()
    assert second["checks"][0]["result"] is None
    assert _put(client, booking2["id"], appliance["id"], [{"key": key, "result": "good"}]).status_code == 200
    first = client.get(_url(booking1["id"], appliance["id"]), headers=H).get_json()
    assert first["checks"][0]["result"] == "attention"


# ------------------------------------------------------------ validation
def test_invalid_bodies_rejected_and_nothing_saved(ctx):
    client, _tech, _user, booking, appliance = ctx
    ok_key = kitchen_passport.CHECKLISTS["hob"][0][0]
    cases = [
        ({"results": []}, "results"),
        ({"results": "good"}, "results"),
        ({}, "results"),
        ({"results": [{"key": ok_key, "result": "excellent"}]}, "results[0].result"),
        ({"results": [{"key": ok_key}]}, "results[0].result"),
        ({"results": [{"key": "suction_performance", "result": "good"}]}, "results[0].key"),  # chimney item
        ({"results": [{"key": ok_key, "result": "good"}, {"key": ok_key, "result": "attention"}]}, "results[1].key"),
        ({"results": [{"key": ok_key, "result": "good", "note": "x" * 301}]}, "results[0].note"),
        ({"results": [{"key": ok_key, "result": "good", "note": 5}]}, "results[0].note"),
        ({"results": ["good"]}, "results[0]"),
        ({"results": [{"key": ok_key, "result": "good"}] * 9}, "results"),
    ]
    for body, field in cases:
        resp = client.put(_url(booking["id"], appliance["id"]), json=body, headers=H)
        assert resp.status_code == 400, body
        assert field in resp.get_json()["fields"], (body, resp.get_json())
    assert client.put(_url(booking["id"], appliance["id"]), data="[1]",
                      content_type="application/json", headers=H).status_code == 400
    assert _count() == 0


def test_mixed_valid_and_invalid_saves_nothing(ctx):
    client, _tech, _user, booking, appliance = ctx
    keys = [k for k, _ in kitchen_passport.CHECKLISTS["hob"]]
    resp = _put(client, booking["id"], appliance["id"],
                [{"key": keys[0], "result": "good"}, {"key": keys[1], "result": "bogus"}])
    assert resp.status_code == 400
    assert _count() == 0


def test_note_of_exactly_300_characters_is_accepted(ctx):
    client, _tech, _user, booking, appliance = ctx
    key = kitchen_passport.CHECKLISTS["hob"][0][0]
    assert _put(client, booking["id"], appliance["id"],
                [{"key": key, "result": "attention", "note": "n" * 300}]).status_code == 200


# --------------------------------------------- authentication / ownership
def test_requires_technician_auth(ctx):
    client, _tech, user, booking, appliance = ctx
    url = _url(booking["id"], appliance["id"])
    assert client.get(url).status_code == 401
    assert client.put(url, json={"results": []}).status_code == 401


def test_customer_token_is_not_a_technician_session(ctx, monkeypatch):
    import app as app_module
    client, _tech, user, booking, appliance = ctx
    monkeypatch.setattr(app_module, "verify_firebase_token", lambda token: None)
    url = _url(booking["id"], appliance["id"])
    assert client.get(url, headers=auth_headers(user["token"])).status_code == 401
    assert client.put(url, json={"results": []}, headers=auth_headers(user["token"])).status_code == 401


def test_other_technician_cannot_read_or_write(ctx, monkeypatch):
    client, _tech, _user, booking, appliance = ctx
    key = kitchen_passport.CHECKLISTS["hob"][0][0]
    assert _put(client, booking["id"], appliance["id"], [{"key": key, "result": "good"}]).status_code == 200
    _make_tech(client, monkeypatch, "tech-intruder-insp")
    assert client.get(_url(booking["id"], appliance["id"]), headers=H).status_code == 404
    assert _put(client, booking["id"], appliance["id"], [{"key": key, "result": "attention"}]).status_code == 404
    assert _count() == 1


def test_unassigned_booking_and_unknown_ids_are_404(ctx):
    client, _tech, _user, booking, appliance = ctx
    _u, unclaimed = _booking(client, "unclaimed-insp@example.com", "9876900043", claim=False)
    key = kitchen_passport.CHECKLISTS["hob"][0][0]
    body = [{"key": key, "result": "good"}]
    assert client.get(_url(unclaimed["id"], appliance["id"]), headers=H).status_code == 404
    assert _put(client, unclaimed["id"], appliance["id"], body).status_code == 404
    assert client.get(_url("NOPE-1", appliance["id"]), headers=H).status_code == 404
    assert client.get(_url(booking["id"], "KAPP-unknown"), headers=H).status_code == 404
    assert _put(client, booking["id"], "KAPP-unknown", body).status_code == 404
    assert _count() == 0


def test_appliance_of_another_customer_is_404_via_my_booking(ctx):
    client, _tech, _user, booking, _appliance = ctx
    _u2, booking2 = _booking(client, "other-insp@example.com", "9876900044")
    foreign = _register_appliance(client, booking2["id"])
    key = kitchen_passport.CHECKLISTS["hob"][0][0]
    assert client.get(_url(booking["id"], foreign["id"]), headers=H).status_code == 404
    assert _put(client, booking["id"], foreign["id"], [{"key": key, "result": "good"}]).status_code == 404
    assert _count() == 0


# ---------------------------------------------------------- closed bookings
@pytest.mark.parametrize("status", ["Completed", "Cancelled"])
def test_closed_booking_readable_but_not_writable(ctx, status):
    client, _tech, _user, booking, appliance = ctx
    key = kitchen_passport.CHECKLISTS["hob"][0][0]
    assert _put(client, booking["id"], appliance["id"], [{"key": key, "result": "attention", "note": "a"}]).status_code == 200
    conn = database.get_db()
    conn.execute("UPDATE bookings SET status = ? WHERE id = ?", (status, booking["id"]))
    conn.commit()
    conn.close()
    got = client.get(_url(booking["id"], appliance["id"]), headers=H)
    assert got.status_code == 200 and got.get_json()["checks"][0]["result"] == "attention"
    resp = _put(client, booking["id"], appliance["id"], [{"key": key, "result": "good"}])
    assert resp.status_code == 409 and resp.get_json()["code"] == "booking_closed"
    assert client.get(_url(booking["id"], appliance["id"]), headers=H).get_json()["checks"][0]["result"] == "attention"


# ------------------------------------------------------------- regression
def test_existing_endpoints_unaffected(ctx):
    """There was no earlier checklist API to preserve (the job screen's
    'checklist' strings were never backed by one); what must keep working is
    everything around it."""
    client, _tech, user, booking, appliance = ctx
    key = kitchen_passport.CHECKLISTS["hob"][0][0]
    assert _put(client, booking["id"], appliance["id"], [{"key": key, "result": "good"}]).status_code == 200
    assert client.patch(f"/api/technician/bookings/{booking['id']}/appliance",
                        json={"brand": "Elica", "modelNumber": "X1"}, headers=H).status_code == 200
    kitchen = client.get(f"/api/technician/bookings/{booking['id']}/kitchen", headers=H).get_json()
    assert [a["id"] for a in kitchen["appliances"]] == [appliance["id"]]
    mine = client.get("/api/kitchen-passport", headers=auth_headers(user["token"])).get_json()
    assert [a["id"] for a in mine["appliances"]] == [appliance["id"]]
    assert client.get(f"/api/bookings/{booking['id']}", headers=auth_headers(user["token"])).status_code == 200
