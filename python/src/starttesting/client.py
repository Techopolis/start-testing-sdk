from __future__ import annotations

import threading
import traceback
from collections import OrderedDict
from collections.abc import Callable
from dataclasses import asdict, dataclass, replace
from datetime import datetime
from pathlib import Path
from uuid import uuid4

from .auth import (
    AuthenticationService,
    AuthorizationError,
    AuthorizationService,
    ProjectService,
    effective_mode,
)
from .diagnostics import DiagnosticStorage, RingBuffer
from .environment import resolve_build
from .models import (
    BuildInfo,
    CapabilitySet,
    DiagnosticEvent,
    DiagnosticSession,
    Distribution,
    Environment,
    ErrorSeverity,
    EventType,
    ExternalFeedback,
    Incident,
    ProjectConfiguration,
    PromptPolicy,
    UserMode,
    encode,
    timestamp,
    utc_now,
)
from .privacy import Redactor


@dataclass(frozen=True)
class Options:
    max_events: int = 1000
    max_buffer_bytes: int = 2_000_000
    max_event_bytes: int = 32_000
    retention_seconds: int = 900
    log_window_seconds: int = 300
    prompt_policy: PromptPolicy = PromptPolicy.ALWAYS
    dedup_seconds: int = 60
    prompt_interval_seconds: int = 10
    full_logs: bool = False
    safe_log_level: EventType = EventType.WARNING
    max_recent_incidents: int = 10

    def __post_init__(self):
        if (
            min(
                self.max_events,
                self.max_buffer_bytes,
                self.max_event_bytes,
                self.retention_seconds,
                self.log_window_seconds,
                self.max_recent_incidents,
            )
            <= 0
        ):
            raise ValueError("Diagnostic limits must be positive")
        if min(self.dedup_seconds, self.prompt_interval_seconds) < 0:
            raise ValueError("Prompt intervals cannot be negative")
        if self.safe_log_level not in {EventType.WARNING, EventType.ERROR, EventType.CRITICAL}:
            raise ValueError("Safe log level must be warning, error, or critical")


