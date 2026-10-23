"""Pay now vs pay after service, and the technician's dynamic invoice QR.

Razorpay is replaced by an in-memory fake (real network use fails the test).
Money only counts as received when the server sees a captured INR payment for
exactly the QR's amount; a technician/customer tap never marks anything paid."""
import pytest

import app as app_module
import database
from conftest import add_payment_intent, add_technician, auth_headers, register_and_login

KEY_ID = "rzp_test_unit_test_key"
SECRET = "unit-test-secret-not-real"
CLAIMS = {
    "tech-token": dict(uid="tech-uid", email=None, email_verified=False,
                       sign_in_provider="phone", phone_number="+919999900001"),
    "tech2-token": dict(uid="tech2-uid", email=None, email_verified=False,
                        sign_in_provider="phone", phone_number="+919999900002"),
}


class FakeRazorpay:
    def __init__(self):
        self.calls = []
        self.qrs = {}
        self.qr_payments = {}   # qr id -> list of payment dicts
        self.payments = {}      # payment id -> payment dict
        self.fail = None        # exception to raise on every call
        self.fail_on = {}       # (method, path-prefix) -> exception
        self._n = 0

    def __call__(self, method, path, payload=None):
        self.calls.append((method, path, payload))
        if self.fail:
            raise self.fail
        for (m, prefix), exc in self.fail_on.items():
            if method == m and path.startswith(prefix):
                raise exc
        if (method, path) == ("POST", "/payments/qr_codes"):
            self._n += 1
            qid = f"qr_fake{self._n:04d}"
            self.qrs[qid] = dict(payload, id=qid, status="active")
            return {"id": qid, "image_url": f"https://example.test/{qid}.png", "status": "active"}
        if path.startswith("/payments/qr_codes/") and path.endswith("/close"):
            self.qrs[path.split("/")[3]]["status"] = "closed"
            return {"status": "closed"}
        if path.startswith("/payments/qr_codes/") and "/payments" in path:
            return {"items": [dict(p) for p in self.qr_payments.get(path.split("/")[3], [])]}
        if method == "GET" and path.startswith("/payments/"):
            return dict(self.payments[path.split("/")[2]])
        if method == "POST" and path.endswith("/capture"):
            pid = path.split("/")[2]
            assert payload["amount"] == self.payments[pid]["amount"]
            self.payments[pid]["status"] = "captured"
            return dict(self.payments[pid])
        raise AssertionError(f"unexpected Razorpay call {method} {path}")

    def pay_qr(self, qr_id, pid, amount, status="captured", currency="INR"):
        p = {"id": pid, "amount": amount, "currency": currency, "status": status, "order_id": None}
        self.payments[pid] = p
        self.qr_payments.setdefault(qr_id, []).append(p)

    def created(self):
        return [c for c in self.calls if (c[0], c[1]) == ("POST", "/payments/qr_codes")]


@pytest.fixture(autouse=True)
def rz(monkeypatch):
    fake = FakeRazorpay()
    monkeypatch.setattr(app_module, "RAZORPAY_KEY_ID", KEY_ID)
    monkeypatch.setattr(app_module, "RAZORPAY_KEY_SECRET", SECRET)
    monkeypatch.setattr(app_module, "RAZORPAY_MODE", "test")
    monkeypatch.setattr(app_module, "_razorpay_api", fake)
    monkeypatch.setattr(app_module, "verify_firebase_token",
                        lambda t: ({"name": None, **CLAIMS[t]} if t in CLAIMS else None))

    def no_network(*a, **k):
        raise AssertionError("tests must not make real network calls")

    monkeypatch.setattr(app_module.urllib.request, "urlopen", no_network)
    return fake


def _tech(client, token="tech-token"):
    t = client.post("/api/technician/bootstrap", json={"name": "T"}, headers=auth_headers(token)).get_json()
    conn = database.get_db()
    conn.execute("UPDATE technicians SET verified = 1, online = 1 WHERE id = ?", (t["id"],))
    conn.commit()
    conn.close()
    return t


