"""Staff PIN seeding and fail-closed, allowlist-only owner access.

Policy under test:
- A fresh database with no STAFF_SEED_OWNER_PIN/STAFF_SEED_STAFF_PIN and no
  explicit opt-in seeds ZERO staff rows and logs a loud refusal (fails safe:
  no login at all, never a login whose credential is public in the repo).
- RASOI_ALLOW_DEFAULT_STAFF_PIN=1 is the explicit dev/test-only opt-in.
- Explicitly configured PINs seed rows; only staff rows authenticate by PIN.
- No log line ever contains a credential value.
- Only verified Google identities on STAFF_BOOTSTRAP_OWNER_EMAILS can become
  owners. Uninvited Firebase identities cannot bootstrap staff.
"""
import os
import tempfile

import database
import app as app_module
from conftest import auth_headers, mock_firebase_claims

OWNER_PHONE = "9822000001"
STAFF_PHONE = "9822000002"


def _fresh_db(monkeypatch):
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    monkeypatch.setattr(database, "DB_PATH", path)
    return path


def test_fresh_db_without_config_seeds_no_staff(monkeypatch, capsys):
    _fresh_db(monkeypatch)
    monkeypatch.delenv("STAFF_SEED_OWNER_PIN", raising=False)
    monkeypatch.delenv("STAFF_SEED_STAFF_PIN", raising=False)
    monkeypatch.delenv("RASOI_ALLOW_DEFAULT_STAFF_PIN", raising=False)

    database.init_db()

    conn = database.get_db()
    n = conn.execute("SELECT COUNT(*) AS n FROM staff").fetchone()["n"]
    conn.close()
    assert n == 0, "refusal must seed nothing"
    out = capsys.readouterr().out
    assert "refusing to seed" in out
    assert "STAFF_SEED_OWNER_PIN" in out  # names the fix, not the value


def test_explicit_opt_in_seeds_and_warns_without_value(monkeypatch, capsys):
    _fresh_db(monkeypatch)
    monkeypatch.delenv("STAFF_SEED_OWNER_PIN", raising=False)
    monkeypatch.delenv("STAFF_SEED_STAFF_PIN", raising=False)
    monkeypatch.setenv("RASOI_ALLOW_DEFAULT_STAFF_PIN", "1")

    database.init_db()

    conn = database.get_db()
    n = conn.execute("SELECT COUNT(*) AS n FROM staff").fetchone()["n"]
    conn.close()
    assert n == 2
    out = capsys.readouterr().out
    assert "RASOI_ALLOW_DEFAULT_STAFF_PIN" in out
    # the credential value itself must never appear in logs
    assert "1234" not in out


def test_configured_pins_seed_and_authenticate(monkeypatch):
    path = _fresh_db(monkeypatch)
    monkeypatch.setenv("STAFF_SEED_OWNER_PIN", "738291")
    monkeypatch.setenv("STAFF_SEED_STAFF_PIN", "481902")

    database.init_db()

    app_module.app.testing = True
    with app_module.app.test_client() as c:
        owner = c.post("/api/staff/login", json={"phone": OWNER_PHONE, "pin": "738291"})
        assert owner.status_code == 401, owner.get_json()
        ops = c.post("/api/staff/login", json={"phone": STAFF_PHONE, "pin": "481902"})
        assert ops.status_code == 200, ops.get_json()
        assert ops.get_json()["staff"]["role"] == "staff"
        # the OTHER account's pin must not open the owner's account
        cross = c.post("/api/staff/login", json={"phone": OWNER_PHONE, "pin": "481902"})
        assert cross.status_code == 401
    os.unlink(path)


def test_configured_to_public_value_warns_but_never_prints_it(monkeypatch, capsys):
    path = _fresh_db(monkeypatch)
    monkeypatch.setenv("STAFF_SEED_OWNER_PIN", "1234")
    monkeypatch.setenv("STAFF_SEED_STAFF_PIN", "1234")

    database.init_db()

    conn = database.get_db()
    n = conn.execute("SELECT COUNT(*) AS n FROM staff").fetchone()["n"]
    conn.close()
    assert n == 2  # operator may have chosen it deliberately — still seeds
    out = capsys.readouterr().out
    assert "public in this repository" in out
    assert "1234" not in out, "logs must not contain the credential value"
    os.unlink(path)


def _wipe_staff():
    conn = database.get_db()
    conn.execute("DELETE FROM staff")
    conn.commit()
    conn.close()


def test_non_allowlisted_firebase_identity_cannot_bootstrap_staff(client, monkeypatch):
    _wipe_staff()
    monkeypatch.setattr(app_module, "_STAFF_BOOTSTRAP_OWNER_EMAILS", {"real-owner@example.com"})
    mock_firebase_claims(monkeypatch, uid="intruder-uid",
                         email="intruder@example.com", email_verified=True)
    resp = client.post("/api/staff/bootstrap", json={"role": "owner"}, headers=auth_headers("x"))
    assert resp.status_code == 403, resp.get_json()
    conn = database.get_db()
    n = conn.execute("SELECT COUNT(*) AS n FROM staff").fetchone()["n"]
    conn.close()
    assert n == 0


