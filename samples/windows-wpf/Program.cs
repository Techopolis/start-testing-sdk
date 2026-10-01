using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
using StartTesting.Auth;
using StartTesting.Core;

namespace StartTestingWpfSample;
public static class Program
{
    [STAThread]
    public static void Main()
    {
        var backend = new MockBackend();
        using var client = new StartTestingClient(new() { ProjectId = "proj_demo", Build = new(AppEnvironment.Beta, Distribution.GithubPrerelease), FullLogs = true }, backend, backend);
        var reporter = new Reporter(client, backend, backend, backend);
        var panel = new StackPanel { Margin = new Thickness(20) };
        var title = new TextBox(); AutomationProperties.SetName(title, "Issue Title");
        var description = new TextBox { AcceptsReturn = true, MinHeight = 100 }; AutomationProperties.SetName(description, "Description");
        var status = new TextBox { IsReadOnly = true, Text = "Local mock backend. Sign in to report." }; AutomationProperties.SetName(status, "Report status");
        var login = new Button { Content = "Sign in as Mock Tester" };
        var capture = new Button { Content = "Trigger reportable error" };
        var submit = new Button { Content = "Review and Submit", IsEnabled = false };
        Incident? incident = null;
        login.Click += async (_, _) => { await client.SetAuthorizationAsync(await backend.AuthenticateAsync("proj_demo")); status.Text = "Mock tester signed in. Developer logs attach automatically."; submit.IsEnabled = true; };
        capture.Click += (_, _) => { client.Breadcrumb("Opened Preferences"); incident = client.RecordError(new InvalidOperationException("Save failed")); status.Text = "Diagnostics captured. Nothing submitted."; };
        submit.Click += async (_, _) => {
            try {
                var report = await reporter.PrepareAsync(new(title.Text, description.Text), incident, true);
                if (MessageBox.Show("Send this issue and its diagnostic bundle?\n" + report.Bundle?.Preview, "Review report", MessageBoxButton.OKCancel) != MessageBoxResult.OK) return;
                var result = await reporter.SubmitAsync(report, Reporter.Approve(report));
                status.Text = result.Complete ? "Issue submitted. Developer logs attached." : "Issue created; attachments incomplete.";
            } catch (Exception error) { status.Text = client.Redactor.Text(error.Message); }
        };
        panel.Children.Add(login); panel.Children.Add(capture); panel.Children.Add(new Label { Content = "Issue Title", Target = title }); panel.Children.Add(title);
        panel.Children.Add(new Label { Content = "Description", Target = description }); panel.Children.Add(description); panel.Children.Add(submit); panel.Children.Add(status);
        new Application().Run(new Window { Title = "Start Testing WPF - Local mock sample", Content = panel, Width = 650, Height = 500 });
    }
}