def _booking(client, tech, cust, bid="BK1", status="Completed", total_rupees=1000, mode="pay_after_service",
             paid_paise=0):
    ts = database.now()
    conn = database.get_db()
    conn.execute(
        "INSERT INTO bookings (id, category, service, price, technician_id, status, user_id, total_amount, "
        "payment_mode, amount_paid_paise, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        (bid, "RasoiSpark", "Clean", total_rupees, tech["id"], status, cust["user"]["id"], total_rupees,
         mode, paid_paise, ts, ts),
    )
    conn.commit()
    conn.close()


def _part(bid, status, price_paise=20000, qty=1, pid=None):
    conn = database.get_db()
    conn.execute(
        "INSERT INTO booking_parts (id, booking_id, name, qty, price_paise, status, created_at) VALUES (?,?,?,?,?,?,?)",
        (pid or f"P-{status}-{price_paise}", bid, "Filter", qty, price_paise, status, database.now()))
    conn.commit()
    conn.close()


def _qr(client, bid="BK1", token="tech-token"):
    return client.post(f"/api/technician/bookings/{bid}/payment-qr", headers=auth_headers(token))


def _status(client, bid="BK1", token="tech-token"):
    return client.get(f"/api/technician/bookings/{bid}/payment", headers=auth_headers(token))


def _row(bid="BK1"):
    conn = database.get_db()
    r = conn.execute("SELECT * FROM bookings WHERE id = ?", (bid,)).fetchone()
    conn.close()
    return r


def _setup(client, **kw):
    cust = register_and_login(client)
    tech = _tech(client)
    _booking(client, tech, cust, **kw)
    return cust, tech


# ------------------------------------------------ pay after service (checkout)
def _checkout_setup(client):
    conn = database.get_db()
    add_technician(conn)
    conn.commit()
    conn.close()
    sid = client.get("/api/services").get_json()[0]["id"]
    cust = register_and_login(client)
    return cust, sid


def test_pay_after_service_creates_unpaid_payable_booking_without_payment(client):
    cust, sid = _checkout_setup(client)
    h = auth_headers(cust["token"])
    r = client.post("/api/bookings/cart", json={"serviceIds": [sid], "useCoins": False,
                                                "paymentMode": "pay_after_service", "area": "Home"}, headers=h)
    assert r.status_code == 201, r.get_json()
    b = r.get_json()["bookings"][0]
    assert b["payment"]["mode"] == "pay_after_service" and b["payment"]["status"] == "unpaid"
    assert b["payment"]["paidPaise"] == 0 and b["payment"]["duePaise"] == b["total_amount"] * 100
    assert b["payment"]["duePaise"] > 0
    conn = database.get_db()
    assert conn.execute("SELECT COUNT(*) AS n FROM razorpay_payment_intents").fetchone()["n"] == 0
    conn.close()


def test_client_cannot_claim_it_already_paid(client):
    cust, sid = _checkout_setup(client)
    h = auth_headers(cust["token"])
    r = client.post("/api/bookings/cart", json={
        "serviceIds": [sid], "useCoins": False, "paymentMode": "pay_after_service",
        "paymentStatus": "paid", "amountPaidPaise": 99999999, "paidAt": "2020-01-01T00:00:00Z"}, headers=h)
    b = r.get_json()["bookings"][0]
    assert b["payment"]["status"] == "unpaid" and b["payment"]["paidPaise"] == 0 and b["payment"]["paidAt"] is None


def test_checkout_requires_an_explicit_valid_choice(client):
    cust, sid = _checkout_setup(client)
    h = auth_headers(cust["token"])
    assert client.post("/api/bookings/cart", json={"serviceIds": [sid]}, headers=h).status_code == 402
    assert client.post("/api/bookings/cart", json={"serviceIds": [sid], "paymentMode": "free"}, headers=h).status_code == 400
    assert client.post("/api/bookings/cart", json={"serviceIds": [sid], "paymentMode": "pay_now"}, headers=h).status_code == 402
    both = {**h, "X-Razorpay-Order-Id": add_payment_intent(cust["user"]["id"], [sid])}
    assert client.post("/api/bookings/cart", json={"serviceIds": [sid], "paymentMode": "pay_after_service"},
                       headers=both).status_code == 400
    assert client.get("/api/bookings", headers=h).get_json() == []


