"""Kitchen Passport V9.7 — technician-assessed health scores.

Scores are computed on read from the saved checklist answers: good = 100,
attention = 40, not_tested excluded, at least 6 of 8 items tested, a flagged
safety item holds the status below Healthy without changing the number, and
the AI / combined scores stay null until Vision AI exists.
"""
import json
from fractions import Fraction

import pytest

import database
import kitchen_health as kh
import kitchen_passport
from conftest import register_and_login, auth_headers, mock_firebase_claims

H = auth_headers("x")
HOB = {"category": "hob", "brand": "Elica", "specs": {"fuel": "gas", "burners": 4}}
HOB_KEYS = [k for k, _ in kitchen_passport.CHECKLISTS["hob"]]
# hob items that are NOT safety items (gas_flow and safety are)
HOB_NON_SAFETY = [k for k in HOB_KEYS if k not in kh.SAFETY_ITEMS]


def _saved(**results):
    return {k: {"result": r, "note": ""} for k, r in results.items()}


def _hob(good=(), attention=(), not_tested=()):
    saved = {}
    for keys, result in ((good, "good"), (attention, "attention"), (not_tested, "not_tested")):
        for k in keys:
            saved[k] = {"result": result, "note": ""}
    return kh.assess_appliance("hob", saved)


def _reference_score(good, attention):
    """Independent half-up average using exact fractions."""
    avg = Fraction(100 * good + 40 * attention, good + attention)
    return int(avg + Fraction(1, 2))


# ---------------------------------------------------------------- pure scoring
def test_all_good_is_100_healthy():
    a = _hob(good=HOB_KEYS)
    assert a["technicianScore"] == 100 and a["status"] == "healthy"
    assert a["coverage"] == {"tested": 8, "total": 8, "label": "8 of 8 checks tested"}


def test_all_attention_is_40_critical():
    a = _hob(attention=HOB_KEYS)
    assert a["technicianScore"] == 40 and a["status"] == "critical"


@pytest.mark.parametrize("attention_count,score,score_status", [
    (0, 100, "healthy"),
    (1, 93, "healthy"),     # 92.5 rounds half up
    (2, 85, "healthy"),     # boundary: 85 is Healthy
    (3, 78, "attention"),   # 77.5 rounds half up
    (4, 70, "attention"),   # boundary: 70 is Attention
    (5, 63, "priority"),    # 62.5
    (6, 55, "priority"),
    (7, 48, "critical"),    # 47.5
    (8, 40, "critical"),
])
def test_eight_item_examples(attention_count, score, score_status):
    attention = HOB_KEYS[:attention_count]
    a = _hob(good=[k for k in HOB_KEYS if k not in attention], attention=attention)
    assert a["technicianScore"] == score
    assert a["scoreStatus"] == score_status


@pytest.mark.parametrize("score,status", [
    (100, "healthy"), (85, "healthy"), (84, "attention"), (70, "attention"),
    (69, "priority"), (50, "priority"), (49, "critical"), (0, "critical"),
])
def test_status_boundaries(score, status):
    assert kh.status_for_score(score) == status


@pytest.mark.parametrize("tested", [6, 7, 8])
def test_every_good_attention_mix_matches_the_reference_average(tested):
    """Sweeps every attention count at each coverage level; the score must
    equal an exact half-up average and the score status must follow the
    documented bands."""
    use = HOB_KEYS[:tested]
    for k in range(tested + 1):
        a = _hob(good=use[k:], attention=use[:k], not_tested=HOB_KEYS[tested:])
        expected = _reference_score(tested - k, k)
        assert a["technicianScore"] == expected, (tested, k)
        assert a["scoreStatus"] == kh.status_for_score(expected), (tested, k)
        assert a["coverage"]["tested"] == tested


# ------------------------------------------------------- not tested / coverage
def test_not_tested_is_excluded_not_zero_and_not_a_pass():
    a = _hob(good=HOB_KEYS[:6], not_tested=HOB_KEYS[6:])
    assert a["technicianScore"] == 100          # not averaged in as 0
    assert a["coverage"]["tested"] == 6
    assert a["notTestedItems"] == [lbl for k, lbl in kitchen_passport.CHECKLISTS["hob"] if k in HOB_KEYS[6:]]
    mixed = _hob(good=HOB_KEYS[:3], attention=HOB_KEYS[3:6], not_tested=HOB_KEYS[6:])
    assert mixed["technicianScore"] == 70       # (3*100 + 3*40) / 6, untested ignored


