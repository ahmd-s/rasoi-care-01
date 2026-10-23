"""Razorpay checkout: server-side order creation, payment verification, and
the payment gates on booking/shop-order creation.

Razorpay itself is never called: `_razorpay_api` is replaced with an in-memory
fake and any real network use fails the test. The key values below are
obviously fake test strings, not credentials."""
import hashlib
import hmac
import json

import pytest

import app as app_module
import database
from conftest import add_payment_intent, add_technician, auth_headers, register_and_login

KEY_ID = "rzp_test_unit_test_key"
SECRET = "unit-test-secret-not-real"


class FakeRazorpay:
    """In-memory stand-in for the Razorpay REST API."""

    def __init__(self):
        self.calls = []
        self.orders = {}
        self.payments = {}
        self.fail = False
        self._n = 0

    def __call__(self, method, path, payload=None):
        self.calls.append((method, path, payload))
        if self.fail:
            raise RuntimeError("Razorpay request failed (500)")
        if (method, path) == ("POST", "/orders"):
            self._n += 1
            oid = f"order_fake{self._n:04d}"
            self.orders[oid] = dict(payload, id=oid)
            return {"id": oid, "amount": payload["amount"], "currency": payload["currency"]}
        if method == "GET" and path.startswith("/payments/"):
            return dict(self.payments[path.split("/")[2]])
        if method == "POST" and path.endswith("/capture"):
            pid = path.split("/")[2]
            assert payload["amount"] == self.payments[pid]["amount"]
            self.payments[pid]["status"] = "captured"
            return dict(self.payments[pid])
        raise AssertionError(f"unexpected Razorpay call {method} {path}")

    def add_payment(self, pid, order_id, amount, status="captured", currency="INR"):
        self.payments[pid] = {"id": pid, "order_id": order_id, "amount": amount,
                              "currency": currency, "status": status}


@pytest.fixture(autouse=True)
def rz(monkeypatch):
    fake = FakeRazorpay()
    monkeypatch.setattr(app_module, "RAZORPAY_KEY_ID", KEY_ID)
    monkeypatch.setattr(app_module, "RAZORPAY_KEY_SECRET", SECRET)
    monkeypatch.setattr(app_module, "RAZORPAY_MODE", "test")
    monkeypatch.setattr(app_module, "_razorpay_api", fake)

    def no_network(*a, **k):
        raise AssertionError("tests must not make real network calls")

    monkeypatch.setattr(app_module.urllib.request, "urlopen", no_network)
    return fake


def sign(order_id, payment_id, secret=SECRET):
    return hmac.new(secret.encode(), f"{order_id}|{payment_id}".encode(), hashlib.sha256).hexdigest()


def _customer(client, email="alice@example.com", phone="9876543210"):
    c = register_and_login(client, email=email, phone=phone)
    return c, auth_headers(c["token"])


def _service(client):
    s = client.get("/api/services").get_json()[0]
    return s["id"], s["category"]


def _technician():
    conn = database.get_db()
    add_technician(conn)
    conn.commit()
    conn.close()


def _count(table):
    conn = database.get_db()
    n = conn.execute(f"SELECT COUNT(*) AS n FROM {table}").fetchone()["n"]
    conn.close()
    return n


def _intent(order_id):
    conn = database.get_db()
    row = conn.execute("SELECT * FROM razorpay_payment_intents WHERE order_id = ?", (order_id,)).fetchone()
    conn.close()
    return row


SHOP = [{"productId": "chimney_kit", "qty": 2}]
SHOP_TOTAL = 2 * app_module.SHOP_PRODUCTS["chimney_kit"]["price_paise"]


# ------------------------------------------------------------ order creation
def test_order_requires_auth(client):
    assert client.post("/api/payments/razorpay/order", json={"shopItems": SHOP}).status_code == 401


def test_order_not_configured_is_503(client, monkeypatch, rz):
    _, h = _customer(client)
    monkeypatch.setattr(app_module, "RAZORPAY_KEY_SECRET", "")
    r = client.post("/api/payments/razorpay/order", json={"shopItems": SHOP}, headers=h)
    assert r.status_code == 503 and rz.calls == []


