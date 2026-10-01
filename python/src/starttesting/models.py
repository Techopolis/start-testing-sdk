"""Versioned, immutable diagnostic contracts shared by platform adapters."""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime
from enum import StrEnum
from uuid import uuid4

SDK_VERSION = "0.1.0a1"
SCHEMA_VERSION = 1


def utc_now() -> datetime:
    return datetime.now(UTC)


def timestamp(value: datetime) -> str:
    if value.tzinfo is None:
        raise ValueError("Timestamps must include a timezone")
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


def encode(value: object) -> str:
    return json.dumps(
        value, ensure_ascii=True, sort_keys=True, separators=(",", ":"), allow_nan=False
    )


class Environment(StrEnum):
    DEVELOPMENT = "development"
    BETA = "beta"
    PRODUCTION = "production"
    UNKNOWN = "unknown"
    AUTO = "auto"


class Distribution(StrEnum):
    XCODE = "xcode"
    TESTFLIGHT = "testflight"
    APP_STORE = "app_store"
    DIRECT = "direct"
    DEBUG = "debug"
    GITHUB_PRERELEASE = "github_prerelease"
    GITHUB_RELEASE = "github_release"
    MSIX = "msix"
    MSIX_FLIGHT = "msix_flight"
    MICROSOFT_STORE = "microsoft_store"
    ENTERPRISE = "enterprise"
    UNPACKAGED = "unpackaged"
    SOURCE = "source"
    VIRTUALENV = "virtualenv"
    PIP = "pip"
    PYINSTALLER = "pyinstaller"
    STANDALONE_BUNDLE = "standalone_bundle"
    UNKNOWN = "unknown"


class EventType(StrEnum):
    BREADCRUMB = "breadcrumb"
    DEBUG = "debug"
    INFO = "info"
    WARNING = "warning"
    ERROR = "error"
    CRITICAL = "critical"
    EXCEPTION = "exception"
    CUSTOM = "custom"


class ErrorSeverity(StrEnum):
    INFORMATIONAL = "informational"
    WARNING = "warning"
    REPORTABLE = "reportable"
    CRITICAL = "critical"
    FATAL = "fatal"


class UserMode(StrEnum):
    AUTHENTICATED_TESTER = "authenticated_tester"
    BETA_FEEDBACK = "beta_feedback"
    PRODUCTION_SUPPORT = "production_support"


class ExternalFeedback(StrEnum):
    DISABLED = "disabled"
    ERRORS_ONLY = "errors_only"
    MANUAL_AND_ERRORS = "manual_and_errors"


class PromptPolicy(StrEnum):
    ALWAYS = "always"
    CRITICAL_ONLY = "critical_only"
    MANUAL_ONLY = "manual_only"


@dataclass(frozen=True)
class BuildInfo:
    environment: Environment = Environment.UNKNOWN
    distribution: Distribution = Distribution.UNKNOWN
    version: str = "unknown"
    build: str = "unknown"
    commit: str = ""
    os: str = "unknown"
    os_version: str = "unknown"
    architecture: str = "unknown"
    device_model: str = "unknown"
    sdk_version: str = SDK_VERSION


@dataclass(frozen=True)
class DiagnosticSession:
    session_id: str = field(default_factory=lambda: str(uuid4()))
    started_at: str = field(default_factory=lambda: timestamp(utc_now()))


@dataclass(frozen=True)
class DiagnosticEvent:
    sequence: int
    timestamp: str
    type: EventType
    message: str
    session_id: str
    category: str = "application"
    fields_json: str = "{}"
    thread_id: int | None = None
    task_id: str | None = None
    screen: str | None = None
    full_only: bool = False

    def to_dict(self) -> dict:
        result = asdict(self)
        result["fields"] = json.loads(result.pop("fields_json"))
        return result


@dataclass(frozen=True)
class Incident:
    incident_id: str
    timestamp: str
    severity: ErrorSeverity
    error_type: str
    safe_message: str
    exception_summary: str
    stack_trace: str
    session_id: str
    build_info: BuildInfo
    events: tuple[DiagnosticEvent, ...]
    origin: str = "error"
    report_status: str = "captured"
    schema_version: int = SCHEMA_VERSION
    project_id: str = ""
    tester_subject: str | None = None

    def to_dict(self) -> dict:
        data = asdict(self)
        data.pop("events")
        data["breadcrumb_range"] = self._range(EventType.BREADCRUMB)
        data["full_log_range"] = self._range()
        return data

    def _range(self, kind: EventType | None = None) -> list[int]:
        seq = [e.sequence for e in self.events if kind is None or e.type == kind]
        return [seq[0], seq[-1]] if seq else []


@dataclass(frozen=True)
class CapabilitySet:
    """Server-issued UI hints. The service must independently enforce every action."""

    project_id: str
    subject: str
    expires_at: datetime
    capabilities: frozenset[str]
    grant_id: str

    def allows(self, name: str, project_id: str, now: datetime) -> bool:
        return (
            self.project_id == project_id
            and bool(self.subject)
            and self.expires_at > now
            and name in self.capabilities
        )


@dataclass(frozen=True)
class FieldDefinition:
    key: str
    label: str
    capability: str
    choices: tuple[str, ...] = ()


@dataclass(frozen=True)
class ProjectConfiguration:
    project_id: str
    external_feedback: ExternalFeedback = ExternalFeedback.DISABLED
    tester_environments: frozenset[Environment] = frozenset(
        {Environment.DEVELOPMENT, Environment.BETA}
    )
    full_logs_enabled: bool = False
    fields: tuple[FieldDefinition, ...] = ()


@dataclass(frozen=True)
class IssueDraft:
    title: str = ""
    description: str = ""
    expected_behavior: str = ""
    actual_behavior: str = ""
    steps_to_reproduce: str = ""
    metadata_json: str = "{}"

    def to_dict(self) -> dict:
        data = asdict(self)
        data["metadata"] = json.loads(data.pop("metadata_json"))
        return data


@dataclass(frozen=True)
class AIDraft:
    title: str
    summary: str
    observed_behavior: str
    expected_behavior: str
    reproduction_context: str
    relevant_diagnostics: str
    possible_hypothesis: str

    def as_issue_draft(self) -> IssueDraft:
        description = (
            f"{self.summary}\n\nRelevant diagnostics:\n{self.relevant_diagnostics}"
            f"\n\nHypothesis (unverified):\n{self.possible_hypothesis}"
        )
        return IssueDraft(
            self.title,
            description,
            self.expected_behavior,
            self.observed_behavior,
            self.reproduction_context,
        )
