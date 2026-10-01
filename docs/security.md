# Security boundaries

See [SECURITY.md](../SECURITY.md), [privacy](privacy.md), and the
[threat model](threat-model.md). This alpha has not received an independent security audit.

The public project ID identifies a project; it grants no access. Backend adapters
must authenticate the caller and enforce current project capabilities on every
write. UI visibility is not an authorization boundary. The local mock enforces
its own grants so unit tests can exercise denial and revocation.

Diagnostic capture is local and bounded. Filtering precedes storage and is
reapplied before submission. Registered custom filters are trusted application
code. Filtering is a risk reduction measure, not proof that arbitrary text or
images contain no sensitive information. Users must review what they attach.

Credentials stay in the platform credential store and are excluded from report
bundles. AI context requires explicit consent and a scope-authorized connection.
Server adapters need bounded responses, timeouts, HTTPS, safe errors and explicit
redirect policy. Never log access tokens, refresh tokens, authorization codes or
whole authentication responses.