@pytest.mark.parametrize("mode,key", [("live", "rzp_test_x"), ("test", "rzp_live_x"), ("staging", "rzp_test_x")])
def test_order_refuses_mode_key_mismatch(client, monkeypatch, rz, mode, key):
    _, h = _customer(client)
    monkeypatch.setattr(app_module, "RAZORPAY_MODE", mode)
    monkeypatch.setattr(app_module, "RAZORPAY_KEY_ID", key)
    r = client.post("/api/payments/razorpay/order", json={"shopItems": SHOP}, headers=h)
    assert r.status_code == 503 and rz.calls == []


@pytest.mark.parametrize("body", [
    {}, {"shopItems": []}, {"shopItems": SHOP, "useCoins": True},
    {"serviceIds": ["x"]},                                  # services without booking details
    {"shopItems": SHOP, "booking": {"area": "Home"}},       # booking details without services
    {"shopItems": [{"productId": "nope", "qty": 1}]},
    {"shopItems": [{"productId": "chimney_kit", "qty": 0}]},
    {"shopItems": [{"productId": "chimney_kit", "qty": 51}]},
    {"shopItems": [{"productId": "chimney_kit", "qty": 1}, {"productId": "chimney_kit", "qty": 1}]},
])
def test_order_rejects_bad_carts(client, rz, body):
    _, h = _customer(client)
    r = client.post("/api/payments/razorpay/order", json=body, headers=h)
    assert r.status_code == 400
    assert rz.calls == [] and _count("razorpay_payment_intents") == 0


def test_order_unknown_service_is_400(client, rz):
    _technician()
    _, h = _customer(client)
    r = client.post("/api/payments/razorpay/order",
                    json={"serviceIds": ["nope"], "booking": {"area": "Home"}}, headers=h)
    assert r.status_code == 400 and rz.calls == []


def test_order_is_priced_server_side_and_never_exposes_secret(client, rz):
    c, h = _customer(client)
    r = client.post("/api/payments/razorpay/order",
                    json={"shopItems": SHOP, "amount": 1, "amountPaise": 1, "total": 1}, headers=h)
    assert r.status_code == 201
    body = r.get_json()
    assert body["amount"] == SHOP_TOTAL and body["currency"] == "INR"
    assert body["keyId"] == KEY_ID and SECRET not in r.get_data(as_text=True)
    (method, path, payload), = rz.calls
    assert (method, path) == ("POST", "/orders") and payload["amount"] == SHOP_TOTAL
    row = _intent(body["orderId"])
    assert row["status"] == "created" and row["user_id"] == c["user"]["id"]
    assert row["amount_paise"] == SHOP_TOTAL


def test_order_with_services_uses_server_catalog_price(client, rz):
    _technician()
    sid, _ = _service(client)
    _, h = _customer(client)
    r = client.post("/api/payments/razorpay/order", json={
        "serviceIds": [sid], "booking": {"area": "Home", "addressLine": "Gangapur Road"}, "amount": 1,
    }, headers=h)
    assert r.status_code == 201
    price = client.get("/api/services").get_json()[0]["price"]
    before_gst = price + app_module.CART_VISIT_FEE
    total = before_gst - (app_module.CART_COUPON_DISCOUNT if before_gst > app_module.CART_COUPON_THRESHOLD else 0)
    total += round(total * app_module.CART_GST_RATE)
    assert r.get_json()["amount"] == total * 100


def test_order_razorpay_failure_is_502_and_stores_nothing(client, rz):
    _, h = _customer(client)
    rz.fail = True
    r = client.post("/api/payments/razorpay/order", json={"shopItems": SHOP}, headers=h)
    assert r.status_code == 502 and _count("razorpay_payment_intents") == 0


# ------------------------------------------------------------ verification
def _start(client, h, items=SHOP):
    r = client.post("/api/payments/razorpay/order", json={"shopItems": items}, headers=h)
    assert r.status_code == 201
    return r.get_json()


def _verify(client, h, order_id, payment_id="pay_fake0001", signature=None):
    return client.post("/api/payments/razorpay/verify", headers=h, json={
        "orderId": order_id, "paymentId": payment_id,
        "signature": sign(order_id, payment_id) if signature is None else signature})


