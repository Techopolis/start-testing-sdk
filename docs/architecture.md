# Architecture

The SDK is independently licensed client software. It has no database dependency
and contains no proprietary server implementation. Existing Start Testing models
were reviewed before defining the contracts; see backend-contract.md.

## Responsibilities

| Layer | Responsibility |
| --- | --- |
| Core models | Environments, distributions, sessions, incidents, grants and drafts |
| Diagnostics | Redaction, bounded buffers, opt-in local files and frozen context |
| Authorization | Server-supplied capabilities, expiry and project scoping |
| Reporter | Consent, exact report review, issue creation and attachment retries |
| Platform UI | Native controls, focus, alert actions and status messages |
| ChatGPT | Local identity, plan permission and sanitized draft generation |
| Backend adapter | Project authorization, intake and attachment transport |

Python is the reference implementation. Models are value objects; nested Python
fields use serialized JSON, Swift uses value types, and .NET uses immutable
collections. Later log events do not mutate an Incident. A monotonically increasing
sequence preserves capture order within a session.

The service interfaces deliberately describe operations rather than hard-coded
URLs. Authentication yields a project-scoped CapabilitySet. A project service
returns only permitted fields. Create and attach operations receive the grant,
project ID and idempotency key. Production adapters must validate these independently
on every request. A malicious embedding app can alter every client-side check.

## Submission

Prepare revalidates authorization, sanitizes the draft, builds the selected bundle,
and binds the report to its owner and current mode. Approval identifies the exact
prepared report. Submit checks approval, revalidates permission and redaction, and
creates the issue. Attachments are then uploaded with stable idempotency keys.
Partial failure returns the issue reference plus pending attachment names.

No automatic retry loop sends data in the background. In-memory retry state lasts
for the current reporter instance. The backend must retain idempotency keys long
enough to recover an ambiguous response. A durable cross-restart submission queue
is not implemented in this alpha.

## Extending platforms

PySide, PyQt and Tkinter can adapt the Python Client and Reporter without importing
wxPython. WinForms and WPF can use the .NET libraries without WinUI. Future Android
and other SDKs should consume the logical contracts in schemas/ and add matching
conformance fixtures. Those adapters are not implemented in this release.
