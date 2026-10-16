"""Vision AI — provider interface, OpenAI adapter and deterministic fake.

Each provider is a small object with
`analyze(request) -> dict` that returns the *parsed JSON* of a model reply
(shape: vision_guardrails.RESPONSE_SCHEMA); everything it returns is untrusted
and is validated by vision_guardrails before anything is stored or shown.

Configuration (environment, server-side only; never in the Flutter apps):

    VISION_AI_PROVIDER      unset/empty -> AI disabled (the safe default).
                            Only registered names enable AI; an unknown name
                            keeps AI disabled and logs a warning.
    VISION_AI_KILL_SWITCH   "1" disables AI immediately, whatever else is set.
    RASOI_ALLOW_FAKE_VISION "1" is required before the "fake" provider can be
                            selected, so it cannot be enabled by accident on a
                            real deployment (same pattern as
                            RASOI_ALLOW_DEFAULT_STAFF_PIN).

The OpenAI adapter reads credentials from the server environment only, uses
the Responses API with structured JSON output, bounds request size and time,
and never logs image bytes, keys or raw replies.
"""
import base64
import json
import os

from vision_guardrails import CODES, PROFILES


class ProviderTransientError(Exception):
    """Timeout, rate limit, 5xx — worth retrying with backoff."""


class ProviderPermanentError(Exception):
    """Authentication, billing or request-rejected — retrying will not help."""


class VisionRequest:
    """What a provider is given. `images` are re-encoded JPEG bytes held in
    memory only; `technician_checks` maps checklist label -> result
    (good/attention/not_tested) and never includes free-text notes."""

    def __init__(self, category, images, prompt, schema, technician_checks, timeout_seconds):
        self.category = category
        self.images = images
        self.prompt = prompt
        self.schema = schema
        self.technician_checks = technician_checks
        self.timeout_seconds = timeout_seconds


class VisionProvider:
    name = "base"
    model = "none"
    # True for providers that fabricate output (tests / local demos). The job
    # runner persists this with the inspection, and a simulated result is never
    # allowed to contribute to any health score, accepted or not.
    simulated = False

    def analyze(self, request):  # pragma: no cover - interface
        raise NotImplementedError


def valid_fake_response(category, n_images, *, code=None, severity="medium", confidence=0.9,
                        evidence="Residue and discolouration are visible on the surface in the first photo.",
                        photo_indexes=None):
    """A well-formed, guardrail-clean reply for `category` (test helper)."""
    code = code or next(iter(CODES[category]))
    return {
        "visibility": "adequate",
        "findings": [{
            "code": code, "severity": severity, "confidence": confidence,
            "evidence": evidence,
            "photoIndexes": photo_indexes if photo_indexes is not None else [0],
        }],
    }


class FakeProvider(VisionProvider):
    """Deterministic stand-in used by tests and local demos. `script` is a
    list consumed one entry per call: a dict is returned as the reply, an
    Exception instance is raised, a callable is invoked with the request.
    With an empty script every call returns one valid medium finding. It makes
    no network calls and sees only synthetic images."""

    name = "fake"
    model = "fake-vision-v1"
    simulated = True

    def __init__(self, script=None):
        self.script = list(script or [])
        self.calls = []

    def analyze(self, request):
        self.calls.append(request)
        if self.script:
            step = self.script.pop(0)
            if isinstance(step, BaseException):
                raise step
            if callable(step):
                return step(request)
            return step
        return valid_fake_response(request.category, len(request.images))