def test_pay_now_marks_booking_paid_from_the_verified_intent_only(client):
    cust, sid = _checkout_setup(client)
    h = {**auth_headers(cust["token"]), "X-Razorpay-Order-Id": add_payment_intent(cust["user"]["id"], [sid])}
    r = client.post("/api/bookings/cart", json={"serviceIds": [sid], "useCoins": False, "paymentMode": "pay_now"},
                    headers=h)
    assert r.status_code == 201, r.get_json()
    p = r.get_json()["bookings"][0]["payment"]
    assert p["mode"] == "pay_now" and p["status"] == "paid" and p["duePaise"] == 0 and p["paidAt"]
    # unpaid intent -> nothing is created, nothing is marked paid
    h2 = {**auth_headers(cust["token"]),
          "X-Razorpay-Order-Id": add_payment_intent(cust["user"]["id"], [sid], status="created")}
    assert client.post("/api/bookings/cart", json={"serviceIds": [sid]}, headers=h2).status_code == 402


# ------------------------------------------------------------- invoice QR
def test_qr_requires_assigned_technician_and_completed_job(client, rz):
    cust, tech = _setup(client)
    assert client.post("/api/technician/bookings/BK1/payment-qr").status_code == 401
    _tech(client, "tech2-token")
    assert _qr(client, token="tech2-token").status_code == 404           # not their booking
    assert _qr(client, bid="NOPE").status_code == 404
    conn = database.get_db()
    conn.execute("UPDATE bookings SET status = 'In Progress' WHERE id = 'BK1'")
    conn.commit()
    conn.close()
    assert _qr(client).status_code == 409                                  # amount not final yet
    assert rz.created() == []


def test_qr_is_for_exactly_the_outstanding_invoice(client, rz):
    cust, tech = _setup(client, total_rupees=1000)
    _part("BK1", "approved", 20000, qty=2)       # +400.00 approved extra work
    _part("BK1", "pending", 99900)
    _part("BK1", "rejected", 88800)
    r = _qr(client)
    assert r.status_code == 201, r.get_json()
    due = 1000 * 100 + 2 * 20000
    body = r.get_json()
    assert body["qr"]["amountPaise"] == due and body["payment"]["duePaise"] == due
    assert body["qr"]["status"] == "active" and body["qr"]["imageUrl"].startswith("https://")
    (_, _, payload), = rz.created()
    assert payload["type"] == "upi_qr" and payload["usage"] == "single_use" and payload["fixed_amount"] is True
    assert payload["payment_amount"] == due and payload["notes"] == {"booking_id": "BK1"}


def test_qr_for_a_prepaid_booking_covers_only_the_unpaid_extras(client, rz):
    cust, tech = _setup(client, total_rupees=1000, mode="pay_now", paid_paise=100000)
    assert _qr(client).get_json()["payment"]["status"] == "paid"           # nothing due
    assert rz.created() == []
    _part("BK1", "approved", 15000)
    r = _qr(client)
    assert r.status_code == 201 and r.get_json()["qr"]["amountPaise"] == 15000


def test_qr_is_idempotent_and_replaced_when_the_amount_changes(client, rz):
    cust, tech = _setup(client)
    first = _qr(client).get_json()["qr"]
    again = _qr(client)
    assert again.status_code == 200 and again.get_json()["qr"]["qrId"] == first["qrId"]
    assert len(rz.created()) == 1
    _part("BK1", "approved", 5000)                        # invoice grows after the QR was shown
    third = _qr(client)
    assert third.status_code == 201 and third.get_json()["qr"]["qrId"] != first["qrId"]
    assert third.get_json()["qr"]["amountPaise"] == 100000 + 5000
    assert rz.qrs[first["qrId"]]["status"] == "closed"    # the old code can no longer be paid


