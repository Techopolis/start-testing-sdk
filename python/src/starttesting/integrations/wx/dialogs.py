from __future__ import annotations

import threading
from pathlib import Path

import wx

from ...chatgpt import ChatGPTProvider, draft_context, draft_issue
from ...chatgpt.contracts import USAGE_URL
from ...models import IssueDraft, UserMode, encode
from ...reporting.bundle import DiagnosticBundle, selected_attachment


class TextPreview(wx.Dialog):
    def __init__(self, parent, title: str, text: str, *, confirm: bool = False):
        super().__init__(parent, title=title, style=wx.DEFAULT_DIALOG_STYLE | wx.RESIZE_BORDER)
        layout = wx.BoxSizer(wx.VERTICAL)
        label = wx.StaticText(self, label="Review the information below.")
        layout.Add(label, 0, wx.ALL, 10)
        contents = wx.TextCtrl(self, value=text, style=wx.TE_MULTILINE | wx.TE_READONLY)
        contents.SetName("Information to review")
        layout.Add(contents, 1, wx.EXPAND | wx.LEFT | wx.RIGHT, 10)
        layout.Add(
            self.CreateButtonSizer(wx.OK | (wx.CANCEL if confirm else 0)),
            0,
            wx.ALL | wx.ALIGN_RIGHT,
            10,
        )
        self.SetSizer(layout)
        self.SetSize((700, 520))
        self.CentreOnParent()
        contents.SetFocus()


