from __future__ import annotations

import wx

from ...models import ErrorSeverity, UserMode
from .dialogs import ReporterDialog, TextPreview


class WxIntegration:
    def __init__(self, parent, reporter, *, chatgpt_auth=None):
        self.parent, self.reporter, self.auth = parent, reporter, chatgpt_auth
        self._previous = reporter.client.on_incident
        self._active = False
        self._closed = False
        self._callback = lambda incident: wx.CallAfter(self.show_incident, incident)
        reporter.client.on_incident = self._callback

    def show_reporter(self, incident=None):
        with ReporterDialog(
            self.parent, self.reporter, incident=incident, chatgpt_auth=self.auth
        ) as dialog:
            return dialog.ShowModal()

    def show_incident(self, incident):
        if self._active or self._closed:
            return
        self._active = True
        try:
            tester = self.reporter.client.mode == UserMode.AUTHENTICATED_TESTER
            if incident.severity == ErrorSeverity.FATAL:
                message = (
                    "The app closed unexpectedly during the previous session. "
                    "Would you like to send a diagnostic report?"
                )
            elif tester:
                message = (
                    "Something went wrong. Start Testing captured diagnostic information "
                    "for this incident. Would you like to report it?"
                )
            else:
                message = (
                    "Something went wrong. Would you like to send "
                    "diagnostic information to support?"
                )
            if tester and incident.safe_message:
                message = incident.safe_message + "\n\n" + message
            while True:
                with wx.MessageDialog(
                    self.parent,
                    message,
                    "Diagnostics captured",
                    wx.YES_NO | wx.CANCEL | wx.ICON_WARNING,
                ) as alert:
                    alert.SetYesNoCancelLabels(
                        "Report Issue" if tester else "Report a Problem",
                        "View Diagnostics",
                        "Dismiss",
                    )
                    action = alert.ShowModal()
                if action == wx.ID_YES:
                    self.show_reporter(incident)
                    break
                if action == wx.ID_NO:
                    from ...reporting.bundle import DiagnosticBundle

                    bundle = DiagnosticBundle.from_incident(
                        incident,
                        self.reporter.client.redactor,
                        full_logs=tester and self.reporter.client.full_logs_enabled,
                        restricted=not tester,
                    )
                    with TextPreview(self.parent, "View Diagnostics", bundle.preview()) as preview:
                        preview.ShowModal()
                else:
                    if incident.severity == ErrorSeverity.FATAL and self.reporter.client.storage:
                        self.reporter.client.storage.acknowledge(incident.incident_id)
                    break
        finally:
            self._active = False

    def recover_previous_crashes(self):
        for incident in self.reporter.client.recovered_incidents():
            if self.reporter.client.should_prompt(incident):
                wx.CallAfter(self.show_incident, incident)

    def close(self):
        self._closed = True
        if self.reporter.client.on_incident is self._callback:
            self.reporter.client.on_incident = self._previous


__all__ = ["ReporterDialog", "TextPreview", "WxIntegration"]
