"""Technician approval -> sign out -> phone sign-in again must stay a
technician. Approval changes only the technician row; it never creates or
links a staff record, and staff access only comes from an explicit roster
entry."""
import pytest

import app as app_module
import database
from conftest import auth_headers

OWNER_EMAIL = "real-owner@example.com"
PHONE = "+918668690490"
CLAIMS = {
    "tech-token": dict(uid="tech-uid", email=None, email_verified=False,
                       sign_in_provider="phone", phone_number=PHONE),
    "owner-token": dict(uid="owner-uid", email=OWNER_EMAIL, email_verified=True,
                        sign_in_provider="google.com", phone_number=None),
    "gmail-token": dict(uid="g-uid", email="someone@gmail.com", email_verified=True,
                        sign_in_provider="google.com", phone_number=None),
}


@pytest.fixture(autouse=True)
def _stub(monkeypatch):
    monkeypatch.setattr(app_module, "verify_firebase_token",
                        lambda t: ({"name": None, **CLAIMS[t]} if t in CLAIMS else None))
    monkeypatch.setattr(app_module, "_STAFF_BOOTSTRAP_OWNER_EMAILS", {OWNER_EMAIL})


def _count(table):
    conn = database.get_db()
    n = conn.execute(f"SELECT COUNT(*) AS n FROM {table}").fetchone()["n"]
    conn.close()
    return n


def _owner(client):
    r = client.post("/api/staff/bootstrap", json={}, headers=auth_headers("owner-token"))
    assert r.status_code == 200 and r.get_json()["role"] == "owner"


def _apply(client):
    r = client.post("/api/technician/bootstrap", json={"name": "T"}, headers=auth_headers("tech-token"))
    assert r.status_code == 200
    return r.get_json()


def test_approve_then_relogin_stays_technician(client):
    tech = _apply(client)
    assert tech["verified"] is False
    assert client.post("/api/staff/bootstrap", json={}, headers=auth_headers("tech-token")).status_code == 403
    _owner(client)
    staff_before = _count("staff")

    r = client.patch(f"/api/technicians/{tech['id']}/verify", headers=auth_headers("owner-token"))
    assert r.status_code == 200

    # approval wrote no staff row
    assert _count("staff") == staff_before
    conn = database.get_db()
    assert conn.execute("SELECT COUNT(*) AS n FROM staff WHERE firebase_uid = 'tech-uid'").fetchone()["n"] == 0
    conn.close()

    # sign in again with the same phone: still not staff, technician is verified
    assert client.post("/api/staff/bootstrap", json={}, headers=auth_headers("tech-token")).status_code == 403
    again = client.post("/api/technician/bootstrap", json={"name": "T"}, headers=auth_headers("tech-token")).get_json()
    assert again["id"] == tech["id"] and again["verified"] is True
    assert client.get("/api/technician/me", headers=auth_headers("tech-token")).get_json()["verified"] is True
    assert _count("staff") == staff_before


def test_phone_on_staff_roster_still_routes_to_staff(client):
    _owner(client)
    r = client.post("/api/staff", json={"name": "Ops", "phone": "8668690490", "pin": "482913", "role": "staff"},
                    headers=auth_headers("owner-token"))
    assert r.status_code == 201, r.get_data(as_text=True)
    b = client.post("/api/staff/bootstrap", json={}, headers=auth_headers("tech-token"))
    assert b.status_code == 200 and b.get_json()["role"] == "staff"


def test_unapproved_technician_cannot_get_jobs(client):
    tech = _apply(client)
    me = client.get("/api/technician/me", headers=auth_headers("tech-token")).get_json()
    assert me["verified"] is False
    feed = client.get("/api/technician/bookings/available", headers=auth_headers("tech-token"))
    assert feed.status_code != 200 or feed.get_json() == []
    assert tech["verified"] is False


def test_technician_has_no_owner_or_staff_controls(client):
    tech = _apply(client)
    _owner(client)
    client.patch(f"/api/technicians/{tech['id']}/verify", headers=auth_headers("owner-token"))
    h = auth_headers("tech-token")
    assert client.get("/api/staff", headers=h).status_code in (401, 403)
    assert client.post("/api/staff", json={"name": "x", "phone": "9000000001", "pin": "482913", "role": "staff"},
                       headers=h).status_code in (401, 403)
    assert client.patch(f"/api/technicians/{tech['id']}/verify", headers=h).status_code in (401, 403)
    assert client.get("/api/bookings", headers=h).status_code in (401, 403)