def test_owner_allowlist_listed_verified_email_becomes_owner(client, monkeypatch):
    # NOTE: patch the NORMALIZED form — the module lowercases env values when
    # parsing STAFF_BOOTSTRAP_OWNER_EMAILS; matching is case-insensitive by
    # normalization, not by comparison.
    monkeypatch.setattr(app_module, "_STAFF_BOOTSTRAP_OWNER_EMAILS",
                        {"real-owner@example.com", "owner@example.com"})
    mock_firebase_claims(monkeypatch, uid="owner-uid",
                         email="Owner@Example.COM", email_verified=True,
                         sign_in_provider="google.com")
    resp = client.post("/api/staff/bootstrap", json={}, headers=auth_headers("x"))
    assert resp.status_code == 200, resp.get_json()
    assert resp.get_json()["role"] == "owner"
    assert resp.get_json()["id"] == "staff_owner"


def test_allowlisted_but_unverified_email_cannot_bootstrap(client, monkeypatch):
    _wipe_staff()
    monkeypatch.setattr(app_module, "_STAFF_BOOTSTRAP_OWNER_EMAILS", {"real-owner@example.com"})
    # claims email_verified=False — Firebase never confirmed the address,
    # so the allowlist must not match it even though the email is listed
    mock_firebase_claims(monkeypatch, uid="unverified-uid",
                         email="real-owner@example.com", email_verified=False)
    resp = client.post("/api/staff/bootstrap", json={}, headers=auth_headers("x"))
    assert resp.status_code == 403, resp.get_json()


def test_unset_allowlist_fails_closed(client, monkeypatch):
    _wipe_staff()
    monkeypatch.setattr(app_module, "_STAFF_BOOTSTRAP_OWNER_EMAILS", set())
    mock_firebase_claims(monkeypatch, uid="first-uid",
                         email="first@example.com", email_verified=True)
    resp = client.post("/api/staff/bootstrap", json={}, headers=auth_headers("x"))
    assert resp.status_code == 403, resp.get_json()
    conn = database.get_db()
    n = conn.execute("SELECT COUNT(*) AS n FROM staff WHERE firebase_uid = ?", ("first-uid",)).fetchone()["n"]
    conn.close()
    assert n == 0


def test_seeded_pin_owner_row_links_only_to_allowlisted_google_identity(client, monkeypatch):
    monkeypatch.setattr(app_module, "_STAFF_BOOTSTRAP_OWNER_EMAILS", {"real-owner@example.com"})
    mock_firebase_claims(monkeypatch, uid="owner-uid", email="real-owner@example.com",
                         email_verified=True, sign_in_provider="google.com")
    resp = client.post("/api/staff/bootstrap", json={"role": "staff"}, headers=auth_headers("x"))
    assert resp.status_code == 200, resp.get_json()
    assert resp.get_json()["role"] == "owner"
    assert resp.get_json()["id"] == "staff_owner"


def test_verified_phone_only_links_an_existing_staff_invitation(client, monkeypatch):
    mock_firebase_claims(monkeypatch, uid="ops-uid", phone_number="+919822000002")
    resp = client.post("/api/staff/bootstrap", json={"role": "owner"}, headers=auth_headers("x"))
    assert resp.status_code == 200, resp.get_json()
    assert resp.get_json()["role"] == "staff"
    assert resp.get_json()["id"] == "staff_ops"


def test_uninvited_phone_cannot_bootstrap_staff(client, monkeypatch):
    mock_firebase_claims(monkeypatch, uid="tech-uid", phone_number="+919999999999")
    resp = client.post("/api/staff/bootstrap", json={}, headers=auth_headers("x"))
    assert resp.status_code == 403, resp.get_json()


def test_owner_endpoint_rejects_staff_jwt_even_if_role_is_owner(client, monkeypatch):
    _wipe_staff()
    monkeypatch.setattr(app_module, "_STAFF_BOOTSTRAP_OWNER_EMAILS", {"real-owner@example.com"})
    mock_firebase_claims(monkeypatch, uid="owner-uid", email="real-owner@example.com",
                         email_verified=True, sign_in_provider="google.com")
    bootstrap = client.post("/api/staff/bootstrap", json={}, headers=auth_headers("x"))
    assert bootstrap.status_code == 200
    token = app_module.generate_staff_token(bootstrap.get_json()["id"])
    # Listing is staff-gated; use the owner-only create route to assert the
    # stricter Google identity requirement.
    resp = client.post("/api/staff", json={"name": "Other", "phone": "9000000000",
                                           "pin": "8642", "role": "staff"},
                       headers=auth_headers(token))
    assert resp.status_code == 403


def test_owner_invite_cannot_create_another_owner_pin_account(client, monkeypatch):
    _wipe_staff()
    monkeypatch.setattr(app_module, "_STAFF_BOOTSTRAP_OWNER_EMAILS", {"real-owner@example.com"})
    mock_firebase_claims(monkeypatch, uid="owner-uid", email="real-owner@example.com",
                         email_verified=True, sign_in_provider="google.com")
    bootstrap = client.post("/api/staff/bootstrap", json={}, headers=auth_headers("x"))
    token = "x"
    resp = client.post("/api/staff", json={"name": "Extra Owner", "phone": "9000000000",
                                           "pin": "8642", "role": "owner"},
                       headers=auth_headers(token))
    assert bootstrap.status_code == 200
    assert resp.status_code == 400
