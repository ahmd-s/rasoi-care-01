import database
from conftest import add_technician, auth_headers

OWNER_PHONE = "9822000002"
OWNER_PIN = "1234"


def _staff_headers(client):
    login = client.post("/api/staff/login", json={"phone": OWNER_PHONE, "pin": OWNER_PIN}).get_json()
    return auth_headers(login["token"])


def test_list_technicians_redacts_document_urls(client):
    conn = database.get_db()
    add_technician(conn)
    conn.execute(
        "UPDATE technicians SET aadhar_document_url = 'https://firebasestorage.googleapis.com/x' WHERE id = 'tech1'"
    )
    conn.commit()
    conn.close()

    resp = client.get("/api/technicians", headers=_staff_headers(client))
    assert resp.status_code == 200
    tech = resp.get_json()[0]
    assert tech["aadharDocumentUrl"] is None
    assert tech["aadharDocumentReady"] is True


def test_technician_document_rejects_untrusted_host(client):
    conn = database.get_db()
    add_technician(conn)
    conn.execute(
        "UPDATE technicians SET aadhar_document_url = 'https://evil.example.com/steal' WHERE id = 'tech1'"
    )
    conn.commit()
    conn.close()

    resp = client.get("/api/technicians/tech1/document/aadhar-front", headers=_staff_headers(client))
    assert resp.status_code == 502


def test_technician_document_404s_when_not_uploaded(client):
    conn = database.get_db()
    add_technician(conn)
    conn.close()

    resp = client.get("/api/technicians/tech1/document/pan", headers=_staff_headers(client))
    assert resp.status_code == 404


def test_technician_document_requires_staff_auth(client):
    conn = database.get_db()
    add_technician(conn)
    conn.close()

    resp = client.get("/api/technicians/tech1/document/pan")
    assert resp.status_code == 401
