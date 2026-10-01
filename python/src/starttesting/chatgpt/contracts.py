from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol

from ..models import AIDraft

ISSUER = "https://auth.openai.com"
RESOURCE = "https://api.openai.com/v1"
PLAN_SCOPE = "chatgpt.tokens.use.direct"
SCOPES = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
USAGE_URL = "https://chatgpt.com/settings/usage"


class ChatGPTError(RuntimeError):
    """Safe, fixed user-facing message; never include raw HTTP bodies or tokens."""


class LoginCancelled(ChatGPTError):
    pass


@dataclass(frozen=True)
class Connection:
    client_id: str
    subject: str
    email: str
    scopes: tuple[str, ...]
    expires_at: float
    issuer: str = ISSUER
    access_token: str = field(default="", repr=False)
    refresh_token: str = field(default="", repr=False)
    id_token: str = field(default="", repr=False)

    @property
    def plan_enabled(self) -> bool:
        return PLAN_SCOPE in self.scopes and bool(self.access_token)


class AIProvider(Protocol):
    def draft(self, context: dict, *, model: str) -> AIDraft: ...


class CredentialStore(Protocol):
    def load(self) -> dict: ...
    def save(self, value: dict) -> None: ...
