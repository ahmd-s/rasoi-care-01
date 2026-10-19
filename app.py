"""
RasoiCare backend — real Flask REST API.

This is the server all three apps (Customer, Technician, Admin) call
over HTTP. Run it locally with `python3 app.py`, or deploy it (see
README.md) to get a public URL so it can be reached from real,
separate devices.
"""

import os
import base64
import json
import re
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from collections import OrderedDict, defaultdict, deque
from datetime import datetime, timedelta, timezone
from functools import wraps
from threading import Lock

import jwt
from flask import Flask, request, jsonify, send_from_directory, Response
from werkzeug.security import generate_password_hash, check_password_hash
import database
import kitchen_health
import kitchen_passport
import ai_review
import vision_guardrails
import vision_images
import vision_jobs
import vision_provider
from database import get_db, init_db, next_id, now, new_uuid_id

# ---------------------------------------------------------------- worker mode
# This process keeps real security state in memory: the sliding-window rate
# limiters, the auth backoff counters, and the cancellation OTP codes (see
# the rate-limit section below). With more than one worker process, each
# keeps its own private copy of that state — an attacker's attempts get
# counted (and their OTPs issued) in worker A while verification lands in
# worker B, so limits stop limiting and OTPs stop verifying. Procfile and
# render.yaml therefore pin gunicorn to `--workers 1 --threads 1`, which is
# exactly what gunicorn's own defaults already were — the flags just make
# the constraint explicit and impossible to change by accident in the
# deploy config. Scaling past one worker is a deliberate project: move that
# state to a shared store (Redis/DB) FIRST, then raise this.
# gunicorn also honours the WEB_CONCURRENCY env var where present; warn
# loudly if anything tries to raise it without the shared-state work done.
_web_concurrency = (os.environ.get("WEB_CONCURRENCY") or "").strip()
if _web_concurrency and _web_concurrency != "1":
    print(
        f"WARNING: WEB_CONCURRENCY={_web_concurrency} but this app keeps rate-limit, "
        "auth-backoff and OTP state in process memory — multi-worker deploys make "
        "those limits unenforceable. Run exactly one worker until that state moves "
        "to a shared store.",
        file=sys.stderr,
    )


app = Flask(__name__)
FRONTEND_DIR = os.path.dirname(os.path.abspath(__file__))
# The largest legitimate request body is a base64 job photo (validate_json
# caps dataBase64 at 12_000_000 chars there) — 16MB leaves headroom for the
# JSON envelope around it. Without this, Flask buffers a request body of
# any size in memory before validate_json ever gets a chance to reject it,
# which on the single-worker deployment this runs on is a plausible
# memory-exhaustion DoS from just a handful of oversized concurrent
# requests.
app.config["MAX_CONTENT_LENGTH"] = 16 * 1024 * 1024


@app.errorhandler(413)
def _request_too_large(_e):
    return jsonify({"error": "Payload Too Large", "message": "Request body is too large."}), 413


# ---------------------------------------------------------------- rate limiting
# Three tiers, each with its own configurable thresholds (env vars below, all
# with sane defaults so nothing needs to be set to run locally):
#
#   AUTH          — login/signup: the routes a brute-force script actually
#                   targets. Combines a per-account AND a per-IP check so
#                   neither "guess one account's password from many IPs" nor
#                   "spray many accounts from one IP" dodges the limit. Uses
#                   exponential backoff (each wrong attempt doubles the wait
#                   before the next one is even accepted) rather than a hard
#                   lockout — a real account owner who mistypes their
#                   password a couple of times is barely slowed down, but a
#                   scripted guesser hits a wait that grows towards
#                   unusable within a handful of attempts. A correct
#                   attempt resets the count immediately, so it's never a
#                   lasting lockout tied to a fixed clock window.
#   PUBLIC        — read-only, unauthenticated informational endpoints
#                   (legal docs, catalog, health check). Moderate: enough
#                   headroom that a real client never notices, still a
#                   real ceiling against scraping/spam.
#   AUTHENTICATED — everything gated behind an existing require_*_auth
#                   decorator (a real signed-in customer/technician/staff
#                   member acting on their own account). Loosest of the
#                   three, and keyed per-account rather than per-IP — a
#                   request that already proved who it is shouldn't compete
#                   for one shared limit with everyone else behind the same
#                   office Wi-Fi/mobile-carrier NAT.
#
# In-memory — no extra dependency (Flask-Limiter) or shared store (Redis)
# needed: this deploys as a single gunicorn worker (see Procfile/render.yaml,
# no --workers flag), so one process's memory *is* the whole app's state.
# Won't survive a restart and wouldn't be enough on a multi-worker/
# multi-instance deploy, but is a real, meaningful brake on a scripted
# brute-force or spam attempt against the current deployment.


def _env_int(name, default):
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


def _env_float(name, default):
    try:
        return float(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


LIST_PAGE_DEFAULT_LIMIT = _env_int("LIST_PAGE_DEFAULT_LIMIT", 500)
LIST_PAGE_MAX_LIMIT = _env_int("LIST_PAGE_MAX_LIMIT", 2000)


def _pagination_args():
    """(limit, offset) for a staff-only list endpoint, from optional
    `?limit=&offset=` query params — bounded so a client can't force an
    unbounded SELECT * by asking for everything at once. Malformed values
    fall back to the default rather than erroring, since these are just an
    optional refinement on an otherwise-working request."""
    try:
        limit = int(request.args.get("limit", LIST_PAGE_DEFAULT_LIMIT))
    except (TypeError, ValueError):
        limit = LIST_PAGE_DEFAULT_LIMIT
    limit = max(1, min(limit, LIST_PAGE_MAX_LIMIT))
    try:
        offset = int(request.args.get("offset", 0))
    except (TypeError, ValueError):
        offset = 0
    return limit, max(0, offset)


RATE_LIMIT_GLOBAL_MAX_CALLS = _env_int("RATE_LIMIT_GLOBAL_MAX_CALLS", 180)
RATE_LIMIT_GLOBAL_WINDOW_SECONDS = _env_int("RATE_LIMIT_GLOBAL_WINDOW_SECONDS", 60)

RATE_LIMIT_PUBLIC_MAX_CALLS = _env_int("RATE_LIMIT_PUBLIC_MAX_CALLS", 60)
RATE_LIMIT_PUBLIC_WINDOW_SECONDS = _env_int("RATE_LIMIT_PUBLIC_WINDOW_SECONDS", 60)

RATE_LIMIT_AUTHENTICATED_MAX_CALLS = _env_int("RATE_LIMIT_AUTHENTICATED_MAX_CALLS", 120)
RATE_LIMIT_AUTHENTICATED_WINDOW_SECONDS = _env_int("RATE_LIMIT_AUTHENTICATED_WINDOW_SECONDS", 60)

# Auth tier: an account (or IP) gets this many attempts before backoff kicks
# in at all, then each further attempt's wait doubles — base, base*2,
# base*4, ... — capped at max. Recorded separately per-account and per-IP
# (see _auth_gate/_auth_gate_record) so either axis alone is enough to slow
# an attacker down.
RATE_LIMIT_AUTH_ACCOUNT_FREE_ATTEMPTS = _env_int("RATE_LIMIT_AUTH_ACCOUNT_FREE_ATTEMPTS", 5)
RATE_LIMIT_AUTH_ACCOUNT_BACKOFF_BASE_SECONDS = _env_int("RATE_LIMIT_AUTH_ACCOUNT_BACKOFF_BASE_SECONDS", 2)
RATE_LIMIT_AUTH_ACCOUNT_BACKOFF_MAX_SECONDS = _env_int("RATE_LIMIT_AUTH_ACCOUNT_BACKOFF_MAX_SECONDS", 900)

RATE_LIMIT_AUTH_IP_FREE_ATTEMPTS = _env_int("RATE_LIMIT_AUTH_IP_FREE_ATTEMPTS", 15)
RATE_LIMIT_AUTH_IP_BACKOFF_BASE_SECONDS = _env_int("RATE_LIMIT_AUTH_IP_BACKOFF_BASE_SECONDS", 2)
RATE_LIMIT_AUTH_IP_BACKOFF_MAX_SECONDS = _env_int("RATE_LIMIT_AUTH_IP_BACKOFF_MAX_SECONDS", 900)

# Booking-cancellation OTP — an extra SMS-verified confirmation step before
# PATCH /api/bookings/<id>/cancel takes effect (see request_cancel_otp/
# cancel_booking below), since a real job — and any technician cancellation
# fee — can't be undone. Codes live only in memory: short-lived by design,
# and losing them on a restart just means a customer requests a fresh one.
CANCEL_OTP_TTL_SECONDS = _env_int("CANCEL_OTP_TTL_SECONDS", 300)
CANCEL_OTP_MAX_ATTEMPTS = _env_int("CANCEL_OTP_MAX_ATTEMPTS", 5)
_cancel_otp_state = {}
_cancel_otp_lock = Lock()


def _cancel_otp_request(booking_id):
    code = f"{secrets.randbelow(10000):04d}"
    with _cancel_otp_lock:
        _cancel_otp_state[booking_id] = {
            "code": code,
            "expires_at": time.time() + CANCEL_OTP_TTL_SECONDS,
            "attempts": 0,
        }
    return code


def _cancel_otp_verify(booking_id, submitted_code):
    """Returns None on a correct, still-valid code (and clears it — one-time
    use), or an error message otherwise."""
    with _cancel_otp_lock:
        entry = _cancel_otp_state.get(booking_id)
        if not entry:
            return "Request a cancellation code first."
        if time.time() > entry["expires_at"]:
            del _cancel_otp_state[booking_id]
            return "That code expired — request a new one."
        if entry["attempts"] >= CANCEL_OTP_MAX_ATTEMPTS:
            del _cancel_otp_state[booking_id]
            return "Too many incorrect attempts — request a new code."
        if submitted_code != entry["code"]:
            entry["attempts"] += 1
            return "Incorrect code."
        del _cancel_otp_state[booking_id]
        return None


class _BoundedDefaultDict(OrderedDict):
    """Same auto-vivifying convenience as collections.defaultdict, but
    evicts the least-recently-touched key once there are more than
    max_size of them. Both _rate_buckets and _backoff_state below are
    keyed by attacker-controlled values (an IP, an email, a phone number)
    with no natural cap on how many distinct ones exist — without this, a
    scripted client cycling through many bogus identities grows these
    dicts without bound. Worst case from evicting early is a stale key's
    limit/backoff resetting a little sooner than it otherwise would —
    never a memory leak."""

    def __init__(self, default_factory, max_size=20_000):
        super().__init__()
        self.default_factory = default_factory
        self.max_size = max_size

    def __missing__(self, key):
        if len(self) >= self.max_size:
            self.popitem(last=False)
        value = self.default_factory()
        self[key] = value
        return value

    def __getitem__(self, key):
        value = super().__getitem__(key)
        self.move_to_end(key)
        return value


_rate_buckets = _BoundedDefaultDict(deque)
_rate_lock = Lock()


def _rate_limited(key, max_calls, window_seconds):
    """Sliding-window call counter — pure call volume, no notion of
    success/failure. Used for the PUBLIC/AUTHENTICATED tiers and the global
    backstop below."""
    now_ts = time.monotonic()
    with _rate_lock:
        bucket = _rate_buckets[key]
        while bucket and now_ts - bucket[0] > window_seconds:
            bucket.popleft()
        if len(bucket) >= max_calls:
            return True
        bucket.append(now_ts)
        return False


_backoff_state = _BoundedDefaultDict(lambda: {"failures": 0, "blocked_until": 0.0})
_backoff_lock = Lock()


def _backoff_check(key):
    """Seconds remaining if `key` is currently backed off, else None.
    Read-only — does not itself consume or record an attempt."""
    with _backoff_lock:
        blocked_until = _backoff_state[key]["blocked_until"]
    remaining = blocked_until - time.monotonic()
    return remaining if remaining > 0 else None


def _backoff_record_failure(key, free_attempts, base_seconds, max_seconds):
    with _backoff_lock:
        state = _backoff_state[key]
        state["failures"] += 1
        over = state["failures"] - free_attempts
        if over > 0:
            delay = min(base_seconds * (2 ** (over - 1)), max_seconds)
            state["blocked_until"] = time.monotonic() + delay


def _backoff_record_success(key):
    with _backoff_lock:
        _backoff_state.pop(key, None)


class _BoundedStore:
    """Like _BoundedDefaultDict, but for state that's always set
    explicitly (never auto-vivified) — a plain dict assignment bypasses
    _BoundedDefaultDict's only eviction point (__missing__), so it can't
    be reused here. Same bound-by-eviction reasoning: keyed by phone
    numbers submitted to the web OTP endpoints below, with no natural cap
    on how many distinct ones a scripted client could submit."""

    def __init__(self, max_size=20_000):
        self._data = OrderedDict()
        self.max_size = max_size

    def set(self, key, value):
        self._data[key] = value
        self._data.move_to_end(key)
        while len(self._data) > self.max_size:
            self._data.popitem(last=False)

    def get(self, key):
        if key not in self._data:
            return None
        self._data.move_to_end(key)
        return self._data[key]

    def pop(self, key, default=None):
        return self._data.pop(key, default)


# Real, server-verified OTP for the Customer web app's phone sign-in —
# see /api/auth/phone/send-otp and friends below. Previously customer.html
# faked this entirely: a hardcoded, animated "OTP" with no server check,
# backing a login whose password was deterministically derivable from the
# phone number alone (`'rc-' + phone`) — anyone who knew a customer's
# phone number could log into their real account with one POST. Codes
# live only in memory: short-lived by design, and losing them on a
# restart just means a customer requests a fresh one.
WEB_PHONE_OTP_TTL_SECONDS = _env_int("WEB_PHONE_OTP_TTL_SECONDS", 300)
WEB_PHONE_OTP_MAX_ATTEMPTS = _env_int("WEB_PHONE_OTP_MAX_ATTEMPTS", 5)
# How long a just-verified phone with no existing account has to finish
# /api/auth/phone/register before needing to re-verify — long enough to
# type a name, short enough that a stale "verified" flag isn't sitting
# around indefinitely.
WEB_PHONE_VERIFIED_TTL_SECONDS = _env_int("WEB_PHONE_VERIFIED_TTL_SECONDS", 600)
_web_phone_otp_state = _BoundedStore()
_web_phone_otp_lock = Lock()
_web_phone_verified_state = _BoundedStore()
_web_phone_verified_lock = Lock()


def _web_phone_otp_request(phone):
    code = f"{secrets.randbelow(10000):04d}"
    with _web_phone_otp_lock:
        _web_phone_otp_state.set(phone, {
            "code": code,
            "expires_at": time.time() + WEB_PHONE_OTP_TTL_SECONDS,
            "attempts": 0,
        })
    return code


def _web_phone_otp_verify(phone, submitted_code):
    """Returns None on a correct, still-valid code (and marks the phone
    verified for WEB_PHONE_VERIFIED_TTL_SECONDS — see
    _web_phone_take_verified — so a brand-new account can finish signing
    up without re-proving phone ownership a second time), or an error
    message otherwise."""
    with _web_phone_otp_lock:
        entry = _web_phone_otp_state.get(phone)
        if not entry:
            return "Request a code first."
        if time.time() > entry["expires_at"]:
            _web_phone_otp_state.pop(phone)
            return "That code expired — request a new one."
        if entry["attempts"] >= WEB_PHONE_OTP_MAX_ATTEMPTS:
            _web_phone_otp_state.pop(phone)
            return "Too many incorrect attempts — request a new code."
        if submitted_code != entry["code"]:
            entry["attempts"] += 1
            return "Incorrect code."
        _web_phone_otp_state.pop(phone)
    with _web_phone_verified_lock:
        _web_phone_verified_state.set(phone, time.time() + WEB_PHONE_VERIFIED_TTL_SECONDS)
    return None


def _web_phone_take_verified(phone):
    """True (and consumes the flag) if this phone passed OTP verification
    recently and hasn't already been used to register an account; False
    otherwise. One-time — a second call for the same phone returns False
    until it verifies again."""
    with _web_phone_verified_lock:
        expires_at = _web_phone_verified_state.pop(phone)
        return expires_at is not None and time.time() <= expires_at


def _client_ip():
    forwarded = request.headers.get("X-Forwarded-For", "")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.remote_addr or "unknown"


def _auth_gate(account_key):
    """Call before checking credentials on an AUTH-tier route (login,
    register, ...). `account_key` identifies the account being attempted
    (phone/email as submitted — it doesn't need to exist or be correct).
    Returns a Flask response tuple to return immediately if either that
    account or this IP is currently backed off, else None."""
    ip_key = f"authip:{_client_ip()}"
    acct_key = f"authacct:{account_key}"
    remaining = _backoff_check(acct_key) or _backoff_check(ip_key)
    if remaining is not None:
        return jsonify({
            "error": "Too many attempts",
            "message": "Try again shortly",
            "retry_after": round(remaining, 1),
        }), 429
    return None


def _auth_gate_record(account_key, success):
    """Call after checking credentials on an AUTH-tier route, once whether
    the attempt actually succeeded is known."""
    ip_key = f"authip:{_client_ip()}"
    acct_key = f"authacct:{account_key}"
    if success:
        _backoff_record_success(acct_key)
        _backoff_record_success(ip_key)
    else:
        _backoff_record_failure(
            acct_key, RATE_LIMIT_AUTH_ACCOUNT_FREE_ATTEMPTS,
            RATE_LIMIT_AUTH_ACCOUNT_BACKOFF_BASE_SECONDS, RATE_LIMIT_AUTH_ACCOUNT_BACKOFF_MAX_SECONDS,
        )
        _backoff_record_failure(
            ip_key, RATE_LIMIT_AUTH_IP_FREE_ATTEMPTS,
            RATE_LIMIT_AUTH_IP_BACKOFF_BASE_SECONDS, RATE_LIMIT_AUTH_IP_BACKOFF_MAX_SECONDS,
        )


def rate_limit_public(fn):
    """PUBLIC tier — moderate, per-IP call-volume limit. Apply directly to
    unauthenticated, read-only informational routes."""
    @wraps(fn)
    def wrapper(*args, **kwargs):
        if _rate_limited(f"public:{_client_ip()}", RATE_LIMIT_PUBLIC_MAX_CALLS, RATE_LIMIT_PUBLIC_WINDOW_SECONDS):
            return jsonify({"error": "Too Many Requests", "message": "Slow down and try again shortly"}), 429
        return fn(*args, **kwargs)
    return wrapper


def _rate_limit_authenticated(identity_key):
    """AUTHENTICATED tier — looser, per-account call-volume limit. Called
    from inside the require_*_auth decorators once the caller's identity is
    known (not applied per-route), so every route behind one of those
    decorators gets it for free. Returns True if this call should be
    rejected."""
    return _rate_limited(
        f"authed:{identity_key}", RATE_LIMIT_AUTHENTICATED_MAX_CALLS, RATE_LIMIT_AUTHENTICATED_WINDOW_SECONDS
    )


@app.before_request
def _global_rate_limit():
    """A coarse per-IP cap across the whole API, on top of the tiers above —
    not meant to police normal usage (well under this for any real app
    screen), just an outer backstop against a bot hammering any endpoint,
    tiered or not, with an unbounded loop."""
    if not request.path.startswith("/api/"):
        return None
    if _rate_limited(f"ip:{_client_ip()}", RATE_LIMIT_GLOBAL_MAX_CALLS, RATE_LIMIT_GLOBAL_WINDOW_SECONDS):
        return jsonify({"error": "Too Many Requests", "message": "Slow down and try again shortly"}), 429
    return None


@app.after_request
def _security_headers(response):
    """Render's edge already forces HTTPS for the public *.onrender.com
    domain (HTTP requests get redirected before they ever reach this app),
    so HSTS here is defense in depth for any client that talks to us
    directly rather than through a browser redirect. The rest guard the
    legacy static HTML consoles (admin.html/technician.html/etc, served by
    this same app) against being framed or having their MIME type sniffed
    into something executable."""
    response.headers.setdefault("Strict-Transport-Security", "max-age=63072000; includeSubDomains")
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("X-Frame-Options", "DENY")
    response.headers.setdefault("Referrer-Policy", "no-referrer")
    return response

# Previously fell back to a hardcoded, publicly-committed string
# ("rasoicare-dev-secret-change-in-prod") — anyone reading this source
# file knew the exact secret signing every backend-issued JWT (customer
# email/password sessions AND staff sessions, including Owner). If that
# fallback was ever actually in effect on the live deployment, anyone
# could forge a token for any user_id/staff_id they could learn (e.g.
# user_id leaks via the intentionally-unauthenticated GET /api/bookings)
# and fully impersonate them — including an Owner account.
#
# Deliberately does NOT hard-exit when the env var is missing: this
# process doesn't know whether it's the live deployment or a fresh dev
# checkout, and refusing to boot at all would turn a config gap into a
# full outage. Instead it falls back to a fresh random secret every
# process start — never a fixed, knowable value — which closes the
# actual forgery hole immediately even before the env var is set, at the
# cost of invalidating sessions across restarts until it is. Set
# JWT_SECRET in the deployment's environment variables for stable,
# non-invalidating sessions.
JWT_SECRET = os.environ.get("JWT_SECRET")
if not JWT_SECRET:
    JWT_SECRET = secrets.token_hex(32)
    print(
        "WARNING: JWT_SECRET is not set — using a random secret generated for this "
        "process only. Every existing session (customer and staff) will be signed "
        "out on the next restart. Set JWT_SECRET in the environment for a stable "
        "production deployment.",
        file=sys.stderr,
    )
JWT_ALGORITHM = "HS256"
JWT_EXPIRY_DAYS = 7
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
PHONE_RE = re.compile(r"^[0-9]{10}$")
PAN_RE = re.compile(r"^[A-Z]{5}[0-9]{4}[A-Z]$")
IFSC_RE = re.compile(r"^[A-Z]{4}0[A-Z0-9]{6}$")
AADHAAR_RE = re.compile(r"^[0-9]{12}$")
GSTIN_RE = re.compile(r"^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z][Z][0-9A-Z]$")
UPI_ID_RE = re.compile(r"^[\w.\-]{2,256}@[a-zA-Z]{2,64}$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
ISO_DATETIME_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})?$"
)
CODE_RE = re.compile(r"^[0-9]{4}$")
PIN_RE = re.compile(r"^[0-9]{4,8}$")
BASE64_RE = re.compile(r"^[A-Za-z0-9+/]*={0,2}$")
BANK_ACCOUNT_RE = re.compile(r"^[0-9]{5,20}$")
URL_RE = re.compile(r"^https?://\S{1,2000}$")
NUMBER = (int, float)


# ---------------------------------------------------------------- input validation
# Every POST/PATCH endpoint below declares a schema (a dict of field name ->
# Field(...)) and wraps its route with @validate_json(SCHEMA). The decorator
# rejects the request outright — 400, naming every field that's wrong — if
# the body doesn't match: wrong type, too long/short, out of range, wrong
# format. It never coerces a numeric string into a number, truncates an
# over-long value, or escapes something dangerous-looking into a "safe"
# string; a mismatch is a rejection, not a repair job. A handler's own
# `data.get(...)` calls run completely unchanged afterwards — by the time
# they run, every field named in the schema is already known to be
# well-formed, so the handler is just reading validated data.
class Field:
    """One field's rule set.

    `type_` is a Python type or tuple of types (e.g. NUMBER = (int, float)
    for a field JSON might deliver either way). `bool` is deliberately
    never accepted as a match for an `int`/`float`/NUMBER field even though
    Python's `bool` is technically an `int` subclass — a stray `true`/
    `false` slipping into a numeric field is exactly the shape mismatch
    this exists to catch, not something to silently accept as 0/1."""

    def __init__(
        self, type_, *, required=False, min_len=None, max_len=None,
        min_val=None, max_val=None, pattern=None, choices=None,
        item_type=None, strip=True,
    ):
        self.type_ = type_
        self.types = type_ if isinstance(type_, tuple) else (type_,)
        self.required = required
        self.min_len = min_len
        self.max_len = max_len
        self.min_val = min_val
        self.max_val = max_val
        self.pattern = pattern
        self.choices = choices
        self.item_type = item_type  # for list fields: required type of each element
        self.strip = strip

    def _type_name(self):
        return " or ".join(t.__name__ for t in self.types)

    def validate(self, value):
        """Returns an error message string, or None if `value` is valid."""
        if isinstance(value, bool) and bool not in self.types:
            return f"must be a {self._type_name()}"
        if not isinstance(value, self.types):
            return f"must be a {self._type_name()}"
        if isinstance(value, str):
            v = value.strip() if self.strip else value
            # An optional field left blank (client sends "", not the key
            # omitted or null) shouldn't be measured against a pattern/
            # min_len/choices meant for a real value — e.g. the Partner
            # app's apply form always sends `gstNumber`/`upiId` even when
            # those "(optional)" fields are empty, which used to fail their
            # GSTIN/UPI regex and reject the whole submission with a bare
            # 400 the app could only show as "Could not submit (error
            # 400)." A required field still gets the real emptiness caught
            # below, same as before.
            if not v and not self.required:
                return None
            if self.min_len is not None and len(v) < self.min_len:
                return f"must be at least {self.min_len} character(s)"
            if self.max_len is not None and len(v) > self.max_len:
                return f"must be at most {self.max_len} characters"
            if self.pattern is not None and not self.pattern.match(v):
                return "is not in the expected format"
            if self.choices is not None and v not in self.choices:
                return "must be one of: " + ", ".join(str(c) for c in self.choices)
        elif isinstance(value, (int, float)) and not isinstance(value, bool):
            if self.min_val is not None and value < self.min_val:
                return f"must be at least {self.min_val}"
            if self.max_val is not None and value > self.max_val:
                return f"must be at most {self.max_val}"
            if self.choices is not None and value not in self.choices:
                return "must be one of: " + ", ".join(str(c) for c in self.choices)
        elif isinstance(value, list):
            if self.min_len is not None and len(value) < self.min_len:
                return f"must have at least {self.min_len} item(s)"
            if self.max_len is not None and len(value) > self.max_len:
                return f"must have at most {self.max_len} item(s)"
            if self.item_type is not None:
                for i, item in enumerate(value):
                    if isinstance(item, bool) or not isinstance(item, self.item_type):
                        return f"item {i} must be a {self.item_type.__name__}"
        return None


def validate_json(schema):
    """Applies `schema` to the request's JSON body. A field present in the
    body (and not null) is checked against its rule; a field marked
    required=True must be present and non-null. Fields in the body that
    aren't named in the schema are left alone — this validates the fields a
    handler actually reads, not a closed-world "no other keys" contract.
    Returns every violation at once (not just the first) so a client can
    fix its request in one round trip instead of one field at a time."""
    def decorator(fn):
        @wraps(fn)
        def wrapper(*args, **kwargs):
            data = request.get_json(force=True, silent=True)
            if data is None or not isinstance(data, dict):
                return jsonify({
                    "error": "Invalid request",
                    "message": "Request body must be a JSON object",
                }), 400
            errors = {}
            for field_name, field in schema.items():
                if field_name not in data or data[field_name] is None:
                    if field.required:
                        errors[field_name] = "is required"
                    continue
                message = field.validate(data[field_name])
                if message:
                    errors[field_name] = message
            if errors:
                return jsonify({"error": "Invalid request", "fields": errors}), 400
            return fn(*args, **kwargs)
        return wrapper
    return decorator


# Legacy surface control (P1-14 / audit N11): these six HTML consoles are the
# pre-Flutter web apps. They're still served because the rasoi_web_* WebView
# stub APKs load /customer and /technician from this backend (rasoi_web_*/
# lib/main.dart kAppPath), so turning them off is a deliberate owner decision
# paired with retiring those stubs — not something a deploy should do by
# accident. ENABLE_LEGACY_WEB=0 turns them all into JSON 404s; the legal
# pages (/terms, /privacy) and every /api route are NOT part of this surface
# and stay up regardless.
_ENABLE_LEGACY_WEB = (os.environ.get("ENABLE_LEGACY_WEB", "1") != "0")


def _legacy_page(filename):
    if not _ENABLE_LEGACY_WEB:
        return jsonify({
            "error": "Not Found",
            "message": "Legacy web console disabled (ENABLE_LEGACY_WEB=0)",
        }), 404
    return send_from_directory(FRONTEND_DIR, filename)


@app.route("/")
def index():
    return _legacy_page("index.html")


@app.route("/customer")
def customer_app():
    return _legacy_page("customer.html")


@app.route("/technician")
def technician_app():
    return _legacy_page("technician.html")


@app.route("/admin")
def admin_app():
    return _legacy_page("admin.html")


@app.route("/smiler")
def smiler_app():
    return _legacy_page("smiler.html")


@app.route("/homeservices")
def homeservices_app():
    return _legacy_page("homeservices.html")


# ---------------------------------------------------------------- legal docs
# Real Terms of Service / Privacy Policy text, describing what this codebase
# actually does (booking flow, live location sharing, Partner KYC fields,
# manually-recorded payment methods — no payment gateway, no analytics SDK).
# Previously the Customer and Partner apps had "Terms and conditions" /
# "Terms & conditions" entries that opened either a placeholder saying the
# real terms weren't live yet, or a checkbox with no linked document at all.
# Update LEGAL_CONTACT_EMAIL to a real, monitored address before shipping —
# it's the one address used throughout both documents below.
LEGAL_CONTACT_EMAIL = "support@rasoicare.in"
LEGAL_LAST_UPDATED = "23 August 2026"