def test_owner_is_google_allowlist_only(client):
    assert client.post("/api/staff/bootstrap", json={}, headers=auth_headers("gmail-token")).status_code == 403
    assert client.post("/api/staff/bootstrap", json={}, headers=auth_headers("tech-token")).status_code == 403
    _owner(client)


def _roster_phone_staff(client):
    _owner(client)
    r = client.post("/api/staff", json={"name": "Ops", "phone": "8668690490", "pin": "482913", "role": "staff"},
                    headers=auth_headers("owner-token"))
    assert r.status_code == 201
    return r.get_json()["id"]


def _tech_snapshot(tech_id):
    conn = database.get_db()
    row = dict(conn.execute("SELECT * FROM technicians WHERE id = ?", (tech_id,)).fetchone())
    conn.close()
    return row


def test_deactivated_staff_phone_signs_in_as_approved_technician(client):
    tech = _apply(client)
    _owner(client)
    client.patch(f"/api/technicians/{tech['id']}/verify", headers=auth_headers("owner-token"))
    staff_id = _roster_phone_staff(client)
    # active + linked by uid: routes to staff
    assert client.post("/api/staff/bootstrap", json={}, headers=auth_headers("tech-token")).get_json()["role"] == "staff"
    before = _tech_snapshot(tech["id"])

    r = client.patch(f"/api/staff/{staff_id}", json={"active": False}, headers=auth_headers("owner-token"))
    assert r.status_code == 200 and r.get_json()["active"] is False

    # staff access revoked, even though the row is linked to this uid
    b = client.post("/api/staff/bootstrap", json={}, headers=auth_headers("tech-token"))
    assert b.status_code == 403
    assert client.get("/api/staff", headers=auth_headers("tech-token")).status_code in (401, 403)
    # the staff row is kept (history) and was not rewritten by the failed bootstrap
    conn = database.get_db()
    row = conn.execute("SELECT * FROM staff WHERE id = ?", (staff_id,)).fetchone()
    conn.close()
    assert row is not None and row["active"] == 0 and row["role"] == "staff"
    # technician untouched and usable
    assert _tech_snapshot(tech["id"]) == before
    t = client.post("/api/technician/bootstrap", json={"name": "T"}, headers=auth_headers("tech-token")).get_json()
    assert t["id"] == tech["id"] and t["verified"] is True
    assert client.get("/api/technician/me", headers=auth_headers("tech-token")).get_json()["verified"] is True

    # reinstating restores staff routing
    client.patch(f"/api/staff/{staff_id}", json={"active": True}, headers=auth_headers("owner-token"))
    assert client.post("/api/staff/bootstrap", json={}, headers=auth_headers("tech-token")).get_json()["role"] == "staff"


def test_deactivated_unlinked_staff_phone_is_not_staff(client):
    staff_id = _roster_phone_staff(client)
    client.patch(f"/api/staff/{staff_id}", json={"active": False}, headers=auth_headers("owner-token"))
    assert client.post("/api/staff/bootstrap", json={}, headers=auth_headers("tech-token")).status_code == 403


def test_only_allowlisted_owner_can_deactivate(client):
    staff_id = _roster_phone_staff(client)
    assert client.post("/api/staff/bootstrap", json={}, headers=auth_headers("tech-token")).status_code == 200
    # the staff member themself, a technician-only identity, and a random Gmail all fail
    for tok in ("tech-token", "gmail-token"):
        assert client.patch(f"/api/staff/{staff_id}", json={"active": False},
                            headers=auth_headers(tok)).status_code in (401, 403)
    assert client.patch(f"/api/staff/{staff_id}", json={"active": False}).status_code == 401
    conn = database.get_db()
    assert conn.execute("SELECT active FROM staff WHERE id = ?", (staff_id,)).fetchone()["active"] == 1
    conn.close()


def test_owner_row_cannot_be_deactivated_via_api(client):
    _owner(client)
    conn = database.get_db()
    owner_id = conn.execute("SELECT id FROM staff WHERE role = 'owner' AND firebase_uid = 'owner-uid'").fetchone()["id"]
    conn.close()
    r = client.patch(f"/api/staff/{owner_id}", json={"active": False}, headers=auth_headers("owner-token"))
    assert r.status_code == 400
    assert client.post("/api/staff/bootstrap", json={}, headers=auth_headers("owner-token")).status_code == 200


# ---------------------------------------------------------- explicit role choice
def _staff_boot(client, tok, role=None):
    body = {"role": role} if role else {}
    return client.post("/api/staff/bootstrap", json=body, headers=auth_headers(tok))