class Client:
    def __init__(
        self,
        project_id: str,
        *,
        environment: Environment | str = Environment.AUTO,
        distribution: Distribution | str | None = None,
        metadata_path: Path | None = None,
        build: BuildInfo | None = None,
        options: Options | None = None,
        redactor: Redactor | None = None,
        project_service: ProjectService | None = None,
        authorization_service: AuthorizationService | None = None,
        storage: DiagnosticStorage | None = None,
        clock: Callable[[], datetime] = utc_now,
    ):
        if not project_id or len(project_id) > 200:
            raise ValueError("A public project ID is required")
        self.project_id = project_id
        self.options = options or Options()
        self.redactor = redactor or Redactor()
        raw_build = build or resolve_build(
            environment=environment, distribution=distribution, metadata_path=metadata_path
        )
        self.build = replace(
            raw_build,
            **{
                k: self.redactor.text(v)[:256]
                for k, v in asdict(raw_build).items()
                if isinstance(v, str) and k not in {"environment", "distribution"}
            },
        )
        self.project_service, self.authorization_service = project_service, authorization_service
        self.storage, self.clock = storage, clock
        self.session = DiagnosticSession(started_at=timestamp(clock()))
        self.buffer = RingBuffer(
            self.options.max_events, self.options.max_buffer_bytes, self.options.retention_seconds
        )
        self._lock = threading.RLock()
        self._grant: CapabilitySet | None = None
        self._config = ProjectConfiguration(project_id)
        self._sequence = 0
        self._last_event_time: datetime | None = None
        self._prompted: OrderedDict[str, datetime] = OrderedDict()
        self._last_prompt: datetime | None = None
        self._incidents: OrderedDict[str, Incident] = OrderedDict()
        self.on_incident: Callable[[Incident], None] | None = None
        self.storage_failures = 0
        self.callback_failures = 0
        self.closed = False
        if project_service:
            self.refresh_configuration()

    @property
    def grant(self) -> CapabilitySet | None:
        return self._grant

    @property
    def config(self) -> ProjectConfiguration:
        return self._config

    @property
    def mode(self) -> UserMode:
        return effective_mode(self.build, self.config, self.grant, self.clock())

    @property
    def full_logs_enabled(self) -> bool:
        return (
            self.options.full_logs
            and self.config.full_logs_enabled
            and self.mode == UserMode.AUTHENTICATED_TESTER
            and self.allows("attach_full_logs")
        )

    def allows(self, capability: str) -> bool:
        return self.grant is not None and self.grant.allows(
            capability, self.project_id, self.clock()
        )

    def authenticate(self, service: AuthenticationService) -> None:
        grant = service.authenticate(self.project_id)
        self.set_authorization(grant)

    def set_authorization(self, grant: CapabilitySet) -> None:
        if self.authorization_service is None or self.project_service is None:
            raise AuthorizationError("Configure project and authorization services first")
        validated = self.authorization_service.validate(grant, self.project_id)
        config = self.project_service.configuration(self.project_id, validated)
        if config.project_id != self.project_id:
            raise AuthorizationError("Project configuration mismatch")
        with self._lock:
            if self.grant and self.grant.subject != validated.subject:
                self._clear_context()
            self._grant, self._config = validated, config

    def revalidate(self) -> None:
        if self.grant:
            try:
                if self.authorization_service is None:
                    raise AuthorizationError("No authorization service")
                self.set_authorization(
                    self.authorization_service.validate(self.grant, self.project_id)
                )
            except Exception:
                self.sign_out()
                raise
        else:
            self.refresh_configuration()

    def refresh_configuration(self) -> None:
        if self.project_service:
            config = self.project_service.configuration(self.project_id, self.grant)
            if config.project_id != self.project_id:
                raise AuthorizationError("Project configuration mismatch")
            self._config = config

    def _clear_context(self) -> None:
        self.buffer.clear()
        self._incidents.clear()
        if self.storage:
            try:
                self.storage.purge()
            except OSError:
                self.storage_failures += 1
        self.session = DiagnosticSession(started_at=timestamp(self.clock()))

    def sign_out(self, service: AuthenticationService | None = None) -> None:
        with self._lock:
            grant, self._grant = self._grant, None
            self._config = ProjectConfiguration(self.project_id)
            self._clear_context()
        if service and grant:
            service.sign_out(grant)
        self.refresh_configuration()

    def record(
        self,
        message: str,
        *,
        type: EventType = EventType.INFO,
        category: str = "application",
        fields: dict | None = None,
        screen: str | None = None,
        task_id: str | None = None,
    ) -> DiagnosticEvent | None:
        kind = EventType(type)
        if self.closed or category in self.redactor.suppressed_categories:
            return None
        levels = {
            EventType.DEBUG: 10,
            EventType.INFO: 20,
            EventType.WARNING: 30,
            EventType.ERROR: 40,
            EventType.EXCEPTION: 40,
            EventType.CRITICAL: 50,
        }
        full_only = kind in levels and levels[kind] < levels[self.options.safe_log_level]
        if full_only and not self.full_logs_enabled:
            return None
        with self._lock:
            now = self.clock()
            # Preserve capture order if the system wall clock moves backwards.
            if self._last_event_time and now < self._last_event_time:
                now = self._last_event_time
            self._last_event_time = now
            self._sequence += 1
            event = DiagnosticEvent(
                self._sequence,
                timestamp(now),
                kind,
                self.redactor.text(message)[:8192],
                self.session.session_id,
                self.redactor.text(category)[:128],
                encode(self.redactor.clean(fields or {}, filter_fields=True)),
                threading.get_ident(),
                self.redactor.text(task_id)[:128] if task_id else None,
                self.redactor.text(screen)[:128] if screen else None,
                full_only,
            )
            if len(encode(event.to_dict()).encode()) > self.options.max_event_bytes:
                event = replace(event, message="[event exceeded size limit]", fields_json="{}")
            if not self.buffer.append(event, now):
                return None
            if self.storage:
                try:
                    self.storage.append(event, now)
                except (OSError, ValueError):
                    self.storage_failures += 1
            return event

    def breadcrumb(self, message: str, **kwargs) -> DiagnosticEvent | None:
        return self.record(message, type=EventType.BREADCRUMB, **kwargs)

    def record_exception(
        self,
        error: BaseException,
        *,
        severity: ErrorSeverity = ErrorSeverity.WARNING,
        user_message: str = "",
    ) -> Incident | None:
        severity = ErrorSeverity(severity)
        # Stack frame locations only: no frame locals or source-line literals.
        frames = traceback.extract_tb(error.__traceback__, limit=40)
        stack = "\n".join(f"{Path(f.filename).name}:{f.lineno} in {f.name}" for f in frames)
        try:
            summary = self.redactor.text(str(error))[:8192]
        except Exception:
            summary = "[unavailable exception message]"
        with self._lock:
            self.record(
                summary,
                type=EventType.EXCEPTION,
                fields={"error_type": type(error).__name__, "stack_trace": stack},
            )
            if severity in {ErrorSeverity.INFORMATIONAL, ErrorSeverity.WARNING}:
                return None
            incident = self._freeze(severity, type(error).__name__, user_message, summary, stack)
        if severity != ErrorSeverity.FATAL and self.should_prompt(incident) and self.on_incident:
            try:
                self.on_incident(incident)
            except Exception:
                self.callback_failures += 1
        return incident

    def reportable_error(self, error: BaseException, *, user_message: str = "") -> Incident:
        return self.record_exception(
            error, severity=ErrorSeverity.REPORTABLE, user_message=user_message
        )

    def manual_incident(self) -> Incident:
        with self._lock:
            return self._freeze(ErrorSeverity.INFORMATIONAL, "ManualReport", "", "", "", "manual")

    def _freeze(
        self,
        severity: ErrorSeverity,
        error_type: str,
        safe_message: str,
        summary: str,
        stack: str,
        origin: str = "error",
    ) -> Incident:
        if self.closed:
            raise RuntimeError("Client is closed")
        now = max(self.clock(), self._last_event_time or self.clock())
        incident = Incident(
            str(uuid4()),
            timestamp(now),
            severity,
            self.redactor.text(error_type),
            self.redactor.text(safe_message)[:2000],
            self.redactor.text(summary),
            self.redactor.text(stack),
            self.session.session_id,
            self.build,
            self.buffer.snapshot(now, self.options.log_window_seconds, self.session.session_id),
            origin=origin,
            project_id=self.project_id,
            tester_subject=self.grant.subject
            if self.mode == UserMode.AUTHENTICATED_TESTER
            else None,
        )
        self._incidents[incident.incident_id] = incident
        while len(self._incidents) > self.options.max_recent_incidents:
            self._incidents.popitem(last=False)
        if self.storage:
            try:
                self.storage.save_incident(incident, now)
            except (OSError, ValueError):
                self.storage_failures += 1
        return incident

    def should_prompt(self, incident: Incident) -> bool:
        if self.options.prompt_policy == PromptPolicy.MANUAL_ONLY:
            return False
        if self.options.prompt_policy == PromptPolicy.CRITICAL_ONLY and incident.severity not in {
            ErrorSeverity.CRITICAL,
            ErrorSeverity.FATAL,
        }:
            return False
        if self.mode != UserMode.AUTHENTICATED_TESTER and (
            self.config.external_feedback == ExternalFeedback.DISABLED
        ):
            return False
        if incident.severity in {ErrorSeverity.INFORMATIONAL, ErrorSeverity.WARNING}:
            return False
        import hashlib

        fingerprint = hashlib.sha256(
            (incident.error_type + incident.exception_summary + incident.stack_trace).encode()
        ).hexdigest()
        now = self.clock()
        with self._lock:
            previous = self._prompted.get(fingerprint)
            if previous and (now - previous).total_seconds() < self.options.dedup_seconds:
                return False
            if (
                self._last_prompt
                and (now - self._last_prompt).total_seconds() < self.options.prompt_interval_seconds
            ):
                return False
            self._prompted[fingerprint] = self._last_prompt = now
            while len(self._prompted) > 256:
                self._prompted.popitem(last=False)
            return True

    def recovered_incidents(self) -> tuple[Incident, ...]:
        if not self.storage:
            return ()
        return tuple(
            i
            for i in self.storage.recovered_fatal_incidents(self.clock())
            if i.project_id == self.project_id
        )

    def close(self) -> None:
        self.closed = True
        if self.storage:
            self.storage.close()