def test_five_tested_is_not_enough():
    a = _hob(good=HOB_KEYS[:5], not_tested=HOB_KEYS[5:])
    assert a["technicianScore"] is None and a["status"] is None and a["scoreStatus"] is None
    assert a["message"] == "Not enough checks to score."
    assert a["coverage"]["label"] == "5 of 8 checks tested"


def test_unrecorded_items_do_not_count_as_tested():
    a = kh.assess_appliance("hob", _saved(**{k: "good" for k in HOB_KEYS[:5]}))
    assert a["technicianScore"] is None and a["coverage"]["tested"] == 5
    empty = kh.assess_appliance("hob", {})
    assert empty["technicianScore"] is None and empty["coverage"]["tested"] == 0


def test_exactly_six_tested_is_enough():
    a = _hob(good=HOB_KEYS[:6])
    assert a["technicianScore"] == 100 and a["message"] is None


def test_unknown_check_keys_are_ignored():
    saved = _saved(**{k: "good" for k in HOB_KEYS})
    saved["bogus"] = {"result": "attention", "note": ""}
    assert kh.assess_appliance("hob", saved)["technicianScore"] == 100


# ------------------------------------------------------------------- safety
def test_safety_flag_caps_status_but_not_the_score():
    attention = ["safety"]
    a = _hob(good=[k for k in HOB_KEYS if k not in attention], attention=attention)
    assert a["technicianScore"] == 93            # number untouched (92.5 -> 93)
    assert a["scoreStatus"] == "healthy"         # what the number alone says
    assert a["status"] == "attention"            # held below Healthy
    assert a["safetyFlagged"] is True
    assert a["safetyWarning"] == "Safety item flagged"
    assert a["safetyFlaggedItems"] == ["Safety"]
    assert any("held at Attention" in line for line in a["explanation"])


def test_safety_cap_does_not_raise_a_worse_status():
    a = _hob(attention=HOB_KEYS)
    assert a["technicianScore"] == 40 and a["status"] == "critical" and a["safetyFlagged"]


def test_non_safety_attention_does_not_flag_safety():
    a = _hob(good=[k for k in HOB_KEYS if k != "ignition"], attention=["ignition"])
    assert a["safetyFlagged"] is False and a["safetyWarning"] is None and a["status"] == "healthy"


def test_safety_good_does_not_flag():
    assert _hob(good=HOB_KEYS)["safetyFlagged"] is False


def test_gas_flow_counts_as_safety():
    a = _hob(good=[k for k in HOB_KEYS if k != "gas_flow"], attention=["gas_flow"])
    assert a["safetyFlagged"] and a["status"] == "attention"


def test_safety_flag_survives_insufficient_coverage():
    a = _hob(attention=["safety"], good=HOB_KEYS[:2])
    assert a["technicianScore"] is None and a["status"] is None
    assert a["safetyFlagged"] is True


def test_every_category_has_a_safety_item_and_all_are_real_checklist_keys():
    all_keys = {k for items in kitchen_passport.CHECKLISTS.values() for k, _ in items}
    assert kh.SAFETY_ITEMS <= all_keys
    for category, items in kitchen_passport.CHECKLISTS.items():
        assert any(k in kh.SAFETY_ITEMS for k, _ in items), category


# ---------------------------------------------------------- AI / combined
def test_ai_and_combined_are_null_and_labelled_technician_only():
    a = _hob(good=HOB_KEYS)
    assert a["aiScore"] is None and a["combinedScore"] is None
    assert a["ai"] == {"available": False, "reason": "vision_ai_not_available"}
    assert a["scoreBasis"] == "technician_only"
    assert a["scoreBasisLabel"] == "Technician assessment only"
    assert a["disclaimer"] == "Operational guidance, not a certification or a diagnosis of hidden faults."
    assert a["disclaimer"] in a["explanation"]


