"""Start Testing: local diagnostics with explicit, reviewed submission."""

from __future__ import annotations

import threading

from .client import Client, Options
from .models import ErrorSeverity, EventType

__version__ = "0.1.0a1"
_client: Client | None = None
_lock = threading.RLock()


def configure(project_id: str, **kwargs) -> Client:
    global _client
    with _lock:
        if _client is not None and not _client.closed:
            raise RuntimeError("Already configured; close the existing client first")
        _client = Client(project_id, **kwargs)
        return _client


def get_client() -> Client:
    if _client is None or _client.closed:
        raise RuntimeError("Call starttesting.configure first")
    return _client


def breadcrumb(message: str, **kwargs):
    return get_client().breadcrumb(message, **kwargs)


def record_exception(error: BaseException, **kwargs):
    return get_client().record_exception(error, **kwargs)


def reportable_error(error: BaseException, *, user_message: str = ""):
    return get_client().reportable_error(error, user_message=user_message)


def install_exception_hooks(**kwargs):
    from .integrations.exceptions import install_exception_hooks as install

    return install(get_client(), **kwargs)


def register_sensitive_key(key: str) -> None:
    get_client().redactor.register_sensitive_key(key)


def register_sensitive_value(value: str) -> None:
    get_client().redactor.register_sensitive_value(value)


def register_redaction_pattern(pattern: str) -> None:
    get_client().redactor.register_redaction_pattern(pattern)


def register_redactor(callback) -> None:
    get_client().redactor.register_redactor(callback)


__all__ = [
    "Client",
    "Options",
    "ErrorSeverity",
    "EventType",
    "configure",
    "get_client",
    "breadcrumb",
    "record_exception",
    "reportable_error",
    "install_exception_hooks",
    "register_sensitive_key",
    "register_sensitive_value",
    "register_redaction_pattern",
    "register_redactor",
]
