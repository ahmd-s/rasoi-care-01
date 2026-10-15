"""Kitchen Passport (V9.7) — appliance categories and registration validation.

The category ids and per-category registration fields mirror
APPLIANCE_ENGINE.md in the V9.7 package. The appliance *category* is the
appliance selector itself — there is deliberately no generic "type" field,
only attributes that are meaningful for that category (a hob's fuel, a
refrigerator's door layout, ...). The Partner app's
lib/features/passport/passport_catalog.dart carries the same table for the
registration form; tests/test_kitchen_passport.py pins the two together.
"""
import os
import re
from datetime import datetime, timezone

CATEGORIES = (
    "chimney",
    "hob",
    "microwave",
    "oven",
    "dishwasher",
    "refrigerator",
    "ro_purifier",
)

MAX_BRAND_LEN = 60


def _env_limit(name, default):
    try:
        return max(1, int(os.environ.get(name, default)))
    except ValueError:
        return default


# Caps, enforced server-side. A home kitchen has roughly one appliance per
# category, so 30 leaves room for multiples (two ovens, a second fridge) and
# for a customer who is a small commercial kitchen; 100 saved brands per
# technician is far more than anyone types by hand. Both are env-tunable like
# the repo's other limits (see _env_int in app.py).
MAX_APPLIANCES_PER_CUSTOMER = _env_limit("KITCHEN_MAX_APPLIANCES_PER_CUSTOMER", 30)
MAX_CUSTOM_BRANDS_PER_TECHNICIAN = _env_limit("KITCHEN_MAX_CUSTOM_BRANDS_PER_TECHNICIAN", 100)

# Bookings in these states are closed: reads stay allowed, writes do not.
CLOSED_BOOKING_STATUSES = ("Completed", "Cancelled")

_REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")


def serial_key(serial):
    """Identity form of a serial number: case- and whitespace-insensitive, so
    'sn 123' and 'SN123' are the same unit. '' means no serial recorded."""
    return "".join((serial or "").split()).casefold()


def _choice(*choices, required=True):
    return {"kind": "choice", "choices": tuple(choices), "required": required}


def _int(lo, hi, required=True):
    return {"kind": "int", "min": lo, "max": hi, "required": required}


# category -> {spec key -> rule}. Keys are stored as given in `specs`.
SPEC_FIELDS = {
    "chimney": {
        "mounting": _choice("wall_mounted", "island", "built_in"),
        "filter": _choice("baffle", "mesh", "carbon"),
        "width_cm": _int(30, 150),
        "suction_m3h": _int(200, 3000, required=False),
    },
    "hob": {
        "fuel": _choice("gas", "induction", "electric_radiant"),
        "burners": _int(1, 6),
    },
    "microwave": {
        "style": _choice("solo", "grill", "convection"),
        "mounting": _choice("countertop", "built_in"),
        "capacity_litres": _int(10, 60),
    },
    "oven": {
        "mounting": _choice("countertop", "built_in"),
        "capacity_litres": _int(9, 120),
        "convection": _choice("yes", "no"),
    },
    "dishwasher": {
        "installation": _choice("freestanding", "built_in", "countertop"),
        "place_settings": _int(4, 16),
    },
    "refrigerator": {
        "door_layout": _choice("single", "double", "side_by_side", "french_door"),
        "cooling": _choice("direct_cool", "frost_free"),
        "capacity_litres": _int(50, 800),
    },
    "ro_purifier": {
        "technology": _choice("ro", "ro_uv", "ro_uf", "ro_uv_uf"),
        "mounting": _choice("wall", "counter", "under_sink"),
        "tank_litres": _int(3, 30),
    },
}


def normalise_brand_name(name):
    """Collapses internal whitespace so 'Bosch  ' and 'Bosch' are one brand."""
    return " ".join((name or "").split())


def brand_key(name):
    """Case-insensitive identity used to de-duplicate custom brands."""
    return normalise_brand_name(name).casefold()


def validate_brand_name(name):
    """Returns an error string, or None when `name` is an acceptable brand."""
    if not isinstance(name, str):
        return "must be a string"
    cleaned = normalise_brand_name(name)
    if not cleaned:
        return "is required"
    if len(cleaned) > MAX_BRAND_LEN:
        return f"must be at most {MAX_BRAND_LEN} characters"
    return None


