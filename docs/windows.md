# Windows integration and verification

You do not need a Windows machine to develop the portable Python or .NET core.
The GitHub Actions Windows job builds native Windows projects and packages the
wx sample on a hosted Windows runner. That job passes. It proves the code builds
and its tests pass on Windows; it does not replace a person using the report
window with a screen reader, which has not been done.

## Python

Follow [Python integration](python.md). The wx integration uses native controls
and dispatches work results back to the UI thread. Build PyInstaller artifacts on
the target operating system; a macOS artifact is not a Windows executable.

## .NET

The alpha targets .NET 10. Add a project reference from your app to
`dotnet/StartTesting.Auth/StartTesting.Auth.csproj`. For a WinUI app, also reference
`dotnet/StartTesting.WinUI/StartTesting.WinUI.csproj`. These are source references;
no NuGet package has been published.

Use the runnable examples in `samples/windows-wpf` and `samples/windows-winui`.
They own a client, mock services and reporter. Replace mock services with your
production adapters before sending real reports. WinUI dialogs require the
window's XamlRoot and UI dispatcher.

## Reporting without an account

`StartTestingInstallService` talks to Start Testing with a project SDK key. In a
development or beta build it files issues with logs and no sign-in. In any other
build it opens a help desk ticket with no logs.

```csharp
var build = BuildResolver.Resolve();
var install = new StartTestingInstallService("st_sdk_...",
    Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "YourApp", "StartTesting", "install-id"),
    build);
var client = new StartTestingClient(new() { ProjectId = projectId, Build = build, FullLogs = true }, install);
await client.RevalidateAsync();
var reporter = new Reporter(client, issues, install, install);
```

Windows has no equivalent of TestFlight detection. A build is a beta build when
its distribution says so, for example a GitHub prerelease or an MSIX flight, or
when the `StartTestingEnvironment` setting says so. Signing in to Start Testing
as a tester is not implemented for .NET yet.

## Noticing errors and letting ChatGPT watch the log

Add `StartTestingLoggerProvider` to your logging, naming your own categories:

```csharp
builder.AddProvider(new StartTestingLoggerProvider(client, LogLevel.Information, ["YourApp."]));
```

In tester mode, an error your own categories log offers a report, at most once a
minute. Categories outside that list, such as `Microsoft.` and `System.`, are
recorded for reports but never raise a prompt.

`AILogMonitor` lets the tester's ChatGPT account read those same records and
offer a drafted report when it judges the app is failing. It reads only your own
categories, sends only failures it has not sent before, and is limited to fifteen
checks an hour. The host app decides when it is enabled:

```csharp
var monitor = new AILogMonitor(client, new ChatGPTLogTriage(provider, () => chosenModel),
    category => category.StartsWith("YourApp."), () => testerTurnedItOn);
monitor.Start();
```

Pass a `draftWithAI` function to `NativeReporter` to add a Draft with ChatGPT
button to the report window.

On a Windows runner:

```powershell
dotnet run --project dotnet/Tests
dotnet build samples/windows-wpf
dotnet build samples/windows-winui/StartTesting.WinUISample.csproj -p:Platform=x64
```

The .NET local OAuth credential store uses Windows DPAPI CurrentUser encryption.
The application must protect its diagnostic storage folder with a per-user ACL.
Diagnostic files are sensitive even after filtering. Never grant tester access
based on debug configuration, MSIX distribution, or possession of a project ID.
