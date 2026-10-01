"""Best-effort redaction. Do not pass private data to diagnostics in the first place."""

from __future__ import annotations

import math
import re
import threading
from collections.abc import Callable, Mapping

REDACTED = "[REDACTED]"
_DEFAULT_KEYS = {
    "password",
    "passwd",
    "passcode",
    "secret",
    "token",
    "accesstoken",
    "refreshtoken",
    "idtoken",
    "apikey",
    "authorization",
    "cookie",
    "setcookie",
    "clientsecret",
    "requestbody",
    "responsebody",
}


def normalized(key: str) -> str:
    return re.sub(r"[^a-z0-9]", "", key.lower())


class Redactor:
    def __init__(
        self,
        *,
        allowed_fields: set[str] | None = None,
        denied_fields: set[str] | None = None,
        suppressed_categories: set[str] | None = None,
    ):
        self._keys = set(_DEFAULT_KEYS)
        self._values: set[str] = set()
        self._patterns: list[re.Pattern] = []
        self._custom: list[Callable[[str], str]] = []
        self.allowed_fields = None if allowed_fields is None else frozenset(allowed_fields)
        self.denied_fields = frozenset(denied_fields or ())
        self.suppressed_categories = frozenset(suppressed_categories or ())
        self._lock = threading.RLock()

    def register_sensitive_key(self, key: str) -> None:
        if not normalized(key):
            raise ValueError("Sensitive key cannot be empty")
        with self._lock:
            self._keys.add(normalized(key))

    def register_sensitive_value(self, value: str) -> None:
        if not value:
            raise ValueError("Sensitive value cannot be empty")
        with self._lock:
            self._values.add(value)

    def register_redaction_pattern(self, pattern: str) -> None:
        compiled = re.compile(pattern)
        with self._lock:
            self._patterns.append(compiled)

    def register_redactor(self, redactor: Callable[[str], str]) -> None:
        with self._lock:
            self._custom.append(redactor)

    def text(self, text: str) -> str:
        if not isinstance(text, str):
            return "[unsupported value]"
        with self._lock:
            try:
                for callback in self._custom:
                    text = callback(text)
                    if not isinstance(text, str):
                        return REDACTED
                for value in sorted(self._values, key=len, reverse=True):
                    text = text.replace(value, REDACTED)
                for pattern in self._patterns:
                    text = pattern.sub(REDACTED, text)
                text = re.sub(r"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+", REDACTED, text)
                text = re.sub(r"\bsk-[A-Za-z0-9_-]{8,}\b", REDACTED, text)
                text = re.sub(
                    r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+", REDACTED, text
                )
                # Matches common assignments, JSON fields, and query parameters.
                keys = "|".join(re.escape(k) for k in sorted(self._keys, key=len, reverse=True))
                flexible = "|".join(
                    "[-_ ]*".join(map(re.escape, k))
                    for k in sorted(self._keys, key=len, reverse=True)
                )
                text = re.sub(
                    rf"""(?ix)(?:["']?\b(?:{keys}|{flexible})["']?\s*[:=]\s*)
                    (?:"[^"\n]*"|'[^'\n]*'|[^\s,;&\}}]+)""",
                    REDACTED,
                    text,
                )
                text = re.sub(r"(?i)(https?://)[^/\s:@]+:[^/\s@]+@", r"\1[REDACTED]@", text)
                return text
            except Exception:
                # A failing developer redactor must never fall back to raw data.
                return REDACTED

    def clean(self, value: object, *, filter_fields: bool = False, _depth: int = 0) -> object:
        if _depth > 8:
            return "[depth limit]"
        if isinstance(value, str):
            return self.text(value)[:8192]
        if value is None or isinstance(value, (bool, int)):
            return value
        if isinstance(value, float):
            return value if math.isfinite(value) else "[non-finite]"
        if isinstance(value, Mapping):
            with self._lock:
                keys = frozenset(self._keys)
            result = {}
            for key, entry in list(value.items())[:64]:
                if not isinstance(key, str):
                    continue
                if filter_fields and (
                    key in self.denied_fields
                    or (self.allowed_fields is not None and key not in self.allowed_fields)
                ):
                    continue
                safe_key = self.text(key)[:128]
                result[safe_key] = (
                    REDACTED
                    if any(k in normalized(key) for k in keys)
                    else self.clean(entry, filter_fields=filter_fields, _depth=_depth + 1)
                )
            return result
        if isinstance(value, (list, tuple)):
            return [
                self.clean(v, filter_fields=filter_fields, _depth=_depth + 1) for v in value[:64]
            ]
        # Never call arbitrary object repr/str, which may expose its credentials.
        return "[unsupported value]"
