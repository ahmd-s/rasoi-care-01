"""Kitchen Passport V9.7 — technician-assessed health scores.

Pure functions (no Flask, no database): everything is computed on read from
the saved inspection checklist answers (kitchen_inspection_checks), so a score
can never go stale or disagree with the answers behind it.

Rules (agreed for this slice):
- good = 100, attention = 40, equally weighted. not_tested is excluded from the
  average — it is never treated as "not applicable" and never as a pass.
- At least MIN_TESTED of the checklist's items must be tested (good/attention)
  before a score is produced; otherwise there is no number at all.
- Status bands (inclusive): Healthy 85-100, Attention 70-84, Priority 50-69,
  Critical 0-49.
- A flagged (attention) safety item keeps the *status* from being Healthy
  (held at Attention) but never changes the calculated score.
- The AI visual score does not exist yet: aiScore and combinedScore are null.
  combined_score() implements the documented 70/30 blend and only returns a
  value when both scores are genuinely available.

Scores are operational guidance, not a certification.
"""
from kitchen_passport import CHECKLISTS

POINTS = {"good": 100, "attention": 40}
MIN_TESTED = 6

# Checklist items where an "attention" result is a safety concern. Gas flow is
# included because a gas fault is a safety fault, not just a performance one.
SAFETY_ITEMS = frozenset({"safety", "electrical_safety", "electrical_and_safety", "gas_flow"})

STATUS_LABELS = {
    "healthy": "Healthy",
    "attention": "Attention",
    "priority": "Priority",
    "critical": "Critical",
}
_RANK = {"critical": 0, "priority": 1, "attention": 2, "healthy": 3}

BASIS = "technician_only"
BASIS_LABEL = "Technician assessment only"
AI_UNAVAILABLE = {"available": False, "reason": "vision_ai_not_available"}
DISCLAIMER = "Operational guidance, not a certification or a diagnosis of hidden faults."
SAFETY_WARNING = "Safety item flagged"
NOT_ENOUGH_CHECKS = "Not enough checks to score."


def status_for_score(score):
    if score >= 85:
        return "healthy"
    if score >= 70:
        return "attention"
    if score >= 50:
        return "priority"
    return "critical"


def _half_up_average(total, n):
    """round-half-up(total / n) in exact integer arithmetic."""
    return (2 * total + n) // (2 * n)


def combined_score(technician_score, ai_score):
    """The documented blend, 70% technician + 30% AI visual, rounded half up.
    None unless BOTH scores are real numbers in 0-100: a missing AI score is
    never replaced by zero, by the technician score, or by a default."""
    for value in (technician_score, ai_score):
        if value is None or isinstance(value, bool) or not isinstance(value, (int, float)):
            return None
        if value < 0 or value > 100:
            return None
    # (7t + 3a) / 10, exact via integers when both are whole numbers.
    if isinstance(technician_score, int) and isinstance(ai_score, int):
        return (2 * (7 * technician_score + 3 * ai_score) + 10) // 20
    return int(0.7 * technician_score + 0.3 * ai_score + 0.5)


def _cap_for_safety(status, safety_flagged):
    if safety_flagged and status == "healthy":
        return "attention"
    return status


def _status_fields(status):
    return {"status": status, "statusLabel": STATUS_LABELS[status] if status else None}


def assess_appliance(category, saved, *, include_notes=False):
    """Assessment of one appliance for one visit.

    `saved` maps check_key -> {"result": ..., "note": ...} for the answers
    recorded on that visit. Keys that aren't on the category's current
    checklist are ignored."""
    checklist = CHECKLISTS[category]
    total = len(checklist)
    tested = flagged = 0
    points = 0
    not_tested, flagged_items, safety_items = [], [], []
    for key, label in checklist:
        entry = saved.get(key)
        result = entry["result"] if entry else None
        if result in POINTS:
            tested += 1
            points += POINTS[result]
        elif result == "not_tested":
            not_tested.append(label)
        if result == "attention":
            flagged += 1
            item = {"key": key, "label": label}
            if include_notes:
                item["note"] = (entry.get("note") or "")
            flagged_items.append(item)
            if key in SAFETY_ITEMS:
                safety_items.append(label)

    safety_flagged = bool(safety_items)
    scored = tested >= MIN_TESTED
    score = _half_up_average(points, tested) if scored else None
    score_status = status_for_score(score) if scored else None
    status = _cap_for_safety(score_status, safety_flagged) if scored else None

    explanation = [f"{BASIS_LABEL}. Vision AI inspection is not available yet."]
    if scored:
        line = f"Based on {tested} of {total} checks."
        if total - tested:
            line += f" {total - tested} not tested (not counted in the score)."
        explanation.append(line)
    else:
        explanation.append(
            f"Only {tested} of {total} checks tested; at least {MIN_TESTED} are needed to score.")
    if flagged_items:
        explanation.append("Needs attention: " + ", ".join(i["label"] for i in flagged_items) + ".")
    if safety_flagged:
        msg = f"{SAFETY_WARNING}: " + ", ".join(safety_items) + "."
        if scored and score_status == "healthy":
            msg += " Status held at Attention until it is resolved."
        explanation.append(msg)
    explanation.append(DISCLAIMER)

    return {
        "category": category,
        "coverage": {
            "tested": tested,
            "total": total,
            "label": f"{tested} of {total} checks tested",
        },
        "technicianScore": score,
        "scoreStatus": score_status,
        **_status_fields(status),
        "safetyFlagged": safety_flagged,
        "safetyWarning": SAFETY_WARNING if safety_flagged else None,
        "safetyFlaggedItems": safety_items,
        "flaggedItems": flagged_items,
        "notTestedItems": not_tested,
        "message": None if scored else NOT_ENOUGH_CHECKS,
        "explanation": explanation,
        "aiScore": None,
        "combinedScore": None,
        "ai": dict(AI_UNAVAILABLE),
        "scoreBasis": BASIS,
        "scoreBasisLabel": BASIS_LABEL,
        "disclaimer": DISCLAIMER,
    }