@pytest.mark.parametrize("tech,ai,expected", [
    (80, 90, 83), (100, 100, 100), (0, 0, 0), (80, 0, 56), (0, 100, 30),
    (85, 55, 76),            # 59.5 + 16.5 = 76.0
    (90, 85, 89),            # 63 + 25.5 = 88.5 -> 89 (half up)
])
def test_combined_formula_is_70_30_when_both_exist(tech, ai, expected):
    assert kh.combined_score(tech, ai) == expected


@pytest.mark.parametrize("tech,ai", [
    (None, 90), (80, None), (None, None), (101, 50), (50, -1), (True, 50), ("80", 50),
])
def test_combined_is_none_unless_both_are_real(tech, ai):
    assert kh.combined_score(tech, ai) is None


# --------------------------------------------------- latest visit selection
def _rows(booking, stamp, **results):
    return [{"booking_id": booking, "check_key": k, "result": r, "note": "", "updated_at": stamp}
            for k, r in results.items()]


def test_latest_usable_visit_wins_over_a_newer_partial_one():
    old = _rows("B1", "2026-01-01T00:00:00Z", **{k: "good" for k in HOB_KEYS})
    new = _rows("B2", "2026-02-01T00:00:00Z", ignition="attention")
    a, booking, at = kh.latest_assessment("hob", old + new)
    assert (booking, at) == ("B1", "2026-01-01T00:00:00Z") and a["technicianScore"] == 100


def test_newer_complete_visit_replaces_older():
    old = _rows("B1", "2026-01-01T00:00:00Z", **{k: "good" for k in HOB_KEYS})
    new = _rows("B2", "2026-02-01T00:00:00Z", **{k: "attention" for k in HOB_KEYS})
    a, booking, _ = kh.latest_assessment("hob", old + new)
    assert booking == "B2" and a["technicianScore"] == 40


def test_newer_partial_safety_flag_is_not_hidden():
    old = _rows("B1", "2026-01-01T00:00:00Z", **{k: "good" for k in HOB_KEYS})
    new = _rows("B2", "2026-02-01T00:00:00Z", safety="attention")
    a, booking, _ = kh.latest_assessment("hob", old + new)
    assert booking == "B1" and a["technicianScore"] == 100
    assert a["safetyFlagged"] is True and a["status"] == "attention"


def test_only_partial_visits_report_coverage_without_a_score():
    a, booking, _ = kh.latest_assessment("hob", _rows("B1", "2026-01-01T00:00:00Z", ignition="good"))
    assert booking == "B1" and a["technicianScore"] is None and a["coverage"]["tested"] == 1


def test_no_rows_at_all():
    a, booking, at = kh.latest_assessment("hob", [])
    assert (booking, at) == (None, None) and a["technicianScore"] is None


# ------------------------------------------------------------------ kitchen
def _entry(i, score_rows=None):
    assessment = kh.latest_assessment("hob", score_rows or [])[0]
    return {"id": f"A{i}", "category": "hob", "brand": "B", "model": "", "assessment": assessment,
            "bookingId": None, "assessedAt": None}


def _scored_entry(i, good, attention):
    saved = {}
    keys = HOB_NON_SAFETY + [k for k in HOB_KEYS if k in kh.SAFETY_ITEMS]
    for k in keys[:good]:
        saved[k] = {"result": "good", "note": ""}
    for k in keys[good:good + attention]:
        saved[k] = {"result": "attention", "note": ""}
    e = _entry(i)
    e["assessment"] = kh.assess_appliance("hob", saved)
    return e


def test_kitchen_average_ignores_unassessed_appliances():
    entries = [_scored_entry(1, 6, 0), _scored_entry(2, 3, 3), _entry(3)]  # 100, 70, unassessed
    k = kh.summarize_kitchen(entries)
    assert k["technicianScore"] == 85            # (100+70)/2, not /3
    assert k["status"] == "healthy"
    assert k["coverage"] == {"assessed": 2, "registered": 3, "label": "2 of 3 appliances assessed"}
    assert k["notAssessedApplianceIds"] == ["A3"]
    assert [a["technicianScore"] for a in k["appliances"]] == [100, 70, None]
    assert k["aiScore"] is None and k["combinedScore"] is None
    assert k["scoreBasisLabel"] == "Technician assessment only"


