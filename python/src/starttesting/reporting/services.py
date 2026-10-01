"""Proposed SDK transport contract, not a claim about production endpoints."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from ..models import CapabilitySet, IssueDraft


@dataclass(frozen=True)
class ReportReference:
    report_id: str
    kind: str  # issue or feedback


@dataclass(frozen=True)
class Upload:
    name: str
    content_type: str
    data: bytes
    accessible_description: str
    required_capability: str = "attach_diagnostics"


class IssueService(Protocol):
    def create_issue(
        self, project_id: str, grant: CapabilitySet, draft: IssueDraft, idempotency_key: str
    ) -> ReportReference: ...


class FeedbackService(Protocol):
    def submit_feedback(
        self,
        project_id: str,
        description: str,
        *,
        origin: str,
        environment: str,
        idempotency_key: str,
    ) -> ReportReference: ...


class AttachmentService(Protocol):
    def attach(
        self,
        project_id: str,
        grant: CapabilitySet | None,
        report: ReportReference,
        upload: Upload,
        idempotency_key: str,
    ) -> str: ...


@dataclass(frozen=True)
class SubmissionResult:
    report: ReportReference
    attached: tuple[str, ...]
    pending: tuple[str, ...]

    @property
    def complete(self) -> bool:
        return not self.pending
