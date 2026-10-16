"""Vision AI — job state, background worker, recovery and limits (Stage A).

Design, in one paragraph: a submission becomes a row in kitchen_ai_inspections
(the source of truth) and is handed to a small in-process daemon worker. The
row records which process owns it (`worker_id`) and when that process last
proved it was alive (`heartbeat_at`). Every state change after submission is a
conditional UPDATE that includes the owner and the expected status, so a stale
or superseded worker can never overwrite a newer state. A job whose owner
stops heartbeating is marked failed + retryable ('interrupted') by a
staleness sweep that runs lazily on requests and periodically from the keeper
thread. Images are held in memory only, so a job that dies with its process
cannot be resumed — the technician resubmits the photos; we never pretend a
job resumed. See docs/VISION_AI.md.

Everything off the request thread uses database.db_session_unpooled(): the
shared Postgres pool is not thread-safe.
"""
import json
import logging
import os
import queue
import random
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone

import database
import vision_guardrails as vg
import vision_provider as vp
from vision_provider import ProviderPermanentError, ProviderTransientError, VisionRequest

log = logging.getLogger("vision_ai")

# Identifies this process as the owner of the jobs it creates. A new process
# (restart, new deploy instance) has a different id, so it can tell its own
# jobs from another live instance's during an overlapping deploy.
WORKER_ID = uuid.uuid4().hex

QUEUED, RUNNING, COMPLETED, FAILED, REJECTED = "queued", "running", "completed", "failed", "rejected"
ACTIVE = (QUEUED, RUNNING)

INTERRUPTED_MESSAGE = ("The analysis was interrupted before it finished (the server restarted or "
                       "timed out). Please resubmit the photos.")
BUSY_MESSAGE = "The AI service is busy. Please try again in a moment."


def _env_int(name, default):
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


def _env_float(name, default):
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return default


# Read at call time so deployments (and tests) can change them.
def max_submissions_per_visit():
    return _env_int("VISION_AI_MAX_SUBMISSIONS_PER_VISIT", 3)       # provisional, per the agreed plan


def technician_daily_limit():
    return _env_int("VISION_AI_TECH_DAILY_LIMIT", 20)


def global_daily_limit():
    """Submissions per UTC day across all technicians; 0 = unlimited. This is
    a COUNT of analyses, not a spend cap: no provider pricing is known, so no
    monetary limit is implemented."""
    return _env_int("VISION_AI_GLOBAL_DAILY_LIMIT", 500)


def provider_timeout_seconds():
    return _env_float("VISION_AI_PROVIDER_TIMEOUT", 45.0)


def keeper_interval_seconds():
    return _env_float("VISION_AI_KEEPER_SECONDS", 30.0)


def stale_seconds():
    """How long a job may go without a heartbeat before it is declared
    interrupted. Never less than 3 keeper intervals, so a single missed beat
    cannot kill a healthy job."""
    return max(_env_float("VISION_AI_STALE_SECONDS", 120.0), 3 * keeper_interval_seconds())


def max_runtime_seconds():
    """Hard cap on one job's running time, heartbeat or not (a provider call
    that hangs must not keep a job alive forever)."""
    return max(_env_float("VISION_AI_MAX_RUNTIME_SECONDS", 180.0),
               provider_timeout_seconds() + 15.0)


MAX_PROVIDER_CALLS = 3          # retries and the single structural re-ask share this budget
BACKOFF_BASE_SECONDS = 1.0      # module attribute so tests can set it to 0
WORKER_THREADS = 2
QUEUE_MAX = 6
BREAKER_THRESHOLD = 5
BREAKER_OPEN_SECONDS = 300


def _iso(dt):
    return dt.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _ago(seconds):
    return _iso(datetime.now(timezone.utc) - timedelta(seconds=seconds))


def _day_start():
    d = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    return _iso(d)


# ------------------------------------------------------------ circuit breaker
class _Breaker:
    """Opens after BREAKER_THRESHOLD consecutive provider failures so a dead
    or misconfigured provider is not hammered. In-process, like the app's
    other rate state; a restart closes it."""

    def __init__(self):
        self.lock = threading.Lock()
        self.failures = 0
        self.open_until = 0.0

    def record_failure(self):
        with self.lock:
            self.failures += 1
            if self.failures >= BREAKER_THRESHOLD:
                self.open_until = time.monotonic() + BREAKER_OPEN_SECONDS

    def record_success(self):
        with self.lock:
            self.failures = 0
            self.open_until = 0.0

    def is_open(self):
        with self.lock:
            if self.open_until and time.monotonic() < self.open_until:
                return True
            if self.open_until:
                self.open_until, self.failures = 0.0, 0
            return False