def test_kitchen_with_nothing_assessed_has_no_score():
    k = kh.summarize_kitchen([_entry(1), _entry(2)])
    assert k["technicianScore"] is None and k["status"] is None
    assert k["message"] == "No appliance has enough checks to score yet."
    assert k["coverage"]["label"] == "0 of 2 appliances assessed"


def test_empty_kitchen():
    k = kh.summarize_kitchen([])
    assert k["technicianScore"] is None and k["registeredCount"] == 0
    assert k["message"] == "No appliances are registered yet."


def test_kitchen_status_held_below_healthy_by_any_safety_flag():
    flagged = _scored_entry(2, 7, 1)
    flagged["assessment"] = kh.assess_appliance("hob", {
        **{k: {"result": "good", "note": ""} for k in HOB_KEYS if k != "safety"},
        "safety": {"result": "attention", "note": ""}})
    k = kh.summarize_kitchen([_scored_entry(1, 6, 0), flagged])
    assert k["technicianScore"] >= 85 and k["scoreStatus"] == "healthy"
    assert k["status"] == "attention" and k["safetyFlagged"] is True
    assert k["safetyFlaggedApplianceIds"] == ["A2"]
    assert "A2" in k["needsAttentionApplianceIds"]


def test_kitchen_rounds_half_up():
    k = kh.summarize_kitchen([_scored_entry(1, 6, 0), _scored_entry(2, 0, 6)])  # 100 and 40
    assert k["technicianScore"] == 70


