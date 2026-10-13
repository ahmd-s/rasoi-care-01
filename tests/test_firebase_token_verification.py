"""P1-10 (c) — regression tests for the REAL verify_firebase_token.

conftest's mock_firebase_claims monkeypatches verify_firebase_token away
entirely, so the signature/audience/issuer/expiry checks had NO coverage —
this file exercises the actual function with self-generated RS256 tokens
and a monkeypatched Google-certs endpoint, asserting it fails closed on
every forgery path and never returns claims for a bad token.
"""
import time
from datetime import datetime, timedelta, timezone

import jwt as pyjwt
import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

import app as app_module

PROJECT = app_module.FIREBASE_PROJECT_ID


@pytest.fixture(scope="module")
def keypair():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = issuer = x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, "fakesecuretoken.googleapis.com"),
    ])
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(datetime.now(timezone.utc) - timedelta(hours=1))
        .not_valid_after(datetime.now(timezone.utc) + timedelta(hours=1))
        .sign(key, hashes.SHA256())
    )
    pem = cert.public_bytes(serialization.Encoding.PEM).decode("ascii")
    priv = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode("ascii")
    return {"kid": "test-key-1", "cert_pem": pem, "private_key": priv}


@pytest.fixture()
def fake_certs(monkeypatch, keypair):
    monkeypatch.setattr(
        app_module, "_get_firebase_certs", lambda: {keypair["kid"]: keypair["cert_pem"]}
    )


def _token(keypair, **overrides):
    now = int(time.time())
    payload = {
        "iss": f"https://securetoken.google.com/{PROJECT}",
        "aud": PROJECT,
        "sub": "real-firebase-uid-123",
        "user_id": "real-firebase-uid-123",
        "email": "person@example.com",
        "email_verified": True,
        "iat": now - 10,
        "exp": now + 900,
    }
    payload.update(overrides)
    return pyjwt.encode(payload, keypair["private_key"], algorithm="RS256",
                        headers={"kid": keypair["kid"], "alg": "RS256"})


def test_valid_token_verifies(fake_certs, keypair):
    claims = app_module.verify_firebase_token(_token(keypair))
    assert claims is not None
    assert claims["uid"] == "real-firebase-uid-123"
    assert claims["email"] == "person@example.com"
    assert claims["email_verified"] is True


def test_expired_token_rejected(fake_certs, keypair):
    now = int(time.time())
    token = _token(keypair, iat=now - 7200, exp=now - 3600)  # expired 1h ago
    assert app_module.verify_firebase_token(token) is None


def test_wrong_audience_rejected(fake_certs, keypair):
    token = _token(keypair, aud="some-other-firebase-project")
    assert app_module.verify_firebase_token(token) is None


def test_wrong_issuer_rejected(fake_certs, keypair):
    token = _token(keypair, iss="https://evil.example.com/")
    assert app_module.verify_firebase_token(token) is None


def test_signed_by_unknown_key_rejected(fake_certs, keypair):
    # signed with a DIFFERENT key than the one the (faked) Google certs serve
    other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    other_priv = other.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode("ascii")
    now = int(time.time())
    payload = {
        "iss": f"https://securetoken.google.com/{PROJECT}", "aud": PROJECT,
        "sub": "attacker-uid", "user_id": "attacker-uid",
        "iat": now - 10, "exp": now + 900,
    }
    token = pyjwt.encode(payload, other_priv, algorithm="RS256",
                         headers={"kid": keypair["kid"], "alg": "RS256"})
    assert app_module.verify_firebase_token(token) is None


def test_unknown_kid_rejected(fake_certs, keypair):
    # valid signature, but the header kid isn't in the certs Google serves
    now = int(time.time())
    payload = {
        "iss": f"https://securetoken.google.com/{PROJECT}", "aud": PROJECT,
        "sub": "u", "user_id": "u", "iat": now - 10, "exp": now + 900,
    }
    forged = pyjwt.encode(payload, keypair["private_key"], algorithm="RS256",
                          headers={"kid": "attacker-generated-kid", "alg": "RS256"})
    assert app_module.verify_firebase_token(forged) is None


def test_alg_confusion_none_rejected(fake_certs, keypair):
    now = int(time.time())
    payload = {
        "iss": f"https://securetoken.google.com/{PROJECT}", "aud": PROJECT,
        "sub": "u", "user_id": "u", "iat": now - 10, "exp": now + 900,
    }
    unverified = pyjwt.encode(payload, key=None, algorithm="none",
                              headers={"kid": keypair["kid"], "alg": "none"})
    assert app_module.verify_firebase_token(unverified) is None


def test_garbage_token_rejected(fake_certs):
    assert app_module.verify_firebase_token("not-a-jwt") is None
    assert app_module.verify_firebase_token("") is None
    assert app_module.verify_firebase_token(None) is None
    assert app_module.verify_firebase_token("aaa.bbb.ccc") is None


def test_token_without_sub_rejected(fake_certs, keypair):
    now = int(time.time())
    payload = {
        "iss": f"https://securetoken.google.com/{PROJECT}", "aud": PROJECT,
        "iat": now - 10, "exp": now + 900,
    }
    token = pyjwt.encode(payload, keypair["private_key"], algorithm="RS256",
                         headers={"kid": keypair["kid"], "alg": "RS256"})
    assert app_module.verify_firebase_token(token) is None


def test_missing_certs_fails_closed(monkeypatch, keypair):
    # network/cert-fetch failure must reject, never verify
    monkeypatch.setattr(app_module, "_get_firebase_certs", lambda: None)
    assert app_module.verify_firebase_token(_token(keypair)) is None


def test_rejection_is_logged_not_silent(fake_certs, keypair, capsys):
    capsys.readouterr()
    app_module.verify_firebase_token(_token(keypair, aud="wrong-project"))
    err = capsys.readouterr().err
    assert "verify_firebase_token" in err, "every rejection must be logged"


def test_rejected_token_cannot_authenticate_any_endpoint(client, fake_certs, keypair):
    """End-to-end: a structurally-valid but wrongly-signed token must not
    grant any customer identity — the bootstrap endpoint stays 401."""
    other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    priv = other.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode("ascii")
    now = int(time.time())
    payload = {
        "iss": f"https://securetoken.google.com/{PROJECT}", "aud": PROJECT,
        "sub": "attacker", "user_id": "attacker", "email": "attacker@example.com",
        "email_verified": True, "iat": now - 10, "exp": now + 900,
    }
    token = pyjwt.encode(payload, priv, algorithm="RS256",
                         headers={"kid": keypair["kid"], "alg": "RS256"})
    resp = client.post("/api/staff/bootstrap", json={},
                       headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 401
