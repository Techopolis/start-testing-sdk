from __future__ import annotations

import asyncio
import sys
import threading
from collections.abc import Callable
from dataclasses import dataclass

from ..client import Client
from ..models import ErrorSeverity


@dataclass
class ExceptionHooks:
    previous_sys: Callable
    previous_thread: Callable
    sys_handler: Callable
    thread_handler: Callable
    loop: asyncio.AbstractEventLoop | None = None
    previous_asyncio: Callable | None = None
    asyncio_handler: Callable | None = None

    def uninstall(self) -> None:
        # Never overwrite a newer handler installed by the host application.
        if sys.excepthook is self.sys_handler:
            sys.excepthook = self.previous_sys
        if threading.excepthook is self.thread_handler:
            threading.excepthook = self.previous_thread
        if self.loop and self.loop.get_exception_handler() is self.asyncio_handler:
            self.loop.set_exception_handler(self.previous_asyncio)


def install_exception_hooks(
    client: Client, *, loop: asyncio.AbstractEventLoop | None = None
) -> ExceptionHooks:
    previous_sys, previous_thread = sys.excepthook, threading.excepthook

    def sys_handler(kind, error, tb):
        try:
            if not issubclass(kind, (KeyboardInterrupt, SystemExit)):
                client.record_exception(error, severity=ErrorSeverity.FATAL)
        except Exception:
            pass
        finally:
            previous_sys(kind, error, tb)

    def thread_handler(args):
        try:
            if not issubclass(args.exc_type, (KeyboardInterrupt, SystemExit)):
                # A failed worker thread is not necessarily a process crash.
                client.record_exception(args.exc_value, severity=ErrorSeverity.REPORTABLE)
        except Exception:
            pass
        finally:
            previous_thread(args)

    hooks = ExceptionHooks(previous_sys, previous_thread, sys_handler, thread_handler, loop)
    sys.excepthook, threading.excepthook = sys_handler, thread_handler
    if loop:
        previous = loop.get_exception_handler()

        def asyncio_handler(event_loop, context):
            try:
                error = context.get("exception")
                if isinstance(error, BaseException):
                    client.record_exception(error, severity=ErrorSeverity.REPORTABLE)
                else:
                    client.record_exception(
                        RuntimeError("Unhandled asyncio error"), severity=ErrorSeverity.REPORTABLE
                    )
            except Exception:
                pass
            finally:
                if previous:
                    previous(event_loop, context)
                else:
                    event_loop.default_exception_handler(context)

        hooks.previous_asyncio, hooks.asyncio_handler = previous, asyncio_handler
        loop.set_exception_handler(asyncio_handler)
    return hooks
