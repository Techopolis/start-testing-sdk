from __future__ import annotations

import json
from urllib.parse import urlsplit

from .contracts import ChatGPTError


class OpenAITransport:
    def __init__(self):
        import httpx

        self.http = httpx.Client(
            timeout=httpx.Timeout(30.0, connect=10.0), follow_redirects=False, trust_env=False
        )

    @staticmethod
    def validate_url(url: str) -> None:
        parts = urlsplit(url)
        if (
            parts.scheme != "https"
            or parts.hostname not in {"auth.openai.com", "api.openai.com"}
            or parts.port not in {None, 443}
            or parts.username
            or parts.password
            or parts.fragment
        ):
            raise ChatGPTError("Unexpected OpenAI endpoint")

    @staticmethod
    def check_status(status: int) -> None:
        if status in {401, 403}:
            raise ChatGPTError("ChatGPT permission expired or was revoked. Connect again.")
        if status == 429:
            raise ChatGPTError("ChatGPT usage limit reached. Manage usage or report manually.")
        if not 200 <= status < 300:
            raise ChatGPTError("OpenAI request failed. Try again or report manually.")

    def request(
        self, method: str, url: str, *, form: dict | None = None, token: str | None = None
    ) -> dict:
        self.validate_url(url)
        headers = {"Authorization": f"Bearer {token}"} if token else {}
        try:
            with self.http.stream(method, url, data=form, headers=headers) as response:
                self.check_status(response.status_code)
                raw = bytearray()
                for chunk in response.iter_bytes():
                    raw.extend(chunk)
                    if len(raw) > 1_000_000:
                        raise ChatGPTError("OpenAI response exceeded the size limit")
            value = json.loads(raw) if raw else {}
            if not isinstance(value, dict):
                raise ChatGPTError("OpenAI returned an invalid response")
            return value
        except ChatGPTError:
            raise
        except Exception:
            raise ChatGPTError(
                "OpenAI connection failed. Manual reporting remains available."
            ) from None

    def events(self, url: str, token: str, payload: dict):
        self.validate_url(url)
        try:
            with self.http.stream(
                "POST",
                url,
                json=payload,
                headers={"Authorization": f"Bearer {token}", "Accept": "text/event-stream"},
            ) as response:
                self.check_status(response.status_code)
                buffer = bytearray()
                total = 0
                data = []
                for chunk in response.iter_bytes():
                    total += len(chunk)
                    if total > 2_000_000:
                        raise ChatGPTError("ChatGPT stream exceeded the size limit")
                    buffer.extend(chunk)
                    while b"\n" in buffer:
                        line, _, remainder = buffer.partition(b"\n")
                        buffer = bytearray(remainder)
                        line = line.rstrip(b"\r").decode("utf-8")
                        if line.startswith("data:"):
                            data.append(line[5:].lstrip())
                        elif not line and data:
                            body = "\n".join(data)
                            data.clear()
                            if body != "[DONE]":
                                yield json.loads(body)
        except ChatGPTError:
            raise
        except Exception:
            raise ChatGPTError(
                "ChatGPT stream was interrupted. Try again or report manually."
            ) from None

    def close(self) -> None:
        self.http.close()
