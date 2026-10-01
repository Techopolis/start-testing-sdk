from __future__ import annotations

import copy
import json
from pathlib import Path
from uuid import uuid4

from ..diagnostics.storage import DiagnosticStorage
from .contracts import ChatGPTError


class MemoryCredentialStore:
    """Tests only. Credentials disappear on process exit."""

    def __init__(self):
        self._data = {}

    def load(self) -> dict:
        return copy.deepcopy(self._data)

    def save(self, value: dict) -> None:
        self._data = copy.deepcopy(value)


class KeyringCredentialStore:
    """Single local runtime per app namespace; no plaintext fallback."""

    def __init__(self, app_id: str, lock_directory: Path):
        import keyring

        backend = keyring.get_keyring()
        allowed = {
            ("keyring.backends.macOS", "Keyring"),
            ("keyring.backends.Windows", "WinVaultKeyring"),
            ("keyring.backends.SecretService", "Keyring"),
        }
        if (type(backend).__module__, type(backend).__name__) not in allowed:
            raise ChatGPTError("A supported OS credential vault is required for ChatGPT")
        self._backend = backend
        self._namespace = "starttesting.chatgpt." + app_id
        self._lock = DiagnosticStorage(lock_directory)

    def load(self) -> dict:
        try:
            raw = self._backend.get_password(self._namespace, "profiles")
            if not raw:
                return {}
            manifest = json.loads(raw)
            if "generation" not in manifest:
                return manifest
            count = manifest["chunks"]
            if not isinstance(count, int) or not 1 <= count <= 256:
                raise ValueError("Invalid credential record")
            chunks = [
                self._backend.get_password(self._namespace, f"{manifest['generation']}:{n}")
                for n in range(count)
            ]
            if any(chunk is None for chunk in chunks):
                raise ValueError("Incomplete credential record")
            return json.loads("".join(chunks))
        except Exception:
            raise ChatGPTError("Could not read the OS credential vault") from None

    def save(self, value: dict) -> None:
        # Windows Credential Manager limits each generic credential blob. Small
        # chunks stay within that limit; the manifest switches generations last.
        raw = json.dumps(value, ensure_ascii=True)
        chunks = [raw[n : n + 1000] for n in range(0, len(raw), 1000)]
        if len(chunks) > 256:
            raise ChatGPTError("Too many saved ChatGPT profiles")
        generation = str(uuid4())
        written = []
        committed = False
        try:
            previous_raw = self._backend.get_password(self._namespace, "profiles")
            previous = json.loads(previous_raw) if previous_raw else {}
            for n, chunk in enumerate(chunks):
                key = f"{generation}:{n}"
                self._backend.set_password(self._namespace, key, chunk)
                written.append(key)
            self._backend.set_password(
                self._namespace,
                "profiles",
                json.dumps({"generation": generation, "chunks": len(chunks)}),
            )
            committed = True
            if "generation" in previous:
                for n in range(min(previous.get("chunks", 0), 256)):
                    self._backend.delete_password(self._namespace, f"{previous['generation']}:{n}")
        except Exception:
            if not committed:
                for key in written:
                    try:
                        self._backend.delete_password(self._namespace, key)
                    except Exception:
                        pass
                raise ChatGPTError("Could not save to the OS credential vault") from None

    def close(self) -> None:
        self._lock.close()
