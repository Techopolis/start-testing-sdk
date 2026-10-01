# Contributing

Bug reports, test reports from real devices, and pull requests are all welcome.
Windows has never been run on a real machine, so a Windows test report is a real
contribution even if everything worked.

This project is built by and for people who use screen readers. Anything a
person reads, including UI text, error messages, documentation, and release
notes, must make sense read aloud as plain text. No emoji or decorative
characters. Every control needs a label, and every image needs alt text.

Use plain ASCII for source, UI strings, and documentation. Keep source files under
600 lines. Do not change the proprietary service while working on this SDK.

1. Describe the behavioral change and affected platform.
2. Preserve the separation between environment, distribution, and authorization.
3. Add tests for behavior and security boundaries. Use only synthetic data.
4. Run the checks in docs/verification.md, including native builds for affected UI.
5. Document what was tested locally and what still requires another platform.
6. Submit changes under Apache-2.0. Preserve dependency and reused-code attribution.

A diagnostic change needs tests for bounded storage and secret filtering before
persistence and transmission. A reporting change needs tests for explicit review,
restricted feedback, denied/expired grants, automatic logs, and upload retry.
An authentication change needs cryptographic token tests and callback failure tests.

Run Python formatting and linting with the repository configuration. Use
`swift format format --in-place --recursive apple/Sources apple/Tests` for Swift.
Use `dotnet format <project> whitespace` for C# projects.

No production uploads, package publication, signing changes, or App Store releases
are part of ordinary local verification. New App Store apps must exclude mainland
China (CHN), preserve Hong Kong, Macau and Taiwan, and verify live availability
before release.