def test_owner_choice_needs_the_allowlisted_google_identity(client):
    assert _staff_boot(client, "owner-token", "owner").get_json()["role"] == "owner"
    for tok in ("tech-token", "gmail-token"):
        assert _staff_boot(client, tok, "owner").status_code == 403
    conn = database.get_db()
    # nothing was created for the rejected identities
    assert conn.execute("SELECT COUNT(*) AS n FROM staff WHERE firebase_uid IN ('tech-uid','g-uid')").fetchone()["n"] == 0
    conn.close()


def test_staff_choice_rejects_the_owner_identity(client):
    r = _staff_boot(client, "owner-token", "staff")
    assert r.status_code == 403
    conn = database.get_db()
    assert conn.execute("SELECT COUNT(*) AS n FROM staff WHERE role = 'owner' AND firebase_uid = 'owner-uid'").fetchone()["n"] == 0
    conn.close()
    # the owner choice still works afterwards
    assert _staff_boot(client, "owner-token", "owner").get_json()["role"] == "owner"
    assert _staff_boot(client, "owner-token", "staff").status_code == 403


def test_staff_choice_works_for_roster_phone_and_rejects_others(client):
    _owner(client)
    client.post("/api/staff", json={"name": "Ops", "phone": "8668690490", "pin": "482913", "role": "staff"},
                headers=auth_headers("owner-token"))
    assert _staff_boot(client, "tech-token", "staff").get_json()["role"] == "staff"
    assert _staff_boot(client, "gmail-token", "staff").status_code == 403


def test_technician_choice_rejected_for_staff_only_and_owner_identities(client):
    _owner(client)
    client.post("/api/staff", json={"name": "Ops", "phone": "8668690490", "pin": "482913", "role": "staff"},
                headers=auth_headers("owner-token"))
    # staff-only phone has no technician record -> no profile is minted
    r = client.post("/api/technician/bootstrap", json={"name": "T"}, headers=auth_headers("tech-token"))
    assert r.status_code == 403
    # the allowlisted owner cannot become a technician either
    r = client.post("/api/technician/bootstrap", json={"name": "O"}, headers=auth_headers("owner-token"))
    assert r.status_code == 403
    conn = database.get_db()
    assert conn.execute("SELECT COUNT(*) AS n FROM technicians").fetchone()["n"] == 0
    conn.close()


def test_identity_with_both_roles_gets_the_chosen_workspace_only(client):
    tech = _apply(client)
    _owner(client)
    client.patch(f"/api/technicians/{tech['id']}/verify", headers=auth_headers("owner-token"))
    client.post("/api/staff", json={"name": "Ops", "phone": "8668690490", "pin": "482913", "role": "staff"},
                headers=auth_headers("owner-token"))
    h = auth_headers("tech-token")
    # technician workspace
    assert client.post("/api/technician/bootstrap", json={"name": "T"}, headers=h).get_json()["id"] == tech["id"]
    assert client.get("/api/technician/me", headers=h).status_code == 200
    # staff workspace
    assert _staff_boot(client, "tech-token", "staff").get_json()["role"] == "staff"
    # each endpoint enforces only that role: staff can't use owner controls
    assert client.get("/api/staff", headers=h).status_code in (401, 403)
    assert client.post("/api/staff", json={"name": "x", "phone": "9000000001", "pin": "482913", "role": "staff"},
                       headers=h).status_code in (401, 403)
    # and never owner
    assert _staff_boot(client, "tech-token", "owner").status_code == 403


def test_new_phone_technician_choice_creates_unverified_applicant_only(client):
    t = client.post("/api/technician/bootstrap", json={"name": "N"}, headers=auth_headers("tech-token"))
    assert t.status_code == 200 and t.get_json()["verified"] is False
    assert _staff_boot(client, "tech-token", "staff").status_code == 403


# ---------------------------------------------------- application photo handling
DOC_URLS = {
    "aadharDocumentUrl": "https://example.test/o/aadhar_front.jpg",
    "aadharDocumentBackUrl": "https://example.test/o/aadhar_back.jpg",
    "panDocumentUrl": "https://example.test/o/pan.jpg",
}


def test_application_submits_without_a_profile_photo_and_profile_loads(client):
    _apply(client)
    h = auth_headers("tech-token")
    body = {"name": "T", "area": "Nashik", "address": "1 Main Rd", "employmentType": "outsourced",
            "submit": True, **DOC_URLS}
    r = client.patch("/api/technician/me", json=body, headers=h)
    assert r.status_code == 200, r.get_data(as_text=True)
    me = client.get("/api/technician/me", headers=h)
    assert me.status_code == 200
    j = me.get_json()
    assert j["applicationSubmitted"] is True and j["verified"] is False
    assert not j.get("photoUrl")


