"""Stage D — the customer-facing Kitchen Passport overview. Scoping to the
signed-in customer, honest handling of missing data, score/guidance display,
history from persisted visits, and that only technician-accepted AI feeds a
customer-visible score. Fake provider, synthetic images."""
import json

import pytest

import vision_provider as vp

import kitchen_health
from conftest import auth_headers, register_and_login
from test_vision_jobs import H, HOB_KEYS, _booking, _register, _vision_state, ctx  # noqa: F401
from test_vision_review import (RESIDUE, _analyse, _finding, _reply, _review, _save_checks)  # noqa: F401

URL = "/api/kitchen-passport/overview"

@pytest.fixture(autouse=True)
def _provider_is_not_simulated(monkeypatch):
    """These tests exercise score integration, which only real (non-simulated)
    providers may feed. FakeProvider is simulated by default, so model a real
    provider here; tests/test_vision_simulated.py covers the simulated case."""
    monkeypatch.setattr(vp.FakeProvider, "simulated", False)
    monkeypatch.setattr(vp.FakeProvider, "name", "stub-real")
    monkeypatch.setattr(vp.FakeProvider, "model", "stub-real-v1")



def _get(client, user):
    resp = client.get(URL, headers=auth_headers(user["token"]))
    assert resp.status_code == 200, resp.get_json()
    return resp.get_json()


def _second_visit(client, user):
    """Another booking by the same customer, claimed by the same technician."""
    service_id = client.get("/api/services").get_json()[1]["id"]
    booking = client.post("/api/bookings", json={"service_id": service_id},
                          headers=auth_headers(user["token"])).get_json()
    assert client.patch(f"/api/bookings/{booking['id']}/claim", json={}, headers=H).status_code == 200
    return booking


# -------------------------------------------------------------- authorization
def test_requires_a_customer_token(ctx):
    client = ctx[0]
    assert client.get(URL).status_code == 401
    assert client.get(URL, headers=auth_headers("not-a-token")).status_code == 401


def test_a_customer_sees_only_their_own_kitchen(ctx):
    client, _t, user, booking, appliance, _p = ctx
    _save_checks(client, booking, appliance, safety="attention")
    other = register_and_login(client, email="other-cust@example.com", phone="9876900099")
    mine, theirs = _get(client, user), _get(client, other)
    assert [a["id"] for a in mine["appliances"]] == [appliance["id"]]
    assert theirs["appliances"] == [] and theirs["kitchen"]["registeredCount"] == 0
    assert theirs["needsAttention"] == [] and theirs["kitchen"]["nextService"] is None
    text = json.dumps(theirs)
    assert appliance["id"] not in text and booking["id"] not in text


def test_history_never_includes_another_customers_booking(ctx):
    client, _t, user, booking, appliance, _p = ctx
    _save_checks(client, booking, appliance)
    # Another customer's booking id carrying checks for MY appliance (e.g. stale or hostile data).
    other_user, other_booking = _booking(client, "hist-other@example.com", "9876900098")
    import database
    conn = database.get_db()
    conn.execute(
        "INSERT INTO kitchen_inspection_checks (id, appliance_id, booking_id, technician_id, check_key, result, note, "
        "updated_at) SELECT 'KIC-x', ?, ?, technician_id, 'ignition', 'attention', 'SECRET-OTHER', ? "
        "FROM bookings WHERE id = ?",
        (appliance["id"], other_booking["id"], database.now(), booking["id"]))
    conn.commit()
    conn.close()
    text = json.dumps(_get(client, user))
    assert other_booking["id"] not in text and "SECRET-OTHER" not in text
    assert len(_get(client, user)["appliances"][0]["history"]) == 1


# ---------------------------------------------------------------- missing data
def test_empty_kitchen_is_reported_honestly(ctx):
    client = ctx[0]
    lone = register_and_login(client, email="lone@example.com", phone="9876900097")
    body = _get(client, lone)
    assert body["appliances"] == []
    k = body["kitchen"]
    assert k["score"] is None and k["status"] is None and k["nextService"] is None
    assert k["registeredCount"] == 0 and k["assessedCount"] == 0


