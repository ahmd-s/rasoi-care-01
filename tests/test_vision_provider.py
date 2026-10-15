"""OpenAI adapter contract tests; never make network calls or use credentials."""
import json

import pytest

import vision_guardrails as vg
import vision_provider as vp


class _Response:
    output_text = '{"visibility":"adequate","findings":[]}'


class _Responses:
    def __init__(self):
        self.kwargs = None

    def create(self, **kwargs):
        self.kwargs = kwargs
        return _Response()


class _Client:
    def __init__(self):
        self.responses = _Responses()


def _request(images=None):
    return vp.VisionRequest("hob", images or [b"jpeg bytes"], "Inspect visible defects", vg.RESPONSE_SCHEMA,
                            {}, 12)


def test_openai_provider_sends_bounded_structured_image_request():
    client = _Client()
    provider = vp.OpenAIProvider(client=client)
    assert provider.analyze(_request()) == {"visibility": "adequate", "findings": []}
    sent = client.responses.kwargs
    assert sent["model"] == "gpt-4.1-mini"
    assert sent["timeout"] == 12 and sent["max_output_tokens"] == 1200
    assert sent["store"] is False
    fmt = sent["text"]["format"]
    assert fmt["type"] == "json_schema" and fmt["strict"] is True
    assert "minimum" not in json.dumps(fmt["schema"])
    image = sent["input"][0]["content"][1]
    assert image["type"] == "input_image" and image["image_url"].startswith("data:image/jpeg;base64,")


@pytest.mark.parametrize("images", [[b"x"] * 6, [b"x" * (6_000_001)]])
def test_openai_provider_rejects_oversized_requests(images):
    with pytest.raises(vp.ProviderPermanentError):
        vp.OpenAIProvider(client=_Client()).analyze(_request(images))


def test_openai_requires_explicit_enablement_and_server_key(monkeypatch):
    monkeypatch.setenv("VISION_AI_PROVIDER", "openai")
    monkeypatch.delenv("VISION_AI_ENABLED", raising=False)
    monkeypatch.setenv("OPENAI_API_KEY", "server-secret")
    assert vp.get_provider() is None
    monkeypatch.setenv("VISION_AI_ENABLED", "1")
    monkeypatch.delenv("OPENAI_API_KEY")
    assert vp.get_provider() is None
    monkeypatch.setenv("OPENAI_API_KEY", "server-secret")
    assert isinstance(vp.get_provider(), vp.OpenAIProvider)


def test_openai_malformed_json_is_returned_for_the_bounded_structural_reask():
    class BadResponse:
        output_text = "not json"

    class BadClient:
        class responses:
            @staticmethod
            def create(**kwargs):
                return BadResponse()

    assert vp.OpenAIProvider(client=BadClient()).analyze(_request()) == "not json"
