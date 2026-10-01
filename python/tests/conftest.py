from datetime import UTC, datetime, timedelta

import pytest

from starttesting.auth.mock import MockBackend
from starttesting.client import Client, Options
from starttesting.models import Environment
from starttesting.reporting.reporter import Reporter


class Clock:
    def __init__(self):
        self.value = datetime.now(UTC)

    def __call__(self):
        return self.value

    def advance(self, seconds):
        self.value += timedelta(seconds=seconds)


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def rig(clock):
    backend = MockBackend(clock=clock)
    client = Client(
        "proj_demo",
        environment=Environment.BETA,
        project_service=backend,
        authorization_service=backend,
        clock=clock,
        options=Options(full_logs=True),
    )
    client.authenticate(backend)
    reporter = Reporter(client, issues=backend, feedback=backend, attachments=backend)
    yield client, backend, reporter
    client.close()
