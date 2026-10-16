"""A result produced by a simulated (fake/test) provider must be clearly marked
and must NEVER contribute to a technician- or customer-visible health score,
even when a technician accepts it. The marker is written by the server from the
provider that actually ran; nothing a client sends can set or clear it."""
import json

import pytest

import ai_review
import database
import vision_jobs
import vision_provider as vp
from conftest import auth_headers
from test_vision_jobs import (H, _images, _insert_row, _rows, _setrow, _submit, _url, _vision_state, ctx)  # noqa: F401
from test_vision_review import (RESIDUE, _analyse, _finding, _health, _reply, _review, _reviews,  # noqa: F401
                                _save_checks, _stored)

OVERVIEW = "/api/kitchen-passport/overview"


def _overview(client, user):
    return client.get(OVERVIEW, headers=auth_headers(user["token"])).get_json()


# ------------------------------------------------------------ the provider flag
def test_only_the_fake_provider_is_simulated():
    assert vp.FakeProvider.simulated is True
    assert vp.VisionProvider.simulated is False
    assert vp.OpenAIProvider.simulated is False


def test_config_tells_the_app_when_the_active_provider_is_simulated(ctx):
    client = ctx[0]
    assert client.get("/api/technician/ai-inspection/config", headers=H).get_json()["simulated"] is True


def test_selecting_the_fake_provider_by_environment_is_simulated_end_to_end(ctx, monkeypatch):
    client, _t, _u, booking, appliance, _p = ctx
    vp.set_provider_for_tests(None)
    monkeypatch.setenv("RASOI_ALLOW_FAKE_VISION", "1")
    monkeypatch.setenv("VISION_AI_PROVIDER", "fake")
    job = _analyse(client, booking, appliance, None)
    assert job["simulated"] is True and job["result"]["simulated"] is True
    assert _stored(job["id"])["simulated"] == 1