def test_qr_unavailable_reports_the_prerequisite(client, rz):
    _setup(client)
    rz.fail_on[("POST", "/payments/qr_codes")] = app_module.RazorpayError("Razorpay request failed (400)", 400)
    r = _qr(client)
    assert r.status_code == 503 and r.get_json()["code"] == "qr_not_enabled"
    rz.fail_on[("POST", "/payments/qr_codes")] = app_module.RazorpayError("Razorpay request failed (500)", 500)
    r = _qr(client)
    assert r.status_code == 502 and "code" not in r.get_json()
    conn = database.get_db()
    assert conn.execute("SELECT COUNT(*) AS n FROM booking_payments").fetchone()["n"] == 0
    conn.close()


def test_qr_not_configured_or_mode_mismatch(client, rz, monkeypatch):
    _setup(client)
    monkeypatch.setattr(app_module, "RAZORPAY_KEY_SECRET", "")
    assert _qr(client).status_code == 503
    monkeypatch.setattr(app_module, "RAZORPAY_KEY_SECRET", SECRET)
    monkeypatch.setattr(app_module, "RAZORPAY_MODE", "live")
    assert _qr(client).status_code == 503
    assert rz.calls == []


def test_status_is_unpaid_until_razorpay_confirms(client, rz):
    cust, tech = _setup(client)
    _qr(client)
    s = _status(client).get_json()
    assert s["payment"]["status"] == "unpaid" and s["qr"]["status"] == "active"
    assert _row()["amount_paid_paise"] == 0


def test_captured_exact_amount_marks_paid_once(client, rz):
    cust, tech = _setup(client)
    qr = _qr(client).get_json()["qr"]
    rz.pay_qr(qr["qrId"], "pay_ok1", 100000)
    s = _status(client).get_json()
    assert s["payment"]["status"] == "paid" and s["payment"]["duePaise"] == 0 and s["payment"]["paidAt"]
    assert s["qr"]["status"] == "paid"
    row = _row()
    assert row["amount_paid_paise"] == 100000 and row["payment_method"] == "upi"
    for _ in range(3):                                   # refresh replays never double-credit
        assert _status(client).get_json()["payment"]["paidPaise"] == 100000
    assert _row()["amount_paid_paise"] == 100000
    assert _qr(client).status_code == 200 and len(rz.created()) == 1   # nothing more to collect


@pytest.mark.parametrize("override", [
    {"amount": 99999}, {"amount": 100001}, {"currency": "USD"}, {"status": "failed"},
    {"status": "created"}, {"status": "refunded"},
])
def test_wrong_amount_or_uncaptured_payment_never_marks_paid(client, rz, override):
    cust, tech = _setup(client)
    qr = _qr(client).get_json()["qr"]
    rz.pay_qr(qr["qrId"], "pay_bad", 100000)
    rz.payments["pay_bad"].update(override)
    s = _status(client).get_json()
    assert s["payment"]["status"] == "unpaid" and _row()["amount_paid_paise"] == 0
    assert s["qr"]["status"] == "active"


def test_authorized_payment_is_captured_for_the_exact_amount(client, rz):
    cust, tech = _setup(client)
    qr = _qr(client).get_json()["qr"]
    rz.pay_qr(qr["qrId"], "pay_auth", 100000, status="authorized")
    assert _status(client).get_json()["payment"]["status"] == "paid"
    cap, = [c for c in rz.calls if c[1].endswith("/capture")]
    assert cap[2] == {"amount": 100000, "currency": "INR"}