def latest_assessment(category, rows):
    """Picks the visit to report for one appliance from all its saved rows
    (dicts with booking_id, check_key, result, note, updated_at).

    The most recent visit that has enough checks to score wins; if none does,
    the most recent visit is reported (coverage only, no score). A safety flag
    on a *newer* partial visit still carries through, so a fresh finding is
    never hidden behind an older complete inspection.

    Returns (assessment, booking_id, assessed_at); booking_id and assessed_at
    are None when nothing has been recorded."""
    by_visit = {}
    for r in rows:
        by_visit.setdefault(r["booking_id"], []).append(r)
    visits = []
    for booking_id, items in by_visit.items():
        saved = {i["check_key"]: {"result": i["result"], "note": i["note"]} for i in items}
        assessed_at = max(i["updated_at"] for i in items)
        visits.append((assessed_at, booking_id, assess_appliance(category, saved)))
    if not visits:
        return assess_appliance(category, {}), None, None
    visits.sort(key=lambda v: (v[0], v[1]))
    newest = visits[-1]
    usable = [v for v in visits if v[2]["technicianScore"] is not None]
    chosen = usable[-1] if usable else newest
    assessment = chosen[2]
    if newest is not chosen and newest[2]["safetyFlagged"] and not assessment["safetyFlagged"]:
        assessment = dict(assessment)
        assessment["safetyFlagged"] = True
        assessment["safetyWarning"] = SAFETY_WARNING
        assessment["safetyFlaggedItems"] = newest[2]["safetyFlaggedItems"]
        if assessment["status"] == "healthy":
            assessment["status"] = "attention"
            assessment["statusLabel"] = STATUS_LABELS["attention"]
        assessment["explanation"] = list(assessment["explanation"][:-1]) + [
            f"{SAFETY_WARNING} on a more recent, incomplete visit: "
            + ", ".join(newest[2]["safetyFlaggedItems"]) + ".",
            DISCLAIMER,
        ]
    return assessment, chosen[1], chosen[0]


def summarize_kitchen(entries):
    """Kitchen-level view over a customer's registered appliances.

    `entries` is a list of dicts: {"id", "category", "brand", "model",
    "assessment", "bookingId", "assessedAt"}; bookingId is used internally
    only and is never included in the output. The kitchen score is the
    round-half-up average of the appliances that have a score; appliances
    without one are listed but never counted as zero. A flagged safety item on
    any appliance holds the kitchen status below Healthy, mirroring the
    appliance rule. No appliance assessed -> no score."""
    registered = len(entries)
    scored = [e for e in entries if e["assessment"]["technicianScore"] is not None]
    assessed = len(scored)
    score = (_half_up_average(sum(e["assessment"]["technicianScore"] for e in scored), assessed)
             if assessed else None)
    safety_ids = [e["id"] for e in entries if e["assessment"]["safetyFlagged"]]
    score_status = status_for_score(score) if score is not None else None
    status = _cap_for_safety(score_status, bool(safety_ids)) if score is not None else None

    needs_attention = [
        e["id"] for e in entries
        if e["assessment"]["safetyFlagged"]
        or (e["assessment"]["status"] is not None and e["assessment"]["status"] != "healthy")
    ]
    not_assessed = [e["id"] for e in entries if e["assessment"]["technicianScore"] is None]

    explanation = [f"{BASIS_LABEL}. Vision AI inspection is not available yet."]
    if assessed:
        explanation.append(
            f"Average of {assessed} assessed of {registered} registered appliances; "
            "appliances without enough checks are not counted.")
    elif registered:
        explanation.append("No appliance has enough checks to score yet.")
    else:
        explanation.append("No appliances are registered yet.")
    if safety_ids:
        explanation.append(f"{SAFETY_WARNING} on {len(safety_ids)} appliance(s).")
    explanation.append(DISCLAIMER)

    return {
        "registeredCount": registered,
        "assessedCount": assessed,
        "coverage": {
            "assessed": assessed,
            "registered": registered,
            "label": f"{assessed} of {registered} appliances assessed",
        },
        "technicianScore": score,
        "scoreStatus": score_status,
        **_status_fields(status),
        "safetyFlagged": bool(safety_ids),
        "safetyWarning": SAFETY_WARNING if safety_ids else None,
        "safetyFlaggedApplianceIds": safety_ids,
        "needsAttentionApplianceIds": needs_attention,
        "notAssessedApplianceIds": not_assessed,
        "message": None if assessed else (
            "No appliance has enough checks to score yet." if registered
            else "No appliances are registered yet."),
        "explanation": explanation,
        "appliances": [
            {
                "id": e["id"],
                "category": e["category"],
                "brand": e["brand"],
                "model": e["model"],
                # Deliberately no booking id: the visit behind a score may have
                # been another technician's, and booking ids are sequential.
                "assessedAt": e["assessedAt"],
                **{k: e["assessment"][k] for k in (
                    "technicianScore", "scoreStatus", "status", "statusLabel", "coverage",
                    "safetyFlagged", "safetyFlaggedItems", "message")},
                "flaggedItems": [i["label"] for i in e["assessment"]["flaggedItems"]],
            }
            for e in entries
        ],
        "aiScore": None,
        "combinedScore": None,
        "ai": dict(AI_UNAVAILABLE),
        "scoreBasis": BASIS,
        "scoreBasisLabel": BASIS_LABEL,
        "disclaimer": DISCLAIMER,
    }