breaker = _Breaker()


# ----------------------------------------------------------------- SQL bits
# A submission only counts toward the limits if it could have cost something:
# a job that failed before any provider call (interrupted by a restart, or
# turned away as busy) is free for the technician.
_COUNTED = "NOT (status = 'failed' AND provider_called = 0 AND error_code IN ('interrupted', 'busy'))"

_SUBMIT_LOCK_KEY = 1447449929   # arbitrary constant; "VISI" — only Vision AI submissions use it

_INSERT_COLS = ("id, appliance_id, booking_id, technician_id, status, client_request_id, worker_id, "
                "heartbeat_at, image_count, image_hashes, created_at, updated_at")


class SubmitError(Exception):
    def __init__(self, http_status, code, message):
        super().__init__(message)
        self.http_status = http_status
        self.code = code
        self.message = message


def _count(conn, where, params):
    return conn.execute(
        f"SELECT COUNT(*) AS n FROM kitchen_ai_inspections WHERE {where} AND {_COUNTED}", params
    ).fetchone()["n"]


def _limit_error(conn, appliance_id, booking_id, technician_id):
    """Which limit (if any) a new submission would currently break."""
    if _count(conn, "appliance_id = ? AND booking_id = ?", (appliance_id, booking_id)) \
            >= max_submissions_per_visit():
        return SubmitError(429, "visit_limit_reached",
                           f"At most {max_submissions_per_visit()} AI analyses are allowed per appliance per visit.")
    if _count(conn, "technician_id = ? AND created_at >= ?", (technician_id, _day_start())) \
            >= technician_daily_limit():
        return SubmitError(429, "daily_limit_reached", "You have reached today's AI analysis limit.")
    g = global_daily_limit()
    if g and _count(conn, "created_at >= ?", (_day_start(),)) >= g:
        return SubmitError(429, "global_limit_reached", "The daily AI analysis limit has been reached.")
    return None


def find_by_request_id(conn, technician_id, client_request_id):
    if not client_request_id:
        return None
    return conn.execute(
        "SELECT * FROM kitchen_ai_inspections WHERE technician_id = ? AND client_request_id = ?",
        (technician_id, client_request_id),
    ).fetchone()


def create_job(conn, *, appliance_id, booking_id, technician_id, client_request_id, image_hashes):
    """Creates a queued job owned by this process. Returns (row, created).

    Duplicate submissions (same technician + clientRequestId) return the
    original job. The visit / daily / global limits are enforced INSIDE the
    INSERT (INSERT … SELECT … WHERE counts < limits), so two requests cannot
    both slip past a separate count-then-insert check on one database.
    On Postgres the whole count-and-insert additionally runs under an advisory
    lock (see below), so the limits also hold across overlapping instances."""
    existing = find_by_request_id(conn, technician_id, client_request_id)
    if existing:
        if existing["appliance_id"] != appliance_id or existing["booking_id"] != booking_id:
            raise SubmitError(409, "request_id_reused", "This request id was already used for a different inspection.")
        return existing, False

    if database.DATABASE_URL:
        # Postgres runs READ COMMITTED: without this, two overlapping
        # transactions (two instances during a deploy) both count the same rows
        # and both insert, exceeding a limit. A transaction-scoped advisory
        # lock makes the count-and-insert below one-at-a-time across every
        # connection; it is released automatically at commit/rollback. SQLite
        # needs nothing: its single writer lock already serialises the insert.
        conn.execute("SELECT pg_advisory_xact_lock(?)", (_SUBMIT_LOCK_KEY,))

    job_id = database.new_uuid_id("KAI")
    stamp = database.now()
    visit_count = ("SELECT COUNT(*) FROM kitchen_ai_inspections WHERE appliance_id = ? AND booking_id = ? AND "
                   + _COUNTED)
    tech_count = ("SELECT COUNT(*) FROM kitchen_ai_inspections WHERE technician_id = ? AND created_at >= ? AND "
                  + _COUNTED)
    global_count = "SELECT COUNT(*) FROM kitchen_ai_inspections WHERE created_at >= ? AND " + _COUNTED
    day = _day_start()
    cur = conn.execute(
        f"INSERT INTO kitchen_ai_inspections ({_INSERT_COLS}) "
        "SELECT ?,?,?,?,?,?,?,?,?,?,?,? "
        f"WHERE ({visit_count}) < ? AND ({tech_count}) < ? AND (? = 0 OR ({global_count}) < ?) "
        "ON CONFLICT DO NOTHING",
        (job_id, appliance_id, booking_id, technician_id, QUEUED, client_request_id or "", WORKER_ID,
         stamp, len(image_hashes), json.dumps(image_hashes), stamp, stamp,
         appliance_id, booking_id, max_submissions_per_visit(),
         technician_id, day, technician_daily_limit(),
         global_daily_limit(), day, global_daily_limit()),
    )
    created = cur.rowcount == 1
    conn.commit()
    if created:
        return conn.execute("SELECT * FROM kitchen_ai_inspections WHERE id = ?", (job_id,)).fetchone(), True
    raced = find_by_request_id(conn, technician_id, client_request_id)
    if raced:
        return raced, False
    raise _limit_error(conn, appliance_id, booking_id, technician_id) or SubmitError(
        429, "limit_reached", "An AI analysis limit has been reached.")