TERMS_OF_SERVICE_SECTIONS = [
    ("Who we are and what these terms cover", [
        "Rasoi Care operates a marketplace connecting customers who need home-appliance "
        "repair, installation, and annual maintenance with independent service technicians "
        "(\"Partners\"). These Terms of Service govern your use of the Rasoi Care Customer "
        "app, the Rasoi Care Partner app, and the Rasoi Care Admin console (together, the "
        "\"Services\"). By creating an account or booking a service you agree to these terms.",
    ]),
    ("Eligibility", [
        "You must be at least 18 years old to create an account or book a service through "
        "Rasoi Care. The Services are not directed at anyone under 18, and we do not "
        "knowingly allow accounts for anyone under that age. If we learn an account belongs "
        "to someone under 18, we will close it.",
    ]),
    ("Your account", [
        "You can sign in by phone OTP, email and password, or Google sign-in. You're "
        "responsible for the accuracy of the details on your account and for keeping your "
        "device and sign-in credentials secure.",
        "Partner accounts go through an extra step: before a technician account can accept "
        "jobs, we require identity details, a government ID document, and payout bank "
        "details, and a member of our team reviews the application before it goes live.",
    ]),
    ("Booking a service", [
        "You choose an appliance category and describe the issue, pick an address and time, "
        "and a Partner accepts the job. A booking moves through a fixed sequence — Requested, "
        "Accepted, On the way, In Progress, Completed — and we show you which stage it's at.",
        "Before a job can be marked Completed, the Partner records a before photo, an after "
        "photo, and your signature confirming the work was done.",
    ]),
    ("Cancelling a booking", [
        "You can cancel a booking at any time before it's completed. If a Partner has already "
        "been assigned or has started travelling to you, cancelling may carry a fee that "
        "scales with how far the job had progressed — shown to you in the app before you "
        "confirm the cancellation. That fee compensates the Partner for time already "
        "committed to your job.",
    ]),
    ("Payment", [
        "You pay the Partner directly — in cash, by UPI, by card, or via a payment link — at "
        "the time of service, and the Partner records which method you used. Rasoi Care does "
        "not process payments and does not receive or store your card or bank details.",
    ]),
    ("Partners", [
        "Partners are independent technicians, not Rasoi Care employees. We expect Partners "
        "to behave professionally, honour the agreed price, and use the app's photo and "
        "signature steps to confirm completed work. We can suspend a Partner account over "
        "safety issues, fraud, or conduct complaints.",
    ]),
    ("Location sharing during a booking", [
        "Once a Partner accepts your booking, their live location is shared with you inside "
        "the app so you can track their arrival. That sharing stops as soon as the job is "
        "completed or cancelled — we don't track a Partner's location outside an active job, "
        "and we don't share your address with a Partner until they're assigned to your "
        "booking.",
    ]),
    ("Reviews and other features", [
        "You can rate and review a completed job — reviews should be honest, since other "
        "customers and our Partner-quality process both rely on them. Optional features like "
        "referral codes and reward coins are described where you use them in the app and are "
        "subject to whatever terms are shown there at the time.",
    ]),
    ("Liability", [
        "Services are carried out by independent Partners, and we're not liable for "
        "pre-existing appliance faults unrelated to the work performed. To the extent the law "
        "allows, our liability arising from a booking is limited to the amount you paid for "
        "that booking.",
    ]),
    ("Suspension and account closure", [
        "We may suspend or close an account for fraud, abuse, non-payment, or a breach of "
        "these terms. You can stop using the Services and ask us to delete your account at "
        f"any time by writing to {LEGAL_CONTACT_EMAIL}.",
    ]),
    ("Changes to these terms", [
        "We may update these terms as the Services change. We'll update the date at the top "
        "of this page and, for material changes, let you know inside the app.",
    ]),
    ("Governing law", [
        "These terms are governed by the laws of India, and courts located in India have "
        "exclusive jurisdiction over any dispute arising from them.",
    ]),
    ("Contact us", [
        f"Questions about these terms can be sent to {LEGAL_CONTACT_EMAIL}.",
    ]),
]

PRIVACY_POLICY_SECTIONS = [
    ("Scope", [
        "This Privacy Policy covers the Rasoi Care Customer app, Partner app, and Admin "
        "console, and the backend they all talk to.",
    ]),
    ("Information we collect", [
        "Account information: your name, phone number, and email address, from phone-OTP, "
        "email, or Google sign-in (handled by Firebase Authentication).",
        "Profile information: your saved address(es) and their map coordinates, and the "
        "appliances you tell us you own.",
        "Booking information: the appliance category and issue you describe, any notes or "
        "photos you attach, and the booking's status history.",
        "Location: your saved address coordinates, and — only while a Partner is en route to "
        "or working on your active booking — the Partner's live location, so you can track "
        "their arrival.",
        "Job-completion records: a before photo, an after photo, and a signature, captured by "
        "the Partner to confirm the work performed on your booking.",
        "Partner verification information (Partner app only): date of birth, address, ID "
        "numbers (Aadhaar, PAN), ID document photos, and bank account and IFSC details, "
        "collected to verify identity and pay out earnings.",
        "Payment method label: whether a booking was paid by cash, UPI, card, or link, as "
        "recorded by the Partner — we don't collect or store card numbers or bank "
        "credentials for customer payments, since payment happens directly between you and "
        "the Partner.",
        "Device preferences: language, theme, and notification choices, stored on your "
        "device.",
        "Ratings and reviews you submit about a completed booking.",
    ]),
    ("How we use this information", [
        "To create and run your account, match you with a Partner, show live tracking, "
        "verify Partner applications, calculate and pay out Partner earnings, look into "
        "complaints, and keep improving the Services.",
    ]),
    ("Who we share it with", [
        "The Partner assigned to your booking sees your name, address, phone number, and "
        "issue details, so they can carry out the job.",
        "While a booking is active, the Partner app shows the assigned customer's location "
        "and profile name for that job only.",
        "Firebase Authentication and Cloud Firestore (Google LLC) provide our sign-in and "
        "profile-storage infrastructure.",
        "Google Maps Platform provides maps, address lookup, and live-tracking display.",
        "We do not sell your personal information. Partner verification documents (ID "
        "numbers, ID photos, bank details) are used only for verification and payout, and "
        "are not shared outside that process.",
    ]),
    ("Data security", [
        "We use reasonable technical safeguards — including hashed passwords, signed session "
        "tokens, and HTTPS in transit — and restrict access to sensitive Partner verification "
        "documents to the verification and payout process.",
    ]),
    ("Data retention", [
        "We keep account and booking records for as long as your account is active, and as "
        "long as needed to resolve disputes or meet legal and accounting obligations. You can "
        "ask us to delete your account and its associated data at any time; some records "
        "(such as completed-transaction history) may need to be retained for longer where "
        "the law requires it.",
    ]),
    ("Your rights", [
        f"You can ask to access, correct, or delete your personal information by writing to "
        f"{LEGAL_CONTACT_EMAIL}. Partners can also update most verification details directly "
        "from their profile in the Partner app.",
    ]),
    ("Children's privacy", [
        "The Services are for users aged 18 and over, and we do not knowingly collect "
        "personal information from children. If you believe a child has given us "
        f"information, contact {LEGAL_CONTACT_EMAIL} and we'll delete it.",
    ]),
    ("Changes to this policy", [
        "We may update this policy as the Services change. We'll update the date at the top "
        "of this page when we do.",
    ]),
    ("Contact us", [
        f"Questions about this policy can be sent to {LEGAL_CONTACT_EMAIL}.",
    ]),
]


def _legal_doc_payload(title, sections):
    return {
        "title": title,
        "lastUpdated": LEGAL_LAST_UPDATED,
        "sections": [{"heading": heading, "paragraphs": paragraphs} for heading, paragraphs in sections],
    }


def _legal_doc_html(title, sections):
    import html as _html
    body_parts = []
    for heading, paragraphs in sections:
        body_parts.append(f"<h2>{_html.escape(heading)}</h2>")
        for para in paragraphs:
            body_parts.append(f"<p>{_html.escape(para)}</p>")
    return (
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        f"<title>Rasoi Care — {_html.escape(title)}</title>"
        "<style>"
        "body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;"
        "max-width:700px;margin:0 auto;padding:32px 20px 60px;color:#1c1c1e;line-height:1.55}"
        "h1{font-size:26px;margin-bottom:4px}"
        "h2{font-size:17px;margin-top:28px;margin-bottom:8px}"
        ".updated{color:#6b6b70;font-size:13px;margin-bottom:24px}"
        "p{font-size:15px;margin:0 0 10px}"
        "</style></head><body>"
        f"<h1>{_html.escape(title)}</h1>"
        f"<div class=\"updated\">Last updated {_html.escape(LEGAL_LAST_UPDATED)}</div>"
        + "".join(body_parts) +
        "</body></html>"
    )


@app.route("/api/legal/terms", methods=["GET"])
@rate_limit_public
def api_legal_terms():
    return jsonify(_legal_doc_payload("Terms of Service", TERMS_OF_SERVICE_SECTIONS))


@app.route("/api/legal/privacy", methods=["GET"])
@rate_limit_public
def api_legal_privacy():
    return jsonify(_legal_doc_payload("Privacy Policy", PRIVACY_POLICY_SECTIONS))


@app.route("/terms")
def terms_page():
    return Response(_legal_doc_html("Terms of Service", TERMS_OF_SERVICE_SECTIONS), mimetype="text/html")


@app.route("/privacy")
def privacy_page():
    return Response(_legal_doc_html("Privacy Policy", PRIVACY_POLICY_SECTIONS), mimetype="text/html")


STATUS_ORDER = ["Requested", "Accepted", "On the way", "In Progress", "Completed"]


# ---------------------------------------------------------------- CORS
# Hand-rolled instead of pulling in flask-cors, so this has zero extra
# dependencies to install at deploy time.
#
# Previously this reflected Access-Control-Allow-Origin: * on every response.
# That's harmless to the native Flutter apps (they don't enforce CORS), but it
# let any web page anywhere read the authenticated API responses from a
# victim's browser (any site could fire fetch() with a stolen/cookieless
# token flow or probe endpoints). Now the origin is echoed only when it's on
# the allowlist. Native apps and the same-origin legacy HTML pages served by
# this very app (admin.html etc.) never needed CORS in the first place, so
# the default list is deliberately minimal: the production backend's own
# origin (Render serves it) plus localhost for development. Set
# ALLOWED_ORIGINS (comma-separated) to widen it deliberately.
#
# `Authorization` joins Allow-Headers so a future Flutter-web build sending
# Bearer tokens can't be silently broken by a blocked preflight.
_ALLOWED_ORIGINS = {
    o.strip()
    for o in os.environ.get(
        "ALLOWED_ORIGINS",
        "https://rasoicare-backend.onrender.com,http://localhost:8420,http://localhost:8000",
    ).split(",")
    if o.strip()
}


@app.after_request
def add_cors_headers(resp):
    origin = request.headers.get("Origin")
    if origin and origin in _ALLOWED_ORIGINS:
        resp.headers["Access-Control-Allow-Origin"] = origin
        # Cacheable per-origin response: without Vary, a shared cache could
        # serve one allowlisted origin's CORS headers to a different origin.
        resp.headers["Vary"] = "Origin"
        resp.headers["Access-Control-Allow-Methods"] = "GET, POST, PATCH, OPTIONS"
        resp.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
    return resp


@app.route("/api/<path:_any>", methods=["OPTIONS"])
def cors_preflight(_any):
    return "", 204


# ---------------------------------------------------------------- helpers
# Joins in the technician's firebase_uid alongside every bookings.* column —
# the Customer app needs this (not the technician's backend id) to watch
# their live location, since that's how the Partner app keys the Firestore
# document it writes to (technician_locations/{firebase_uid}, not
# technician_locations/{TECH-xxxx}). Query call sites that only ever fetch
# a `bookings` row should use this instead of "SELECT * FROM bookings" —
# row["technician_firebase_uid"] is None for legacy/seed technicians that
# have never bootstrapped through the Partner app, which is expected.
BOOKING_SELECT = (
    "SELECT bookings.*, technicians.firebase_uid AS technician_firebase_uid, "
    "users.phone AS customer_phone "
    "FROM bookings LEFT JOIN technicians ON technicians.id = bookings.technician_id "
    "LEFT JOIN users ON users.id = bookings.user_id"
)

# List-query twin of BOOKING_SELECT (same joins, same calling convention)
# that never transports the raw base64 photo/signature blobs. A booking can
# carry up to ~12MB + ~12MB + ~4MB of base64 text; a staff list of 500 rows
# was dragging hundreds of MB through Postgres and serialization only for
# booking_row_to_dict to immediately discard it (it serializes those columns
# as booleans anyway — `bool(row[...])`). The projection selects every
# bookings column EXCEPT the three blobs, which are aliased to an exactly
# truthiness-equivalent boolean expression under the same column name, so
# booking_row_to_dict's `"col" in keys and bool(row[col])` logic produces
# byte-identical JSON with a payload three orders of magnitude smaller.
# Call sites: every .fetchall() list/report query. Single-row .fetchone()
# detail/mutation paths keep using BOOKING_SELECT (full row) unchanged.
# Column source of truth: database.BOOKINGS_COLUMNS (drift-guarded by
# tests/test_booking_list_payload.py).
_BOOKING_LIST_SCALARS = [
    c for c in database.BOOKINGS_COLUMNS if c not in database.BOOKINGS_BLOB_COLUMNS
]
_BOOKING_LIST_BLOB_ALIASES = [
    f"(bookings.{c} IS NOT NULL AND length(bookings.{c}) > 0) AS {c}"
    for c in database.BOOKINGS_BLOB_COLUMNS
]
BOOKING_LIST_SELECT = (
    "SELECT "
    + ", ".join(f"bookings.{c}" for c in _BOOKING_LIST_SCALARS)
    + ", " + ", ".join(_BOOKING_LIST_BLOB_ALIASES)
    + ", technicians.firebase_uid AS technician_firebase_uid, "
    "users.phone AS customer_phone "
    "FROM bookings LEFT JOIN technicians ON technicians.id = bookings.technician_id "
    "LEFT JOIN users ON users.id = bookings.user_id"
)


def part_row_to_dict(row):
    return {
        "id": row["id"],
        "name": row["name"],
        "sku": row["sku"],
        "qty": row["qty"],
        "pricePaise": row["price_paise"],
        "status": row["status"],
        "createdAt": row["created_at"],
        "decidedAt": row["decided_at"],
    }


def fetch_booking_parts(conn, booking_id):
    rows = conn.execute(
        "SELECT * FROM booking_parts WHERE booking_id = ? ORDER BY created_at", (booking_id,)
    ).fetchall()
    return [part_row_to_dict(r) for r in rows]


def fetch_booking_parts_bulk(conn, booking_ids):
    """One query for every booking id in a list response, keyed by
    booking_id — avoids an N+1 query per row for list_bookings/
    technician_my_bookings."""
    if not booking_ids:
        return {}
    placeholders = ",".join("?" * len(booking_ids))
    rows = conn.execute(
        f"SELECT * FROM booking_parts WHERE booking_id IN ({placeholders}) ORDER BY created_at",
        tuple(booking_ids),
    ).fetchall()
    by_booking = {}
    for r in rows:
        by_booking.setdefault(r["booking_id"], []).append(part_row_to_dict(r))
    return by_booking


def service_change_row_to_dict(row):
    return {
        "id": row["id"],
        "oldService": row["old_service"],
        "newService": row["new_service"],
        "oldPricePaise": row["old_price"] * 100,
        "newPricePaise": row["new_price"] * 100,
        "createdAt": row["created_at"],
    }


def fetch_booking_service_changes(conn, booking_id):
    rows = conn.execute(
        "SELECT * FROM booking_service_changes WHERE booking_id = ? ORDER BY created_at",
        (booking_id,),
    ).fetchall()
    return [service_change_row_to_dict(r) for r in rows]


def fetch_booking_service_changes_bulk(conn, booking_ids):
    """One query for every booking id in a list response — see
    fetch_booking_parts_bulk, same reasoning."""
    if not booking_ids:
        return {}
    placeholders = ",".join("?" * len(booking_ids))
    rows = conn.execute(
        f"SELECT * FROM booking_service_changes WHERE booking_id IN ({placeholders}) "
        "ORDER BY created_at",
        tuple(booking_ids),
    ).fetchall()
    by_booking = {}
    for r in rows:
        by_booking.setdefault(r["booking_id"], []).append(service_change_row_to_dict(r))
    return by_booking


def booking_row_to_dict(
    row, *, include_start_code=False, parts=None, service_changes=None, redact_customer_contact=False
):
    keys = row.keys()
    d = {
        "id": row["id"],
        "category": row["category"],
        "service": row["service"],
        "price": row["price"],
        "technicianId": row["technician_id"],
        "technicianFirebaseUid": row["technician_firebase_uid"]
        if "technician_firebase_uid" in keys
        else None,
        "customerName": row["customer_name"],
        "status": row["status"],
        "bachatSlot": row["bachat_slot"],
        "ratings": (
            {"service": row["service_rating"], "tech": row["tech_rating"]}
            if row["service_rating"] is not None
            else None
        ),
        "createdAt": row["created_at"],
        "updatedAt": row["updated_at"],
        "user_id": row["user_id"] if "user_id" in keys else None,
        "service_id": row["service_id"] if "service_id" in keys else None,
        "total_amount": row["total_amount"] if "total_amount" in keys else row["price"],
        "area": row["area"] if "area" in keys else None,
        # The real street address behind the short `area` label above — see
        # create_booking and migrate_bookings_columns. Null for bookings
        # made before this existed, or by a client that didn't send one.
        "addressLine": row["address_line"] if "address_line" in keys else None,
        # Which of the Partner app's five service cities this booking is
        # in — see infer_city. Distinct from `area` above (a display label
        # like "Home"/"Office"); this is what dispatch actually matches
        # against a technician's own city.
        "city": row["city"] if "city" in keys else None,
        "lat": row["lat"] if "lat" in keys else None,
        "lng": row["lng"] if "lng" in keys else None,
        # Real work-log data, filled in as the technician actually advances
        # the job — see advance_booking. None until that's happened, which
        # the Customer app's invoice treats as "not recorded" rather than
        # showing an invented reading.
        "suctionBefore": row["suction_before"] if "suction_before" in keys else None,
        "suctionAfter": row["suction_after"] if "suction_after" in keys else None,
        "timeOnSiteMin": row["time_on_site_min"] if "time_on_site_min" in keys else None,
        "cancelledAt": row["cancelled_at"] if "cancelled_at" in keys else None,
        "cancellationFee": row["cancellation_fee"] if "cancellation_fee" in keys else None,
        "directions": row["directions"] if "directions" in keys else None,
        "notes": row["notes"] if "notes" in keys else None,
        # What the customer actually ticked on the Issue screen (see
        # create_booking) — [] when they reported nothing, never a
        # fabricated symptom list.
        "issues": json.loads(row["issues_json"])
        if ("issues_json" in keys and row["issues_json"]) else [],
        "paymentMethod": row["payment_method"] if "payment_method" in keys else None,
        # Set by the technician on-site once they've actually looked at the
        # appliance — see PATCH .../appliance. Null until then, never a
        # guessed value.
        "brand": row["brand"] if "brand" in keys else None,
        "modelNumber": row["model_number"] if "model_number" in keys else None,
        # Real parts/extra-work quotes the technician has actually raised
        # for this job — [] when none exist, or when the caller didn't pass
        # `parts=` (most single-booking-mutation endpoints don't bother;
        # the Partner/Customer apps re-fetch the full list/detail endpoints,
        # which always do, to see current parts state).
        "parts": parts if parts is not None else [],
        # Real record of the technician swapping this booking's service for
        # a different one — [] when it's never happened, or when the caller
        # didn't pass `service_changes=` (see the `parts` comment above for
        # why that's fine: the list/detail endpoints that matter always do).
        "serviceChanges": service_changes if service_changes is not None else [],
        # The real day+slot the customer picked, as an ISO timestamp — see
        # create_booking and _cancellation_fee_for. Null for bookings made
        # before this was captured, or by a client that didn't send one.
        "scheduledAt": row["scheduled_at"] if "scheduled_at" in keys else None,
        # The customer's own verified phone number (see bootstrap_customer),
        # so the technician's "Call" action can dial a real number instead
        # of a fake "Calling — masked" toast. Null for bookings made before
        # this was captured, or if the customer never verified a phone.
        "customerPhone": row["customer_phone"] if "customer_phone" in keys else None,
        # Shown to the customer so they can hand it to the technician in
        # person before work starts — advance_booking refuses to move a
        # booking into "In Progress" without a matching code, so a
        # technician can't mark a visit started without actually being
        # there. Deliberately omitted from the technician's own
        # /api/technician/bookings response (include_start_code stays
        # False there) — the whole point is that only the customer's app
        # ever shows it.
        "startCode": row["start_code"]
        if (include_start_code and "start_code" in keys) else None,
        # Booleans, not the raw base64 — the Partner app uses these to know
        # what's still missing before "Complete and invoice" can succeed;
        # the actual image bytes are fetched separately via
        # /api/bookings/<id>/photo/<kind> only when actually needed.
        "beforePhotoReady": bool(row["before_photo_b64"]) if "before_photo_b64" in keys else False,
        "afterPhotoReady": bool(row["after_photo_b64"]) if "after_photo_b64" in keys else False,
        "signatureReady": bool(row["signature_b64"]) if "signature_b64" in keys else False,
    }
    if redact_customer_contact:
        # The broadcast "available requests" feed goes out to every
        # matching technician before any of them is assigned — see
        # technician_available_bookings. The privacy policy promises the
        # customer's exact address/coordinates/phone aren't shared with a
        # Partner until they're actually assigned to the booking, so those
        # fields never leave the server here, whoever ends up claiming it.
        for field in ("addressLine", "lat", "lng", "directions", "notes", "customerPhone"):
            d[field] = None
    return d


def complaint_row_to_dict(row):
    return {
        "id": row["id"],
        "bookingId": row["booking_id"],
        "text": row["text"],
        "status": row["status"],
        "response": row["response"],
        "createdAt": row["created_at"],
    }


def technician_categories(row):
    """A technician can be skilled in more than one category; categories_json
    holds the full list. Older rows (or rows never updated since) only have
    the single `category` column — fall back to a one-item list from that so
    every caller can treat "categories" as always-a-list."""
    keys = row.keys()
    raw = row["categories_json"] if "categories_json" in keys else None
    if raw:
        try:
            cats = json.loads(raw)
            if isinstance(cats, list) and cats:
                return cats
        except (TypeError, ValueError):
            pass
    return [row["category"]] if row["category"] else []


def technician_row_to_dict(row, *, redact_documents=False, redact_financial=False):
    keys = row.keys()
    d = {
        "id": row["id"],
        "name": row["name"],
        "category": row["category"],
        "categories": technician_categories(row),
        "area": row["area"] if "area" in keys else "",
        "email": row["email"] if "email" in keys else None,
        "verified": bool(row["verified"]) if "verified" in keys else True,
        "online": bool(row["online"]),
        "rating": round(row["rating"], 1),
        "ratingCount": row["rating_count"],
        "jobsCompleted": row["jobs_completed"],
        "photoUrl": row["photo_url"] if "photo_url" in keys else None,
        "experienceYears": row["experience_years"] if "experience_years" in keys else None,
        "idDocumentUrl": row["id_document_url"] if "id_document_url" in keys else None,
        "bankAccountName": row["bank_account_name"] if "bank_account_name" in keys else None,
        "bankAccountNumber": row["bank_account_number"] if "bank_account_number" in keys else None,
        "bankIfsc": row["bank_ifsc"] if "bank_ifsc" in keys else None,
        "panNumber": row["pan_number"] if "pan_number" in keys else None,
        "aadharNumber": row["aadhar_number"] if "aadhar_number" in keys else None,
        "dateOfBirth": row["date_of_birth"] if "date_of_birth" in keys else None,
        "gstNumber": row["gst_number"] if "gst_number" in keys else None,
        "emergencyContactName": row["emergency_contact_name"]
        if "emergency_contact_name" in keys
        else None,
        "emergencyContactPhone": row["emergency_contact_phone"]
        if "emergency_contact_phone" in keys
        else None,
        "aadharDocumentUrl": row["aadhar_document_url"] if "aadhar_document_url" in keys else None,
        "aadharDocumentBackUrl": row["aadhar_document_back_url"]
        if "aadhar_document_back_url" in keys
        else None,
        "panDocumentUrl": row["pan_document_url"] if "pan_document_url" in keys else None,
        "bankPassbookUrl": row["bank_passbook_url"] if "bank_passbook_url" in keys else None,
        "address": row["address"] if "address" in keys else None,
        "upiId": row["upi_id"] if "upi_id" in keys else None,
        "documentsDeferred": _TECH_DOCS_DEFERRED,
        "applicationSubmitted": bool(row["application_submitted"])
        if "application_submitted" in keys
        else True,
        "partnerCode": row["partner_code"] if "partner_code" in keys else None,
        # Self-declared once at KYC/onboarding (see update_technician_me) —
        # never editable by an admin afterward. Drives which commission
        # formula compute_commission_paise applies to this technician's
        # completed jobs.
        "employmentType": row["employment_type"] if "employment_type" in keys else "outsourced",
    }
    # aadharDocumentReady/panDocumentReady/bankPassbookReady tell a caller
    # whether a document was ever uploaded without needing the raw URL —
    # always present so the Admin app's "missing document" chips keep
    # working even when the URLs themselves are redacted below.
    d["aadharDocumentReady"] = bool(d["aadharDocumentUrl"])
    d["aadharDocumentBackReady"] = bool(d["aadharDocumentBackUrl"])
    d["panDocumentReady"] = bool(d["panDocumentUrl"])
    d["bankPassbookReady"] = bool(d["bankPassbookUrl"])
    if redact_financial:
        # Payout bank/UPI/GST details are owner-only financial data; staff
        # views of a technician never include them.
        for field in ("bankAccountName", "bankAccountNumber", "bankIfsc", "upiId", "gstNumber",
                      "bankPassbookUrl"):
            d[field] = None
        d["bankPassbookReady"] = False
    if redact_documents:
        # These are long-lived, non-expiring Firebase Storage URLs whose
        # only "auth" is an unguessable token in the query string — handing
        # them to the Admin app's staff-scoped listing means anyone who
        # ever sees that response (a log, a proxy, a shared screenshot) can
        # view a technician's Aadhaar/PAN/bank passbook indefinitely with
        # no session at all. Staff views the actual image through
        # GET /api/technicians/<id>/document/<kind> instead, which requires
        # a live staff token on every fetch — see technician_document.
        for field in ("aadharDocumentUrl", "aadharDocumentBackUrl", "panDocumentUrl", "bankPassbookUrl"):
            d[field] = None
    return d


def user_row_to_dict(row):
    keys = row.keys()
    return {
        "id": row["id"],
        "email": row["email"],
        "name": row["name"],
        "phone": row["phone"],
        "created_at": row["created_at"],
        "coinsBalance": row["coins_balance"] if "coins_balance" in keys else 0,
    }


def shop_order_row_to_dict(row):
    return {
        "id": row["id"],
        "items": json.loads(row["items_json"]),
        "totalPaise": row["total_paise"],
        "status": row["status"],
        "createdAt": row["created_at"],
    }


def appliance_row_to_dict(row):
    return {
        "id": row["id"],
        "name": row["name"],
        "category": row["category"],
        "mono": row["mono"],
    }


def service_row_to_dict(row):
    return {
        "id": row["id"],
        "appliance_id": row["appliance_id"],
        "appliance_name": row["appliance_name"],
        "category": row["category"],
        "name": row["name"],
        "price": row["price"],
        "quick_fix": bool(row["quick_fix"]),
    }


def staff_row_to_dict(row):
    keys = row.keys()
    return {
        "id": row["id"],
        "name": row["name"],
        "phone": row["phone"],
        "email": row["email"] if "email" in keys else None,
        "role": row["role"],
        "active": bool(row["active"]),
        "createdAt": row["created_at"],
    }


def inventory_row_to_dict(row):
    return {
        "id": row["id"],
        "name": row["name"],
        "sku": row["sku"],
        "category": row["category"],
        "quantity": row["quantity"],
        "reorderLevel": row["reorder_level"],
        "lowStock": row["quantity"] < row["reorder_level"],
        "updatedAt": row["updated_at"],
    }


# ---------------------------------------------------------------- auth
def generate_token(user_id):
    payload = {
        "sub": user_id,
        "exp": datetime.now(timezone.utc) + timedelta(days=JWT_EXPIRY_DAYS),
        "iat": datetime.now(timezone.utc),
    }
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM)


def decode_token(token):
    """Returns the user id from a valid token, or None if missing/expired/invalid."""
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        return payload.get("sub")
    except jwt.PyJWTError:
        return None


def get_bearer_token():
    header = request.headers.get("Authorization", "")
    if not header.startswith("Bearer "):
        return None
    return header[len("Bearer "):].strip()


# ---------------------------------------------------------------- Firebase bridge
#
# The three native apps (Customer/Partner/Admin) sign in with Firebase Auth
# directly, not through /api/auth/login — there's no separate "backend
# password" for them. Instead they send their Firebase ID token as the
# Bearer token on every API call, and we verify it here ourselves (no
# firebase-admin dependency needed: it's a standard RS256-signed JWT,
# verifiable with Google's published public certs).
#
# This is purely additive — decode_token/decode_staff_token (the existing
# backend-issued JWTs the web apps use) are tried first everywhere, so
# nothing about the web apps' auth changes.
FIREBASE_PROJECT_ID = os.environ.get("FIREBASE_PROJECT_ID", "rasoi-care")
_GOOGLE_CERTS_URL = (
    "https://www.googleapis.com/robot/v1/metadata/x509/"
    "securetoken@system.gserviceaccount.com"
)
_firebase_certs_cache = {"certs": None, "fetched_at": 0.0}


def _get_firebase_certs():
    """Google rotates these certs periodically; a short cache keeps every
    request from re-fetching while still picking up rotations quickly."""
    import time
    import urllib.request

    cache = _firebase_certs_cache
    if cache["certs"] and (time.time() - cache["fetched_at"]) < 3600:
        return cache["certs"]
    try:
        with urllib.request.urlopen(_GOOGLE_CERTS_URL, timeout=10) as resp:
            certs = json.loads(resp.read().decode())
        cache["certs"] = certs
        cache["fetched_at"] = time.time()
        return certs
    except Exception:
        # Network hiccup — fall back to whatever we last had (possibly
        # None, in which case verification below just fails closed).
        return cache["certs"]


