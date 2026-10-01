# Start Testing authentication and modes

Configure the public project ID. Supply AuthenticationService, AuthorizationService,
ProjectService, IssueService, FeedbackService and AttachmentService implementations
as needed. SessionService is a future backend adapter seam. Core has no live endpoints.

The provided mocks create test identities in memory. Calling `authenticate` on a
mock is a demonstration, not a real login. A production adapter must use the real
Start Testing identity flow and return only server-verified grants.

A grant binds an opaque grant ID, subject, project, expiry, and capability names.
Examples: create_issue, attach_diagnostics, attach_full_logs, attach_files,
set_priority, set_severity, select_milestone, add_labels, assign_issue,
view_testing_session, use_ai, submit_feedback. Project field definitions also carry
the capability required to show or set that field.

Grants are short-lived local UI hints between service calls. Revocation is checked
on prepare and submit; there is no automatic revocation push channel in this alpha.
The backend must reject revoked grants even if the local UI still shows a cached
permission. Build metadata never substitutes for authorization.

| Build environment | Authorized tester with project policy | Other user |
| --- | --- | --- |
| development | Authenticated tester | Restricted configured feedback |
| beta | Authenticated tester | Restricted configured feedback |
| production | Support by default; a signed-in tester when the app opts in with `productionTesters` | Support (help desk ticket) |
| unknown | Support by default | Support |

## Project key reporting without an account

A service that authenticates the build itself, such as the Swift
`StartTestingInstallService` with a project SDK key, can set
`installDiagnostics` in the project configuration. In development and beta builds
only, that enables the full report form, the unrestricted diagnostic bundle and
full logs without a tester grant. The key and the random install ID identify a
build and an installation, not a person: anyone holding the build can report. The
server accepts no internal fields on this path, lets an install attach only to
its own reports, and limits reports per install. Revoke the key to stop it.

Debug and info records are now kept locally in development and beta builds
whenever full logs are enabled in the options, so the log exists before sign-in.
Sending them still requires a grant with attach_full_logs or project key reporting.

External feedback defaults to disabled without configuration. errors_only enables
incident feedback, while manual_and_errors also permits manual reports. Internal
fields are omitted from public configuration and stripped from public feedback.
