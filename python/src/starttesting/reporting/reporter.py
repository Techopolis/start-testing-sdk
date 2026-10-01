from __future__ import annotations

import hashlib
import json
import threading
from dataclasses import dataclass, replace
from uuid import uuid4

from ..auth import AuthorizationError
from ..client import Client
from ..models import ExternalFeedback, Incident, IssueDraft, UserMode, encode
from .bundle import DiagnosticBundle
from .services import (
    AttachmentService,
    FeedbackService,
    IssueService,
    ReportReference,
    SubmissionResult,
    Upload,
)


@dataclass(frozen=True)
class PreparedReport:
    request_id: str
    incident: Incident
    draft: IssueDraft
    mode: UserMode
    subject: str | None
    bundle: DiagnosticBundle | None
    attachments: tuple[Upload, ...]

    @property
    def fingerprint(self) -> str:
        data = {
            "request_id": self.request_id,
            "draft": self.draft.to_dict(),
            "mode": self.mode,
            "subject": self.subject,
            "incident_id": self.incident.incident_id,
            "files": [
                {
                    "name": u.name,
                    "description": u.accessible_description,
                    "type": u.content_type,
                    "capability": u.required_capability,
                    "digest": hashlib.sha256(u.data).hexdigest(),
                }
                for u in self.uploads
            ],
        }
        return hashlib.sha256(encode(data).encode()).hexdigest()

    @property
    def uploads(self) -> tuple[Upload, ...]:
        return (self.bundle.uploads if self.bundle else ()) + self.attachments


@dataclass(frozen=True)
class ReviewApproval:
    fingerprint: str


