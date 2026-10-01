# Optional ChatGPT drafting

Python desktop and .NET implement the official open-source desktop sign-in flow.
The implementation uses a loopback listener bound before browser launch, PKCE,
state and nonce, a dynamic client ID persisted per profile, and verified RS256 ID
tokens. Identity-only authorization is insufficient: inference requires
`chatgpt.tokens.use.direct`. Refresh tokens remain in local credential storage.

Python uses supported operating-system keyring backends. .NET uses Windows DPAPI.
Memory stores exist for tests only. Do not use them for production credentials.
OAuth tests use synthetic signed tokens; no real user account was used here.

Model discovery uses the documented models response. Draft requests use the
public Responses API with `store=false`, `stream=true`, and require a completed
response event. Only the reviewed, redacted, bounded incident excerpt is sent.
The full diagnostic attachment bundle is not sent to ChatGPT. AI output supplies
editable prose and cannot submit reports or choose issue metadata.

Swift implements the same flow in `ChatGPTAuth` and `ChatGPTProvider`, with
credentials in the Keychain and sign-in and drafting controls in the SwiftUI
reporter. macOS opens the default browser. iOS presents the system sign-in sheet
so the app stays in front while its loopback listener waits. OpenAI's documentation
requires a loopback callback and does not address mobile apps; the iOS path is
untested on a device and with a real account. Drafting is offered to authorized
testers with `use_ai` and to development and beta installs reporting with a
project key. Production builds never offer it.

The SDK's Apache license does not establish eligibility for every embedding app.
The official access rules distinguish open-source applications from paid or
remotely hosted integrations; review them before enabling this in a real app.

Official sources reviewed:

- [OSS eligibility](https://developers.openai.com/siwc/token-sharing-open-source)
- [Sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [Profiles and sessions](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
- [Models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [Recovery](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery)
- [Preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
