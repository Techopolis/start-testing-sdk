from __future__ import annotations

import base64
import hashlib
import hmac
import re
import secrets
import threading
import time
import webbrowser
from dataclasses import asdict, replace
from urllib.parse import urlencode
from uuid import uuid4

from .contracts import (
    ISSUER,
    RESOURCE,
    SCOPES,
    ChatGPTError,
    Connection,
    CredentialStore,
    LoginCancelled,
)
from .loopback import LoopbackCallback
from .transport import OpenAITransport


class ChatGPTAuth:
    """Blocking I/O; call on a worker thread. Tokens never enter Start Testing services."""

    def __init__(self, store: CredentialStore, *, app_name: str, transport=None, clock=time.time):
        if not app_name.strip():
            raise ValueError("Use the embedding application's actual name")
        self.store, self.app_name = store, app_name
        self.transport = transport or OpenAITransport()
        self.clock = clock
        self._lock = threading.RLock()
        data = store.load()
        if not data:
            data = {
                "host_id": "urn:uuid:" + str(uuid4()),
                "profiles": {},
                "pending_registrations": [],
            }
            store.save(data)
        self.host_id = data["host_id"]
        self._discovery = None

    def discovery(self) -> dict:
        if self._discovery is None:
            data = self.transport.request("GET", ISSUER + "/.well-known/openid-configuration")
            if data.get("issuer") != ISSUER:
                raise ChatGPTError("Unexpected OpenAI identity issuer")
            for key in (
                "authorization_endpoint",
                "token_endpoint",
                "jwks_uri",
                "revocation_endpoint",
            ):
                if key not in data or not data[key].startswith(ISSUER + "/"):
                    raise ChatGPTError("Unexpected OpenAI identity endpoint")
                OpenAITransport.validate_url(data[key])
            self._discovery = data
        return self._discovery

    def connections(self) -> tuple[Connection, ...]:
        return tuple(
            Connection(**{**v, "scopes": tuple(v["scopes"])})
            for v in self.store.load()["profiles"].values()
        )

    def pending_registrations(self) -> tuple[str, ...]:
        return tuple(self.store.load().get("pending_registrations", ()))

    def _save_connection(self, connection: Connection) -> None:
        data = self.store.load()
        data["profiles"][connection.client_id] = asdict(connection)
        data["pending_registrations"] = [
            x for x in data.get("pending_registrations", ()) if x != connection.client_id
        ]
        self.store.save(data)

    def _profile(self, client_id: str) -> Connection:
        for profile in self.connections():
            if profile.client_id == client_id:
                return profile
        raise ChatGPTError("Choose a saved ChatGPT account")

    def validate_id_token(self, token: str, client_id: str, nonce: str | None) -> dict:
        import jwt

        try:
            jwks = self.transport.request("GET", self.discovery()["jwks_uri"])
            header = jwt.get_unverified_header(token)
            if header.get("alg") != "RS256" or not header.get("kid"):
                raise ValueError("Unsupported signing algorithm")
            keys = [k for k in jwks["keys"] if k.get("kid") == header["kid"]]
            if len(keys) != 1:
                raise ValueError("Signing key not found")
            key = jwt.PyJWK.from_dict(keys[0], algorithm="RS256").key
            identity = jwt.decode(
                token,
                key,
                algorithms=["RS256"],
                audience=client_id,
                issuer=ISSUER,
                options={"require": ["iss", "aud", "exp", "sub"]},
            )
            if not isinstance(identity["sub"], str) or not identity["sub"]:
                raise ValueError("Missing subject")
            if nonce is not None and not hmac.compare_digest(identity.get("nonce", ""), nonce):
                raise ValueError("Invalid nonce")
            if identity.get("azp", client_id) != client_id:
                raise ValueError("Wrong authorized party")
            return identity
        except Exception:
            raise ChatGPTError("ChatGPT identity verification failed") from None

    def sign_in(
        self,
        *,
        client_id: str | None = None,
        browser_open=None,
        cancel: threading.Event | None = None,
        timeout: float = 180,
        callback_factory=LoopbackCallback,
    ) -> Connection:
        with self._lock:
            saved = None
            if client_id:
                saved = next((p for p in self.connections() if p.client_id == client_id), None)
                if saved is None and client_id not in self.pending_registrations():
                    raise ChatGPTError("Unknown ChatGPT registration")
            endpoints = self.discovery()
            state, nonce, verifier = (secrets.token_urlsafe(32) for _ in range(3))
            challenge = (
                base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
                .rstrip(b"=")
                .decode()
            )
            callback = callback_factory(state)
            try:
                params = {
                    "client_id": client_id or "dynamic_agent_client",
                    "ext_agent_host_id": self.host_id,
                    "response_type": "code",
                    "redirect_uri": callback.redirect_uri,
                    "scope": SCOPES,
                    "resource": RESOURCE,
                    "state": state,
                    "nonce": nonce,
                    "code_challenge_method": "S256",
                    "code_challenge": challenge,
                }
                if not client_id:
                    params["agent_name_hint"] = self.app_name
                elif saved and saved.id_token:
                    params["id_token_hint"] = saved.id_token
                opener = browser_open or webbrowser.open
                if not opener(endpoints["authorization_endpoint"] + "?" + urlencode(params)):
                    raise ChatGPTError("Could not open the system browser")
                result = callback.wait(timeout=timeout, cancel=cancel)
                if not hmac.compare_digest(result.get("state", ""), state):
                    raise ChatGPTError("Invalid ChatGPT callback state")
                if result.get("error"):
                    raise LoginCancelled("ChatGPT sign-in was cancelled or denied")
                issued = result.get("client_id", client_id)
                if not issued or not re.fullmatch(r"oaiapp_[A-Za-z0-9_-]{1,200}", issued):
                    raise ChatGPTError("ChatGPT registration did not return an issued client ID")
                if client_id and issued != client_id:
                    raise ChatGPTError("ChatGPT callback changed the selected registration")
                code = result.get("code")
                if not isinstance(code, str) or not code:
                    raise ChatGPTError("ChatGPT callback did not contain a code")
                # Retain the registration before exchange so invalid_grant can be retried.
                data = self.store.load()
                if not client_id and issued not in data["pending_registrations"]:
                    data["pending_registrations"].append(issued)
                    self.store.save(data)
                tokens = self.transport.request(
                    "POST",
                    endpoints["token_endpoint"],
                    form={
                        "grant_type": "authorization_code",
                        "client_id": issued,
                        "code": code,
                        "code_verifier": verifier,
                        "redirect_uri": callback.redirect_uri,
                        "resource": RESOURCE,
                    },
                )
                identity = self.validate_id_token(tokens.get("id_token", ""), issued, nonce)
                if saved and (identity["sub"] != saved.subject or identity["iss"] != saved.issuer):
                    raise ChatGPTError("ChatGPT account did not match the selected registration")
                connection = self._connection(issued, identity, tokens)
                self._save_connection(connection)
                return connection
            finally:
                callback.close()

    def _connection(
        self, client_id: str, identity: dict, tokens: dict, previous: Connection | None = None
    ) -> Connection:
        try:
            scopes = (
                tuple(tokens["scope"].split())
                if "scope" in tokens
                else (previous.scopes if previous else ())
            )
            expires = float(tokens["expires_in"])
            if not 0 < expires <= 86400 * 30 or tokens.get("token_type", "").lower() != "bearer":
                raise ValueError("Invalid token response")
            access = tokens["access_token"]
            refresh = tokens.get("refresh_token", previous.refresh_token if previous else "")
            id_token = tokens.get("id_token", previous.id_token if previous else "")
            if not all(isinstance(v, str) for v in (access, refresh, id_token)) or not access:
                raise ValueError("Invalid tokens")
            return Connection(
                client_id,
                identity["sub"],
                identity.get("email", ""),
                scopes,
                self.clock() + expires,
                access_token=access,
                refresh_token=refresh,
                id_token=id_token,
            )
        except (KeyError, TypeError, ValueError):
            raise ChatGPTError("OpenAI returned an invalid credential response") from None

    def access_token(self, client_id: str) -> str:
        with self._lock:
            profile = self._profile(client_id)
            if not profile.plan_enabled:
                raise ChatGPTError("This connection has no ChatGPT plan-use permission")
            if profile.expires_at <= self.clock() + 60:
                if not profile.refresh_token:
                    raise ChatGPTError("ChatGPT session expired. Connect again.")
                tokens = self.transport.request(
                    "POST",
                    self.discovery()["token_endpoint"],
                    form={
                        "grant_type": "refresh_token",
                        "client_id": client_id,
                        "refresh_token": profile.refresh_token,
                        "resource": RESOURCE,
                    },
                )
                identity = {"sub": profile.subject, "email": profile.email}
                if tokens.get("id_token"):
                    identity = self.validate_id_token(tokens["id_token"], client_id, None)
                    if identity["sub"] != profile.subject:
                        raise ChatGPTError("Refreshed ChatGPT identity did not match")
                profile = self._connection(client_id, identity, tokens, profile)
                self._save_connection(profile)
            if not profile.plan_enabled:
                raise ChatGPTError("ChatGPT plan-use permission is no longer enabled")
            return profile.access_token

    def disconnect(self, client_id: str) -> bool:
        """True means remote revocation confirmed; local credentials are always cleared."""
        with self._lock:
            profile = self._profile(client_id)
            revoked = False
            try:
                if profile.refresh_token:
                    self.transport.request(
                        "POST",
                        self.discovery()["revocation_endpoint"],
                        form={
                            "token": profile.refresh_token,
                            "token_type_hint": "refresh_token",
                            "client_id": client_id,
                        },
                    )
                    revoked = True
            except ChatGPTError:
                pass
            finally:
                self._save_connection(
                    replace(
                        profile,
                        access_token="",
                        refresh_token="",
                        id_token="",
                        scopes=(),
                        expires_at=0,
                    )
                )
            return revoked
