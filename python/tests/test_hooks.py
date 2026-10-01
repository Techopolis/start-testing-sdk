import asyncio
import sys
import threading
from types import SimpleNamespace

from starttesting.integrations.exceptions import install_exception_hooks


def test_hooks_chain_and_restore(rig, monkeypatch):
    client, _, _ = rig
    calls = []

    def previous_sys(*args):
        calls.append("sys")

    def previous_thread(*args):
        calls.append("thread")

    monkeypatch.setattr(sys, "excepthook", previous_sys)
    monkeypatch.setattr(threading, "excepthook", previous_thread)
    loop = asyncio.new_event_loop()
    loop.set_exception_handler(lambda *args: calls.append("asyncio"))
    previous_asyncio = loop.get_exception_handler()
    hooks = install_exception_hooks(client, loop=loop)
    try:
        error = ValueError("test")
        sys.excepthook(ValueError, error, None)
        threading.excepthook(
            SimpleNamespace(exc_type=ValueError, exc_value=error, exc_traceback=None)
        )
        loop.call_exception_handler({"exception": error})
        assert calls == ["sys", "thread", "asyncio"]
        hooks.uninstall()
        assert sys.excepthook is previous_sys
        assert threading.excepthook is previous_thread
        assert loop.get_exception_handler() is previous_asyncio
    finally:
        hooks.uninstall()
        loop.close()


def test_hooks_do_not_clobber_later_handlers(rig, monkeypatch):
    client, _, _ = rig
    old = sys.excepthook
    monkeypatch.setattr(sys, "excepthook", old)
    hooks = install_exception_hooks(client)

    def newer(*args):
        pass

    sys.excepthook = newer
    hooks.uninstall()
    assert sys.excepthook is newer
