using System.Collections.Immutable;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using StartTesting.Auth;
using StartTesting.Core;
using StartTesting.Diagnostics;

namespace StartTesting.WinUI;

public sealed class NativeReporter(FrameworkElement root, Reporter reporter) : IDisposable
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
        bool tester = reporter.Client.Mode == UserMode.AuthenticatedTester;
        var alert = Dialog("Diagnostics captured", incident.Severity == ErrorSeverity.Fatal
            ? "The app closed unexpectedly during the previous session. Would you like to send a diagnostic report?"
            : tester ? "Something went wrong. Start Testing captured diagnostic information for this incident. Would you like to report it?"
            : "Something went wrong. Would you like to send diagnostic information to support?",
            tester ? "Report Issue" : "Report a Problem", "Dismiss");
        alert.SecondaryButtonText = "View Diagnostics";
        showing = true;
        try
        {
            var result = await alert.ShowAsync();
            if (result == ContentDialogResult.Secondary)
            {
                var bundle = DiagnosticBundle.Create(incident, reporter.Client.Redactor,
                    tester && reporter.Client.FullLogsEnabled && incident.TesterSubject == reporter.Client.Grant?.Subject, !tester);
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
        bool tester = reporter.Client.Mode == UserMode.AuthenticatedTester;
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
        var metadata = new Dictionary<string, ComboBox>();
        if (tester)
            foreach (var field in reporter.Client.Configuration.Fields.Where(f => reporter.Client.Allows(f.Capability)))
            {
                var choice = new ComboBox { Header = field.Label, ItemsSource = field.Choices, HorizontalAlignment = HorizontalAlignment.Stretch };
                AutomationProperties.SetName(choice, field.Label); panel.Children.Add(choice); metadata[field.Key] = choice;
            }
        var consent = new CheckBox { Content = "Include diagnostic information", IsChecked = tester && reporter.Client.Allows("attach_diagnostics") };
        panel.Children.Add(consent);
        var logStatus = new TextBlock { Text = reporter.Client.FullLogsEnabled ? "Developer logs will be attached automatically when diagnostics are included." : "Only minimal diagnostics will be included.", TextWrapping = TextWrapping.Wrap };
        panel.Children.Add(logStatus);
        var status = new TextBlock { Text = "Review before submitting.", TextWrapping = TextWrapping.Wrap };
        AutomationProperties.SetLiveSetting(status, AutomationLiveSetting.Polite); panel.Children.Add(status);
        var dialog = Dialog(tester ? "Report Issue" : "Report a Problem", new ScrollViewer { Content = panel, MaxHeight = 600 }, "Review Report");
        PreparedReport? prepared = null;
        while (true)
        {
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            try
            {
                var fields = metadata.Where(p => p.Value.SelectedItem is string).ToImmutableDictionary(p => p.Key, p => (string)p.Value.SelectedItem);
                prepared = await reporter.PrepareAsync(new(title?.Text ?? "", description.Text, expected?.Text ?? "", actual?.Text ?? "", steps?.Text ?? "", fields), incident, consent.IsChecked == true);
                break;
            }
            catch (Exception error)
            {
                status.Text = reporter.Client.Redactor.Text(error.Message);
                FrameworkElementAutomationPeer.FromElement(status)?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
            }
        }
        var review = Dialog("Review report before sending", new ScrollViewer { MaxHeight = 600, Content = new TextBox { IsReadOnly = true, AcceptsReturn = true,
            Text = System.Text.Encoding.UTF8.GetString(Wire.Encode(prepared.Draft)) + "\n\n" + (prepared.Bundle?.Preview ?? "No diagnostics selected."), TextWrapping = TextWrapping.Wrap } }, tester ? "Submit Issue" : "Send Feedback");
        if (await review.ShowAsync() != ContentDialogResult.Primary) return;
        while (true)
        {
            try
            {
                var result = await reporter.SubmitAsync(prepared, Reporter.Approve(prepared));
                if (result.Complete) { await PreviewAsync("Report submitted", $"Report {result.Report.ReportId} submitted. Selected diagnostic files attached."); return; }
                var retry = Dialog("Attachment upload incomplete", $"Report {result.Report.ReportId} exists. {result.Pending.Length} attachments need retry.", "Retry Attachments", "Close");
                if (await retry.ShowAsync() != ContentDialogResult.Primary) return;
            }
            catch (Exception error) { await PreviewAsync("Submission could not finish", reporter.Client.Redactor.Text(error.Message)); return; }
        }
    }
    public void Dispose() { if (handler is not null) reporter.Client.IncidentCaptured -= handler; }
}
