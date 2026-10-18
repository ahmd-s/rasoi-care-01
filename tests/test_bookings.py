import database
from conftest import register_and_login, auth_headers, add_technician


def _first_service_id(client):
    services = client.get("/api/services").get_json()
    return services[0]["id"]


def test_create_booking_requires_auth(client):
    resp = client.post("/api/bookings", json={"service_id": "x"})
    assert resp.status_code == 401


def test_create_booking_fails_with_no_technicians(client):
    user = register_and_login(client)
    service_id = _first_service_id(client)
    resp = client.post(
        "/api/bookings",
        json={"service_id": service_id},
        headers=auth_headers(user["token"]),
    )
    assert resp.status_code == 503


def test_create_booking_happy_path(client):
    conn = database.get_db()
    add_technician(conn)
    conn.close()

    user = register_and_login(client)
    service_id = _first_service_id(client)
    resp = client.post(
        "/api/bookings",
        json={"service_id": service_id},
        headers=auth_headers(user["token"]),
    )
    assert resp.status_code == 201, resp.get_json()
    body = resp.get_json()
    assert body["id"].startswith("RC-")
    assert body["status"] == "Requested"
    assert body["technicianId"] is None

    listing = client.get("/api/bookings", headers=auth_headers(user["token"])).get_json()
    assert len(listing) == 1
    assert listing[0]["id"] == body["id"]


def test_create_booking_rejects_unknown_service_id(client):
    conn = database.get_db()
    add_technician(conn)
    conn.close()

    user = register_and_login(client)
    resp = client.post(
        "/api/bookings",
        json={"service_id": "does-not-exist"},
        headers=auth_headers(user["token"]),
    )
    assert resp.status_code == 400


def test_bookings_isolated_between_customers(client):
    conn = database.get_db()
    add_technician(conn)
    conn.close()

    alice = register_and_login(client, email="alice2@example.com", phone="9876543211")
    bob = register_and_login(client, email="bob2@example.com", name="Bob", phone="9876543212")
    service_id = _first_service_id(client)

    client.post("/api/bookings", json={"service_id": service_id}, headers=auth_headers(alice["token"]))

    bob_bookings = client.get("/api/bookings", headers=auth_headers(bob["token"])).get_json()
    assert bob_bookings == []


OWNER_PHONE = "9822000002"
OWNER_PIN = "1234"


def _staff_headers(client):
    login = client.post("/api/staff/login", json={"phone": OWNER_PHONE, "pin": OWNER_PIN}).get_json()
    return auth_headers(login["token"])


def test_assign_technician_rejects_unverified_technician(client):
    conn = database.get_db()
    conn.execute(
        "INSERT INTO technicians (id, name, category, area, verified, online, rating, rating_count, jobs_completed) "
        "VALUES ('unverified-tech', 'Not Yet Verified', 'RasoiSpark', 'Test Area', 0, 0, 5.0, 0, 0)"
    )
    add_technician(conn)  # so a booking can be created at all
    conn.commit()
    conn.close()

    user = register_and_login(client)
    service_id = _first_service_id(client)
    booking = client.post(
        "/api/bookings", json={"service_id": service_id}, headers=auth_headers(user["token"])
    ).get_json()

    resp = client.patch(
        f"/api/bookings/{booking['id']}/assign",
        json={"technician_id": "unverified-tech"},
        headers=_staff_headers(client),
    )
    assert resp.status_code == 400


def test_assign_technician_rejects_reassigning_completed_booking(client):
    conn = database.get_db()
    add_technician(conn, tid="tech1")
    add_technician(conn, tid="tech2")
    conn.commit()
    conn.close()

    user = register_and_login(client)
    service_id = _first_service_id(client)
    booking = client.post(
        "/api/bookings", json={"service_id": service_id}, headers=auth_headers(user["token"])
    ).get_json()

    staff_headers = _staff_headers(client)
    client.patch(
        f"/api/bookings/{booking['id']}/assign",
        json={"technician_id": "tech1"},
        headers=staff_headers,
    )
    conn = database.get_db()
    conn.execute("UPDATE bookings SET status = 'Completed' WHERE id = ?", (booking["id"],))
    conn.commit()
    conn.close()

    resp = client.patch(
        f"/api/bookings/{booking['id']}/assign",
        json={"technician_id": "tech2"},
        headers=staff_headers,
    )
    assert resp.status_code == 400
