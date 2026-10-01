# Initial threat model

This is a design review of the alpha, not a completed penetration test.

| Threat | Existing control | Remaining work |
| --- | --- | --- |
| Anonymous caller reaches internal issue fields | Conservative modes and capability checks; mock independently validates grants | Verify production server enforcement |
| Logs disclose credentials | Key/value/regex filters before storage and upload; review and consent | App-specific sensitive values; adversarial data review |
| Local diagnostics grow without bound | Buffer and disk count, byte and age limits | Long-running platform stress tests |
| A later error changes a pending report | Immutable incident snapshots | Review all custom adapters for mutation |
| Upload retry creates duplicate issues | Idempotency keys and in-memory report progress | Production server semantics and restart recovery |
| OAuth callback injection | Bound loopback, host/path/state, PKCE, nonce, verified JWT | Live provider interoperability |
| Identity login used as inference permission | Explicit plan-use scope guard | Provider integration verification |
| AI changes permissions or submits a report | Text-only draft, separate manual approval | Native-platform feature completion |
| Account changes expose old diagnostics | Incident subject binding in report submission | Thorough native preview and account-switch audit |
| Local malware reads app files | Private local files, credential vault/DPAPI | Host ACL setup; no claim of defense against compromised user account |

A successful mock test cannot establish the security of a proprietary production
server. Before release, validate those boundaries against the real service.
