"""Vision AI — technician review of an AI result (Stage C).

The AI result stored on kitchen_ai_inspections is immutable evidence and is
never modified here. A technician's decision about it lives in its own
append-only table (kitchen_ai_reviews): accept the result as is, accept it with
per-finding changes ("edit"), or reject it. Only an accepted/edited decision on
a valid completed result can make an AI score eligible for the combined health
score, and only as the server recomputes it; nothing the client sends is ever
used as a score.

Rules enforced here:
- decisions are keyed to findings the AI actually returned (by code); the
  technician cannot add a finding, only confirm, reject or lower/raise the
  severity of an existing one within the allowed severity set;
- free-text notes pass the same untrusted-text / prohibited-claim scan as AI
  output;
- the score is recomputed server-side from the confirmed findings with the
  same fixed penalties as the original result;
- rejected and unreviewed findings never count as confirmed facts.
"""
import hashlib
import json

import database
import vision_guardrails as vg

ACCEPT, EDIT, REJECT = "accept", "edit", "reject"
DECISIONS = (ACCEPT, EDIT, REJECT)
CONFIRM, DROP = "confirm", "reject"
MAX_NOTE = 300
MAX_REVISIONS = 10


class ReviewError(Exception):
    def __init__(self, status, code, message, fields=None):
        super().__init__(message)
        self.status, self.code, self.message, self.fields = status, code, message, fields


def result_hash(result_json):
    return hashlib.sha256((result_json or "").encode("utf-8")).hexdigest()


def _clean_text(value, field):
    if value is None or value == "":
        return ""
    if not isinstance(value, str):
        raise ReviewError(400, "invalid_review", f"{field} must be text.", {field: "must be text"})
    text = vg.normalise_text(value)
    if len(text) > MAX_NOTE:
        raise ReviewError(400, "invalid_review", f"{field} is too long.", {field: f"at most {MAX_NOTE} characters"})
    if vg.scan_text(text):
        raise ReviewError(400, "note_rejected",
                          f"{field} contains text that is not allowed (hidden-fault claims, links or instructions).",
                          {field: "not allowed"})
    return text


def _load_result(inspection):
    """The immutable stored result of a completed inspection, or a ReviewError."""
    if inspection["status"] != "completed" or not inspection["result_json"]:
        raise ReviewError(409, "not_reviewable", "Only a completed analysis with a result can be reviewed.")
    try:
        result = json.loads(inspection["result_json"])
    except ValueError:
        raise ReviewError(409, "not_reviewable", "This analysis has no readable result.")
    if not isinstance(result, dict) or not isinstance(result.get("findings"), list):
        raise ReviewError(409, "not_reviewable", "This analysis has no readable result.")
    return result


def validate_decision(inspection, body):
    """Validates a review request against the stored result. Returns
    (decision, finding_decisions, reason, reviewed_score)."""
    result = _load_result(inspection)
    decision = body.get("decision")
    if decision not in DECISIONS:
        raise ReviewError(400, "invalid_review", "decision must be accept, edit or reject.",
                          {"decision": "must be accept, edit or reject"})
    reason = _clean_text(body.get("reason"), "reason")
    originals = {f["code"]: f for f in result["findings"] if isinstance(f, dict) and "code" in f}
    score = result.get("conditionScore")
    has_score = isinstance(score, int) and not isinstance(score, bool) and result.get("visibility") != "insufficient"

    if decision == REJECT:
        if body.get("findings"):
            raise ReviewError(400, "invalid_review", "A rejection does not take per-finding decisions.")
        return decision, [{"code": c, "decision": DROP, "severity": f["severity"], "note": ""}
                          for c, f in originals.items()], reason, None

    if not has_score:
        raise ReviewError(409, "nothing_to_accept",
                          "This analysis has no score to accept (the photos were not clear enough). "
                          "Reject it and retake the photos.")
    if decision == ACCEPT:
        if body.get("findings"):
            raise ReviewError(400, "invalid_review", "Use decision 'edit' to change individual findings.")
        return decision, [{"code": c, "decision": CONFIRM, "severity": f["severity"], "note": ""}
                          for c, f in originals.items()], reason, score

    # EDIT
    items = body.get("findings")
    if not isinstance(items, list) or not items:
        raise ReviewError(400, "invalid_review", "findings are required for an edit.",
                          {"findings": "required"})
    seen, out = set(), []
    for item in items:
        if not isinstance(item, dict):
            raise ReviewError(400, "invalid_review", "Each finding decision must be an object.")
        code = item.get("code")
        if code not in originals:
            raise ReviewError(400, "unknown_finding", "A decision refers to a finding this analysis does not have.")
        if code in seen:
            raise ReviewError(400, "duplicate_finding", "A finding was decided more than once.")
        seen.add(code)
        verdict = item.get("decision")
        if verdict not in (CONFIRM, DROP):
            raise ReviewError(400, "invalid_review", "Each finding needs a decision of confirm or reject.")
        severity = item.get("severity", originals[code]["severity"])
        if severity not in vg.SEVERITIES:
            raise ReviewError(400, "invalid_review", "severity must be one of: " + ", ".join(vg.SEVERITIES))
        out.append({"code": code, "decision": verdict, "severity": severity,
                    "note": _clean_text(item.get("note"), "note")})
    if seen != set(originals):
        raise ReviewError(400, "incomplete_review", "Every finding in the analysis needs a decision.")
    confirmed = [f for f in out if f["decision"] == CONFIRM]
    if not confirmed:
        raise ReviewError(400, "invalid_review",
                          "All findings were rejected; use decision 'reject' to reject the analysis.")
    return decision, out, reason, vg.condition_score(confirmed)