def test_one_payment_cannot_pay_two_bookings(client, rz):
    cust, tech = _setup(client)
    _booking(client, tech, cust, bid="BK2")
    qr1 = _qr(client, "BK1").get_json()["qr"]
    qr2 = _qr(client, "BK2").get_json()["qr"]
    rz.pay_qr(qr1["qrId"], "pay_same", 100000)
    assert _status(client, "BK1").get_json()["payment"]["status"] == "paid"
    rz.pay_qr(qr2["qrId"], "pay_same", 100000)           # same payment id replayed against another booking
    assert _status(client, "BK2").get_json()["payment"]["status"] == "unpaid"
    assert _row("BK2")["amount_paid_paise"] == 0


def test_payment_on_another_bookings_qr_does_not_credit_this_booking(client, rz):
    cust, tech = _setup(client)
    _booking(client, tech, cust, bid="BK2", total_rupees=2000)
    qr1 = _qr(client, "BK1").get_json()["qr"]
    _qr(client, "BK2")
    rz.pay_qr(qr1["qrId"], "pay_1", 100000)
    _status(client, "BK2")
    assert _row("BK2")["amount_paid_paise"] == 0
    assert _status(client, "BK1").get_json()["payment"]["status"] == "paid"


def test_technician_label_endpoint_cannot_mark_paid(client, rz):
    cust, tech = _setup(client)
    r = client.patch("/api/bookings/BK1/payment", json={"paymentMethod": "cash"}, headers=auth_headers("tech-token"))
    assert r.status_code == 200
    assert r.get_json()["payment"]["status"] == "unpaid"
    assert _row()["amount_paid_paise"] == 0


def test_razorpay_outage_during_refresh_leaves_unpaid_with_warning(client, rz):
    cust, tech = _setup(client)
    _qr(client)
    rz.fail = app_module.RazorpayError("Razorpay request failed (network)")
    s = _status(client)
    assert s.status_code == 200 and s.get_json()["payment"]["status"] == "unpaid" and s.get_json()["warning"]
    # and a new QR is NOT issued while we cannot check the existing one
    assert _qr(client).status_code == 502


def test_expired_qr_is_retired_and_a_fresh_one_issued(client, rz):
    cust, tech = _setup(client)
    first = _qr(client).get_json()["qr"]
    conn = database.get_db()
    conn.execute("UPDATE booking_payments SET created_at = '2020-01-01T00:00:00Z' WHERE kind = 'qr'")
    conn.commit()
    conn.close()
    assert _status(client).get_json()["qr"]["status"] == "expired"
    second = _qr(client)
    assert second.status_code == 201 and second.get_json()["qr"]["qrId"] != first["qrId"]


def test_customer_sees_only_their_own_payment_status(client, rz):
    cust, tech = _setup(client)
    qr = _qr(client).get_json()["qr"]
    other = register_and_login(client, email="bob@example.com", name="Bob", phone="9876500000")
    assert client.get("/api/bookings/BK1/payment", headers=auth_headers(other["token"])).status_code == 404
    assert client.get("/api/bookings/BK1/payment").status_code == 401
    mine = client.get("/api/bookings/BK1/payment", headers=auth_headers(cust["token"]))
    assert mine.status_code == 200 and "qr" not in mine.get_json()
    assert mine.get_json()["payment"]["duePaise"] == 100000
    rz.pay_qr(qr["qrId"], "pay_c1", 100000)           # customer refresh also confirms server-side
    assert client.get("/api/bookings/BK1/payment", headers=auth_headers(cust["token"])).get_json()["payment"]["status"] == "paid"


def test_booking_endpoints_expose_payment_summary(client, rz):
    cust, tech = _setup(client)
    one = client.get("/api/bookings/BK1", headers=auth_headers(cust["token"])).get_json()
    assert one["payment"]["mode"] == "pay_after_service" and one["payment"]["duePaise"] == 100000
    lst = client.get("/api/bookings", headers=auth_headers(cust["token"])).get_json()
    assert lst[0]["payment"]["duePaise"] == 100000
    mine = client.get("/api/technician/bookings", headers=auth_headers("tech-token")).get_json()
    assert mine[0]["payment"]["duePaise"] == 100000
