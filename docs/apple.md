# Add the Swift package to an Apple app

Status: alpha, iOS/iPadOS 17+ and macOS 14+. The package is local and unpublished.

1. Open the app's project in Xcode.
2. Choose File > Add Package Dependencies, then Add Local.
3. Select the `apple` folder inside your checkout of this repository.
4. Add `StartTestingAuth` and `StartTestingUI` to the app target. They bring the
   core and diagnostics dependencies. Add those products explicitly if your
   project's dependency policy requires direct dependencies for imported modules.

Apple documents package integration in
[Adding package dependencies to your app](https://developer.apple.com/documentation/xcode/adding-package-dependencies-to-your-app).

Create one client and reporter for the app's lifetime:

```swift
import StartTestingAuth
import StartTestingCore
import StartTestingUI

let services = MockServices()
let client = StartTestingClient(
    projectId: "proj_demo",
    build: BuildInfo(environment: .beta, distribution: .testflight),
    options: Options(fullLogs: true),
    projects: services,
    authorization: services
)
let reporter = Reporter(
    client: client, issues: services, feedback: services, attachments: services
)
```

Use the actual build distribution for your app. Environment does not grant tester
privileges. Inside a SwiftUI view, attach the native incident presentation:

```swift
YourRootView()
    .startTestingIncidents(reporter: reporter)
```

Record actions and handled failures from an asynchronous task:

```swift
await client.breadcrumb("Opened Preferences")
await client.record(
    error, severity: .reportable, userMessage: "Unable to save preferences"
)
```

`error` is the error caught by your app. A demo tester session can be established
with `try await client.setAuthorization(services.authenticate(projectId: "proj_demo"))`.
This is mock authentication only. For a real app, implement the service protocols
against your server and replace `MockServices`.

The [complete sample](../samples/ios/SampleApp.swift) shows ownership, a manual
reporter sheet, mock sign-in, and incident alerts. Open
`samples/ios/StartTestingSDKSample.xcodeproj` to run the iPhone/iPad example.
On Mac, run `swift run --package-path samples/macos` from the repository root.

## Reporting without a tester account

Development and beta builds can report with a project SDK key instead of a
sign-in. Add `StartTestingService`, then:

```swift
import StartTestingService

let install = try StartTestingInstallService(
    sdkKey: "st_sdk_...",   // from Start Testing project settings; beta builds only
    installStore: TesterKeychainStore(service: "com.example.app.StartTesting", account: "install-id"),
    build: build
)
let client = StartTestingClient(
    projectId: projectID, build: build, options: Options(fullLogs: true), projects: install
)
try await client.revalidate()   // loads what the key allows
let reporter = Reporter(client: client, issues: MockServices(), feedback: install, attachments: install)
```

The key identifies the build and a random install ID in Keychain tells
installations apart. Neither identifies a person. The report screen shows the
full form with an optional name, and no internal fields such as priority. See
[authentication](authentication.md).

In any other build, including the App Store build, the same service opens a help
desk ticket instead: a description with an optional name and email, no logs and
no AI drafting. Support replies by email when an address was given. A key
alone never unlocks tester reporting in a production build.

## Tester mode in a production build

A tester can still get the full tester form in the App Store build by signing in
to Start Testing. Create the service with `productionTesters: true`, then attach
the hidden entry to something unremarkable such as the version row:

```swift
Text(version).startTestingTesterMode(
    isOn: { signedInWithProjectAccess },
    signIn: { await signIn(); return message },
    signOut: { await signOut(); return message })
```

Activating the view seven times opens a screen that welcomes the tester, explains
that people who are not testers can close it, and offers Start Testing sign-in.
The server decides whether the account may report for the project. VoiceOver
activations count the same as taps.

Store builds should resolve their build with `BuildResolver.resolveFromStore()`:
TestFlight and the App Store receive the same binary, and only the store receipt
tells them apart.

## System log

When full logs are permitted, a report also attaches `system-log.txt`: this
process's own unified log from two minutes before the issue to one minute after
(`Options.systemLogLead` and `systemLogTrail`; disable with `systemLog: false`).
It cannot include other processes or a previous launch, and values logged as
private remain `<private>`. It is redacted and capped at 2 MB, keeping the newest lines.

## Noticing errors automatically

`await client.record(error, ...)` is how the app reports a failure it caught. In
tester mode the SDK can also notice errors the app only wrote to its log:

```swift
await client.watchSystemLogErrors(subsystems: ["com.example.app"])
```

Error and fault lines logged under those subsystems offer a report, at most once
a minute. Other subsystems are ignored, because system frameworks log routine
errors constantly. This does nothing outside tester mode, and it cannot see
crashes or problems that are never logged.

## ChatGPT drafting

A tester who has connected ChatGPT can turn on "Draft automatically when an error
is reported". Opening the report for an error then sends the redacted excerpt to
ChatGPT straight away and fills in the draft for review. It is off by default.

```swift
import StartTestingChatGPT

let chatGPT = try ChatGPTAuth.standard(
    appName: "Your App", keychainService: "com.example.app.StartTesting.ChatGPT"
)
YourRootView().startTestingIncidents(reporter: reporter, chatGPT: chatGPT)
// or ReporterView(reporter: reporter, incident: incident, chatGPT: chatGPT)
```

The report screen then offers Sign In with ChatGPT and Draft with ChatGPT. See
[ChatGPT integration and eligibility](chatgpt.md) before enabling it in a real app.

## Current limits

- The no-account server routes exist in the proprietary server source but must be
  deployed before `StartTestingInstallService` works against starttesting.net.
- ChatGPT sign-in is tested against a simulated OpenAI service only. It has not
  been run with a real ChatGPT account, and the iOS sign-in sheet has not been
  run on a device.
- User-selected attachments are not yet present in the SwiftUI reporter.
- Swift captures the error's recording context. It does not claim to intercept
  every crash, Objective-C exception, or the original Swift throw stack.
- Automated tests do not establish manual VoiceOver usability.

No App Store release has been performed. New apps must exclude mainland China
(CHN) and preserve Hong Kong, Macau and Taiwan unless explicitly requested
otherwise. Availability must be checked in App Store Connect before release.
