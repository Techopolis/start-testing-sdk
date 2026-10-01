# Implementation status

This repository is a working 0.1 alpha, not a completed production V1.

| Area | Implemented | Outstanding |
| --- | --- | --- |
| Python | Bounded diagnostics, privacy filters, frozen incidents, authorization protocols, mock backend, reviewed reports, automatic logs, retries, wx UI | Real service adapter; Windows runtime/accessibility evidence |
| Swift | Core actor workflow, storage, privacy, native SwiftUI reporter and alerts, real tester OAuth/service adapter, project key reporting without an account, system log attachment, ChatGPT sign-in and drafting | Deployment and live verification of project key routes; live ChatGPT account verification; user-selected attachments; complete UI validation |
| .NET | Core workflow, storage, privacy, mocks, logging, OAuth, WinUI reporter and WPF/WinUI samples, project key reporting without an account, help desk tickets, prompts for logged errors, AI log monitor | Tester sign-in to Start Testing; tester mode screen; live verification against the service; use on a real Windows machine; selected attachments; complete accessibility validation |
| ChatGPT | Python and .NET desktop implementations; synthetic OAuth tests | Live account verification, deployment eligibility review, native macOS implementation; iOS remains gated |
| Distribution | Apache-2.0 source and package metadata; local macOS PyInstaller examples | Registry publication, signed platform artifacts, release audit |

The Swift service adapter now has matching authenticated endpoints in the
proprietary server. Perspective Transcribe integrates real tester sign-in in
Debug and InternalTesting builds, with the tester screen hidden in Release.
Python and .NET samples still use mocks. A physical iPhone run verified real account login and project access after the
production deployment. Two tester reports reached production on 2026-10-01 with
four of five attachments; the breadcrumbs file was rejected by a server build
that predated the fix accepting that content type. A full five-file submission
against the current server has not yet been confirmed.

Anonymous production feedback, registry distribution, complete accessibility
validation and the other outstanding items above remain unfinished. See
[backend-contract.md](backend-contract.md) for the implemented tester contract.

## Windows without a Windows computer

The checked-in GitHub Actions workflow runs Windows tests and builds on hosted
Windows runners after the source is pushed to a GitHub repository with Actions
enabled. This workflow has not yet run remotely. It does not require the user to
own Windows. Human screen-reader evaluation remains separate from automated CI.

See [verification](verification.md) for commands and the limits of local evidence.
