using System.Collections.Immutable;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using StartTesting.Auth;
using StartTesting.Core;
using StartTesting.Diagnostics;

namespace StartTesting.WinUI;

// draftWithAI is optional: given the incident and the tester's notes, it returns a draft
// from the tester's own AI account, or null. It is offered only in tester mode.
public sealed class NativeReporter(FrameworkElement root, Reporter reporter,
    Func<Incident, string, Task<IssueDraft?>>? draftWithAI = null) : IDisposable
{
    private bool showing;
    private Action<Incident>? handler;
    public void InstallIncidentAlerts()
    {
        if (handler is not null) return;
        handler = incident => root.DispatcherQueue.TryEnqueue(async () => {
            if (showing) return;
            try { await AlertAsync(incident); }
            catch (Exception) { /* Native host may be closing. No automatic upload. */ }
        });
        reporter.Client.IncidentCaptured += handler;
    }
    private ContentDialog Dialog(string title, object content, string primary, string close = "Cancel") => new() {
        XamlRoot = root.XamlRoot, Title = title, Content = content,
        PrimaryButtonText = primary, CloseButtonText = close, DefaultButton = ContentDialogButton.Close };
    public async Task AlertAsync(Incident incident)
    {
        bool tester = reporter.Client.DetailedReports;
        bool diagnostics = tester || reporter.Client.Configuration.FeedbackDiagnostics;
        var alert = Dialog(diagnostics ? "Diagnostics captured" : "Something went wrong", incident.ErrorType == "AINoticed"
            ? "ChatGPT noticed a possible problem in the logs: " + incident.SafeMessage + ". Would you like to review the report it drafted?"
            : incident.Severity == ErrorSeverity.Fatal
            ? "The app closed unexpectedly during the previous session. Would you like to send a diagnostic report?"
            : tester ? "Something went wrong. Start Testing captured diagnostic information for this incident. Would you like to report it?"
            : diagnostics ? "Something went wrong. Would you like to send diagnostic information to support?"
            : "Something went wrong. Would you like to tell support what happened?",
            tester ? "Report Issue" : "Report a Problem", "Dismiss");
        if (diagnostics) alert.SecondaryButtonText = "View Diagnostics";
        showing = true;
        try
        {
            var result = await alert.ShowAsync();
            if (result == ContentDialogResult.Secondary)
            {
                var bundle = DiagnosticBundle.Create(incident, reporter.Client.Redactor,
                    reporter.Client.FullLogsEnabled && incident.TesterSubject == reporter.Client.Grant?.Subject, !tester);
                await PreviewAsync("View Diagnostics", bundle.Preview);
            }
            else if (result == ContentDialogResult.Primary) await ShowAsync(incident);
        }
        finally { showing = false; }
    }
    private async Task PreviewAsync(string title, string text)
    {
        var preview = new TextBox { Text = text, AcceptsReturn = true, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 500 };
        AutomationProperties.SetName(preview, "Diagnostic information");
        var dialog = Dialog(title, new ScrollViewer { Content = preview }, "", "Close");
        await dialog.ShowAsync();
    }
    public async Task ShowAsync(Incident? incident = null)
    {
        await reporter.Client.RevalidateAsync();
        // "tester" means the full form: a signed-in tester, or a testing build with a project key.
        bool signedIn = reporter.Client.Mode == UserMode.AuthenticatedTester;
        bool tester = reporter.Client.DetailedReports;
        bool diagnostics = tester || reporter.Client.Configuration.FeedbackDiagnostics;
        incident ??= reporter.Client.ManualIncident();
        var panel = new StackPanel { Spacing = 10 };
        TextBox Field(string label, bool multiline = false)
        {
            var text = new TextBox { Header = label, AcceptsReturn = multiline, TextWrapping = TextWrapping.Wrap, MinWidth = 340 };
            AutomationProperties.SetName(text, label); panel.Children.Add(text); return text;
        }
        var title = tester ? Field("Issue Title") : null;
        var description = Field(tester ? "Description" : "Describe what happened", true);
        var expected = tester ? Field("Expected Behavior", true) : null;
        var actual = tester ? Field("Actual Behavior", true) : null;
        var steps = tester ? Field("Steps to Reproduce", true) : null;
        var name = signedIn ? null : Field("Your Name (optional)");
        var email = signedIn || tester ? null : Field("Your Email (optional)");
        // A problem the AI noticed arrives with its draft already written.
        void Fill(IssueDraft draft)
        {
            if (title is not null) title.Text = draft.Title;
            description.Text = draft.Description;
            if (expected is not null) expected.Text = draft.ExpectedBehavior;
            if (actual is not null) actual.Text = draft.ActualBehavior;
            if (steps is not null) steps.Text = draft.StepsToReproduce;
        }
        var suggestion = reporter.Client.SuggestedDraft(incident.IncidentId);
        if (suggestion is not null && tester) Fill(suggestion);
        else if (title is not null) { title.Text = incident.SafeMessage; description.Text = incident.SafeMessage; }
        var metadata = new Dictionary<string, ComboBox>();
        if (signedIn)
            foreach (var field in reporter.Client.Configuration.Fields.Where(f => reporter.Client.Allows(f.Capability)))
            {
                var choice = new ComboBox { Header = field.Label, ItemsSource = field.Choices, HorizontalAlignment = HorizontalAlignment.Stretch };
                AutomationProperties.SetName(choice, field.Label); panel.Children.Add(choice); metadata[field.Key] = choice;
            }
        var consent = new CheckBox { Content = "Include diagnostic information", IsChecked = tester && (!signedIn || reporter.Client.Allows("attach_diagnostics")) };
        var logStatus = new TextBlock { Text = !diagnostics ? "This opens a support request. No logs are sent with it."
            : reporter.Client.FullLogsEnabled ? "Developer logs will be attached automatically when diagnostics are included." : "Only minimal diagnostics will be included.", TextWrapping = TextWrapping.Wrap };
        if (diagnostics) panel.Children.Add(consent);
        panel.Children.Add(logStatus);
        var status = new TextBlock { Text = suggestion is not null && tester ? "ChatGPT noticed this in the logs and drafted the report. Review and edit it before submitting." : "Review before submitting.", TextWrapping = TextWrapping.Wrap };
        AutomationProperties.SetLiveSetting(status, AutomationLiveSetting.Polite);
        void Announce(string message)
        {
            status.Text = message;
            FrameworkElementAutomationPeer.FromElement(status)?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
        }
        if (draftWithAI is not null && AIDrafting.Allowed(reporter.Client))
        {
            var draftButton = new Button { Content = "Draft with ChatGPT" };
            AutomationProperties.SetHelpText(draftButton, "Sends a short redacted summary of this report to your ChatGPT account and fills in the form for you to review");
            draftButton.Click += async (_, _) =>
            {
                draftButton.IsEnabled = false;
                Announce("ChatGPT is drafting this report.");
                try
                {
                    var drafted = await draftWithAI(incident, description.Text);
                    if (drafted is null) Announce("ChatGPT is not connected. You can write the report yourself.");
                    else { Fill(drafted); Announce("ChatGPT draft added. Review and edit it before submitting."); }
                }
                catch (Exception error) { Announce(reporter.Client.Redactor.Text(error.Message)); }
                finally { draftButton.IsEnabled = true; }
            };
            panel.Children.Add(draftButton);
        }
        panel.Children.Add(status);
        var dialog = Dialog(tester ? "Report Issue" : "Report a Problem", new ScrollViewer { Content = panel, MaxHeight = 600 }, "Review Report");
        PreparedReport? prepared = null;
        while (true)
        {
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            try
            {
                var fields = metadata.Where(p => p.Value.SelectedItem is string).ToImmutableDictionary(p => p.Key, p => (string)p.Value.SelectedItem);
                if (name is not null && name.Text.Trim().Length > 0) fields = fields.SetItem("reporter", name.Text);
                if (email is not null && email.Text.Trim().Length > 0) fields = fields.SetItem("email", email.Text);
                prepared = await reporter.PrepareAsync(new(title?.Text ?? "", description.Text, expected?.Text ?? "", actual?.Text ?? "", steps?.Text ?? "", fields), incident, diagnostics && consent.IsChecked == true);
                break;
            }
            catch (Exception error) { Announce(reporter.Client.Redactor.Text(error.Message)); }
        }
        var review = Dialog("Review report before sending", new ScrollViewer { MaxHeight = 600, Content = new TextBox { IsReadOnly = true, AcceptsReturn = true,
            Text = System.Text.Encoding.UTF8.GetString(Wire.Encode(prepared.Draft)) + "\n\n" + (prepared.Bundle?.Preview ?? "No diagnostics selected."), TextWrapping = TextWrapping.Wrap } }, tester ? "Submit Issue" : "Send Feedback");
        if (await review.ShowAsync() != ContentDialogResult.Primary) return;
        while (true)
        {
            try
            {
                var result = await reporter.SubmitAsync(prepared, Reporter.Approve(prepared));
                if (result.Report.Kind == "ticket") { await PreviewAsync("Support request sent", "Support request sent. The team will reply by email if you gave an address."); return; }
                if (result.Complete) { await PreviewAsync("Report submitted", $"Report {result.Report.ReportId} submitted." + (prepared.Bundle is null ? "" : " Selected diagnostic files attached.")); return; }
                var retry = Dialog("Attachment upload incomplete", $"Report {result.Report.ReportId} exists. {result.Pending.Length} attachments need retry.", "Retry Attachments", "Close");
                if (await retry.ShowAsync() != ContentDialogResult.Primary) return;
            }
            catch (Exception error) { await PreviewAsync("Submission could not finish", reporter.Client.Redactor.Text(error.Message)); return; }
        }
    }
    public void Dispose() { if (handler is not null) reporter.Client.IncidentCaptured -= handler; }
}
