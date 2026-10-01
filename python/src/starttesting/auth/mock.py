"""Explicit local demo backend. Never use as a production authorization authority."""

from __future__ import annotations

import hashlib
import threading
from dataclasses import replace
from datetime import timedelta
from uuid import uuid4

from ..models import (
    CapabilitySet,
    Environment,
    ExternalFeedback,
    FieldDefinition,
    IssueDraft,
    ProjectConfiguration,
    utc_now,
)
from ..reporting.services import ReportReference, Upload
from . import AuthorizationError


class MockBackend:
    def __init__(
        self,
        project_id: str = "proj_demo",
        *,
        clock=utc_now,
        external_feedback: ExternalFeedback = ExternalFeedback.MANUAL_AND_ERRORS,
    ):
        self.clock = clock
        self.project_id = project_id
        self.policy = ProjectConfiguration(
            project_id,
            external_feedback,
            full_logs_enabled=True,
            fields=(
                FieldDefinition(
                    "severity", "Severity", "set_severity", ("low", "medium", "high", "critical")
                ),
                FieldDefinition(
                    "priority", "Priority", "set_priority", ("low", "medium", "high", "urgent")
                ),
                FieldDefinition("milestone", "Milestone", "select_milestone", ("Beta 1",)),
                FieldDefinition("labels", "Labels", "add_labels", ("regression", "ui")),
                FieldDefinition("component", "Component", "set_component", ("settings",)),
                FieldDefinition(
                    "testing_session", "Testing Session", "view_testing_session", ("Demo session",)
                ),
            ),
        )
        self._grants: dict[str, CapabilitySet] = {}
        self.issues: dict[str, dict] = {}
        self.feedback: dict[str, dict] = {}
        self.attachments: dict[str, dict[str, Upload]] = {}
        self._requests: dict[str, tuple[str, ReportReference]] = {}
        self.fail_attachments: set[str] = set()
        self._lock = threading.RLock()

    def authenticate(
        self,
        project_id: str,
        *,
        subject: str = "mock-tester",
        authorized: bool = True,
        capabilities: frozenset[str] | None = None,
        ttl_seconds: int = 900,
    ) -> CapabilitySet:
        if project_id != self.project_id or not authorized:
            raise AuthorizationError("Mock account does not have project access")
        caps = (
            capabilities
            if capabilities is not None
            else frozenset(
                {
                    "create_issue",
                    "attach_diagnostics",
                    "attach_full_logs",
                    "attach_files",
                    "set_priority",
                    "set_severity",
                    "select_milestone",
                    "add_labels",
                    "set_component",
                    "view_testing_session",
                    "use_ai",
                    "submit_feedback",
                }
            )
        )
        grant = CapabilitySet(
            project_id, subject, self.clock() + timedelta(seconds=ttl_seconds), caps, str(uuid4())
        )
        with self._lock:
            self._grants[grant.grant_id] = grant
        return grant

    def validate(self, grant: CapabilitySet, project_id: str) -> CapabilitySet:
        with self._lock:
            stored = self._grants.get(grant.grant_id)
            if (
                stored is None
                or stored != grant
                or stored.project_id != project_id
                or stored.expires_at <= self.clock()
            ):
                raise AuthorizationError("Tester authorization expired or was revoked")
            return stored

    def _require(
        self, grant: CapabilitySet | None, project_id: str, capability: str
    ) -> CapabilitySet:
        if grant is None:
            raise AuthorizationError("Tester sign-in required")
        current = self.validate(grant, project_id)
        if not current.allows(capability, project_id, self.clock()):
            raise AuthorizationError(f"Missing capability: {capability}")
        return current

    def sign_out(self, grant: CapabilitySet) -> None:
        with self._lock:
            self._grants.pop(grant.grant_id, None)

    revoke = sign_out

    def configuration(
        self, project_id: str, grant: CapabilitySet | None = None
    ) -> ProjectConfiguration:
        if project_id != self.project_id:
            raise AuthorizationError("Unknown project")
        if grant:
            self._require(grant, project_id, "create_issue")
            fields = tuple(f for f in self.policy.fields if f.capability in grant.capabilities)
            return replace(self.policy, fields=fields)
        return replace(self.policy, fields=(), full_logs_enabled=False)

    def sessions(self, project_id: str, grant: CapabilitySet) -> tuple[str, ...]:
        self._require(grant, project_id, "view_testing_session")
        return ("Demo session",)

    def create_issue(
        self, project_id: str, grant: CapabilitySet, draft: IssueDraft, idempotency_key: str
    ) -> ReportReference:
        import json

        self._require(grant, project_id, "create_issue")
        definitions = {f.key: f for f in self.policy.fields}
        for key, value in json.loads(draft.metadata_json).items():
            if key not in definitions:
                raise ValueError("Unsupported issue field")
            definition = definitions[key]
            self._require(grant, project_id, definition.capability)
            if definition.choices and value not in definition.choices:
                raise ValueError("Unsupported field choice")
        with self._lock:
            if idempotency_key in self._requests:
                owner, ref = self._requests[idempotency_key]
                if owner != grant.subject:
                    raise AuthorizationError("Report belongs to another tester")
                return ref
            ref = ReportReference(f"ST-{len(self.issues) + 1}", "issue")
            self.issues[ref.report_id] = {
                "project_id": project_id,
                "subject": grant.subject,
                "draft": draft.to_dict(),
            }
            self._requests[idempotency_key] = (grant.subject, ref)
            self.attachments[ref.report_id] = {}
            return ref

    def submit_feedback(
        self,
        project_id: str,
        description: str,
        *,
        origin: str,
        environment: str,
        idempotency_key: str,
    ) -> ReportReference:
        if (
            project_id != self.project_id
            or self.policy.external_feedback == ExternalFeedback.DISABLED
        ):
            raise AuthorizationError("External feedback is disabled")
        if origin == "manual" and self.policy.external_feedback == ExternalFeedback.ERRORS_ONLY:
            raise AuthorizationError("Only incident feedback is enabled")
        Environment(environment)
        with self._lock:
            if idempotency_key in self._requests:
                owner, ref = self._requests[idempotency_key]
                if owner != "anonymous":
                    raise AuthorizationError("Invalid feedback request")
                return ref
            ref = ReportReference(f"FB-{len(self.feedback) + 1}", "feedback")
            self.feedback[ref.report_id] = {
                "description": description,
                "origin": origin,
                "environment": environment,
            }
            self._requests[idempotency_key] = ("anonymous", ref)
            self.attachments[ref.report_id] = {}
            return ref

    def attach(
        self,
        project_id: str,
        grant: CapabilitySet | None,
        report: ReportReference,
        upload: Upload,
        idempotency_key: str,
    ) -> str:
        if project_id != self.project_id:
            raise AuthorizationError("Wrong project")
        with self._lock:
            if report.kind == "issue":
                self._require(grant, project_id, upload.required_capability)
                if report.report_id not in self.issues or (
                    self.issues[report.report_id]["subject"] != grant.subject
                ):
                    raise AuthorizationError("Report belongs to another tester")
            elif report.report_id not in self.feedback:
                raise AuthorizationError("Unknown feedback receipt")
            if upload.name in self.fail_attachments:
                raise OSError("Simulated upload failure")
            key = hashlib.sha256(idempotency_key.encode()).hexdigest()
            self.attachments[report.report_id][key] = upload
            return key