def _validate_spec(rule, value):
    if rule["kind"] == "choice":
        if not isinstance(value, str) or value not in rule["choices"]:
            return "must be one of: " + ", ".join(rule["choices"])
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        return "must be a whole number"
    if value < rule["min"] or value > rule["max"]:
        return f"must be between {rule['min']} and {rule['max']}"
    return None


def validate_registration(data):
    """Validates a registration body. Returns (clean, errors); `clean` is
    None when `errors` (field -> message) is non-empty. Unknown spec keys are
    rejected rather than silently stored."""
    errors = {}
    category = data.get("category")
    if category not in CATEGORIES:
        errors["category"] = "must be one of: " + ", ".join(CATEGORIES)
        return None, errors

    brand = data.get("brand")
    msg = validate_brand_name(brand)
    if msg:
        errors["brand"] = msg

    optional_text = {}
    for key, limit in (("model", 80), ("serialNumber", 80), ("notes", 300)):
        value = data.get(key)
        if value is None:
            optional_text[key] = ""
        elif not isinstance(value, str):
            errors[key] = "must be a string"
        elif len(value.strip()) > limit:
            errors[key] = f"must be at most {limit} characters"
        else:
            optional_text[key] = value.strip()

    install_year = data.get("installYear")
    if install_year is not None:
        this_year = datetime.now(timezone.utc).year
        if isinstance(install_year, bool) or not isinstance(install_year, int):
            errors["installYear"] = "must be a whole number"
        elif install_year < 1990 or install_year > this_year:
            errors["installYear"] = f"must be between 1990 and {this_year}"

    request_id = data.get("clientRequestId")
    if request_id is None:
        request_id = ""
    elif not isinstance(request_id, str) or not _REQUEST_ID_RE.match(request_id):
        errors["clientRequestId"] = "must be 8-64 letters, digits, '-' or '_'"

    raw_specs = data.get("specs")
    if raw_specs is None:
        raw_specs = {}
    specs = {}
    if not isinstance(raw_specs, dict):
        errors["specs"] = "must be an object"
    else:
        rules = SPEC_FIELDS[category]
        for key in raw_specs:
            if key not in rules:
                errors[f"specs.{key}"] = "is not a field for this appliance"
        for key, rule in rules.items():
            value = raw_specs.get(key)
            if value is None or value == "":
                if rule["required"]:
                    errors[f"specs.{key}"] = "is required"
                continue
            msg = _validate_spec(rule, value)
            if msg:
                errors[f"specs.{key}"] = msg
            else:
                specs[key] = value

    if errors:
        return None, errors
    return {
        "category": category,
        "brand": normalise_brand_name(brand),
        "model": optional_text["model"],
        "serial_number": optional_text["serialNumber"],
        "serial_key": serial_key(optional_text["serialNumber"]),
        "client_request_id": request_id,
        "install_year": install_year,
        "notes": optional_text["notes"],
        "specs": specs,
    }, {}


