"""Opt-in local persistence. Each client requires its own storage directory."""

from __future__ import annotations

import json
import os
import stat
import tempfile
import threading
from datetime import datetime, timedelta
from pathlib import Path

from ..models import (
    BuildInfo,
    DiagnosticEvent,
    Distribution,
    Environment,
    ErrorSeverity,
    EventType,
    Incident,
    encode,
)


def private_directory(path: Path) -> None:
    if path.is_symlink():
        raise ValueError("Storage directory cannot be a symlink")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if os.name != "nt":
        if path.stat().st_uid != os.getuid():
            raise PermissionError("Storage directory must belong to this user")
        path.chmod(0o700)


def atomic_write(path: Path, content: bytes) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=".write-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class DiagnosticStorage:
    def __init__(
        self,
        directory: Path,
        *,
        segment_bytes: int = 1_000_000,
        segments: int = 4,
        retention_seconds: int = 86400,
        max_incidents: int = 10,
        max_incident_bytes: int = 3_000_000,
    ):
        if min(segment_bytes, segments, retention_seconds, max_incidents, max_incident_bytes) <= 0:
            raise ValueError("Storage limits must be positive")
        private_directory(directory)
        self.directory = directory
        self.segment_bytes, self.segments = segment_bytes, segments
        self.retention_seconds = retention_seconds
        self.max_incidents, self.max_incident_bytes = max_incidents, max_incident_bytes
        self._lock = threading.RLock()
        self._closed = False
        # OS advisory lock is released on process exit, including abnormal exit.
        lockpath = directory / ".lock"
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
        self._lockfile = os.fdopen(os.open(lockpath, flags, 0o600), "r+b")
        try:
            if os.name == "nt":
                import msvcrt

                # Lock the first byte without writing. Windows allows locking past the
                # end of a file, and writing to a byte another process holds fails.
                self._lockfile.seek(0)
                msvcrt.locking(self._lockfile.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl

                fcntl.flock(self._lockfile, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self._lockfile.close()
            raise RuntimeError("Diagnostic directory is already in use") from None

    def _safe_files(self, pattern: str) -> list[Path]:
        return [
            p
            for p in self.directory.glob(pattern)
            if not p.is_symlink() and stat.S_ISREG(p.stat().st_mode)
        ]

    def prune(self, now: datetime) -> None:
        with self._lock:
            cutoff = (now - timedelta(seconds=self.retention_seconds)).timestamp()
            for pattern in ("events-*.jsonl", "incident-*.json"):
                for path in self._safe_files(pattern):
                    if path.stat().st_mtime < cutoff:
                        path.unlink()
            incidents = sorted(
                self._safe_files("incident-*.json"), key=lambda p: p.stat().st_mtime, reverse=True
            )
            for path in incidents[self.max_incidents :]:
                path.unlink()

    def append(self, event: DiagnosticEvent, now: datetime) -> None:
        raw = (encode(event.to_dict()) + "\n").encode()
        if len(raw) > self.segment_bytes:
            return
        with self._lock:
            self.prune(now)
            current = self.directory / "events-0.jsonl"
            if current.is_symlink():
                raise ValueError("Log cannot be a symlink")
            if current.exists() and current.stat().st_size + len(raw) > self.segment_bytes:
                for index in range(self.segments - 1, -1, -1):
                    source = self.directory / f"events-{index}.jsonl"
                    if source.exists():
                        if index == self.segments - 1:
                            source.unlink()
                        else:
                            source.replace(self.directory / f"events-{index + 1}.jsonl")
            flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0)
            with os.fdopen(os.open(current, flags, 0o600), "ab") as stream:
                stream.write(raw)

    def save_incident(self, incident: Incident, now: datetime) -> None:
        data = incident.to_dict()
        data["events"] = [e.to_dict() for e in incident.events]
        raw = encode(data).encode()
        if len(raw) > self.max_incident_bytes:
            raise ValueError("Incident exceeds persistence limit")
        from uuid import UUID

        UUID(incident.incident_id)
        with self._lock:
            atomic_write(self.directory / f"incident-{incident.incident_id}.json", raw)
            self.prune(now)

    def recovered_fatal_incidents(self, now: datetime) -> tuple[Incident, ...]:
        with self._lock:
            self.prune(now)
            result = []
            for path in self._safe_files("incident-*.json"):
                try:
                    with path.open("rb") as stream:
                        raw = stream.read(self.max_incident_bytes + 1)
                    if len(raw) > self.max_incident_bytes:
                        continue
                    data = json.loads(raw)
                    if data["severity"] != "fatal" or data["schema_version"] != 1:
                        continue
                    build = data["build_info"]
                    build["environment"] = Environment(build["environment"])
                    build["distribution"] = Distribution(build["distribution"])
                    events = []
                    for item in data.pop("events"):
                        item["type"] = EventType(item["type"])
                        item["fields_json"] = encode(item.pop("fields"))
                        events.append(DiagnosticEvent(**item))
                    data.pop("breadcrumb_range", None)
                    data.pop("full_log_range", None)
                    data["severity"] = ErrorSeverity(data["severity"])
                    data["build_info"] = BuildInfo(**build)
                    result.append(Incident(**data, events=tuple(events)))
                except (ValueError, TypeError, KeyError, OSError):
                    continue
            return tuple(sorted(result, key=lambda i: i.timestamp))

    def acknowledge(self, incident_id: str) -> None:
        from uuid import UUID

        UUID(incident_id)
        with self._lock:
            (self.directory / f"incident-{incident_id}.json").unlink(missing_ok=True)

    def purge(self) -> None:
        with self._lock:
            for pattern in ("events-*.jsonl", "incident-*.json"):
                for path in self._safe_files(pattern):
                    path.unlink()

    def close(self) -> None:
        if not self._closed:
            self._closed = True
            self._lockfile.close()