def test_verify_requires_auth_and_fields(client):
    assert client.post("/api/payments/razorpay/verify", json={}).status_code == 401
    _, h = _customer(client)
    assert client.post("/api/payments/razorpay/verify", json={"orderId": "o"}, headers=h).status_code == 400


def test_verify_unknown_order_is_404(client):
    _, h = _customer(client)
    assert _verify(client, h, "order_missing").status_code == 404


def test_verify_other_customers_order_is_404(client, rz):
    _, h1 = _customer(client)
    _, h2 = _customer(client, email="bob@example.com", phone="9876500000")
    order = _start(client, h1)
    rz.add_payment("pay_fake0001", order["orderId"], order["amount"])
    assert _verify(client, h2, order["orderId"]).status_code == 404
    assert _count("shop_orders") == 0


@pytest.mark.parametrize("signature", ["", "0" * 64, "not-a-signature"])
def test_verify_bad_signature_places_nothing(client, rz, signature):
    _, h = _customer(client)
    order = _start(client, h)
    rz.add_payment("pay_fake0001", order["orderId"], order["amount"])
    r = _verify(client, h, order["orderId"], signature=signature or "x")
    assert r.status_code == 400
    assert _count("shop_orders") == 0 and _intent(order["orderId"])["status"] == "created"
    assert not any(c[0] == "GET" for c in rz.calls)  # rejected before asking Razorpay


def test_verify_signature_from_wrong_secret_is_rejected(client, rz):
    _, h = _customer(client)
    order = _start(client, h)
    rz.add_payment("pay_fake0001", order["orderId"], order["amount"])
    r = _verify(client, h, order["orderId"], signature=sign(order["orderId"], "pay_fake0001", secret="other"))
    assert r.status_code == 400 and _count("shop_orders") == 0


@pytest.mark.parametrize("override", [
    {"status": "created"}, {"status": "failed"}, {"status": "refunded"},
    {"amount": 100}, {"currency": "USD"}, {"order_id": "order_someone_else"},
])
def test_verify_requires_captured_matching_payment(client, rz, override):
    _, h = _customer(client)
    order = _start(client, h)
    rz.add_payment("pay_fake0001", order["orderId"], order["amount"])
    rz.payments["pay_fake0001"].update(override)
    r = _verify(client, h, order["orderId"])
    assert r.status_code == 402
    assert _count("shop_orders") == 0 and _intent(order["orderId"])["status"] == "created"


def test_verify_razorpay_outage_is_502_and_places_nothing(client, rz):
    _, h = _customer(client)
    order = _start(client, h)
    rz.fail = True
    assert _verify(client, h, order["orderId"]).status_code == 502
    assert _count("shop_orders") == 0


def test_verify_captured_shop_payment_places_exactly_one_order(client, rz):
    c, h = _customer(client)
    order = _start(client, h)
    rz.add_payment("pay_fake0001", order["orderId"], order["amount"])
    r = _verify(client, h, order["orderId"])
    assert r.status_code == 200
    assert r.get_json()["paymentId"] == "pay_fake0001" and r.get_json()["shopOrder"]["totalPaise"] == SHOP_TOTAL
    conn = database.get_db()
    row = conn.execute("SELECT * FROM shop_orders").fetchone()
    conn.close()
    assert row["payment_order_id"] == order["orderId"] and row["user_id"] == c["user"]["id"]
    assert _intent(order["orderId"])["status"] == "complete"

    # Replay: same response, nothing duplicated, no second capture.
    again = _verify(client, h, order["orderId"])
    assert again.status_code == 200 and again.get_json() == r.get_json()
    assert _count("shop_orders") == 1
    # A different payment id can't claim the already-completed order.
    assert _verify(client, h, order["orderId"], payment_id="pay_other").status_code == 409


def test_verify_captures_an_authorized_payment_for_the_exact_amount(client, rz):
    _, h = _customer(client)
    order = _start(client, h)
    rz.add_payment("pay_fake0001", order["orderId"], order["amount"], status="authorized")
    assert _verify(client, h, order["orderId"]).status_code == 200
    captures = [c for c in rz.calls if c[1].endswith("/capture")]
    assert len(captures) == 1 and captures[0][2] == {"amount": SHOP_TOTAL, "currency": "INR"}