def test_registered_but_unchecked_appliance_has_no_score_guidance_or_history(ctx):
    client, _t, user, _b, appliance, _p = ctx
    body = _get(client, user)
    a = body["appliances"][0]
    assert a["id"] == appliance["id"]
    assert a["score"] is None and a["status"] is None and a["notEnoughChecks"] is True
    assert a["nextService"] is None and a["history"] == [] and a["attentionItems"] == []
    assert body["kitchen"]["score"] is None and body["kitchen"]["nextService"] is None
    assert body["needsAttention"] == []


def test_too_few_checks_gives_no_score(ctx):
    client, _t, user, booking, appliance, _p = ctx
    client.put(f"/api/technician/bookings/{booking['id']}/kitchen/appliances/{appliance['id']}/inspection",
               json={"results": [{"key": k, "result": "good"} for k in HOB_KEYS[:5]]}, headers=H)
    a = _get(client, user)["appliances"][0]
    assert a["score"] is None and a["notEnoughChecks"] is True and a["nextService"] is None
    assert len(a["history"]) == 1 and a["history"][0]["score"] is None   # visit shown, never a made-up score


# ------------------------------------------------------- score and guidance
@pytest.mark.parametrize("overrides,score,status,urgency,days", [
    ({}, 100, "healthy", "routine", 35),
    ({"ignition": "attention", "pan_support": "attention", "glass_surface": "attention"}, 78, "attention", "soon", 21),
    ({k: "attention" for k in ["ignition", "pan_support", "glass_surface", "knobs_and_controls", "burner_performance"]},
     63, "priority", "priority", 7),
    ({k: "attention" for k in HOB_KEYS[:7]}, 48, "critical", "urgent", 0),
])
def test_scores_status_and_guidance_follow_the_existing_thresholds(ctx, overrides, score, status, urgency, days):
    client, _t, user, booking, appliance, _p = ctx
    _save_checks(client, booking, appliance, **overrides)
    body = _get(client, user)
    a = body["appliances"][0]
    assert (a["score"], a["status"]) == (score, status)
    assert a["nextService"]["urgency"] == urgency and a["nextService"]["estimatedDays"] == days
    assert body["kitchen"]["score"] == score and body["kitchen"]["nextService"]["estimatedDays"] == days
    assert a["basis"] == "technician_only"


def test_a_flagged_safety_item_raises_the_guidance_to_priority_and_is_listed(ctx):
    client, _t, user, booking, appliance, _p = ctx
    _save_checks(client, booking, appliance, safety="attention")
    body = _get(client, user)
    a = body["appliances"][0]
    assert a["score"] == 93 and a["status"] == "attention"          # technician score unchanged, status held
    assert a["safetyFlagged"] is True and a["attentionItems"] == ["Safety"]
    assert a["nextService"]["urgency"] == "priority" and a["nextService"]["estimatedDays"] == 7
    assert body["needsAttention"] == [appliance["id"]] and body["kitchen"]["safetyFlagged"] is True


def test_kitchen_next_service_is_the_most_urgent_appliance(ctx):
    client, _t, user, booking, appliance, _p = ctx
    second = _register(client, booking["id"], {"category": "hob", "brand": "Faber",
                       "specs": {"fuel": "gas", "burners": 2}, "serialNumber": "S-2"})
    _save_checks(client, booking, appliance)                                          # healthy
    _save_checks(client, booking, second, **{k: "attention" for k in HOB_KEYS[:5]})   # priority
    k = _get(client, user)["kitchen"]
    assert k["nextService"]["applianceId"] == second["id"] and k["nextService"]["estimatedDays"] == 7
    assert k["assessedCount"] == 2 and k["score"] == 82        # average of 100 and 63, unchanged formula


def test_service_guidance_pure_function():
    assert kitchen_health.service_guidance(None, False) is None
    assert kitchen_health.service_guidance("healthy", False)["estimatedDays"] == 35
    assert kitchen_health.service_guidance("attention", True)["urgency"] == "priority"
    assert kitchen_health.service_guidance("critical", True)["urgency"] == "urgent"


