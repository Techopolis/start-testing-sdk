import base64
import hashlib
import json
import threading
import time
from dataclasses import fields
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import urlopen

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from starttesting.chatgpt import (
    ChatGPTAuth,
    ChatGPTError,
    ChatGPTProvider,
    draft_context,
    draft_issue,
)
from starttesting.chatgpt.contracts import ISSUER, PLAN_SCOPE, AIDraft, LoginCancelled
from starttesting.chatgpt.loopback import LoopbackCallback
from starttesting.chatgpt.storage import MemoryCredentialStore
from starttesting.models import EventType


class FakeTransport:
    def __init__(self):
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.params = {}
        self.calls = []
        self.scope = "openid " + PLAN_SCOPE
        self.identity_overrides = {}
        self.fail_token = False
        self.events_list = []
        self.client_id = "oaiapp_test"
        self.refresh_tokens = []

    def browser(self, url):
        self.params = {k: v[0] for k, v in parse_qs(urlsplit(url).query).items()}
        return True

    def request(self, method, url, **kwargs):
        self.calls.append((method, url, kwargs))
        if url.endswith("openid-configuration"):
            return {
                "issuer": ISSUER,
                "authorization_endpoint": ISSUER + "/api/accounts/authorize",
                "token_endpoint": ISSUER + "/api/accounts/oauth/token",
                "jwks_uri": ISSUER + "/.well-known/jwks.json",
                "revocation_endpoint": ISSUER + "/revoke",
            }
        if url.endswith("jwks.json"):
            key = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(self.key.public_key()))
            key["kid"] = "test-key"
            return {"keys": [key]}
        if url.endswith("/token"):
            if self.fail_token:
                raise ChatGPTError("Simulated token failure")
            if kwargs["form"]["grant_type"] == "refresh_token":
                self.refresh_tokens.append(kwargs["form"])
                return {
                    "access_token": "fake-new-access",
                    "refresh_token": "fake-rotated-refresh",
                    "expires_in": 3600,
                    "token_type": "Bearer",
                    "scope": self.scope,
                }
            assert kwargs["form"]["client_id"] == self.client_id
            digest = hashlib.sha256(kwargs["form"]["code_verifier"].encode()).digest()
            assert (
                base64.urlsafe_b64encode(digest).rstrip(b"=").decode()
                == self.params["code_challenge"]
            )
            assert kwargs["form"]["redirect_uri"] == self.params["redirect_uri"]
            claims = {
                "iss": ISSUER,
                "aud": self.client_id,
                "exp": time.time() + 300,
                "sub": "verified-sub",
                "nonce": self.params["nonce"],
                "email": "example@example.test",
            }
            claims.update(self.identity_overrides)
            token = jwt.encode(claims, self.key, algorithm="RS256", headers={"kid": "test-key"})
            return {
                "id_token": token,
                "access_token": "fake-access",
                "refresh_token": "fake-refresh",
                "scope": self.scope,
                "expires_in": 3600,
                "token_type": "Bearer",
            }
        if url.endswith("/models"):
            return {
                "models": [
                    {"slug": "test-model", "display_name": "Test model", "visibility": "list"}
                ]
            }
        if url.endswith("/revoke"):
            return {}
        raise AssertionError(url)

    def events(self, url, token, payload):
        self.calls.append(("stream", url, payload))
        yield from self.events_list


@pytest.fixture
def auth_rig():
    transport = FakeTransport()
    store = MemoryCredentialStore()
    auth = ChatGPTAuth(store, app_name="Start Testing sample", transport=transport)

    class Callback:
        closed = False
        redirect_uri = "http://127.0.0.1:54321/auth/callback"

        def __init__(self, state):
            self.state = state

        def wait(self, **kwargs):
            return {"state": self.state, "code": "fake-code", "client_id": transport.client_id}

        def close(self):
            self.closed = True

    return auth, transport, store, Callback


def sign_in(rig):
    auth, transport, _, callback = rig
    return auth.sign_in(browser_open=transport.browser, callback_factory=callback)


def test_registration_reuse_host_and_fresh_state(auth_rig):
    auth, transport, store, callback = auth_rig
    profile = sign_in(auth_rig)
    assert profile.plan_enabled
    assert profile.subject == "verified-sub"
    assert "fake-access" not in repr(profile)
    first = dict(transport.params)
    assert first["client_id"] == "dynamic_agent_client"
    assert first["agent_name_hint"] == "Start Testing sample"
    second_auth = ChatGPTAuth(store, app_name="Start Testing sample", transport=transport)
    second_auth.sign_in(
        client_id=profile.client_id, browser_open=transport.browser, callback_factory=callback
    )
    assert transport.params["client_id"] == profile.client_id
    assert "agent_name_hint" not in transport.params
    assert transport.params["ext_agent_host_id"] == first["ext_agent_host_id"]
    assert "id_token_hint" in transport.params
    for name in ("state", "nonce", "code_challenge"):
        assert transport.params[name] != first[name]
    assert not auth.pending_registrations()


@pytest.mark.parametrize(
    "overrides",
    [
        {"nonce": "wrong"},
        {"aud": "wrong"},
        {"iss": "https://attacker.invalid"},
        {"exp": 1},
        {"sub": ""},
        {"azp": "wrong"},
    ],
)
def test_rejects_invalid_identity(auth_rig, overrides):
    auth, transport, _, _ = auth_rig
    transport.identity_overrides = overrides
    with pytest.raises(ChatGPTError, match="verification"):
        sign_in(auth_rig)
    assert not auth.connections()