def serialise(row):
    return {
        "id": row["id"],
        "inspectionId": row["inspection_id"],
        "revision": row["revision"],
        "decision": row["decision"],
        "findings": json.loads(row["finding_decisions"] or "[]"),
        "reason": row["reason"],
        "reviewedScore": row["reviewed_score"],
        "technicianId": row["technician_id"],
        "reviewedAt": row["created_at"],
    }


def latest_review(conn, inspection_id):
    return conn.execute(
        "SELECT * FROM kitchen_ai_reviews WHERE inspection_id = ? ORDER BY revision DESC LIMIT 1",
        (inspection_id,)).fetchone()


def find_by_request_id(conn, technician_id, client_request_id):
    return conn.execute(
        "SELECT * FROM kitchen_ai_reviews WHERE technician_id = ? AND client_request_id = ?",
        (technician_id, client_request_id)).fetchone()


def create_review(conn, inspection, technician_id, body, client_request_id):
    """Records a decision. Returns (review row, created). A repeat of the same
    clientRequestId returns the original row and writes nothing."""
    replay = find_by_request_id(conn, technician_id, client_request_id)
    if replay:
        if replay["inspection_id"] != inspection["id"]:
            raise ReviewError(409, "request_id_reused", "This request id was already used for a different review.")
        return replay, False
    decision, findings, reason, score = validate_decision(inspection, body)
    current = latest_review(conn, inspection["id"])
    revision = (current["revision"] if current else 0) + 1
    if revision > MAX_REVISIONS:
        raise ReviewError(409, "revision_limit", "This analysis has been reviewed too many times.")
    review_id = database.new_uuid_id("KAR")
    cur = conn.execute(
        "INSERT INTO kitchen_ai_reviews (id, inspection_id, appliance_id, booking_id, technician_id, revision, "
        "decision, client_request_id, finding_decisions, reason, reviewed_score, result_sha256, created_at) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT DO NOTHING",
        (review_id, inspection["id"], inspection["appliance_id"], inspection["booking_id"], technician_id,
         revision, decision, client_request_id, json.dumps(findings), reason, score,
         result_hash(inspection["result_json"]), database.now()))
    conn.commit()
    if cur.rowcount != 1:
        raced = find_by_request_id(conn, technician_id, client_request_id)
        if raced and raced["inspection_id"] == inspection["id"]:
            return raced, False
        raise ReviewError(409, "review_conflict", "This analysis was reviewed at the same time. Reload and try again.")
    return conn.execute("SELECT * FROM kitchen_ai_reviews WHERE id = ?", (review_id,)).fetchone(), True


def effective_for_health(conn, appliance_id, booking_id):
    """The review whose AI score may feed the combined health score for this
    appliance on this visit, or None.

    Only the NEWEST completed analysis of the visit is considered: an older
    accepted analysis does not keep counting once a newer one exists. Its
    latest decision must be accept/edit with a score, and the stored result
    must still hash to what was reviewed."""
    inspection = conn.execute(
        "SELECT * FROM kitchen_ai_inspections WHERE appliance_id = ? AND booking_id = ? AND status = 'completed' "
        "AND result_json IS NOT NULL ORDER BY completed_at DESC, created_at DESC, id DESC LIMIT 1",
        (appliance_id, booking_id)).fetchone()
    if not inspection:
        return None
    review = latest_review(conn, inspection["id"])
    if not review or review["decision"] not in (ACCEPT, EDIT):
        return None
    score = review["reviewed_score"]
    if isinstance(score, bool) or not isinstance(score, int) or not 0 <= score <= 100:
        return None
    if review["result_sha256"] != result_hash(inspection["result_json"]):
        return None
    findings = json.loads(review["finding_decisions"] or "[]")
    confirmed = [f for f in findings if f.get("decision") == CONFIRM]
    try:
        result = json.loads(inspection["result_json"])
        labels = {f["code"]: f.get("label") for f in result["findings"]}
        safety = {f["code"] for f in result["findings"] if f.get("safetyRelevant")}
    except (ValueError, KeyError, TypeError):
        return None
    return {
        "inspectionId": inspection["id"], "reviewId": review["id"], "decision": review["decision"],
        "aiScore": score, "reviewedAt": review["created_at"],
        "confirmedFindings": len(confirmed),
        "confirmedSafetyFindings": [labels.get(f["code"]) or f["code"] for f in confirmed if f["code"] in safety],
    }
