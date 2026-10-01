using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using StartTesting.Auth;
using StartTesting.Core;
using StartTesting.WinUI;

namespace StartTestingSample;
public partial class App : Application
{
    private Window? window;
    public App() { InitializeComponent(); }
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var backend = new MockBackend();
        var client = new StartTestingClient(new() { ProjectId = "proj_demo", Build = new(AppEnvironment.Beta, Distribution.GithubPrerelease), FullLogs = true }, backend, backend);
        window = new Window { Title = "Start Testing SDK - Local mock demo" };
        var panel = new StackPanel { Spacing = 12, Padding = new Thickness(20) };
        var reporter = new NativeReporter(panel, new Reporter(client, backend, backend, backend));
        reporter.InstallIncidentAlerts();
        var signIn = new Button { Content = "Sign in as Mock Tester" };
        signIn.Click += async (_, _) => { await client.SetAuthorizationAsync(await backend.AuthenticateAsync("proj_demo")); signIn.Content = "Mock tester signed in"; };
        var fail = new Button { Content = "Trigger reportable error" };
        fail.Click += (_, _) => { client.Breadcrumb("Opened Preferences"); client.Record("Audio engine starting", EventType.Debug); client.RecordError(new System.InvalidOperationException("Preview failed")); };
        var manual = new Button { Content = "Open reporter" };
        manual.Click += async (_, _) => await reporter.ShowAsync();
        panel.Children.Add(new TextBlock { Text = "All Start Testing submissions use the local mock backend." });
        panel.Children.Add(signIn); panel.Children.Add(fail); panel.Children.Add(manual);
        window.Content = panel; window.Closed += (_, _) => { reporter.Dispose(); client.Dispose(); }; window.Activate();
    }
}
