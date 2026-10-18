from conftest import register_and_login, auth_headers, mock_firebase_claims


def test_customer_bootstrap_unverified_email_cannot_take_over_existing_account(client, monkeypatch):
    victim = register_and_login(client, email="victim@example.com")

    # A brand-new Firebase account claiming the victim's email, but not
    # verified by Firebase — must never attach to the victim's real row.
    mock_firebase_claims(monkeypatch, uid="attacker-uid", email="victim@example.com", email_verified=False)
    resp = client.post("/api/me/bootstrap", json={"name": "Attacker"}, headers=auth_headers("x"))
    assert resp.status_code == 200
    attacker = resp.get_json()
    assert attacker["id"] != victim["user"]["id"]


def test_customer_bootstrap_verified_email_merges_into_existing_account(client, monkeypatch):
    victim = register_and_login(client, email="victim2@example.com")

    # A verified email match is the legitimate "old password account"
    # migration path and should still work.
    mock_firebase_claims(monkeypatch, uid="real-uid", email="victim2@example.com", email_verified=True)
    resp = client.post("/api/me/bootstrap", json={"name": "Victim"}, headers=auth_headers("x"))
    assert resp.status_code == 200
    assert resp.get_json()["id"] == victim["user"]["id"]


def test_staff_bootstrap_second_signup_cannot_become_owner(client, monkeypatch):
    mock_firebase_claims(monkeypatch, uid="owner-uid", email="owner@example.com", email_verified=True)
    first = client.post("/api/staff/bootstrap", json={"role": "owner"}, headers=auth_headers("x"))
    assert first.status_code == 403

    mock_firebase_claims(monkeypatch, uid="attacker-uid", email="attacker@example.com", email_verified=True)
    second = client.post("/api/staff/bootstrap", json={"role": "owner"}, headers=auth_headers("x"))
    assert second.status_code == 403


def test_staff_bootstrap_unverified_email_cannot_take_over_existing_staff(client, monkeypatch):
    import database

    conn = database.get_db()
    conn.execute("UPDATE staff SET email = ? WHERE id = ?", ("staffer@example.com", "staff_ops"))
    conn.commit()
    conn.close()
    mock_firebase_claims(monkeypatch, uid="staffer-uid", email="staffer@example.com", email_verified=True)
    original_resp = client.post("/api/staff/bootstrap", json={}, headers=auth_headers("x"))
    assert original_resp.status_code == 200
    original = original_resp.get_json()

    mock_firebase_claims(monkeypatch, uid="attacker-uid", email="staffer@example.com", email_verified=False)
    resp = client.post("/api/staff/bootstrap", json={}, headers=auth_headers("x"))
    assert resp.status_code == 403
    conn = database.get_db()
    assert conn.execute("SELECT firebase_uid FROM staff WHERE id = ?", (original["id"],)).fetchone()["firebase_uid"] == "staffer-uid"
    conn.close()
