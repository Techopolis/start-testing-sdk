"""Native reference app. Start Testing operations use only the local mock backend."""

from __future__ import annotations

import argparse
import json
import logging
import os
from pathlib import Path


def build_path() -> Path:
    # PyInstaller sets __file__ to the bundled path; no environment inference from sys.frozen.
    return Path(__file__).resolve().with_name("starttesting_build.json")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check-build", action="store_true")
    args = parser.parse_args()
    if args.check_build:
        from dataclasses import asdict

        from starttesting.environment import resolve_build

        print(json.dumps(asdict(resolve_build(metadata_path=build_path()))))
        return
    import wx
    from starttesting import Client, Options
    from starttesting.auth.mock import MockBackend
    from starttesting.diagnostics import DiagnosticStorage
    from starttesting.integrations.logging import StartTestingLogHandler
    from starttesting.reporting.reporter import Reporter
    from starttesting.wx import WxIntegration

    app = wx.App(False)
    backend = MockBackend()
    data_root = Path(os.environ.get("LOCALAPPDATA", str(Path.home() / ".local" / "share")))
    storage = DiagnosticStorage(data_root / "StartTestingSample" / "diagnostics")
    client = Client(
        "proj_demo",
        metadata_path=build_path(),
        project_service=backend,
        authorization_service=backend,
        options=Options(full_logs=True),
        storage=storage,
    )
    reporter = Reporter(client, issues=backend, feedback=backend, attachments=backend)
    logger = logging.getLogger("starttesting-sample")
    logger.setLevel(logging.DEBUG)
    handler = StartTestingLogHandler(client, logging.DEBUG)
    logger.addHandler(handler)
    frame = wx.Frame(None, title="Start Testing SDK - Local mock demonstration", size=(700, 470))
    panel = wx.Panel(frame)
    layout = wx.BoxSizer(wx.VERTICAL)
    intro = wx.StaticText(
        panel,
        label=(
            "Start Testing beta sample. Start Testing reports stay in the local mock backend.\n"
            "Sign in as a mock tester, perform actions, then trigger an error.\n"
            "ChatGPT is optional and sends only context you review to OpenAI."
        ),
    )
    layout.Add(intro, 0, wx.ALL, 15)
    status = wx.TextCtrl(panel, value="Anonymous beta feedback mode", style=wx.TE_READONLY)
    status.SetName("Sample status")
    integration = WxIntegration(frame, reporter)
    auth_resources = []

    def announce(text):
        status.SetValue(text)
        status.SetFocus()

    def sign_in(event):
        client.authenticate(backend)
        announce("Mock tester authenticated. Mode: " + client.mode.value)

    def sign_out(event):
        client.sign_out(backend)
        announce("Signed out. Internal controls and full logs are disabled.")

    def action(event):
        client.breadcrumb("Opened Preferences")
        client.breadcrumb("Selected Samantha voice")
        logger.debug(
            "Preparing audio engine",
            extra={"starttesting_fields": {"voice": "Samantha"}},
        )
        announce("Actions and diagnostic breadcrumbs recorded.")

    def fail(event):
        client.breadcrumb("Activated Preview")
        client.reportable_error(
            RuntimeError("Audio engine returned error -10875"),
            user_message="Unable to preview the selected voice",
        )

    def enable_chatgpt(event):
        try:
            from starttesting.chatgpt import ChatGPTAuth
            from starttesting.chatgpt.storage import KeyringCredentialStore

            if integration.auth is None:
                vault = KeyringCredentialStore(
                    "starttesting-demo", data_root / "StartTestingSample" / "auth-lock"
                )
                auth = ChatGPTAuth(vault, app_name="Start Testing SDK sample")
                auth_resources.extend([vault, auth.transport])
                integration.auth = auth
            announce(
                "ChatGPT controls enabled in the tester reporter. Sign-in requires your action."
            )
        except Exception:
            announce("ChatGPT needs the chatgpt extra and a supported OS credential vault.")

    for title, action_fn in (
        ("Sign in as Mock Tester", sign_in),
        ("Sign out", sign_out),
        ("Perform test actions", action),
        ("Trigger reportable error", fail),
        ("Open manual reporter", lambda event: integration.show_reporter()),
        ("Enable optional ChatGPT controls", enable_chatgpt),
    ):
        button = wx.Button(panel, label=title)
        button.Bind(wx.EVT_BUTTON, action_fn)
        layout.Add(button, 0, wx.EXPAND | wx.LEFT | wx.RIGHT | wx.BOTTOM, 15)
    layout.Add(status, 0, wx.EXPAND | wx.ALL, 15)
    panel.SetSizer(layout)
    frame.Show()
    wx.CallAfter(integration.recover_previous_crashes)
    try:
        app.MainLoop()
    finally:
        integration.close()
        logger.removeHandler(handler)
        client.close()
        for resource in reversed(auth_resources):
            resource.close()


if __name__ == "__main__":
    main()