# ---------------------------------------------------------------- inspection
# Appliance-specific technician checklists (APPLIANCE_ENGINE.md). Order is the
# order shown on screen. The Partner app's inspection_catalog.dart carries the
# same keys/labels; tests/test_kitchen_passport.py pins the two together.
CHECKLISTS = {
    "chimney": (
        ("suction_performance", "Suction performance"),
        ("filter_condition", "Filter condition"),
        ("grease_and_dirt", "Grease and dirt"),
        ("motor_condition", "Motor condition"),
        ("controls_and_lights", "Controls and lights"),
        ("duct_and_airflow", "Duct and airflow"),
        ("physical_condition", "Physical condition"),
        ("safety", "Safety"),
    ),
    "hob": (
        ("burner_performance", "Burner performance"),
        ("ignition", "Ignition"),
        ("gas_flow", "Gas flow"),
        ("burner_and_cap_condition", "Burner and cap condition"),
        ("pan_support", "Pan support"),
        ("glass_surface", "Glass / surface"),
        ("knobs_and_controls", "Knobs and controls"),
        ("safety", "Safety"),
    ),
    "microwave": (
        ("heating_performance", "Heating performance"),
        ("power_operation", "Power / operation"),
        ("door_and_seal", "Door and seal"),
        ("turntable", "Turntable"),
        ("controls_display", "Controls / display"),
        ("interior_condition", "Interior condition"),
        ("noise_vibration", "Noise / vibration"),
        ("electrical_safety", "Electrical safety"),
    ),
    "oven": (
        ("heating_performance", "Heating performance"),
        ("temperature_control", "Temperature control"),
        ("heating_elements", "Heating elements"),
        ("door_and_seal", "Door and seal"),
        ("controls_timer", "Controls / timer"),
        ("interior_condition", "Interior condition"),
        ("fan_convection", "Fan / convection"),
        ("electrical_safety", "Electrical safety"),
    ),
    "dishwasher": (
        ("cleaning_performance", "Cleaning performance"),
        ("water_inlet", "Water inlet"),
        ("drainage", "Drainage"),
        ("spray_arms", "Spray arms"),
        ("filter_condition", "Filter condition"),
        ("door_and_seal", "Door and seal"),
        ("noise_vibration", "Noise / vibration"),
        ("electrical_safety", "Electrical safety"),
    ),
    "refrigerator": (
        ("cooling_performance", "Cooling performance"),
        ("compressor", "Compressor"),
        ("door_seal", "Door seal"),
        ("frost_ice_condition", "Frost / ice condition"),
        ("drainage", "Drainage"),
        ("interior_condition", "Interior condition"),
        ("fan_airflow", "Fan / airflow"),
        ("electrical_safety", "Electrical safety"),
    ),
    "ro_purifier": (
        ("purification_tds_performance", "Purification / TDS performance"),
        ("ro_membrane_condition", "RO membrane condition"),
        ("pre_filter_sediment", "Pre-filter / sediment filter"),
        ("carbon_filter_condition", "Carbon filter condition"),
        ("water_leakage", "Water leakage"),
        ("storage_tank_float", "Storage tank / float"),
        ("pump_flow_condition", "Pump / flow condition"),
        ("electrical_and_safety", "Electrical and safety"),
    ),
}

# Technician-observed outcomes only. "not_tested" is explicit so a skipped
# item is never mistaken for a passed one.
INSPECTION_RESULTS = ("good", "attention", "not_tested")
MAX_INSPECTION_NOTE_LEN = 300


def validate_inspection(category, data):
    """Validates a PUT body {"results": [{"key", "result", "note"?}, ...]}.
    Returns (rows, errors) where rows is [(key, result, note)]. Partial
    saves are allowed (progress on a few items); every key must belong to
    this category's checklist and appear at most once."""
    errors = {}
    items = data.get("results") if isinstance(data, dict) else None
    if not isinstance(items, list) or not items:
        return None, {"results": "must be a non-empty list"}
    valid_keys = {k for k, _ in CHECKLISTS[category]}
    if len(items) > len(valid_keys):
        return None, {"results": f"must have at most {len(valid_keys)} items"}
    rows, seen = [], set()
    for i, item in enumerate(items):
        where = f"results[{i}]"
        if not isinstance(item, dict):
            errors[where] = "must be an object"
            continue
        key = item.get("key")
        if key not in valid_keys:
            errors[f"{where}.key"] = "is not a checklist item for this appliance"
            continue
        if key in seen:
            errors[f"{where}.key"] = "is repeated"
            continue
        seen.add(key)
        result = item.get("result")
        if result not in INSPECTION_RESULTS:
            errors[f"{where}.result"] = "must be one of: " + ", ".join(INSPECTION_RESULTS)
        note = item.get("note")
        if note is None:
            note = ""
        elif not isinstance(note, str):
            errors[f"{where}.note"] = "must be a string"
            note = ""
        elif len(note.strip()) > MAX_INSPECTION_NOTE_LEN:
            errors[f"{where}.note"] = f"must be at most {MAX_INSPECTION_NOTE_LEN} characters"
        rows.append((key, result, note.strip()))
    if errors:
        return None, errors
    return rows, {}