def verify_firebase_token(id_token):
    """Returns {"uid", "email", "name"} for a valid Firebase ID token
    issued to the rasoi-care project, or None if it's missing, expired,
    or fails signature/audience/issuer checks.

    Every failure is logged (never just silently returns None) — this used
    to swallow the real reason entirely, so a genuine misconfiguration
    (wrong project id, cert-fetch failure, clock skew) looked identical to
    "customer's token is stale" from the client's point of view, and the
    Customer app's checkout would show "Your session needs refreshing" for
    a problem retrying could never actually fix. `leeway` tolerates a few
    seconds of clock difference between this server and Google's, which a
    zero-tolerance check would otherwise reject as "expired"/"not yet
    valid" for a perfectly real, current token."""
    if not id_token:
        return None
    try:
        from cryptography.hazmat.backends import default_backend
        from cryptography.x509 import load_pem_x509_certificate

        unverified_header = jwt.get_unverified_header(id_token)
        kid = unverified_header.get("kid")
        certs = _get_firebase_certs()
        if not certs:
            print("verify_firebase_token: could not fetch Google's certs", file=sys.stderr)
            return None
        if kid not in certs:
            print(f"verify_firebase_token: unknown key id {kid!r}", file=sys.stderr)
            return None
        public_key = load_pem_x509_certificate(
            certs[kid].encode("utf-8"), default_backend()
        ).public_key()
        payload = jwt.decode(
            id_token,
            public_key,
            algorithms=["RS256"],
            audience=FIREBASE_PROJECT_ID,
            issuer=f"https://securetoken.google.com/{FIREBASE_PROJECT_ID}",
            leeway=10,
        )
        uid = payload.get("user_id") or payload.get("sub")
        if not uid:
            print("verify_firebase_token: token has no user_id/sub claim", file=sys.stderr)
            return None
        return {
            "uid": uid,
            "email": payload.get("email"),
            # Only true once Firebase itself has confirmed this token's
            # holder actually controls that email (a verification link
            # click, or a provider like Google that verifies it upfront) —
            # required before any bootstrap endpoint may fall back to
            # matching an existing row by email, so a brand-new signup
            # using someone else's known-but-unverified email can never
            # attach itself to that person's real account.
            "email_verified": bool(payload.get("email_verified")),
            "name": payload.get("name"),
            # Only ever set for a phone-OTP sign-in, and only once Firebase
            # has actually verified it — safe to trust over anything the
            # client claims about its own phone number.
            "phone_number": payload.get("phone_number"),
            "sign_in_provider": (payload.get("firebase") or {}).get("sign_in_provider"),
        }
    except Exception as e:
        print(f"verify_firebase_token: rejected — {e}", file=sys.stderr)
        return None


def get_current_user_optional():
    """Returns the user row for a valid Bearer token, or None (does not
    reject the request) — used by endpoints that behave differently for
    authenticated vs anonymous callers without requiring auth. Accepts
    either a backend-issued JWT or a Firebase ID token."""
    token = get_bearer_token()
    if not token:
        return None
    conn = get_db()
    user_id = decode_token(token)
    if user_id:
        row = conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
        conn.close()
        return row
    claims = verify_firebase_token(token)
    if claims:
        row = conn.execute(
            "SELECT * FROM users WHERE firebase_uid = ?", (claims["uid"],)
        ).fetchone()
        conn.close()
        return row
    conn.close()
    return None


def require_auth(fn):
    @wraps(fn)
    def wrapper(*args, **kwargs):
        token = get_bearer_token()
        if not token:
            return jsonify({"error": "Unauthorized", "message": "Missing bearer token"}), 401
        row = get_current_user_optional()
        if not row:
            return jsonify({"error": "Unauthorized", "message": "Invalid or expired token"}), 401
        if _rate_limit_authenticated(f"user:{row['id']}"):
            return jsonify({"error": "Too Many Requests", "message": "Slow down and try again shortly"}), 429
        request.user = row
        return fn(*args, **kwargs)
    return wrapper


def generate_staff_token(staff_id):
    payload = {
        "sub": staff_id,
        "typ": "staff",
        "exp": datetime.now(timezone.utc) + timedelta(days=JWT_EXPIRY_DAYS),
        "iat": datetime.now(timezone.utc),
    }
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM)


def decode_staff_token(token):
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        if payload.get("typ") != "staff":
            return None
        return payload.get("sub")
    except jwt.PyJWTError:
        return None


def get_current_staff_optional():
    """Same Firebase-or-backend-JWT bridging as get_current_user_optional,
    for the staff table (Admin app)."""
    token = get_bearer_token()
    if not token:
        return None
    conn = get_db()
    staff_id = decode_staff_token(token)
    if staff_id:
        row = conn.execute("SELECT * FROM staff WHERE id = ?", (staff_id,)).fetchone()
        conn.close()
        return row
    claims = verify_firebase_token(token)
    if claims:
        row = conn.execute(
            "SELECT * FROM staff WHERE firebase_uid = ?", (claims["uid"],)
        ).fetchone()
        conn.close()
        return row
    conn.close()
    return None


def require_staff_auth(fn):
    @wraps(fn)
    def wrapper(*args, **kwargs):
        token = get_bearer_token()
        if not token:
            return jsonify({"error": "Unauthorized", "message": "Missing bearer token"}), 401
        row = get_current_staff_optional()
        if not row or not row["active"]:
            return jsonify({"error": "Unauthorized", "message": "Staff account not found or inactive"}), 401
        if _rate_limit_authenticated(f"staff:{row['id']}"):
            return jsonify({"error": "Too Many Requests", "message": "Slow down and try again shortly"}), 429
        request.staff = row
        return fn(*args, **kwargs)
    return wrapper


def _owner_identity_ok():
    """True only for an owner row whose live request carries a verified,
    allowlisted Google Firebase identity. A legacy staff JWT (including one
    from phone/PIN login) never qualifies. Call inside a request that has
    already passed require_staff_auth."""
    if request.staff["role"] != "owner":
        return False
    token = get_bearer_token()
    if not token or decode_staff_token(token):
        return False
    claims = verify_firebase_token(token)
    email = (claims.get("email") or "").strip().lower() if claims else ""
    return bool(
        claims and claims.get("sign_in_provider") == "google.com" and
        claims.get("email_verified") and email and
        email in _STAFF_BOOTSTRAP_OWNER_EMAILS
    )


def require_owner(fn):
    @wraps(fn)
    @require_staff_auth
    def wrapper(*args, **kwargs):
        if request.staff["role"] != "owner":
            return jsonify({"error": "Forbidden", "message": "Owner role required"}), 403
        # Owner actions require a live Firebase identity whose verified
        # address is explicitly configured. A legacy staff JWT (including
        # one minted by the phone/PIN endpoint) is never sufficient.
        if not _owner_identity_ok():
            return jsonify({"error": "Forbidden", "message": "Verified allowlisted Google identity required"}), 403
        return fn(*args, **kwargs)
    return wrapper


def get_current_technician_optional():
    """Same shape as get_current_user_optional/get_current_staff_optional,
    for the technicians table — used by endpoints that accept a customer,
    staff, or technician token and decide access based on which one
    actually shows up."""
    token = get_bearer_token()
    if not token:
        return None
    claims = verify_firebase_token(token)
    if not claims:
        return None
    conn = get_db()
    row = conn.execute(
        "SELECT * FROM technicians WHERE firebase_uid = ?", (claims["uid"],)
    ).fetchone()
    conn.close()
    return row


def require_technician_auth(fn):
    """Technicians only ever authenticate via Firebase (the Partner app) —
    there's no legacy backend JWT for them, since technician.html has
    never had a login system."""
    @wraps(fn)
    def wrapper(*args, **kwargs):
        token = get_bearer_token()
        claims = verify_firebase_token(token) if token else None
        if not claims:
            return jsonify({"error": "Unauthorized", "message": "Invalid or missing Firebase token"}), 401
        conn = get_db()
        row = conn.execute(
            "SELECT * FROM technicians WHERE firebase_uid = ?", (claims["uid"],)
        ).fetchone()
        conn.close()
        if not row:
            return jsonify({"error": "Unauthorized", "message": "No technician profile — call /api/technician/bootstrap first"}), 401
        if _rate_limit_authenticated(f"tech:{row['id']}"):
            return jsonify({"error": "Too Many Requests", "message": "Slow down and try again shortly"}), 429
        request.technician = row
        return fn(*args, **kwargs)
    return wrapper


@app.route("/api/staff/login", methods=["POST"])
@validate_json({
    "phone": Field(str, required=True, pattern=PHONE_RE),
    "pin": Field(str, required=True, pattern=PIN_RE, strip=False),
})
def staff_login():
    """Phone + PIN login — a PIN is short (a handful of digits), so this is
    exactly the kind of endpoint a brute-force script would target. AUTH
    tier: gated per phone number (so guessing one account's PIN is slow)
    AND per IP (so rotating phone numbers from one source doesn't dodge the
    first limit), with exponential backoff rather than a flat lockout — see
    _auth_gate/_auth_gate_record."""
    data = request.get_json(force=True, silent=True) or {}
    phone = (data.get("phone") or "").strip()
    pin = data.get("pin") or ""
    gated = _auth_gate(phone)
    if gated:
        return gated
    conn = get_db()
    row = conn.execute("SELECT * FROM staff WHERE phone = ?", (phone,)).fetchone()
    conn.close()
    ok = bool(row and row["active"] and check_password_hash(row["pin_hash"], pin))
    # Owner accounts are Google-identity-only. Return the same response for
    # any PIN attempt so callers cannot use status differences to confirm a
    # correct owner PIN.
    if not ok or row["role"] == "owner":
        _auth_gate_record(phone, False)
        return jsonify({"error": "Invalid phone or PIN"}), 401
    _auth_gate_record(phone, True)
    return jsonify({"token": generate_staff_token(row["id"]), "staff": staff_row_to_dict(row)})


@app.route("/api/staff/me", methods=["GET"])
@require_staff_auth
def staff_me():
    return jsonify(staff_row_to_dict(request.staff))


# Comma-separated, case-insensitive owner identity allowlist. Missing or
# empty configuration fails closed: it never creates an owner or a staff
# record through public Firebase bootstrap.
# STAGING-ONLY switch (server-side; never client-supplied). When set, a
# technician application may be submitted without the identity/bank document
# images (Storage isn't available in that environment); the application still
# waits for owner approval. Unset (production default) = Aadhaar front/back
# and PAN images are required to submit.
_TECH_DOCS_DEFERRED = (os.environ.get("TECHNICIAN_DOCUMENTS_DEFERRED") or "").strip().lower() in (
    "1", "true", "yes",
)

_REQUIRED_APPLICATION_DOCS = (
    ("aadhar_document_url", "aadharDocumentUrl", "Aadhaar front image"),
    ("aadhar_document_back_url", "aadharDocumentBackUrl", "Aadhaar back image"),
    ("pan_document_url", "panDocumentUrl", "PAN image"),
)

_STAFF_BOOTSTRAP_OWNER_EMAILS = {
    e.strip().lower()
    for e in (os.environ.get("STAFF_BOOTSTRAP_OWNER_EMAILS") or "").split(",")
    if e.strip()
}


@app.route("/api/staff/bootstrap", methods=["POST"])
@validate_json({
    "name": Field(str, max_len=100),
    "role": Field(str, choices=("owner", "staff")),
})
def bootstrap_staff():
    """Resolve an existing staff invitation or the explicitly allowlisted owner.

    Public Firebase sign-up never creates a staff account. Existing staff
    rows can be linked by Firebase UID, verified email, or verified phone;
    a new owner is created only for a verified email in the configured
    allowlist. The optional ``role`` is the workspace the person chose at
    sign-in; it never grants anything, it only has to MATCH what the backend
    independently resolves ("owner" needs the allowlisted Google identity,
    "staff" refuses an owner identity), otherwise 403 and nothing is written.
    """
    token = get_bearer_token()
    claims = verify_firebase_token(token) if token else None
    if not claims:
        return jsonify({"error": "Unauthorized", "message": "Invalid or missing Firebase token"}), 401

    data = request.get_json(force=True, silent=True) or {}
    name = (data.get("name") or claims.get("name") or "").strip() or "Staff"
    email = (claims.get("email") or "").strip().lower()
    verified_email = bool(email and claims.get("email_verified"))
    is_allowlisted_owner = bool(
        verified_email and claims.get("sign_in_provider") == "google.com" and
        _STAFF_BOOTSTRAP_OWNER_EMAILS and
        email in _STAFF_BOOTSTRAP_OWNER_EMAILS
    )

    requested_role = data.get("role")
    if requested_role == "owner" and not is_allowlisted_owner:
        return jsonify({
            "error": "Forbidden",
            "message": "Owner sign-in requires the configured owner Google account",
        }), 403

    conn = get_db()
    # Serialize the "is there any staff yet?" decision against concurrent
    # first-bootstraps: SQLite takes the write lock immediately (BEGIN
    # IMMEDIATE); Postgres takes a transaction-scoped advisory lock keyed
    # to this decision (a SELECT FOR UPDATE can't lock what doesn't exist
    # yet, but an advisory lock locks the decision itself).
    if not database.DATABASE_URL:
        if not conn.in_transaction:
            conn.execute("BEGIN IMMEDIATE")
    else:
        conn.execute("SELECT pg_advisory_xact_lock(hashtext('rasoicare-owner-bootstrap'))")
    try:
        row = conn.execute("SELECT * FROM staff WHERE firebase_uid = ?", (claims["uid"],)).fetchone()
        if not row and verified_email:
            row = conn.execute(
                "SELECT * FROM staff WHERE LOWER(email) = ?", (email,)
            ).fetchone()
        phone_digits = re.sub(r"\D", "", str(claims.get("phone_number") or ""))
        if not row and 10 <= len(phone_digits) <= 15:
            # Firebase only supplies phone_number after phone verification.
            # Match the existing invited staff roster; never create staff
            # from a new phone number here.
            candidates = conn.execute(
                "SELECT * FROM staff WHERE phone IS NOT NULL AND active = 1"
            ).fetchall()
            matches = [
                candidate for candidate in candidates
                if re.sub(r"\D", "", str(candidate["phone"] or ""))[-10:] == phone_digits[-10:]
            ]
            if len(matches) == 1:
                row = matches[0]

        ts = now()
        if requested_role == "staff" and (is_allowlisted_owner or (row and row["role"] == "owner")):
            conn.rollback()
            conn.close()
            return jsonify({
                "error": "Forbidden",
                "message": "This is the owner account. Choose Owner to sign in.",
            }), 403
        if row and not row["active"] and row["role"] != "owner":
            # A deactivated staff assignment grants nothing and is not
            # touched: this identity is simply "not staff" (it may still be
            # an approved technician, which lives in a separate table).
            conn.rollback()
            conn.close()
            return jsonify({"error": "Forbidden", "message": "No active staff invitation for this identity"}), 403
        if row:
            role = row["role"]
            if is_allowlisted_owner:
                role = "owner"
            # Existing owner records may only be attached to the allowlisted
            # verified Google identity. This prevents an old PIN-only owner
            # record from silently becoming an owner through phone auth.
            elif role == "owner":
                conn.rollback()
                conn.close()
                return jsonify({"error": "Forbidden", "message": "Verified allowlisted Google identity required"}), 403
            conn.execute(
                "UPDATE staff SET firebase_uid = ?, email = COALESCE(email, ?), name = ?, role = ? WHERE id = ?",
                (claims["uid"], email if verified_email else None, name, role, row["id"]),
            )
            staff_id = row["id"]
        elif is_allowlisted_owner:
            # Reuse one unlinked owner roster row when present (for example,
            # the staging PIN-seeded row), otherwise provision this one
            # explicitly allowlisted identity as owner. Other staff rows do
            # not prevent the configured owner from joining.
            unlinked_owner = conn.execute(
                "SELECT * FROM staff WHERE role = 'owner' AND active = 1 "
                "AND (firebase_uid IS NULL OR firebase_uid = '') "
                "AND (email IS NULL OR email = '') ORDER BY created_at LIMIT 1"
            ).fetchone()
            if unlinked_owner:
                staff_id = unlinked_owner["id"]
                conn.execute(
                    "UPDATE staff SET firebase_uid = ?, email = ?, name = ? WHERE id = ?",
                    (claims["uid"], email, name, staff_id),
                )
            else:
                staff_id = new_uuid_id("STF")
                conn.execute(
                    "INSERT INTO staff (id, name, phone, email, pin_hash, role, active, created_at, firebase_uid) "
                    "VALUES (?,?,?,?,?,'owner',1,?,?)",
                    (staff_id, name, f"fb-{claims['uid'][:24]}", email,
                     "firebase-auth", ts, claims["uid"]),
                )
        else:
            conn.rollback()
            conn.close()
            return jsonify({"error": "Forbidden", "message": "No active staff invitation for this identity"}), 403
        conn.commit()
    except Exception:
        try:
            conn.rollback()
        except Exception:
            pass
        raise
    row = conn.execute("SELECT * FROM staff WHERE id = ?", (staff_id,)).fetchone()
    conn.close()
    if not row["active"]:
        return jsonify({"error": "Unauthorized", "message": "Staff account not found or inactive"}), 401
    return jsonify(staff_row_to_dict(row))


@app.route("/api/staff", methods=["GET"])
@require_owner
def list_staff():
    conn = get_db()
    rows = conn.execute("SELECT * FROM staff ORDER BY name").fetchall()
    conn.close()
    return jsonify([staff_row_to_dict(r) for r in rows])


@app.route("/api/staff", methods=["POST"])
@require_owner
@validate_json({
    "name": Field(str, required=True, min_len=1, max_len=100),
    "phone": Field(str, required=True, pattern=PHONE_RE),
    "pin": Field(str, required=True, pattern=PIN_RE, strip=False),
    "role": Field(str, choices=("owner", "staff")),
})
def invite_staff():
    data = request.get_json(force=True, silent=True) or {}
    name = (data.get("name") or "").strip()
    phone = (data.get("phone") or "").strip()
    pin = data.get("pin") or ""
    role = data.get("role") or "staff"
    if not name or not phone or len(pin) < 4:
        return jsonify({"error": "name, phone, and a pin of at least 4 digits are required"}), 400
    if role not in ("owner", "staff"):
        return jsonify({"error": "role must be 'owner' or 'staff'"}), 400
    if role == "owner":
        return jsonify({"error": "Owner access is granted only to an allowlisted, verified Google identity"}), 400

    conn = get_db()
    existing = conn.execute("SELECT id FROM staff WHERE phone = ?", (phone,)).fetchone()
    if existing:
        conn.close()
        return jsonify({"error": "A staff account with this phone already exists"}), 409
    staff_id = new_uuid_id("STF")
    conn.execute(
        "INSERT INTO staff (id, name, phone, pin_hash, role, active, created_at) VALUES (?,?,?,?,?,1,?)",
        (staff_id, name, phone, generate_password_hash(pin), role, now()),
    )
    conn.commit()
    row = conn.execute("SELECT * FROM staff WHERE id = ?", (staff_id,)).fetchone()
    conn.close()
    return jsonify(staff_row_to_dict(row)), 201


@app.route("/api/staff/<staff_id>", methods=["PATCH"])
@require_owner
@validate_json({
    "role": Field(str, choices=("owner", "staff")),
    "active": Field(bool),
})
def update_staff(staff_id):
    data = request.get_json(force=True, silent=True) or {}
    conn = get_db()
    row = conn.execute("SELECT * FROM staff WHERE id = ?", (staff_id,)).fetchone()
    if not row:
        conn.close()
        return jsonify({"error": "not found"}), 404
    role = data.get("role", row["role"])
    active = int(data["active"]) if "active" in data else row["active"]
    if role not in ("owner", "staff"):
        conn.close()
        return jsonify({"error": "role must be 'owner' or 'staff'"}), 400
    if role == "owner":
        conn.close()
        return jsonify({"error": "Owner access is granted only to an allowlisted, verified Google identity"}), 400
    conn.execute("UPDATE staff SET role = ?, active = ? WHERE id = ?", (role, active, staff_id))
    conn.commit()
    row = conn.execute("SELECT * FROM staff WHERE id = ?", (staff_id,)).fetchone()
    conn.close()
    return jsonify(staff_row_to_dict(row))


@app.route("/api/auth/register", methods=["POST"])
@validate_json({
    "email": Field(str, required=True, max_len=254, pattern=EMAIL_RE),
    "password": Field(str, required=True, min_len=6, max_len=128, strip=False),
    "name": Field(str, required=True, min_len=1, max_len=100),
    "phone": Field(str, pattern=PHONE_RE),
})
def auth_register():
    """AUTH tier — not a credential *check* like login, but repeated
    registration attempts (email enumeration, signup spam) are exactly the
    kind of thing this tier exists for, so it's gated the same way: per
    submitted email and per IP, with backoff. Every call counts as a
    "failure" for backoff purposes regardless of outcome — there's no
    legitimate reason for one email/IP to be hitting this endpoint
    repeatedly in a short window the way there is for login."""
    data = request.get_json(force=True, silent=True) or {}
    email = (data.get("email") or "").strip().lower()
    password = data.get("password") or ""
    name = (data.get("name") or "").strip()
    phone = data.get("phone")

    gated = _auth_gate(email)
    if gated:
        return gated

    if not email or not EMAIL_RE.match(email):
        _auth_gate_record(email, False)
        return jsonify({"error": "A valid email is required"}), 400
    if len(password) < 6:
        _auth_gate_record(email, False)
        return jsonify({"error": "Password must be at least 6 characters"}), 400
    if not name:
        _auth_gate_record(email, False)
        return jsonify({"error": "Name is required"}), 400

    conn = get_db()
    existing = conn.execute("SELECT id FROM users WHERE email = ?", (email,)).fetchone()
    if existing:
        conn.close()
        _auth_gate_record(email, False)
        return jsonify({"error": "Email already registered"}), 409

    user_id = new_uuid_id("USR")
    conn.execute(
        "INSERT INTO users (id, email, password_hash, name, phone, created_at) VALUES (?,?,?,?,?,?)",
        (user_id, email, generate_password_hash(password), name, phone, now()),
    )
    conn.commit()
    row = conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
    conn.close()
    _auth_gate_record(email, True)
    return jsonify({"token": generate_token(user_id), "user": user_row_to_dict(row)}), 201


@app.route("/api/auth/login", methods=["POST"])
@validate_json({
    "email": Field(str, required=True, max_len=254, pattern=EMAIL_RE),
    "password": Field(str, required=True, min_len=1, max_len=128, strip=False),
})
def auth_login():
    """AUTH tier — see staff_login's doc comment; same per-account/per-IP
    backoff, keyed by the submitted email instead of phone."""
    data = request.get_json(force=True, silent=True) or {}
    email = (data.get("email") or "").strip().lower()
    password = data.get("password") or ""

    gated = _auth_gate(email)
    if gated:
        return gated

    conn = get_db()
    row = conn.execute("SELECT * FROM users WHERE email = ?", (email,)).fetchone()
    conn.close()
    ok = bool(row and check_password_hash(row["password_hash"], password))
    _auth_gate_record(email, ok)
    if not ok:
        return jsonify({"error": "Invalid email or password"}), 401

    return jsonify({"token": generate_token(row["id"]), "user": user_row_to_dict(row)})


@app.route("/api/auth/phone/send-otp", methods=["POST"])
@validate_json({
    "phone": Field(str, required=True, pattern=PHONE_RE),
})
def auth_phone_send_otp():
    """Starts the Customer web app's phone sign-in. AUTH tier — gated per
    phone number and per IP, same as staff_login, since this is exactly
    the kind of endpoint a scripted client would hammer to enumerate
    working phone numbers or exhaust the SMS budget."""
    data = request.get_json(force=True, silent=True) or {}
    phone = data["phone"]
    gated = _auth_gate(f"webphone:{phone}")
    if gated:
        return gated
    code = _web_phone_otp_request(phone)
    sent = send_sms(
        f"+91{phone}",
        f"Rasoi Care: your sign-in code is {code}. It expires in "
        f"{WEB_PHONE_OTP_TTL_SECONDS // 60} minutes.",
        request_id=f"webphone-{phone}",
    )
    # Every call here counts toward the gate regardless of outcome — same
    # reasoning as auth_register: there's no legitimate reason for one
    # phone/IP to be hitting this repeatedly in a short window.
    _auth_gate_record(f"webphone:{phone}", True)
    if not sent:
        return jsonify({
            "sent": False,
            "message": "We couldn't text you a code just now — try again in a moment.",
        })
    return jsonify({"sent": True})


@app.route("/api/auth/phone/verify-otp", methods=["POST"])
@validate_json({
    "phone": Field(str, required=True, pattern=PHONE_RE),
    "otp": Field(str, required=True, pattern=CODE_RE, strip=False),
})
def auth_phone_verify_otp():
    """Verifies the code from send-otp above. An existing account with
    this phone logs straight in; a phone with no account yet is instead
    marked verified (see _web_phone_take_verified) so
    /api/auth/phone/register can finish creating one without asking for
    the code a second time."""
    data = request.get_json(force=True, silent=True) or {}
    phone = data["phone"]
    otp = data["otp"]
    gated = _auth_gate(f"webphone:{phone}")
    if gated:
        return gated
    error = _web_phone_otp_verify(phone, otp)
    _auth_gate_record(f"webphone:{phone}", error is None)
    if error:
        return jsonify({"error": "Invalid code", "message": error}), 400
    conn = get_db()
    row = conn.execute("SELECT * FROM users WHERE phone = ?", (phone,)).fetchone()
    conn.close()
    if row:
        return jsonify({"token": generate_token(row["id"]), "user": user_row_to_dict(row)})
    return jsonify({"needsRegistration": True})


@app.route("/api/auth/phone/register", methods=["POST"])
@validate_json({
    "phone": Field(str, required=True, pattern=PHONE_RE),
    "name": Field(str, required=True, min_len=1, max_len=100),
    "email": Field(str, max_len=254, pattern=EMAIL_RE),
})
def auth_phone_register():
    """Finishes sign-up for a phone that just passed OTP verification
    above and has no existing account yet. The new account's password is
    a random secret that's never disclosed anywhere — sign-in for it only
    ever happens through the phone-OTP flow again, so there's nothing to
    derive or guess (unlike the old `'rc-' + phone` scheme this replaces)."""
    data = request.get_json(force=True, silent=True) or {}
    phone = data["phone"]
    name = data["name"].strip()
    email = (data.get("email") or "").strip().lower() or f"{phone}@rasoicare.demo"

    if not _web_phone_take_verified(phone):
        return jsonify({
            "error": "Phone not verified",
            "message": "Verify your phone with a fresh code first.",
        }), 400

    conn = get_db()
    # Normally verify-otp already logs a phone with an existing account
    # straight in and never sends the client here — but the phone genuinely
    # did just prove ownership via a real code, so if this endpoint gets
    # called anyway (e.g. a stale client, a retried request), log into the
    # existing account rather than erroring.
    existing_phone = conn.execute("SELECT * FROM users WHERE phone = ?", (phone,)).fetchone()
    if existing_phone:
        conn.close()
        return jsonify({
            "token": generate_token(existing_phone["id"]),
            "user": user_row_to_dict(existing_phone),
        })
    if conn.execute("SELECT id FROM users WHERE email = ?", (email,)).fetchone():
        conn.close()
        return jsonify({"error": "Email already registered"}), 409

    user_id = new_uuid_id("USR")
    conn.execute(
        "INSERT INTO users (id, email, password_hash, name, phone, created_at) VALUES (?,?,?,?,?,?)",
        (user_id, email, generate_password_hash(secrets.token_urlsafe(32)), name, phone, now()),
    )
    conn.commit()
    row = conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
    conn.close()
    return jsonify({"token": generate_token(user_id), "user": user_row_to_dict(row)}), 201


@app.route("/api/auth/me", methods=["GET"])
@require_auth
def auth_me():
    return jsonify(user_row_to_dict(request.user))


@app.route("/api/me/bootstrap", methods=["POST"])
@validate_json({
    "name": Field(str, max_len=100),
    "phone": Field(str, pattern=PHONE_RE),
})
def bootstrap_customer():
    """Called once right after Firebase sign-in/sign-up in the Customer
    app. Finds or creates the matching `users` row (keyed by Firebase
    uid, falling back to email so an old password-based account someone
    already had keeps its history) and returns it — every other endpoint
    the app calls afterwards just uses the same Firebase ID token and
    resolves back to this same row."""
    token = get_bearer_token()
    claims = verify_firebase_token(token) if token else None
    if not claims:
        return jsonify({"error": "Unauthorized", "message": "Invalid or missing Firebase token"}), 401

    data = request.get_json(force=True, silent=True) or {}
    name = (data.get("name") or claims.get("name") or "").strip() or "Customer"
    # A Firebase-verified phone number beats whatever the client claims —
    # previously this only looked at the request body, which the Customer
    # app's phone-OTP sign-in never actually populates, so a technician's
    # "Call" action had no real number to dial for the overwhelming
    # majority of customers even though Firebase had it the whole time.
    phone = claims.get("phone_number") or data.get("phone")

    conn = get_db()
    row = conn.execute("SELECT * FROM users WHERE firebase_uid = ?", (claims["uid"],)).fetchone()
    if not row and claims.get("email") and claims.get("email_verified"):
        row = conn.execute("SELECT * FROM users WHERE email = ?", (claims["email"],)).fetchone()
    ts = now()
    if row:
        conn.execute(
            "UPDATE users SET firebase_uid = ?, name = ?, phone = COALESCE(?, phone) WHERE id = ?",
            (claims["uid"], name, phone, row["id"]),
        )
        user_id = row["id"]
    else:
        user_id = new_uuid_id("USR")
        # An unverified email can't be trusted as this new row's own email
        # either — besides the same account-takeover concern as the
        # lookup above, `users.email` is UNIQUE, so reusing an email
        # already claimed by someone else's real account would otherwise
        # crash this insert outright.
        safe_email = claims.get("email") if claims.get("email_verified") else None
        conn.execute(
            "INSERT INTO users (id, email, password_hash, name, phone, created_at, firebase_uid) "
            "VALUES (?,?,?,?,?,?,?)",
            (user_id, safe_email or f"{claims['uid']}@firebase.local",
             "firebase-auth", name, phone, ts, claims["uid"]),
        )
    conn.commit()
    row = conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
    conn.close()
    return jsonify(user_row_to_dict(row))