def test_identity_only_blocks_inference(auth_rig):
    auth, transport, _, _ = auth_rig
    transport.scope = "openid profile email"
    profile = sign_in(auth_rig)
    assert not profile.plan_enabled
    with pytest.raises(ChatGPTError, match="plan-use"):
        auth.access_token(profile.client_id)


def test_persist_issued_client_before_failed_exchange(auth_rig):
    auth, transport, _, _ = auth_rig
    transport.fail_token = True
    with pytest.raises(ChatGPTError):
        sign_in(auth_rig)
    assert auth.pending_registrations() == ("oaiapp_test",)
    assert not auth.connections()


def test_refresh_rotation_and_disconnect(auth_rig):
    auth, transport, _, _ = auth_rig
    profile = sign_in(auth_rig)
    auth.clock = lambda: profile.expires_at + 1
    assert auth.access_token(profile.client_id) == "fake-new-access"
    assert auth.connections()[0].refresh_token == "fake-rotated-refresh"
    assert transport.refresh_tokens[0]["client_id"] == "oaiapp_test"
    assert "scope" not in transport.refresh_tokens[0]
    assert auth.disconnect(profile.client_id)
    assert auth.connections()[0].access_token == ""
    assert auth.connections()[0].id_token == ""
    assert auth.connections()[0].client_id == profile.client_id


def test_refresh_permission_revoked(auth_rig):
    auth, transport, _, _ = auth_rig
    profile = sign_in(auth_rig)
    auth.clock = lambda: profile.expires_at + 1
    transport.scope = "openid"
    with pytest.raises(ChatGPTError, match="no longer"):
        auth.access_token(profile.client_id)


def test_bad_state_and_cancelled(auth_rig):
    auth, transport, _, callback = auth_rig

    class Wrong(callback):
        def wait(self, **kwargs):
            return {"state": "wrong", "code": "fake-code", "client_id": "oaiapp_test"}

    with pytest.raises(ChatGPTError, match="state"):
        auth.sign_in(browser_open=transport.browser, callback_factory=Wrong)

    class Cancelled(callback):
        def wait(self, **kwargs):
            return {"state": self.state, "error": "access_denied"}

    with pytest.raises(LoginCancelled):
        auth.sign_in(browser_open=transport.browser, callback_factory=Cancelled)
    assert not auth.connections()


def test_real_loopback_validates_callback_and_closes():
    callback = LoopbackCallback("expected-state")
    result = []
    thread = threading.Thread(target=lambda: result.append(callback.wait(timeout=3)))
    thread.start()
    try:
        with pytest.raises(HTTPError):
            urlopen(callback.redirect_uri + "?state=wrong&code=fake", timeout=1)
        query = urlencode({"state": "expected-state", "code": "fake", "client_id": "oaiapp_test"})
        with urlopen(callback.redirect_uri + "?" + query, timeout=2) as response:
            assert response.status == 200
            assert response.headers["Cache-Control"] == "no-store"
        thread.join(3)
        assert result[0]["code"] == "fake"
    finally:
        callback.close()
        thread.join(3)


def test_context_minimal_and_structured_draft(auth_rig, rig):
    auth, transport, _, _ = auth_rig
    client, backend, _ = rig
    client.redactor.register_sensitive_value("fake-sensitive-note")
    client.record("Old debug", type=EventType.DEBUG)
    incident = client.reportable_error(ValueError("Error"))
    context = draft_context(client, incident, "fake-sensitive-note")
    assert "fake-sensitive-note" not in json.dumps(context)
    assert len(json.dumps(context).encode()) < 12_000
    profile = sign_in(auth_rig)
    provider = ChatGPTProvider(auth, profile.client_id)
    payload = {field.name: field.name for field in fields(AIDraft)}
    transport.events_list = [
        {"type": "response.output_text.delta", "delta": json.dumps(payload)},
        {"type": "response.completed"},
    ]
    draft = draft_issue(client, provider, incident, "Notes", model="test-model", consent=True)
    assert draft.title == "title"
    assert "Hypothesis (unverified)" in draft.as_issue_draft().description
    assert not backend.issues
    call = transport.calls[-1]
    assert call[2]["store"] is False
    assert call[2]["stream"] is True
    assert call[1] == "https://api.openai.com/v1/responses"
    with pytest.raises(PermissionError):
        draft_issue(client, provider, incident, "Notes", model="test-model", consent=False)


@pytest.mark.parametrize(
    "events",
    [
        [],
        [{"type": "response.failed"}],
        [{"type": "response.incomplete"}],
        [{"type": "error"}],
        [
            {"type": "response.output_text.delta", "delta": "bad-json"},
            {"type": "response.completed"},
        ],
    ],
)
def test_inference_failure_preserves_manual_reporting(auth_rig, rig, events):
    auth, transport, _, _ = auth_rig
    client, _, reporter = rig
    profile = sign_in(auth_rig)
    provider = ChatGPTProvider(auth, profile.client_id)
    transport.events_list = events
    with pytest.raises(ChatGPTError):
        provider.draft({"error": "test"}, model="test-model")
    from starttesting.models import IssueDraft

    report = reporter.prepare(
        IssueDraft("Manual title", "Manual description"), diagnostic_consent=True
    )
    assert reporter.submit(report, reporter.approve(report)).complete