class Reporter:
    def __init__(
        self,
        client: Client,
        *,
        issues: IssueService,
        feedback: FeedbackService,
        attachments: AttachmentService,
    ):
        self.client = client
        self.issues, self.feedback, self.attachments = issues, feedback, attachments
        self._lock = threading.RLock()
        self._progress: dict[str, tuple[str, ReportReference, set[str]]] = {}

    def prepare(
        self,
        draft: IssueDraft,
        *,
        incident: Incident | None = None,
        diagnostic_consent: bool = False,
        attachments: tuple[Upload, ...] = (),
    ) -> PreparedReport:
        client = self.client
        client.revalidate()
        incident = incident or client.manual_incident()
        if incident.project_id != client.project_id:
            raise AuthorizationError("Incident belongs to another project")
        mode = client.mode
        subject = client.grant.subject if mode == UserMode.AUTHENTICATED_TESTER else None
        if mode == UserMode.AUTHENTICATED_TESTER:
            if incident.tester_subject is not None and incident.tester_subject != subject:
                raise AuthorizationError("Incident belongs to another tester")
            fields = {f.key: f for f in client.config.fields}
            metadata = json.loads(draft.metadata_json)
            if not isinstance(metadata, dict):
                raise ValueError("Issue metadata must be an object")
            for key, value in metadata.items():
                if key not in fields or not client.allows(fields[key].capability):
                    raise AuthorizationError("Issue field is not permitted")
                if fields[key].choices and value not in fields[key].choices:
                    raise ValueError("Issue field choice is invalid")
            if not draft.title.strip():
                raise ValueError("Issue title is required")
            if attachments and not client.allows("attach_files"):
                raise AuthorizationError("File attachments are not permitted")
            bundle = None
            if diagnostic_consent:
                if not client.allows("attach_diagnostics"):
                    raise AuthorizationError("Diagnostic attachments are not permitted")
                bundle = DiagnosticBundle.from_incident(
                    incident,
                    client.redactor,
                    full_logs=client.full_logs_enabled and incident.tester_subject == subject,
                )
        else:
            policy = client.config.external_feedback
            if policy == ExternalFeedback.DISABLED or (
                policy == ExternalFeedback.ERRORS_ONLY and incident.origin == "manual"
            ):
                raise AuthorizationError("This feedback workflow is disabled")
            # Public feedback cannot carry internal metadata, title, or arbitrary files.
            draft = IssueDraft(description=draft.description)
            if attachments:
                raise AuthorizationError("External attachments are not enabled in this adapter")
            bundle = (
                DiagnosticBundle.from_incident(
                    incident, client.redactor, full_logs=False, restricted=True
                )
                if diagnostic_consent
                else None
            )
        if not draft.description.strip():
            raise ValueError("Describe what happened")
        clean = client.redactor.clean(draft.to_dict())
        clean["metadata_json"] = encode(clean.pop("metadata"))
        draft = IssueDraft(**clean)
        if len(attachments) > 5 or sum(len(u.data) for u in attachments) > 10_000_000:
            raise ValueError("Attachment count or combined size exceeds limit")
        return PreparedReport(str(uuid4()), incident, draft, mode, subject, bundle, attachments)

    @staticmethod
    def approve(report: PreparedReport) -> ReviewApproval:
        """Call from the user's explicit Submit action after showing this exact report."""
        return ReviewApproval(report.fingerprint)

    def _sanitize_upload(self, upload: Upload) -> Upload:
        redactor = self.client.redactor
        data = upload.data
        if upload.content_type == "application/json":
            data = encode(redactor.clean(json.loads(data))).encode()
        elif upload.content_type == "application/x-ndjson" or upload.name == "dev-logs.txt":
            data = b"".join(
                encode(redactor.clean(json.loads(line))).encode() + b"\n"
                for line in data.splitlines()
                if line
            )
            if upload.name == "dev-logs.txt":
                data = data.rstrip(b"\n")
        elif upload.content_type.startswith("text/"):
            data = redactor.text(data.decode("utf-8")).encode()
        return replace(
            upload,
            name=redactor.text(upload.name),
            data=data,
            accessible_description=redactor.text(upload.accessible_description),
        )

    def submit(self, report: PreparedReport, approval: ReviewApproval) -> SubmissionResult:
        if approval.fingerprint != report.fingerprint:
            raise ValueError("Report changed after review; review it again")
        with self._lock:
            return self._submit(report)

    def _submit(self, report: PreparedReport) -> SubmissionResult:
        client = self.client
        client.revalidate()
        if client.mode != report.mode or (
            report.subject is not None
            and (not client.grant or client.grant.subject != report.subject)
        ):
            raise AuthorizationError("Authorization changed; reopen the reporter")
        # Rebuild at the final boundary. New privacy rules require a new preview/review.
        sanitized = tuple(self._sanitize_upload(u) for u in report.uploads)
        draft = client.redactor.clean(report.draft.to_dict())
        if sanitized != report.uploads or draft != report.draft.to_dict():
            raise ValueError("Privacy rules changed; reopen and review the sanitized report")
        if report.mode == UserMode.AUTHENTICATED_TESTER:
            for upload in report.uploads:
                if not client.allows(upload.required_capability):
                    raise AuthorizationError("Attachment permission changed; reopen the reporter")
            if (
                report.bundle
                and any(u.required_capability == "attach_full_logs" for u in report.bundle.uploads)
                and not client.full_logs_enabled
            ):
                raise AuthorizationError("Full log policy changed; reopen the reporter")
        elif client.config.external_feedback == ExternalFeedback.DISABLED or (
            client.config.external_feedback == ExternalFeedback.ERRORS_ONLY
            and report.incident.origin == "manual"
        ):
            raise AuthorizationError("External feedback policy changed")
        if report.request_id not in self._progress:
            if len(self._progress) >= 100:
                raise RuntimeError("Reporter submission limit reached; create a new Reporter")
            if report.mode == UserMode.AUTHENTICATED_TESTER:
                ref = self.issues.create_issue(
                    client.project_id, client.grant, report.draft, report.request_id
                )
            else:
                ref = self.feedback.submit_feedback(
                    client.project_id,
                    report.draft.description,
                    origin=report.incident.origin,
                    environment=client.build.environment.value,
                    idempotency_key=report.request_id,
                )
            self._progress[report.request_id] = (report.fingerprint, ref, set())
        fingerprint, ref, completed = self._progress[report.request_id]
        if fingerprint != report.fingerprint:
            raise ValueError("Cannot edit a partially submitted report; retry the original")
        pending = []
        for index, upload in enumerate(report.uploads):
            key = f"{report.request_id}:{index}:{hashlib.sha256(upload.data).hexdigest()}"
            if key in completed:
                continue
            named = replace(upload, name=f"{ref.report_id}-{upload.name}")
            try:
                # The real service must authorize ownership and size/type on every upload.
                self.attachments.attach(client.project_id, client.grant, ref, named, key)
            except (OSError, TimeoutError, AuthorizationError):
                pending.append(named.name)
            else:
                completed.add(key)
        attached = tuple(
            f"{ref.report_id}-{u.name}"
            for u in report.uploads
            if f"{ref.report_id}-{u.name}" not in pending
        )
        if not pending and client.storage:
            client.storage.acknowledge(report.incident.incident_id)
        return SubmissionResult(ref, attached, tuple(pending))