SHOP_PRODUCTS = {
    "chimney_kit": {"name": "Chimney Cleaning Kit", "price_paise": 14900},
    "cooktop_kit": {"name": "Cooktop & Hob Cleaning Kit", "price_paise": 11900},
    "dishwasher_kit": {"name": "Dishwasher Cleaning Kit", "price_paise": 12900},
    "microwave_kit": {"name": "Microwave Cleaning Kit", "price_paise": 11900},
    "refrigerator_kit": {"name": "Refrigerator Cleaning Kit", "price_paise": 9900},
}


@app.route("/api/shop/orders", methods=["POST"])
@require_auth
@validate_json({
    "items": Field(list, required=True, min_len=1, max_len=50, item_type=dict),
})
def create_shop_order():
    """Places a real order for one or more cleaning kits — prices are looked
    up from SHOP_PRODUCTS server-side (never trusted from the client) so a
    tampered request can't under-charge. No payment gateway exists in this
    codebase (see PaymentScreen), so like bookings this is pay-on-delivery:
    placing the order just records it for fulfillment."""
    data = request.get_json(force=True, silent=True) or {}
    items = data.get("items")
    if not isinstance(items, list) or not items:
        return jsonify({"error": "items must be a non-empty list"}), 400

    order_items = []
    total_paise = 0
    for entry in items:
        product_id = entry.get("productId") if isinstance(entry, dict) else None
        product = SHOP_PRODUCTS.get(product_id)
        if not product:
            return jsonify({"error": f"Unknown product: {product_id}"}), 400
        try:
            qty = int(entry.get("qty", 0))
        except (TypeError, ValueError):
            return jsonify({"error": "qty must be a whole number"}), 400
        if qty <= 0:
            return jsonify({"error": "qty must be positive"}), 400
        subtotal = product["price_paise"] * qty
        order_items.append({
            "productId": product_id,
            "name": product["name"],
            "qty": qty,
            "unitPricePaise": product["price_paise"],
            "subtotalPaise": subtotal,
        })
        total_paise += subtotal

    order_id = new_uuid_id("ORD")
    conn = get_db()
    conn.execute(
        "INSERT INTO shop_orders (id, user_id, items_json, total_paise, status, created_at) "
        "VALUES (?,?,?,?,?,?)",
        (order_id, request.user["id"], json.dumps(order_items), total_paise, "Placed", now()),
    )
    conn.commit()
    row = conn.execute("SELECT * FROM shop_orders WHERE id = ?", (order_id,)).fetchone()
    conn.close()
    return jsonify(shop_order_row_to_dict(row)), 201


@app.route("/api/shop/orders", methods=["GET"])
@require_auth
def list_shop_orders():
    conn = get_db()
    rows = conn.execute(
        "SELECT * FROM shop_orders WHERE user_id = ? ORDER BY created_at DESC",
        (request.user["id"],),
    ).fetchall()
    conn.close()
    return jsonify([shop_order_row_to_dict(r) for r in rows])


@app.route("/api/me/coins/redeem", methods=["POST"])
@require_auth
@validate_json({
    "amount": Field(int, required=True, min_val=1, max_val=1_000_000),
})
def redeem_coins():
    """Called by the Customer app's checkout when the customer opts to use
    Care Coins — deducts up to their real balance and returns the updated
    profile, so the client can knock that many rupees off the payable
    total (1 coin = ₹1). Decoupled from booking creation (a multi-service
    cart creates one booking row per service) so redemption happens
    exactly once per checkout regardless of how many bookings follow."""
    data = request.get_json(force=True, silent=True) or {}
    try:
        amount = int(data.get("amount", 0))
    except (TypeError, ValueError):
        return jsonify({"error": "amount must be a whole number of coins"}), 400
    if amount <= 0:
        return jsonify({"error": "amount must be positive"}), 400

    conn = get_db()
    # The balance check and the decrement happen in one atomic statement —
    # a plain SELECT-then-UPDATE would let two concurrent requests both
    # read the same starting balance, both pass the check, and both
    # deduct, driving coins_balance negative (double-spending the same
    # coins). The WHERE clause makes the decrement itself conditional, so
    # only one of two racing requests can ever succeed.
    cur = conn.execute(
        "UPDATE users SET coins_balance = coins_balance - ? WHERE id = ? AND coins_balance >= ?",
        (amount, request.user["id"], amount),
    )
    conn.commit()
    if cur.rowcount == 0:
        conn.close()
        return jsonify({"error": "Not enough Care Coins"}), 400
    row = conn.execute("SELECT * FROM users WHERE id = ?", (request.user["id"],)).fetchone()
    conn.close()
    return jsonify(user_row_to_dict(row))


# ---------------------------------------------------------------- health
@app.route("/api/health", methods=["GET"])
@rate_limit_public
def health():
    return jsonify({"ok": True, "service": "rasoicare-backend"})


# ---------------------------------------------------------------- appliances
@app.route("/api/appliances", methods=["GET"])
@rate_limit_public
def list_appliances():
    category = request.args.get("category")
    conn = get_db()
    if category:
        rows = conn.execute(
            "SELECT * FROM appliances WHERE category = ? ORDER BY name", (category,)
        ).fetchall()
    else:
        rows = conn.execute("SELECT * FROM appliances ORDER BY name").fetchall()
    conn.close()
    return jsonify([appliance_row_to_dict(r) for r in rows])


@app.route("/api/appliances/<appliance_id>", methods=["GET"])
@rate_limit_public
def get_appliance(appliance_id):
    conn = get_db()
    row = conn.execute("SELECT * FROM appliances WHERE id = ?", (appliance_id,)).fetchone()
    conn.close()
    if not row:
        return jsonify({"error": "Appliance not found"}), 404
    return jsonify(appliance_row_to_dict(row))


# ---------------------------------------------------------------- services
SERVICE_SELECT = (
    "SELECT services.*, appliances.name AS appliance_name FROM services "
    "JOIN appliances ON appliances.id = services.appliance_id"
)


@app.route("/api/services", methods=["GET"])
@rate_limit_public
def list_services():
    category = request.args.get("category")
    quick_fix_param = request.args.get("quick_fix")

    clauses, params = [], []
    if category:
        clauses.append("services.category = ?")
        params.append(category)
    if quick_fix_param is not None:
        clauses.append("services.quick_fix = ?")
        params.append(1 if quick_fix_param.lower() in ("true", "1", "yes") else 0)

    sql = SERVICE_SELECT
    if clauses:
        sql += " WHERE " + " AND ".join(clauses)
    sql += " ORDER BY services.name"

    conn = get_db()
    rows = conn.execute(sql, params).fetchall()
    conn.close()
    return jsonify([service_row_to_dict(r) for r in rows])


@app.route("/api/services/<service_id>", methods=["GET"])
@rate_limit_public
def get_service(service_id):
    conn = get_db()
    row = conn.execute(SERVICE_SELECT + " WHERE services.id = ?", (service_id,)).fetchone()
    conn.close()
    if not row:
        return jsonify({"error": "Service not found"}), 404
    return jsonify(service_row_to_dict(row))



# ---------------------------------------------------------------- kitchen health score
def appliance_health_row_to_dict(row):
    return {
        "id": row["id"],
        "appliance_id": row["appliance_id"],
        "appliance_name": row["appliance_name"],
        "metric_name": row["metric_name"],
        "value_pct": row["value_pct"],
        "status_label": row["status_label"],
        "updated_at": row["updated_at"],
    }


HEALTH_SELECT = (
    "SELECT appliance_health.*, appliances.name AS appliance_name FROM appliance_health "
    "JOIN appliances ON appliances.id = appliance_health.appliance_id"
)


@app.route("/api/health-score", methods=["GET"])
@require_auth
def get_health_score():
    conn = get_db()
    rows = conn.execute(
        HEALTH_SELECT + " WHERE appliance_health.user_id = ? ORDER BY appliance_health.updated_at DESC",
        (request.user["id"],),
    ).fetchall()
    conn.close()
    return jsonify([appliance_health_row_to_dict(r) for r in rows])


@app.route("/api/bookings/<booking_id>/health-update", methods=["POST"])
@require_technician_auth
@validate_json({
    "metric_name": Field(str, required=True, min_len=1, max_len=100),
    "status_label": Field(str, required=True, min_len=1, max_len=100),
    "value_pct": Field(int, required=True, min_val=0, max_val=100),
})
def update_booking_health(booking_id):
    """Called by the Partner app after completing a job. Requires the same
    Firebase-verified technician session as /advance, and only the
    technician actually assigned to this booking can post a health update
    for it — otherwise any technician could write appliance-health data
    onto a stranger's booking. technician.html has no login system and
    can't send this, so its own health-update button already stopped
    working when /advance picked up the same auth requirement."""
    data = request.get_json(force=True, silent=True) or {}
    metric_name = data["metric_name"].strip()
    status_label = data["status_label"].strip()
    value_pct = data["value_pct"]

    conn = get_db()
    booking = conn.execute(BOOKING_SELECT + " WHERE bookings.id = ?", (booking_id,)).fetchone()
    if not booking:
        conn.close()
        return jsonify({"error": "not found"}), 404
    if booking["technician_id"] != request.technician["id"]:
        # 404, not 403 — booking ids are sequential, so a 403 here would
        # confirm the id exists and belongs to someone else, the same
        # enumeration every other booking-scoped route avoids.
        conn.close()
        return jsonify({"error": "not found"}), 404
    if not booking["user_id"]:
        conn.close()
        return jsonify({"error": "This booking has no associated user account"}), 400

    appliance_id = None
    if booking["service_id"]:
        service_row = conn.execute(
            "SELECT appliance_id FROM services WHERE id = ?", (booking["service_id"],)
        ).fetchone()
        if service_row:
            appliance_id = service_row["appliance_id"]
    if not appliance_id:
        # Legacy bookings (Bachat Package etc.) have no service_id — fall
        # back to the first appliance in the booking's category family.
        fallback = conn.execute(
            "SELECT id FROM appliances WHERE category = ? LIMIT 1", (booking["category"],)
        ).fetchone()
        appliance_id = fallback["id"] if fallback else None
    if not appliance_id:
        conn.close()
        return jsonify({"error": "Could not resolve an appliance for this booking"}), 400

    health_id = new_uuid_id("HEALTH")
    conn.execute(
        "INSERT INTO appliance_health (id, user_id, appliance_id, metric_name, value_pct, status_label, updated_at) "
        "VALUES (?,?,?,?,?,?,?) "
        "ON CONFLICT(user_id, appliance_id) DO UPDATE SET "
        "metric_name=excluded.metric_name, value_pct=excluded.value_pct, "
        "status_label=excluded.status_label, updated_at=excluded.updated_at",
        (health_id, booking["user_id"], appliance_id, metric_name, value_pct, status_label, now()),
    )
    conn.commit()
    row = conn.execute(
        HEALTH_SELECT + " WHERE appliance_health.user_id = ? AND appliance_health.appliance_id = ?",
        (booking["user_id"], appliance_id),
    ).fetchone()
    conn.close()
    return jsonify(appliance_health_row_to_dict(row)), 201


# ---------------------------------------------------------------- bookings
@app.route("/api/bookings", methods=["GET"])
def list_bookings():
    """Used to be auth-optional: with no Bearer token at all it returned
    every booking in the system (every customer's name/phone/address), so
    anyone who found the URL could scrape the whole booking log. Now a
    valid token is mandatory — a customer token scopes to that customer's
    own bookings (the app's "my bookings" view); a staff token gets the
    full ops list the Admin app/admin.html need. technician.html sends
    neither (it has no login system) and so no longer gets a response —
    an accepted regression, same as the /advance and /health-update gates
    it was already broken against."""
    user = get_current_user_optional()
    staff = get_current_staff_optional() if not user else None
    if not user and not staff:
        return jsonify({"error": "Unauthorized", "message": "Missing or invalid bearer token"}), 401
    conn = get_db()
    if user:
        rows = conn.execute(
            BOOKING_LIST_SELECT + " WHERE bookings.user_id = ? ORDER BY bookings.created_at DESC",
            (user["id"],),
        ).fetchall()
    else:
        limit, offset = _pagination_args()
        rows = conn.execute(
            BOOKING_LIST_SELECT + " ORDER BY bookings.created_at DESC LIMIT ? OFFSET ?",
            (limit, offset),
        ).fetchall()
    parts_by_booking = fetch_booking_parts_bulk(conn, [r["id"] for r in rows])
    service_changes_by_booking = fetch_booking_service_changes_bulk(conn, [r["id"] for r in rows])
    conn.close()
    return jsonify([
        booking_row_to_dict(
            r,
            include_start_code=bool(user),
            parts=parts_by_booking.get(r["id"]),
            service_changes=service_changes_by_booking.get(r["id"]),
        )
        for r in rows
    ])


@app.route("/api/bookings/<booking_id>", methods=["GET"])
def get_booking(booking_id):
    """Same auth requirement as list_bookings: a customer token can only
    fetch their own booking (404s otherwise, not 403, to avoid confirming
    other ids exist); a staff token can fetch any booking."""
    user = get_current_user_optional()
    staff = get_current_staff_optional() if not user else None
    if not user and not staff:
        return jsonify({"error": "Unauthorized", "message": "Missing or invalid bearer token"}), 401
    conn = get_db()
    row = conn.execute(BOOKING_SELECT + " WHERE bookings.id = ?", (booking_id,)).fetchone()
    if not row:
        conn.close()
        return jsonify({"error": "not found"}), 404
    if user and row["user_id"] and row["user_id"] != user["id"]:
        conn.close()
        return jsonify({"error": "not found"}), 404
    parts = fetch_booking_parts(conn, booking_id)
    service_changes = fetch_booking_service_changes(conn, booking_id)
    conn.close()
    return jsonify(booking_row_to_dict(
        row, include_start_code=bool(user), parts=parts, service_changes=service_changes,
    ))


# httpSMS (https://httpsms.com) turns a real Android phone with a SIM into
# an HTTP-callable SMS gateway — used here to text a customer their
# booking's start code as a backup to seeing it in-app. Configuring it is
# entirely optional: HTTPSMS_API_KEY comes from the httpSMS account's
# settings page, and HTTPSMS_FROM_NUMBER is the E.164 number of the
# Android phone registered to that account. Same "never block the real
# feature for an optional integration" spirit as verify_firebase_token's
# cert fetch above — a missing/failed send never raises and never keeps a
# booking from being created.
HTTPSMS_API_KEY = os.environ.get("HTTPSMS_API_KEY")
HTTPSMS_FROM_NUMBER = os.environ.get("HTTPSMS_FROM_NUMBER")
HTTPSMS_SEND_URL = "https://api.httpsms.com/v1/messages/send"


def send_sms(to_number, content, *, request_id=None):
    """Sends one text message via httpSMS. No-ops (returns False without
    making any network call) when the integration isn't configured or
    there's no recipient number — callers should treat this purely as a
    best-effort notification, never as something the response depends on."""
    if not HTTPSMS_API_KEY or not HTTPSMS_FROM_NUMBER or not to_number:
        return False
    payload = json.dumps({
        "content": content,
        "from": HTTPSMS_FROM_NUMBER,
        "to": to_number,
        "request_id": request_id or str(uuid.uuid4()),
    }).encode("utf-8")
    req = urllib.request.Request(
        HTTPSMS_SEND_URL,
        data=payload,
        method="POST",
        headers={"Content-Type": "application/json", "x-api-Key": HTTPSMS_API_KEY},
    )
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            return 200 <= resp.status < 300
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as exc:
        print(f"httpSMS send failed: {exc}", file=sys.stderr)
        return False


# The Partner app's technician sign-up only ever offers these five cities
# as a technician's own `area` (see careplus_partner's tech_apply_screen.dart
# _cities list) — kept in sync here so a booking can be matched against the
# same fixed set. Coordinates are each city's approximate centre, close
# enough for "which of these five cities is this booking in" — the cities
# are hundreds of kilometres apart, so there's no real ambiguity at this
# granularity.
PARTNER_CITY_CENTERS = {
    "Nashik": (19.9975, 73.7898),
    "Pune": (18.5204, 73.8567),
    "Mumbai": (19.0760, 72.8777),
    "Nagpur": (21.1458, 79.0882),
    "Aurangabad": (19.8762, 75.3433),
}


def infer_city(address_line, lat, lng):
    """Which of the Partner app's five service cities a booking is in, for
    technician_available_bookings' dispatch matching — replaces the old,
    broken comparison against `area` (a short address *label* like
    "Home"/"Office", never a city; see migrate_bookings_columns' comment
    on the `city` column). Prefers real coordinates (nearest city centre)
    when the client sent them; falls back to a plain substring match on
    the reverse-geocoded/typed address text otherwise. None if neither
    yields a confident match — technician_available_bookings already
    treats a booking with no city as visible to every technician of the
    matching category, same as it always has for the legacy promo path."""
    if lat is not None and lng is not None:
        return min(
            PARTNER_CITY_CENTERS,
            key=lambda city: (PARTNER_CITY_CENTERS[city][0] - lat) ** 2
            + (PARTNER_CITY_CENTERS[city][1] - lng) ** 2,
        )
    if address_line:
        lowered = address_line.lower()
        for city in PARTNER_CITY_CENTERS:
            if city.lower() in lowered:
                return city
    return None


@app.route("/api/bookings", methods=["POST"])
@require_auth
@validate_json({
    "service_id": Field(str, max_len=50),
    "category": Field(str, max_len=100),
    "service": Field(str, max_len=200),
    "price": Field(NUMBER, min_val=0, max_val=10_000_000),
    "bachatSlot": Field(str, max_len=100),
    "scheduledAt": Field(str, max_len=40, pattern=ISO_DATETIME_RE, strip=False),
    "area": Field(str, max_len=200),
    "addressLine": Field(str, max_len=300),
    "lat": Field(NUMBER, min_val=-90, max_val=90),
    "lng": Field(NUMBER, min_val=-180, max_val=180),
    "directions": Field(str, max_len=500),
    "notes": Field(str, max_len=2000),
    "issues": Field(list, max_len=30, item_type=str),
})
def create_booking():
    """Called by the Customer app when someone books a service. Accepts
    either a catalog `service_id` (price/category looked up server-side,
    so the client can't tamper with total_amount) or the legacy
    category/service/price shape used by the Bachat Package promo
    booking, which isn't a purchasable catalog item."""
    data = request.get_json(force=True, silent=True) or {}
    service_id = data.get("service_id")
    bachat_slot = data.get("bachatSlot")
    # The customer's chosen day+slot, as a real timestamp — used only for
    # the time-based cancellation policy (see _cancellation_fee_for).
    # Optional: bookings from a client that doesn't send it (or predating
    # this field) just fall back to the older status-based fee tiers.
    scheduled_at = data.get("scheduledAt")
    area = (data.get("area") or "").strip() or None
    # The real street address the map pin (lat/lng, below) actually points
    # to — `area` above is just a short label ("Home"/"Office") and isn't
    # enough on its own for a technician to find the door.
    address_line = (data.get("addressLine") or "").strip() or None
    lat = data.get("lat")
    lng = data.get("lng")
    lat = float(lat) if isinstance(lat, (int, float)) else None
    lng = float(lng) if isinstance(lng, (int, float)) else None
    directions = (data.get("directions") or "").strip() or None
    notes = (data.get("notes") or "").strip() or None
    # Which symptom checkboxes the customer ticked on the Issue screen —
    # previously collected in the app's UI and then silently dropped: never
    # sent here, so a technician's job screen had nothing real to show and
    # fell back to the same canned "Weak suction, rattling noise..." for
    # every booking regardless of appliance or what was actually reported.
    issues = data.get("issues")
    issues_json = json.dumps(issues) if isinstance(issues, list) and issues else None

    if service_id:
        conn = get_db()
        service_row = conn.execute(SERVICE_SELECT + " WHERE services.id = ?", (service_id,)).fetchone()
        conn.close()
        if not service_row:
            return jsonify({"error": "Unknown service_id"}), 400
        category = service_row["category"]
        service = service_row["appliance_name"] + " · " + service_row["name"]
        price = service_row["price"]
    else:
        category = data.get("category")
        service = data.get("service")
        price = data.get("price", 0)
        service_id = None
        if not category or not service:
            return jsonify({"error": "service_id, or category and service, are required"}), 400

    total_amount = price

    conn = get_db()
    # Real dispatch works like Uber/Ola/Rapido, not a single upfront
    # assignment: the booking goes out unassigned (technician_id NULL) and
    # every eligible technician sees it in their own broadcast feed (see
    # GET /api/technician/bookings/available) until one of them claims it
    # (PATCH .../claim). The one remaining upfront check — at least one
    # technician exists anywhere at all — just avoids creating a booking
    # that could never be fulfilled today (e.g. a fresh install with no
    # technicians signed up yet); it's not a category/area match, since
    # that's exactly what the broadcast is for.
    if conn.execute("SELECT 1 FROM technicians LIMIT 1").fetchone() is None:
        conn.close()
        return jsonify({"error": "No technician is available for this service yet"}), 503

    booking_id = next_id(conn, "order", "RC")
    ts = now()
    # A 4-digit code the customer hands the technician in person once
    # they've arrived — see advance_booking, which refuses to move this
    # booking into "In Progress" without it. Not required to be globally
    # unique since it's only ever checked against this one booking's row.
    start_code = f"{secrets.randbelow(10000):04d}"
    city = infer_city(address_line, lat, lng)
    conn.execute(
        "INSERT INTO bookings (id, category, service, price, technician_id, customer_name, "
        "status, bachat_slot, service_rating, tech_rating, area, created_at, updated_at, "
        "user_id, service_id, total_amount, lat, lng, directions, notes, issues_json, "
        "start_code, scheduled_at, address_line, city) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (booking_id, category, service, price, None, request.user["name"],
         "Requested", bachat_slot, None, None, area, ts, ts,
         request.user["id"], service_id, total_amount, lat, lng, directions,
         notes, issues_json, start_code, scheduled_at, address_line, city),
    )
    conn.commit()
    row = conn.execute(BOOKING_SELECT + " WHERE bookings.id = ?", (booking_id,)).fetchone()
    conn.close()
    # Best-effort — the code is already in the response above regardless of
    # whether this SMS actually goes out (see send_sms's no-op behavior).
    if request.user["phone"]:
        send_sms(
            f"+91{request.user['phone']}",
            f"Rasoi Care: your start code for {service} is {start_code}. "
            "Share it with your technician when they arrive to begin the job.",
            request_id=booking_id,
        )
    return jsonify(booking_row_to_dict(row, include_start_code=True)), 201


CART_VISIT_FEE = 49
CART_COUPON_THRESHOLD = 1700
CART_COUPON_DISCOUNT = 200
CART_GST_RATE = 0.18


@app.route("/api/bookings/cart", methods=["POST"])
@require_auth
@validate_json({
    "serviceIds": Field(list, required=True, min_len=1, max_len=20, item_type=str),
    "useCoins": Field(bool),
    "scheduledAt": Field(str, max_len=40, pattern=ISO_DATETIME_RE, strip=False),
    "area": Field(str, max_len=200),
    "addressLine": Field(str, max_len=300),
    "lat": Field(NUMBER, min_val=-90, max_val=90),
    "lng": Field(NUMBER, min_val=-180, max_val=180),
    "directions": Field(str, max_len=500),
    "notes": Field(str, max_len=2000),
    "issues": Field(list, max_len=30, item_type=str),
})
def create_booking_cart():
    """Real checkout for the Customer app's Service tab — one or more
    catalog services booked at once, sharing one visit/address/schedule.
    Every rupee charged here comes from a value only the server knows: the
    catalog's own price per serviceId, the same fixed visit-fee/coupon/GST
    business rules the app itself discloses (mirrored from
    PricingBreakdown in providers.dart), and the caller's real Care Coins
    balance — never a client-supplied total. This is what closes the hole
    create_booking's legacy category/service/price shape always left open:
    that endpoint still exists for the older Bachat Package promo flow,
    which isn't a purchasable catalog item and has no per-service price to
    verify against."""
    data = request.get_json(force=True, silent=True) or {}
    service_ids = data.get("serviceIds") or []
    use_coins = bool(data.get("useCoins"))
    idem_key = (request.headers.get("Idempotency-Key") or "").strip() or None
    if idem_key is not None and not re.fullmatch(r"[A-Za-z0-9_\-]{8,64}", idem_key):
        return jsonify({"error": "Invalid Idempotency-Key"}), 400
    if idem_key:
        conn = get_db()
        prior = conn.execute(
            "SELECT response_json FROM booking_idempotency WHERE user_id = ? AND idem_key = ?",
            (request.user["id"], idem_key),
        ).fetchone()
        conn.close()
        if prior:
            return app.response_class(prior["response_json"], status=201, mimetype="application/json")
    scheduled_at = data.get("scheduledAt")
    area = (data.get("area") or "").strip() or None
    address_line = (data.get("addressLine") or "").strip() or None
    lat = data.get("lat")
    lng = data.get("lng")
    lat = float(lat) if isinstance(lat, (int, float)) else None
    lng = float(lng) if isinstance(lng, (int, float)) else None
    directions = (data.get("directions") or "").strip() or None
    notes = (data.get("notes") or "").strip() or None
    issues = data.get("issues")
    issues_json = json.dumps(issues) if isinstance(issues, list) and issues else None

    conn = get_db()
    rows = []
    for sid in service_ids:
        row = conn.execute(SERVICE_SELECT + " WHERE services.id = ?", (sid,)).fetchone()
        if not row:
            conn.close()
            return jsonify({"error": f"Unknown serviceId: {sid}"}), 400
        rows.append(row)

    if conn.execute("SELECT 1 FROM technicians LIMIT 1").fetchone() is None:
        conn.close()
        return jsonify({"error": "No technician is available for this service yet"}), 503

    subtotal = sum(r["price"] for r in rows)
    pre_gst_base = subtotal + CART_VISIT_FEE
    coupon = CART_COUPON_DISCOUNT if pre_gst_base > CART_COUPON_THRESHOLD else 0
    after_coupon = pre_gst_base - coupon
    gst = round(after_coupon * CART_GST_RATE)
    before_coins = after_coupon + gst

    coins_redeemed = 0
    if use_coins and before_coins > 0:
        # A plain SELECT-then-UPDATE here would let two concurrent
        # checkouts both read the same starting balance and both redeem
        # from it, driving coins_balance negative (same class of bug fixed
        # in redeem_coins above). Compare-and-swap instead: the UPDATE's
        # own WHERE re-checks the balance hasn't moved since we read it —
        # same guard technique claim_booking uses for its race — so a
        # losing request notices instead of overwriting silently, and
        # simply retries against the fresh balance.
        for _ in range(5):
            user_row = conn.execute(
                "SELECT coins_balance FROM users WHERE id = ?", (request.user["id"],)
            ).fetchone()
            coins_redeemed = min(user_row["coins_balance"], before_coins)
            if coins_redeemed <= 0:
                break
            cur = conn.execute(
                "UPDATE users SET coins_balance = coins_balance - ? WHERE id = ? AND coins_balance = ?",
                (coins_redeemed, request.user["id"], user_row["coins_balance"]),
            )
            if cur.rowcount == 1:
                break
        else:
            conn.close()
            return jsonify({"error": "Could not redeem Care Coins — try again."}), 409

    grand_total = before_coins - coins_redeemed

    # Same proportional-share algorithm as the app's own _allocate() in
    # booking_screens.dart — each booking row still carries a real,
    # individually-meaningful price while the sum matches the checkout
    # total exactly; the last line absorbs any rounding remainder.
    allocations = []
    allocated = 0
    for i, r in enumerate(rows):
        if i == len(rows) - 1:
            allocations.append(grand_total - allocated)
        else:
            share = round(grand_total * r["price"] / subtotal) if subtotal else 0
            allocations.append(share)
            allocated += share

    created_ids = []
    ts = now()
    city = infer_city(address_line, lat, lng)
    for r, price in zip(rows, allocations):
        booking_id = next_id(conn, "order", "RC")
        start_code = f"{secrets.randbelow(10000):04d}"
        category = r["category"]
        service = r["appliance_name"] + " · " + r["name"]
        conn.execute(
            "INSERT INTO bookings (id, category, service, price, technician_id, customer_name, "
            "status, bachat_slot, service_rating, tech_rating, area, created_at, updated_at, "
            "user_id, service_id, total_amount, lat, lng, directions, notes, issues_json, "
            "start_code, scheduled_at, address_line, city) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (booking_id, category, service, price, None, request.user["name"],
             "Requested", None, None, None, area, ts, ts,
             request.user["id"], r["id"], price, lat, lng, directions,
             notes, issues_json, start_code, scheduled_at, address_line, city),
        )
        created_ids.append((booking_id, service, start_code))

    bookings_out = []
    for booking_id, _service, _start_code in created_ids:
        row = conn.execute(BOOKING_SELECT + " WHERE bookings.id = ?", (booking_id,)).fetchone()
        parts = fetch_booking_parts(conn, booking_id)
        service_changes = fetch_booking_service_changes(conn, booking_id)
        bookings_out.append(booking_row_to_dict(
            row, include_start_code=True, parts=parts, service_changes=service_changes,
        ))
    response_body = {
        "bookings": bookings_out,
        "pricing": {
            "subtotal": subtotal,
            "visitFee": CART_VISIT_FEE,
            "couponDiscount": coupon,
            "gst": gst,
            "coinsRedeemed": coins_redeemed,
            "grandTotal": grand_total,
        },
    }
    if idem_key:
        # Same transaction as the bookings and the coin redemption: either
        # all of it is committed together with the replay record, or none.
        try:
            conn.execute(
                "INSERT INTO booking_idempotency (user_id, idem_key, response_json, created_at) VALUES (?,?,?,?)",
                (request.user["id"], idem_key, json.dumps(response_body), ts),
            )
        except Exception:
            # A concurrent request with the same key won the race.
            conn.rollback()
            prior = conn.execute(
                "SELECT response_json FROM booking_idempotency WHERE user_id = ? AND idem_key = ?",
                (request.user["id"], idem_key),
            ).fetchone()
            conn.close()
            if prior:
                return app.response_class(prior["response_json"], status=201, mimetype="application/json")
            return jsonify({"error": "Could not create the booking — please try again."}), 409
    conn.commit()
    conn.close()

    # Best-effort — same as create_booking's own SMS, one per booking.
    if request.user["phone"]:
        for booking_id, service, start_code in created_ids:
            send_sms(
                f"+91{request.user['phone']}",
                f"Rasoi Care: your start code for {service} is {start_code}. "
                "Share it with your technician when they arrive to begin the job.",
                request_id=booking_id,
            )

    return jsonify(response_body), 201


