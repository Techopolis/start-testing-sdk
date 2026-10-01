"""Local mock workflow. Run with --submit to explicitly authorize the demo submission."""

import argparse
import logging

from starttesting import Client, Options
from starttesting.auth.mock import MockBackend
from starttesting.integrations.logging import StartTestingLogHandler
from starttesting.models import IssueDraft
from starttesting.reporting.reporter import Reporter


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--anonymous", action="store_true")
    parser.add_argument(
        "--environment", choices=["development", "beta", "production"], default="beta"
    )
    parser.add_argument(
        "--submit", action="store_true", help="Consent to submission to the local mock"
    )
    args = parser.parse_args()
    backend = MockBackend()
    client = Client(
        "proj_demo",
        environment=args.environment,
        distribution="github_prerelease",
        project_service=backend,
        authorization_service=backend,
        options=Options(full_logs=True),
    )
    if not args.anonymous:
        client.authenticate(backend)
    logger = logging.getLogger("sample")
    logger.setLevel(logging.DEBUG)
    handler = StartTestingLogHandler(client, logging.DEBUG)
    logger.addHandler(handler)
    reporter = Reporter(client, issues=backend, feedback=backend, attachments=backend)
    try:
        client.breadcrumb("Opened Preferences")
        client.breadcrumb("Selected Samantha voice")
        logger.debug(
            "Initializing preview engine",
            extra={"starttesting_fields": {"category": "audio"}},
        )
        incident = client.reportable_error(
            RuntimeError("Audio engine returned error -10875"),
            user_message="Unable to preview the selected voice",
        )
        draft = IssueDraft(
            "Voice preview fails",
            "Preview failed after selecting Samantha.",
            "The voice should play",
            "No audio played",
            "Open Preferences; select Samantha; Preview",
        )
        report = reporter.prepare(draft, incident=incident, diagnostic_consent=True)
        print("Backend: local in-memory mock")
        print("Mode:", client.mode.value)
        print("Draft:", report.draft.to_dict())
        print("Automatic attachments:", ", ".join(u.name for u in report.uploads))
        if args.submit:
            result = reporter.submit(report, reporter.approve(report))
            print("Created:", result.report.report_id)
            print("Attached:", ", ".join(result.attached))
            print("Complete:", result.complete)
        else:
            print("Nothing submitted. Use --submit to consent to the local mock demonstration.")
    finally:
        logger.removeHandler(handler)
        client.close()


if __name__ == "__main__":
    main()