class OpenAIProvider(VisionProvider):
    """OpenAI Responses API adapter. Imports the SDK lazily so deployments
    with AI disabled do not need to initialize a client or read credentials."""

    name = "openai"
    model = "gpt-4.1-mini"
    MAX_IMAGES = 5
    MAX_TOTAL_IMAGE_BYTES = 6_000_000
    MAX_OUTPUT_TOKENS = 1200

    def __init__(self, *, client=None):
        self._client = client

    @staticmethod
    def _structured_schema(schema):
        """Return the strict subset accepted by Structured Outputs. The
        application validator remains authoritative for dropped bounds."""
        schema = json.loads(json.dumps(schema))

        def clean(node):
            if isinstance(node, dict):
                for key in ("minimum", "maximum", "minLength", "maxLength", "minItems"):
                    node.pop(key, None)
                for value in node.values():
                    clean(value)
            elif isinstance(node, list):
                for value in node:
                    clean(value)
        clean(schema)
        return schema

    def _client_or_create(self, timeout):
        if self._client is not None:
            return self._client
        server_credential = os.environ.get("OPENAI_API_KEY", "").strip()
        if not server_credential:
            raise ProviderPermanentError("provider unavailable")
        try:
            from openai import OpenAI
            self._client = OpenAI(api_key=server_credential, timeout=timeout, max_retries=0)
        except Exception as exc:
            # Do not expose SDK exception strings; they may contain headers.
            raise ProviderPermanentError("provider unavailable") from exc
        return self._client

    def analyze(self, request):
        if not request.images or len(request.images) > self.MAX_IMAGES:
            raise ProviderPermanentError("invalid request")
        if sum(len(image) for image in request.images) > self.MAX_TOTAL_IMAGE_BYTES:
            raise ProviderPermanentError("invalid request")
        timeout = max(0.1, min(float(request.timeout_seconds), 60.0))
        model = os.environ.get("OPENAI_VISION_MODEL", self.model).strip()
        if not model or len(model) > 100:
            raise ProviderPermanentError("invalid configuration")
        client = self._client_or_create(timeout)
        content = [{"type": "input_text", "text": request.prompt}]
        for image in request.images:
            encoded = base64.b64encode(image).decode("ascii")
            content.append({"type": "input_image", "image_url": f"data:image/jpeg;base64,{encoded}",
                            "detail": "auto"})
        try:
            response = client.responses.create(
                model=model,
                input=[{"role": "user", "content": content}],
                text={"format": {"type": "json_schema", "name": "rasoi_visual_inspection",
                                  "strict": True, "schema": self._structured_schema(request.schema)}},
                max_output_tokens=self.MAX_OUTPUT_TOKENS,
                store=False,
                timeout=timeout,
            )
        except Exception as exc:
            self._raise_safe_provider_error(exc)
        output_text = getattr(response, "output_text", None)
        if not isinstance(output_text, str):
            output_text = ""
        try:
            parsed = json.loads(output_text)
        except (TypeError, ValueError):
            # Let the existing structural validator trigger its one bounded
            # re-ask; do not bypass that recovery path here.
            return output_text
        return parsed

    @staticmethod
    def _raise_safe_provider_error(exc):
        """Classify SDK errors by type/status without returning their text."""
        try:
            import openai
            if isinstance(exc, (openai.APITimeoutError, openai.APIConnectionError)):
                raise ProviderTransientError("provider temporarily unavailable") from exc
            if isinstance(exc, openai.APIStatusError):
                status = exc.status_code
                if status == 429 or status >= 500 or status in (408, 409):
                    raise ProviderTransientError("provider temporarily unavailable") from exc
                raise ProviderPermanentError("provider rejected request") from exc
        except ImportError:
            pass
        # Tests and SDK-version-specific exceptions are handled conservatively.
        raise ProviderPermanentError("provider unavailable") from exc


def _registry():
    registry = {}
    if os.environ.get("RASOI_ALLOW_FAKE_VISION") == "1":
        registry["fake"] = FakeProvider
    if os.environ.get("VISION_AI_ENABLED") == "1" and os.environ.get("OPENAI_API_KEY", "").strip():
        registry["openai"] = OpenAIProvider
    return registry


# Tests (and only tests) can install a provider object directly.
_override = None


def set_provider_for_tests(provider):
    global _override
    _override = provider


def configured_provider_name():
    return (os.environ.get("VISION_AI_PROVIDER") or "").strip().lower()


def kill_switch_on():
    return os.environ.get("VISION_AI_KILL_SWITCH") == "1"


def get_provider():
    """The active provider, or None when AI is disabled (no/unknown provider
    configured, or the kill switch is on)."""
    if kill_switch_on():
        return None
    if _override is not None:
        return _override
    name = configured_provider_name()
    if not name:
        return None
    factory = _registry().get(name)
    if factory is None:
        return None
    return factory()


def profile_label(category):
    return PROFILES[category][0]