@app.route("/api/technician/bookings/available", methods=["GET"])
@require_technician_auth
def technician_available_bookings():
    """The Partner app's incoming-request feed — real Uber/Ola/Rapido-style
    broadcast dispatch: every verified, on-duty technician whose category
    matches sees the same unclaimed booking here at once (oldest first),
    and whoever taps Accept first actually gets it — see claim_booking for
    the race guard. Returns nothing at all if this technician is offline
    or unverified, matching how those flags already govern eligibility
    everywhere else in the app."""
    tech = request.technician
    if not tech["verified"] or not tech["online"]:
        return jsonify([])
    my_categories = technician_categories(tech)
    conn = get_db()
    rows = conn.execute(
        BOOKING_LIST_SELECT + " WHERE bookings.technician_id IS NULL AND bookings.status = 'Requested' "
        "ORDER BY bookings.created_at ASC"
    ).fetchall()
    conn.close()
    # A booking with no inferred city at all (the legacy Bachat-slot promo
    # path, which never collects an address to infer one from) is shown to
    # any matching-category technician; one with a real city is only
    # broadcast to technicians actually in that city — a Nashik technician
    # can't do a Mumbai job. Matched against `city` (see infer_city), not
    # `area` — `area` is just the customer's address label ("Home"/
    # "Office"), never a city, so comparing it to a technician's own city
    # here would never actually match a real booking.
    matching = [
        r for r in rows
        if r["category"] in my_categories and (not r["city"] or r["city"] == tech["area"])
    ]
    return jsonify([booking_row_to_dict(r, redact_customer_contact=True) for r in matching])


@app.route("/api/bookings/<booking_id>/claim", methods=["PATCH"])
@require_technician_auth
def claim_booking(booking_id):
    """Accepting a broadcast request. The UPDATE's own WHERE clause
    (technician_id IS NULL AND status = 'Requested') is the actual race
    guard — if two technicians tap Accept on the same broadcast request
    at the same instant, only one UPDATE can possibly match a row,
    whichever the database happens to process first. The loser gets a
    clear "someone else already took this" instead of silently
    overwriting the winner's claim or the two of them somehow sharing it.

    Verification is checked here, not just in the /available feed above —
    that feed is only what the Partner app happens to call first, not an
    access control boundary. Without this, a technician who's done nothing
    but sign up (bootstrap_technician leaves them unverified/offline) could
    call this endpoint directly with a guessed booking id and be assigned
    to, and complete, a real customer's job before ever going through
    admin verification."""
    if not request.technician["verified"]:
        return jsonify({
            "error": "Forbidden",
            "message": "Your account needs to be verified before you can accept jobs.",
        }), 403
    # db_session (P1-02): commits on clean exit, rolls back on unexpected
    # exceptions, and always closes — an error can no longer leak the
    # connection. All early returns below are decision-only (nothing dirty
    # is written on them), so commit-on-exit is a no-op there.
    with database.db_session() as conn:
        return _claim_booking_with_conn(conn, booking_id)


def _claim_booking_with_conn(conn, booking_id):
    ts = now()
    cur = conn.execute(
        "UPDATE bookings SET technician_id = ?, status = 'Accepted', updated_at = ? "
        "WHERE id = ? AND technician_id IS NULL AND status = 'Requested'",
        (request.technician["id"], ts, booking_id),
    )
    conn.commit()
    if cur.rowcount != 1:
        row = conn.execute(
            "SELECT status, technician_id FROM bookings WHERE id = ?", (booking_id,)
        ).fetchone()
        if not row:
            return jsonify({"error": "not found"}), 404
        if row["technician_id"] is not None:
            return jsonify({
                "error": "Already claimed",
                "message": "Another technician already accepted this job.",
            }), 409
        return jsonify({
            "error": "No longer available",
            "message": "This request isn't open to accept any more.",
        }), 409
    row = conn.execute(BOOKING_SELECT + " WHERE bookings.id = ?", (booking_id,)).fetchone()
    return jsonify(booking_row_to_dict(row))


@app.route("/api/bookings/<booking_id>/advance", methods=["PATCH"])
@require_technician_auth
@validate_json({
    "startCode": Field(str, pattern=CODE_RE, strip=False),
    "suctionBefore": Field(NUMBER, min_val=0, max_val=100_000),
    "suctionAfter": Field(NUMBER, min_val=0, max_val=100_000),
})
def advance_booking(booking_id):
    """Called by the Technician app to move a job to its next status.
    Previously had no auth at all, so anyone could drive any booking id to
    Completed with no real job done — which, since Care Coins are earned
    here, was a direct free-money path. Now requires a real technician
    session and that the booking is actually theirs."""
    data = request.get_json(force=True, silent=True) or {}
    # db_session (P1-02): always closes, rolls back on unexpected exceptions
    # (so a mid-side-effect crash can't leave half of the completion effects
    # applied), commits on clean exit. Explicit conn.commit() below is kept
    # where the original had it — committing twice is harmless.
    with database.db_session() as conn:
        return _advance_booking_with_conn(conn, data, booking_id)


def _advance_booking_with_conn(conn, data, booking_id):
    row = conn.execute(BOOKING_SELECT + " WHERE bookings.id = ?", (booking_id,)).fetchone()
    if not row:
        return jsonify({"error": "not found"}), 404
    if row["technician_id"] != request.technician["id"]:
        return jsonify({"error": "not found"}), 404

    idx = STATUS_ORDER.index(row["status"]) if row["status"] in STATUS_ORDER else 0
    if idx >= len(STATUS_ORDER) - 1:
        return jsonify(booking_row_to_dict(row))

    new_status = STATUS_ORDER[idx + 1]

    # Moving into "In Progress" is the technician claiming they've arrived
    # and are starting the actual work — require the 4-digit code the
    # Customer app shows that customer, so this can't happen without the
    # technician genuinely being there in person.
    if new_status == "In Progress":
        submitted_code = (data.get("startCode") or "").strip()
        if not submitted_code or submitted_code != (row["start_code"] or ""):
            return jsonify({
                "error": "Incorrect verification code",
                "message": "Ask the customer for the 4-digit code shown in their app.",
            }), 400

    # Completing the job is the moment the customer's invoice appears and
    # they're asked to rate the visit — previously this succeeded no
    # matter what (the on-screen checklist/photos/signature were never
    # actually checked anywhere), so an invoice could appear before any
    # real work, photo, or signature existed. Now it requires all three to
    # have actually been submitted first via the endpoints below.
    if new_status == "Completed":
        missing = [
            label for label, present in (
                ("a before photo", row["before_photo_b64"]),
                ("an after photo", row["after_photo_b64"]),
                ("the customer's signature", row["signature_b64"]),
            ) if not present
        ]
        if missing:
            return jsonify({
                "error": "Job not ready to complete",
                "message": "Still missing: " + ", ".join(missing) + ".",
            }), 400
        # A part/quote the technician raised is worthless to the customer
        # once the job is already Completed and invoiced — there's no
        # re-invoicing flow, so an undecided quote left dangling here would
        # never get paid for, and the customer never even gets a real
        # chance to approve or reject it. Block completion until every
        # part on this booking has an actual customer decision on record.
        pending_parts = conn.execute(
            "SELECT name FROM booking_parts WHERE booking_id = ? AND status = 'pending' "
            "ORDER BY created_at",
            (booking_id,),
        ).fetchall()
        if pending_parts:
            names = ", ".join(r["name"] for r in pending_parts)
            return jsonify({
                "error": "Awaiting customer approval",
                "message": f"The customer still needs to approve or reject: {names}.",
            }), 400

    ts = now()
    # The status transition itself is guarded — `AND status = ?` matches
    # only if the booking is still in the state we just read. This is the
    # same race-guard pattern claim_booking uses. Without it, two
    # concurrent "complete" taps (double-tap, flaky network retry, or a
    # completion racing a cancellation) could both read "In Progress",
    # both pass every gate above, and BOTH fire the completion side
    # effects below — double-counting jobs_completed, double-firing the
    # weekly/monthly incentives, and double-crediting Care Coins.
    # With it, exactly one request's UPDATE can match; the loser re-reads
    # and is told the current (already advanced) state, idempotently, with
    # zero new ledger/coin rows.
    cur = conn.execute(
        "UPDATE bookings SET status = ?, updated_at = ? WHERE id = ? AND status = ?",
        (new_status, ts, booking_id, row["status"]),
    )
    if cur.rowcount != 1:
        current = conn.execute(
            BOOKING_SELECT + " WHERE bookings.id = ?", (booking_id,)
        ).fetchone()
        conn.commit()
        return jsonify(booking_row_to_dict(current))
    if new_status == "In Progress":
        # Real start-of-work marker — used below to compute a genuine
        # time-on-site instead of a made-up figure.
        conn.execute("UPDATE bookings SET in_progress_at = ? WHERE id = ?", (ts, booking_id))
        # Auto-fine for a late arrival — the customer's app shows their
        # slot as scheduled_at through scheduled_at+1h (see _timeWindow in
        # the Partner/Customer apps), so starting work later than that
        # grace window is a real lateness, not a guess. Skipped entirely
        # for a booking with no real scheduled slot on record (made before
        # that column existed, or by a client that never sent one) — there's
        # nothing genuine to measure lateness against for those.
        if row["scheduled_at"]:
            try:
                scheduled = datetime.fromisoformat(row["scheduled_at"].replace("Z", "+00:00"))
                started = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                if started > scheduled + timedelta(minutes=LATE_ARRIVAL_GRACE_MINUTES):
                    conn.execute(
                        "INSERT INTO technician_ledger "
                        "(id, technician_id, booking_id, kind, amount_paise, reason, created_at) "
                        "VALUES (?,?,?,?,?,?,?)",
                        (new_uuid_id("LEDG"), row["technician_id"], booking_id, "fine",
                         -LATE_ARRIVAL_FINE_PAISE,
                         f"Late arrival on {booking_id} (started more than "
                         f"{LATE_ARRIVAL_GRACE_MINUTES} min after the scheduled slot)", ts),
                    )
            except ValueError:
                pass  # malformed scheduled_at on an old row — never block the real status change for this
    if new_status == "Completed":
        conn.execute(
            "UPDATE technicians SET jobs_completed = jobs_completed + 1 WHERE id = ?",
            (row["technician_id"],),
        )
        # Two independent, auto-computed incentives (never a manual admin
        # entry): a weekly one (calendar Monday–Sunday) and a monthly one
        # that replaces the old lifetime-jobs milestone — see
        # MONTHLY_JOBS_FOR_BONUS below. Each fires exactly once per its own
        # period, the moment the technician's completed count for that
        # period first reaches the threshold. The UPDATE above already
        # moved this booking to Completed on this same connection, so it's
        # already counted in both queries below.
        completed_at = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        week_start_iso = _week_start_iso(completed_at)
        completed_this_week = conn.execute(
            "SELECT COUNT(*) AS n FROM bookings "
            "WHERE technician_id = ? AND status = 'Completed' AND updated_at >= ?",
            (row["technician_id"], week_start_iso),
        ).fetchone()["n"]
        if completed_this_week == WEEKLY_JOBS_FOR_BONUS:
            conn.execute(
                "INSERT INTO technician_ledger "
                "(id, technician_id, booking_id, kind, amount_paise, reason, created_at) "
                "VALUES (?,?,?,?,?,?,?)",
                (new_uuid_id("LEDG"), row["technician_id"], booking_id, "incentive",
                 WEEKLY_BONUS_PAISE, f"{WEEKLY_JOBS_FOR_BONUS} jobs completed this week", ts),
            )
        # A third, independent incentive on a calendar-month cadence — the
        # biggest of the three, and stacks on top of whatever weekly
        # bonuses already fired this month rather than replacing them
        # (each is its own ledger row, so all just sum together).
        month_start_iso = _month_start_iso(completed_at)
        completed_this_month = conn.execute(
            "SELECT COUNT(*) AS n FROM bookings "
            "WHERE technician_id = ? AND status = 'Completed' AND updated_at >= ?",
            (row["technician_id"], month_start_iso),
        ).fetchone()["n"]
        if completed_this_month == MONTHLY_JOBS_FOR_BONUS:
            conn.execute(
                "INSERT INTO technician_ledger "
                "(id, technician_id, booking_id, kind, amount_paise, reason, created_at) "
                "VALUES (?,?,?,?,?,?,?)",
                (new_uuid_id("LEDG"), row["technician_id"], booking_id, "incentive",
                 MONTHLY_BONUS_PAISE, f"{MONTHLY_JOBS_FOR_BONUS} jobs completed this month", ts),
            )
        # Care Coins — 2% of the real total, credited only once the job is
        # actually done (not at booking time, so a cancelled or never-
        # completed booking earns nothing). The idx guard above already
        # makes this whole branch run at most once per booking, since
        # Completed is the terminal status.
        if row["user_id"] and row["total_amount"]:
            coins_earned = (row["total_amount"] * 2) // 100
            if coins_earned > 0:
                conn.execute(
                    "UPDATE users SET coins_balance = coins_balance + ? WHERE id = ?",
                    (coins_earned, row["user_id"]),
                )
                # Best-effort — a customer without a phone on file, or with
                # httpSMS unconfigured, just doesn't get this text; the
                # coins are already credited either way.
                if row["customer_phone"]:
                    send_sms(
                        f"+91{row['customer_phone']}",
                        f"Rasoi Care: you earned {coins_earned} Care Coins for your "
                        f"{row['service']} booking. Redeem them on your next visit!",
                        request_id=f"coins-{booking_id}",
                    )
        suction_before = data.get("suctionBefore")
        suction_after = data.get("suctionAfter")
        if suction_before is not None or suction_after is not None:
            conn.execute(
                "UPDATE bookings SET suction_before = ?, suction_after = ? WHERE id = ?",
                (suction_before, suction_after, booking_id),
            )
        if row["in_progress_at"]:
            started = datetime.fromisoformat(row["in_progress_at"].rstrip("Z"))
            finished = datetime.fromisoformat(ts.rstrip("Z"))
            minutes = max(1, round((finished - started).total_seconds() / 60))
            conn.execute(
                "UPDATE bookings SET time_on_site_min = ? WHERE id = ?", (minutes, booking_id)
            )
    conn.commit()
    # Same-connection re-read: sees this transaction's own writes; the
    # response is identical to the pre-refactor commit-then-read order.
    row = conn.execute(BOOKING_SELECT + " WHERE bookings.id = ?", (booking_id,)).fetchone()
    return jsonify(booking_row_to_dict(row))


@app.route("/api/bookings/<booking_id>/photo", methods=["PATCH"])
@require_technician_auth
@validate_json({
    "kind": Field(str, required=True, choices=("before", "after")),
    "dataBase64": Field(str, required=True, min_len=1, max_len=12_000_000, pattern=BASE64_RE, strip=False),
})
def upload_job_photo(booking_id):
    """Stores a before/after job photo as base64 — directly in this
    booking's row rather than Firebase Storage, so completing a job never
    depends on a Storage bucket/rules setup existing. advance_booking
    refuses to mark a job Completed until both of these are present.
    The column is picked via an explicit if/else (not string-built from
    `kind`) so no request-influenced value ever reaches the SQL text."""
    data = request.get_json(force=True, silent=True) or {}
    kind = data.get("kind")
    if kind not in ("before", "after"):
        return jsonify({"error": "kind must be 'before' or 'after'"}), 400
    data_b64 = data.get("dataBase64")
    if not data_b64:
        return jsonify({"error": "dataBase64 is required"}), 400
    with database.db_session() as conn:
        row = conn.execute("SELECT technician_id FROM bookings WHERE id = ?", (booking_id,)).fetchone()
        if not row:
            return jsonify({"error": "not found"}), 404
        if row["technician_id"] != request.technician["id"]:
            return jsonify({"error": "not found"}), 404
        if kind == "before":
            conn.execute("UPDATE bookings SET before_photo_b64 = ? WHERE id = ?", (data_b64, booking_id))
        else:
            conn.execute("UPDATE bookings SET after_photo_b64 = ? WHERE id = ?", (data_b64, booking_id))
        return jsonify({"ok": True})


@app.route("/api/bookings/<booking_id>/signature", methods=["PATCH"])
@require_technician_auth
@validate_json({
    "dataBase64": Field(str, required=True, min_len=1, max_len=4_000_000, pattern=BASE64_RE, strip=False),
})
def upload_job_signature(booking_id):
    """Stores the customer's captured signature as base64, same reasoning
    as upload_job_photo above."""
    data = request.get_json(force=True, silent=True) or {}
    data_b64 = data.get("dataBase64")
    if not data_b64:
        return jsonify({"error": "dataBase64 is required"}), 400
    with database.db_session() as conn:
        row = conn.execute("SELECT technician_id FROM bookings WHERE id = ?", (booking_id,)).fetchone()
        if not row:
            return jsonify({"error": "not found"}), 404
        if row["technician_id"] != request.technician["id"]:
            return jsonify({"error": "not found"}), 404
        conn.execute("UPDATE bookings SET signature_b64 = ? WHERE id = ?", (data_b64, booking_id))
        return jsonify({"ok": True})


_PHOTO_MIME = {"before": "image/jpeg", "after": "image/jpeg", "signature": "image/png"}


@app.route("/api/bookings/<booking_id>/photo/<kind>", methods=["GET"])
def get_job_photo(booking_id, kind):
    """Serves a stored before/after photo or signature as an actual image
    response — lets the Admin/Partner/Customer apps display it with a
    plain Image.network(url) the same way they already do for Firebase
    Storage document URLs, without needing a separate download step. The
    column is picked via an explicit if/elif/else (not string-built from
    `kind`) so no request-influenced value ever reaches the SQL text.

    Booking IDs are sequential, so this must never be reachable without
    proof the caller is the customer on this exact booking, the technician
    assigned to it, or staff — same three token types every other booking
    route accepts, checked here against this specific booking's owners."""
    if kind not in _PHOTO_MIME:
        return jsonify({"error": "kind must be 'before', 'after', or 'signature'"}), 400
    user = get_current_user_optional()
    staff = get_current_staff_optional() if not user else None
    technician = get_current_technician_optional() if not user and not staff else None
    if not user and not staff and not technician:
        return jsonify({"error": "Unauthorized", "message": "Missing or invalid bearer token"}), 401
    conn = get_db()
    owner_row = conn.execute(
        "SELECT user_id, technician_id FROM bookings WHERE id = ?", (booking_id,)
    ).fetchone()
    if not owner_row:
        conn.close()
        return jsonify({"error": "not found"}), 404
    if user and owner_row["user_id"] != user["id"]:
        conn.close()
        return jsonify({"error": "not found"}), 404
    if technician and owner_row["technician_id"] != technician["id"]:
        conn.close()
        return jsonify({"error": "not found"}), 404
    if kind == "before":
        row = conn.execute(
            "SELECT before_photo_b64 AS data FROM bookings WHERE id = ?", (booking_id,)
        ).fetchone()
    elif kind == "after":
        row = conn.execute(
            "SELECT after_photo_b64 AS data FROM bookings WHERE id = ?", (booking_id,)
        ).fetchone()
    else:
        row = conn.execute(
            "SELECT signature_b64 AS data FROM bookings WHERE id = ?", (booking_id,)
        ).fetchone()
    conn.close()
    if not row or not row["data"]:
        return jsonify({"error": "not found"}), 404
    image_bytes = base64.b64decode(row["data"])
    return Response(image_bytes, mimetype=_PHOTO_MIME[kind])


@app.route("/api/bookings/<booking_id>/decline", methods=["PATCH"])
@require_technician_auth
def decline_booking(booking_id):
    """Called by the Technician app when a technician backs out of a job
    they'd already claimed, before actually heading over. Real dispatch
    now broadcasts an unclaimed request to every eligible technician (see
    technician_available_bookings/claim_booking), so there's no longer a
    single other technician to hand this off to the way the old reroute
    chain did — instead this just puts it back in that same broadcast
    pool (technician_id NULL, status back to Requested) for whoever
    claims it next. Only allowed while still just Accepted; once a
    technician is actually on the way, backing out needs a real
    cancellation instead of a quiet handoff."""
    conn = get_db()
    row = conn.execute(BOOKING_SELECT + " WHERE bookings.id = ?", (booking_id,)).fetchone()
    if not row:
        conn.close()
        return jsonify({"error": "not found"}), 404
    if row["technician_id"] != request.technician["id"]:
        conn.close()
        return jsonify({"error": "not found"}), 404
    if row["status"] != "Accepted":
        conn.close()
        return jsonify({"error": f"Cannot back out of a {row['status'].lower()} job"}), 400

    ts = now()
    conn.execute(
        "UPDATE bookings SET technician_id = NULL, status = 'Requested', updated_at = ? "
        "WHERE id = ?",
        (ts, booking_id),
    )
    conn.commit()
    row = conn.execute(BOOKING_SELECT + " WHERE bookings.id = ?", (booking_id,)).fetchone()
    conn.close()
    return jsonify(booking_row_to_dict(row))


@app.route("/api/bookings/<booking_id>/payment", methods=["PATCH"])
@require_technician_auth
@validate_json({
    "paymentMethod": Field(str, required=True, choices=("upi", "card", "cash", "link")),
})
def set_booking_payment(booking_id):
    """Called by the Technician app's close-job screen once the customer's
    actually paid. There's no payment gateway behind this (see
    PaymentScreen in the Customer app) — collection is still UPI/cash to
    the technician in person — but which method was used is now a real,
    stored fact instead of a button that only showed a SnackBar and
    recorded nothing."""
    data = request.get_json(force=True, silent=True) or {}
    method = (data.get("paymentMethod") or "").strip()
    if method not in ("upi", "card", "cash", "link"):
        return jsonify({"error": "paymentMethod must be one of: upi, card, cash, link"}), 400
    conn = get_db()
    row = conn.execute(BOOKING_SELECT + " WHERE bookings.id = ?", (booking_id,)).fetchone()
    if not row:
        conn.close()
        return jsonify({"error": "not found"}), 404
    if row["technician_id"] != request.technician["id"]:
        conn.close()
        return jsonify({"error": "not found"}), 404
    conn.execute(
        "UPDATE bookings SET payment_method = ?, updated_at = ? WHERE id = ?",
        (method, now(), booking_id),
    )
    conn.commit()
    row = conn.execute(BOOKING_SELECT + " WHERE bookings.id = ?", (booking_id,)).fetchone()
    conn.close()
    return jsonify(booking_row_to_dict(row))


# A booking can be cancelled at any of these statuses — not once it's
# Completed or already Cancelled. Independent of the fee itself (see
# _cancellation_fee_for below).
CANCELLABLE_STATUSES = {"Requested", "Accepted", "On the way", "In Progress"}

# The cancellation policy proper: tiered by how close the customer's
# scheduled day+slot is, same shape as Urban Company's partner-support
# policy — more than 12h out is free, within 12h is up to ₹100, within 3h
# is up to ₹200 — credited to the technician, not the platform, since
# their time was genuinely reserved for this job the closer it gets.
CANCELLATION_FEE_FAR_HOURS = _env_int("CANCELLATION_FEE_FAR_HOURS", 12)
CANCELLATION_FEE_NEAR_HOURS = _env_int("CANCELLATION_FEE_NEAR_HOURS", 3)
CANCELLATION_FEE_FAR_RUPEES = _env_int("CANCELLATION_FEE_FAR_RUPEES", 100)
CANCELLATION_FEE_NEAR_RUPEES = _env_int("CANCELLATION_FEE_NEAR_RUPEES", 200)

# Fallback only — used when a booking has no scheduled_at at all (made
# before this column existed, or by a client that never sent one), since
# there's nothing real to measure "hours before service" against for
# those. Same values this app used exclusively before the time-based
# policy above existed, tiered instead by how far the job had progressed.
CANCELLATION_FEE_BY_STATUS_FALLBACK = {
    "Requested": 0,
    "Accepted": CANCELLATION_FEE_FAR_RUPEES,
    "On the way": CANCELLATION_FEE_NEAR_RUPEES,
    "In Progress": CANCELLATION_FEE_NEAR_RUPEES,
}


# Technician commission — two-tier by how a technician is engaged (see
# `employment_type` on the technicians table, self-declared once at KYC).
# Both formulas apply their rate to the same real, GST-inclusive total
# stripped down to the actual service price: GST is backed out first (the
# backend never stores tax as its own column, see booking_row_to_dict) the
# same way the Customer app's invoice does, total / (1 + GST_RATE) — that
# alone leaves the service price plus the flat visit fee, so the visit fee
# is then subtracted too, for both employment types, since neither is paid
# a cut of a fee that isn't for their own labour. E.g. a ₹1,599 deep-clean
# invoiced at ₹1,944 (₹1,599 + ₹49 visit fee, +18% GST): backing out GST
# gives ₹1,648, minus the ₹49 visit fee gives back the original ₹1,599 —
# that's the number both commission rates apply to.
GST_RATE = _env_float("GST_RATE", 0.18)
PAYROLL_COMMISSION_RATE = _env_float("PAYROLL_COMMISSION_RATE", 0.10)
OUTSOURCED_COMMISSION_RATE = _env_float("OUTSOURCED_COMMISSION_RATE", 0.60)
# The real ₹49 visit fee already charged on every booking — see
# kVisitFeePaise in the Customer app's checkout pricing
# (careplus_flutter/lib/state/providers.dart). Kept as its own constant
# here (rather than importing across languages) since this backend has no
# shared-constants mechanism with the Flutter apps; the two must be kept
# in sync by hand if the real fee ever changes.
VISIT_CHARGE_PAISE = _env_int("VISIT_CHARGE_PAISE", 4900)  # ₹49

# Auto-computed, rule-based additions to a technician's ledger — see
# advance_booking. Not a manual admin entry: these fire deterministically
# off real activity (a job actually completed, a job actually started
# late), so the same milestone or the same late arrival is never counted
# twice. Two independent tiers — weekly and monthly (there used to also be
# a lifetime-jobs milestone; it was replaced by the monthly one below).
WEEKLY_JOBS_FOR_BONUS = _env_int("WEEKLY_JOBS_FOR_BONUS", 15)
WEEKLY_BONUS_PAISE = _env_int("WEEKLY_BONUS_PAISE", 20_000)  # ₹200
# The bigger of the two — a calendar-month milestone, on top of (never
# instead of) whatever weekly bonuses already fired within that same
# month. Both tiers are independent ledger entries that simply sum
# together in incentiveTotalPaise/netTotalPaise, so a technician's best
# month stacks a monthly bonus on top of up to 4-5 weekly ones.
MONTHLY_JOBS_FOR_BONUS = _env_int("MONTHLY_JOBS_FOR_BONUS", 75)
MONTHLY_BONUS_PAISE = _env_int("MONTHLY_BONUS_PAISE", 50_000)  # ₹500
LATE_ARRIVAL_GRACE_MINUTES = _env_int("LATE_ARRIVAL_GRACE_MINUTES", 60)
LATE_ARRIVAL_FINE_PAISE = _env_int("LATE_ARRIVAL_FINE_PAISE", 5_000)  # ₹50


def _week_start_iso(dt):
    """The ISO start (Monday 00:00:00) of dt's calendar week, as the same
    'Z'-suffixed string format used throughout for created_at/updated_at —
    shared by advance_booking's weekly-bonus check and
    technician_earnings_payload's weekly progress count so both agree on
    exactly the same week boundary."""
    week_start = (dt - timedelta(days=dt.weekday())).replace(
        hour=0, minute=0, second=0, microsecond=0)
    return week_start.strftime("%Y-%m-%dT%H:%M:%SZ")


def _month_start_iso(dt):
    """The ISO start (1st of the month, 00:00:00) of dt's calendar month —
    shared by advance_booking's monthly-bonus check and
    technician_earnings_payload's monthly progress count."""
    month_start = dt.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    return month_start.strftime("%Y-%m-%dT%H:%M:%SZ")


def compute_commission_paise(total_amount_rupees, employment_type):
    """A technician's real commission on one completed booking, in paise.
    `total_amount_rupees` is the booking's stored total (GST-inclusive,
    whole rupees — see bookings.total_amount); 0 for a falsy/zero total
    rather than raising, since a mock/legacy row might have none."""
    if not total_amount_rupees:
        return 0
    basic_paise = round((total_amount_rupees * 100) / (1 + GST_RATE))
    billable_paise = max(0, basic_paise - VISIT_CHARGE_PAISE)
    rate = PAYROLL_COMMISSION_RATE if employment_type == "payroll" else OUTSOURCED_COMMISSION_RATE
    return round(billable_paise * rate)


