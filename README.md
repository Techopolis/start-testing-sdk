# Start Testing SDK

An open-source SDK from Techopolis that lets people report problems from inside
your app, with the logs a developer needs already attached. Reports go to
[Start Testing](https://starttesting.net), the Techopolis platform for tracking
issues, testing, and support.

**Status: 0.1.0 alpha.** The Swift package for iPhone, iPad, and Mac is the most
complete. Python and .NET contain the core workflow with mock services only.
Read [Platform status](#platform-status) before relying on any of it.

The SDK is licensed under Apache-2.0. The Start Testing service itself is a
separate, proprietary product.

## Why this exists

This started because testers had to sign in before they could report anything.
Seeing a Start Testing login inside someone else's app confused people, and a
tester who just wanted to say "this broke" should not need an account to say it.

At the same time, the logs a testing assistant captured from a Mac during a test
session were far better than anything an app sent on its own. The SDK should get
those same logs from inside the app, so that testing in the app is easy and an
issue arrives with what a developer needs to fix it.

## How it works

The SDK decides what a person can do from the kind of build they are running.
Nobody has to sign in to report a problem.

### Who gets what

- **A test build** (run from Xcode, or installed through TestFlight): the full
  issue form, with no sign-in. Title, description, expected and actual behavior,
  steps to reproduce, and an optional name. Logs are attached automatically. The
  report becomes an issue in your Start Testing project.
- **The App Store build**: a short Report a Problem form with a description and
  an optional name and email. It opens a help desk ticket in Start Testing. No
  logs are sent. Support replies by email if an address was given.
- **A signed-in team member**, in any build: everything a test build gets, plus
  team fields such as priority. The server checks the account and its access to
  the project on every request.

### How a build is identified

Each build carries a project SDK key from your Start Testing project settings.
The key identifies the build, not a person, and you can revoke it at any time.
A random install ID kept in the Keychain tells installations apart so reports
can be grouped and rate limited. Neither one proves who someone is.

TestFlight and the App Store receive the same binary, so the SDK asks the store
at run time which one it is.

### Tester mode

Testers sometimes need the full form in the App Store build. Attach the SDK's
hidden entry to something unremarkable, such as the version number. Activating
it seven times opens a screen that welcomes the tester, tells anyone who is not
a tester to close it, and offers Start Testing sign-in. VoiceOver activations
count the same as taps. Customers never see a tester option.

### How an error is noticed

The app tells the SDK when it catches a failure, and the SDK offers a report. In
tester mode the SDK can also watch the app's own log and offer a report when the
app logs an error, so failures nobody wired up are still noticed. It does not
catch crashes, and it cannot know about problems that are never logged, such as
a mislabeled button. Those are reported by hand, with the same logs attached.

### What a report contains

When the person agrees to include diagnostics, a report attaches:

- `manifest.json`: the list of files with sizes and checksums.
- `incident.json`: what went wrong and when.
- `environment.json`: app version, build, operating system.
- `breadcrumbs.jsonl`: the recent actions your app recorded.
- `dev-logs.txt`: debug and info lines your app recorded.
- `system-log.txt`: the app's own system log from two minutes before the issue
  to one minute after. This includes messages from Apple frameworks running
  inside your app, not only lines your app wrote.

The system log covers only your app's process. It cannot include other apps or
a previous launch, and anything logged as private stays private.

Everything is redacted for passwords, tokens, and keys you register before it is
stored or shown. The person can read exactly what will be sent before sending.
Nothing is submitted just because it was captured.

### ChatGPT drafting

Testers can optionally sign in with their own ChatGPT account and have it draft
the report from the captured diagnostics. They see the exact text that will be
sent to ChatGPT first, and they edit the draft before submitting. A tester can
also choose to have every error report drafted automatically.

A tester can also let ChatGPT watch the app's log. It reads only the lines the
app's own code wrote, never the operating system's, and when it judges that the
app is failing at something it offers a report it has already drafted. The tester
still reviews and sends it. Only a short,
redacted excerpt is sent; the attachments are not. ChatGPT credentials stay in
the device Keychain and never reach Start Testing. This is offered to testers
only, never in the App Store build's support form.

OpenAI offers this sign-in to open-source and locally run apps, and asks paid
or closed apps to apply. See [ChatGPT integration](docs/chatgpt.md) before
turning it on in your own app.

## Platform status

### Apple platforms: iPhone, iPad, Mac

Minimum iOS and iPadOS 17, macOS 14. Everything described above is implemented
in the Swift package under `apple/`.

Checked so far: the unit tests pass, the package builds for iOS, and ChatGPT
sign-in, model listing, and drafting were run against the real OpenAI service on
a Mac. Tester sign-in and project access were run on a physical iPhone.

Not yet checked on a device: the tester mode screen and its seven activations
with VoiceOver, TestFlight detection, a report sent without sign-in, a help desk
ticket, and ChatGPT sign-in on an iPhone.

### Python

The reference implementation of the core workflow, with a wxPython reporter. It
uses an in-memory mock backend and does not contact Start Testing. Reporting
without sign-in, help desk tickets, tester mode, and the system log are not
implemented in Python.

### Windows and .NET (experimental, untested)

**Windows support is experimental. It has never been run on a real Windows
machine.** The .NET libraries contain the core workflow, ChatGPT sign-in, and a
WinUI reporter, all against mock services. Expect rough edges, and please file a
*Windows test report* issue saying what worked and what did not.

## Add it to an Apple app

Add the `apple` folder as a local Swift package and link `StartTestingAuth`,
`StartTestingUI`, and `StartTestingService`.

```swift
import StartTestingAuth
import StartTestingCore
import StartTestingService
import StartTestingUI

let build = await BuildResolver.resolveFromStore()
let install = try StartTestingInstallService(
    sdkKey: "st_sdk_...",
    installStore: TesterKeychainStore(service: "com.example.app.StartTesting", account: "install-id"),
    build: build
)
let client = StartTestingClient(
    projectId: "your-project-id", build: build,
    options: Options(fullLogs: true), projects: install
)
try await client.revalidate()
```

Record what the app does, and report failures:

```swift
await client.breadcrumb("Opened Preferences")
await client.record(error, severity: .reportable, userMessage: "Unable to save preferences")
```

Attach `.startTestingIncidents(reporter:)` to your root view to offer a report
when something fails. The full walkthrough, including tester mode and ChatGPT,
is in [docs/apple.md](docs/apple.md).

## Run the Python demonstration

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -e 'python[dev,chatgpt,wx,packaging]'
.venv/bin/python samples/python-cli/demo.py --submit
.venv/bin/python samples/python-wx/demo.py
```

The examples use the mock backend. `--submit` sends to that mock, not to Start
Testing. See [docs/python.md](docs/python.md).

## Build and test

```bash
swift test --package-path apple
swift run --package-path samples/macos
dotnet run --project dotnet/Tests
```

No package has been published to a registry. Install from this source checkout.

## Using it with Start Testing

You need a project in [Start Testing](https://starttesting.net) and a project
SDK key from that project's settings. The routes the SDK calls are listed in
[docs/backend-contract.md](docs/backend-contract.md). The service's source code
is not part of this repository.

## Repository

- `apple/`: Swift package, native SwiftUI views, tests.
- `python/`: reference core, wxPython integration, tests.
- `dotnet/`: .NET libraries, Windows reporter, test runner.
- `samples/`: sample apps for each platform.
- `docs/`: architecture, privacy, threat model, and platform guides.

## Contributing

Bug reports and pull requests are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md), the [Code of Conduct](CODE_OF_CONDUCT.md),
and [SUPPORT.md](SUPPORT.md). Report security problems privately as described
in [SECURITY.md](SECURITY.md).

## Contributors

<a href="https://github.com/Techopolis/start-testing-sdk/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=Techopolis/start-testing-sdk" alt="Profile pictures of the people who have contributed to the Start Testing SDK" />
</a>

Made with [contrib.rocks](https://contrib.rocks).

## License

[Apache-2.0](LICENSE)