def test_firebase_storage_download_url_is_accepted_as_photo_url(client):
    _apply(client)
    url = ("https://firebasestorage.googleapis.com/v0/b/rasoi-care-b78ea.firebasestorage.app/o/"
           "technician_applications%2Fuid%2Fphoto.jpg?alt=media&token=abc-123")
    r = client.patch("/api/technician/me", json={"photoUrl": url}, headers=auth_headers("tech-token"))
    assert r.status_code == 200
    assert r.get_json()["photoUrl"] == url


# ------------------------------------------- staging-only deferred documents
SUBMIT = {"name": "T", "area": "Nashik", "address": "1 Main Rd", "employmentType": "outsourced",
          "submit": True}


def test_production_still_requires_identity_documents(client, monkeypatch):
    monkeypatch.setattr(app_module, "_TECH_DOCS_DEFERRED", False)
    _apply(client)
    h = auth_headers("tech-token")
    r = client.patch("/api/technician/me", json=SUBMIT, headers=h)
    assert r.status_code == 400
    assert set(r.get_json()["fields"]) == {"aadharDocumentUrl", "aadharDocumentBackUrl", "panDocumentUrl"}
    me = client.get("/api/technician/me", headers=h).get_json()
    assert me["applicationSubmitted"] is False and me["documentsDeferred"] is False
    # partial documents are still not enough
    r = client.patch("/api/technician/me", json={**SUBMIT, "aadharDocumentUrl": DOC_URLS["aadharDocumentUrl"]}, headers=h)
    assert r.status_code == 400
    # with all three it submits, and still waits for approval
    r = client.patch("/api/technician/me", json={**SUBMIT, **DOC_URLS}, headers=h)
    assert r.status_code == 200
    assert r.get_json()["applicationSubmitted"] is True and r.get_json()["verified"] is False


def test_staging_flag_allows_submission_without_any_images(client, monkeypatch):
    monkeypatch.setattr(app_module, "_TECH_DOCS_DEFERRED", True)
    _apply(client)
    h = auth_headers("tech-token")
    r = client.patch("/api/technician/me", json=SUBMIT, headers=h)
    assert r.status_code == 200, r.get_data(as_text=True)
    j = r.get_json()
    assert j["applicationSubmitted"] is True and j["documentsDeferred"] is True
    # no URLs were invented
    assert not j.get("photoUrl")
    conn = database.get_db()
    row = conn.execute("SELECT photo_url, aadhar_document_url, aadhar_document_back_url, pan_document_url, "
                       "bank_passbook_url FROM technicians").fetchone()
    conn.close()
    assert all(not v for v in tuple(row))


def test_deferred_application_stays_pending_and_blocked_until_owner_approves(client, monkeypatch):
    monkeypatch.setattr(app_module, "_TECH_DOCS_DEFERRED", True)
    tech = _apply(client)
    h = auth_headers("tech-token")
    client.patch("/api/technician/me", json=SUBMIT, headers=h)
    me = client.get("/api/technician/me", headers=h).get_json()
    assert me["verified"] is False and me.get("online") in (False, 0, None)
    feed = client.get("/api/technician/bookings/available", headers=h)
    assert feed.status_code != 200 or feed.get_json() == []
    # cannot self-approve, go online-verified, or reach owner/staff controls
    assert client.patch(f"/api/technicians/{tech['id']}/verify", headers=h).status_code in (401, 403)
    assert client.get("/api/staff", headers=h).status_code in (401, 403)
    assert client.get("/api/bookings", headers=h).status_code in (401, 403)
    assert client.post("/api/staff/bootstrap", json={}, headers=h).status_code == 403
    # only the allowlisted owner can approve
    assert client.patch(f"/api/technicians/{tech['id']}/verify", headers=auth_headers("gmail-token")).status_code in (401, 403)
    _owner(client)
    assert client.patch(f"/api/technicians/{tech['id']}/verify", headers=auth_headers("owner-token")).status_code == 200
    assert client.get("/api/technician/me", headers=h).get_json()["verified"] is True


def test_client_cannot_switch_the_deferred_mode_on(client, monkeypatch):
    monkeypatch.setattr(app_module, "_TECH_DOCS_DEFERRED", False)
    _apply(client)
    h = auth_headers("tech-token")
    for body in ({**SUBMIT, "documentsDeferred": True}, {**SUBMIT, "role": "owner", "staging": True}):
        r = client.patch("/api/technician/me", json=body, headers=h)
        assert r.status_code == 400  # missing documents (or unknown field) — never accepted
    assert client.get("/api/technician/me", headers=h).get_json()["applicationSubmitted"] is False
