import json
import logging
import sys
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace

import pytest

from starttesting.auth import AuthorizationError
from starttesting.auth.mock import MockBackend
from starttesting.client import Client, Options
from starttesting.diagnostics import DiagnosticStorage
from starttesting.environment import resolve_build
from starttesting.integrations.logging import StartTestingLogHandler
from starttesting.models import (
    Environment,
    ErrorSeverity,
    EventType,
    ExternalFeedback,
    IssueDraft,
    PromptPolicy,
    UserMode,
)
from starttesting.privacy import Redactor
from starttesting.reporting.bundle import DiagnosticBundle, selected_attachment


@pytest.mark.parametrize(
    "distribution,environment",
    [
        ("testflight", "beta"),
        ("github_prerelease", "beta"),
        ("msix_flight", "beta"),
        ("github_release", "production"),
        ("app_store", "production"),
        ("xcode", "development"),
        ("debug", "development"),
        ("pyinstaller", "unknown"),
        ("source", "unknown"),
        ("msix", "unknown"),
    ],
)
def test_build_signals(distribution, environment):
    build = resolve_build(distribution=distribution, environ={})
    assert build.environment.value == environment


@pytest.mark.parametrize("environment", ["beta", "production"])
def test_pyinstaller_explicit_metadata(tmp_path, monkeypatch, environment):
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    path = tmp_path / "starttesting_build.json"
    path.write_text(
        json.dumps({"environment": environment, "distribution": "pyinstaller", "version": "2.0"})
    )
    assert resolve_build(metadata_path=path, environ={}).environment.value == environment
    assert (
        resolve_build(
            environment="development",
            metadata_path=path,
            environ={"START_TESTING_ENVIRONMENT": "production"},
        ).environment
        == Environment.DEVELOPMENT
    )


@pytest.mark.parametrize(
    "environment,tester,expected",
    [
        ("development", True, "authenticated_tester"),
        ("beta", True, "authenticated_tester"),
        ("development", False, "beta_feedback"),
        ("beta", False, "beta_feedback"),
        ("production", False, "production_support"),
        ("production", True, "production_support"),
        ("unknown", True, "production_support"),
    ],
)
def test_modes(environment, tester, expected):
    backend = MockBackend()
    client = Client(
        "proj_demo",
        environment=environment,
        project_service=backend,
        authorization_service=backend,
        options=Options(full_logs=True),
    )
    if tester:
        client.authenticate(backend)
    assert client.mode.value == expected
    assert client.full_logs_enabled == (expected == "authenticated_tester")
    client.close()


def test_unauthorized_expired_revoked_and_forged(rig, clock):
    client, backend, reporter = rig
    with pytest.raises(AuthorizationError):
        backend.authenticate("proj_demo", authorized=False)
    with pytest.raises(AuthorizationError):
        client.set_authorization(replace(client.grant, subject="forged"))
    incident = client.reportable_error(ValueError("Oops"))
    prepared = reporter.prepare(
        IssueDraft("Title", "Description"), incident=incident, diagnostic_consent=True
    )
    backend.revoke(client.grant)
    with pytest.raises(AuthorizationError):
        reporter.submit(prepared, reporter.approve(prepared))
    assert backend.issues == {}
    client.authenticate(backend)
    clock.advance(901)
    assert client.mode == UserMode.BETA_FEEDBACK
    assert client.record("private debug", type=EventType.DEBUG) is None


def test_redaction_before_disk_preview_upload(rig, tmp_path):
    client, backend, reporter = rig
    storage = DiagnosticStorage(tmp_path / "diagnostics")
    client.storage = storage
    client.redactor.register_sensitive_value("fake-private-value")
    client.redactor.register_sensitive_key("custom_pin")
    client.redactor.register_redaction_pattern(r"FAKE-[0-9]+")
    client.record(
        'authorization=abc123 password="sword fish" Bearer fake-bearer',
        type=EventType.DEBUG,
        fields={
            "nested": {
                "api_key": "fake-key",
                "custom_pin": "1234",
                "extra": "fake-private-value",
                "other": "FAKE-999",
            }
        },
    )
    incident = client.reportable_error(ValueError("token=secret123"))
    prepared = reporter.prepare(
        IssueDraft("Title", "Description"), incident=incident, diagnostic_consent=True
    )
    result = reporter.submit(prepared, reporter.approve(prepared))
    content = (
        prepared.bundle.preview()
        + b"".join(p.read_bytes() for p in storage.directory.glob("*.json*")).decode()
    )
    content += b"".join(
        u.data for u in backend.attachments[result.report.report_id].values()
    ).decode()
    for secret in (
        "abc123",
        "sword fish",
        "fake-bearer",
        "fake-key",
        "1234",
        "fake-private-value",
        "FAKE-999",
        "secret123",
    ):
        assert secret not in content
    assert "REDACTED" in content
    assert any("dev-logs" in name for name in result.attached)


