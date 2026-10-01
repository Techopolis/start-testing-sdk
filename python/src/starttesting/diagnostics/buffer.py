from __future__ import annotations

import threading
from collections import deque
from datetime import datetime, timedelta

from ..models import DiagnosticEvent, encode, timestamp


class RingBuffer:
    """Bounded by count, serialized bytes, and time. Snapshots are immutable."""

    def __init__(
        self, max_events: int = 1000, max_bytes: int = 2_000_000, retention_seconds: int = 900
    ):
        if min(max_events, max_bytes, retention_seconds) <= 0:
            raise ValueError("Buffer limits must be positive")
        self.max_events, self.max_bytes = max_events, max_bytes
        self.retention_seconds = retention_seconds
        self._events: deque[tuple[DiagnosticEvent, int]] = deque()
        self._bytes = 0
        self._lock = threading.RLock()
        self.dropped = 0

    def append(self, event: DiagnosticEvent, now: datetime) -> bool:
        size = len(encode(event.to_dict()).encode())
        with self._lock:
            self._prune(now)
            if size > self.max_bytes:
                self.dropped += 1
                return False
            self._events.append((event, size))
            self._bytes += size
            while len(self._events) > self.max_events or self._bytes > self.max_bytes:
                self._evict()
            return True

    def _evict(self) -> None:
        _, size = self._events.popleft()
        self._bytes -= size
        self.dropped += 1

    def _prune(self, now: datetime) -> None:
        cutoff = timestamp(now - timedelta(seconds=self.retention_seconds))
        while self._events and self._events[0][0].timestamp < cutoff:
            self._evict()

    def snapshot(
        self, now: datetime, window_seconds: int, session_id: str
    ) -> tuple[DiagnosticEvent, ...]:
        with self._lock:
            self._prune(now)
            cutoff = timestamp(now - timedelta(seconds=window_seconds))
            end = timestamp(now)
            return tuple(
                e
                for e, _ in self._events
                if cutoff <= e.timestamp <= end and e.session_id == session_id
            )

    def clear(self) -> None:
        with self._lock:
            self._events.clear()
            self._bytes = 0

    @property
    def byte_size(self) -> int:
        with self._lock:
            return self._bytes
