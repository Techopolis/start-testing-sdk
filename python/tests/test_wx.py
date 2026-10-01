"""Native integration smoke tests. Opt in on an interactive desktop with RUN_WX_TESTS=1."""

import os
import time

import pytest

if os.environ.get("RUN_WX_TESTS") != "1":
    pytest.skip("Set RUN_WX_TESTS=1 on an interactive desktop", allow_module_level=True)

wx = pytest.importorskip("wx")
from starttesting.integrations.wx.dialogs import ReporterDialog, TextPreview  # noqa: E402


@pytest.fixture(scope="module")
def app():
    existing = wx.App.Get()
    return existing or wx.App(False)


def test_native_reporter_controls_and_submission(app, rig, monkeypatch):
    client, backend, reporter = rig
    incident = client.reportable_error(ValueError("Test failure"))
    parent = wx.Frame(None, title="SDK native test")
    dialog = ReporterDialog(parent, reporter, incident=incident)
    monkeypatch.setattr(TextPreview, "ShowModal", lambda self: wx.ID_OK)
    monkeypatch.setattr(wx, "MessageBox", lambda *args, **kwargs: wx.ID_OK)
    completed = []
    monkeypatch.setattr(dialog, "EndModal", completed.append)
    try:
        assert dialog.controls["title"].GetName() == "Issue Title"
        assert dialog.controls["description"].GetName() == "Description"
        assert "automatically" in dialog.log_status.GetLabel()
        assert "milestone" in dialog.metadata_controls
        dialog.controls["title"].SetValue("Native test")
        dialog.controls["description"].SetValue("Native UI submission test")
        dialog.Show()
        dialog.on_submit(None)
        deadline = time.monotonic() + 5
        while not completed and time.monotonic() < deadline:
            wx.Yield()
            time.sleep(0.01)
        assert completed == [wx.ID_OK]
        assert len(backend.issues) == 1
        assert len(backend.attachments["ST-1"]) == 5
    finally:
        dialog.Destroy()
        parent.Destroy()
        wx.Yield()


def test_external_native_reporter_hides_internal_fields(app, rig):
    client, _, reporter = rig
    client.sign_out()
    parent = wx.Frame(None, title="SDK native test")
    dialog = ReporterDialog(parent, reporter)
    try:
        assert dialog.GetTitle() == "Report a Problem"
        assert list(dialog.controls) == ["description"]
        assert not dialog.metadata_controls
        assert not dialog.consent.GetValue()
        assert not hasattr(dialog, "account")
    finally:
        dialog.Destroy()
        parent.Destroy()
        wx.Yield()
