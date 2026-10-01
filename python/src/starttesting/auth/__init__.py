from __future__ import annotations

from datetime import datetime
from typing import Protocol

from ..models import BuildInfo, CapabilitySet, Environment, ProjectConfiguration, UserMode


class AuthorizationError(PermissionError):
    pass


class AuthenticationService(Protocol):
    def authenticate(self, project_id: str) -> CapabilitySet: ...
    def sign_out(self, grant: CapabilitySet) -> None: ...


class AuthorizationService(Protocol):
    def validate(self, grant: CapabilitySet, project_id: str) -> CapabilitySet: ...


class ProjectService(Protocol):
    def configuration(
        self, project_id: str, grant: CapabilitySet | None
    ) -> ProjectConfiguration: ...


class SessionService(Protocol):
    def sessions(self, project_id: str, grant: CapabilitySet) -> tuple[str, ...]: ...


def effective_mode(
    build: BuildInfo, config: ProjectConfiguration, grant: CapabilitySet | None, now: datetime
) -> UserMode:
    if (
        build.environment in config.tester_environments
        and grant is not None
        and grant.allows("create_issue", config.project_id, now)
    ):
        return UserMode.AUTHENTICATED_TESTER
    if build.environment in {Environment.BETA, Environment.DEVELOPMENT}:
        return UserMode.BETA_FEEDBACK
    return UserMode.PRODUCTION_SUPPORT