def technician_earnings_payload(conn, tech_row):
    """Real, itemized earnings for `tech_row` — one commission figure per
    completed job (computed fresh here from that booking's own total and
    the technician's employment_type, never stored, so nothing can go
    stale) plus every auto-computed ledger entry (incentive/fine, see
    advance_booking). Shared by the technician's own /me endpoint and the
    staff-facing per-technician one so both always agree."""
    employment_type = tech_row["employment_type"] if "employment_type" in tech_row.keys() else "outsourced"
    bookings = conn.execute(
        "SELECT id, service, total_amount, updated_at FROM bookings "
        "WHERE technician_id = ? AND status = 'Completed' ORDER BY updated_at DESC",
        (tech_row["id"],),
    ).fetchall()
    jobs = []
    commission_total_paise = 0
    for b in bookings:
        commission_paise = compute_commission_paise(b["total_amount"], employment_type)
        commission_total_paise += commission_paise
        jobs.append({
            "bookingId": b["id"],
            "service": b["service"],
            "totalAmountPaise": (b["total_amount"] or 0) * 100,
            "commissionPaise": commission_paise,
            "completedAt": b["updated_at"],
        })
    ledger_rows = conn.execute(
        "SELECT * FROM technician_ledger WHERE technician_id = ? ORDER BY created_at DESC",
        (tech_row["id"],),
    ).fetchall()
    ledger = [
        {
            "id": r["id"],
            "bookingId": r["booking_id"],
            "kind": r["kind"],
            "amountPaise": r["amount_paise"],
            "reason": r["reason"],
            "createdAt": r["created_at"],
        }
        for r in ledger_rows
    ]
    ledger_total_paise = sum(r["amount_paise"] for r in ledger_rows)
    # Live progress toward each milestone, computed the same way the
    # auto-incentive checks in advance_booking decide whether to fire, so
    # the number shown here is always "how many more until the next real
    # payout" rather than a static/stale snapshot.
    now = datetime.now(timezone.utc)
    week_start_iso = _week_start_iso(now)
    jobs_completed_this_week = conn.execute(
        "SELECT COUNT(*) AS n FROM bookings "
        "WHERE technician_id = ? AND status = 'Completed' AND updated_at >= ?",
        (tech_row["id"], week_start_iso),
    ).fetchone()["n"]
    month_start_iso = _month_start_iso(now)
    jobs_completed_this_month = conn.execute(
        "SELECT COUNT(*) AS n FROM bookings "
        "WHERE technician_id = ? AND status = 'Completed' AND updated_at >= ?",
        (tech_row["id"], month_start_iso),
    ).fetchone()["n"]
    return {
        "employmentType": employment_type,
        "commissionRate": PAYROLL_COMMISSION_RATE if employment_type == "payroll" else OUTSOURCED_COMMISSION_RATE,
        "visitChargePaise": VISIT_CHARGE_PAISE,
        "jobs": jobs,
        "commissionTotalPaise": commission_total_paise,
        "ledger": ledger,
        "incentiveTotalPaise": sum(r["amount_paise"] for r in ledger_rows if r["kind"] == "incentive"),
        "fineTotalPaise": sum(r["amount_paise"] for r in ledger_rows if r["kind"] == "fine"),
        "netTotalPaise": commission_total_paise + ledger_total_paise,
        "jobsCompletedThisWeek": jobs_completed_this_week,
        "jobsCompletedThisMonth": jobs_completed_this_month,
        "weeklyJobsForBonus": WEEKLY_JOBS_FOR_BONUS,
        "weeklyBonusPaise": WEEKLY_BONUS_PAISE,
        "monthlyJobsForBonus": MONTHLY_JOBS_FOR_BONUS,
        "monthlyBonusPaise": MONTHLY_BONUS_PAISE,
        "lateArrivalGraceMinutes": LATE_ARRIVAL_GRACE_MINUTES,
        "lateArrivalFinePaise": LATE_ARRIVAL_FINE_PAISE,
    }


def _cancellation_fee_for(row):
    """The real fee (in rupees) cancelling `row` right now would apply —
    see the policy comment above. Never raises: a missing or malformed
    scheduled_at just falls back to the status-based tiers."""
    scheduled_at = row["scheduled_at"] if "scheduled_at" in row.keys() else None
    if not scheduled_at:
        return CANCELLATION_FEE_BY_STATUS_FALLBACK.get(row["status"], 0)
    try:
        scheduled = datetime.fromisoformat(scheduled_at.replace("Z", "+00:00"))
    except ValueError:
        return CANCELLATION_FEE_BY_STATUS_FALLBACK.get(row["status"], 0)
    if scheduled.tzinfo is None:
        scheduled = scheduled.replace(tzinfo=timezone.utc)
    hours_left = (scheduled - datetime.now(timezone.utc)).total_seconds() / 3600
    if hours_left > CANCELLATION_FEE_FAR_HOURS:
        return 0
    if hours_left > CANCELLATION_FEE_NEAR_HOURS:
        return CANCELLATION_FEE_FAR_RUPEES
    return CANCELLATION_FEE_NEAR_RUPEES


@app.route("/api/bookings/<booking_id>/cancel/request-otp", methods=["POST"])
@require_auth
def request_cancel_otp(booking_id):
    """Texts the customer a short-lived 4-digit code that PATCH .../cancel
    below now requires. Never includes the code itself in this response —
    only whether the SMS actually went out, so the app can tell "check your
    phone" apart from "we couldn't send it" (no phone on file, httpSMS
    unreachable) without ever having to trust the client with the code."""
    conn = get_db()
    row = conn.execute(BOOKING_SELECT + " WHERE bookings.id = ?", (booking_id,)).fetchone()
    conn.close()
    if not row:
        return jsonify({"error": "not found"}), 404
    if row["user_id"] != request.user["id"]:
        # 404, not 403 — see get_booking's comment: booking ids are
        # sequential, so a 403 would confirm the id exists.
        return jsonify({"error": "not found"}), 404
    if row["status"] not in CANCELLABLE_STATUSES:
        return jsonify({"error": f"Cannot cancel a {row['status'].lower()} booking"}), 400
    if not request.user["phone"]:
        return jsonify({
            "error": "No phone on file",
            "message": "Add a phone number to your account before cancelling.",
        }), 400

    code = _cancel_otp_request(booking_id)
    sent = send_sms(
        f"+91{request.user['phone']}",
        f"Rasoi Care: your cancellation code is {code}. It expires in "
        f"{CANCEL_OTP_TTL_SECONDS // 60} minutes.",
        request_id=f"cancel-{booking_id}",
    )
    if not sent:
        # A real phone is on file — the SMS itself just didn't go out (the
        # httpSMS gateway phone offline/misconfigured, or its API key
        # invalid). Distinct from the no-phone-on-file 400 above: that one
        # is fixed in Account settings, this one is a Rasoi Care problem
        # the customer can only wait out and retry.
        return jsonify({
            "sent": False,
            "message": "We couldn't text you a code just now — try again in a moment.",
        })
    return jsonify({"sent": sent})


@app.route("/api/bookings/<booking_id>/cancel", methods=["PATCH"])
@require_auth
@validate_json({
    "otp": Field(str, required=True, pattern=CODE_RE, strip=False),
})
def cancel_booking(booking_id):
    """Called by the Customer app. Only the booking's own customer can
    cancel it, and only before it's completed. Requires the SMS code from
    request_cancel_otp above — an extra confirmation step, since the fee
    (if any) is credited to the technician and cancelling can't be undone.
    See _cancellation_fee_for for how the fee itself is computed."""
    conn = get_db()
    row = conn.execute(BOOKING_SELECT + " WHERE bookings.id = ?", (booking_id,)).fetchone()
    if not row:
        conn.close()
        return jsonify({"error": "not found"}), 404
    if row["user_id"] != request.user["id"]:
        # 404, not 403 — see get_booking's comment: booking ids are
        # sequential, so a 403 would confirm the id exists.
        conn.close()
        return jsonify({"error": "not found"}), 404
    if row["status"] not in CANCELLABLE_STATUSES:
        conn.close()
        return jsonify({"error": f"Cannot cancel a {row['status'].lower()} booking"}), 400

    data = request.get_json(force=True, silent=True) or {}
    otp_error = _cancel_otp_verify(booking_id, data["otp"])
    if otp_error:
        conn.close()
        return jsonify({"error": "Invalid code", "message": otp_error}), 400

    fee = _cancellation_fee_for(row)
    ts = now()
    conn.execute(
        "UPDATE bookings SET status = 'Cancelled', updated_at = ?, cancelled_at = ?, "
        "cancellation_fee = ? WHERE id = ?",
        (ts, ts, fee, booking_id),
    )
    conn.commit()
    row = conn.execute(BOOKING_SELECT + " WHERE bookings.id = ?", (booking_id,)).fetchone()
    conn.close()
    return jsonify(booking_row_to_dict(row))


@app.route("/api/bookings/<booking_id>/assign", methods=["PATCH"])
@require_staff_auth
@validate_json({
    "technician_id": Field(str, required=True, min_len=1, max_len=50),
})
def assign_technician(booking_id):
    """Called by the Admin app to assign or reassign which technician is on
    a booking — e.g. routing a freshly requested job, or swapping in a
    replacement if the original technician can't make it. Staff-only: this
    reroutes real jobs and money, so it shouldn't be callable by anyone who
    just finds the URL."""
    data = request.get_json(force=True, silent=True) or {}
    technician_id = data.get("technician_id")
    if not technician_id:
        return jsonify({"error": "technician_id is required"}), 400

    conn = get_db()
    booking = conn.execute(BOOKING_SELECT + " WHERE bookings.id = ?", (booking_id,)).fetchone()
    if not booking:
        conn.close()
        return jsonify({"error": "not found"}), 404
    # Once a job is Completed or Cancelled there's nothing left to route —
    # allowing a reassignment here would silently move commission
    # attribution (technician_earnings_payload prices strictly off whoever
    # currently sits in technician_id on a Completed row) away from
    # whoever actually did the work, with no record a change happened.
    if booking["status"] in ("Completed", "Cancelled"):
        conn.close()
        return jsonify({"error": f"Cannot reassign a {booking['status'].lower()} booking"}), 400
    tech = conn.execute("SELECT * FROM technicians WHERE id = ?", (technician_id,)).fetchone()
    if not tech:
        conn.close()
        return jsonify({"error": "Unknown technician_id"}), 400
    # The Admin app's own picker only offers verified technicians (see
    # assign_technician_sheet.dart) — enforced here too, since that's a
    # client-side filter, not an access boundary, and this is the same
    # trust-and-safety gate claim_booking enforces for self-service claims.
    if not tech["verified"]:
        conn.close()
        return jsonify({"error": "This technician hasn't been verified yet"}), 400

    new_status = "Accepted" if booking["status"] == "Requested" else booking["status"]
    conn.execute(
        "UPDATE bookings SET technician_id = ?, status = ?, updated_at = ? WHERE id = ?",
        (technician_id, new_status, now(), booking_id),
    )
    conn.commit()
    row = conn.execute(BOOKING_SELECT + " WHERE bookings.id = ?", (booking_id,)).fetchone()
    conn.close()
    return jsonify(booking_row_to_dict(row))


@app.route("/api/bookings/<booking_id>/rating", methods=["POST"])
@require_auth
@validate_json({
    "serviceRating": Field(int, min_val=0, max_val=5),
    "techRating": Field(int, min_val=0, max_val=5),
    "raiseComplaint": Field(bool),
    "complaintText": Field(str, max_len=2000),
})
def rate_booking(booking_id):
    """Called by the Customer app after a job completes. Updates the
    booking's ratings, rolls the technician's aggregate rating, and
    optionally opens a complaint — all in one transaction. Only the
    booking's own customer can rate it — without this check, anyone with a
    valid customer account (their own, on any booking) could drag down a
    technician's rating or spam fake complaints against jobs that aren't
    theirs."""
    data = request.get_json(force=True)
    service_rating = int(data.get("serviceRating", 0))
    tech_rating = int(data.get("techRating", 0))
    raise_complaint = bool(data.get("raiseComplaint"))
    complaint_text = data.get("complaintText") or "Customer flagged this service as unsatisfactory."

    conn = get_db()
    booking = conn.execute(BOOKING_SELECT + " WHERE bookings.id = ?", (booking_id,)).fetchone()
    if not booking:
        conn.close()
        return jsonify({"error": "not found"}), 404
    if booking["user_id"] != request.user["id"]:
        # 404, not 403 — see get_booking's comment: booking ids are
        # sequential, so a 403 would confirm the id exists.
        conn.close()
        return jsonify({"error": "not found"}), 404
    # A booking's rating column is NULL until the first real call here —
    # without this, a customer replaying the same request could roll the
    # technician's aggregate rating into their average again and again,
    # arbitrarily inflating or crashing it.
    if booking["service_rating"] is not None or booking["tech_rating"] is not None:
        conn.close()
        return jsonify({"error": "This booking has already been rated"}), 400

    conn.execute(
        "UPDATE bookings SET service_rating = ?, tech_rating = ?, updated_at = ? WHERE id = ?",
        (service_rating, tech_rating, now(), booking_id),
    )

    tech = conn.execute(
        "SELECT * FROM technicians WHERE id = ?", (booking["technician_id"],)
    ).fetchone()
    if tech:
        new_count = tech["rating_count"] + 1
        new_rating = round(((tech["rating"] * tech["rating_count"]) + tech_rating) / new_count, 2)
        conn.execute(
            "UPDATE technicians SET rating = ?, rating_count = ? WHERE id = ?",
            (new_rating, new_count, tech["id"]),
        )

    complaint = None
    if raise_complaint:
        complaint_id = next_id(conn, "complaint", "CMP")
        ts = now()
        conn.execute(
            "INSERT INTO complaints (id, booking_id, text, status, response, created_at) "
            "VALUES (?,?,?,?,?,?)",
            (complaint_id, booking_id, complaint_text, "New", None, ts),
        )
        complaint = {"id": complaint_id, "bookingId": booking_id, "text": complaint_text,
                     "status": "New", "response": None, "createdAt": ts}

    conn.commit()
    row = conn.execute(BOOKING_SELECT + " WHERE bookings.id = ?", (booking_id,)).fetchone()
    conn.close()
    return jsonify({"booking": booking_row_to_dict(row), "complaint": complaint})


# ---------------------------------------------------------------- complaints
@app.route("/api/complaints", methods=["GET"])
@require_staff_auth
def list_complaints():
    """Staff-only — a complaint can contain a customer's own words about a
    bad experience, not something to leave world-readable."""
    limit, offset = _pagination_args()
    conn = get_db()
    rows = conn.execute(
        "SELECT * FROM complaints ORDER BY created_at DESC LIMIT ? OFFSET ?", (limit, offset)
    ).fetchall()
    conn.close()
    return jsonify([complaint_row_to_dict(r) for r in rows])


@app.route("/api/complaints/<complaint_id>", methods=["PATCH"])
@require_staff_auth
@validate_json({
    "response": Field(str, max_len=2000),
    "status": Field(str, max_len=50),
})
def update_complaint(complaint_id):
    """Called by the Admin dashboard (respond / resolve / reopen). Staff-
    only — no real app currently lets a technician respond to a complaint
    directly."""
    data = request.get_json(force=True)
    conn = get_db()
    row = conn.execute("SELECT * FROM complaints WHERE id = ?", (complaint_id,)).fetchone()
    if not row:
        conn.close()
        return jsonify({"error": "not found"}), 404

    response = data.get("response", row["response"])
    status = data.get("status", row["status"])
    conn.execute(
        "UPDATE complaints SET response = ?, status = ? WHERE id = ?",
        (response, status, complaint_id),
    )
    conn.commit()
    row = conn.execute("SELECT * FROM complaints WHERE id = ?", (complaint_id,)).fetchone()
    conn.close()
    return jsonify(complaint_row_to_dict(row))


# ---------------------------------------------------------------- technicians
# These three routes used to have no auth at all — technician_row_to_dict
# includes bank account/IFSC/PAN/Aadhaar/DOB/address/emergency-contact,
# i.e. a full KYC dossier, and verify/create had no gate either (so anyone
# could self-register a "technician" and immediately self-verify it,
# completely bypassing the Admin app's document-review step before it
# starts receiving real customer bookings). All three now require a real
# signed-in staff session — matches the Admin app's own access model,
# which already lets any signed-in staff member (not just Owner) review
# and verify technicians.
@app.route("/api/technicians", methods=["GET"])
@require_staff_auth
def list_technicians():
    limit, offset = _pagination_args()
    owner_view = _owner_identity_ok()
    conn = get_db()
    rows = conn.execute(
        "SELECT * FROM technicians ORDER BY name LIMIT ? OFFSET ?", (limit, offset)
    ).fetchall()
    conn.close()
    return jsonify([technician_row_to_dict(r, redact_documents=True, redact_financial=not owner_view) for r in rows])


# Only Firebase Storage's own download-URL hosts — see technician_document.
# The URLs this fetches from come from a technician's own PATCH
# /api/technician/me (aadharDocumentUrl etc.), validated only as "looks
# like a URL", so without a host allowlist a technician could point one at
# an arbitrary address and have the backend fetch it server-side (SSRF) the
# next time staff opens that document.
_DOCUMENT_PROXY_ALLOWED_HOSTS = ("firebasestorage.googleapis.com", "storage.googleapis.com")

_DOCUMENT_PROXY_FIELD_BY_KIND = {
    "aadhar-front": "aadhar_document_url",
    "aadhar-back": "aadhar_document_back_url",
    "pan": "pan_document_url",
    "bank-passbook": "bank_passbook_url",
}


@app.route("/api/technicians/<technician_id>/document/<kind>", methods=["GET"])
@require_staff_auth
def technician_document(technician_id, kind):
    """Proxies a technician's KYC document (Aadhaar/PAN/bank passbook)
    through a staff-authenticated request instead of handing the Admin app
    the raw, non-expiring Firebase Storage URL — see get_job_photo for the
    same pattern already used for booking photos. Without this, the URLs
    returned by GET /api/technicians could view a person's identity
    documents indefinitely, with no session, if they ever leaked (a log, a
    proxy, a shared screenshot)."""
    field = _DOCUMENT_PROXY_FIELD_BY_KIND.get(kind)
    if not field:
        return jsonify({"error": "kind must be one of: " + ", ".join(_DOCUMENT_PROXY_FIELD_BY_KIND)}), 400
    if kind == "bank-passbook" and not _owner_identity_ok():
        return jsonify({"error": "Forbidden", "message": "Bank documents are owner-only"}), 403
    conn = get_db()
    row = conn.execute("SELECT * FROM technicians WHERE id = ?", (technician_id,)).fetchone()
    conn.close()
    if not row:
        return jsonify({"error": "not found"}), 404
    url = row[field] if field in row.keys() else None
    if not url:
        return jsonify({"error": "not found"}), 404
    host = urllib.parse.urlparse(url).hostname
    if host not in _DOCUMENT_PROXY_ALLOWED_HOSTS:
        return jsonify({"error": "Document URL is not from a trusted host"}), 502
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            data = resp.read()
            content_type = resp.headers.get("Content-Type", "application/octet-stream")
    except Exception:
        return jsonify({"error": "Could not fetch this document right now"}), 502
    return Response(data, mimetype=content_type)


@app.route("/api/technicians", methods=["POST"])
@require_staff_auth
@validate_json({
    "name": Field(str, required=True, min_len=1, max_len=100),
    "category": Field(str, required=True, min_len=1, max_len=100),
    "area": Field(str, required=True, min_len=1, max_len=200),
})
def create_technician():
    """Called by the Admin app to add a new technician. New hires start
    unverified and offline — they're excluded from auto-routing and from
    the technician app's job feed until an admin verifies them."""
    data = request.get_json(force=True, silent=True) or {}
    name = data["name"].strip()
    category = data["category"].strip()
    area = data["area"].strip()

    conn = get_db()
    tech_id = new_uuid_id("TECH")
    conn.execute(
        "INSERT INTO technicians (id, name, category, area, verified, online, rating, rating_count, jobs_completed) "
        "VALUES (?,?,?,?,0,0,5.0,0,0)",
        (tech_id, name, category, area),
    )
    conn.commit()
    row = conn.execute("SELECT * FROM technicians WHERE id = ?", (tech_id,)).fetchone()
    conn.close()
    return jsonify(technician_row_to_dict(row, redact_documents=True, redact_financial=not _owner_identity_ok())), 201


# Excludes 0/O and 1/I — easy to confuse when a technician reads their code
# aloud or copies it down by hand.
_PARTNER_CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


def _generate_partner_code(conn):
    while True:
        code = "RC-" + "".join(secrets.choice(_PARTNER_CODE_CHARS) for _ in range(6))
        if not conn.execute(
            "SELECT 1 FROM technicians WHERE partner_code = ?", (code,)
        ).fetchone():
            return code


@app.route("/api/technicians/<technician_id>/verify", methods=["PATCH"])
@require_staff_auth
def verify_technician(technician_id):
    """Called by the Admin app once it has checked a new technician's
    documents/background — flips them verified and brings them online so
    they start appearing in auto-routing and the job feed. The first time a
    technician is verified, this also mints a permanent partner code — a
    short, human-shareable ID for their own reference, distinct from (and
    never confused with) their internal database id. Re-verifying later
    (there's no "unverify") keeps whatever code they already have."""
    conn = get_db()
    row = conn.execute("SELECT * FROM technicians WHERE id = ?", (technician_id,)).fetchone()
    if not row:
        conn.close()
        return jsonify({"error": "not found"}), 404
    if row["partner_code"]:
        conn.execute("UPDATE technicians SET verified = 1, online = 1 WHERE id = ?", (technician_id,))
    else:
        code = _generate_partner_code(conn)
        conn.execute(
            "UPDATE technicians SET verified = 1, online = 1, partner_code = ? WHERE id = ?",
            (code, technician_id),
        )
    conn.commit()
    row = conn.execute("SELECT * FROM technicians WHERE id = ?", (technician_id,)).fetchone()
    conn.close()
    return jsonify(technician_row_to_dict(row, redact_documents=True, redact_financial=not _owner_identity_ok()))


@app.route("/api/technicians/<technician_id>/earnings", methods=["GET"])
@require_owner
def technician_earnings_admin(technician_id):
    """Same real commission + ledger computation as the technician's own
    /api/technician/earnings, exposed to staff for reviewing a payout
    before it's actually run. See technician_earnings_payload."""
    conn = get_db()
    row = conn.execute("SELECT * FROM technicians WHERE id = ?", (technician_id,)).fetchone()
    if not row:
        conn.close()
        return jsonify({"error": "not found"}), 404
    payload = technician_earnings_payload(conn, row)
    conn.close()
    return jsonify(payload)


# ------------------------------------------------ technician self-service
# (the Partner app's own login/session — everything above this is the
# admin-managed view that technician.html and the Admin app already use.)
def _identity_is_staff_or_owner(conn, claims):
    """True when this verified identity is an active staff/owner (by uid,
    verified email, verified phone, or the owner allowlist). Used so that
    choosing "Technician" at sign-in cannot mint a technician profile for a
    staff/owner-only identity. Read-only."""
    email = (claims.get("email") or "").strip().lower()
    verified_email = bool(email and claims.get("email_verified"))
    if (verified_email and claims.get("sign_in_provider") == "google.com"
            and email in _STAFF_BOOTSTRAP_OWNER_EMAILS):
        return True
    if conn.execute("SELECT 1 FROM staff WHERE firebase_uid = ? AND active = 1", (claims["uid"],)).fetchone():
        return True
    if verified_email and conn.execute(
            "SELECT 1 FROM staff WHERE LOWER(email) = ? AND active = 1", (email,)).fetchone():
        return True
    digits = re.sub(r"\D", "", str(claims.get("phone_number") or ""))
    if 10 <= len(digits) <= 15:
        for cand in conn.execute("SELECT phone FROM staff WHERE phone IS NOT NULL AND active = 1").fetchall():
            if re.sub(r"\D", "", str(cand["phone"] or ""))[-10:] == digits[-10:]:
                return True
    return False


@app.route("/api/technician/bootstrap", methods=["POST"])
@validate_json({
    "name": Field(str, max_len=100),
    "category": Field(str, max_len=100),
    "area": Field(str, max_len=200),
})
def bootstrap_technician():
    """Called once right after Firebase sign-in/sign-up in the Partner
    app. A self-registered technician starts unverified/offline, same as
    one an admin adds by hand — they need an admin to verify them (see
    /api/technicians/<id>/verify) before they're routed real jobs."""
    token = get_bearer_token()
    claims = verify_firebase_token(token) if token else None
    if not claims:
        return jsonify({"error": "Unauthorized", "message": "Invalid or missing Firebase token"}), 401

    data = request.get_json(force=True, silent=True) or {}
    name = (data.get("name") or claims.get("name") or "").strip() or "Technician"
    category = (data.get("category") or "").strip() or "RasoiSpark"
    area = (data.get("area") or "").strip()

    conn = get_db()
    row = conn.execute(
        "SELECT * FROM technicians WHERE firebase_uid = ?", (claims["uid"],)
    ).fetchone()
    if not row and claims.get("email") and claims.get("email_verified"):
        row = conn.execute("SELECT * FROM technicians WHERE email = ?", (claims["email"],)).fetchone()
    if row:
        conn.execute(
            "UPDATE technicians SET firebase_uid = ?, name = ? WHERE id = ?",
            (claims["uid"], name, row["id"]),
        )
        tech_id = row["id"]
    else:
        if _identity_is_staff_or_owner(conn, claims):
            conn.close()
            return jsonify({
                "error": "Forbidden",
                "message": "This account is a staff or owner account and has no technician profile",
            }), 403
        tech_id = new_uuid_id("TECH")
        conn.execute(
            "INSERT INTO technicians (id, name, category, area, verified, online, rating, "
            "rating_count, jobs_completed, email, firebase_uid) VALUES (?,?,?,?,0,0,5.0,0,0,?,?)",
            (tech_id, name, category, area, claims.get("email"), claims["uid"]),
        )
    conn.commit()
    row = conn.execute("SELECT * FROM technicians WHERE id = ?", (tech_id,)).fetchone()
    conn.close()
    return jsonify(technician_row_to_dict(row))


@app.route("/api/technician/me", methods=["GET"])
@require_technician_auth
def technician_me():
    return jsonify(technician_row_to_dict(request.technician))


@app.route("/api/technician/earnings", methods=["GET"])
@require_technician_auth
def technician_earnings():
    """Real, itemized earnings for the signed-in technician — replaces
    treating 100% of a completed job's invoice total as "earned" with the
    actual commission this technician's employment_type entitles them to,
    plus their real bonus/incentive and fine history. See
    technician_earnings_payload for the shape."""
    conn = get_db()
    payload = technician_earnings_payload(conn, request.technician)
    conn.close()
    return jsonify(payload)


@app.route("/api/technician/me", methods=["PATCH"])
@require_technician_auth
@validate_json({
    "name": Field(str, max_len=100),
    "area": Field(str, max_len=200),
    "photoUrl": Field(str, max_len=2000, pattern=URL_RE),
    "experienceYears": Field(int, min_val=0, max_val=80),
    "idDocumentUrl": Field(str, max_len=2000, pattern=URL_RE),
    "bankAccountName": Field(str, max_len=200),
    "bankAccountNumber": Field(str, pattern=BANK_ACCOUNT_RE, strip=False),
    "bankIfsc": Field(str, pattern=IFSC_RE, strip=False),
    "panNumber": Field(str, pattern=PAN_RE, strip=False),
    "aadharNumber": Field(str, pattern=AADHAAR_RE, strip=False),
    "dateOfBirth": Field(str, pattern=DATE_RE, strip=False),
    "gstNumber": Field(str, pattern=GSTIN_RE, strip=False),
    "emergencyContactName": Field(str, max_len=100),
    "emergencyContactPhone": Field(str, pattern=PHONE_RE, strip=False),
    "aadharDocumentUrl": Field(str, max_len=2000, pattern=URL_RE),
    "aadharDocumentBackUrl": Field(str, max_len=2000, pattern=URL_RE),
    "panDocumentUrl": Field(str, max_len=2000, pattern=URL_RE),
    "bankPassbookUrl": Field(str, max_len=2000, pattern=URL_RE),
    "address": Field(str, max_len=500),
    "upiId": Field(str, max_len=256, pattern=UPI_ID_RE, strip=False),
    "categories": Field(list, max_len=20, item_type=str),
    "employmentType": Field(str, choices=("payroll", "outsourced")),
    "submit": Field(bool),
})
def update_technician_me():
    """Called by the Partner app's signup flow to fill in (and eventually
    submit) the KYC application — profile, category/area, experience, ID
    document and bank details. Anyone can update their own fields at any
    time before verification; setting `submit: true` flips
    application_submitted so the Admin app knows there's a completed
    application waiting for review. Updating fields after verification is
    still allowed (e.g. changing a bank account) but doesn't reset
    verified — an admin would need to notice and re-check if that matters
    for a real deployment.

    `employmentType` is the one field that's genuinely one-way: it's only
    ever written here while `application_submitted` is still false, so it
    can be set once during onboarding and never edited again afterward —
    not by the technician, and there's deliberately no admin endpoint that
    touches it either."""
    data = request.get_json(force=True, silent=True) or {}
    tech = request.technician
    fields = {
        "name": data.get("name"),
        "area": data.get("area"),
        "photo_url": data.get("photoUrl"),
        "experience_years": data.get("experienceYears"),
        "id_document_url": data.get("idDocumentUrl"),
        "bank_account_name": data.get("bankAccountName"),
        "bank_account_number": data.get("bankAccountNumber"),
        "bank_ifsc": data.get("bankIfsc"),
        "pan_number": data.get("panNumber"),
        "aadhar_number": data.get("aadharNumber"),
        "date_of_birth": data.get("dateOfBirth"),
        "gst_number": data.get("gstNumber"),
        "emergency_contact_name": data.get("emergencyContactName"),
        "emergency_contact_phone": data.get("emergencyContactPhone"),
        "aadhar_document_url": data.get("aadharDocumentUrl"),
        "aadhar_document_back_url": data.get("aadharDocumentBackUrl"),
        "pan_document_url": data.get("panDocumentUrl"),
        "bank_passbook_url": data.get("bankPassbookUrl"),
        "address": data.get("address"),
        "upi_id": data.get("upiId"),
    }
    conn = get_db()
    for column, value in fields.items():
        if value is not None:
            conn.execute(
                f"UPDATE technicians SET {column} = ? WHERE id = ?", (value, tech["id"])
            )
    # `categories` (a list) doesn't map to one column — store the full list
    # as JSON, and keep `category` in sync as the first pick so job-routing
    # queries that still filter on the single column at least match the
    # technician's primary skill.
    categories = data.get("categories")
    if isinstance(categories, list) and categories:
        conn.execute(
            "UPDATE technicians SET categories_json = ?, category = ? WHERE id = ?",
            (json.dumps(categories), categories[0], tech["id"]),
        )
    employment_type = data.get("employmentType")
    if employment_type and not tech["application_submitted"]:
        conn.execute(
            "UPDATE technicians SET employment_type = ? WHERE id = ?",
            (employment_type, tech["id"]),
        )
    if data.get("submit"):
        if not _TECH_DOCS_DEFERRED:
            current = conn.execute("SELECT * FROM technicians WHERE id = ?", (tech["id"],)).fetchone()
            missing = {
                key: f"{label} is required"
                for col, key, label in _REQUIRED_APPLICATION_DOCS
                if not (current[col] if col in current.keys() else None)
            }
            if missing:
                conn.rollback()
                conn.close()
                return jsonify({"error": "Invalid request", "fields": missing}), 400
        conn.execute(
            "UPDATE technicians SET application_submitted = 1 WHERE id = ?", (tech["id"],)
        )
    conn.commit()
    row = conn.execute("SELECT * FROM technicians WHERE id = ?", (tech["id"],)).fetchone()
    conn.close()
    return jsonify(technician_row_to_dict(row))


