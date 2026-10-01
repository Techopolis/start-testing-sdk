# Start Testing service adapter

The Swift StartTestingService product implements real tester authentication,
project discovery, issue creation and diagnostic uploads against starttesting.net.
The adjacent proprietary Start-testing repository now contains the corresponding
server endpoints. Its pre-existing OAuth, membership and storage code was used as
the integration contract. The adjacent Start-Testing-iOS app was inspected as a
protocol reference; its implementation was not copied into this open-source SDK.

## Authentication and authority

Apple ASWebAuthenticationSession opens the server's OAuth authorization screen.
The native client uses dynamic registration, PKCE S256, a random state and an
app-specific callback scheme. The token exchange requires read/write access.
Tokens remain in Keychain and refresh through the existing server OAuth endpoint.
No Firebase secret, API key or client secret is embedded in the app.

`GET /api/sdk/tester/session` authenticates the OAuth caller, matches the host app's
bundle identifier or exact app name, and returns accessible project configuration.
A returned capability statement lasts 15 minutes and is tied to user and project.
It is configuration received over authenticated HTTPS, not an independent bearer
credential. Every write authenticates the current OAuth token and independently
checks live project membership and capabilities. Debug or TestFlight build status
does not grant permissions. API-key credentials cannot use the tester routes.

## Implemented routes

| Method and path | Behavior |
| --- | --- |
| GET /api/sdk/tester/session | Current tester identity, matching projects and permitted fields |
| POST /api/sdk/tester/reports | Create an issue with the caller as reporter; return reportId and kind |
| POST /api/sdk/tester/reports/{id}/attachments | Upload bounded JSON/text diagnostics to an owned report |
| POST /api/sdk/tester/signout | Revoke the current OAuth session and associated refresh token |

Issue creation uses the request UUID and caller/project scope to deduplicate
retries. Changed fields under the same request ID are rejected. Attachment IDs
are deterministic per report and request; retries verify content hash and metadata.
Uploads are bounded to 4 MB, stored privately and counted against workspace quota.
Full logs require the additional attach_full_logs capability. Attachment content
is JSON or plain text; arbitrary user-selected files are not supported by this route.

## Project key routes

These authenticate with `X-Start-Testing-Key` and need no account. They are in
the server source and are not yet deployed.

| Method and path | Behavior |
| --- | --- |
| GET /api/sdk/config | Project name and whether reports and diagnostics are enabled for the key |
| POST /api/sdk/reports | Create an issue from an install; title and text fields only |
| POST /api/sdk/reports/{id}/attachments | Upload diagnostics to a report made by the same key and install |

Production builds use the existing `POST /api/sdk/events` route with type
`support`, which opens a help desk ticket. `GET /api/sdk/config` reports
`supportEnabled` when the key allows support and the organization has a help desk.

Reports are stored with source sdk_feedback. Limits: 20 reports per install per
hour, 10 attachments per report, attachments accepted for 24 hours, 4 MB each.

## Field mapping

| SDK logical field | Service JSON field |
| --- | --- |
| project | projectId |
| title | draft.title |
| description | draft.description |
| reproduction steps | draft.stepsToReproduce |
| expected behavior | draft.expectedBehavior |
| actual behavior | draft.actualBehavior |
| priority | draft.metadata.priority |

The server resolves organization scope and filters priority editing by capability.
Issue creation reuses existing bugs and entityAttachments tables; no database
migration was added. It does not send email or invoke automated fixing.

## Remaining work and verification limits

The Python and .NET examples still use their mock adapters. Anonymous production
feedback through the Swift adapter is explicitly unavailable; Transcribe retains
its existing support email entry. The older SDK-key ingestion route is separate.
Persistent resumable submissions and arbitrary attachments remain future work.

Backend lint, TypeScript checks, production build and contract tests passed.
Swift service tests cover PKCE, callback validation, refresh, identity mismatch
and local clearing when remote sign-out fails. A physical iPhone run separately verified live account login and Perspective
Transcribe project access. The production server deployment is active. A reviewed
report submission and its attachments still need end-to-end verification.