def test_redactor_fail_closed_and_suppression():
    redactor = Redactor(allowed_fields={"safe"}, suppressed_categories={"auth"})
    client = Client("public", redactor=redactor)
    assert client.record("password", category="auth") is None
    event = client.record(
        "something", type=EventType.WARNING, fields={"safe": "yes", "private": "no"}
    )
    assert json.loads(event.fields_json) == {"safe": "yes"}

    def broken(text):
        raise RuntimeError("bad redactor")

    redactor.register_redactor(broken)
    assert redactor.text("private") == "[REDACTED]"


def test_immutable_window_and_retention(rig, clock):
    client, _, _ = rig
    fields = {"nested": {"safe": "before"}}
    client.record("old", type=EventType.DEBUG)
    clock.advance(301)
    client.breadcrumb("Clicked save", fields=fields)
    fields["nested"]["safe"] = "after"
    incident = client.reportable_error(ValueError("save failed"))
    client.breadcrumb("Later activity")
    assert [e.message for e in incident.events] == ["Clicked save", "save failed"]
    assert "before" in incident.events[0].fields_json
    assert "after" not in incident.events[0].fields_json
    clock.advance(901)
    assert client.buffer.snapshot(clock(), 10000, client.session.session_id) == ()


def test_bounded_concurrent_capture(clock):
    client = Client("proj", clock=clock, options=Options(max_events=100, max_buffer_bytes=15_000))
    with ThreadPoolExecutor(8) as pool:
        list(pool.map(lambda n: client.breadcrumb(f"Action {n}"), range(500)))
    events = client.buffer.snapshot(clock(), 300, client.session.session_id)
    assert len(events) <= 100
    assert client.buffer.byte_size <= 15_000
    assert [e.sequence for e in events] == sorted(e.sequence for e in events)
    assert len({e.sequence for e in events}) == len(events)
    assert client.buffer.dropped > 0


def test_log_rotation_recovery_lock_and_cleanup(tmp_path, clock):
    root = tmp_path / "diagnostics"
    storage = DiagnosticStorage(root, segment_bytes=1200, segments=2, max_incidents=2)
    with pytest.raises(RuntimeError):
        DiagnosticStorage(root)
    client = Client("proj", storage=storage, clock=clock)
    for n in range(50):
        client.breadcrumb(f"Breadcrumb {n}")
    assert len(list(root.glob("events-*.jsonl"))) <= 2
    assert all(p.stat().st_size <= 1200 for p in root.glob("events-*.jsonl"))
    fatal = client.record_exception(RuntimeError("crash"), severity=ErrorSeverity.FATAL)
    client.close()
    storage = DiagnosticStorage(root)
    recovered = storage.recovered_fatal_incidents(clock())
    assert recovered[0].incident_id == fatal.incident_id
    assert recovered[0].events == fatal.events
    storage.acknowledge(fatal.incident_id)
    assert not storage.recovered_fatal_incidents(clock())
    clock.advance(86401)
    storage.prune(clock())
    assert not list(root.glob("events-*.jsonl"))
    storage.close()


def test_prompts_warnings_dedup_and_no_submission(rig, clock):
    client, backend, _ = rig
    prompts = []
    client.on_incident = prompts.append
    client.record_exception(ValueError("warning"))
    assert not prompts
    incident = client.reportable_error(ValueError("failure"))
    client.reportable_error(ValueError("failure"))
    assert prompts == [incident]
    clock.advance(61)
    client.reportable_error(ValueError("failure"))
    assert len(prompts) == 2
    client.record_exception(ValueError("fatal"), severity=ErrorSeverity.FATAL)
    assert len(prompts) == 2
    assert not backend.issues
    client.options = replace(client.options, prompt_policy=PromptPolicy.MANUAL_ONLY)
    clock.advance(61)
    client.reportable_error(ValueError("new failure"))
    assert len(prompts) == 2


def test_critical_only(rig, clock):
    client, _, _ = rig
    client.options = replace(client.options, prompt_policy=PromptPolicy.CRITICAL_ONLY)
    prompts = []
    client.on_incident = prompts.append
    client.reportable_error(ValueError("not critical"))
    client.record_exception(ValueError("critical"), severity=ErrorSeverity.CRITICAL)
    assert len(prompts) == 1


def test_logging_requires_explicit_full_mode(rig):
    client, _, _ = rig
    logger = logging.getLogger("starttesting-test")
    logger.setLevel(logging.DEBUG)
    logger.propagate = False
    handler = StartTestingLogHandler(client, logging.DEBUG)
    logger.addHandler(handler)
    try:
        logger.debug("debug %s", "detail", extra={"starttesting_fields": {"password": "fakepw"}})
        events = client.manual_incident().events
        assert "debug detail" in [e.message for e in events]
        assert "fakepw" not in str(events)
        client.sign_out()
        logger.debug("private detail")
        assert not client.manual_incident().events
    finally:
        logger.removeHandler(handler)


