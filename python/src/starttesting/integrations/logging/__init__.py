from __future__ import annotations

import logging
import threading
import traceback
from pathlib import Path

from ...client import Client
from ...models import EventType


class StartTestingLogHandler(logging.Handler):
    def __init__(self, client: Client | None = None, level: int = logging.WARNING):
        super().__init__(level)
        if client is None:
            from ... import get_client

            client = get_client()
        self.client = client
        self._active = threading.local()

    def emit(self, record: logging.LogRecord) -> None:
        if getattr(self._active, "value", False):
            return
        self._active.value = True
        try:
            kind = (
                EventType.CRITICAL
                if record.levelno >= logging.CRITICAL
                else EventType.ERROR
                if record.levelno >= logging.ERROR
                else EventType.WARNING
                if record.levelno >= logging.WARNING
                else EventType.INFO
                if record.levelno >= logging.INFO
                else EventType.DEBUG
            )
            fields = dict(getattr(record, "starttesting_fields", {}) or {})
            if record.exc_info:
                frames = traceback.extract_tb(record.exc_info[2], limit=40)
                fields["stack_trace"] = "\n".join(
                    f"{Path(f.filename).name}:{f.lineno} in {f.name}" for f in frames
                )
                fields["exception"] = str(record.exc_info[1])
            self.client.record(record.getMessage(), type=kind, category=record.name, fields=fields)
        except Exception:
            # logging.handleError may print the original record and leak secrets.
            pass
        finally:
            self._active.value = False
