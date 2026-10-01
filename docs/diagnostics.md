# Diagnostics

Events contain UTC capture timestamps, session ID, sequence, category, message,
structured fields and a normalized type. Python additionally accepts explicit screen
and task IDs and records the thread ID. The .NET adapter records managed thread IDs.
Swift records an explicit call-site stack for `record(error:)`; Swift Error does not
carry the original throw stack.

Buffers are bounded by count, serialized bytes, and age. Python/.NET/Swift default
to 1,000 events, 2 MB, and 15 minutes. Event messages and structured data are bounded.
The recent report window defaults to five minutes. Oversized events are replaced
with a size-limit marker or dropped when even the marker exceeds the buffer limit.
Dropping old events is expected; this is not a lossless audit log.

The logical bundle is version 1: manifest.json, incident.json, environment.json,
breadcrumbs.jsonl, and dev-logs.txt when permitted. Manifest entries contain logical
names, sizes and SHA-256 digests. Upload display names receive the final issue ID
prefix; a real backend adapter should preserve logical names as metadata.

Bundles can be inspected without uploading. Python exposes a ZIP serializer and
byte-size calculation; Swift/.NET expose immutable upload entries and previews.
The logical contract is portable; platform event extensions and serialized date
precision differ. Do not assume platform bundles are byte-identical.

Application logging integrations are opt-in. Python uses a logging.Handler and
.NET uses ILoggerProvider. Neither changes the application's global logger level.
Swift applications call explicit record/breadcrumb APIs; this alpha does not read
the operating system's unified log database.