@app.route("/api/technician/online", methods=["PATCH"])
@require_technician_auth
@validate_json({
    "online": Field(bool, required=True),
})
def technician_set_online():
    data = request.get_json(force=True, silent=True) or {}
    online = data["online"]
    conn = get_db()
    conn.execute("UPDATE technicians SET online = ? WHERE id = ?", (1 if online else 0, request.technician["id"]))
    conn.commit()
    row = conn.execute("SELECT * FROM technicians WHERE id = ?", (request.technician["id"],)).fetchone()
    conn.close()
    return jsonify(technician_row_to_dict(row))


@app.route("/api/technician/bookings", methods=["GET"])
@require_technician_auth
def technician_my_bookings():
    """The Partner app's job feed — only jobs assigned to this technician,
    scoped by their own Firebase-verified identity rather than a client-
    supplied id (so one technician can't read another's job list)."""
    conn = get_db()
    rows = conn.execute(
        BOOKING_LIST_SELECT + " WHERE bookings.technician_id = ? ORDER BY bookings.created_at DESC",
        (request.technician["id"],),
    ).fetchall()
    parts_by_booking = fetch_booking_parts_bulk(conn, [r["id"] for r in rows])
    service_changes_by_booking = fetch_booking_service_changes_bulk(conn, [r["id"] for r in rows])
    conn.close()
    return jsonify([
        booking_row_to_dict(
            r,
            parts=parts_by_booking.get(r["id"]),
            service_changes=service_changes_by_booking.get(r["id"]),
        )
        for r in rows
    ])


@app.route("/api/technician/bookings/<booking_id>/appliance", methods=["PATCH"])
@require_technician_auth
@validate_json({
    "brand": Field(str, max_len=100),
    "modelNumber": Field(str, max_len=100),
})
def update_booking_appliance(booking_id):
    """The technician records the real brand/model off the appliance itself
    once they're actually on-site looking at it — the customer never types
    this at booking time, so it stays null until a technician sets it.
    Either field can be sent alone; an explicit empty string clears it
    (Field.validate() already treats a blank optional string as valid)."""
    data = request.get_json(force=True, silent=True) or {}
    conn = get_db()
    row = conn.execute("SELECT technician_id FROM bookings WHERE id = ?", (booking_id,)).fetchone()
    if not row:
        conn.close()
        return jsonify({"error": "not found"}), 404
    if row["technician_id"] != request.technician["id"]:
        conn.close()
        return jsonify({"error": "not found"}), 404
    if "brand" in data:
        conn.execute("UPDATE bookings SET brand = ? WHERE id = ?", (data["brand"].strip(), booking_id))
    if "modelNumber" in data:
        conn.execute(
            "UPDATE bookings SET model_number = ? WHERE id = ?",
            (data["modelNumber"].strip(), booking_id),
        )
    conn.commit()
    row = conn.execute(BOOKING_SELECT + " WHERE bookings.id = ?", (booking_id,)).fetchone()
    parts = fetch_booking_parts(conn, booking_id)
    conn.close()
    return jsonify(booking_row_to_dict(row, parts=parts))


# ---------------------------------------------------------------- kitchen passport (V9.7)
def kitchen_appliance_row_to_dict(row):
    try:
        specs = json.loads(row["specs"] or "{}")
    except ValueError:
        specs = {}
    return {
        "id": row["id"],
        "category": row["category"],
        "brand": row["brand"],
        "model": row["model"],
        "serialNumber": row["serial_number"],
        "installYear": row["install_year"],
        "specs": specs,
        "notes": row["notes"],
        "createdAt": row["created_at"],
    }


def _assigned_booking_customer(conn, booking_id, *, for_write=False):
    """The customer's user id for a booking assigned to the calling
    technician, else (None, error response). 404 for both "no such booking"
    and "someone else's booking" so ids can't be enumerated, matching the
    other booking-scoped technician routes. Reading the passport stays
    allowed on any assigned booking (including Completed/Cancelled ones);
    `for_write` additionally refuses a closed booking."""
    row = conn.execute(
        "SELECT user_id, technician_id, status FROM bookings WHERE id = ?", (booking_id,)
    ).fetchone()
    if not row or row["technician_id"] != request.technician["id"]:
        return None, (jsonify({"error": "not found"}), 404)
    if not row["user_id"]:
        return None, (jsonify({"error": "This booking has no associated customer account"}), 400)
    if for_write and row["status"] in kitchen_passport.CLOSED_BOOKING_STATUSES:
        return None, (jsonify({
            "error": "Conflict", "code": "booking_closed",
            "message": f"This booking is {row['status'].lower()}; appliances can no longer be registered on it.",
        }), 409)
    return row["user_id"], None


def _kitchen_conflict(code, message):
    return jsonify({"error": "Conflict", "code": code, "message": message}), 409


@app.route("/api/technician/bookings/<booking_id>/kitchen", methods=["GET"])
@require_technician_auth
def technician_booking_kitchen(booking_id):
    """Appliances already registered in the customer's Kitchen Passport, for
    the customer of a booking assigned to this technician."""
    conn = get_db()
    user_id, err = _assigned_booking_customer(conn, booking_id)
    if err:
        conn.close()
        return err
    rows = conn.execute(
        "SELECT * FROM kitchen_appliances WHERE user_id = ? ORDER BY created_at, id", (user_id,)
    ).fetchall()
    conn.close()
    return jsonify({"appliances": [kitchen_appliance_row_to_dict(r) for r in rows]})


@app.route("/api/technician/bookings/<booking_id>/kitchen/appliances", methods=["POST"])
@require_technician_auth
def technician_register_kitchen_appliance(booking_id):
    """Registers an appliance in the booking customer's passport.

    Duplicate handling: a retried submit (same `clientRequestId`, which the
    Partner app generates once per form) returns the already-created record
    with 200 instead of a second row; a serial number already registered for
    this customer + category is a 409. Two units of the same brand/model
    without a serial number are deliberately allowed — they can be genuine
    (two identical microwaves)."""
    data = request.get_json(force=True, silent=True)
    if not isinstance(data, dict):
        return jsonify({"error": "Invalid request", "message": "Request body must be a JSON object"}), 400
    clean, errors = kitchen_passport.validate_registration(data)
    if errors:
        return jsonify({"error": "Invalid request", "fields": errors}), 400
    conn = get_db()
    user_id, err = _assigned_booking_customer(conn, booking_id, for_write=True)
    if err:
        conn.close()
        return err
    tech_id = request.technician["id"]
    rid = clean["client_request_id"]

    def _by_request_id():
        if not rid:
            return None
        return conn.execute(
            "SELECT * FROM kitchen_appliances WHERE registered_by = ? AND client_request_id = ?",
            (tech_id, rid),
        ).fetchone()

    def _replay(row):
        if row["user_id"] != user_id:
            return _kitchen_conflict(
                "request_id_reused", "This request id was already used for a different customer.")
        return jsonify(kitchen_appliance_row_to_dict(row)), 200

    existing = _by_request_id()
    if existing:
        conn.close()
        return _replay(existing)

    appliance_id = new_uuid_id("KAPP")
    # One statement: insert only while the customer is under the cap, and let
    # the unique indexes (serial, request id) turn a duplicate into a no-op,
    # so concurrent requests can't slip past a separate count/exists check.
    cur = conn.execute(
        "INSERT INTO kitchen_appliances (id, user_id, category, brand, model, serial_number, "
        "install_year, specs, notes, registered_by, booking_id, serial_key, client_request_id, created_at) "
        "SELECT ?,?,?,?,?,?,?,?,?,?,?,?,?,? "
        "WHERE (SELECT COUNT(*) FROM kitchen_appliances WHERE user_id = ?) < ? "
        "ON CONFLICT DO NOTHING",
        (
            appliance_id, user_id, clean["category"], clean["brand"], clean["model"],
            clean["serial_number"], clean["install_year"], json.dumps(clean["specs"], sort_keys=True),
            clean["notes"], tech_id, booking_id, clean["serial_key"], rid, now(),
            user_id, kitchen_passport.MAX_APPLIANCES_PER_CUSTOMER,
        ),
    )
    created = cur.rowcount == 1
    conn.commit()
    if created:
        row = conn.execute("SELECT * FROM kitchen_appliances WHERE id = ?", (appliance_id,)).fetchone()
        conn.close()
        return jsonify(kitchen_appliance_row_to_dict(row)), 201
    # Nothing inserted: work out why (request-id race, duplicate serial, or cap).
    raced = _by_request_id()
    if raced:
        conn.close()
        return _replay(raced)
    if clean["serial_key"]:
        dup = conn.execute(
            "SELECT id FROM kitchen_appliances WHERE user_id = ? AND category = ? AND serial_key = ?",
            (user_id, clean["category"], clean["serial_key"]),
        ).fetchone()
        if dup:
            conn.close()
            return _kitchen_conflict(
                "duplicate_appliance",
                "An appliance with this serial number is already registered for this customer.")
    conn.close()
    return _kitchen_conflict(
        "appliance_limit_reached",
        f"A customer can have at most {kitchen_passport.MAX_APPLIANCES_PER_CUSTOMER} registered appliances.")


def _inspection_appliance(conn, booking_id, appliance_id, *, for_write):
    """(user_id, appliance row, error) for an inspection route. The booking
    must be assigned to the caller (and open, for writes), and the appliance
    must belong to that booking's customer — otherwise 404, so appliance ids
    of other customers can't be probed through a booking of your own."""
    user_id, err = _assigned_booking_customer(conn, booking_id, for_write=for_write)
    if err:
        return None, None, err
    appliance = conn.execute(
        "SELECT * FROM kitchen_appliances WHERE id = ? AND user_id = ?", (appliance_id, user_id)
    ).fetchone()
    if not appliance:
        return None, None, (jsonify({"error": "not found"}), 404)
    return user_id, appliance, None


def _inspection_payload(conn, booking_id, appliance):
    category = appliance["category"]
    rows = conn.execute(
        "SELECT check_key, result, note, updated_at FROM kitchen_inspection_checks "
        "WHERE appliance_id = ? AND booking_id = ?",
        (appliance["id"], booking_id),
    ).fetchall()
    saved = {r["check_key"]: r for r in rows}
    return {
        "applianceId": appliance["id"],
        "category": category,
        "bookingId": booking_id,
        "checks": [
            {
                "key": key,
                "label": label,
                "result": saved[key]["result"] if key in saved else None,
                "note": saved[key]["note"] if key in saved else "",
                "updatedAt": saved[key]["updated_at"] if key in saved else None,
            }
            for key, label in kitchen_passport.CHECKLISTS[category]
        ],
    }


@app.route("/api/technician/bookings/<booking_id>/kitchen/appliances/<appliance_id>/inspection",
           methods=["GET"])
@require_technician_auth
def get_kitchen_inspection(booking_id, appliance_id):
    """The category's checklist with whatever results this visit has saved so
    far (result null = not yet recorded). Readable on any assigned booking."""
    conn = get_db()
    _uid, appliance, err = _inspection_appliance(conn, booking_id, appliance_id, for_write=False)
    if err:
        conn.close()
        return err
    payload = _inspection_payload(conn, booking_id, appliance)
    conn.close()
    return jsonify(payload)


@app.route("/api/technician/bookings/<booking_id>/kitchen/appliances/<appliance_id>/inspection",
           methods=["PUT"])
@require_technician_auth
def save_kitchen_inspection(booking_id, appliance_id):
    """Upserts checklist results for this appliance on this visit (booking).
    Partial saves are fine; items not in the body are left as they were.
    Refused on Completed/Cancelled bookings like registration is."""
    data = request.get_json(force=True, silent=True)
    if not isinstance(data, dict):
        return jsonify({"error": "Invalid request", "message": "Request body must be a JSON object"}), 400
    conn = get_db()
    _uid, appliance, err = _inspection_appliance(conn, booking_id, appliance_id, for_write=True)
    if err:
        conn.close()
        return err
    rows, errors = kitchen_passport.validate_inspection(appliance["category"], data)
    if errors:
        conn.close()
        return jsonify({"error": "Invalid request", "fields": errors}), 400
    stamp = now()
    for key, result, note in rows:
        conn.execute(
            "INSERT INTO kitchen_inspection_checks "
            "(id, appliance_id, booking_id, technician_id, check_key, result, note, updated_at) "
            "VALUES (?,?,?,?,?,?,?,?) "
            "ON CONFLICT (appliance_id, booking_id, check_key) DO UPDATE SET "
            "result = excluded.result, note = excluded.note, "
            "technician_id = excluded.technician_id, updated_at = excluded.updated_at",
            (new_uuid_id("KCHK"), appliance_id, booking_id, request.technician["id"],
             key, result, note, stamp),
        )
    conn.commit()
    payload = _inspection_payload(conn, booking_id, appliance)
    conn.close()
    return jsonify(payload)


def _kitchen_health_entries(conn, user_id):
    """Per-appliance assessments for a customer's whole kitchen, computed from
    the saved checklist answers (latest usable visit per appliance)."""
    appliances = conn.execute(
        "SELECT id, category, brand, model FROM kitchen_appliances WHERE user_id = ? "
        "ORDER BY created_at, id", (user_id,)
    ).fetchall()
    rows_by_appliance = {a["id"]: [] for a in appliances}
    if appliances:
        marks = ",".join("?" * len(appliances))
        for r in conn.execute(
            "SELECT appliance_id, booking_id, check_key, result, note, updated_at "
            f"FROM kitchen_inspection_checks WHERE appliance_id IN ({marks})",
            [a["id"] for a in appliances],
        ).fetchall():
            rows_by_appliance[r["appliance_id"]].append(dict(r))
    entries = []
    for a in appliances:
        assessment, booking_id, assessed_at = kitchen_health.latest_assessment(
            a["category"], rows_by_appliance[a["id"]])
        if booking_id:
            # Only a technician-accepted, valid AI review for the SAME visit is folded in.
            assessment = kitchen_health.apply_ai_review(
                assessment, ai_review.effective_for_health(conn, a["id"], booking_id))
        entries.append({
            "id": a["id"], "category": a["category"], "brand": a["brand"], "model": a["model"],
            "assessment": assessment, "bookingId": booking_id, "assessedAt": assessed_at,
        })
    return entries


@app.route("/api/technician/bookings/<booking_id>/kitchen/appliances/<appliance_id>/health",
           methods=["GET"])
@require_technician_auth
def get_kitchen_appliance_health(booking_id, appliance_id):
    """Technician-assessed health of one appliance for THIS visit (booking),
    including the technician's own notes on flagged items. Same access rules
    as the checklist read."""
    conn = get_db()
    _uid, appliance, err = _inspection_appliance(conn, booking_id, appliance_id, for_write=False)
    if err:
        conn.close()
        return err
    rows = conn.execute(
        "SELECT check_key, result, note FROM kitchen_inspection_checks "
        "WHERE appliance_id = ? AND booking_id = ?", (appliance_id, booking_id)
    ).fetchall()
    review = ai_review.effective_for_health(conn, appliance_id, booking_id)
    conn.close()
    saved = {r["check_key"]: {"result": r["result"], "note": r["note"]} for r in rows}
    result = kitchen_health.assess_appliance(appliance["category"], saved, include_notes=True)
    result = kitchen_health.apply_ai_review(result, review)
    result.update({"applianceId": appliance_id, "bookingId": booking_id})
    return jsonify(result)


@app.route("/api/technician/bookings/<booking_id>/kitchen/health", methods=["GET"])
@require_technician_auth
def get_booking_kitchen_health(booking_id):
    """Kitchen-level view for the customer of a booking assigned to this
    technician. Built from every technician's saved answers, so it carries
    flagged item labels only — never another technician's free-text notes."""
    conn = get_db()
    user_id, err = _assigned_booking_customer(conn, booking_id)
    if err:
        conn.close()
        return err
    summary = kitchen_health.summarize_kitchen(_kitchen_health_entries(conn, user_id))
    conn.close()
    return jsonify(summary)


@app.route("/api/kitchen-passport/overview", methods=["GET"])
@require_auth
def get_my_kitchen_passport_overview():
    """The signed-in customer's own Passport: scores, service guidance and
    visit history. Everything is scoped to request.user; technician notes,
    booking ids and AI internals are not included."""
    user_id = request.user["id"]
    conn = get_db()
    try:
        entries = _kitchen_health_entries(conn, user_id)
        history = {}
        if entries:
            marks = ",".join("?" * len(entries))
            rows = conn.execute(
                "SELECT appliance_id, booking_id, check_key, result, note, updated_at "
                f"FROM kitchen_inspection_checks WHERE appliance_id IN ({marks})",
                [e["id"] for e in entries]).fetchall()
            # Only this customer's own bookings can appear in their history.
            bookings = {b["id"]: {"service": b["service"], "status": b["status"]} for b in conn.execute(
                "SELECT id, service, status FROM bookings WHERE user_id = ?", (user_id,)).fetchall()}
            by_appliance = {}
            for r in rows:
                by_appliance.setdefault(r["appliance_id"], []).append(dict(r))
            for e in entries:
                history[e["id"]] = kitchen_health.visit_history(
                    e["category"], by_appliance.get(e["id"], []), bookings)
        return jsonify(kitchen_health.customer_overview(entries, history))
    finally:
        conn.close()


@app.route("/api/kitchen-passport/health", methods=["GET"])
@require_auth
def get_my_kitchen_health():
    """The signed-in customer's own kitchen health (read-only)."""
    conn = get_db()
    summary = kitchen_health.summarize_kitchen(_kitchen_health_entries(conn, request.user["id"]))
    conn.close()
    return jsonify(summary)


# ---------------------------------------------------------------- vision AI (Stage A)
# Asynchronous, server-mediated photo inspection. Stage A ships the plumbing
# only: no real provider is integrated, so unless an operator explicitly
# configures one (see docs/VISION_AI.md) every submission is refused with 503
# and the health scores stay technician-only. Photos are validated and held in
# memory for the job; they are never stored.
def _ai_unavailable(code="ai_unavailable", message="AI inspection is not available right now."):
    return jsonify({"error": "Service unavailable", "code": code, "message": message}), 503


def _ai_job_for(conn, booking_id, appliance_id, inspection_id):
    return conn.execute(
        "SELECT * FROM kitchen_ai_inspections WHERE id = ? AND appliance_id = ? AND booking_id = ?",
        (inspection_id, appliance_id, booking_id),
    ).fetchone()


@app.route("/api/technician/ai-inspection/config", methods=["GET"])
@require_technician_auth
def ai_inspection_config():
    """What the Partner app needs before offering photo capture. No secrets
    and no provider details."""
    active = vision_provider.get_provider()
    return jsonify({
        "enabled": active is not None and not vision_jobs.breaker.is_open(),
        # True when the active provider fabricates output (tests / demos).
        "simulated": bool(getattr(active, "simulated", False)),
        "minImages": vision_images.MIN_IMAGES,
        "maxImages": vision_images.MAX_IMAGES,
        "maxImageBytes": vision_images.MAX_IMAGE_BYTES,
        "maxTotalBytes": vision_images.MAX_TOTAL_BYTES,
        "acceptedTypes": sorted(vision_images.ALLOWED_FORMATS.values()),
        "recommendedLongEdgePx": vision_images.OUTPUT_LONG_EDGE,
        "recommendedJpegQuality": vision_images.OUTPUT_QUALITY,
        "maxSubmissionsPerVisit": vision_jobs.max_submissions_per_visit(),
        "privacyNotice": vision_guardrails.PRIVACY_NOTICE,
    })


@app.route("/api/technician/bookings/<booking_id>/kitchen/appliances/<appliance_id>/ai-inspections",
           methods=["POST"])
@require_technician_auth
def submit_ai_inspection(booking_id, appliance_id):
    """Queues a Vision AI analysis of 1-5 photos of this appliance for this
    visit. Responds 202 immediately; poll the returned inspection id."""
    data = request.get_json(force=True, silent=True)
    if not isinstance(data, dict):
        return jsonify({"error": "Invalid request", "message": "Request body must be a JSON object"}), 400
    client_request_id = data.get("clientRequestId")
    if client_request_id is None:
        client_request_id = ""
    elif not isinstance(client_request_id, str) or not kitchen_passport._REQUEST_ID_RE.match(client_request_id):
        return jsonify({"error": "Invalid request",
                        "fields": {"clientRequestId": "must be 8-64 letters, digits, '-' or '_'"}}), 400

    conn = get_db()
    try:
        _uid, appliance, err = _inspection_appliance(conn, booking_id, appliance_id, for_write=True)
        if err:
            return err
        tech_id = request.technician["id"]
        vision_jobs.sweep_stale(conn)
        replay = vision_jobs.find_by_request_id(conn, tech_id, client_request_id)
        if replay:
            if replay["appliance_id"] != appliance_id or replay["booking_id"] != booking_id:
                return jsonify({"error": "Conflict", "code": "request_id_reused",
                                "message": "This request id was already used for a different inspection."}), 409
            return jsonify({"inspection": vision_jobs.serialise(replay)}), 200
        # AI availability is checked after ownership and replay, so a retried
        # request still returns its original job and a disabled deployment
        # reveals nothing about other technicians' bookings.
        if vision_provider.get_provider() is None:
            return _ai_unavailable()
        if vision_jobs.breaker.is_open():
            return _ai_unavailable("circuit_open", "The AI service is temporarily unavailable. Please try again later.")
        if not vision_jobs.queue_has_room():
            return _ai_unavailable("busy", vision_jobs.BUSY_MESSAGE)
        limit_error = vision_jobs._limit_error(conn, appliance_id, booking_id, tech_id)
        if limit_error:
            return jsonify({"error": "Too Many Requests", "code": limit_error.code,
                            "message": limit_error.message}), 429
        category = appliance["category"]
        check_rows = conn.execute(
            "SELECT check_key, result FROM kitchen_inspection_checks WHERE appliance_id = ? AND booking_id = ?",
            (appliance_id, booking_id),
        ).fetchall()
    finally:
        conn.close()

    # CPU-bound decode / re-encode happens with no database connection held.
    try:
        images = vision_images.validate_images(data.get("images"))
    except vision_images.ImageRejected as rejected:
        body = {"error": "Invalid request", "code": rejected.code, "message": rejected.message}
        if rejected.index is not None:
            body["imageIndex"] = rejected.index
        return jsonify(body), 400

    labels = dict(kitchen_passport.CHECKLISTS[category])
    ctx = {
        "category": category, "applianceId": appliance_id, "bookingId": booking_id,
        "images": [i.jpeg for i in images],
        # Checklist label -> result only; technician free-text notes are never sent.
        "technician_checks": {labels[r["check_key"]]: r["result"] for r in check_rows if r["check_key"] in labels},
    }
    conn = get_db()
    try:
        try:
            row, created = vision_jobs.create_job(
                conn, appliance_id=appliance_id, booking_id=booking_id, technician_id=tech_id,
                client_request_id=client_request_id, image_hashes=[i.sha256 for i in images])
        except vision_jobs.SubmitError as e:
            return jsonify({"error": "Too Many Requests" if e.http_status == 429 else "Conflict",
                            "code": e.code, "message": e.message}), e.http_status
        job_id = row["id"]
    finally:
        conn.close()
    if not created:
        conn = get_db()
        try:
            return jsonify({"inspection": vision_jobs.serialise(
                conn.execute("SELECT * FROM kitchen_ai_inspections WHERE id = ?", (job_id,)).fetchone())}), 200
        finally:
            conn.close()
    if not vision_jobs.enqueue(job_id, ctx):
        vision_jobs.mark_busy(job_id)
    conn = get_db()
    try:
        row = conn.execute("SELECT * FROM kitchen_ai_inspections WHERE id = ?", (job_id,)).fetchone()
        return jsonify({"inspection": vision_jobs.serialise(row)}), 202
    finally:
        conn.close()


@app.route("/api/technician/bookings/<booking_id>/kitchen/appliances/<appliance_id>/ai-inspections",
           methods=["GET"])
@require_technician_auth
def list_ai_inspections(booking_id, appliance_id):
    """Recent analyses for this appliance on this visit (newest first), without
    result bodies. Readable on closed bookings."""
    conn = get_db()
    try:
        _uid, _appliance, err = _inspection_appliance(conn, booking_id, appliance_id, for_write=False)
        if err:
            return err
        vision_jobs.sweep_stale(conn)
        rows = conn.execute(
            "SELECT * FROM kitchen_ai_inspections WHERE appliance_id = ? AND booking_id = ? "
            "ORDER BY created_at DESC, id DESC LIMIT 10", (appliance_id, booking_id)).fetchall()
        return jsonify({"inspections": [vision_jobs.serialise(r, include_result=False) for r in rows]})
    finally:
        conn.close()


@app.route("/api/technician/bookings/<booking_id>/kitchen/appliances/<appliance_id>/ai-inspections/<inspection_id>",
           methods=["GET"])
@require_technician_auth
def get_ai_inspection(booking_id, appliance_id, inspection_id):
    """Status (and, once completed, the validated result) of one analysis.
    An id that belongs to another appliance or visit is a 404."""
    conn = get_db()
    try:
        _uid, _appliance, err = _inspection_appliance(conn, booking_id, appliance_id, for_write=False)
        if err:
            return err
        vision_jobs.sweep_stale(conn)
        row = _ai_job_for(conn, booking_id, appliance_id, inspection_id)
        if not row:
            return jsonify({"error": "not found"}), 404
        payload = vision_jobs.serialise(row)
        review = ai_review.latest_review(conn, inspection_id)
        payload["review"] = ai_review.serialise(review) if review else None
        if payload["result"] is not None:
            # The stored result is untouched; only this response says whether a
            # technician has accepted it and whether it feeds the health score.
            eligible = ai_review.effective_for_health(conn, appliance_id, booking_id)
            payload["result"]["accepted"] = bool(review and review["decision"] in (ai_review.ACCEPT, ai_review.EDIT))
            payload["result"]["usedInHealthScore"] = bool(eligible and eligible["inspectionId"] == inspection_id)
        return jsonify({"inspection": payload})
    finally:
        conn.close()


@app.route("/api/technician/bookings/<booking_id>/kitchen/appliances/<appliance_id>/ai-inspections/<inspection_id>/review",
           methods=["POST"])
@require_technician_auth
def review_ai_inspection(booking_id, appliance_id, inspection_id):
    """Records the technician's decision (accept / edit / reject) about an AI
    result. Append-only: the AI result itself is never changed, and a repeat of
    the same clientRequestId returns the original decision. Only the technician
    who ran the analysis, on a booking still assigned to them and open, may
    review it."""
    data = request.get_json(force=True, silent=True)
    if not isinstance(data, dict):
        return jsonify({"error": "Invalid request", "message": "Request body must be a JSON object"}), 400
    client_request_id = data.get("clientRequestId")
    if not isinstance(client_request_id, str) or not kitchen_passport._REQUEST_ID_RE.match(client_request_id):
        return jsonify({"error": "Invalid request",
                        "fields": {"clientRequestId": "required: 8-64 letters, digits, '-' or '_'"}}), 400
    conn = get_db()
    try:
        _uid, _appliance, err = _inspection_appliance(conn, booking_id, appliance_id, for_write=True)
        if err:
            return err
        tech_id = request.technician["id"]
        row = _ai_job_for(conn, booking_id, appliance_id, inspection_id)
        # Someone else's analysis is indistinguishable from a missing one.
        if not row or row["technician_id"] != tech_id:
            return jsonify({"error": "not found"}), 404
        try:
            review, created = ai_review.create_review(conn, row, tech_id, data, client_request_id)
        except ai_review.ReviewError as e:
            body = {"error": "Invalid request" if e.status == 400 else "Conflict",
                    "code": e.code, "message": e.message}
            if e.fields:
                body["fields"] = e.fields
            return jsonify(body), e.status
        return jsonify({"review": ai_review.serialise(review)}), 201 if created else 200
    finally:
        conn.close()