# ------------------------------------------------------------------ persistence
def test_the_marker_is_persisted_on_the_inspection_and_the_review(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    job = _analyse(client, booking, appliance, provider)
    assert job["simulated"] is True and job["result"]["simulated"] is True
    row = _stored(job["id"])
    assert row["simulated"] == 1 and row["provider"] == "fake"
    listed = client.get(_url(booking["id"], appliance["id"]), headers=H).get_json()["inspections"][0]
    assert listed["simulated"] is True
    resp = _review(client, booking, appliance, job["id"], {"decision": "accept"})
    assert resp.status_code == 201 and resp.get_json()["review"]["simulated"] is True
    assert _reviews()[0]["simulated"] == 1
    detail = client.get(_url(booking["id"], appliance["id"], job["id"]), headers=H).get_json()["inspection"]
    assert detail["simulated"] is True and detail["review"]["simulated"] is True
    assert detail["result"]["usedInHealthScore"] is False


def test_the_stored_ai_result_itself_is_not_altered_by_the_marker(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    job = _analyse(client, booking, appliance, provider)
    assert "simulated" not in json.loads(_stored(job["id"])["result_json"])      # marker lives in the column


def test_a_real_provider_is_not_marked_simulated(ctx, monkeypatch):
    client, _t, _u, booking, appliance, provider = ctx
    monkeypatch.setattr(vp.FakeProvider, "simulated", False)
    monkeypatch.setattr(vp.FakeProvider, "name", "stub-real")
    monkeypatch.setattr(vp.FakeProvider, "model", "stub-real-v1")
    job = _analyse(client, booking, appliance, provider)
    assert job["simulated"] is False and _stored(job["id"])["simulated"] == 0


# ------------------------------------------------------------ score exclusion
def test_an_accepted_simulated_result_never_reaches_a_technician_score(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    _save_checks(client, booking, appliance)
    before = _health(client, booking, appliance)
    job = _analyse(client, booking, appliance, provider, _reply(_finding(RESIDUE, "high")))
    assert _review(client, booking, appliance, job["id"], {"decision": "accept"}).status_code == 201
    after = _health(client, booking, appliance)
    assert after == before
    assert after["aiScore"] is None and after["combinedScore"] is None and after["scoreBasis"] == "technician_only"


def test_an_edited_simulated_result_never_reaches_a_score_either(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    _save_checks(client, booking, appliance)
    before = _health(client, booking, appliance)
    job = _analyse(client, booking, appliance, provider, _reply(_finding(RESIDUE, "medium")))
    _review(client, booking, appliance, job["id"],
            {"decision": "edit", "findings": [{"code": RESIDUE, "decision": "confirm", "severity": "low"}]})
    assert _health(client, booking, appliance) == before


def test_an_accepted_simulated_result_never_reaches_the_customer_overview(ctx):
    client, _t, user, booking, appliance, provider = ctx
    _save_checks(client, booking, appliance)
    before = _overview(client, user)
    job = _analyse(client, booking, appliance, provider, _reply(_finding(RESIDUE, "critical")))
    _review(client, booking, appliance, job["id"], {"decision": "accept"})
    after = _overview(client, user)
    assert after == before
    assert after["appliances"][0]["basis"] == "technician_only" and after["appliances"][0]["score"] == 100
    text = json.dumps(after)
    assert "simulated" not in text and "fake" not in text and job["id"] not in text


def test_the_technician_kitchen_summary_excludes_it_too(ctx):
    client, _t, user, booking, appliance, provider = ctx
    _save_checks(client, booking, appliance)
    job = _analyse(client, booking, appliance, provider, _reply(_finding(RESIDUE, "high")))
    _review(client, booking, appliance, job["id"], {"decision": "accept"})
    own = client.get("/api/kitchen-passport/health", headers=auth_headers(user["token"])).get_json()
    assert own["appliances"][0]["aiScore"] is None and own["appliances"][0]["combinedScore"] is None


# ------------------------------------------------------- spoof / removal attempts
def test_a_client_cannot_mark_a_simulated_submission_as_real(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    resp = _submit(client, booking["id"], appliance["id"], images=_images(1),
                   simulated=False, provider="openai", model="gpt-4.1-mini", isSimulated=False)
    job = resp.get_json()["inspection"]
    got = client.get(_url(booking["id"], appliance["id"], job["id"]), headers=H).get_json()["inspection"]
    assert got["simulated"] is True and _stored(job["id"])["provider"] == "fake"


def test_a_client_cannot_clear_the_marker_through_a_review(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    _save_checks(client, booking, appliance)
    job = _analyse(client, booking, appliance, provider)
    resp = _review(client, booking, appliance, job["id"],
                   {"decision": "accept", "simulated": False, "provider": "openai", "usedInHealthScore": True})
    assert resp.status_code == 201 and resp.get_json()["review"]["simulated"] is True
    assert _reviews()[0]["simulated"] == 1
    assert _health(client, booking, appliance)["aiScore"] is None


def test_no_endpoint_accepts_a_marker_change(ctx):
    client, _t, _u, booking, appliance, provider = ctx
    job = _analyse(client, booking, appliance, provider)
    url = _url(booking["id"], appliance["id"], job["id"])
    for method in (client.patch, client.put, client.delete):
        assert method(url, json={"simulated": False}, headers=H).status_code in (404, 405)


def test_clearing_the_stored_flag_in_the_database_still_does_not_make_it_count(ctx):
    """Defence in depth: even with the column tampered back to 0, the recorded
    provider/model name still identifies the result as simulated."""
    client, _t, _u, booking, appliance, provider = ctx
    _save_checks(client, booking, appliance)
    job = _analyse(client, booking, appliance, provider)
    _review(client, booking, appliance, job["id"], {"decision": "accept"})
    _setrow(job["id"], simulated=0)
    conn = database.get_db()
    conn.execute("UPDATE kitchen_ai_reviews SET simulated = 0")
    conn.commit()
    conn.close()
    assert _health(client, booking, appliance)["aiScore"] is None
    got = client.get(_url(booking["id"], appliance["id"], job["id"]), headers=H).get_json()["inspection"]
    assert got["simulated"] is True


def test_a_review_row_marked_simulated_blocks_the_score_even_for_a_real_inspection(ctx, monkeypatch):
    client, _t, _u, booking, appliance, provider = ctx
    monkeypatch.setattr(vp.FakeProvider, "simulated", False)
    monkeypatch.setattr(vp.FakeProvider, "name", "stub-real")
    monkeypatch.setattr(vp.FakeProvider, "model", "stub-real-v1")
    _save_checks(client, booking, appliance)
    job = _analyse(client, booking, appliance, provider, _reply(_finding(RESIDUE, "low")))
    _review(client, booking, appliance, job["id"], {"decision": "accept"})
    assert _health(client, booking, appliance)["combinedScore"] is not None
    conn = database.get_db()
    conn.execute("UPDATE kitchen_ai_reviews SET simulated = 1")
    conn.commit()
    conn.close()
    assert _health(client, booking, appliance)["combinedScore"] is None


# ------------------------------------------------------------------- migration
def test_migration_backfills_results_a_fake_provider_already_produced(ctx):
    client, tech, _u, booking, appliance, _p = ctx
    old = _insert_row(appliance["id"], booking["id"], tech["id"], status="completed", provider="fake",
                      model="fake-vision-v1", result_json="{}", simulated=0)
    real = _insert_row(appliance["id"], booking["id"], tech["id"], status="completed", provider="openai",
                       model="gpt-4.1-mini", result_json="{}", simulated=0)
    conn = database.get_db()
    try:
        database.migrate_vision_simulated_columns(conn)
        database.migrate_vision_simulated_columns(conn)         # idempotent
        # fetchall(): the Postgres cursor wrapper is not iterable.
        rows = {r["id"]: r["simulated"]
                for r in conn.execute("SELECT id, simulated FROM kitchen_ai_inspections").fetchall()}
    finally:
        conn.close()
    assert rows[old] == 1 and rows[real] == 0
