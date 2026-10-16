"""Vision AI Stage C — technician review persistence and its (conditional)
effect on the combined health score. Fake provider and synthetic images only."""
import json

import pytest

import ai_review
import database
import kitchen_health
import vision_guardrails as vg
import vision_provider as vp
from conftest import auth_headers, mock_firebase_claims
from test_vision_jobs import (H, HOB_KEYS, _booking, _images, _make_tech, _register, _setrow,  # noqa: F401
                              _submit, _url, _vision_state, ctx)  # fixtures re-exported for pytest

RESIDUE, BURN = "burner_residue_visible", "burn_marks_visible"
EVIDENCE = "Residue and discolouration are visible on the surface in the first photo."


def _finding(code, severity="medium", confidence=0.9):
    return {"code": code, "severity": severity, "confidence": confidence, "evidence": EVIDENCE, "photoIndexes": [0]}


def _reply(*findings, visibility="adequate"):
    return {"visibility": visibility, "findings": list(findings)}


def _analyse(client, booking, appliance, provider, reply=None, base=0):
    if reply is not None:
        provider.script.append(reply)
    resp = _submit(client, booking["id"], appliance["id"], images=_images(1, base=base))
    assert resp.status_code in (200, 202), resp.get_json()
    job = resp.get_json()["inspection"]
    got = client.get(_url(booking["id"], appliance["id"], job["id"]), headers=H).get_json()["inspection"]
    assert got["status"] == "completed", got
    return got


def _review_url(booking, appliance, inspection_id):
    return _url(booking["id"], appliance["id"], inspection_id) + "/review"


_n = [0]


def _review(client, booking, appliance, inspection_id, body, headers=H, rid=None):
    _n[0] += 1
    body = {"clientRequestId": rid or f"req-review-{_n[0]:06d}", **body}
    return client.post(_review_url(booking, appliance, inspection_id), json=body, headers=headers)


def _save_checks(client, booking, appliance, **overrides):
    results = [{"key": k, "result": overrides.get(k, "good")} for k in HOB_KEYS]
    resp = client.put(f"/api/technician/bookings/{booking['id']}/kitchen/appliances/{appliance['id']}/inspection",
                      json={"results": results}, headers=H)
    assert resp.status_code == 200, resp.get_json()


def _health(client, booking, appliance):
    return client.get(f"/api/technician/bookings/{booking['id']}/kitchen/appliances/{appliance['id']}/health",
                      headers=H).get_json()


def _stored(inspection_id):
    conn = database.get_db()
    row = conn.execute("SELECT * FROM kitchen_ai_inspections WHERE id = ?", (inspection_id,)).fetchone()
    conn.close()
    return dict(row)


def _reviews():
    conn = database.get_db()
    rows = [dict(r) for r in conn.execute("SELECT * FROM kitchen_ai_reviews ORDER BY created_at, revision").fetchall()]
    conn.close()
    return rows


TWO = _reply(_finding(RESIDUE, "medium"), _finding(BURN, "high"))  # score 100-15-30 = 55


# ------------------------------------------------------------------ access
def test_review_requires_technician_auth(ctx, monkeypatch):
    import app as app_module
    client, _t, user, booking, appliance, provider = ctx
    job = _analyse(client, booking, appliance, provider)
    url = _review_url(booking, appliance, job["id"])
    body = {"decision": "accept", "clientRequestId": "req-noauth-1"}
    assert client.post(url, json=body).status_code == 401
    monkeypatch.setattr(app_module, "verify_firebase_token", lambda token: None)
    assert client.post(url, json=body, headers=auth_headers(user["token"])).status_code == 401
    assert _reviews() == []


def test_other_technician_and_foreign_ids_get_404_and_write_nothing(ctx, monkeypatch):
    client, _t, _u, booking, appliance, provider = ctx
    job = _analyse(client, booking, appliance, provider)
    _x, booking2 = _booking(client, "rv-other@example.com", "9876900071")
    foreign = _register(client, booking2["id"])
    assert _review(client, booking, foreign, job["id"], {"decision": "accept"}).status_code == 404
    assert _review(client, booking2, appliance, job["id"], {"decision": "accept"}).status_code == 404
    assert _review(client, booking, appliance, "KAI-nope", {"decision": "accept"}).status_code == 404
    _make_tech(client, monkeypatch, "tech-rv-intruder")
    assert _review(client, booking, appliance, job["id"], {"decision": "accept"}).status_code == 404
    assert _reviews() == []