def test_verify_captured_service_payment_creates_one_booking(client, rz):
    _technician()
    sid, _ = _service(client)
    c, h = _customer(client)
    r = client.post("/api/payments/razorpay/order", json={
        "serviceIds": [sid], "booking": {"area": "Home", "addressLine": "Gangapur Road, Nashik"},
    }, headers=h)
    order = r.get_json()
    rz.add_payment("pay_fake0001", order["orderId"], order["amount"])
    v = _verify(client, h, order["orderId"])
    assert v.status_code == 200, v.get_json()
    bookings = v.get_json()["bookings"]
    assert len(bookings) == 1 and bookings[0]["id"].startswith("RC-")
    assert _verify(client, h, order["orderId"]).get_json() == v.get_json()
    assert _count("bookings") == 1


# ------------------------------------------- payment gates on direct creation
def test_cart_requires_a_captured_matching_payment(client):
    _technician()
    sid, _ = _service(client)
    c, h = _customer(client)
    other, h2 = _customer(client, email="bob@example.com", phone="9876500000")
    uid = c["user"]["id"]
    body = {"serviceIds": [sid], "useCoins": False, "area": "Home"}

    def post(order_id=None, payload=body, headers=h):
        hh = dict(headers, **({"X-Razorpay-Order-Id": order_id} if order_id else {}))
        return client.post("/api/bookings/cart", json=payload, headers=hh)

    assert post().status_code == 402                                    # no payment reference
    assert post("order_unknown").status_code == 402                     # unknown order
    unpaid = add_payment_intent(uid, [sid], {"area": "Home"}, status="created")
    assert post(unpaid).status_code == 402                              # not captured yet
    theirs = add_payment_intent(other["user"]["id"], [sid], {"area": "Home"})
    assert post(theirs).status_code == 402                              # someone else's payment
    paid = add_payment_intent(uid, [sid], {"area": "Home"})
    assert post(paid, {**body, "area": "Office"}).status_code == 409    # booking details tampered
    assert post(paid, {**body, "serviceIds": ["other"]}).status_code == 409   # services tampered
    assert post(paid, {**body, "useCoins": True}).status_code == 409    # coins not allowed
    assert post(paid, {**body, "notes": "extra"}).status_code == 409    # extra field not paid for
    assert _count("bookings") == 0
    assert post(paid).status_code == 201 and _count("bookings") == 1


def test_shop_order_requires_a_captured_matching_payment(client):
    c, h = _customer(client)
    other, _ = _customer(client, email="bob@example.com", phone="9876500000")
    uid = c["user"]["id"]

    def post(order_id=None, items=SHOP):
        body = {"items": items}
        if order_id:
            body["paymentOrderId"] = order_id
        return client.post("/api/shop/orders", json=body, headers=h)

    assert post().status_code == 402
    assert post("order_unknown").status_code == 402
    assert post(add_payment_intent(uid, shop_items=SHOP, status="created")).status_code == 402
    assert post(add_payment_intent(other["user"]["id"], shop_items=SHOP)).status_code == 402
    paid = add_payment_intent(uid, shop_items=SHOP)
    assert post(paid, [{"productId": "chimney_kit", "qty": 1}]).status_code == 409   # fewer than paid
    assert post(paid, [{"productId": "cooktop_kit", "qty": 2}]).status_code == 409   # different product
    assert _count("shop_orders") == 0
    first = post(paid)
    assert first.status_code == 201
    assert post(paid).get_json() == first.get_json() and _count("shop_orders") == 1   # replay-safe


def test_database_enforces_one_shop_order_per_payment(client):
    c, _ = _customer(client)
    conn = database.get_db()
    ts = database.now()
    conn.execute("INSERT INTO shop_orders (id, user_id, items_json, total_paise, status, created_at, payment_order_id) "
                 "VALUES ('S1', ?, '[]', 1, 'Placed', ?, 'order_dup')", (c["user"]["id"], ts))
    with pytest.raises(Exception):
        conn.execute("INSERT INTO shop_orders (id, user_id, items_json, total_paise, status, created_at, payment_order_id) "
                     "VALUES ('S2', ?, '[]', 1, 'Placed', ?, 'order_dup')", (c["user"]["id"], ts))
    conn.close()