# ------------------------------------------------------------------- sweep
def sweep_stale(conn):
    """Fails jobs whose owner has stopped heartbeating (process gone) and
    running jobs that exceeded the hard runtime cap. Safe to run from any
    process at any time: it only touches rows that are provably dead, and
    live owners keep their heartbeat fresh. Returns the number of jobs failed."""
    stamp = database.now()
    n = conn.execute(
        "UPDATE kitchen_ai_inspections SET status = 'failed', error_code = 'interrupted', "
        "error_message = ?, retryable = 1, completed_at = ?, updated_at = ? "
        "WHERE status IN ('queued', 'running') AND heartbeat_at < ?",
        (INTERRUPTED_MESSAGE, stamp, stamp, _ago(stale_seconds())),
    ).rowcount
    n += conn.execute(
        "UPDATE kitchen_ai_inspections SET status = 'failed', error_code = 'timeout', "
        "error_message = ?, retryable = 1, completed_at = ?, updated_at = ? "
        "WHERE status = 'running' AND started_at < ?",
        ("The analysis took too long and was stopped. Please try again.", stamp, stamp,
         _ago(max_runtime_seconds())),
    ).rowcount
    # A job that was never started (its owner is alive and heartbeating, but
    # the worker never picked it up) must not wait forever either. No provider
    # call was made, so it stays free for the technician.
    n += conn.execute(
        "UPDATE kitchen_ai_inspections SET status = 'failed', error_code = 'interrupted', "
        "error_message = ?, retryable = 1, completed_at = ?, updated_at = ? "
        "WHERE status = 'queued' AND created_at < ?",
        (INTERRUPTED_MESSAGE, stamp, stamp, _ago(max_runtime_seconds())),
    ).rowcount
    conn.commit()
    return n


# ------------------------------------------------------- conditional updates
def _owned_update(job_id, sets, params, expect=RUNNING):
    """UPDATE this job only if THIS process still owns it in `expect` state.
    Returns True if the row changed. A superseded worker gets False and must
    discard its result."""
    stamp = database.now()
    with database.db_session_unpooled() as conn:
        return conn.execute(
            f"UPDATE kitchen_ai_inspections SET {sets}, updated_at = ?, heartbeat_at = ? "
            "WHERE id = ? AND worker_id = ? AND status = ?",
            (*params, stamp, stamp, job_id, WORKER_ID, expect),
        ).rowcount == 1


def _claim(job_id):
    stamp = database.now()
    return _owned_update(job_id, "status = 'running', started_at = ?", (stamp,), expect=QUEUED)


def is_simulated(row):
    """Whether an inspection row came from a simulated provider. The persisted
    marker is authoritative; the recorded provider/model name is a second line
    of defence for rows written before the marker existed."""
    keys = row.keys()
    return bool(
        ("simulated" in keys and row["simulated"])
        or (row["provider"] or "") == "fake"
        or (row["model"] or "").startswith("fake")
    )


def _mark_call(job_id, provider):
    return _owned_update(
        job_id, "provider_called = 1, attempts = attempts + 1, provider = ?, model = ?, simulated = ?",
        (provider.name, provider.model, 1 if getattr(provider, "simulated", False) else 0))


def _fail(job_id, code, message, retryable, status=FAILED, expect=RUNNING):
    return _owned_update(
        job_id, "status = ?, error_code = ?, error_message = ?, retryable = ?, completed_at = ?",
        (status, code, message, 1 if retryable else 0, database.now()), expect=expect)


