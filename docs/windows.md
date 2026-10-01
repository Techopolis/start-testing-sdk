# Windows integration and verification

You do not need a Windows machine to develop the portable Python or .NET core.
The GitHub Actions Windows job builds native Windows projects and packages the
wx sample on a hosted Windows runner after this repository is pushed to GitHub.
It has not run yet. It does not replace a human screen-reader audit.

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
