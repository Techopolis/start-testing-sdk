"""Optional desktop ChatGPT plan integration. Importing this module does not sign in."""

from .contracts import AIDraft, AIProvider, ChatGPTError, Connection, LoginCancelled
from .drafting import ChatGPTProvider, draft_context, draft_issue
from .oauth import ChatGPTAuth

__all__ = [
    "AIDraft",
    "AIProvider",
    "ChatGPTAuth",
    "ChatGPTError",
    "ChatGPTProvider",
    "Connection",
    "LoginCancelled",
    "draft_context",
    "draft_issue",
]
