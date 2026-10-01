# Security policy

This is an alpha. The Swift package talks to the Start Testing service; the
Python and .NET packages use mock services only.

## Reporting a vulnerability

Report it privately through
[GitHub security advisories](https://github.com/Techopolis/start-testing-sdk/security/advisories/new).
Do not post exploit details or private logs in a public issue.

## What this project touches

- Keychain: the tester sign-in session, a random install ID, and ChatGPT
  credentials when a tester connects ChatGPT. Windows uses DPAPI and Python uses
  the operating system keyring.
- User defaults: an optional reporter name and email, the selected ChatGPT
  model, and the registered sign-in client ID.
- Disk: an optional diagnostic store of recent events and unsent incidents in a
  directory the host app chooses, excluded from backup and bounded in size.
- The app's own system log, read only when a report is being prepared.
- Network: starttesting.net for reports, and auth.openai.com and api.openai.com
  only when a tester uses ChatGPT drafting.
- A listener on 127.0.0.1 that exists only while ChatGPT sign-in is open.
- The default browser or the system sign-in sheet, for sign-in.

It starts no background jobs and installs nothing.

## Handling secrets

Do not put access tokens, refresh tokens, SDK secrets, private project credentials,
signing keys, or raw customer data in issues, diagnostic fixtures, or sample apps.
Public project IDs are not secrets. Fake test credentials are explicitly labeled.

A project SDK key ships inside the app and should be treated as public. It lets
a build create reports and nothing else. Revoke it in Start Testing if it is abused.

Every production service adapter must enforce project membership, grant lifetime,
revocation, per-action capabilities, report ownership, feedback policy, attachment
limits and idempotency on the server. The client is not a security boundary.

Diagnostic redaction is best effort. Avoid logging sensitive data at the source.
Images are user-selected and require inspection; this SDK does not remove secrets
from image pixels or image metadata. Current storage uses bounded retention and
per-user directories; Windows hosts must supply a private local-app-data directory
with appropriate ACLs. OS account compromise remains outside the SDK's protection.

See docs/threat-model.md and docs/privacy.md for the limits of these protections.
