"""October catalogue migration: Steam deep clean + three approved prices.

Runs once (tracked in schema_migrations), changes only the approved prices,
and never resets an admin edit made after it has been applied.
"""
import database

VERSION = "customer_catalog_steam_and_prices_2026_10"


def _price(conn, sid):
    return conn.execute("SELECT price FROM services WHERE id = ?", (sid,)).fetchone()["price"]


def test_fresh_db_has_new_catalogue(client):
    conn = database.get_db()
    try:
        assert _price(conn, "svc_chimney_steam_deep_clean") == 1299
        assert _price(conn, "svc_chimney_deep_clean_full") == 1699
        assert _price(conn, "svc_hob_install") == 499
        assert _price(conn, "svc_hob_uninstall") == 299
        assert conn.execute("SELECT COUNT(*) AS n FROM schema_migrations WHERE version = ?",
                            (VERSION,)).fetchone()["n"] == 1
    finally:
        conn.close()


def test_existing_db_upgraded_once_and_admin_edits_survive(client):
    conn = database.get_db()
    try:
        # Simulate a staging DB seeded before this release.
        conn.execute("DELETE FROM schema_migrations WHERE version = ?", (VERSION,))
        conn.execute("DELETE FROM services WHERE id = 'svc_chimney_steam_deep_clean'")
        for sid, old in (("svc_chimney_deep_clean_full", 1599), ("svc_hob_install", 699),
                         ("svc_hob_uninstall", 399)):
            conn.execute("UPDATE services SET price = ? WHERE id = ?", (old, sid))
        before_other = _price(conn, "svc_chimney_install")
        conn.commit()
    finally:
        conn.close()

    database.init_db()
    conn = database.get_db()
    try:
        assert _price(conn, "svc_chimney_steam_deep_clean") == 1299
        assert _price(conn, "svc_chimney_deep_clean_full") == 1699
        assert _price(conn, "svc_hob_install") == 499
        assert _price(conn, "svc_hob_uninstall") == 299
        assert _price(conn, "svc_chimney_install") == before_other
        # A later admin edit must survive further boots.
        conn.execute("UPDATE services SET price = 1750 WHERE id = 'svc_chimney_deep_clean_full'")
        conn.commit()
    finally:
        conn.close()

    database.init_db()
    database.init_db()
    conn = database.get_db()
    try:
        assert _price(conn, "svc_chimney_deep_clean_full") == 1750
        assert conn.execute("SELECT COUNT(*) AS n FROM schema_migrations WHERE version = ?",
                            (VERSION,)).fetchone()["n"] == 1
    finally:
        conn.close()


def test_chimney_list_puts_steam_first(client):
    rows = client.get("/api/services?appliance=app_chimney").get_json()
    assert rows[0]["name"] == "Steam deep clean"
    assert any(r["name"].startswith("Deep clean") and r["price"] == 1699 for r in rows)


def test_customer_app_prices_match_server_catalogue(client):
    """Every service the Customer app lists (MockRepository) must carry the
    same price on the server, or cart/booking price checks would disagree."""
    import pathlib
    import re
    src = pathlib.Path(__file__).resolve().parent.parent / "careplus_flutter/lib/data/mock_repository.dart"
    text = src.read_text()
    pairs = re.findall(r"id: '(svc_[a-z0-9_]+)'.*?pricePaise: (\d+),", text, flags=re.S)
    assert len(pairs) == text.count("id: 'svc_")
    conn = database.get_db()
    try:
        for sid, paise in pairs:
            row = conn.execute("SELECT price FROM services WHERE id = ?", (sid,)).fetchone()
            assert row is not None, f"{sid} missing on server"
            assert row["price"] * 100 == int(paise), f"{sid}: app {paise} vs server {row['price']}"
    finally:
        conn.close()