def test_a_reassigned_technician_cannot_review_someone_elses_analysis(ctx, monkeypatch):
    client, tech, _u, booking, appliance, provider = ctx
    job = _analyse(client, booking, appliance, provider)
    other = _make_tech(client, monkeypatch, "tech-rv-second")
    conn = database.get_db()
    conn.execute("UPDATE bookings SET technician_id = ? WHERE id = ?", (other["id"], booking["id"]))
    conn.commit()
    conn.close()
    assert _review(client, booking, appliance, job["id"], {"decision": "accept"}).status_code == 404
    assert _reviews() == []


def test_closed_booking_refuses_review(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    job = _analyse(client, booking, appliance, provider)
    conn = database.get_db()
    conn.execute("UPDATE bookings SET status = 'Completed' WHERE id = ?", (booking["id"],))
    conn.commit()
    conn.close()
    resp = _review(client, booking, appliance, job["id"], {"decision": "accept"})
    assert resp.status_code == 409 and resp.get_json()["code"] == "booking_closed"
    assert _reviews() == []


# ------------------------------------------------------------- persistence
def test_accept_is_stored_separately_and_the_ai_result_is_untouched(ctx):
    client, tech, _u, booking, appliance, provider = ctx
    job = _analyse(client, booking, appliance, provider, TWO)
    before = _stored(job["id"])
    resp = _review(client, booking, appliance, job["id"], {"decision": "accept", "reason": "Matches what I saw."})
    assert resp.status_code == 201
    review = resp.get_json()["review"]
    assert review["decision"] == "accept" and review["revision"] == 1
    assert review["technicianId"] == tech["id"] and review["reviewedAt"]
    assert review["reviewedScore"] == 55
    assert {f["decision"] for f in review["findings"]} == {"confirm"}
    after = _stored(job["id"])
    assert after == before                                   # result_json, score, timestamps all unchanged
    assert json.loads(after["result_json"])["accepted"] is False   # the stored evidence still says "not accepted"
    rows = _reviews()
    assert len(rows) == 1 and rows[0]["result_sha256"] == ai_review.result_hash(before["result_json"])


def test_detail_endpoint_reports_the_review_without_altering_the_stored_result(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    job = _analyse(client, booking, appliance, provider, TWO)
    assert job["review"] is None and job["result"]["accepted"] is False
    _review(client, booking, appliance, job["id"], {"decision": "accept"})
    got = client.get(_url(booking["id"], appliance["id"], job["id"]), headers=H).get_json()["inspection"]
    assert got["review"]["decision"] == "accept"
    assert got["result"]["accepted"] is True and got["result"]["usedInHealthScore"] is True
    assert json.loads(_stored(job["id"])["result_json"])["accepted"] is False


def test_review_is_idempotent_on_client_request_id(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    job = _analyse(client, booking, appliance, provider)
    first = _review(client, booking, appliance, job["id"], {"decision": "accept"}, rid="req-idem-0001")
    again = _review(client, booking, appliance, job["id"], {"decision": "accept"}, rid="req-idem-0001")
    assert first.status_code == 201 and again.status_code == 200
    assert first.get_json() == again.get_json()
    assert len(_reviews()) == 1
    # Same id, different decision body: still the original, nothing new written.
    third = _review(client, booking, appliance, job["id"], {"decision": "reject"}, rid="req-idem-0001")
    assert third.status_code == 200 and third.get_json()["review"]["decision"] == "accept"
    assert len(_reviews()) == 1


def test_request_id_cannot_be_reused_for_another_analysis(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    a = _analyse(client, booking, appliance, provider, base=0)
    b = _analyse(client, booking, appliance, provider, base=10)
    assert _review(client, booking, appliance, a["id"], {"decision": "accept"}, rid="req-reuse-001").status_code == 201
    resp = _review(client, booking, appliance, b["id"], {"decision": "accept"}, rid="req-reuse-001")
    assert resp.status_code == 409 and resp.get_json()["code"] == "request_id_reused"


@pytest.mark.parametrize("rid", [None, "", "short", "has space here!", 123])
def test_client_request_id_is_required(ctx, rid):
    client, _t, _u, booking, appliance, provider = ctx
    job = _analyse(client, booking, appliance, provider)
    body = {"decision": "accept"}
    if rid is not None:
        body["clientRequestId"] = rid
    resp = client.post(_review_url(booking, appliance, job["id"]), json=body, headers=H)
    assert resp.status_code == 400 and _reviews() == []


def test_changing_your_mind_appends_a_revision(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    job = _analyse(client, booking, appliance, provider)
    _review(client, booking, appliance, job["id"], {"decision": "accept"})
    second = _review(client, booking, appliance, job["id"], {"decision": "reject", "reason": "Wrong appliance."})
    assert second.get_json()["review"]["revision"] == 2
    assert [r["decision"] for r in _reviews()] == ["accept", "reject"]      # nothing was updated or deleted
    got = client.get(_url(booking["id"], appliance["id"], job["id"]), headers=H).get_json()["inspection"]
    assert got["review"]["decision"] == "reject" and got["result"]["accepted"] is False


def test_only_completed_results_can_be_reviewed(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    provider.script.append(vp.ProviderPermanentError("nope"))
    resp = _submit(client, booking["id"], appliance["id"])
    job = resp.get_json()["inspection"]
    assert client.get(_url(booking["id"], appliance["id"], job["id"]), headers=H).get_json()["inspection"]["status"] == "failed"
    out = _review(client, booking, appliance, job["id"], {"decision": "accept"})
    assert out.status_code == 409 and out.get_json()["code"] == "not_reviewable"
    assert _reviews() == []


def test_unclear_photos_can_be_rejected_but_not_accepted(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    job = _analyse(client, booking, appliance, provider, _reply(visibility="insufficient"))
    assert job["result"]["conditionScore"] is None
    refused = _review(client, booking, appliance, job["id"], {"decision": "accept"})
    assert refused.status_code == 409 and refused.get_json()["code"] == "nothing_to_accept"
    assert _review(client, booking, appliance, job["id"], {"decision": "reject"}).status_code == 201


# -------------------------------------------------------------- edit rules
def _edit(findings, **extra):
    return {"decision": "edit", "findings": findings, **extra}


def test_edit_recomputes_the_score_on_the_server_from_confirmed_findings(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    job = _analyse(client, booking, appliance, provider, TWO)
    body = _edit([{"code": RESIDUE, "decision": "confirm", "severity": "low", "note": "Light film only."},
                  {"code": BURN, "decision": "reject"}], reviewedScore=100, conditionScore=100)
    resp = _review(client, booking, appliance, job["id"], body)
    assert resp.status_code == 201
    review = resp.get_json()["review"]
    assert review["reviewedScore"] == 95                      # only the confirmed low finding: 100 - 5
    by_code = {f["code"]: f for f in review["findings"]}
    assert by_code[RESIDUE]["severity"] == "low" and by_code[RESIDUE]["note"] == "Light film only."
    assert by_code[BURN]["decision"] == "reject"
    stored = json.loads(_stored(job["id"])["result_json"])
    assert {f["code"]: f["severity"] for f in stored["findings"]} == {RESIDUE: "medium", BURN: "high"}


@pytest.mark.parametrize("findings,code", [
    ([{"code": RESIDUE, "decision": "confirm"}], "incomplete_review"),
    ([{"code": RESIDUE, "decision": "confirm"}, {"code": BURN, "decision": "confirm"},
      {"code": RESIDUE, "decision": "confirm"}], "duplicate_finding"),
    ([{"code": RESIDUE, "decision": "confirm"}, {"code": "gas_leak_inside", "decision": "confirm"}], "unknown_finding"),
    ([{"code": RESIDUE, "decision": "confirm", "severity": "catastrophic"}, {"code": BURN, "decision": "confirm"}],
     "invalid_review"),
    ([{"code": RESIDUE, "decision": "maybe"}, {"code": BURN, "decision": "confirm"}], "invalid_review"),
    ([{"code": RESIDUE, "decision": "reject"}, {"code": BURN, "decision": "reject"}], "invalid_review"),
    ([{"code": RESIDUE, "decision": "confirm", "note": "Compressor failure suspected"},
      {"code": BURN, "decision": "confirm"}], "note_rejected"),
    ([{"code": RESIDUE, "decision": "confirm", "note": "see http://evil.example/x"},
      {"code": BURN, "decision": "confirm"}], "note_rejected"),
    ([{"code": RESIDUE, "decision": "confirm", "note": "x" * 301}, {"code": BURN, "decision": "confirm"}],
     "invalid_review"),
    ("nope", "invalid_review"),
])
def test_invalid_edits_are_rejected_and_write_nothing(ctx, findings, code):
    client, _t, _u, booking, appliance, provider = ctx
    job = _analyse(client, booking, appliance, provider, TWO)
    resp = _review(client, booking, appliance, job["id"], _edit(findings))
    assert resp.status_code == 400 and resp.get_json()["code"] == code
    assert _reviews() == []


def test_unknown_decision_and_misused_fields_are_rejected(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    job = _analyse(client, booking, appliance, provider, TWO)
    for body in ({"decision": "approve"}, {}, {"decision": "accept", "findings": [{"code": RESIDUE, "decision": "confirm"}]},
                 {"decision": "reject", "findings": [{"code": RESIDUE, "decision": "confirm"}]},
                 {"decision": "accept", "reason": "see http://x.example"}):
        assert _review(client, booking, appliance, job["id"], body).status_code == 400, body
    assert _reviews() == []


# --------------------------------------------------------- score integration
def test_nothing_changes_until_a_technician_accepts(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    _save_checks(client, booking, appliance)
    before = _health(client, booking, appliance)
    assert before["technicianScore"] == 100 and before["aiScore"] is None and before["combinedScore"] is None
    job = _analyse(client, booking, appliance, provider, TWO)
    unreviewed = _health(client, booking, appliance)
    assert unreviewed == before                                  # an unreviewed result changes nothing
    _review(client, booking, appliance, job["id"], {"decision": "reject"})
    assert _health(client, booking, appliance) == before         # nor does a rejected one


def test_accepted_result_feeds_the_documented_70_30_blend(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    _save_checks(client, booking, appliance)
    job = _analyse(client, booking, appliance, provider, _reply(_finding(RESIDUE, "low")))   # AI score 95
    _review(client, booking, appliance, job["id"], {"decision": "accept"})
    h = _health(client, booking, appliance)
    assert h["technicianScore"] == 100                           # never altered
    assert h["aiScore"] == 95
    assert h["combinedScore"] == 99                              # 0.7*100 + 0.3*95 = 98.5, half-up
    assert h["scoreBasis"] == "technician_plus_ai" and h["ai"]["available"] is True
    assert h["ai"]["inspectionId"] == job["id"]
    assert h["status"] == "healthy"


def test_a_later_reject_removes_the_ai_score_again(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    _save_checks(client, booking, appliance)
    job = _analyse(client, booking, appliance, provider, _reply(_finding(RESIDUE, "low")))
    _review(client, booking, appliance, job["id"], {"decision": "accept"})
    assert _health(client, booking, appliance)["combinedScore"] is not None
    _review(client, booking, appliance, job["id"], {"decision": "reject"})
    h = _health(client, booking, appliance)
    assert h["aiScore"] is None and h["combinedScore"] is None and h["scoreBasis"] == "technician_only"


def test_edited_review_uses_only_confirmed_findings(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    _save_checks(client, booking, appliance)
    job = _analyse(client, booking, appliance, provider, TWO)
    _review(client, booking, appliance, job["id"], _edit(
        [{"code": RESIDUE, "decision": "confirm"}, {"code": BURN, "decision": "reject"}]))
    h = _health(client, booking, appliance)
    assert h["aiScore"] == 85 and h["ai"]["confirmedFindings"] == 1 and h["ai"]["confirmedSafetyFindings"] == []


def test_no_combined_score_without_a_real_technician_score(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    job = _analyse(client, booking, appliance, provider, _reply(_finding(RESIDUE, "low")))
    _review(client, booking, appliance, job["id"], {"decision": "accept"})
    h = _health(client, booking, appliance)
    assert h["technicianScore"] is None and h["combinedScore"] is None and h["status"] is None
    assert h["ai"]["reason"] == "technician_score_missing"


def test_ai_cannot_upgrade_the_technicians_own_band(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    _save_checks(client, booking, appliance, ignition="attention", gas_flow="attention" if False else "good",
                 burner_performance="attention", pan_support="attention")
    base = _health(client, booking, appliance)
    assert base["scoreStatus"] == "attention" and base["technicianScore"] == 78
    job = _analyse(client, booking, appliance, provider, _reply())           # clean photos: AI 100
    _review(client, booking, appliance, job["id"], {"decision": "accept"})
    h = _health(client, booking, appliance)
    assert h["aiScore"] == 100 and h["combinedScore"] == 85                   # the blend itself is unchanged
    assert kitchen_health.status_for_score(h["combinedScore"]) == "healthy"
    assert h["status"] == "attention"                                         # but the band cannot improve


def test_a_confirmed_visible_safety_finding_holds_status_below_healthy(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    _save_checks(client, booking, appliance)
    job = _analyse(client, booking, appliance, provider, _reply(_finding(BURN, "low")))      # AI 95
    _review(client, booking, appliance, job["id"], {"decision": "accept"})
    h = _health(client, booking, appliance)
    assert h["combinedScore"] >= 85 and h["status"] == "attention"
    assert h["ai"]["confirmedSafetyFindings"] == ["Visible burn marks"]
    assert h["safetyFlagged"] is False                                        # checklist flags are untouched
    assert any("accepted AI review" in line for line in h["explanation"])


def test_rejecting_the_safety_finding_in_an_edit_does_not_hold_the_status(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    _save_checks(client, booking, appliance)
    job = _analyse(client, booking, appliance, provider, _reply(_finding(BURN, "low"), _finding(RESIDUE, "low")))
    _review(client, booking, appliance, job["id"], _edit(
        [{"code": BURN, "decision": "reject"}, {"code": RESIDUE, "decision": "confirm"}]))
    h = _health(client, booking, appliance)
    assert h["status"] == "healthy" and h["ai"]["confirmedSafetyFindings"] == []


def test_a_newer_unreviewed_analysis_supersedes_an_older_accepted_one(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    _save_checks(client, booking, appliance)
    old = _analyse(client, booking, appliance, provider, _reply(_finding(RESIDUE, "low")), base=0)
    _review(client, booking, appliance, old["id"], {"decision": "accept"})
    assert _health(client, booking, appliance)["combinedScore"] is not None
    _setrow(old["id"], completed_at="2020-01-01T00:00:00Z")
    _analyse(client, booking, appliance, provider, _reply(_finding(RESIDUE, "high")), base=10)
    h = _health(client, booking, appliance)
    assert h["aiScore"] is None and h["combinedScore"] is None


def test_review_is_ignored_if_the_stored_result_no_longer_matches(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    _save_checks(client, booking, appliance)
    job = _analyse(client, booking, appliance, provider, _reply(_finding(RESIDUE, "low")))
    _review(client, booking, appliance, job["id"], {"decision": "accept"})
    tampered = json.loads(_stored(job["id"])["result_json"])
    tampered["conditionScore"] = 100
    _setrow(job["id"], result_json=json.dumps(tampered))
    h = _health(client, booking, appliance)
    assert h["aiScore"] is None and h["combinedScore"] is None


def test_checklist_answers_are_never_changed_by_a_review(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    _save_checks(client, booking, appliance, ignition="attention")
    url = f"/api/technician/bookings/{booking['id']}/kitchen/appliances/{appliance['id']}/inspection"
    before = client.get(url, headers=H).get_json()
    job = _analyse(client, booking, appliance, provider, TWO)
    _review(client, booking, appliance, job["id"], {"decision": "accept"})
    assert client.get(url, headers=H).get_json() == before


def test_kitchen_summary_exposes_appliance_ai_scores_but_not_a_kitchen_level_blend(ctx):
    client, _t, user, booking, appliance, provider = ctx
    _save_checks(client, booking, appliance)
    job = _analyse(client, booking, appliance, provider, _reply(_finding(RESIDUE, "low")))
    _review(client, booking, appliance, job["id"], {"decision": "accept"})
    own = client.get("/api/kitchen-passport/health", headers=auth_headers(user["token"])).get_json()
    row = own["appliances"][0]
    assert row["aiScore"] == 95 and row["combinedScore"] is not None
    assert own["aiScore"] is None and own["combinedScore"] is None            # kitchen level is unchanged
    assert own["technicianScore"] == 100


# ------------------------------------------------------ pure function checks
def test_apply_ai_review_without_a_review_changes_nothing():
    a = kitchen_health.assess_appliance("hob", {k: {"result": "good", "note": ""} for k in HOB_KEYS})
    assert kitchen_health.apply_ai_review(a, None) is a


def test_apply_ai_review_never_mutates_the_input_or_the_technician_fields():
    a = kitchen_health.assess_appliance("hob", {k: {"result": "good", "note": ""} for k in HOB_KEYS})
    snap = json.dumps(a, sort_keys=True)
    review = {"inspectionId": "I", "decision": "accept", "aiScore": 60, "reviewedAt": "t",
              "confirmedFindings": 1, "confirmedSafetyFindings": []}
    out = kitchen_health.apply_ai_review(a, review)
    assert json.dumps(a, sort_keys=True) == snap
    for k in ("technicianScore", "scoreStatus", "coverage", "flaggedItems", "safetyFlagged"):
        assert out[k] == a[k]
    assert out["combinedScore"] == 88 and out["aiScore"] == 60            # (7*100 + 3*60) / 10 = 88