class ReporterDialog(wx.Dialog):
    """All service calls run on a worker. Only wx.CallAfter updates native controls."""

    def __init__(self, parent, reporter, *, incident=None, chatgpt_auth=None):
        self.reporter, self.client = reporter, reporter.client
        self.incident = incident or self.client.manual_incident()
        self.auth = chatgpt_auth
        self.provider = None
        self.selected_model = ""
        self.files = []
        self.pending_report = None
        self._busy = False
        self._alive = True
        self._cancel = threading.Event()
        self.tester = self.client.mode == UserMode.AUTHENTICATED_TESTER
        super().__init__(
            parent,
            title="Report Issue" if self.tester else "Report a Problem",
            style=wx.DEFAULT_DIALOG_STYLE | wx.RESIZE_BORDER,
        )
        self.EnableLayoutAdaptation(True)
        self.SetLayoutAdaptationMode(wx.DIALOG_ADAPTATION_MODE_ENABLED)
        root = wx.BoxSizer(wx.VERTICAL)
        self.controls = {}
        self.edit_controls = []
        if self.tester:
            self._field(root, "title", "Issue &Title", self.incident.safe_message)
        self._field(
            root,
            "description",
            "&Description" if self.tester else "&Describe what happened",
            self.incident.safe_message,
            multiline=True,
        )
        if self.tester:
            self._field(root, "expected_behavior", "&Expected Behavior", multiline=True)
            self._field(root, "actual_behavior", "&Actual Behavior", multiline=True)
            self._field(root, "steps_to_reproduce", "Steps to &Reproduce", multiline=True)
        self.metadata_controls = {}
        if self.tester:
            for definition in self.client.config.fields:
                if self.client.allows(definition.capability):
                    root.Add(wx.StaticText(self, label=definition.label), 0, wx.LEFT | wx.TOP, 10)
                    choice = wx.Choice(self, choices=["Not set", *definition.choices])
                    choice.SetName(definition.label)
                    choice.SetSelection(0)
                    root.Add(choice, 0, wx.EXPAND | wx.LEFT | wx.RIGHT, 10)
                    self.metadata_controls[definition.key] = choice
                    self.edit_controls.append(choice)
        self.consent = wx.CheckBox(self, label="Include &diagnostic information with this report")
        self.consent.SetValue(self.tester and self.client.allows("attach_diagnostics"))
        self.consent.Enable(not self.tester or self.client.allows("attach_diagnostics"))
        root.Add(self.consent, 0, wx.ALL, 10)
        self.edit_controls.append(self.consent)
        self.log_status = wx.StaticText(self)
        root.Add(self.log_status, 0, wx.LEFT | wx.RIGHT, 10)
        self.consent.Bind(wx.EVT_CHECKBOX, lambda event: self.update_log_status())
        self.update_log_status()
        actions = wx.BoxSizer(wx.HORIZONTAL)
        view = wx.Button(self, label="&View Diagnostics")
        view.Bind(wx.EVT_BUTTON, self.on_view)
        actions.Add(view, 0, wx.RIGHT, 8)
        self.edit_controls.append(view)
        if self.tester and self.client.allows("attach_files"):
            add = wx.Button(self, label="Add &Attachment")
            add.Bind(wx.EVT_BUTTON, self.on_attachment)
            actions.Add(add, 0)
            self.edit_controls.append(add)
        root.Add(actions, 0, wx.ALL, 10)
        self.file_status = wx.StaticText(self, label="No additional attachments selected.")
        root.Add(self.file_status, 0, wx.LEFT | wx.RIGHT, 10)
        if self.tester and self.client.allows("use_ai") and self.auth:
            self.add_chatgpt_controls(root)
        self.status = wx.TextCtrl(
            self, value="Diagnostics captured. Review before submitting.", style=wx.TE_READONLY
        )
        self.status.SetName("Report status")
        root.Add(self.status, 0, wx.EXPAND | wx.ALL, 10)
        buttons = wx.StdDialogButtonSizer()
        self.submit_button = wx.Button(self, wx.ID_OK, label="&Review and Submit")
        self.cancel_button = wx.Button(self, wx.ID_CANCEL)
        buttons.AddButton(self.submit_button)
        buttons.AddButton(self.cancel_button)
        buttons.Realize()
        root.Add(buttons, 0, wx.ALL | wx.ALIGN_RIGHT, 10)
        self.submit_button.Bind(wx.EVT_BUTTON, self.on_submit)
        self.cancel_button.Bind(wx.EVT_BUTTON, self.on_cancel)
        self.Bind(wx.EVT_CLOSE, self.on_close)
        self.SetSizer(root)
        self.SetSize((720, 760))
        self.CentreOnParent()
        self.controls["title" if self.tester else "description"].SetFocus()

    def _field(self, root, key, label, value="", multiline=False):
        root.Add(wx.StaticText(self, label=label), 0, wx.LEFT | wx.TOP, 10)
        control = wx.TextCtrl(self, value=value, style=wx.TE_MULTILINE if multiline else 0)
        control.SetName(label.replace("&", ""))
        if multiline:
            control.SetMinSize((-1, 60))
        root.Add(control, 1 if multiline else 0, wx.EXPAND | wx.LEFT | wx.RIGHT, 10)
        self.controls[key] = control
        self.edit_controls.append(control)

    def update_log_status(self):
        if self.tester and self.client.full_logs_enabled and self.consent.GetValue():
            label = "Developer logs will be attached automatically."
        elif self.consent.GetValue():
            label = "Minimal diagnostics will be included. Full developer logs are not included."
        else:
            label = "Diagnostic information will not be attached."
        self.log_status.SetLabel(label)
        self.log_status.SetName(label)

    def announce(self, message):
        self.status.SetValue(message)
        self.status.SetFocus()
        self.status.SetSelection(0, 0)

    def background(self, work, done):
        if self._busy:
            return
        self._busy = True
        self._cancel.clear()
        self.submit_button.Disable()
        for control in self.edit_controls:
            control.Disable()

        def finish(value, error):
            if not self._alive:
                return
            self._busy = False
            self.submit_button.Enable()
            for control in self.edit_controls:
                control.Enable()
            if self.pending_report:
                for control in self.edit_controls:
                    control.Disable()
            if error:
                self.announce("The action could not finish. You can retry or report manually.")
                wx.MessageBox(
                    self.client.redactor.text(str(error))[:1000],
                    "Action could not finish",
                    wx.OK | wx.ICON_ERROR,
                    self,
                )
            else:
                done(value)

        def run():
            try:
                value = work()
            except Exception as error:
                wx.CallAfter(finish, None, error)
            else:
                wx.CallAfter(finish, value, None)

        threading.Thread(target=run, daemon=True, name="StartTestingReporter").start()

    def on_cancel(self, event):
        if self._busy:
            self._cancel.set()
            self.announce("Waiting for the current action. Sign-in cancellation requested.")
            return
        self._alive = False
        self.EndModal(wx.ID_CANCEL)

    def on_close(self, event):
        if self._busy:
            self._cancel.set()
            if event.CanVeto():
                event.Veto()
            return
        self._alive = False
        event.Skip()

    def on_view(self, event):
        bundle = DiagnosticBundle.from_incident(
            self.incident,
            self.client.redactor,
            full_logs=self.tester and self.client.full_logs_enabled,
            restricted=not self.tester,
        )
        with TextPreview(self, "View Diagnostics", bundle.preview()) as dialog:
            dialog.ShowModal()

    def on_attachment(self, event):
        with wx.FileDialog(
            self,
            "Choose an attachment",
            wildcard=(
                "Supported files "
                "(*.txt;*.log;*.json;*.png;*.jpg;*.jpeg)|*.txt;*.log;*.json;*.png;*.jpg;*.jpeg"
            ),
            style=wx.FD_OPEN | wx.FD_FILE_MUST_EXIST,
        ) as picker:
            if picker.ShowModal() != wx.ID_OK:
                return
            path = Path(picker.GetPath())
        with wx.TextEntryDialog(
            self,
            "Describe the attachment for readers using assistive technology.",
            "Attachment description",
        ) as dialog:
            if dialog.ShowModal() != wx.ID_OK:
                return
            description = dialog.GetValue()
        if len(self.files) >= 5:
            self.announce("Five attachments are already selected.")
            return

        def done(upload):
            self.files.append(upload)
            self.file_status.SetLabel("Attachments: " + ", ".join(u.name for u in self.files))
            self.announce("Attachment added. Review image contents and metadata before submitting.")

        self.background(lambda: selected_attachment(path, description, self.client.redactor), done)

    def _draft(self):
        values = {key: control.GetValue() for key, control in self.controls.items()}
        metadata = {
            key: control.GetStringSelection()
            for key, control in self.metadata_controls.items()
            if control.GetSelection() > 0
        }
        return IssueDraft(**values, metadata_json=encode(metadata))

    def on_submit(self, event):
        if self.pending_report:
            self._send(self.pending_report)
            return
        draft, consent, attachments = self._draft(), self.consent.GetValue(), tuple(self.files)

        def ready(report):
            text = encode(report.draft.to_dict()) + "\n\n"
            text += report.bundle.preview() if report.bundle else "No diagnostics selected."
            text += "\n\nAdditional attachments:\n" + "\n".join(
                f"{u.name}: {u.accessible_description} ({len(u.data)} bytes)"
                for u in report.attachments
            )
            with TextPreview(self, "Review report before sending", text, confirm=True) as dialog:
                if dialog.ShowModal() == wx.ID_OK:
                    self._send(report)

        self.background(
            lambda: self.reporter.prepare(
                draft, incident=self.incident, diagnostic_consent=consent, attachments=attachments
            ),
            ready,
        )

    def _send(self, report):
        approval = self.reporter.approve(report)
        self.pending_report = report

        def done(result):
            if result.complete:
                self.announce(
                    f"Issue submitted: {result.report.report_id}. Selected diagnostics attached."
                )
                wx.MessageBox(self.status.GetValue(), "Report submitted", wx.OK, self)
                self._alive = False
                self.EndModal(wx.ID_OK)
            else:
                self.submit_button.SetLabel("&Retry Attachments")
                self.announce(
                    f"Report {result.report.report_id} created. "
                    f"{len(result.pending)} attachments need retry."
                )

        self.background(lambda: self.reporter.submit(report, approval), done)

    def add_chatgpt_controls(self, root):
        self.account = wx.Choice(self, choices=["Add a ChatGPT account"])
        self.account.SetName("ChatGPT account")
        self.account.SetSelection(0)
        self.account_ids = []
        self.model = wx.Choice(self)
        self.model.SetName("ChatGPT model")
        root.Add(wx.StaticText(self, label="ChatGPT account and model (optional)"), 0, wx.LEFT, 10)
        root.Add(self.account, 0, wx.EXPAND | wx.LEFT | wx.RIGHT, 10)
        root.Add(self.model, 0, wx.EXPAND | wx.LEFT | wx.RIGHT, 10)
        row = wx.BoxSizer(wx.HORIZONTAL)
        for label, callback in (
            ("Continue with ChatGPT", self.on_connect),
            ("Draft with ChatGPT", self.on_ai),
            ("Manage usage", self.on_usage),
            ("Disconnect", self.on_disconnect),
        ):
            button = wx.Button(self, label=label)
            button.Bind(wx.EVT_BUTTON, callback)
            row.Add(button, 0, wx.RIGHT, 4)
            self.edit_controls.append(button)
        root.Add(row, 0, wx.ALL, 10)
        self.edit_controls.extend([self.account, self.model])
        self.account.Bind(wx.EVT_CHOICE, self.on_account)

    def on_connect(self, event):
        selection = self.account.GetSelection()
        client_id = self.account_ids[selection - 1] if selection > 0 else None

        def work():
            profile = self.auth.sign_in(client_id=client_id, cancel=self._cancel)
            provider = ChatGPTProvider(self.auth, profile.client_id)
            return profile, provider, provider.models() if profile.plan_enabled else ()

        def done(result):
            profile, self.provider, models = result
            self.account_ids = [p.client_id for p in self.auth.connections()]
            self.account.Set(
                ["Add a ChatGPT account"]
                + [f"{p.email or p.subject} ({p.client_id[-8:]})" for p in self.auth.connections()]
            )
            self.account.SetSelection(self.account_ids.index(profile.client_id) + 1)
            self.model_slugs = [slug for slug, _ in models]
            self.model.Set([label for _, label in models])
            if models:
                self.model.SetSelection(0)
            self.announce(
                "ChatGPT connected. Using your ChatGPT plan."
                if profile.plan_enabled
                else "ChatGPT identity connected. Plan usage is not enabled."
            )

        self.background(work, done)

    def on_account(self, event):
        self.provider = None
        self.model.Clear()
        self.announce("Select Continue with ChatGPT to validate this account.")

    def on_ai(self, event):
        if not self.provider or self.model.GetSelection() < 0:
            self.announce("Connect an eligible ChatGPT account and choose a model first.")
            return
        notes = self.controls["description"].GetValue()
        model = self.model_slugs[self.model.GetSelection()]

        def ready(context):
            with TextPreview(
                self, "Send this context to ChatGPT?", encode(context), confirm=True
            ) as dialog:
                if dialog.ShowModal() != wx.ID_OK:
                    return

            def done(result):
                draft = result.as_issue_draft()
                for key, control in self.controls.items():
                    control.SetValue(getattr(draft, key))
                self.announce(
                    "Draft ready. Review and edit before submitting. Issue metadata is unchanged."
                )

            self.background(
                lambda: draft_issue(
                    self.client, self.provider, self.incident, notes, model=model, consent=True
                ),
                done,
            )

        self.background(lambda: draft_context(self.client, self.incident, notes), ready)

    def on_usage(self, event):
        import webbrowser

        webbrowser.open(USAGE_URL)

    def on_disconnect(self, event):
        if self.provider:
            client_id = self.provider.client_id
            self.provider = None
            self.model.Clear()
            self.background(
                lambda: self.auth.disconnect(client_id),
                lambda revoked: self.announce(
                    "ChatGPT disconnected."
                    if revoked
                    else (
                        "ChatGPT disconnected locally. Remote revocation unconfirmed; "
                        "use ChatGPT Settings."
                    )
                ),
            )