# ------------------------------------------------------------------- API
def _make_tech(client, monkeypatch, uid):
    mock_firebase_claims(monkeypatch, uid=uid, email=f"{uid}@example.com", email_verified=True)
    tech = client.post("/api/technician/bootstrap",
                       json={"name": "Health Tech", "category": "RasoiSpark", "area": "Test Area"},
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


def _register(client, booking_id, body=HOB):
    resp = client.post(f"/api/technician/bookings/{booking_id}/kitchen/appliances", json=body, headers=H)
    assert resp.status_code == 201, resp.get_json()
    return resp.get_json()


def _save(client, booking_id, appliance_id, results):
    resp = client.put(
        f"/api/technician/bookings/{booking_id}/kitchen/appliances/{appliance_id}/inspection",
        json={"results": results}, headers=H)
    assert resp.status_code == 200, resp.get_json()


def _health_url(booking_id, appliance_id):
    return f"/api/technician/bookings/{booking_id}/kitchen/appliances/{appliance_id}/health"


def _results(**by_key):
    return [{"key": k, "result": r[0], **({"note": r[1]} if len(r) > 1 else {})} for k, r in by_key.items()]


@pytest.fixture()
def ctx(client, monkeypatch):
    _make_tech(client, monkeypatch, "tech-health")
    user, booking = _booking(client, "health-customer@example.com", "9876900050")
    appliance = _register(client, booking["id"])
    return client, user, booking, appliance


def test_appliance_health_api_end_to_end(ctx):
    client, _user, booking, appliance = ctx
    results = _results(**{k: ("good",) for k in HOB_KEYS if k not in ("ignition", "safety")},
                       ignition=("attention", "igniter clicks slowly"),
                       safety=("attention", "loose gas hose"))
    _save(client, booking["id"], appliance["id"], results)
    body = client.get(_health_url(booking["id"], appliance["id"]), headers=H).get_json()
    assert body["technicianScore"] == 85           # (6*100 + 2*40) / 8
    assert body["scoreStatus"] == "healthy" and body["status"] == "attention"
    assert body["safetyFlagged"] is True and body["safetyWarning"] == "Safety item flagged"
    assert body["coverage"]["label"] == "8 of 8 checks tested"
    assert {i["label"]: i["note"] for i in body["flaggedItems"]} == {
        "Ignition": "igniter clicks slowly", "Safety": "loose gas hose"}
    assert body["aiScore"] is None and body["combinedScore"] is None
    assert body["scoreBasisLabel"] == "Technician assessment only"
    assert body["applianceId"] == appliance["id"] and body["bookingId"] == booking["id"]


def test_score_follows_the_saved_answers(ctx):
    client, _user, booking, appliance = ctx
    _save(client, booking["id"], appliance["id"], _results(**{k: ("attention",) for k in HOB_KEYS}))
    url = _health_url(booking["id"], appliance["id"])
    assert client.get(url, headers=H).get_json()["technicianScore"] == 40
    _save(client, booking["id"], appliance["id"], _results(**{k: ("good",) for k in HOB_KEYS}))
    assert client.get(url, headers=H).get_json()["technicianScore"] == 100


def test_insufficient_coverage_via_api(ctx):
    client, _user, booking, appliance = ctx
    _save(client, booking["id"], appliance["id"],
          _results(**{k: ("good",) for k in HOB_KEYS[:5]}, **{k: ("not_tested",) for k in HOB_KEYS[5:]}))
    body = client.get(_health_url(booking["id"], appliance["id"]), headers=H).get_json()
    assert body["technicianScore"] is None and body["status"] is None
    assert body["message"] == "Not enough checks to score."
    assert body["coverage"]["label"] == "5 of 8 checks tested"


def test_fresh_appliance_has_no_score(ctx):
    client, _user, booking, appliance = ctx
    body = client.get(_health_url(booking["id"], appliance["id"]), headers=H).get_json()
    assert body["technicianScore"] is None and body["coverage"]["tested"] == 0


def test_nothing_is_written_by_reading_health(ctx):
    client, _user, booking, appliance = ctx
    _save(client, booking["id"], appliance["id"], _results(**{k: ("good",) for k in HOB_KEYS}))

    def counts():
        conn = database.get_db()
        out = [conn.execute(f"SELECT COUNT(*) AS n FROM {t}").fetchone()["n"]
               for t in ("appliance_health", "kitchen_inspection_checks", "kitchen_appliances")]
        conn.close()
        return out
    before = counts()
    client.get(_health_url(booking["id"], appliance["id"]), headers=H)
    client.get(f"/api/technician/bookings/{booking['id']}/kitchen/health", headers=H)
    assert counts() == before and before[0] == 0   # legacy appliance_health untouched


def test_kitchen_health_partial_coverage_via_api(ctx):
    client, user, booking, appliance = ctx
    other = _register(client, booking["id"], {"category": "ro_purifier", "brand": "Kent",
                      "specs": {"technology": "ro", "mounting": "wall", "tank_litres": 8}})
    _save(client, booking["id"], appliance["id"], _results(**{k: ("good",) for k in HOB_KEYS}))
    body = client.get(f"/api/technician/bookings/{booking['id']}/kitchen/health", headers=H).get_json()
    assert body["technicianScore"] == 100 and body["status"] == "healthy"
    assert body["coverage"]["label"] == "1 of 2 appliances assessed"
    assert body["notAssessedApplianceIds"] == [other["id"]]
    by_id = {a["id"]: a for a in body["appliances"]}
    assert by_id[appliance["id"]]["technicianScore"] == 100
    assert by_id[other["id"]]["technicianScore"] is None
    assert by_id[other["id"]]["message"] == "Not enough checks to score."
    assert body["aiScore"] is None and body["combinedScore"] is None


def test_kitchen_summary_never_exposes_free_text_notes(ctx):
    client, _user, booking, appliance = ctx
    _save(client, booking["id"], appliance["id"], _results(
        **{k: ("good",) for k in HOB_KEYS if k != "ignition"}, ignition=("attention", "SECRET-NOTE-TEXT")))
    own = client.get(f"/api/technician/bookings/{booking['id']}/kitchen/health", headers=H).get_json()
    assert "SECRET-NOTE-TEXT" not in json.dumps(own)
    assert own["appliances"][0]["flaggedItems"] == ["Ignition"]


def test_customer_endpoint_is_own_kitchen_only(ctx):
    client, user, booking, appliance = ctx
    _save(client, booking["id"], appliance["id"], _results(**{k: ("good",) for k in HOB_KEYS}))
    mine = client.get("/api/kitchen-passport/health", headers=auth_headers(user["token"])).get_json()
    assert mine["technicianScore"] == 100 and mine["coverage"]["label"] == "1 of 1 appliances assessed"
    assert "SECRET" not in json.dumps(mine)
    other = register_and_login(client, email="health-other@example.com", phone="9876900051")
    theirs = client.get("/api/kitchen-passport/health", headers=auth_headers(other["token"])).get_json()
    assert theirs["registeredCount"] == 0 and theirs["technicianScore"] is None
    assert theirs["appliances"] == []


# ------------------------------------------------- authentication / ownership
def test_endpoints_require_authentication(ctx):
    client, _user, booking, appliance = ctx
    assert client.get(_health_url(booking["id"], appliance["id"])).status_code == 401
    assert client.get(f"/api/technician/bookings/{booking['id']}/kitchen/health").status_code == 401
    assert client.get("/api/kitchen-passport/health").status_code == 401


def test_customer_token_is_not_a_technician_session(ctx, monkeypatch):
    import app as app_module
    client, user, booking, appliance = ctx
    monkeypatch.setattr(app_module, "verify_firebase_token", lambda token: None)
    t = auth_headers(user["token"])
    assert client.get(_health_url(booking["id"], appliance["id"]), headers=t).status_code == 401
    assert client.get(f"/api/technician/bookings/{booking['id']}/kitchen/health", headers=t).status_code == 401


def test_other_technician_gets_404_everywhere(ctx, monkeypatch):
    client, _user, booking, appliance = ctx
    _save(client, booking["id"], appliance["id"], _results(**{k: ("good",) for k in HOB_KEYS}))
    _make_tech(client, monkeypatch, "tech-health-intruder")
    assert client.get(_health_url(booking["id"], appliance["id"]), headers=H).status_code == 404
    assert client.get(f"/api/technician/bookings/{booking['id']}/kitchen/health", headers=H).status_code == 404


def test_unassigned_unknown_and_foreign_appliance_are_404(ctx):
    client, _user, booking, appliance = ctx
    _u, unclaimed = _booking(client, "health-unclaimed@example.com", "9876900052", claim=False)
    assert client.get(_health_url(unclaimed["id"], appliance["id"]), headers=H).status_code == 404
    assert client.get(f"/api/technician/bookings/{unclaimed['id']}/kitchen/health", headers=H).status_code == 404
    assert client.get(_health_url("NOPE-1", appliance["id"]), headers=H).status_code == 404
    assert client.get(_health_url(booking["id"], "KAPP-unknown"), headers=H).status_code == 404
    _u2, booking2 = _booking(client, "health-foreign@example.com", "9876900053")
    foreign = _register(client, booking2["id"])
    assert client.get(_health_url(booking["id"], foreign["id"]), headers=H).status_code == 404


@pytest.mark.parametrize("status", ["Completed", "Cancelled"])
def test_health_is_readable_on_closed_bookings(ctx, status):
    client, _user, booking, appliance = ctx
    _save(client, booking["id"], appliance["id"], _results(**{k: ("good",) for k in HOB_KEYS}))
    conn = database.get_db()
    conn.execute("UPDATE bookings SET status = ? WHERE id = ?", (status, booking["id"]))
    conn.commit()
    conn.close()
    assert client.get(_health_url(booking["id"], appliance["id"]), headers=H).get_json()["technicianScore"] == 100
    assert client.get(f"/api/technician/bookings/{booking['id']}/kitchen/health",
                      headers=H).status_code == 200


def test_new_technician_sees_earlier_visit_score_without_its_notes(client, monkeypatch):
    """A second technician on a later booking for the same customer sees the
    kitchen score built from the earlier visit, but only flagged labels."""
    _make_tech(client, monkeypatch, "tech-first")
    user, booking1 = _booking(client, "revisit@example.com", "9876900054")
    appliance = _register(client, booking1["id"])
    _save(client, booking1["id"], appliance["id"], _results(
        **{k: ("good",) for k in HOB_KEYS if k != "ignition"}, ignition=("attention", "PRIVATE-NOTE")))
    _make_tech(client, monkeypatch, "tech-second")
    service_id = client.get("/api/services").get_json()[0]["id"]
    booking2 = client.post("/api/bookings", json={"service_id": service_id},
                           headers=auth_headers(user["token"])).get_json()
    assert client.patch(f"/api/bookings/{booking2['id']}/claim", json={}, headers=H).status_code == 200
    body = client.get(f"/api/technician/bookings/{booking2['id']}/kitchen/health", headers=H).get_json()
    assert body["technicianScore"] == 93 and body["appliances"][0]["assessedAt"]
    text = json.dumps(body)
    assert "PRIVATE-NOTE" not in text
    assert booking1["id"] not in text    # the earlier visit's booking id is not disclosed


KITCHEN_KEYS = {
    "ai", "aiScore", "appliances", "assessedCount", "combinedScore", "coverage", "disclaimer",
    "explanation", "message", "needsAttentionApplianceIds", "notAssessedApplianceIds",
    "registeredCount", "safetyFlagged", "safetyFlaggedApplianceIds", "safetyWarning",
    "scoreBasis", "scoreBasisLabel", "scoreStatus", "status", "statusLabel", "technicianScore",
}
KITCHEN_APPLIANCE_KEYS = {
    "assessedAt", "brand", "category", "coverage", "flaggedItems", "id", "message", "model",
    "safetyFlagged", "safetyFlaggedItems", "scoreStatus", "status", "statusLabel", "technicianScore",
}


def test_kitchen_responses_expose_only_whitelisted_fields(ctx):
    """Guards against leaking customer, booking or technician data: if a new
    field is added to a kitchen summary this fails until it is reviewed."""
    client, user, booking, appliance = ctx
    _save(client, booking["id"], appliance["id"], _results(**{k: ("good",) for k in HOB_KEYS}))
    tech_view = client.get(f"/api/technician/bookings/{booking['id']}/kitchen/health", headers=H).get_json()
    own_view = client.get("/api/kitchen-passport/health", headers=auth_headers(user["token"])).get_json()
    for body in (tech_view, own_view):
        assert set(body) == KITCHEN_KEYS
        assert set(body["appliances"][0]) == KITCHEN_APPLIANCE_KEYS
        text = json.dumps(body)
        assert booking["id"] not in text
        for needle in (user["token"], "health-customer@example.com", "9876900050", "tech-health"):
            assert needle not in text


def test_kitchen_safety_flag_is_visible_when_the_appliance_is_unscored(ctx):
    client, _user, booking, appliance = ctx
    _save(client, booking["id"], appliance["id"], _results(safety=("attention", "private")))
    body = client.get(f"/api/technician/bookings/{booking['id']}/kitchen/health", headers=H).get_json()
    assert body["technicianScore"] is None and body["status"] is None
    assert body["safetyFlagged"] is True and body["safetyWarning"] == "Safety item flagged"
    assert body["safetyFlaggedApplianceIds"] == [appliance["id"]]
    assert body["appliances"][0]["safetyFlaggedItems"] == ["Safety"]


def test_kitchen_status_held_below_healthy_via_api(ctx):
    client, _user, booking, appliance = ctx
    _save(client, booking["id"], appliance["id"], _results(
        **{k: ("good",) for k in HOB_KEYS if k != "gas_flow"}, gas_flow=("attention",)))
    body = client.get(f"/api/technician/bookings/{booking['id']}/kitchen/health", headers=H).get_json()
    assert body["technicianScore"] == 93 and body["scoreStatus"] == "healthy"
    assert body["status"] == "attention" and body["safetyFlagged"] is True


def test_water_leakage_is_not_a_safety_override():
    """Agreed scope: only Safety, Electrical safety, Electrical and safety and
    Gas flow hold the status below Healthy in this slice."""
    assert kh.SAFETY_ITEMS == {"safety", "electrical_safety", "electrical_and_safety", "gas_flow"}
    keys = [k for k, _ in kitchen_passport.CHECKLISTS["ro_purifier"]]
    a = kh.assess_appliance("ro_purifier", {
        **{k: {"result": "good", "note": ""} for k in keys if k != "water_leakage"},
        "water_leakage": {"result": "attention", "note": ""}})
    assert a["safetyFlagged"] is False and a["scoreStatus"] == "healthy" and a["status"] == "healthy"