# --------------------------------------------------------------------- history
def test_history_lists_real_visits_newest_first_without_notes_or_ids(ctx):
    client, _t, user, booking, appliance, _p = ctx
    client.put(f"/api/technician/bookings/{booking['id']}/kitchen/appliances/{appliance['id']}/inspection",
               json={"results": [{"key": k, "result": "good" if k != "ignition" else "attention",
                                  **({"note": "PRIVATE-NOTE"} if k == "ignition" else {})}
                                 for k in HOB_KEYS]}, headers=H)
    second = _second_visit(client, user)
    _save_checks(client, second, appliance)
    body = _get(client, user)
    history = body["appliances"][0]["history"]
    assert len(history) == 2
    assert [h["score"] for h in history] == [100, 93] or [h["score"] for h in history] == [93, 100]
    assert history[0]["date"] >= history[1]["date"]
    assert all(h["serviceName"] and h["bookingStatus"] for h in history)
    text = json.dumps(body)
    for needle in ("PRIVATE-NOTE", booking["id"], second["id"], "tech-ai", user["token"]):
        assert needle not in text


def test_response_exposes_only_whitelisted_fields(ctx):
    client, _t, user, booking, appliance, provider = ctx
    _save_checks(client, booking, appliance, ignition="attention")
    job = _analyse(client, booking, appliance, provider, _reply(_finding(RESIDUE, "low")))
    _review(client, booking, appliance, job["id"], {"decision": "accept"})
    body = _get(client, user)
    assert set(body) == {"kitchen", "appliances", "needsAttention"}
    assert set(body["kitchen"]) == {"score", "status", "registeredCount", "assessedCount", "safetyFlagged",
                                    "basis", "nextService"}
    assert set(body["appliances"][0]) == {
        "id", "category", "brand", "model", "score", "status", "checksTested", "checksTotal", "notEnoughChecks",
        "safetyFlagged", "attentionItems", "basis", "assessedAt", "nextService", "history"}
    assert set(body["appliances"][0]["history"][0]) == {
        "date", "serviceName", "bookingStatus", "score", "status", "safetyFlagged"}
    assert set(body["appliances"][0]["nextService"]) == {"urgency", "estimatedDays"}
    text = json.dumps(body)
    for forbidden in ("aiScore", "inspectionId", "KAI-", "KAR-", "findings", "evidence", "technicianScore",
                      "serialNumber", "firebase"):
        assert forbidden not in text


# -------------------------------------------------------------------- AI gating
def test_unreviewed_or_rejected_ai_never_changes_a_customer_visible_score(ctx):
    client, _t, user, booking, appliance, provider = ctx
    _save_checks(client, booking, appliance)
    before = _get(client, user)
    job = _analyse(client, booking, appliance, provider, _reply(_finding(RESIDUE, "high")))
    assert _get(client, user) == before                       # analysed but unreviewed
    _review(client, booking, appliance, job["id"], {"decision": "reject"})
    assert _get(client, user) == before                       # rejected


def test_accepted_ai_is_blended_and_labelled_but_its_internals_are_not_exposed(ctx):
    client, _t, user, booking, appliance, provider = ctx
    _save_checks(client, booking, appliance)
    job = _analyse(client, booking, appliance, provider, _reply(_finding(RESIDUE, "low")))   # AI 95
    _review(client, booking, appliance, job["id"], {"decision": "accept"})
    body = _get(client, user)
    a = body["appliances"][0]
    assert a["score"] == 99 and a["basis"] == "technician_plus_photo_review"
    assert body["kitchen"]["score"] == 100 and body["kitchen"]["basis"] == "technician_only"
    _review(client, booking, appliance, job["id"], {"decision": "reject"})
    assert _get(client, user)["appliances"][0]["score"] == 100


def test_ai_can_not_raise_the_customer_status_above_the_technicians(ctx):
    client, _t, user, booking, appliance, provider = ctx
    _save_checks(client, booking, appliance, ignition="attention", burner_performance="attention",
                 pan_support="attention")                     # technician 78 -> attention
    job = _analyse(client, booking, appliance, provider, _reply())
    _review(client, booking, appliance, job["id"], {"decision": "accept"})
    a = _get(client, user)["appliances"][0]
    assert a["score"] == 85 and a["status"] == "attention"
