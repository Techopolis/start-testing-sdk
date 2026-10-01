# Verification evidence

Local checks were performed on an Apple silicon Mac with Python 3.14.7,
.NET SDK 10.0.401 and Xcode 27 / Swift 6.4. This is alpha evidence, not a release certification.

| Check | Observed result |
| --- | --- |
| Python including native wx smoke tests | 57 passed |
| Ruff Python lint | Passed |
| Swift package | 7 XCTest tests passed |
| macOS sample | Build passed; no manual VoiceOver audit |
| iOS Simulator sample | Build passed; both UI scenarios reached their expected controls, but the accessibility audit failed (contrast, Dynamic Type and clipping) |
| .NET test runner | 16 core assertions and synthetic OAuth checks passed |
| WPF sample | Cross-build passed; not run on Windows |
| WinUI | Managed source compiled; full local build stops at Windows-only MakePri tool |
| macOS PyInstaller beta and production samples | Built and embedded environment metadata verified |
| Windows CI | Workflow added; no hosted run yet |
| Real service / real ChatGPT account | Not tested |

From the repository root, reproduce checks:

```bash
RUN_WX_TESTS=1 .venv/bin/python -m pytest python/tests -q
.venv/bin/python -m ruff check python samples/python-cli samples/python-wx scripts
swift test --package-path apple
swift build --package-path samples/macos
.local/dotnet/dotnet run --project dotnet/Tests
.local/dotnet/dotnet build samples/windows-wpf
```

Use `dotnet` instead of `.local/dotnet/dotnet` when the SDK is on PATH.
Omit RUN_WX_TESTS on a machine without an interactive desktop; wx tests will skip.

```bash
.venv/bin/python scripts/package_python_sample.py --environment beta
.venv/bin/python scripts/package_python_sample.py --environment production
xcodebuild -project samples/ios/StartTestingSDKSample.xcodeproj \
  -scheme StartTestingSDKSample -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

For UI tests, use `xcrun simctl list devices available` to select an installed
simulator and run the same Xcode project and scheme with
`-destination 'platform=iOS Simulator,id=DEVICE_UUID' test`.
Manual keyboard, VoiceOver and Windows screen-reader evaluation remains outstanding.