# ------------------------------------------------------------------- worker
def run_job(job_id, ctx):
    """Runs one analysis to a terminal state. `ctx` holds the in-memory
    inputs (never persisted): category, applianceId, bookingId, images (JPEG
    bytes), technician checks by label. All provider output is untrusted."""
    try:
        if not _claim(job_id):
            return  # swept (or never ours) — nothing to do
        provider = vp.get_provider()
        if provider is None:
            _fail(job_id, "ai_unavailable", "AI inspection is not available right now.", True)
            return
        _analyse(job_id, ctx, provider)
    except Exception as e:  # never leak internals; never leave a job 'queued' or 'running'
        # Only the exception CLASS is logged: messages can carry request
        # details, keys or content.
        log.error("vision job %s crashed (%s)", job_id, type(e).__name__)
        for state in (RUNNING, QUEUED):
            try:
                if _fail(job_id, "internal_error", "The analysis failed unexpectedly. Please try again.",
                         True, expect=state):
                    break
            except Exception as inner:
                log.error("vision job %s could not be marked failed (%s)", job_id, type(inner).__name__)
    finally:
        ctx["images"] = None  # drop the photo bytes as soon as the job ends


def _analyse(job_id, ctx, provider):
    category = ctx["category"]
    request = VisionRequest(
        category=category, images=ctx["images"], prompt=vg.build_prompt(category),
        schema=vg.RESPONSE_SCHEMA, technician_checks=ctx["technician_checks"],
        timeout_seconds=provider_timeout_seconds())
    structural_retry_used = False
    calls = 0
    while calls < MAX_PROVIDER_CALLS:
        if not _mark_call(job_id, provider):
            return  # ownership lost: discard
        calls += 1
        try:
            raw = provider.analyze(request)
        except ProviderTransientError:
            breaker.record_failure()
            if calls < MAX_PROVIDER_CALLS:
                delay = BACKOFF_BASE_SECONDS * (2 ** (calls - 1))
                time.sleep(delay + random.uniform(0, 0.25 * delay))
                continue
            _fail(job_id, "provider_unavailable",
                  "The AI service did not respond. Please try again later.", True)
            return
        except ProviderPermanentError:
            breaker.record_failure()
            _fail(job_id, "provider_rejected",
                  "The AI service rejected the request. Please contact support.", False)
            return
        except Exception as e:
            breaker.record_failure()
            log.error("vision provider failed for job %s (%s)", job_id, type(e).__name__)
            _fail(job_id, "provider_error", "The AI service failed. Please try again later.", True)
            return
        breaker.record_success()

        try:
            validated = vg.validate_provider_response(category, len(request.images), raw)
        except vg.StructuralError:
            if not structural_retry_used and calls < MAX_PROVIDER_CALLS:
                structural_retry_used = True  # ask once more
                continue
            _fail(job_id, "invalid_response", "The AI service returned an unusable answer. Please try again.", True)
            return
        except vg.GuardrailViolation as violation:
            _fail(job_id, violation.code, violation.message, True, status=REJECTED)
            return
        _complete(job_id, ctx, provider, validated)
        return
    _fail(job_id, "invalid_response", "The AI service returned an unusable answer. Please try again.", True)


def _complete(job_id, ctx, provider, validated):
    with database.db_session_unpooled() as conn:
        rows = conn.execute(
            "SELECT check_key, result FROM kitchen_inspection_checks WHERE appliance_id = ? AND booking_id = ?",
            (ctx["applianceId"], ctx["bookingId"]),
        ).fetchall()
        technician_results = {r["check_key"]: r["result"] for r in rows}
        result = vg.build_result(ctx["category"], validated, len(ctx["images"]), technician_results)
        stamp = database.now()
        changed = conn.execute(
            "UPDATE kitchen_ai_inspections SET status = 'completed', result_json = ?, condition_score = ?, "
            "retryable = 0, error_code = '', error_message = '', provider = ?, model = ?, simulated = ?, "
            "completed_at = ?, updated_at = ?, heartbeat_at = ? "
            "WHERE id = ? AND worker_id = ? AND status = 'running'",
            (json.dumps(result), result["conditionScore"], provider.name, provider.model,
             1 if getattr(provider, "simulated", False) else 0,
             stamp, stamp, stamp, job_id, WORKER_ID),
        ).rowcount
    if changed != 1:
        log.warning("vision job %s finished after losing ownership; result discarded", job_id)


# ------------------------------------------------------- queue and threads
_queue = queue.Queue(maxsize=QUEUE_MAX)
_start_lock = threading.Lock()
_started = False
_inline = False
_active = 0
_active_lock = threading.Lock()


