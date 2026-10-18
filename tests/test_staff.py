from conftest import auth_headers

OWNER_PHONE = "9822000001"
OWNER_PIN = "1234"


def test_owner_cannot_sign_in_with_pin(client):
    resp = client.post("/api/staff/login", json={"phone": OWNER_PHONE, "pin": OWNER_PIN})
    assert resp.status_code == 401


def test_staff_login_wrong_pin_rejected(client):
    resp = client.post("/api/staff/login", json={"phone": OWNER_PHONE, "pin": "0000"})
    assert resp.status_code == 401


def test_staff_me_requires_auth(client):
    resp = client.get("/api/staff/me")
    assert resp.status_code == 401


def test_staff_me_returns_current_staff(client):
    login = client.post("/api/staff/login", json={"phone": "9822000002", "pin": OWNER_PIN}).get_json()
    assert login.get("token")
    resp = client.get("/api/staff/me", headers=auth_headers(login["token"]))
    assert resp.status_code == 200
    assert resp.get_json()["phone"] == "9822000002"


def test_customer_token_rejected_on_staff_route(client):
    from conftest import register_and_login
    user = register_and_login(client)
    resp = client.get("/api/staff/me", headers=auth_headers(user["token"]))
    assert resp.status_code == 401


def test_staff_cannot_read_owner_roster_or_financial_metrics(client):
    login = client.post("/api/staff/login", json={"phone": "9822000002", "pin": OWNER_PIN})
    assert login.status_code == 200
    headers = auth_headers(login.get_json()["token"])

    assert client.get("/api/staff", headers=headers).status_code == 403

    overview = client.get("/api/stats/overview", headers=headers)
    assert overview.status_code == 200
    assert "revenue" not in overview.get_json()

    reports = client.get("/api/stats/reports", headers=headers)
    assert reports.status_code == 200
    body = reports.get_json()
    assert body["revenueTrend"] == []
    assert body["revenueByCategory"] == []
    assert "grossRevenue" not in body
    assert body["pnl"] is None
    assert all("revenueInPeriod" not in row for row in body["technicianLeaderboard"])

    earnings = client.get("/api/technicians/not-a-tech/earnings", headers=headers)
    assert earnings.status_code == 403


def _staff_headers(client):
    login = client.post("/api/staff/login", json={"phone": "9822000002", "pin": OWNER_PIN})
    assert login.status_code == 200
    return auth_headers(login.get_json()["token"])


def _seed_technician_with_bank_details():
    import database

    conn = database.get_db()
    conn.execute(
        "INSERT INTO technicians (id, name, category, area, verified, online, rating, rating_count, "
        "jobs_completed, bank_account_name, bank_account_number, bank_ifsc, upi_id, gst_number, "
        "bank_passbook_url) VALUES ('tech-bank','Bank Tech','RasoiSpark','Area',1,0,5.0,0,0,"
        "'Holder','123456789012','TEST0000001','tech@upi','GSTTEST','https://example.invalid/p')"
    )
    conn.commit()
    conn.close()


def test_staff_technician_list_hides_bank_and_payout_details(client):
    _seed_technician_with_bank_details()
    resp = client.get("/api/technicians", headers=_staff_headers(client))
    assert resp.status_code == 200
    row = next(t for t in resp.get_json() if t["id"] == "tech-bank")
    for field in ("bankAccountName", "bankAccountNumber", "bankIfsc", "upiId", "gstNumber", "bankPassbookUrl"):
        assert row[field] is None
    assert row["bankPassbookReady"] is False


def test_staff_cannot_open_bank_passbook_document(client):
    _seed_technician_with_bank_details()
    resp = client.get("/api/technicians/tech-bank/document/bank-passbook", headers=_staff_headers(client))
    assert resp.status_code == 403


def test_owner_row_with_legacy_jwt_gets_no_financial_metrics(client):
    import app as app_module

    token = app_module.generate_staff_token("staff_owner")
    headers = auth_headers(token)
    assert "revenue" not in client.get("/api/stats/overview", headers=headers).get_json()
    reports = client.get("/api/stats/reports", headers=headers).get_json()
    assert reports["isOwner"] is False
    assert reports["pnl"] is None
    assert client.get("/api/staff", headers=headers).status_code == 403
    assert client.post("/api/reset", headers=headers).status_code == 403


def test_owner_with_allowlisted_google_identity_sees_financials(client, monkeypatch):
    import app as app_module
    from conftest import mock_firebase_claims

    monkeypatch.setattr(app_module, "_STAFF_BOOTSTRAP_OWNER_EMAILS", {"real-owner@example.com"})
    mock_firebase_claims(monkeypatch, uid="owner-uid", email="real-owner@example.com",
                         email_verified=True, sign_in_provider="google.com")
    assert client.post("/api/staff/bootstrap", json={}, headers=auth_headers("x")).status_code == 200
    headers = auth_headers("x")
    assert "revenue" in client.get("/api/stats/overview", headers=headers).get_json()
    assert client.get("/api/staff", headers=headers).status_code == 200
    _seed_technician_with_bank_details()
    row = next(t for t in client.get("/api/technicians", headers=headers).get_json() if t["id"] == "tech-bank")
    assert row["bankAccountNumber"] == "123456789012"


def test_owner_google_identity_off_allowlist_is_denied_owner_routes(client, monkeypatch):
    import app as app_module
    from conftest import mock_firebase_claims

    monkeypatch.setattr(app_module, "_STAFF_BOOTSTRAP_OWNER_EMAILS", {"real-owner@example.com"})
    mock_firebase_claims(monkeypatch, uid="owner-uid", email="real-owner@example.com",
                         email_verified=True, sign_in_provider="google.com")
    assert client.post("/api/staff/bootstrap", json={}, headers=auth_headers("x")).status_code == 200
    # Same linked owner row, but the allowlist no longer lists the address.
    monkeypatch.setattr(app_module, "_STAFF_BOOTSTRAP_OWNER_EMAILS", {"someone-else@example.com"})
    headers = auth_headers("x")
    assert client.get("/api/staff", headers=headers).status_code == 403
    assert "revenue" not in client.get("/api/stats/overview", headers=headers).get_json()