@app.route("/api/technician/custom-brands", methods=["GET"])
@require_technician_auth
def list_custom_brands():
    category = request.args.get("category")
    if category is not None and category not in kitchen_passport.CATEGORIES:
        return jsonify({"error": "Invalid request", "fields": {"category": "is not a known appliance category"}}), 400
    conn = get_db()
    if category:
        rows = conn.execute(
            "SELECT * FROM custom_brands WHERE technician_id = ? AND category = ? ORDER BY name_key",
            (request.technician["id"], category),
        ).fetchall()
    else:
        rows = conn.execute(
            "SELECT * FROM custom_brands WHERE technician_id = ? ORDER BY category, name_key",
            (request.technician["id"],),
        ).fetchall()
    conn.close()
    return jsonify({"brands": [{"id": r["id"], "category": r["category"], "name": r["name"]} for r in rows]})


@app.route("/api/technician/custom-brands", methods=["POST"])
@require_technician_auth
def add_custom_brand():
    """Saves a brand the technician typed via Add Brand so it's offered again
    for that appliance category. Idempotent: re-adding the same name (any
    case) returns the existing row with 200 instead of a duplicate."""
    data = request.get_json(force=True, silent=True)
    if not isinstance(data, dict):
        return jsonify({"error": "Invalid request", "message": "Request body must be a JSON object"}), 400
    errors = {}
    category = data.get("category")
    if category not in kitchen_passport.CATEGORIES:
        errors["category"] = "must be one of: " + ", ".join(kitchen_passport.CATEGORIES)
    msg = kitchen_passport.validate_brand_name(data.get("name"))
    if msg:
        errors["name"] = msg
    if errors:
        return jsonify({"error": "Invalid request", "fields": errors}), 400
    name = kitchen_passport.normalise_brand_name(data["name"])
    key = kitchen_passport.brand_key(name)
    tech_id = request.technician["id"]
    conn = get_db()

    def _find():
        return conn.execute(
            "SELECT * FROM custom_brands WHERE technician_id = ? AND category = ? AND name_key = ?",
            (tech_id, category, key),
        ).fetchone()

    def _reply(row, status):
        return jsonify({"id": row["id"], "category": row["category"], "name": row["name"]}), status

    existing = _find()
    if existing:
        conn.close()
        return _reply(existing, 200)
    # Insert only while under the cap; the unique key makes a concurrent
    # duplicate a no-op that the re-read below turns into a 200.
    cur = conn.execute(
        "INSERT INTO custom_brands (id, technician_id, category, name, name_key, created_at) "
        "SELECT ?,?,?,?,?,? "
        "WHERE (SELECT COUNT(*) FROM custom_brands WHERE technician_id = ?) < ? "
        "ON CONFLICT DO NOTHING",
        (new_uuid_id("KBRAND"), tech_id, category, name, key, now(),
         tech_id, kitchen_passport.MAX_CUSTOM_BRANDS_PER_TECHNICIAN),
    )
    created = cur.rowcount == 1
    conn.commit()
    row = _find()
    conn.close()
    if row:
        return _reply(row, 201 if created else 200)
    return _kitchen_conflict(
        "brand_limit_reached",
        f"You can save at most {kitchen_passport.MAX_CUSTOM_BRANDS_PER_TECHNICIAN} custom brands.")


@app.route("/api/kitchen-passport", methods=["GET"])
@require_auth
def get_kitchen_passport():
    """The signed-in customer's own registered appliances."""
    conn = get_db()
    rows = conn.execute(
        "SELECT * FROM kitchen_appliances WHERE user_id = ? ORDER BY created_at, id",
        (request.user["id"],),
    ).fetchall()
    conn.close()
    return jsonify({"appliances": [kitchen_appliance_row_to_dict(r) for r in rows]})


@app.route("/api/technician/bookings/<booking_id>/service", methods=["PATCH"])
@require_technician_auth
@validate_json({
    "serviceId": Field(str, required=True, max_len=50),
})
def update_booking_service(booking_id):
    """The technician swaps this booking's service for a different one in
    the same catalog category — e.g. the customer asks mid-visit to
    upgrade a filter clean into a full deep clean. Recomputes price/
    total_amount straight from the real services catalog the exact same
    way create_booking's service_id path does (total_amount = the
    catalog's own price), so the new amount is real, not client-supplied,
    and immediately shows up everywhere that reads this booking — the
    Customer app's invoice included. Logs the change to
    booking_service_changes so the customer can see exactly what changed.
    Blocked once the job is already Completed or Cancelled — the invoice
    is final by then."""
    data = request.get_json(force=True, silent=True) or {}
    service_id = data["serviceId"]
    with database.db_session() as conn:
        row = conn.execute(BOOKING_SELECT + " WHERE bookings.id = ?", (booking_id,)).fetchone()
        if not row:
            return jsonify({"error": "not found"}), 404
        if row["technician_id"] != request.technician["id"]:
            return jsonify({"error": "not found"}), 404
        if row["status"] in ("Completed", "Cancelled"):
            return jsonify({
                "error": "Job already finished",
                "message": "Can't change the service on a completed or cancelled job.",
            }), 400
        service_row = conn.execute(SERVICE_SELECT + " WHERE services.id = ?", (service_id,)).fetchone()
        if not service_row:
            return jsonify({"error": "Unknown serviceId"}), 400
        if service_row["category"] != row["category"]:
            return jsonify({
                "error": "Service category mismatch",
                "message": "That service isn't offered for this job's category.",
            }), 400
        new_service_name = service_row["appliance_name"] + " · " + service_row["name"]
        new_price = service_row["price"]
        ts = now()
        conn.execute(
            "INSERT INTO booking_service_changes "
            "(id, booking_id, old_service, new_service, old_price, new_price, created_at) "
            "VALUES (?,?,?,?,?,?,?)",
            (new_uuid_id("SVCC"), booking_id, row["service"], new_service_name, row["price"], new_price, ts),
        )
        conn.execute(
            "UPDATE bookings SET service = ?, price = ?, total_amount = ?, updated_at = ? WHERE id = ?",
            (new_service_name, new_price, new_price, ts, booking_id),
        )
        row = conn.execute(BOOKING_SELECT + " WHERE bookings.id = ?", (booking_id,)).fetchone()
        parts = fetch_booking_parts(conn, booking_id)
        service_changes = fetch_booking_service_changes(conn, booking_id)
        return jsonify(booking_row_to_dict(row, parts=parts, service_changes=service_changes))


@app.route("/api/technician/bookings/<booking_id>/parts", methods=["POST"])
@require_technician_auth
@validate_json({
    "name": Field(str, required=True, min_len=1, max_len=200),
    "sku": Field(str, max_len=100),
    "qty": Field(int, required=True, min_val=1, max_val=99),
    "pricePaise": Field(NUMBER, required=True, min_val=0, max_val=10_000_000),
})
def add_booking_part(booking_id):
    """A real part/extra-work quote the technician is raising mid-job — e.g.
    "the baffle filter also needs replacing, ₹640" — separate from the
    booking's own fixed service price. Starts 'pending': the customer sees
    it on their invoice and approves or rejects it via PATCH .../parts/<id>
    below; nothing is charged just by adding it here."""
    data = request.get_json(force=True, silent=True) or {}
    conn = get_db()
    row = conn.execute("SELECT technician_id FROM bookings WHERE id = ?", (booking_id,)).fetchone()
    if not row:
        conn.close()
        return jsonify({"error": "not found"}), 404
    if row["technician_id"] != request.technician["id"]:
        conn.close()
        return jsonify({"error": "not found"}), 404
    part_id = new_uuid_id("PART")
    conn.execute(
        "INSERT INTO booking_parts (id, booking_id, name, sku, qty, price_paise, status, created_at) "
        "VALUES (?,?,?,?,?,?,'pending',?)",
        (part_id, booking_id, data["name"].strip(), (data.get("sku") or "").strip() or None,
         data["qty"], data["pricePaise"], now()),
    )
    conn.commit()
    row = conn.execute("SELECT * FROM booking_parts WHERE id = ?", (part_id,)).fetchone()
    conn.close()
    return jsonify(part_row_to_dict(row)), 201


@app.route("/api/technician/bookings/<booking_id>/parts/<part_id>", methods=["DELETE"])
@require_technician_auth
def delete_booking_part(booking_id, part_id):
    """Lets a technician retract a quote they raised by mistake — only
    while it's still 'pending'. Once the customer has actually approved or
    rejected it, that's a real decision on record and stays, same spirit as
    advance_booking never letting a completed step un-happen."""
    conn = get_db()
    booking = conn.execute("SELECT technician_id FROM bookings WHERE id = ?", (booking_id,)).fetchone()
    if not booking:
        conn.close()
        return jsonify({"error": "not found"}), 404
    if booking["technician_id"] != request.technician["id"]:
        conn.close()
        return jsonify({"error": "not found"}), 404
    part = conn.execute(
        "SELECT * FROM booking_parts WHERE id = ? AND booking_id = ?", (part_id, booking_id)
    ).fetchone()
    if not part:
        conn.close()
        return jsonify({"error": "not found"}), 404
    if part["status"] != "pending":
        conn.close()
        return jsonify({
            "error": "Already decided",
            "message": "The customer has already approved or rejected this — it can't be removed.",
        }), 400
    conn.execute("DELETE FROM booking_parts WHERE id = ?", (part_id,))
    conn.commit()
    conn.close()
    return jsonify({"ok": True})


@app.route("/api/bookings/<booking_id>/parts/<part_id>", methods=["PATCH"])
@require_auth
@validate_json({
    "status": Field(str, required=True, choices=("approved", "rejected")),
})
def decide_booking_part(booking_id, part_id):
    """The customer's side of the quote: approve or reject a part the
    technician raised. Only the booking's own customer can decide — checked
    the same way get_booking scopes a fetch, 404 rather than 403 so a
    guessed id doesn't confirm anything exists."""
    data = request.get_json(force=True, silent=True) or {}
    conn = get_db()
    booking = conn.execute("SELECT user_id FROM bookings WHERE id = ?", (booking_id,)).fetchone()
    if not booking or booking["user_id"] != request.user["id"]:
        conn.close()
        return jsonify({"error": "not found"}), 404
    part = conn.execute(
        "SELECT * FROM booking_parts WHERE id = ? AND booking_id = ?", (part_id, booking_id)
    ).fetchone()
    if not part:
        conn.close()
        return jsonify({"error": "not found"}), 404
    if part["status"] != "pending":
        conn.close()
        return jsonify({"error": "Already decided", "message": "This quote was already decided."}), 400
    conn.execute(
        "UPDATE booking_parts SET status = ?, decided_at = ? WHERE id = ?",
        (data["status"], now(), part_id),
    )
    conn.commit()
    row = conn.execute("SELECT * FROM booking_parts WHERE id = ?", (part_id,)).fetchone()
    conn.close()
    return jsonify(part_row_to_dict(row))


# ---------------------------------------------------------------- inventory
@app.route("/api/inventory", methods=["GET"])
@require_staff_auth
def list_inventory():
    conn = get_db()
    rows = conn.execute("SELECT * FROM inventory ORDER BY name").fetchall()
    conn.close()
    return jsonify([inventory_row_to_dict(r) for r in rows])


@app.route("/api/inventory", methods=["POST"])
@require_staff_auth
@validate_json({
    "name": Field(str, required=True, min_len=1, max_len=100),
    "sku": Field(str, required=True, min_len=1, max_len=50),
    "category": Field(str, required=True, min_len=1, max_len=100),
    "quantity": Field(int, min_val=0, max_val=1_000_000),
    "reorderLevel": Field(int, min_val=0, max_val=1_000_000),
})
def create_inventory_item():
    data = request.get_json(force=True, silent=True) or {}
    name = data["name"].strip()
    sku = data["sku"].strip()
    category = data["category"].strip()
    quantity = data.get("quantity", 0)
    reorder_level = data.get("reorderLevel", 10)

    conn = get_db()
    item_id = new_uuid_id("INV")
    conn.execute(
        "INSERT INTO inventory (id, name, sku, category, quantity, reorder_level, updated_at) "
        "VALUES (?,?,?,?,?,?,?)",
        (item_id, name, sku, category, quantity, reorder_level, now()),
    )
    conn.commit()
    row = conn.execute("SELECT * FROM inventory WHERE id = ?", (item_id,)).fetchone()
    conn.close()
    return jsonify(inventory_row_to_dict(row)), 201


@app.route("/api/inventory/<item_id>", methods=["PATCH"])
@require_staff_auth
@validate_json({
    "quantity": Field(int, min_val=0, max_val=1_000_000),
    "reorderLevel": Field(int, min_val=0, max_val=1_000_000),
})
def update_inventory_item(item_id):
    data = request.get_json(force=True, silent=True) or {}
    conn = get_db()
    row = conn.execute("SELECT * FROM inventory WHERE id = ?", (item_id,)).fetchone()
    if not row:
        conn.close()
        return jsonify({"error": "not found"}), 404
    quantity = data["quantity"] if "quantity" in data else row["quantity"]
    reorder_level = data["reorderLevel"] if "reorderLevel" in data else row["reorder_level"]
    conn.execute(
        "UPDATE inventory SET quantity = ?, reorder_level = ?, updated_at = ? WHERE id = ?",
        (quantity, reorder_level, now(), item_id),
    )
    conn.commit()
    row = conn.execute("SELECT * FROM inventory WHERE id = ?", (item_id,)).fetchone()
    conn.close()
    return jsonify(inventory_row_to_dict(row))


# ---------------------------------------------------------------- stats
@app.route("/api/stats/overview", methods=["GET"])
@require_staff_auth
def stats_overview():
    is_owner = _owner_identity_ok()
    conn = get_db()
    total_bookings = conn.execute("SELECT COUNT(*) AS n FROM bookings").fetchone()["n"]
    revenue = None
    if is_owner:
        revenue = conn.execute(
            "SELECT COALESCE(SUM(price),0) AS s FROM bookings WHERE status = 'Completed'"
        ).fetchone()["s"]
    open_complaints = conn.execute(
        "SELECT COUNT(*) AS n FROM complaints WHERE status != 'Resolved'"
    ).fetchone()["n"]
    online_techs = conn.execute(
        "SELECT COUNT(*) AS n FROM technicians WHERE online = 1"
    ).fetchone()["n"]
    total_techs = conn.execute("SELECT COUNT(*) AS n FROM technicians").fetchone()["n"]
    conn.close()
    result = {
        "totalBookings": total_bookings,
        "openComplaints": open_complaints,
        "onlineTechnicians": online_techs,
        "totalTechnicians": total_techs,
    }
    if is_owner:
        result["revenue"] = revenue
    return jsonify(result)


# ---------------------------------------------------------------- reports
PERIOD_DAYS = {"week": 7, "month": 30, "quarter": 90}
TECH_PAYOUT_RATE = 0.65  # assumed share of revenue paid out to technicians — not a real ledger figure


@app.route("/api/stats/reports", methods=["GET"])
@require_staff_auth
def stats_reports():
    is_owner = _owner_identity_ok()
    period = request.args.get("period", "week")
    days = PERIOD_DAYS.get(period, 7)
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat(timespec="seconds") + "Z"
    # Optional district filter (see careplus_admin's State -> District picker)
    # — scopes every number in this report down to one operating area
    # instead of the whole business.
    area = (request.args.get("area") or "").strip() or None

    conn = get_db()
    # bookings.created_at must be qualified — BOOKING_SELECT LEFT JOINs
    # technicians and users, and users has its own created_at column, so an
    # unqualified WHERE created_at >= ? is ambiguous to SQLite (unlike an
    # unqualified ORDER BY, which resolves against the result-set's column
    # names rather than the source tables, so that form alone was fine).
    # This was silently 500ing every single call before this fix, filtered
    # or not — a pre-existing regression from BOOKING_SELECT gaining that
    # users join, unrelated to the district filter added here.
    if area:
        bookings = conn.execute(
            BOOKING_LIST_SELECT + " WHERE bookings.created_at >= ? AND bookings.area = ? "
            "ORDER BY bookings.created_at",
            (cutoff, area),
        ).fetchall()
        complaints = conn.execute(
            "SELECT complaints.* FROM complaints JOIN bookings ON bookings.id = complaints.booking_id "
            "WHERE complaints.created_at >= ? AND bookings.area = ?",
            (cutoff, area),
        ).fetchall()
        technicians = conn.execute("SELECT * FROM technicians WHERE area = ?", (area,)).fetchall()
    else:
        bookings = conn.execute(
            BOOKING_LIST_SELECT + " WHERE bookings.created_at >= ? ORDER BY bookings.created_at",
            (cutoff,),
        ).fetchall()
        complaints = conn.execute(
            "SELECT * FROM complaints WHERE created_at >= ?", (cutoff,)
        ).fetchall()
        technicians = conn.execute("SELECT * FROM technicians").fetchall()
    conn.close()

    completed = [b for b in bookings if b["status"] == "Completed"]

    revenue_by_day = {}
    rating_sum_by_day = {}
    rating_count_by_day = {}
    for b in completed:
        day = b["updated_at"][:10]
        amount = b["total_amount"] if "total_amount" in b.keys() and b["total_amount"] is not None else b["price"]
        revenue_by_day[day] = revenue_by_day.get(day, 0) + amount
        if b["service_rating"] is not None:
            rating_sum_by_day[day] = rating_sum_by_day.get(day, 0) + b["service_rating"]
            rating_count_by_day[day] = rating_count_by_day.get(day, 0) + 1
    revenue_trend = [{"date": d, "revenue": v} for d, v in sorted(revenue_by_day.items())]
    rating_trend = [
        {"date": d, "avgRating": round(rating_sum_by_day[d] / rating_count_by_day[d], 2)}
        for d in sorted(rating_count_by_day)
    ]

    revenue_by_category = {}
    for b in completed:
        amount = b["total_amount"] if "total_amount" in b.keys() and b["total_amount"] is not None else b["price"]
        revenue_by_category[b["category"]] = revenue_by_category.get(b["category"], 0) + amount
    revenue_by_category = [
        {"category": c, "revenue": v} for c, v in sorted(revenue_by_category.items(), key=lambda kv: -kv[1])
    ]

    jobs_by_tech = {}
    revenue_by_tech = {}
    for b in completed:
        amount = b["total_amount"] if "total_amount" in b.keys() and b["total_amount"] is not None else b["price"]
        jobs_by_tech[b["technician_id"]] = jobs_by_tech.get(b["technician_id"], 0) + 1
        revenue_by_tech[b["technician_id"]] = revenue_by_tech.get(b["technician_id"], 0) + amount
    leaderboard = []
    for t in technicians:
        entry = {
            "id": t["id"],
            "name": t["name"],
            "jobsInPeriod": jobs_by_tech.get(t["id"], 0),
            "rating": round(t["rating"], 1),
        }
        if is_owner:
            entry["revenueInPeriod"] = revenue_by_tech.get(t["id"], 0)
        leaderboard.append(entry)
    leaderboard.sort(
        key=lambda x: -(x.get("revenueInPeriod", x["jobsInPeriod"]))
    )

    complaint_status_breakdown = {}
    for c in complaints:
        complaint_status_breakdown[c["status"]] = complaint_status_breakdown.get(c["status"], 0) + 1

    gross_revenue = sum(revenue_by_day.values())
    result = {
        "period": period,
        "revenueTrend": revenue_trend if is_owner else [],
        "ratingTrend": rating_trend,
        "revenueByCategory": revenue_by_category if is_owner else [],
        "technicianLeaderboard": leaderboard,
        "complaintStatusBreakdown": [
            {"status": s, "count": n} for s, n in complaint_status_breakdown.items()
        ],
        "completedJobs": len(completed),
        "isOwner": is_owner,
        "pnl": None,
    }
    if is_owner:
        result["grossRevenue"] = gross_revenue
        payout = round(gross_revenue * TECH_PAYOUT_RATE)
        result["pnl"] = {
            "grossRevenue": gross_revenue,
            "technicianPayout": payout,
            "netMargin": gross_revenue - payout,
            "payoutRateAssumed": TECH_PAYOUT_RATE,
        }
    return jsonify(result)


# ---------------------------------------------------------------- reset
# No longer wipes and reseeds fake data (see database.py's seed() docstring)
# — init_db() itself already purges any leftover demo rows on every boot,
# so this just re-runs that, idempotently. Kept as a manual trigger for an
# already-running instance that hasn't restarted since the demo data was
# removed. Owner-only: even idempotent initialization is an operational control.
@app.route("/api/reset", methods=["POST"])
@require_owner
def reset():
    init_db()
    return jsonify({"ok": True})


# ==================================================================
# Home Services API — backs homeservices.html. Reuses the RasoiCare
# login (@require_auth, same as /api/bookings etc.) rather than having
# its own account system; every row is scoped to request.user["id"].
# ==================================================================
# Mirrors homeservices.html's own SERVICES list. hs_create_booking prices
# a booking from here rather than trusting the client's price/serviceName
# fields — without this, a request could claim any price up to the
# validator's 10,000,000 ceiling, and hs_advance_booking pays 5% of it
# straight into the wallet on completion with no technician or payment
# ever involved, i.e. self-serve, unlimited point creation from a
# fabricated number.
HS_SERVICES = {
    "water-purifier": ("Water Purifier", 399),
    "otg": ("OTG", 449),
    "hob": ("Hob & Cooktop", 499),
    "microwave": ("Microwave", 549),
    "chimney": ("Chimney", 599),
    "fridge": ("Refrigerator", 649),
    "dishwasher": ("Dishwasher", 699),
}


def hs_booking_row_to_dict(row):
    return {
        "id": row["id"],
        "serviceId": row["service_id"],
        "serviceName": row["service_name"],
        "price": row["price"],
        "date": row["date"],
        "status": row["status"],
        "createdAt": row["created_at"],
        "updatedAt": row["updated_at"],
    }


def hs_wallet_state(conn, user_id):
    wallet_row = conn.execute("SELECT * FROM hs_wallet WHERE user_id = ?", (user_id,)).fetchone()
    tx_rows = conn.execute(
        "SELECT * FROM hs_wallet_tx WHERE user_id = ? ORDER BY created_at DESC", (user_id,)
    ).fetchall()
    return {
        "points": wallet_row["points"] if wallet_row else 100,
        "tx": [{"label": t["label"], "amount": t["amount"], "ts": t["created_at"]} for t in tx_rows],
    }


def hs_profile_dict(row, user_id, fallback_name):
    if row is None:
        return {"name": fallback_name, "plan": None}
    return {"name": row["name"] or fallback_name, "plan": row["plan"]}


def hs_ensure_wallet_and_profile(conn, user_id, fallback_name):
    """First Home Services call for this user — create their wallet
    (100 starter points, matching the old prototype's default) and
    profile rows. A no-op on every later call."""
    if conn.execute("SELECT 1 FROM hs_wallet WHERE user_id = ?", (user_id,)).fetchone() is None:
        conn.execute("INSERT INTO hs_wallet (user_id, points) VALUES (?, 100)", (user_id,))
    if conn.execute("SELECT 1 FROM hs_profile WHERE user_id = ?", (user_id,)).fetchone() is None:
        conn.execute(
            "INSERT INTO hs_profile (user_id, name, plan) VALUES (?, ?, NULL)",
            (user_id, fallback_name),
        )
    conn.commit()


@app.route("/api/hs/state", methods=["GET"])
@require_auth
def hs_state():
    user_id = request.user["id"]
    conn = get_db()
    hs_ensure_wallet_and_profile(conn, user_id, request.user["name"])
    bookings = conn.execute(
        "SELECT * FROM hs_bookings WHERE user_id = ? ORDER BY created_at DESC", (user_id,)
    ).fetchall()
    profile_row = conn.execute("SELECT * FROM hs_profile WHERE user_id = ?", (user_id,)).fetchone()
    wallet = hs_wallet_state(conn, user_id)
    conn.close()
    return jsonify({
        "bookings": [hs_booking_row_to_dict(b) for b in bookings],
        "wallet": wallet,
        "profile": hs_profile_dict(profile_row, user_id, request.user["name"]),
    })


@app.route("/api/hs/bookings", methods=["POST"])
@require_auth
@validate_json({
    "serviceId": Field(str, required=True, min_len=1, max_len=50),
    "date": Field(str, required=True, min_len=1, max_len=50),
})
def hs_create_booking():
    data = request.get_json(force=True, silent=True) or {}
    service_id = data["serviceId"]
    date = data["date"]
    catalog_entry = HS_SERVICES.get(service_id)
    if not catalog_entry:
        return jsonify({"error": f"Unknown serviceId: {service_id}"}), 400
    service_name, price = catalog_entry

    conn = get_db()
    hs_ensure_wallet_and_profile(conn, request.user["id"], request.user["name"])
    booking_id = new_uuid_id("HS")
    ts = now()
    conn.execute(
        "INSERT INTO hs_bookings (id, user_id, service_id, service_name, price, date, status, created_at, updated_at) "
        "VALUES (?,?,?,?,?,?,?,?,?)",
        (booking_id, request.user["id"], service_id, service_name, price, date, STATUS_ORDER[0], ts, ts),
    )
    conn.commit()
    row = conn.execute("SELECT * FROM hs_bookings WHERE id = ?", (booking_id,)).fetchone()
    conn.close()
    return jsonify(hs_booking_row_to_dict(row)), 201


@app.route("/api/hs/bookings/<booking_id>/advance", methods=["PATCH"])
@require_auth
def hs_advance_booking(booking_id):
    """Called by the client's auto-progress timers to move a booking to
    its next status; awards wallet cashback the moment it reaches
    Completed. Same STATUS_ORDER stages as RasoiCare's bookings."""
    user_id = request.user["id"]
    conn = get_db()
    row = conn.execute(
        "SELECT * FROM hs_bookings WHERE id = ? AND user_id = ?", (booking_id, user_id)
    ).fetchone()
    if not row:
        conn.close()
        return jsonify({"error": "not found"}), 404
    hs_ensure_wallet_and_profile(conn, user_id, request.user["name"])

    idx = STATUS_ORDER.index(row["status"]) if row["status"] in STATUS_ORDER else 0
    if idx < len(STATUS_ORDER) - 1:
        new_status = STATUS_ORDER[idx + 1]
        conn.execute(
            "UPDATE hs_bookings SET status = ?, updated_at = ? WHERE id = ?",
            (new_status, now(), booking_id),
        )
        if new_status == "Completed":
            earned = round(row["price"] * 0.05)
            conn.execute(
                "UPDATE hs_wallet SET points = points + ? WHERE user_id = ?", (earned, user_id)
            )
            conn.execute(
                "INSERT INTO hs_wallet_tx (id, user_id, label, amount, created_at) VALUES (?,?,?,?,?)",
                (new_uuid_id("TX"), user_id, "Cashback: " + row["service_name"], earned, now()),
            )
        conn.commit()
        row = conn.execute("SELECT * FROM hs_bookings WHERE id = ?", (booking_id,)).fetchone()

    wallet = hs_wallet_state(conn, user_id)
    conn.close()
    return jsonify({"booking": hs_booking_row_to_dict(row), "wallet": wallet})


@app.route("/api/hs/wallet/redeem", methods=["POST"])
@require_auth
def hs_redeem():
    user_id = request.user["id"]
    conn = get_db()
    hs_ensure_wallet_and_profile(conn, user_id, request.user["name"])
    wallet_row = conn.execute("SELECT * FROM hs_wallet WHERE user_id = ?", (user_id,)).fetchone()
    if wallet_row["points"] < 50:
        conn.close()
        return jsonify({"error": "Not enough points"}), 400
    conn.execute("UPDATE hs_wallet SET points = points - 50 WHERE user_id = ?", (user_id,))
    conn.execute(
        "INSERT INTO hs_wallet_tx (id, user_id, label, amount, created_at) VALUES (?,?,?,?,?)",
        (new_uuid_id("TX"), user_id, "Redeemed for ₹5 off", -50, now()),
    )
    conn.commit()
    wallet = hs_wallet_state(conn, user_id)
    conn.close()
    return jsonify(wallet)


@app.route("/api/hs/profile", methods=["PATCH"])
@require_auth
@validate_json({
    "name": Field(str, max_len=100),
    "plan": Field(str, max_len=100),
})
def hs_update_profile():
    data = request.get_json(force=True, silent=True) or {}
    user_id = request.user["id"]
    conn = get_db()
    hs_ensure_wallet_and_profile(conn, user_id, request.user["name"])
    if data.get("name"):
        conn.execute("UPDATE hs_profile SET name = ? WHERE user_id = ?", (data["name"].strip(), user_id))
    if "plan" in data:
        conn.execute("UPDATE hs_profile SET plan = ? WHERE user_id = ?", (data["plan"], user_id))
    conn.commit()
    row = conn.execute("SELECT * FROM hs_profile WHERE user_id = ?", (user_id,)).fetchone()
    conn.close()
    return jsonify(hs_profile_dict(row, user_id, request.user["name"]))


@app.route("/api/hs/reset", methods=["POST"])
@require_auth
def hs_reset():
    user_id = request.user["id"]
    conn = get_db()
    conn.execute("DELETE FROM hs_bookings WHERE user_id = ?", (user_id,))
    conn.execute("DELETE FROM hs_wallet_tx WHERE user_id = ?", (user_id,))
    conn.execute("UPDATE hs_wallet SET points = 100 WHERE user_id = ?", (user_id,))
    conn.execute(
        "UPDATE hs_profile SET name = ?, plan = NULL WHERE user_id = ?",
        (request.user["name"], user_id),
    )
    conn.commit()
    conn.close()
    return jsonify({"ok": True})


if __name__ == "__main__":
    init_db()
    port = int(os.environ.get("PORT", 8420))
    print(f"RasoiCare backend running on http://127.0.0.1:{port}")
    app.run(host="0.0.0.0", port=port, debug=False)
else:
    init_db()
