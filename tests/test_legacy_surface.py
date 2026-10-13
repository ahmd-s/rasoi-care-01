"""P1-14 tests — the ENABLE_LEGACY_WEB kill-switch.

Default (unset / anything but "0"): the six legacy HTML consoles keep
serving exactly as before (the rasoi_web_* WebView stubs load /customer
and /technician from this backend, so defaulting off would break shipped
APKs). ENABLE_LEGACY_WEB=0 turns them into JSON 404s while /terms,
/privacy and /api routes are untouched.
"""
import app as app_module


def test_legacy_pages_served_by_default(client):
    for path in ("/", "/customer", "/technician", "/admin", "/smiler", "/homeservices"):
        resp = client.get(path)
        assert resp.status_code == 200, (path, resp.status_code)
        assert b"<html" in resp.data.lower(), path


def test_legal_and_api_routes_unaffected_by_default(client):
    assert client.get("/terms").status_code == 200
    assert client.get("/privacy").status_code == 200
    assert client.get("/api/services").status_code == 200


def test_legacy_pages_404_when_disabled(client, monkeypatch):
    monkeypatch.setattr(app_module, "_ENABLE_LEGACY_WEB", False)
    for path in ("/", "/customer", "/technician", "/admin", "/smiler", "/homeservices"):
        resp = client.get(path)
        assert resp.status_code == 404, (path, resp.status_code)
        assert resp.get_json()["error"] == "Not Found"


def test_legal_and_api_survive_when_legacy_disabled(client, monkeypatch):
    monkeypatch.setattr(app_module, "_ENABLE_LEGACY_WEB", False)
    assert client.get("/terms").status_code == 200
    assert client.get("/privacy").status_code == 200
    assert client.get("/api/services").status_code == 200
    assert client.get("/api/health").status_code == 200
