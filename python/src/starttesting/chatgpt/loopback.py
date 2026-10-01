from __future__ import annotations

import hmac
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit

from .contracts import ChatGPTError, LoginCancelled


class LoopbackCallback:
    """Bound before browser launch; exact host/path, state validation, one callback."""

    def __init__(self, state: str):
        self.state = state
        self.result = None
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                parts = urlsplit(self.path)
                if (
                    len(self.path) > 16_384
                    or parts.path != "/auth/callback"
                    or self.headers.get("Host") != f"127.0.0.1:{owner.port}"
                ):
                    self.send_error(400)
                    return
                try:
                    query = parse_qs(parts.query, keep_blank_values=True, max_num_fields=20)
                    if any(len(v) != 1 for v in query.values()):
                        raise ValueError("Repeated callback parameters")
                    params = {key: value[0] for key, value in query.items()}
                    if not hmac.compare_digest(params.get("state", ""), owner.state):
                        raise ValueError("Invalid state")
                    if owner.result is not None:
                        raise ValueError("Callback already consumed")
                except ValueError:
                    self.send_error(400)
                    return
                owner.result = params
                body = b"You can close this window and return to the application."
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("Referrer-Policy", "no-referrer")
                self.send_header("Content-Security-Policy", "default-src 'none'")
                self.end_headers()
                self.wfile.write(body)

        class Server(HTTPServer):
            def get_request(self):
                connection, address = super().get_request()
                connection.settimeout(1)
                return connection, address

            def handle_error(self, request, client_address):
                pass

        self.server = Server(("127.0.0.1", 0), Handler)
        self.server.timeout = 0.25
        self.port = self.server.server_port
        self.redirect_uri = f"http://127.0.0.1:{self.port}/auth/callback"

    def wait(self, *, timeout: float = 180, cancel: threading.Event | None = None) -> dict:
        deadline = time.monotonic() + timeout
        while self.result is None:
            if cancel and cancel.is_set():
                raise LoginCancelled("ChatGPT sign-in cancelled")
            if time.monotonic() >= deadline:
                raise ChatGPTError("ChatGPT sign-in timed out")
            self.server.handle_request()
        return self.result

    def close(self) -> None:
        self.server.server_close()