def queue_has_room():
    return _inline or not _queue.full()


def _worker_loop():
    global _active
    while True:
        job_id, ctx = _queue.get()
        try:
            with _active_lock:
                _active += 1
            run_job(job_id, ctx)
        finally:
            with _active_lock:
                _active -= 1
            _queue.task_done()


def keeper_once():
    """One keeper iteration: refresh the heartbeat of every job this process
    owns (except any past the hard runtime cap), then sweep dead jobs."""
    stamp = database.now()
    with database.db_session_unpooled() as conn:
        conn.execute(
            "UPDATE kitchen_ai_inspections SET heartbeat_at = ? "
            "WHERE worker_id = ? AND ((status = 'queued' AND created_at >= ?) "
            "OR (status = 'running' AND started_at >= ?))",
            (stamp, WORKER_ID, _ago(max_runtime_seconds()), _ago(max_runtime_seconds())))
        sweep_stale(conn)


def _keeper_loop():
    """Heartbeats the jobs this process owns and sweeps dead ones. A job past
    its hard runtime cap is NOT heartbeated, so a hung provider call cannot
    keep itself alive."""
    while True:
        time.sleep(keeper_interval_seconds())
        try:
            keeper_once()
        except Exception as e:
            log.error("vision keeper iteration failed (%s)", type(e).__name__)


def _ensure_threads():
    global _started
    with _start_lock:
        if _started:
            return
        for i in range(WORKER_THREADS):
            threading.Thread(target=_worker_loop, name=f"vision-worker-{i}", daemon=True).start()
        threading.Thread(target=_keeper_loop, name="vision-keeper", daemon=True).start()
        _started = True


def enqueue(job_id, ctx):
    """Hands a job to the worker. Returns False if the queue is full."""
    if _inline:
        run_job(job_id, ctx)
        return True
    _ensure_threads()
    try:
        _queue.put_nowait((job_id, ctx))
        return True
    except queue.Full:
        return False


def mark_busy(job_id):
    """The queue was full after the row was created: fail it as 'busy'
    (free for the technician — no provider call was made)."""
    _fail_unowned_ok(job_id)


def _fail_unowned_ok(job_id):
    stamp = database.now()
    with database.db_session_unpooled() as conn:
        conn.execute(
            "UPDATE kitchen_ai_inspections SET status = 'failed', error_code = 'busy', error_message = ?, "
            "retryable = 1, completed_at = ?, updated_at = ? "
            "WHERE id = ? AND worker_id = ? AND status = 'queued'",
            (BUSY_MESSAGE, stamp, stamp, job_id, WORKER_ID))


def wait_idle(timeout=10.0):
    """Test helper: block until the queue is drained and no job is running."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with _active_lock:
            idle = _active == 0
        if idle and _queue.empty():
            return True
        time.sleep(0.01)
    return False


def reset_for_tests(inline=True, clear_provider=True):
    """Test helper: clear in-process state. inline=True runs jobs on the
    calling thread (deterministic); inline=False uses the real worker."""
    global _inline
    wait_idle(5.0)
    while not _queue.empty():
        try:
            _queue.get_nowait()
            _queue.task_done()
        except queue.Empty:
            break
    _inline = inline
    breaker.record_success()
    if clear_provider:
        vp.set_provider_for_tests(None)


# ------------------------------------------------------------ serialisation
def serialise(row, *, include_result=True):
    """API shape of a job row. Never contains image data (none is stored)."""
    result = None
    if include_result and row["status"] == COMPLETED and row["result_json"]:
        result = json.loads(row["result_json"])
        result.update({
            "inspectionId": row["id"], "applianceId": row["appliance_id"], "bookingId": row["booking_id"],
            "model": row["model"], "analyzedAt": row["completed_at"],
            # From the persisted row, so it cannot be changed through the stored
            # result or any request field.
            "simulated": is_simulated(row),
        })
    error = None
    if row["status"] in (FAILED, REJECTED):
        error = {"code": row["error_code"], "message": row["error_message"]}
    return {
        "id": row["id"],
        "applianceId": row["appliance_id"],
        "bookingId": row["booking_id"],
        "status": row["status"],
        "retryable": bool(row["retryable"]),
        "attempts": row["attempts"],
        "imageCount": row["image_count"],
        "simulated": is_simulated(row),
        "createdAt": row["created_at"],
        "startedAt": row["started_at"],
        "completedAt": row["completed_at"],
        "error": error,
        "result": result,
    }