def test_manual_auto_attachments_and_partial_retry(rig):
    client, backend, reporter = rig
    client.record("developer detail", type=EventType.DEBUG)
    prepared = reporter.prepare(
        IssueDraft("Save failure", "Steps and observations"), diagnostic_consent=True
    )
    backend.fail_attachments.add("ST-1-dev-logs.txt")
    first = reporter.submit(prepared, reporter.approve(prepared))
    assert first.pending == ("ST-1-dev-logs.txt",)
    assert len(backend.issues) == 1
    backend.fail_attachments.clear()
    second = reporter.submit(prepared, reporter.approve(prepared))
    assert second.complete
    assert len(backend.issues) == 1
    assert len(backend.attachments["ST-1"]) == 5
    assert any(b"developer detail" in u.data for u in backend.attachments["ST-1"].values())


def test_review_required_and_new_privacy_rule(rig):
    client, backend, reporter = rig
    prepared = reporter.prepare(IssueDraft("Title", "Description"), diagnostic_consent=True)
    approval = reporter.approve(prepared)
    modified = replace(prepared, draft=IssueDraft("Changed", "Description"))
    with pytest.raises(ValueError, match="changed after review"):
        reporter.submit(modified, approval)
    client.redactor.register_sensitive_value("Description")
    with pytest.raises(ValueError, match="Privacy rules changed"):
        reporter.submit(prepared, approval)
    assert not backend.issues


def test_external_feedback_minimal_and_consent(rig):
    client, backend, reporter = rig
    client.sign_out()
    client.breadcrumb("internal screen name")
    incident = client.reportable_error(ValueError("private stack content"))
    report = reporter.prepare(
        IssueDraft(
            "Hidden title", "Customer description", metadata_json='{"milestone":"Internal"}'
        ),
        incident=incident,
        diagnostic_consent=True,
    )
    assert report.draft.title == ""
    assert report.draft.metadata_json == "{}"
    preview = report.bundle.preview()
    for forbidden in ("internal screen", "private stack", "session_id", "dev-logs", "Internal"):
        assert forbidden not in preview
    result = reporter.submit(report, reporter.approve(report))
    assert result.report.kind == "feedback"
    assert not backend.issues
    report = reporter.prepare(IssueDraft(description="No diagnostic consent"))
    result = reporter.submit(report, reporter.approve(report))
    assert not backend.attachments[result.report.report_id]


def test_errors_only_and_disabled(rig):
    client, backend, reporter = rig
    client.sign_out()
    backend.policy = replace(backend.policy, external_feedback=ExternalFeedback.ERRORS_ONLY)
    with pytest.raises(AuthorizationError):
        reporter.prepare(IssueDraft(description="Manual feedback"))
    incident = client.reportable_error(ValueError("error"))
    assert reporter.prepare(IssueDraft(description="Error feedback"), incident=incident)
    backend.policy = replace(backend.policy, external_feedback=ExternalFeedback.DISABLED)
    with pytest.raises(AuthorizationError):
        reporter.prepare(IssueDraft(description="Error feedback"), incident=incident)


def test_field_and_project_and_subject_boundaries(rig):
    client, backend, reporter = rig
    with pytest.raises(AuthorizationError):
        reporter.prepare(IssueDraft("Title", "Description", metadata_json='{"assignee":"admin"}'))
    incident = client.reportable_error(ValueError("error"))
    client.set_authorization(backend.authenticate("proj_demo", subject="another-tester"))
    with pytest.raises(AuthorizationError):
        reporter.prepare(IssueDraft("Title", "Description"), incident=incident)
    with pytest.raises(AuthorizationError):
        client.set_authorization(replace(client.grant, project_id="other"))


def test_bundle_zip_manifest_and_selected_files(rig, tmp_path):
    import hashlib
    import io
    import zipfile

    client, _, _ = rig
    bundle = DiagnosticBundle.from_incident(
        client.manual_incident(), client.redactor, full_logs=True
    )
    with zipfile.ZipFile(io.BytesIO(bundle.zip_bytes())) as archive:
        manifest = json.loads(archive.read("manifest.json"))
        for entry in manifest["files"]:
            data = archive.read(entry["name"])
            assert len(data) == entry["bytes"]
            assert hashlib.sha256(data).hexdigest() == entry["sha256"]
    path = tmp_path / "selected.txt"
    path.write_text("password=fake-password")
    upload = selected_attachment(path, "Selected test log", client.redactor)
    assert b"fake-password" not in upload.data
    with pytest.raises(ValueError):
        selected_attachment(path, "Description", client.redactor, max_bytes=2)
    link = tmp_path / "link.txt"
    try:
        link.symlink_to(path)
    except OSError:
        pytest.skip("Symlink creation unavailable")
    with pytest.raises(ValueError):
        selected_attachment(link, "Description", client.redactor)
